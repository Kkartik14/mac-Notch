import AppKit
import Combine
import Foundation

/// Now Playing via the Music app's public scripting dictionary.
/// Direct MediaRemote reads return nil for our process on recent macOS
/// (verified live: `MRMediaRemoteGetNowPlayingInfo` -> nil while Music plays),
/// so for Apple Music we ask Music itself. Transport also goes through
/// scripting when Music is running, MediaRemote otherwise.
final class MusicAppMonitor: ObservableObject {
    @Published private(set) var current: NowPlayingActivity?

    private var pollTimer: Timer?
    private var lastSignature: String?
    private var lastArtworkSignature: String?
    private var lastArtworkData: Data?
    var onUpdate: ((NowPlayingActivity, NSImage?) -> Void)?
    var onClear: (() -> Void)?
    /// Fired on every poll for the same track (progress corrections).
    /// Must update the halo silently — never expand.
    var onProgress: ((TimeInterval, TimeInterval, Bool) -> Void)?
    /// Up Next queue, arriving after the card (playlist reads are slow).
    var onQueue: (([UpNextItem]) -> Void)?

    static var isMusicRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Music").isEmpty
    }

    deinit { stop() }

    func start() {
        refresh()
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    func stop() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    func refresh() {
        guard Self.isMusicRunning else {
            if current != nil {
                current = nil
                lastSignature = "empty"
                onClear?()
            }
            return
        }
        // Unit separator delimited: title artist album state position duration.
        // Built via `character id 31` so no raw control char lives in source.
        let source = """
        tell application "Music"
          try
            set t to current track
            set dlm to character id 31
            return (name of t) & dlm & (artist of t) & dlm & (album of t) & dlm & (player state as string) & dlm & (player position as string) & dlm & (duration of t as string)
          on error
            return "NOTRACK"
          end try
        end tell
        """
        guard let script = NSAppleScript(source: source) else {
            NSLog("[Halo] music: script compile failed")
            return
        }
        var error: NSDictionary?
        let result = script.executeAndReturnError(&error)
        if let error {
            NSLog("[Halo] music: script error: %@", error)
            return
        }
        guard result.descriptorType != typeNull else {
            NSLog("[Halo] music: null result")
            return
        }
        let text = result.stringValue ?? ""
        if text == "NOTRACK" || text.isEmpty {
            if current != nil || lastSignature != "empty" {
                current = nil
                lastArtworkData = nil
                lastArtworkSignature = nil
                lastSignature = "empty"
                onClear?()
            }
            return
        }
        let parts = text.components(separatedBy: "\u{1F}")
        guard parts.count >= 6 else {
            NSLog("[Halo] music: malformed payload (%d parts)", parts.count)
            return
        }
        let title = parts[0], artist = parts[1], album = parts[2]
        if title.isEmpty && artist.isEmpty {
            if current != nil {
                current = nil
                lastSignature = "empty"
                onClear?()
            }
            return
        }
        let isPlaying = parts[3] == "playing"
        let elapsed = TimeInterval(parts[4]) ?? 0
        let duration = TimeInterval(parts[5]) ?? 0

        let signature = "\(title)|\(artist)|\(album)|\(isPlaying ? 1 : 0)"
        if signature == lastSignature {
            // Same track: silently refresh progress without re-expanding.
            if var cur = current {
                cur.elapsed = elapsed
                cur.duration = duration
                cur.isPlaying = isPlaying
                current = cur
            }
            onProgress?(elapsed, duration, isPlaying)
            return
        }
        lastSignature = signature

        // Artwork only on track change — the bytes are large (~100KB+).
        var artworkData: Data?
        var image: NSImage?
        if lastArtworkSignature != signature {
            let fetched = fetchArtwork()
            if let fetched, !fetched.isEmpty, NSImage(data: fetched) != nil {
                artworkData = fetched
                image = NSImage(data: fetched)
                lastArtworkSignature = signature
                lastArtworkData = fetched
            }
        } else {
            artworkData = lastArtworkData
            if let artworkData { image = NSImage(data: artworkData) }
        }

        let activity = NowPlayingActivity(
            title: title,
            artist: artist,
            album: album,
            appName: "Music",
            isPlaying: isPlaying,
            elapsed: elapsed,
            duration: duration,
            artworkData: artworkData
        )
        current = activity
        NSLog("[Halo] music: update %@ - %@ (%@)", title, artist, isPlaying ? "playing" : "paused")
        onUpdate?(activity, image)
        fetchUpNext()
    }

    /// Up Next: the tracks immediately after the current one. Bounded reads
    /// only (`index of current track` + 3 neighbor reads, ~0.2s) — no
    /// playlist enumeration, so library size is irrelevant.
    ///
    /// Tiers, each verified before use (the index spaces are NOT the same:
    /// `index of current track` can point at an unreadable play queue):
    /// 1. `current playlist` — works when playing from a real playlist.
    /// 2. `library playlist 1` — when playing from the Library.
    ///    (`current playlist` fails with -1728 there.)
    /// 3. Give up with NOQUEUE — playing from the Apple Music catalog has
    ///    no scripting-visible container at all.
    /// Runs on the main thread like every other script here
    /// (NSAppleScript is main-thread-only); the bounded cost makes that
    /// acceptable on a track change.
    private func fetchUpNext() {
        let signature = lastSignature
        let source = """
        tell application "Music"
          try
            set fsep to character id 31
            set rsep to character id 30
            set curID to (database ID of current track) as string
            set i to index of current track
            set v to missing value
            try
              set v to current playlist
              if (database ID of track i of v) as string is not curID then set v to missing value
            end try
            if v is missing value then
              try
                set v to library playlist 1
                if (database ID of track i of v) as string is not curID then set v to missing value
              end try
            end if
            if v is missing value then return "NOQUEUE"
            set out to (persistent ID of v) & rsep
            repeat with j from (i + 1) to (i + 3)
              try
                set t to track j of v
                set out to out & (j as string) & fsep & (database ID of t as string) & fsep & (name of t) & fsep & (artist of t) & rsep
              end try
            end repeat
            return out
          on error
            return "NOQUEUE"
          end try
        end tell
        """
        DispatchQueue.main.async { [weak self] in
            guard let self, self.lastSignature == signature else { return }
            guard let script = NSAppleScript(source: source) else { return }
            var error: NSDictionary?
            let result = script.executeAndReturnError(&error)
            guard error == nil, result.descriptorType != typeNull else {
                NSLog("[Halo] music: up-next script failed")
                return
            }
            let text = result.stringValue ?? ""
            guard !text.isEmpty, text != "NOQUEUE" else {
                // Catalog context (radio, search, curated mixes): no
                // scripting-visible container. The session-queue resolver
                // (PlaybackHistoryMonitor) owns these now — album-order
                // guessing showed wrong songs for playlist mixes, so the
                // store fallback is deleted, not demoted.
                NSLog("[Halo] music: up-next unavailable via scripting (catalog context)")
                return
            }
            let (playlistID, items) = Self.parseUpNext(text)
            guard !items.isEmpty else { return }
            if var cur = self.current {
                cur.upNext = items
                self.current = cur
            }
            NSLog("[Halo] music: up-next %d tracks (playlist %@)", items.count, playlistID ?? "-")
            self.onQueue?(items)
        }
    }

    /// Pure decode of the up-next payload: header record is the playlist
    /// persistent ID, then `index<31>dbid<31>title<31>artist<30>` records.
    /// Separated for unit testing, like NotificationMonitor.parse.
    /// Returns (playlistID, items).
    static func parseUpNext(_ text: String) -> (String?, [UpNextItem]) {
        let recs = text.components(separatedBy: "\u{1E}").filter { !$0.isEmpty }
        guard recs.count >= 1 else { return (nil, []) }
        // Header: bare persistent ID (no separators) vs first record check.
        var playlistID: String?
        var rest = recs
        if !recs[0].contains("\u{1F}") {
            playlistID = recs[0].isEmpty ? nil : recs[0]
            rest = Array(recs.dropFirst())
        }
        let items: [UpNextItem] = rest.compactMap { rec in
            let f = rec.components(separatedBy: "\u{1F}")
            guard f.count >= 4, let idx = Int(f[0]), !f[2].isEmpty else { return nil }
            return UpNextItem(title: f[2], artist: f[3], playlistID: playlistID, trackIndex: idx)
        }
        return (playlistID, items)
    }

    private func fetchArtwork() -> Data? {
        let source = """
        tell application "Music"
          try
            return data of artwork 1 of current track
          on error
            return ""
          end try
        end tell
        """
        guard let script = NSAppleScript(source: source) else { return nil }
        var error: NSDictionary?
        let result = script.executeAndReturnError(&error)
        guard error == nil else { return nil }
        // Raw picture data comes back as a data descriptor.
        let data = result.data
        guard !data.isEmpty else { return nil }
        return data
    }

    private func command(_ verb: String) {
        guard Self.isMusicRunning else {
            NSLog("[Halo] music: command %@ ignored, Music not running", verb)
            return
        }
        NSLog("[Halo] music: command %@", verb)
        let source = "tell application \"Music\" to \(verb)"
        var error: NSDictionary?
        NSAppleScript(source: source)?.executeAndReturnError(&error)
        if let error { NSLog("[Halo] music: command error: %@", error) }
    }

    func playPause() {
        if Self.isMusicRunning { command("playpause") }
        else { MediaRemote.sendCommand(.togglePlayPause) }
    }
    func next() {
        if Self.isMusicRunning { command("next track") }
        else { MediaRemote.sendCommand(.nextTrack) }
    }
    func previous() {
        if Self.isMusicRunning { command("previous track") }
        else { MediaRemote.sendCommand(.previousTrack) }
    }

    /// Jump playback to `seconds`. Music clamps out-of-range values itself.
    func seek(to seconds: TimeInterval) {
        guard Self.isMusicRunning else { return }
        let clamped = max(0, seconds)
        NSLog("[Halo] music: seek %.1f", clamped)
        let source = "tell application \"Music\" to set player position to \(clamped)"
        var error: NSDictionary?
        NSAppleScript(source: source)?.executeAndReturnError(&error)
        if let error { NSLog("[Halo] music: seek error: %@", error) }
        // Refresh immediately so the halo reflects the jump.
        refresh()
    }
}
