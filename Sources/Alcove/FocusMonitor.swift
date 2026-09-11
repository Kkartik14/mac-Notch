import AppKit
import Combine
import Foundation
import SwiftUI

/// Live Focus-mode reader (disk adapter, see DEC-001).
/// Reads `~/Library/DoNotDisturb/DB/` directly: active assertion ->
/// mode identifier -> name/symbol/tint from ModeConfigurations.
/// Needs Full Disk Access; without it every read fails and the monitor
/// stays silent so manual modes remain in charge. Never prompts, never nags.
final class FocusMonitor: ObservableObject {
    /// Live state. Nil = no Focus active (or no access).
    struct State: Equatable {
        var modeIdentifier: String
        var name: String
        var symbol: String
        var tint: String
    }

    @Published private(set) var current: State?

    private static var dbDir: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/DoNotDisturb/DB", isDirectory: true)
    }
    private var assertionsURL: URL { Self.dbDir.appendingPathComponent("Assertions.json") }
    private var configsURL: URL { Self.dbDir.appendingPathComponent("ModeConfigurations.json") }

    private var pollTimer: Timer?
    private var dirSource: DispatchSourceFileSystemObject?
    private var lastSignature: String?
    private var warnedNoAccess = false
    var onUpdate: ((State) -> Void)?
    var onClear: (() -> Void)?

    /// True when the state files are actually readable (FDA granted).
    static var hasAccess: Bool {
        (try? Data(contentsOf: Self.dbDir.appendingPathComponent("ModeConfigurations.json"), options: .mappedIfSafe)) != nil
    }

    deinit { stop() }

    func start() {
        refresh()
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 10.0, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        // Directory watcher: fires on atomic rewrites too (unlike file FDs).
        dirSource?.cancel()
        let fd = open(Self.dbDir.path, O_EVTONLY)
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
        guard let state = readState() else {
            if current != nil || lastSignature != "empty" {
                current = nil
                lastSignature = "empty"
                onClear?()
            }
            return
        }
        let signature = "\(state.modeIdentifier)"
        if signature == lastSignature { return }
        lastSignature = signature
        current = state
        NSLog("[Alcove] focus: update %@ (%@)", state.name, state.modeIdentifier)
        onUpdate?(state)
    }

    private func readState() -> State? {
        guard
            let aData = try? Data(contentsOf: assertionsURL),
            let aJson = try? JSONSerialization.jsonObject(with: aData) as? [String: Any],
            let data = (aJson["data"] as? [[String: Any]])?.first
        else {
            if !warnedNoAccess {
                warnedNoAccess = true
                NSLog("[Alcove] focus: state unreadable (no Full Disk Access?) — manual modes only")
            }
            return nil
        }
        warnedNoAccess = false
        // Active = asserted but never invalidated.
        let asserted = (data["storeAssertionRecords"] as? [[String: Any]]) ?? []
        let invalidatedIDs = Set(
            ((data["storeInvalidationRecords"] as? [[String: Any]]) ?? []).compactMap { rec in
                (rec["invalidationAssertion"] as? [String: Any])?["assertionUUID"] as? String
            })
        guard let live = asserted.first(where: { ($0["assertionUUID"] as? String).map({ !invalidatedIDs.contains($0) }) ?? false }),
              let details = live["assertionDetails"] as? [String: Any],
              let modeID = details["assertionDetailsModeIdentifier"] as? String
        else { return nil } // nothing active
        let (name, symbol, tint) = Self.modeInfo(for: modeID)
        return State(modeIdentifier: modeID, name: name, symbol: symbol, tint: tint)
    }

    private static var configCache: [String: (String, String, String)] = [:]

    private static func modeInfo(for modeID: String) -> (name: String, symbol: String, tint: String) {
        if let cached = configCache[modeID] { return cached }
        var info = (shortName(modeID), "moon.fill", "systemIndigoColor")
        if let cData = try? Data(contentsOf: dbDir.appendingPathComponent("ModeConfigurations.json")),
           let cJson = try? JSONSerialization.jsonObject(with: cData) as? [String: Any],
           let data = (cJson["data"] as? [[String: Any]])?.first,
           let configs = (data["modeConfigurations"] as? [String: Any])?[modeID] as? [String: Any],
           let mode = configs["mode"] as? [String: Any] {
            let name = mode["name"] as? String ?? info.0
            // Prefer a usable SF symbol; custom descriptor/emoji falls through
            // to raw-text rendering in the view.
            let symbol = mode["symbolImageName"] as? String ?? info.1
            let tint = mode["tintColorName"] as? String ?? info.2
            info = (name, symbol, tint)
        }
        configCache[modeID] = info
        return info
    }

    private static func shortName(_ modeID: String) -> String {
        if modeID.contains("sleep") { return "Sleep" }
        if modeID.contains("work") { return "Work" }
        return "Focus"
    }

    /// SF Symbols only render known names; anything else (custom emoji)
    /// must be drawn as text.
    static func isSFSymbol(_ name: String) -> Bool {
        NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil
    }

    static func tintColor(for name: String) -> Color {
        switch name {
        case "systemPurpleColor": return .purple
        case "systemIndigoColor": return .indigo
        case "systemGreenColor": return .green
        case "systemRedColor": return .red
        case "systemMintColor": return .mint
        case "systemTealColor": return .teal
        case "systemBlueColor": return .blue
        case "systemOrangeColor": return .orange
        case "systemYellowColor": return .yellow
        case "systemPinkColor": return .pink
        default: return .indigo
        }
    }
}
