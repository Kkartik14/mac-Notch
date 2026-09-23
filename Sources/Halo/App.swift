import AppKit
import SwiftUI
import Combine

@main
struct HaloApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            SettingsRootView()
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let haloController = HaloWindowController()
    private let nowPlayingMonitor = NowPlayingMonitor()
    private let musicMonitor = MusicAppMonitor()
    private let spotifyMonitor = SpotifyMonitor()
    private let batteryMonitor = BatteryMonitor()
    private let weatherMonitor = WeatherMonitor()
    private let focusMonitor = FocusMonitor()
    private let notificationMonitor = NotificationMonitor()
    private let calendarMonitor = CalendarMonitor()
    private let historyMonitor = PlaybackHistoryMonitor()
    private let codexMonitor = CodexMonitor()
    private let openCodeMonitor = OpenCodeMonitor()
    private let claudeCodeMonitor = ClaudeCodeMonitor()
    private let settingsWindowController = HaloSettingsWindowController()
    private let settings = HaloSettings.shared
    private var settingsObservation: AnyCancellable?
    private var wasPluggedIn = false
    private var codexWasWaiting = false
    private var codexRequested = false
    private var openCodeWasWaiting = false
    private var openCodeRequested = false
    private var claudeCodeWasWaiting = false
    private var claudeCodeRequested = false

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
        if case .nowPlaying(let n) = haloController.center.activities.first(where: { $0.id == "nowPlaying" }) {
            if n.appName == "Spotify" { spotifyMonitor.seek(to: seconds); return }
        }
        musicMonitor.seek(to: seconds)
    }

    /// Play a queued rail row in place. Library context (playlist + index)
    /// plays directly inside Music; catalog rows fall back to opening the
    /// track page (scripting cannot address catalog tracks).
    private func playQueued(_ item: UpNextItem) {
        if let pid = item.playlistID, let idx = item.trackIndex {
            NSLog("[Halo] music: play queued track %d of playlist %@", idx, pid)
            let source = """
            tell application "Music"
              try
                play track \(idx) of (first playlist whose persistent ID is "\(pid)")
              on error err
                return "ERR:" & err
              end try
            end tell
            """
            var error: NSDictionary?
            let result = NSAppleScript(source: source)?.executeAndReturnError(&error)
            if let error { NSLog("[Halo] music: play-queued error: %@", error) }
            _ = result
            musicMonitor.refreshAfterUserAction()
            return
        }
        // Catalog row: open the track page; playback stays where it is.
        if var u = item.url, u.hasPrefix("https://") {
            u = "music://" + u.dropFirst(8)
            if let url = URL(string: u) {
                NSLog("[Halo] music: open queued track %@", item.title)
                NSWorkspace.shared.open(url)
            }
        } else {
            NSLog("[Halo] music: queued row not playable (%@)", item.title)
        }
    }
    /// After one source goes quiet: keep whichever source still has a
    /// playing track (quietly), else drop the card.
    private func resolveNowPlayingAfterClear() {
        guard settings.showNowPlaying else {
            haloController.center.dismiss("nowPlaying")
            return
        }
        if spotifyPlaying, let cur = spotifyMonitor.current {
            haloController.show(.nowPlaying(cur), autoDismissAfter: nil, intent: .update)
        } else if musicPlaying, let cur = musicMonitor.current {
            haloController.show(.nowPlaying(cur), autoDismissAfter: nil, intent: .update)
        } else {
            haloController.center.dismiss("nowPlaying")
        }
    }

    /// Session queue wins for the track it belongs to (true play order,
    /// incl. curated mixes). Scripting/store tiers apply only when no
    /// session queue was set for the on-screen track — never overwrite
    /// truth with guesses.
    private var sessionQueueSig: String?
    private func trackSig(of n: NowPlayingActivity) -> String { "\(n.title)|\(n.artist)" }
    private func haloTrackSig() -> String? {
        guard case .nowPlaying(let n) = haloController.center.activities.first(where: { $0.id == "nowPlaying" }) else { return nil }
        return trackSig(of: n)
    }
    private func applySessionQueue(_ items: [UpNextItem], contextTitle: String) {
        guard haloController.center.activities.contains(where: {
            if case .nowPlaying(let n) = $0 { return n.appName == "Music" }
            return false
        }) else { return }
        // Staleness gate: walk-back can land on an older context than what's
        // playing. A queue whose context track isn't on screen is dropped —
        // a wrong queue is worse than the history fallback.
        if let playing = haloTrackSig().map({ trackTitle(of: $0) }),
           !contextTitle.isEmpty,
           !PlaybackHistoryMonitor.sameTrack(playing, contextTitle) {
            NSLog("[Halo] queue: dropped stale context %@ (playing %@)", contextTitle, playing)
            return
        }
        sessionQueueSig = haloTrackSig()
        haloController.center.updateNowPlayingQueue(items)
    }

    private func trackTitle(of sig: String) -> String {
        // sig is "title|artist".
        String(sig.split(separator: "|", maxSplits: 1).first ?? "")
    }
    private func applyTierQueue(_ items: [UpNextItem]) {
        // A session queue already set for this exact track wins; stale tier
        // results (slower async) must not clobber it.
        if let sig = haloTrackSig(), sig == sessionQueueSig { return }
        haloController.center.updateNowPlayingQueue(items)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        // No menu-bar icon: the halo is the entire UI. All actions live on
        // its right-click menu instead.
        haloController.actions = HaloActions(
            showDestination: { [weak self] destination in self?.showDestination(destination) },
            showNowPlaying: { [weak self] in self?.showNowPlaying() },
            showCharging: { [weak self] in self?.showCharging() },
            showNotification: { [weak self] in self?.showNotification() },
            showWeather: { [weak self] in self?.showWeather() },
            showFocus: { [weak self] in self?.showFocus() },
            showCalendar: { [weak self] in self?.showCalendar() },
            showCodex: { [weak self] in self?.showCodex() },
            showOpenCode: { [weak self] in self?.showOpenCode() },
            showClaudeCode: { [weak self] in self?.showClaudeCode() },
            previewPillMusic: { [weak self] in self?.previewPill("nowPlaying") },
            previewPillWeather: { [weak self] in self?.previewPill("weather") },
            previewPillCharging: { [weak self] in self?.previewPill("charging") },
            previewPillNotify: { [weak self] in self?.previewPill("notification") },
            previewPillFocus: { [weak self] in self?.previewPill("focus") },
            previewPillCalendar: { [weak self] in self?.previewPill("calendar") },
            expandTop: { [weak self] in self?.haloController.expandTop() },
            dismissAll: { [weak self] in self?.haloController.dismissAll() },
            openSettings: { [weak self] in self?.openSettings() },
            quit: { NSApplication.shared.terminate(nil) }
        )
        haloController.install(contextMenu: makeContextMenu())
        observeSettings()
        HaloPermissionActions.shared.requestCalendarEventsAccess = { [weak self] in
            self?.calendarMonitor.requestAccess(for: .event)
        }
        HaloPermissionActions.shared.requestRemindersAccess = { [weak self] in
            self?.calendarMonitor.requestAccess(for: .reminder)
        }
        HaloPermissionActions.shared.requestLocationAccess = { [weak self] in
            self?.weatherMonitor.requestLocationAccess()
        }
        applySettings()
        startMonitors()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    private func observeSettings() {
        settingsObservation = settings.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] in
                // @Published emits before the property's didSet persists the
                // new value. Deferring one turn lets every monitor see the
                // committed preference and coalesces rapid toggle changes.
                DispatchQueue.main.async {
                    self?.applySettings()
                }
            }
    }

    private func applySettings() {
        calendarMonitor.configure(
            includeEvents: settings.showCalendarEvents,
            includeReminders: settings.showReminders,
            lookaheadDays: settings.calendarLookaheadDays,
            maximumItems: settings.calendarItemLimit
        )

        if !settings.showNowPlaying { haloController.center.dismiss("nowPlaying") }
        if !settings.showBattery { haloController.center.dismiss("charging") }
        if !settings.showNotifications { haloController.center.dismiss("notification") }
        if !settings.showWeather { haloController.center.dismiss("weather") }
        if !settings.showFocus { haloController.center.dismiss("focus") }
        if !settings.showCalendarEvents && !settings.showReminders {
            haloController.center.dismiss("calendar")
        }
        if !settings.showCodex {
            haloController.center.dismiss("codex")
            codexMonitor.stop()
        } else if codexMonitor.connection == .stopped {
            codexMonitor.start()
        }
        if !settings.showOpenCode {
            haloController.center.dismiss("openCode")
            openCodeMonitor.stop()
        } else if openCodeMonitor.connection == .stopped {
            openCodeMonitor.start()
        }
        if !settings.showClaudeCode {
            haloController.center.dismiss("claudeCode")
            claudeCodeMonitor.stop()
        } else if claudeCodeMonitor.connection == .stopped {
            claudeCodeMonitor.start()
        }
    }

    private func startMonitors() {
        // Media keys + seek: routed to whichever player owns playback.
        haloController.center.onPlayPause = { [weak self] in self?.routePlayPause() }
        haloController.center.onNextTrack = { [weak self] in self?.routeNext() }
        haloController.center.onPreviousTrack = { [weak self] in self?.routePrev() }
        haloController.center.onSeek = { [weak self] in self?.routeSeek($0) }
        haloController.center.onPlayQueued = { [weak self] in self?.playQueued($0) }
        haloController.center.onReplayRecent = { [weak self] track in
            self?.replayRecent(track)
        }
        haloController.center.onCompleteReminder = { [weak self] id in
            self?.calendarMonitor.completeReminder(id: id)
        }
        haloController.center.onOpenCalendarItem = { [weak self] item in
            self?.openCalendarItem(item)
        }
        haloController.center.onOpenCalendarLocation = { [weak self] location in
            self?.openCalendarLocation(location)
        }
        haloController.center.onOpenCalendarURL = { [weak self] url in
            self?.openCalendarURL(url)
        }
        haloController.center.onSelectCodexChat = { [weak self] id in
            self?.codexMonitor.selectChat(id)
        }
        haloController.center.onNewCodexChat = { [weak self] in
            self?.codexMonitor.createChat()
        }
        haloController.center.onRefreshCodex = { [weak self] in
            self?.codexMonitor.refresh()
        }
        haloController.center.onSendCodex = { [weak self] text in
            self?.codexMonitor.send(text)
        }
        haloController.center.onInterruptCodex = { [weak self] in
            self?.codexMonitor.interrupt()
        }
        haloController.center.onResolveCodexApproval = { [weak self] decision in
            self?.codexMonitor.resolveApproval(decision)
        }

        haloController.center.onSelectOpenCodeSession = { [weak self] id in
            self?.openCodeMonitor.selectSession(id)
        }
        haloController.center.onNewOpenCodeSession = { [weak self] in
            self?.openCodeMonitor.createSession()
        }
        haloController.center.onRefreshOpenCode = { [weak self] in
            self?.openCodeMonitor.refresh()
        }
        haloController.center.onSendOpenCode = { [weak self] text in
            self?.openCodeMonitor.send(text)
        }
        haloController.center.onInterruptOpenCode = { [weak self] in
            self?.openCodeMonitor.interrupt()
        }
        haloController.center.onResolveOpenCodePermission = { [weak self] decision in
            self?.openCodeMonitor.resolvePermission(decision)
        }

        haloController.center.onSelectClaudeCodeSession = { [weak self] id in
            self?.claudeCodeMonitor.selectSession(id)
        }
        haloController.center.onNewClaudeCodeSession = { [weak self] in
            self?.claudeCodeMonitor.createSession()
        }
        haloController.center.onRefreshClaudeCode = { [weak self] in
            self?.claudeCodeMonitor.refresh()
        }
        haloController.center.onSendClaudeCode = { [weak self] text in
            self?.claudeCodeMonitor.send(text)
        }
        haloController.center.onInterruptClaudeCode = { [weak self] in
            self?.claudeCodeMonitor.interrupt()
        }

        // Codex — a local app-server stream, never terminal scraping. The
        // monitor publishes the same activity for the compact pill and the
        // fixed-size expanded chat workspace.
        codexMonitor.onActivity = { [weak self] activity in
            guard let self, self.settings.showCodex else { return }
            let shouldSurface = !activity.chats.isEmpty || self.codexRequested
            guard shouldSurface else { return }

            let becameWaiting = activity.selectedState == .waiting && !self.codexWasWaiting
            self.codexWasWaiting = activity.selectedState == .waiting
            self.haloController.show(
                .codex(activity),
                autoDismissAfter: nil,
                intent: becameWaiting && self.settings.automaticallyExpandActivities
                    ? .expand(.automatic)
                    : .update,
                collapseAfter: nil
            )
        }
        if settings.showCodex { codexMonitor.start() }

        // OpenCode — a local HTTP server plus SSE event stream. The monitor
        // owns process discovery, session history, live deltas, and
        // permissions; the fixed Halo surface only renders its value model.
        openCodeMonitor.onActivity = { [weak self] activity in
            guard let self, self.settings.showOpenCode else { return }
            let shouldSurface = !activity.sessions.isEmpty || self.openCodeRequested
            guard shouldSurface else { return }

            let becameWaiting = activity.selectedState == .waiting && !self.openCodeWasWaiting
            self.openCodeWasWaiting = activity.selectedState == .waiting
            self.haloController.show(
                .openCode(activity),
                autoDismissAfter: nil,
                intent: becameWaiting && self.settings.automaticallyExpandActivities
                    ? .expand(.automatic)
                    : .update,
                collapseAfter: nil
            )
        }
        if settings.showOpenCode { openCodeMonitor.start() }

        // Claude Code — local print-mode JSON streaming. Claude owns
        // authentication, permissions, and transcript persistence; this
        // adapter only exposes sessions and live developer activity.
        claudeCodeMonitor.onActivity = { [weak self] activity in
            guard let self, self.settings.showClaudeCode else { return }
            let shouldSurface = !activity.sessions.isEmpty || self.claudeCodeRequested
            guard shouldSurface else { return }

            let becameWaiting = activity.selectedState == .waiting && !self.claudeCodeWasWaiting
            self.claudeCodeWasWaiting = activity.selectedState == .waiting
            self.haloController.show(
                .claudeCode(activity),
                autoDismissAfter: nil,
                intent: becameWaiting && self.settings.automaticallyExpandActivities
                    ? .expand(.automatic)
                    : .update,
                collapseAfter: nil
            )
        }
        if settings.showClaudeCode { claudeCodeMonitor.start() }

        // Now Playing — track changes pop the card open and it STAYS open
        // until dismissed. No auto-collapse: collapsing on its own is what
        // forced the expand/dismiss tap loop.
        nowPlayingMonitor.onUpdate = { [weak self] activity, _ in
            guard let self, self.settings.showNowPlaying, !MusicAppMonitor.isMusicRunning else { return }
            self.haloController.show(
                .nowPlaying(activity),
                autoDismissAfter: nil,
                intent: self.settings.automaticallyExpandActivities ? .expand(.automatic) : .update,
                collapseAfter: 3
            )
        }
        nowPlayingMonitor.onClear = { [weak self] in
            guard !MusicAppMonitor.isMusicRunning else { return }
            self?.haloController.center.dismiss("nowPlaying")
        }
        nowPlayingMonitor.start()

        // Apple Music via scripting — the reliable source on recent macOS.
        musicMonitor.onUpdate = { [weak self] activity, _ in
            guard let self, self.settings.showNowPlaying else { return }
            self.haloController.show(
                .nowPlaying(activity),
                autoDismissAfter: nil,
                intent: self.settings.automaticallyExpandActivities ? .expand(.automatic) : .update,
                collapseAfter: 3
            )
        }
        musicMonitor.onClear = { [weak self] in
            self?.resolveNowPlayingAfterClear()
        }
        musicMonitor.onProgress = { [weak self] elapsed, duration, isPlaying in
            self?.haloController.center.updateNowPlayingProgress(elapsed: elapsed, duration: duration, isPlaying: isPlaying)
        }
        musicMonitor.onQueue = { [weak self] items in
            self?.applyTierQueue(items)
        }
        musicMonitor.start()

        // Spotify via scripting — same treatment. Playing source wins the card.
        spotifyMonitor.onUpdate = { [weak self] activity, _ in
            guard let self, self.settings.showNowPlaying else { return }
            self.haloController.show(
                .nowPlaying(activity),
                autoDismissAfter: nil,
                intent: self.settings.automaticallyExpandActivities ? .expand(.automatic) : .update,
                collapseAfter: 3
            )
        }
        spotifyMonitor.onClear = { [weak self] in
            self?.resolveNowPlayingAfterClear()
        }
        spotifyMonitor.onProgress = { [weak self] elapsed, duration, isPlaying in
            self?.haloController.center.updateNowPlayingProgress(elapsed: elapsed, duration: duration, isPlaying: isPlaying)
        }
        spotifyMonitor.onArtwork = { [weak self] data in
            self?.haloController.center.updateNowPlayingArtwork(data)
        }
        spotifyMonitor.start()

        // Battery — fresh plug jumps to the top for 2s (card pops, then
        // priority order returns), unplug clears it. Level changes while
        // plugged update quietly in rank position.
        batteryMonitor.start { [weak self] charge in
            guard let self else { return }
            guard self.settings.showBattery else {
                self.wasPluggedIn = charge.pluggedIn
                self.haloController.center.dismiss("charging")
                return
            }
            self.haloController.center.updateBatteryLevel(charge.level)
            if charge.pluggedIn {
                let isNewPlug = !self.wasPluggedIn
                self.wasPluggedIn = true
                self.haloController.show(
                    .charging(ChargingActivity(
                        level: charge.level,
                        isPluggedIn: true,
                        timeRemainingText: BatteryMonitor.etaText(minutes: charge.minutesRemaining)
                    )),
                    autoDismissAfter: nil,
                    intent: isNewPlug && self.settings.automaticallyExpandActivities
                        ? .expand(.automatic)
                        : .update,
                    collapseAfter: isNewPlug ? 2 : nil
                )
                if isNewPlug {
                    self.haloController.center.moveToTop("charging")
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                        self?.haloController.center.applyPriorityOrder()
                    }
                }
            } else {
                self.wasPluggedIn = false
                self.haloController.center.dismiss("charging")
            }
        }

        // Calendar and Reminders — EventKit requests each permission once,
        // then keeps the activity current through store-change notifications
        // and a one-minute clock refresh. Passive updates never expand the UI.
        calendarMonitor.start(
            onUpdate: { [weak self] activity in
                guard let self,
                      self.settings.showCalendarEvents || self.settings.showReminders
                else { return }
                self.haloController.show(.calendar(activity), autoDismissAfter: nil, intent: .update)
            },
            onClear: { [weak self] in
                self?.haloController.center.dismiss("calendar")
            },
            onEventStart: { [weak self] activity, event in
                guard let self,
                      self.settings.calendarStartAlerts,
                      self.settings.showCalendarEvents
                else { return }
                NSLog("[Halo] calendar: event started: %@", event.title)
                self.haloController.show(
                    .calendar(activity),
                    autoDismissAfter: nil,
                    intent: self.settings.automaticallyExpandActivities ? .expand(.automatic) : .update,
                    collapseAfter: CalendarMonitor.startAlertDuration
                )
            }
        )

        // Weather — quiet pill, refreshes every 10 min. Never force-expands.
        weatherMonitor.start { [weak self] activity in
            guard let self, self.settings.showWeather else { return }
            self.haloController.show(.weather(activity), autoDismissAfter: nil, intent: .update)
        }

        // Focus — live system mode via disk adapter (silent without FDA).
        // Pops once on activation, settles; turning it off clears the card.
        focusMonitor.onUpdate = { [weak self] state in
            guard let self, self.settings.showFocus else { return }
            self.haloController.show(
                .focus(FocusActivity(mode: state.name, symbol: state.symbol)),
                autoDismissAfter: nil,
                intent: self.settings.automaticallyExpandActivities ? .expand(.automatic) : .update,
                collapseAfter: 6
            )
        }
        focusMonitor.onClear = { [weak self] in
            self?.haloController.center.dismiss("focus")
        }
        focusMonitor.start()

        // Recently played — Music's session archives, zero permissions.
        // Feeds the fallback rail when the live queue is hidden.
        historyMonitor.onTracksChanged = { [weak self] tracks in
            self?.haloController.center.updateNowPlayingRecent(tracks)
        }
        // True queue order from the session checkpoint. Beats scripting and
        // store guesses for the same track; gated on Music below.
        historyMonitor.onQueueChanged = { [weak self] items, contextTitle in
            self?.applySessionQueue(items, contextTitle: contextTitle)
        }
        historyMonitor.start()

        // Real notifications via store adapter (silent without FDA).
        // Quiet 3s pill only — never pops the card.
        notificationMonitor.onNew = { [weak self] note in
            guard let self else { return }
            guard self.settings.showNotifications else { return }
            let sender = note.title.isEmpty ? note.subtitle : note.title
            let body = note.subtitle.isEmpty || note.subtitle == sender ? note.body : "\(note.subtitle)\n\(note.body)"
            self.haloController.show(.notification(NotificationActivity(
                appName: self.notificationMonitor.displayName(for: note.appIdentifier),
                sender: sender.isEmpty ? self.notificationMonitor.displayName(for: note.appIdentifier) : sender,
                body: body,
                icon: "bell.fill",
                appIconData: self.notificationMonitor.iconData(for: note.appIdentifier)
            )), autoDismissAfter: 3, intent: .update)
        }
        notificationMonitor.start()
    }

    /// Tap on a played-recently row. Store ID is recorded for future
    /// signed-build replay (MusicKit); until then, open the track in Music
    /// via its music:// deep link. Library/playlist tracks remain fully
    /// replayable through the normal transport + Up Next path.
    private func replayRecent(_ track: PlaybackHistoryMonitor.Track) {
        if let url = track.musicAppURL {
            NSWorkspace.shared.open(url)
        } else {
            NSLog("[Halo] replay: no url for %@", track.title)
        }
    }

    /// Open the exact Calendar or Reminder item. EventKit remains read-only
    /// here; completion is the only write action Halo performs.
    private func openCalendarItem(_ item: CalendarItem) {
        if let itemURL = CalendarMonitor.nativeURL(for: item),
           NSWorkspace.shared.open(itemURL) {
            NSLog("[Halo] calendar: opening exact %@: %@", item.title, itemURL.absoluteString)
            return
        }

        let bundleIdentifier = item.isReminder ? "com.apple.reminders" : "com.apple.iCal"
        guard let appURL = NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: bundleIdentifier
        ) else {
            NSLog("[Halo] calendar: native app unavailable for %@", item.title)
            return
        }

        NSLog("[Halo] calendar: opening %@ for %@", item.isReminder ? "Reminders" : "Calendar", item.title)
        NSWorkspace.shared.open(appURL)
    }

    private func openCalendarLocation(_ location: String) {
        guard let url = CalendarMonitor.mapsURL(for: location),
              NSWorkspace.shared.open(url) else {
            NSLog("[Halo] calendar: Maps could not open location: %@", location)
            return
        }

        NSLog("[Halo] calendar: opening location: %@", location)
    }

    private func openCalendarURL(_ url: URL) {
        guard CalendarMonitor.externalURL(for: url) != nil else { return }

        guard NSWorkspace.shared.open(url) else {
            NSLog("[Halo] calendar: event URL could not open: %@", url.absoluteString)
            return
        }

        NSLog("[Halo] calendar: opening event URL: %@", url.absoluteString)
    }

    private func makeContextMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(withTitle: "Halo", action: nil, keyEquivalent: "")
        menu.addItem(NSMenuItem.separator())
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
        let calendarItem = NSMenuItem(title: "Calendar", action: #selector(showCalendar), keyEquivalent: "k")
        calendarItem.target = self
        menu.addItem(calendarItem)
        let codexItem = NSMenuItem(title: "Codex · Developer activity", action: #selector(showCodex), keyEquivalent: "x")
        codexItem.target = self
        menu.addItem(codexItem)
        let openCodeItem = NSMenuItem(title: "OpenCode · Developer activity", action: #selector(showOpenCode), keyEquivalent: "o")
        openCodeItem.target = self
        menu.addItem(openCodeItem)
        let claudeCodeItem = NSMenuItem(title: "Claude Code · Developer activity", action: #selector(showClaudeCode), keyEquivalent: "l")
        claudeCodeItem.target = self
        menu.addItem(claudeCodeItem)
        let pillMenu = NSMenu()
        let pillDefs: [(String, Selector)] = [
            ("Pill · Music", #selector(previewPillMusic)),
            ("Pill · Weather", #selector(previewPillWeather)),
            ("Pill · Charging", #selector(previewPillCharging)),
            ("Pill · Notify", #selector(previewPillNotify)),
            ("Pill · Focus", #selector(previewPillFocus)),
            ("Pill · Calendar", #selector(previewPillCalendar)),
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
        let quitItem = NSMenuItem(title: "Quit Halo", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quitItem)
        return menu
    }

    /// Expand the real system Now Playing state (Music/Spotify/…). If nothing
    /// is playing there is nothing to show — no fake track.
    @objc private func showNowPlaying() {
        guard settings.showNowPlaying else { return }
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
            self.haloController.show(.nowPlaying(cur), autoDismissAfter: nil, intent: .expand(.user))
        }
    }

    /// Routes the expanded app bar through the same explicit-selection paths
    /// as the context menu. Each destination therefore gets the existing
    /// manual override behavior instead of inventing a second routing layer.
    private func showDestination(_ destination: HaloDestination) {
        switch destination {
        case .nowPlaying: showNowPlaying()
        case .calendar: showCalendar()
        case .codex: showCodex()
        case .openCode: showOpenCode()
        case .claudeCode: showClaudeCode()
        }
    }

    /// Show the live battery state from IOKit — plugged in or on battery.
    @objc private func showCharging() {
        guard settings.showBattery else { return }
        batteryMonitor.refresh() // synchronous: `current` is fresh on return
        guard let cur = batteryMonitor.current else { return }
        haloController.show(.charging(ChargingActivity(
            level: cur.level,
            isPluggedIn: cur.pluggedIn,
            timeRemainingText: BatteryMonitor.etaText(minutes: cur.minutesRemaining)
        )), autoDismissAfter: nil, intent: .expand(.user))
    }

    @objc private func showWeather() {
        guard settings.showWeather else { return }
        guard let cur = weatherMonitor.current else { return }
        haloController.show(.weather(cur), autoDismissAfter: nil, intent: .expand(.user))
    }

    @objc private func showFocus() {
        guard settings.showFocus else { return }
        if let live = focusMonitor.current {
            haloController.show(.focus(FocusActivity(mode: live.name, symbol: live.symbol)), autoDismissAfter: nil, intent: .expand(.user))
        } else {
            haloController.show(.focus(FocusActivity(mode: "Do Not Disturb")), autoDismissAfter: nil, intent: .expand(.user))
        }
    }

    @objc private func showCalendar() {
        guard settings.showCalendarEvents || settings.showReminders else { return }
        calendarMonitor.refresh()
        // EventKit refreshes Reminders asynchronously, and an empty calendar
        // legitimately has no current activity. Open the screen immediately;
        // CalendarExpandedView already renders the empty state and the monitor
        // will replace it when fresh data arrives.
        let current = calendarMonitor.current ?? CalendarActivity(items: [])
        haloController.show(.calendar(current), autoDismissAfter: nil, intent: .expand(.user))
    }

    /// Open the Codex activity in Halo's existing fixed expanded surface.
    /// Selecting this action also makes an empty or unavailable state visible,
    /// so the user gets a useful explanation instead of a silent no-op.
    @objc private func showCodex() {
        guard settings.showCodex else {
            openSettings()
            return
        }
        codexRequested = true
        codexMonitor.start()
        haloController.show(.codex(codexMonitor.activity), autoDismissAfter: nil, intent: .expand(.user))
    }

    /// Open the OpenCode activity in Halo's existing fixed expanded surface.
    /// The local OpenCode server starts on a free loopback port.
    @objc private func showOpenCode() {
        guard settings.showOpenCode else {
            openSettings()
            return
        }
        openCodeRequested = true
        openCodeMonitor.start()
        haloController.show(.openCode(openCodeMonitor.activity), autoDismissAfter: nil, intent: .expand(.user))
    }

    /// Open Claude Code activity in Halo's existing fixed expanded surface.
    /// Claude Code remains responsible for authentication and permissions;
    /// Halo only starts a structured local stream when a turn is sent.
    @objc private func showClaudeCode() {
        guard settings.showClaudeCode else {
            openSettings()
            return
        }
        claudeCodeRequested = true
        claudeCodeMonitor.start()
        haloController.show(.claudeCode(claudeCodeMonitor.activity), autoDismissAfter: nil, intent: .expand(.user))
    }

    /// Preview any activity as a settled pill, using live data when
    /// available and demo data otherwise. For testing pill designs.
    private func previewPill(_ id: String) {
        switch id {
        case "nowPlaying":
            let cur = musicMonitor.current ?? nowPlayingMonitor.current
                ?? NowPlayingActivity(title: "Pray For Me", artist: "The Weeknd, Kendrick Lamar", album: "Starboy", appName: "Music", isPlaying: true, elapsed: 50, duration: 210)
            haloController.show(.nowPlaying(cur), autoDismissAfter: nil, intent: .update)
        case "charging":
            batteryMonitor.refresh()
            let c = batteryMonitor.current
            haloController.show(.charging(ChargingActivity(
                level: c?.level ?? 0.34,
                isPluggedIn: c?.pluggedIn ?? true,
                timeRemainingText: BatteryMonitor.etaText(minutes: c?.minutesRemaining ?? 40)
            )), autoDismissAfter: nil, intent: .update)
        case "weather":
            let w = weatherMonitor.current ?? WeatherActivity(temperatureC: 30, condition: "Overcast", symbol: "cloud.fill", windKph: 12, highC: 31, lowC: 24, isDay: true)
            haloController.show(.weather(w), autoDismissAfter: nil, intent: .update)
        case "notification":
            haloController.show(.notification(NotificationActivity(appName: "Messages", sender: "Henrik", body: "Psst… it's interactive.", icon: "message.fill")), autoDismissAfter: nil, intent: .update)
        case "focus":
            if let live = focusMonitor.current {
                haloController.show(.focus(FocusActivity(mode: live.name, symbol: live.symbol)), autoDismissAfter: nil, intent: .update)
            } else {
                haloController.show(.focus(FocusActivity(mode: "Do Not Disturb")), autoDismissAfter: nil, intent: .update)
            }
        case "calendar":
            var testCalendar = Calendar.current
            testCalendar.timeZone = .current
            let testStart = testCalendar.date(
                bySettingHour: 17,
                minute: 53,
                second: 0,
                of: Date()
            ) ?? Date()
            let sample = CalendarItem(
                id: "preview:test-event",
                title: "Test meeting",
                startDate: testStart,
                endDate: testStart.addingTimeInterval(60 * 60),
                isAllDay: false,
                location: "Halo preview",
                calendarName: "Test calendar",
                kind: .event,
                isCompleted: false
            )
            haloController.show(.calendar(CalendarActivity(items: [sample])), autoDismissAfter: nil, intent: .update)
        default:
            break
        }
    }

    @objc private func previewPillMusic() { previewPill("nowPlaying") }
    @objc private func previewPillWeather() { previewPill("weather") }
    @objc private func previewPillCharging() { previewPill("charging") }
    @objc private func previewPillNotify() { previewPill("notification") }
    @objc private func previewPillFocus() { previewPill("focus") }
    @objc private func previewPillCalendar() { previewPill("calendar") }

    @objc private func showNotification() {
        guard settings.showNotifications else { return }
        haloController.show(.notification(NotificationActivity(
            appName: "Messages",
            sender: "Henrik",
            body: "Psst… it's interactive.",
            icon: "message.fill"
        )), intent: .expand(.user))
    }

    @objc private func expandTop() {
        haloController.expandTop()
    }

    @objc private func dismissAll() {
        haloController.dismissAll()
    }

    @objc private func openSettings() {
        settingsWindowController.show()
    }
}
