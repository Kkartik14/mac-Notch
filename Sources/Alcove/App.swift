import AppKit
import SwiftUI
import Combine

@main
struct AlcoveApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            SettingsRootView()
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let island = IslandWindowController()
    private let nowPlayingMonitor = NowPlayingMonitor()
    private let musicMonitor = MusicAppMonitor()
    private let spotifyMonitor = SpotifyMonitor()
    private let batteryMonitor = BatteryMonitor()
    private let weatherMonitor = WeatherMonitor()
    private let focusMonitor = FocusMonitor()
    private var wasPluggedIn = false

    /// Transport routing: the player that is currently playing owns the
    /// keys. Otherwise prefer Spotify, then Music, then system MediaRemote.
    private var spotifyPlaying: Bool { spotifyMonitor.current?.isPlaying == true }
    private var musicPlaying: Bool { musicMonitor.current?.isPlaying == true }
    private func routePlayPause() {
        if spotifyPlaying || (!musicPlaying && SpotifyMonitor.isSpotifyRunning) { spotifyMonitor.playPause() }
        else { musicMonitor.playPause() }
    }
    private func routeNext() {
        if spotifyPlaying || (!musicPlaying && SpotifyMonitor.isSpotifyRunning) { spotifyMonitor.next() }
        else { musicMonitor.next() }
    }
    private func routePrev() {
        if spotifyPlaying || (!musicPlaying && SpotifyMonitor.isSpotifyRunning) { spotifyMonitor.previous() }
        else { musicMonitor.previous() }
    }
    private func routeSeek(_ seconds: TimeInterval) {
        // Seek belongs to the card on screen.
        if case .nowPlaying(let n) = island.center.islands.first(where: { $0.id == "nowPlaying" }) {
            if n.appName == "Spotify" { spotifyMonitor.seek(to: seconds); return }
        }
        musicMonitor.seek(to: seconds)
    }
    /// After one source goes quiet: keep whichever source still has a
    /// playing track (quietly), else drop the card.
    private func resolveNowPlayingAfterClear() {
        if spotifyPlaying, let cur = spotifyMonitor.current {
            island.show(.nowPlaying(cur), autoDismissAfter: nil, expand: false)
        } else if musicPlaying, let cur = musicMonitor.current {
            island.show(.nowPlaying(cur), autoDismissAfter: nil, expand: false)
        } else {
            island.center.dismiss("nowPlaying")
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        // No menu-bar icon: the island is the entire UI. All actions live on
        // its right-click menu instead.
        island.actions = IslandActions(
            showTimer: { [weak self] in self?.showTimer() },
            showNowPlaying: { [weak self] in self?.showNowPlaying() },
            showCharging: { [weak self] in self?.showCharging() },
            showNotification: { [weak self] in self?.showNotification() },
            showWeather: { [weak self] in self?.showWeather() },
            showFocus: { [weak self] in self?.showFocus() },
            previewPillMusic: { [weak self] in self?.previewPill("nowPlaying") },
            previewPillWeather: { [weak self] in self?.previewPill("weather") },
            previewPillCharging: { [weak self] in self?.previewPill("charging") },
            previewPillTimer: { [weak self] in self?.previewPill("timer") },
            previewPillNotify: { [weak self] in self?.previewPill("notification") },
            previewPillFocus: { [weak self] in self?.previewPill("focus") },
            expandTop: { [weak self] in self?.island.expandTop() },
            dismissAll: { [weak self] in self?.island.dismissAll() },
            openSettings: { [weak self] in self?.openSettings() },
            quit: { NSApplication.shared.terminate(nil) }
        )
        island.install(contextMenu: makeContextMenu())
        startMonitors()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    private func startMonitors() {
        // Media keys + seek: routed to whichever player owns playback.
        island.center.onPlayPause = { [weak self] in self?.routePlayPause() }
        island.center.onNextTrack = { [weak self] in self?.routeNext() }
        island.center.onPreviousTrack = { [weak self] in self?.routePrev() }
        island.center.onSeek = { [weak self] in self?.routeSeek($0) }

        // Now Playing — track changes pop the card open and it STAYS open
        // until dismissed. No auto-collapse: collapsing on its own is what
        // forced the expand/dismiss tap loop.
        nowPlayingMonitor.onUpdate = { [weak self] activity, _ in
            guard !MusicAppMonitor.isMusicRunning else { return }
            self?.island.show(.nowPlaying(activity), autoDismissAfter: nil, expand: true, collapseAfter: 3)
        }
        nowPlayingMonitor.onClear = { [weak self] in
            guard !MusicAppMonitor.isMusicRunning else { return }
            self?.island.center.dismiss("nowPlaying")
        }
        nowPlayingMonitor.start()

        // Apple Music via scripting — the reliable source on recent macOS.
        musicMonitor.onUpdate = { [weak self] activity, _ in
            self?.island.show(.nowPlaying(activity), autoDismissAfter: nil, expand: true, collapseAfter: 3)
        }
        musicMonitor.onClear = { [weak self] in
            self?.resolveNowPlayingAfterClear()
        }
        musicMonitor.onProgress = { [weak self] elapsed, duration, isPlaying in
            self?.island.center.updateNowPlayingProgress(elapsed: elapsed, duration: duration, isPlaying: isPlaying)
        }
        musicMonitor.start()

        // Spotify via scripting — same treatment. Playing source wins the card.
        spotifyMonitor.onUpdate = { [weak self] activity, _ in
            self?.island.show(.nowPlaying(activity), autoDismissAfter: nil, expand: true, collapseAfter: 3)
        }
        spotifyMonitor.onClear = { [weak self] in
            self?.resolveNowPlayingAfterClear()
        }
        spotifyMonitor.onProgress = { [weak self] elapsed, duration, isPlaying in
            self?.island.center.updateNowPlayingProgress(elapsed: elapsed, duration: duration, isPlaying: isPlaying)
        }
        spotifyMonitor.onArtwork = { [weak self] data in
            self?.island.center.updateNowPlayingArtwork(data)
        }
        spotifyMonitor.start()

        // Battery — fresh plug jumps to the top for 2s (card pops, then
        // priority order returns), unplug clears it. Level changes while
        // plugged update quietly in rank position.
        batteryMonitor.start { [weak self] charge in
            guard let self else { return }
            self.island.center.updateBatteryLevel(charge.level)
            if charge.pluggedIn {
                let isNewPlug = !self.wasPluggedIn
                self.wasPluggedIn = true
                self.island.show(
                    .charging(ChargingActivity(
                        level: charge.level,
                        isPluggedIn: true,
                        timeRemainingText: BatteryMonitor.etaText(minutes: charge.minutesRemaining)
                    )),
                    autoDismissAfter: nil,
                    expand: isNewPlug,
                    collapseAfter: isNewPlug ? 2 : nil
                )
                if isNewPlug {
                    self.island.center.moveToTop("charging")
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                        self?.island.center.applyPriorityOrder()
                    }
                }
            } else {
                self.wasPluggedIn = false
                self.island.center.dismiss("charging")
            }
        }

        // Weather — quiet pill, refreshes every 10 min. Never force-expands.
        weatherMonitor.start { [weak self] activity in
            self?.island.show(.weather(activity), autoDismissAfter: nil, expand: false)
        }

        // Focus — live system mode via disk adapter (silent without FDA).
        // Pops once on activation, settles; turning it off clears the card.
        focusMonitor.onUpdate = { [weak self] state in
            self?.island.show(.focus(FocusActivity(mode: state.name, symbol: state.symbol)),
                              autoDismissAfter: nil, expand: true, collapseAfter: 6)
        }
        focusMonitor.onClear = { [weak self] in
            self?.island.center.dismiss("focus")
        }
        focusMonitor.start()
    }

    private func makeContextMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(withTitle: "Alcove", action: nil, keyEquivalent: "")
        menu.addItem(NSMenuItem.separator())
        let timerItem = NSMenuItem(title: "Timer · 60s", action: #selector(showTimer), keyEquivalent: "t")
        timerItem.target = self
        menu.addItem(timerItem)
        let musicItem = NSMenuItem(title: "Now Playing", action: #selector(showNowPlaying), keyEquivalent: "m")
        musicItem.target = self
        menu.addItem(musicItem)
        let chargingItem = NSMenuItem(title: "Charging", action: #selector(showCharging), keyEquivalent: "c")
        chargingItem.target = self
        menu.addItem(chargingItem)
        let notifItem = NSMenuItem(title: "Notification", action: #selector(showNotification), keyEquivalent: "n")
        notifItem.target = self
        menu.addItem(notifItem)
        let weatherItem = NSMenuItem(title: "Weather Card", action: #selector(showWeather), keyEquivalent: "w")
        weatherItem.target = self
        menu.addItem(weatherItem)
        let focusItem = NSMenuItem(title: "Focus Card", action: #selector(showFocus), keyEquivalent: "f")
        focusItem.target = self
        menu.addItem(focusItem)
        let pillMenu = NSMenu()
        let pillDefs: [(String, Selector)] = [
            ("Pill · Music", #selector(previewPillMusic)),
            ("Pill · Weather", #selector(previewPillWeather)),
            ("Pill · Charging", #selector(previewPillCharging)),
            ("Pill · Timer", #selector(previewPillTimer)),
            ("Pill · Notify", #selector(previewPillNotify)),
            ("Pill · Focus", #selector(previewPillFocus)),
        ]
        for (title, sel) in pillDefs {
            let item = NSMenuItem(title: title, action: sel, keyEquivalent: "")
            item.target = self
            pillMenu.addItem(item)
        }
        let pillItem = NSMenuItem(title: "Preview Pill", action: nil, keyEquivalent: "")
        pillItem.submenu = pillMenu
        menu.addItem(pillItem)
        menu.addItem(NSMenuItem.separator())
        let expandItem = NSMenuItem(title: "Expand", action: #selector(expandTop), keyEquivalent: " ")
        expandItem.target = self
        menu.addItem(expandItem)
        let dismissItem = NSMenuItem(title: "Dismiss All", action: #selector(dismissAll), keyEquivalent: "d")
        dismissItem.target = self
        menu.addItem(dismissItem)
        menu.addItem(NSMenuItem.separator())
        let settingsItem = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)
        let quitItem = NSMenuItem(title: "Quit Alcove", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quitItem)
        return menu
    }

    /// Real 60s countdown anchored to the device clock (`Date`), not a fake
    /// animation: `endDate` is recomputed every tick so it survives sleep.
    /// Stays open (no auto-dismiss); the tick dismisses it at zero.
    @objc private func showTimer() {
        var t = TimerActivity(seconds: 60, label: "Timer")
        t.endDate = Date().addingTimeInterval(60)
        island.show(.timer(t), autoDismissAfter: nil, expand: true)
    }

    /// Expand the real system Now Playing state (Music/Spotify/…). If nothing
    /// is playing there is nothing to show — no fake track.
    @objc private func showNowPlaying() {
        nowPlayingMonitor.refresh()
        musicMonitor.refresh()
        spotifyMonitor.refresh()
        focusMonitor.refresh()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            guard let self else { return }
            // Whoever is playing wins; else newest known.
            let cur: NowPlayingActivity?
            if self.spotifyPlaying { cur = self.spotifyMonitor.current }
            else if self.musicPlaying { cur = self.musicMonitor.current }
            else { cur = self.spotifyMonitor.current ?? self.musicMonitor.current ?? self.nowPlayingMonitor.current }
            guard let cur else { return }
            self.island.show(.nowPlaying(cur), autoDismissAfter: nil, expand: true)
        }
    }

    /// Show the live battery state from IOKit — plugged in or on battery.
    @objc private func showCharging() {
        batteryMonitor.refresh() // synchronous: `current` is fresh on return
        guard let cur = batteryMonitor.current else { return }
        island.show(.charging(ChargingActivity(
            level: cur.level,
            isPluggedIn: cur.pluggedIn,
            timeRemainingText: BatteryMonitor.etaText(minutes: cur.minutesRemaining)
        )), autoDismissAfter: nil, expand: true)
    }

    @objc private func showWeather() {
        guard let cur = weatherMonitor.current else { return }
        island.show(.weather(cur), autoDismissAfter: nil, expand: true)
    }

    @objc private func showFocus() {
        if let live = focusMonitor.current {
            island.show(.focus(FocusActivity(mode: live.name, symbol: live.symbol)), autoDismissAfter: nil, expand: true)
        } else {
            island.show(.focus(FocusActivity(mode: "Do Not Disturb")), autoDismissAfter: nil, expand: true)
        }
    }

    /// Preview any activity as a settled pill (expand:false), live data when
    /// available, demo data otherwise. For testing pill designs.
    private func previewPill(_ id: String) {
        switch id {
        case "timer":
            var t = TimerActivity(seconds: 60, label: "Timer")
            t.endDate = Date().addingTimeInterval(60)
            island.show(.timer(t), autoDismissAfter: nil, expand: false)
        case "nowPlaying":
            let cur = musicMonitor.current ?? nowPlayingMonitor.current
                ?? NowPlayingActivity(title: "Pray For Me", artist: "The Weeknd, Kendrick Lamar", album: "Starboy", appName: "Music", isPlaying: true, elapsed: 50, duration: 210)
            island.show(.nowPlaying(cur), autoDismissAfter: nil, expand: false)
        case "charging":
            batteryMonitor.refresh()
            let c = batteryMonitor.current
            island.show(.charging(ChargingActivity(
                level: c?.level ?? 0.34,
                isPluggedIn: c?.pluggedIn ?? true,
                timeRemainingText: BatteryMonitor.etaText(minutes: c?.minutesRemaining ?? 40)
            )), autoDismissAfter: nil, expand: false)
        case "weather":
            let w = weatherMonitor.current ?? WeatherActivity(temperatureC: 30, condition: "Overcast", symbol: "cloud.fill", windKph: 12, highC: 31, lowC: 24, isDay: true)
            island.show(.weather(w), autoDismissAfter: nil, expand: false)
        case "notification":
            island.show(.notification(NotificationActivity(appName: "Messages", sender: "Henrik", body: "Psst… it's interactive.", icon: "message.fill")), autoDismissAfter: nil, expand: false)
        case "focus":
            if let live = focusMonitor.current {
                island.show(.focus(FocusActivity(mode: live.name, symbol: live.symbol)), autoDismissAfter: nil, expand: false)
            } else {
                island.show(.focus(FocusActivity(mode: "Do Not Disturb")), autoDismissAfter: nil, expand: false)
            }
        default:
            break
        }
    }

    @objc private func previewPillMusic() { previewPill("nowPlaying") }
    @objc private func previewPillWeather() { previewPill("weather") }
    @objc private func previewPillCharging() { previewPill("charging") }
    @objc private func previewPillTimer() { previewPill("timer") }
    @objc private func previewPillNotify() { previewPill("notification") }
    @objc private func previewPillFocus() { previewPill("focus") }

    @objc private func showNotification() {
        island.show(.notification(NotificationActivity(
            appName: "Messages",
            sender: "Henrik",
            body: "Psst… it's interactive.",
            icon: "message.fill"
        )))
    }

    @objc private func expandTop() {
        island.expandTop()
    }

    @objc private func dismissAll() {
        island.dismissAll()
    }

    @objc private func openSettings() {
        if #available(macOS 14, *) {
            NSApp.activate()
            NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        }
    }
}