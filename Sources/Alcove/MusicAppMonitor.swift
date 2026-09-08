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
    /// Must update the island silently — never expand.
    var onProgress: ((TimeInterval, TimeInterval, Bool) -> Void)?

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
            NSLog("[Alcove] music: script compile failed")
            return
        }
        var error: NSDictionary?
        let result = script.executeAndReturnError(&error)
        if let error {
            NSLog("[Alcove] music: script error: %@", error)
            return
        }
        guard result.descriptorType != typeNull else {
            NSLog("[Alcove] music: null result")
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
            NSLog("[Alcove] music: malformed payload (%d parts)", parts.count)
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
        NSLog("[Alcove] music: update %@ - %@ (%@)", title, artist, isPlaying ? "playing" : "paused")
        onUpdate?(activity, image)
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
            NSLog("[Alcove] music: command %@ ignored, Music not running", verb)
            return
        }
        NSLog("[Alcove] music: command %@", verb)
        let source = "tell application \"Music\" to \(verb)"
        var error: NSDictionary?
        NSAppleScript(source: source)?.executeAndReturnError(&error)
        if let error { NSLog("[Alcove] music: command error: %@", error) }
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
        NSLog("[Alcove] music: seek %.1f", clamped)
        let source = "tell application \"Music\" to set player position to \(clamped)"
        var error: NSDictionary?
        NSAppleScript(source: source)?.executeAndReturnError(&error)
        if let error { NSLog("[Alcove] music: seek error: %@", error) }
        // Refresh immediately so the island reflects the jump.
        refresh()
    }
}
