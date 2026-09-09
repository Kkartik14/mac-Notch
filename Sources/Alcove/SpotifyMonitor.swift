import AppKit
import Combine
import Foundation

/// Now Playing via Spotify's scripting dictionary.
/// Same treatment as Music: Spotify exposes track/state over AppleScript
/// (MediaRemote reads are dead for our process). Notable quirks, all
/// handled defensively below:
/// - track `duration` is in MILLISECONDS, `player position` in seconds.
/// - artwork comes as a remote `artwork url`, downloaded async.
final class SpotifyMonitor: ObservableObject {
    @Published private(set) var current: NowPlayingActivity?

    private var pollTimer: Timer?
    private var lastSignature: String?
    private var pendingArtworkSignature: String?
    var onUpdate: ((NowPlayingActivity, NSImage?) -> Void)?
    var onClear: (() -> Void)?
    var onProgress: ((TimeInterval, TimeInterval, Bool) -> Void)?
    var onArtwork: ((Data) -> Void)?

    static var isSpotifyRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: "com.spotify.client").isEmpty
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
        guard Self.isSpotifyRunning else {
            if current != nil {
                current = nil
                lastSignature = "empty"
                onClear?()
            }
            return
        }
        let source = """
        tell application "Spotify"
          try
            set t to current track
            set dlm to character id 31
            return (name of t) & dlm & (artist of t) & dlm & (album of t) & dlm & (player state as string) & dlm & (player position as string) & dlm & (duration of t as string) & dlm & (artwork url of t as string)
          on error
            return "NOTRACK"
          end try
        end tell
        """
        guard let script = NSAppleScript(source: source) else { return }
        var error: NSDictionary?
        let result = script.executeAndReturnError(&error)
        if let error {
            NSLog("[Alcove] spotify: script error: %@", error)
            return
        }
        guard result.descriptorType != typeNull else { return }
        let text = result.stringValue ?? ""
        if text == "NOTRACK" || text.isEmpty {
            if current != nil || lastSignature != "empty" {
                current = nil
                lastSignature = "empty"
                onClear?()
            }
            return
        }
        let parts = text.components(separatedBy: "\u{1F}")
        guard parts.count >= 6 else {
            NSLog("[Alcove] spotify: malformed payload (%d parts)", parts.count)
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
        // Spotify reports track duration in ms, position in seconds.
        // Auto-detect in case a build ever changes units.
        var duration = TimeInterval(parts[5]) ?? 0
        if duration > 100_000 { duration /= 1000 }
        if duration > 0, elapsed > duration { duration = elapsed }
        let artURL = parts.count >= 7 ? parts[6] : ""

        let signature = "\(title)|\(artist)|\(album)|\(isPlaying ? 1 : 0)"
        if signature == lastSignature {
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

        let activity = NowPlayingActivity(
            title: title,
            artist: artist,
            album: album,
            appName: "Spotify",
            isPlaying: isPlaying,
            elapsed: elapsed,
            duration: duration,
            artworkData: nil
        )
        current = activity
        NSLog("[Alcove] spotify: update %@ - %@ (%@)", title, artist, isPlaying ? "playing" : "paused")
        onUpdate?(activity, nil)
        fetchArtwork(urlString: artURL, signature: signature)
    }

    private func fetchArtwork(urlString: String, signature: String) {
        guard !urlString.isEmpty, let url = URL(string: urlString),
              url.scheme?.hasPrefix("http") == true else { return }
        pendingArtworkSignature = signature
        URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
            guard let self, let data, !data.isEmpty,
                  self.lastSignature == signature,
                  self.pendingArtworkSignature == signature,
                  NSImage(data: data) != nil else { return }
            DispatchQueue.main.async {
                guard self.lastSignature == signature else { return }
                if var cur = self.current {
                    cur.artworkData = data
                    self.current = cur
                }
                self.onArtwork?(data)
            }
        }.resume()
    }

    private func command(_ verb: String) {
        guard Self.isSpotifyRunning else { return }
        NSLog("[Alcove] spotify: command %@", verb)
        let source = "tell application \"Spotify\" to \(verb)"
        var error: NSDictionary?
        NSAppleScript(source: source)?.executeAndReturnError(&error)
        if let error { NSLog("[Alcove] spotify: command error: %@", error) }
    }

    func playPause() {
        if Self.isSpotifyRunning { command("playpause") }
        else { MediaRemote.sendCommand(.togglePlayPause) }
    }
    func next() {
        if Self.isSpotifyRunning { command("next track") }
        else { MediaRemote.sendCommand(.nextTrack) }
    }
    func previous() {
        if Self.isSpotifyRunning { command("previous track") }
        else { MediaRemote.sendCommand(.previousTrack) }
    }

    /// Jump playback to `seconds`.
    func seek(to seconds: TimeInterval) {
        guard Self.isSpotifyRunning else { return }
        NSLog("[Alcove] spotify: seek %.1f", seconds)
        let source = "tell application \"Spotify\" to set player position to \(max(0, seconds))"
        var error: NSDictionary?
        NSAppleScript(source: source)?.executeAndReturnError(&error)
        if let error { NSLog("[Alcove] spotify: seek error: %@", error) }
        refresh()
    }
}
