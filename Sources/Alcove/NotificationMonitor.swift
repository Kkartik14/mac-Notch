import AppKit
import Combine
import Foundation
import SQLite3

/// Live notification reader (disk adapter, usernoted store).
/// Polls `group.com.apple.usernoted/db2/db` read-only for new `record` rows
/// and decodes the plist payload (app bundle, title, subtitle, body).
/// iPhone-mirrored arrivals land in this same store when relayed, so they
/// flow through untouched. Needs Full Disk Access; without it the monitor
/// stays silent and the demo fallback remains. Never prompts, never nags.
final class NotificationMonitor: ObservableObject {
    struct Note: Equatable {
        var appIdentifier: String
        var title: String
        var subtitle: String
        var body: String
        var date: Date
    }

    private static var dbURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(
                "Library/Group Containers/group.com.apple.usernoted/db2/db",
                isDirectory: false)
    }

    private var pollTimer: Timer?
    private var dirSource: DispatchSourceFileSystemObject?
    private var lastSeenID: Int64?
    private var warnedNoAccess = false
    private var nameCache: [String: String] = [:]
    var onNew: ((Note) -> Void)?

    /// True when the store is actually readable (FDA granted).
    static var hasAccess: Bool {
        var db: OpaquePointer?
        defer { if db != nil { sqlite3_close(db) } }
        guard sqlite3_open_v2(Self.dbURL.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { return false }
        var stmt: OpaquePointer?
        defer { if stmt != nil { sqlite3_finalize(stmt) } }
        return sqlite3_prepare_v2(db, "SELECT rec_id FROM record LIMIT 1", -1, &stmt, nil) == SQLITE_OK
    }

    deinit { stop() }

    func start() {
        // Baseline at current max: never replay history.
        lastSeenID = maxRecordID()
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 4.0, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        dirSource?.cancel()
        let dir = Self.dbURL.deletingLastPathComponent().path
        let fd = open(dir, O_EVTONLY)
        if fd >= 0 {
            let src = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: fd, eventMask: .write, queue: .main)
            src.setEventHandler { [weak self] in self?.refresh() }
            src.setCancelHandler { close(fd) }
            src.resume()
            dirSource = src
        }
    }

    func stop() {
        pollTimer?.invalidate()
        pollTimer = nil
        dirSource?.cancel()
        dirSource = nil
    }

    func refresh() {
        guard let baseline = lastSeenID else {
            lastSeenID = maxRecordID()
            return
        }
        guard let fresh = records(newerThan: baseline) else {
            if !warnedNoAccess {
                warnedNoAccess = true
                NSLog("[Alcove] notifications: store unreadable (no Full Disk Access?) — demo only")
            }
            return
        }
        warnedNoAccess = false
        for (recID, note) in fresh {
            lastSeenID = max(lastSeenID ?? 0, recID)
            if !note.title.isEmpty || !note.body.isEmpty {
                NSLog("[Alcove] notifications: %@ / %@", note.appIdentifier, note.title)
                onNew?(note)
            }
        }
    }

    // MARK: - Store access (all synchronous, read-only, tiny reads)

    private func maxRecordID() -> Int64? {
        var db: OpaquePointer?
        guard sqlite3_open_v2(Self.dbURL.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_close(db) }
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, "SELECT MAX(rec_id) FROM record", -1, &stmt, nil) == SQLITE_OK,
              sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        let v = sqlite3_column_int64(stmt, 0)
        return v > 0 ? v : 0
    }

    private func records(newerThan baseline: Int64) -> [(Int64, Note)]? {
        var db: OpaquePointer?
        guard sqlite3_open_v2(Self.dbURL.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_close(db) }
        var stmt: OpaquePointer?
        let sql = """
        SELECT r.rec_id, a.identifier, r.data FROM record r
        LEFT JOIN app a ON a.app_id = r.app_id
        WHERE r.rec_id > ? ORDER BY r.rec_id ASC LIMIT 10
        """
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, baseline)
        var out: [(Int64, Note)] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let recID = sqlite3_column_int64(stmt, 0)
            let appID = sqlite3_column_text(stmt, 1).map { String(cString: $0) } ?? ""
            guard let blob = sqlite3_column_blob(stmt, 2) else { continue }
            let len = Int(sqlite3_column_bytes(stmt, 2))
            guard len > 0 else { continue }
            let data = Data(bytes: blob, count: len)
            if let note = Self.parse(data: data, appIdentifier: appID) {
                // drop our own noise
                if appID == "com.tryalcove.alcove" { continue }
                out.append((recID, note))
            }
        }
        return out
    }

    /// Pure decode of one record payload. Separated for unit testing.
    static func parse(data: Data, appIdentifier: String) -> Note? {
        guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { return nil }
        let req = plist["req"] as? [String: Any] ?? [:]
        let title = (req["titl"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let subtitle = (req["subt"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let body = (req["body"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        var date = Date()
        if let t = plist["date"] as? Double, t > 0 {
            date = Date(timeIntervalSinceReferenceDate: t) // Cocoa epoch (2001)
        }
        return Note(appIdentifier: appIdentifier, title: title, subtitle: subtitle, body: body, date: date)
    }

    /// Display name for a bundle id, cached (hits disk via bundle lookup).
    func displayName(for bundleID: String) -> String {
        if let cached = nameCache[bundleID] { return cached }
        var name = bundleID
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID),
           let bundle = Bundle(url: url),
           let disp = (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
               ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String) {
            name = disp
        } else if bundleID.hasPrefix("_system_center_:") {
            name = "System"
        }
        nameCache[bundleID] = name
        return name
    }

    /// App icon bytes for the island, nil when unresolvable (view falls back).
    func iconData(for bundleID: String) -> Data? {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        let img = NSWorkspace.shared.icon(forFile: url.path)
        guard let tiff = img.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return nil }
        return png
    }
}
