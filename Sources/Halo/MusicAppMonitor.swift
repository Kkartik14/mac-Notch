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
    private var workspaceObservers: [NSObjectProtocol] = []
    private var probeWorkItems: [DispatchWorkItem] = []
    private var probeGeneration = 0
    private var isSleeping = false
    private var consecutiveRefreshFailures = 0
    private var lastTrackSignature: String?
    private var lastPlaybackState: Bool?
    private var lastArtworkSignature: String?
    private var lastArtworkData: Data?
    private var currentTrackScript: NSAppleScript?
    private var didLogScriptCompileFailure = false
    private var queueArtworkWorkItems: [DispatchWorkItem] = []
    private var queueArtworkGeneration = 0
    var onUpdate: ((NowPlayingActivity, NSImage?) -> Void)?
    var onClear: (() -> Void)?
    /// Fired on every poll for the same track (progress corrections).
    /// Must update the halo silently — never expand.
    var onProgress: ((TimeInterval, TimeInterval, Bool) -> Void)?
    /// Up Next queue, arriving after the card (playlist reads are slow).
    var onQueue: (([UpNextItem]) -> Void)?

    private static let playingPollInterval: TimeInterval = 1.0
    private static let pausedPollInterval: TimeInterval = 3.0
    private static let inactivePollInterval: TimeInterval = 15.0
    private static let actionProbeDelays: [TimeInterval] = [0.10, 0.35, 0.80]

    static var isMusicRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Music").isEmpty
    }

    deinit { stop() }

    func start() {
        stop()
        isSleeping = false
        installWorkspaceObservers()
        refresh()
    }

    func stop() {
        pollTimer?.invalidate()
        pollTimer = nil
        cancelProbeBurst()
        cancelQueueArtwork()
        isSleeping = true
        let notificationCenter = NSWorkspace.shared.notificationCenter
        workspaceObservers.forEach { notificationCenter.removeObserver($0) }
        workspaceObservers.removeAll()
    }

    func refresh() {
        guard !isSleeping else { return }
        guard Self.isMusicRunning else {
            clearCurrentIfNeeded()
            consecutiveRefreshFailures = 0
            scheduleNormalPoll()
            return
        }

        guard let script = currentTrackAppleScript() else {
            scheduleRetry()
            return
        }

        var error: NSDictionary?
        let result = script.executeAndReturnError(&error)
        if let error {
            NSLog("[Halo] music: script error: %@", error)
            scheduleRetry()
            return
        }
        guard result.descriptorType != typeNull else {
            NSLog("[Halo] music: null result")
            scheduleRetry()
            return
        }
        let text = result.stringValue ?? ""
        if text == "NOTRACK" || text.isEmpty {
            clearCurrentIfNeeded()
            consecutiveRefreshFailures = 0
            scheduleNormalPoll()
            return
        }
        let parts = text.components(separatedBy: "\u{1F}")
        guard parts.count >= 6 else {
            NSLog("[Halo] music: malformed payload (%d parts)", parts.count)
            scheduleRetry()
            return
        }
        let title = parts[0], artist = parts[1], album = parts[2]
        if title.isEmpty && artist.isEmpty {
            clearCurrentIfNeeded()
            consecutiveRefreshFailures = 0
            scheduleNormalPoll()
            return
        }
        let isPlaying = parts[3] == "playing"
        let elapsed = TimeInterval(parts[4]) ?? 0
        let duration = TimeInterval(parts[5]) ?? 0

        consecutiveRefreshFailures = 0
        let trackSignature = "\(title)|\(artist)|\(album)"
        if trackSignature == lastTrackSignature {
            // A pause/resume is a playback-state change, not a new track.
            // Keep it silent so the card does not expand or rebuild Up Next.
            let playbackStateChanged = lastPlaybackState != isPlaying
            lastPlaybackState = isPlaying
            if var cur = current {
                cur.elapsed = elapsed
                cur.duration = duration
                cur.isPlaying = isPlaying
                current = cur
            }
            onProgress?(elapsed, duration, isPlaying)
            if playbackStateChanged { cancelProbeBurst() }
            scheduleNormalPoll()
            return
        }
        lastTrackSignature = trackSignature
        lastPlaybackState = isPlaying
        cancelProbeBurst()
        cancelQueueArtwork()

        // Artwork only on track change — the bytes are large (~100KB+).
        var artworkData: Data?
        var image: NSImage?
        if lastArtworkSignature != trackSignature {
            let fetched = fetchArtwork()
            if let fetched, !fetched.isEmpty, NSImage(data: fetched) != nil {
                artworkData = fetched
                image = NSImage(data: fetched)
                lastArtworkSignature = trackSignature
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
        scheduleNormalPoll()
    }

    /// Re-probe quickly after an action that should change Music's state.
    /// The normal adaptive poll resumes after the short burst.
    func refreshAfterUserAction() {
        scheduleProbeBurst()
    }

    private func clearCurrentIfNeeded() {
        let hadCurrent = current != nil
        let needsReset = hadCurrent
            || lastTrackSignature != "empty"
            || lastPlaybackState != nil
            || lastArtworkData != nil
            || lastArtworkSignature != nil
        guard needsReset else { return }
        cancelQueueArtwork()
        current = nil
        lastTrackSignature = "empty"
        lastPlaybackState = nil
        lastArtworkData = nil
        lastArtworkSignature = nil
        if hadCurrent {
            onClear?()
        }
    }

    private func currentTrackAppleScript() -> NSAppleScript? {
        if let currentTrackScript { return currentTrackScript }
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
            if !didLogScriptCompileFailure {
                NSLog("[Halo] music: script compile failed")
                didLogScriptCompileFailure = true
            }
            return nil
        }
        currentTrackScript = script
        return script
    }

    private func scheduleNormalPoll() {
        let interval: TimeInterval
        if !Self.isMusicRunning {
            interval = Self.inactivePollInterval
        } else if current?.isPlaying == true {
            interval = Self.playingPollInterval
        } else {
            interval = Self.pausedPollInterval
        }
        schedulePoll(after: interval)
    }

    private func scheduleRetry() {
        consecutiveRefreshFailures = min(consecutiveRefreshFailures + 1, 4)
        let delay = min(Self.inactivePollInterval, pow(2.0, Double(consecutiveRefreshFailures - 1)))
        schedulePoll(after: delay)
    }

    private func schedulePoll(after interval: TimeInterval) {
        pollTimer?.invalidate()
        pollTimer = nil
        guard !isSleeping else { return }
        pollTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
            guard let self else { return }
            self.pollTimer = nil
            self.refresh()
        }
    }

    private func scheduleProbeBurst(delays requestedDelays: [TimeInterval]? = nil) {
        guard !isSleeping else { return }
        cancelProbeBurst()
        pollTimer?.invalidate()
        pollTimer = nil
        let generation = probeGeneration
        let delays = requestedDelays ?? Self.actionProbeDelays
        probeWorkItems = delays.map { delay in
            let work = DispatchWorkItem { [weak self] in
                guard let self,
                      !self.isSleeping,
                      self.probeGeneration == generation else { return }
                self.refresh()
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
            return work
        }
    }

    private func cancelProbeBurst() {
        probeGeneration &+= 1
        probeWorkItems.forEach { $0.cancel() }
        probeWorkItems.removeAll()
    }

    private enum WorkspaceEvent {
        case launched
        case terminated
        case activated
    }

    private func installWorkspaceObservers() {
        let notificationCenter = NSWorkspace.shared.notificationCenter
        let appEvents: [(Notification.Name, WorkspaceEvent)] = [
            (NSWorkspace.didLaunchApplicationNotification, .launched),
            (NSWorkspace.didTerminateApplicationNotification, .terminated),
            (NSWorkspace.didActivateApplicationNotification, .activated),
        ]
        for (name, event) in appEvents {
            let observer = notificationCenter.addObserver(
                forName: name,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                self?.handleWorkspaceEvent(event, notification: notification)
            }
            workspaceObservers.append(observer)
        }
        let sleepObserver = notificationCenter.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.handleSystemSleep()
        }
        workspaceObservers.append(sleepObserver)

        let wakeNames: [Notification.Name] = [
            NSWorkspace.didWakeNotification,
            NSWorkspace.sessionDidBecomeActiveNotification,
        ]
        for name in wakeNames {
            let observer = notificationCenter.addObserver(
                forName: name,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.handleSystemWake()
            }
            workspaceObservers.append(observer)
        }
    }

    private func handleWorkspaceEvent(_ event: WorkspaceEvent, notification: Notification) {
        guard let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              application.bundleIdentifier == "com.apple.Music" else { return }
        switch event {
        case .launched, .activated:
            scheduleProbeBurst()
        case .terminated:
            cancelProbeBurst()
            refresh()
        }
    }

    private func handleSystemSleep() {
        isSleeping = true
        pollTimer?.invalidate()
        pollTimer = nil
        cancelProbeBurst()
        cancelQueueArtwork()
    }

    private func handleSystemWake() {
        isSleeping = false
        scheduleProbeBurst()
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
        let signature = lastTrackSignature
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
            guard let self, self.lastTrackSignature == signature else { return }
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
            if let playlistID {
                self.fetchQueueArtwork(items: items, playlistID: playlistID, signature: signature)
            }
        }
    }

    /// Playlist rows do not expose a CDN artwork URL through Music's scripting
    /// dictionary. Deliver the titles immediately, then fetch each embedded
    /// artwork payload separately so the queue never delays the card.
    private func fetchQueueArtwork(items: [UpNextItem], playlistID: String, signature: String?) {
        cancelQueueArtwork()
        let generation = queueArtworkGeneration
        for (offset, item) in items.enumerated() {
            guard let trackIndex = item.trackIndex else { continue }
            let work = DispatchWorkItem { [weak self] in
                guard let self,
                      self.queueArtworkGeneration == generation,
                      self.lastTrackSignature == signature,
                      let data = self.fetchQueueArtwork(for: playlistID, trackIndex: trackIndex),
                      !data.isEmpty,
                      NSImage(data: data) != nil else { return }
                self.applyQueueArtwork(
                    data,
                    playlistID: playlistID,
                    trackIndex: trackIndex,
                    signature: signature,
                    generation: generation
                )
            }
            queueArtworkWorkItems.append(work)
            // Let SwiftUI render the text/placeholder row before the first
            // synchronous AppleScript artwork read reaches the main thread.
            let delay = 0.05 + (Double(offset) * 0.05)
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
        }
    }

    private func fetchQueueArtwork(for playlistID: String, trackIndex: Int) -> Data? {
        let escapedID = playlistID
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let source = """
        tell application "Music"
          try
            return data of artwork 1 of track \(trackIndex) of (first playlist whose persistent ID is "\(escapedID)")
          on error
            return ""
          end try
        end tell
        """
        guard let script = NSAppleScript(source: source) else { return nil }
        var error: NSDictionary?
        let result = script.executeAndReturnError(&error)
        guard error == nil, result.descriptorType != typeNull else { return nil }
        let data = result.data
        return data.isEmpty ? nil : data
    }

    private func applyQueueArtwork(
        _ data: Data,
        playlistID: String,
        trackIndex: Int,
        signature: String?,
        generation: Int
    ) {
        guard queueArtworkGeneration == generation,
              lastTrackSignature == signature,
              var cur = current,
              let index = cur.upNext.firstIndex(where: {
                  $0.playlistID == playlistID && $0.trackIndex == trackIndex
              }) else { return }
        guard cur.upNext[index].artData != data else { return }
        cur.upNext[index].artData = data
        current = cur
        onQueue?(cur.upNext)
    }

    private func cancelQueueArtwork() {
        queueArtworkGeneration &+= 1
        queueArtworkWorkItems.forEach { $0.cancel() }
        queueArtworkWorkItems.removeAll()
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
        if Self.isMusicRunning {
            command("playpause")
            scheduleProbeBurst()
        }
        else { MediaRemote.sendCommand(.togglePlayPause) }
    }
    func next() {
        if Self.isMusicRunning {
            command("next track")
            scheduleProbeBurst()
        }
        else { MediaRemote.sendCommand(.nextTrack) }
    }
    func previous() {
        if Self.isMusicRunning {
            command("previous track")
            scheduleProbeBurst()
        }
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
        scheduleProbeBurst(delays: [0.15, 0.50])
    }
}
