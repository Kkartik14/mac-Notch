import AppKit
import Combine
import Compression
import Foundation

/// Recently-played tracks, decoded from Music's own on-disk playback
/// session archives — zero permissions (the folder is user-readable).
///
/// `~/Library/Application Support/Music/PlaybackSessions/IT-*.playbackSessionArchive`
/// is an MPCQueueController checkpoint per playback context, rewritten on
/// every track change. `contentItem.protobuf.gz` embeds the current track
/// as a protobuf; `itemPayload.opackCoder.gz` (when present) carries the
/// item's Apple Music API JSON with a playable store ID. Verified live:
/// protobuf field 2 = title, field 4 = artist (album inside field 3).
final class PlaybackHistoryMonitor: ObservableObject {
    struct Track: Equatable {
        var title: String
        var artist: String
        var storeID: String?   // catalog ID from itemPayload JSON (`playParams.id`)
        /// Apple Music catalog URL from the API JSON (`https://music.apple.com/…`).
        /// Replay opens the music:// form, which routes inside the Music app.
        var url: String?
        /// Sized CDN thumb URL (64x64), from the archive's artwork reference.
        var artworkURL: String?
        /// Filled lazily once the thumb downloads; nil = show placeholder.
        var artworkData: Data?
        var date: Date

        var display: String { artist.isEmpty ? title : "\(artist) — \(title)" }

        /// music:// deep link that opens this track inside the Music app
        /// (verified: https:// forms open the browser instead).
        var musicAppURL: URL? {
            guard var s = url else { return nil }
            if s.hasPrefix("https://") { s = "music://" + s.dropFirst(8) }
            return URL(string: s)
        }
    }

    @Published private(set) var tracks: [Track] = []

    static var sessionsDir: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Music/PlaybackSessions", isDirectory: true)
    }

    private var dirSource: DispatchSourceFileSystemObject?
    private var pollTimer: Timer?
    /// Newest session dir each pass; dedupes watcher + timer overlap.
    private var lastProcessedNewest: String?
    /// Session key the queue was last resolved for (track changes rewrite).
    private var lastQueueKey: String?
    /// Titles|artists with a thumb download currently in flight.
    private var pendingArtwork = Set<String>()
    var onTracksChanged: (([Track]) -> Void)?
    /// True playlist-order queue + the context track title it belongs to
    /// (staleness gate — see applySessionQueue). Empty = nothing known.
    var onQueueChanged: (([UpNextItem], String) -> Void)?
    /// Loose title equality across sources (case, feats, punctuation).
    static func sameTrack(_ a: String, _ b: String) -> Bool {
        func norm(_ s: String) -> String {
            var t = s.lowercased()
            while let x = t.firstIndex(of: "("), let y = t[x...].firstIndex(of: ")"), y > x { t.removeSubrange(x...y) }
            while let x = t.firstIndex(of: "["), let y = t[x...].firstIndex(of: "]"), y > x { t.removeSubrange(x...y) }
            t = t.components(separatedBy: CharacterSet.alphanumerics.inverted).joined(separator: " ")
            return t.split(separator: " ").joined(separator: " ")
        }
        let na = norm(a), nb = norm(b)
        return !na.isEmpty && na == nb
    }

    deinit {
        pollTimer?.invalidate()
        dirSource?.cancel()
    }

    func start() {
        // Seed before the watcher: process first, then watch from a known state.
        scan(initial: true)
        let fd = open(Self.sessionsDir.path, O_EVTONLY)
        if fd >= 0 {
            let src = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: fd, eventMask: .write, queue: .main)
            src.setEventHandler { [weak self] in self?.scan() }
            src.setCancelHandler { close(fd) }
            src.resume()
            dirSource = src
        }
        // Backstop in case Music rewrites in place without dir events.
        pollTimer = Timer.scheduledTimer(withTimeInterval: 10.0, repeats: true) { [weak self] _ in
            self?.scan()
        }
    }

    func stop() {
        pollTimer?.invalidate()
        pollTimer = nil
        dirSource?.cancel()
        dirSource = nil
    }

    /// Newest-first scan of the archives. Music rewrites the newest session
    /// dir in place on every track change (name stays, mtime bumps), so the
    /// dedupe key is the newest dir's name + mtime, not just the name.
    func scan(initial: Bool = false) {
        let fm = FileManager.default
        let entries = (try? fm.contentsOfDirectory(atPath: Self.sessionsDir.path)) ?? []
        let dirs = entries.filter { $0.hasSuffix(".playbackSessionArchive") }
            .map { Self.sessionsDir.appendingPathComponent($0) }
            .sorted { a, b in
                let ma = (try? fm.attributesOfItem(atPath: a.path))?[.modificationDate] as? Date ?? .distantPast
                let mb = (try? fm.attributesOfItem(atPath: b.path))?[.modificationDate] as? Date ?? .distantPast
                return ma > mb
            }
        guard let newest = dirs.first else {
            NSLog("[Alcove] history: no sessions visible (entries=%d)", entries.count)
            return
        }
        let newestMtime = (try? fm.attributesOfItem(atPath: newest.path))?[.modificationDate] as? Date ?? .distantPast
        let key = "\(newest.lastPathComponent)|\(newestMtime.timeIntervalSince1970)"
        if key == lastProcessedNewest && !initial { return }
        lastProcessedNewest = key

        var tracks: [Track] = []
        var seen = Set<String>()
        for dir in dirs {
            if let t = Self.parseSession(dir), seen.insert(t.title + "|" + t.artist).inserted {
                tracks.append(t)
            }
            if tracks.count >= 8 { break }
        }
        if tracks.isEmpty {
            NSLog("[Alcove] history: %d sessions but 0 parsed", dirs.count)
        }
        // Queue resolution runs even when the track list is unchanged: the
        // newest session dir is often partial on first sight and completes
        // later, so a failed pass must retry (lastQueueKey pins only wins).
        resolveQueue(dirs: dirs, sessionKey: key)
        guard tracks != self.tracks else { return }
        self.tracks = tracks
        NSLog("[Alcove] history: %d recent tracks", tracks.count)
        onTracksChanged?(tracks)
        fetchMissingArtwork()
        resolveQueue(dirs: dirs, sessionKey: key)
    }

    /// Rail thumbs come from Apple's public CDN (no auth). One 64x64 jpg
    /// per track, fetched lazily; each landing re-announces so the view
    /// fills in progressively (same pattern as SpotifyMonitor artwork).
    private func fetchMissingArtwork() {
        for t in tracks where t.artworkData == nil {
            guard let urlStr = t.artworkURL, let url = URL(string: urlStr) else { continue }
            let key = t.title + "|" + t.artist
            guard !pendingArtwork.contains(key) else { continue }
            pendingArtwork.insert(key)
            URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
                guard let self,
                      let data, !data.isEmpty, NSImage(data: data) != nil else {
                    self?.pendingArtwork.remove(key)
                    return
                }
                DispatchQueue.main.async {
                    self.pendingArtwork.remove(key)
                    guard let idx = self.tracks.firstIndex(where: {
                        $0.title == t.title && $0.artist == t.artist
                    }) else { return }
                    self.tracks[idx].artworkData = data
                    self.onTracksChanged?(self.tracks)
                }
            }.resume()
        }
    }

    // MARK: - True queue (session order)

    /// Ordered store IDs from the queue-controller checkpoint + current ID
    /// from the item payload → next 3 via one batched lookup (public
    /// iTunes API, no auth) → titles, artists, thumbs. Silent, progressive
    /// (titles first, thumbs upgrade in place).
    private var lastAnnouncedQueue: [UpNextItem]?
    private var lastQueueContextTitle: String?
    /// Session key with a lookup currently in flight (no duplicate requests).
    private var resolvingKey: String?

    private func resolveQueue(dirs: [URL], sessionKey: String) {
        // lastQueueKey pins resolved wins; resolvingKey pins in-flight work.
        // Anything else retries on later scans — partial newest dirs fail
        // fast and complete later.
        guard sessionKey != lastQueueKey, sessionKey != resolvingKey else { return }
        // Newest dir is often a partial in-flight write (missing payloads);
        // walk back to the first complete, parseable session.
        var ctx: (String, [String])?
        var ctxDir: URL?
        for dir in dirs.prefix(5) {
            if let c = Self.queueContext(sessionDir: dir) { ctx = c; ctxDir = dir; break }
        }
        // The queue belongs to its own context track — carry the title so
        // the app can refuse stale queues (walk-back may land on an older
        // context than what's playing).
        let contextTitle = ctxDir.flatMap { Self.parseSession($0)?.title } ?? ""
        guard let (currentID, orderedIDs) = ctx,
              let at = orderedIDs.firstIndex(of: currentID) else {
            NSLog("[Alcove] queue: no position in session container")
            return
        }
        let next = Array(orderedIDs.dropFirst(at + 1).prefix(3))
        guard !next.isEmpty else {
            NSLog("[Alcove] queue: at container end")
            lastQueueKey = sessionKey
            onQueueChanged?([], contextTitle)
            return
        }
        var comps = URLComponents(string: "https://itunes.apple.com/lookup")
        comps?.queryItems = [
            URLQueryItem(name: "id", value: next.joined(separator: ",")),
            URLQueryItem(name: "entity", value: "song"),
        ]
        guard let url = comps?.url else { return }
        resolvingKey = sessionKey
        URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
            guard let self, let data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let results = json["results"] as? [[String: Any]] else {
                NSLog("[Alcove] queue: lookup failed")
                DispatchQueue.main.async { [weak self] in
                    if self?.resolvingKey == sessionKey { self?.resolvingKey = nil }
                }
                return
            }
            // Lookup may reorder; restore play order via requested IDs.
            var byID: [String: [String: Any]] = [:]
            for r in results {
                let sid: String?
                if let n = r["trackId"] as? Int { sid = String(n) }
                else { sid = r["trackId"] as? String }
                if let sid { byID[sid] = r }
            }
            let items: [UpNextItem] = next.compactMap { sid in
                guard let r = byID[sid],
                      let t = r["trackName"] as? String, !t.isEmpty else { return nil }
                let art = (r["artworkUrl100"] as? String)?
                    .replacingOccurrences(of: "100x100", with: "200x200")
                return UpNextItem(title: t, artist: (r["artistName"] as? String) ?? "", artworkURL: art, url: r["url"] as? String)
            }
            guard !items.isEmpty else {
                NSLog("[Alcove] queue: lookup empty")
                DispatchQueue.main.async { [weak self] in
                    if self?.resolvingKey == sessionKey { self?.resolvingKey = nil }
                }
                return
            }
            DispatchQueue.main.async { [weak self] in
                guard let self else {
                    return
                }
                if self.resolvingKey == sessionKey { self.resolvingKey = nil }
                guard self.lastQueueKey != sessionKey else { return }
                self.lastQueueKey = sessionKey
                NSLog("[Alcove] queue: %d tracks (session order): %@", items.count,
                      items.map { $0.title }.joined(separator: " | ") as NSString)
                self.lastAnnouncedQueue = items
                self.lastQueueContextTitle = contextTitle
                self.onQueueChanged?(items, contextTitle)
                self.fetchQueueThumbs(items, sessionKey: sessionKey)
            }
        }.resume()
    }

    /// Thumbnails for resolved queue items; re-announce per landing.
    private func fetchQueueThumbs(_ items: [UpNextItem], sessionKey: String) {
        for item in items {
            guard let str = item.artworkURL, let url = URL(string: str),
                  url.scheme?.hasPrefix("http") == true else { continue }
            let key = "q|" + item.title + "|" + item.artist
            guard !pendingArtwork.contains(key) else { continue }
            pendingArtwork.insert(key)
            URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
                guard let data, !data.isEmpty, NSImage(data: data) != nil else {
                    self?.pendingArtwork.remove(key)
                    return
                }
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.pendingArtwork.remove(key)
                    guard self.lastQueueKey == sessionKey,
                          var announced = self.lastAnnouncedQueue,
                          let idx = announced.firstIndex(where: { $0.title == item.title && $0.artist == item.artist }) else { return }
                    announced[idx].artData = data
                    self.lastAnnouncedQueue = announced
                    self.onQueueChanged?(announced, self.lastQueueContextTitle ?? "")
                }
            }.resume()
        }
    }

    /// Newest session's queue context: (current store ID, ordered queue IDs).
    /// Container = MPCQueueController checkpoint (`relationships.tracks`
    /// store IDs in play order); current ID from the item payload JSON.
    static func queueContext(sessionDir: URL) -> (String, [String])? {
        guard let payload = gunzip(url: sessionDir.appendingPathComponent("itemPayload.opackCoder.gz")),
              let json = extractFirstJSON(url: payload) as? [String: Any],
              let attrs = json["attributes"] as? [String: Any],
              let play = attrs["playParams"] as? [String: Any],
              let currentID = play["id"] as? String,
              let container = gunzip(url: sessionDir.appendingPathComponent("containerPayload.opackCoder.gz")),
              let cjson = extractFirstJSON(url: container) as? [String: Any],
              let rel = (cjson["relationships"] as? [String: Any])?["tracks"] as? [String: Any],
              let items = rel["data"] as? [[String: Any]] else { return nil }
        let ids = items.compactMap { $0["id"] as? String }
        guard !ids.isEmpty else { return nil }
        return (currentID, ids)
    }

    // MARK: - Decoding

    /// One session archive -> Track. Any failure returns nil (session is
    /// skipped, matching the codebase's soft-fail convention).
    static func parseSession(_ dir: URL) -> Track? {
        // 1) Store ID + catalog URL + artwork template from the API JSON.
        var storeID: String?
        var url: String?
        var artworkURL: String?
        if let payload = gunzip(url: dir.appendingPathComponent("itemPayload.opackCoder.gz")),
           let json = extractFirstJSON(url: payload) as? [String: Any],
           let attrs = json["attributes"] as? [String: Any] {
            if let play = attrs["playParams"] as? [String: Any] {
                storeID = play["id"] as? String
            }
            if let u = attrs["url"] as? String {
                url = u.replacingOccurrences(of: "\\/", with: "/")
            }
            if let art = attrs["artwork"] as? [String: Any],
               let u = art["url"] as? String {
                artworkURL = Self.sizedArtworkURL(u.replacingOccurrences(of: "\\/", with: "/"))
            }
        }
        // 2) Title/artist from the protobuf (always present); artwork URL
        //    fallback lives in there too (e.g. `.../800x800bb.jpg`).
        guard let proto = gunzip(url: dir.appendingPathComponent("contentItem.protobuf.gz")),
              let (title, artist) = parseProtobuf(url: proto)
        else { return nil }
        let finalArtworkURL = artworkURL ?? Self.findArtworkURL(in: proto)
        let fm = FileManager.default
        let mtime = (try? fm.attributesOfItem(atPath: dir.path))?[.modificationDate] as? Date
        return Track(title: title, artist: artist, storeID: storeID, url: url,
                     artworkURL: finalArtworkURL, date: mtime ?? Date.distantPast)
    }

    /// Normalize an Apple artwork URL to a small square thumb. Handles both
    /// shapes seen on disk: `{w}x{h}bb.jpg` templates (itemPayload JSON)
    /// and fixed-size variants like `800x800bb.jpg` (protobuf).
    static func sizedArtworkURL(_ raw: String, edge: Int = 64) -> String? {
        guard raw.contains("mzstatic.com") else { return nil }
        if let r = raw.range(of: #"\{w\}x\{h\}bb\.jpg"#, options: .regularExpression) {
            return raw.replacingCharacters(in: r, with: "\(edge)x\(edge)bb.jpg")
        }
        if let r = raw.range(of: #"/\d+x\d+bb\.jpg"#, options: .regularExpression) {
            return raw.replacingCharacters(in: r, with: "/\(edge)x\(edge)bb.jpg")
        }
        return raw.hasSuffix(".jpg") ? raw : nil
    }

    /// Scan the decoded protobuf for an artwork CDN URL. Anchored on
    /// Apple's `NdxNbb.jpg` size suffix — a lazy `.jpg` match would stop at
    /// incidental `.jpg` runs inside the path (e.g. `.rgb.jpg`).
    static func findArtworkURL(in data: Data) -> String? {
        let s = String(decoding: data, as: UTF8.self)
        guard let r = s.range(of: #"https://[!-~]+?/\d+x\d+bb\.jpg"#, options: .regularExpression) else { return nil }
        return sizedArtworkURL(String(s[r]))
    }

    /// The .gz files are plain gzip (verified FLG=0). Decode with the
    /// Compression framework: gzip payload = raw deflate, and Apple's
    /// COMPRESSION_ZLIB operates on exactly that (no headers, adler stripped).
    static func gunzip(url: URL) -> Data? {
        guard let raw = try? Data(contentsOf: url), raw.count > 18,
              raw.starts(with: [0x1f, 0x8b]) else { return nil }
        let body = raw.dropFirst(10).dropLast(8)
        let cap = 1 << 20 // payloads are KBs; cap is headroom
        var dst = [UInt8](repeating: 0, count: cap)
        let n = compression_decode_buffer(&dst, cap, Array(body), body.count, nil,
                                          compression_algorithm(rawValue: 0x205)) // COMPRESSION_ZLIB
        guard n > 0 else { return nil }
        return Data(dst.prefix(n))
    }

    /// Walk protobuf wire format. Verified live shape:
    /// top-level field 2 = nested content item -> f1 = title, f6 = album,
    /// f7 = artist (top-level f1 is the queue-window id). Artist is
    /// best-effort; title is required.
    static func parseProtobuf(url: Data) -> (String, String)? {
        let bytes = [UInt8](url)
        var idx = 0
        var item: Data?
        while idx < bytes.count {
            let key = readVarint(bytes, &idx) ?? 0
            let field = Int(key >> 3)
            let wire = Int(key & 0x7)
            switch wire {
            case 2:
                let len = Int(readVarint(bytes, &idx) ?? 0)
                guard idx + len <= bytes.count else { return nil }
                if field == 2 { item = Data(bytes[idx..<idx+len]) }
                idx += len
            case 0: _ = readVarint(bytes, &idx)
            case 5: idx += 4
            case 1: idx += 8
            default: return nil
            }
        }
        guard let d = item else { return nil }
        let inner = [UInt8](d)
        idx = 0
        var title: String?
        var artist: String?
        while idx < inner.count {
            let key = readVarint(inner, &idx) ?? 0
            let field = Int(key >> 3)
            let wire = Int(key & 0x7)
            switch wire {
            case 2:
                let len = Int(readVarint(inner, &idx) ?? 0)
                guard idx + len <= inner.count else { return nil }
                let chunk = Data(inner[idx..<idx+len])
                idx += len
                // Empty fields (len 0) are legal protobuf; skip capture.
                if field == 1 && len > 0 { title = String(data: chunk, encoding: .utf8) }
                if field == 7 && len > 0 { artist = String(data: chunk, encoding: .utf8) }
            case 0: _ = readVarint(inner, &idx)
            case 5: idx += 4
            case 1: idx += 8
            default: return nil
            }
        }
        guard let t = title, !t.isEmpty else { return nil }
        return (t, artist ?? "")
    }

    private static func readVarint(_ bytes: [UInt8], _ idx: inout Int) -> UInt64? {
        var value: UInt64 = 0
        var shift: UInt64 = 0
        while idx < bytes.count {
            let b = bytes[idx]
            idx += 1
            value |= UInt64(b & 0x7F) << shift
            if b & 0x80 == 0 { return value }
            shift += 7
            if shift > 63 { return nil }
        }
        return nil
    }

    /// Brace-match the first Apple Music API JSON object in a binary blob
    /// (the opackCoder frames prefix the payload with their own bytes).
    static func extractFirstJSON(url: Data) -> Any? {
        let s = String(decoding: url, as: UTF8.self)
        guard let start = s.range(of: "{\"id\":\"") else { return nil }
        let sub = s[start.lowerBound...]
        var depth = 0
        var inString = false
        var escaped = false
        for (off, ch) in sub.enumerated() {
            if escaped { escaped = false; continue }
            if ch == "\\" { escaped = true; continue }
            if ch == "\"" { inString.toggle(); continue }
            guard !inString else { continue }
            if ch == "{" { depth += 1 }
            if ch == "}" {
                depth -= 1
                if depth == 0 {
                    let jsonText = sub[sub.startIndex..<sub.index(sub.startIndex, offsetBy: off+1)]
                    return try? JSONSerialization.jsonObject(with: Data(jsonText.utf8))
                }
            }
        }
        return nil
    }
}
