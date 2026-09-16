import Foundation
import AppKit
import Combine

/// Real Now Playing monitor using the private MediaRemote framework.
/// Subscribes to playback notifications and fetches title/artist/album/artwork
/// from the system Now Playing client.
final class NowPlayingMonitor: ObservableObject {
    @Published private(set) var current: NowPlayingActivity?
    @Published private(set) var artwork: NSImage?

    private var pollTimer: Timer?
    private var lastSignature: String?
    /// Cache for bundleID -> display name. The lookup hits disk
    /// (NSWorkspace + Bundle) so it must not run on every 4s poll.
    private var displayNameCache: [String: String] = [:]
    var onUpdate: ((NowPlayingActivity, NSImage?) -> Void)?
    var onClear: (() -> Void)?

    deinit { stop() }

    func start() {
        MediaRemote.registerForNotifications(DispatchQueue.main) { [weak self] in
            self?.refresh()
        }
        refresh()
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 4.0, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    func stop() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    func refresh() {
        MediaRemote.getNowPlayingInfo(DispatchQueue.main) { [weak self] info in
            let dict = info as? [String: Any] ?? [:]
            self?.handle(info: dict)
        }
    }

    private func handle(info: [String: Any]) {
        let title = info["kMRMediaRemoteNowPlayingInfoTitle"] as? String ?? ""
        let artist = info["kMRMediaRemoteNowPlayingInfoArtist"] as? String ?? ""
        let album = info["kMRMediaRemoteNowPlayingInfoAlbum"] as? String ?? ""
        let rate = info["kMRMediaRemoteNowPlayingInfoPlaybackRate"] as? Double ?? 0
        let elapsed = info["kMRMediaRemoteNowPlayingInfoElapsedTime"] as? TimeInterval ?? 0
        let duration = info["kMRMediaRemoteNowPlayingInfoDuration"] as? TimeInterval ?? 0
        let bundleID = info["kMRMediaRemoteNowPlayingInfoClientIdentifier"] as? String
            ?? info["kMRMediaRemoteNowPlayingInfoApplicationIdentifier"] as? String

        if title.isEmpty && artist.isEmpty {
            current = nil
            artwork = nil
            lastSignature = "empty"
            onClear?()
            return
        }

        // Decode artwork once, store the bytes in the activity so the view
        // can render it. Previously artworkData was always nil, so the UI
        // always fell back to the placeholder gradient.
        var artworkData: Data?
        var image: NSImage? = nil
        if let data = info["kMRMediaRemoteNowPlayingInfoArtworkData"] as? Data {
            artworkData = data
            image = NSImage(data: data)
        } else if let data = info["kMRMediaRemoteNowPlayingInfoArtworkData"] as? NSData {
            artworkData = data as Data
            image = NSImage(data: artworkData!)
        }

        let signature = "\(title)|\(artist)|\(album)|\(rate > 0 ? 1 : 0)"
        if signature == lastSignature {
            // Same track: silently refresh progress/playing state without
            // firing onUpdate (which would re-expand/hijack the halo).
            if var cur = current {
                cur.elapsed = elapsed
                cur.duration = duration
                cur.isPlaying = rate > 0
                // Update artwork only if it newly appeared.
                if cur.artworkData == nil, let artworkData {
                    cur.artworkData = artworkData
                    artwork = image
                }
                current = cur
            }
            return
        }
        lastSignature = signature

        let activity = NowPlayingActivity(
            title: title,
            artist: artist,
            album: album,
            appName: displayName(for: bundleID),
            isPlaying: rate > 0,
            elapsed: elapsed,
            duration: duration,
            artworkData: artworkData
        )
        current = activity
        artwork = image
        onUpdate?(activity, image)
    }

    private func displayName(for bundleID: String?) -> String {
        switch bundleID {
        case "com.apple.Music": return "Music"
        case "com.spotify.client": return "Spotify"
        case "com.apple.iTunes": return "iTunes"
        case "com.apple.podcasts": return "Podcasts"
        case let id? where !id.isEmpty:
            if let cached = displayNameCache[id] { return cached }
            let name = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id)
                .flatMap { Bundle(url: $0)?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String }
                ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: id)
                    .flatMap { Bundle(url: $0)?.object(forInfoDictionaryKey: "CFBundleName") as? String }
                ?? id
            displayNameCache[id] = name
            return name
        default: return "Now Playing"
        }
    }

    func playPause() { MediaRemote.sendCommand(.togglePlayPause) }
    func next() { MediaRemote.sendCommand(.nextTrack) }
    func previous() { MediaRemote.sendCommand(.previousTrack) }
}