import AppKit
import SwiftUI
import Combine

/// Morph timing: bouncy open, critically-damped close. SwiftUI owns all
/// motion now; the window never animates (Plan B).
private let haloOpenResponse = 0.42
private let haloOpenDamping: Double = 0.8
private let haloCloseResponse = 0.45
private let haloCloseDamping: Double = 1.0

/// Fixed window geometry (Plan B): the window never resizes or moves after
/// placement. 640 content + shadow room. All morphing is SwiftUI content
/// inside stationary glass — slide and lag have no mechanism left.
private let haloWindowSize = CGSize(width: 660, height: 210)

/// Container sizes for content inside the fixed window.
private let haloOpenSize = CGSize(width: 640, height: 190)
private let haloClosedFallbackWidth: CGFloat = 185
private let haloClosedHeight: CGFloat = 32
private let haloRadiiOpen = (top: CGFloat(19), bottom: CGFloat(24))
private let haloRadiiClosed = (top: CGFloat(6), bottom: CGFloat(14))

/// Closed pill width tracks the real camera housing when available.
func haloClosedWidth() -> CGFloat {
    guard let screen = NSScreen.main,
          let left = screen.auxiliaryTopLeftArea,
          let right = screen.auxiliaryTopRightArea,
          left.maxX < right.minX
    else { return haloClosedFallbackWidth }
    return screen.frame.width - left.width - right.width + 4
}

// MARK: - Activity types

enum HaloActivity: Equatable, Identifiable {
    case nowPlaying(NowPlayingActivity)
    case charging(ChargingActivity)
    case notification(NotificationActivity)
    case focus(FocusActivity)
    case weather(WeatherActivity)
    case calendar(CalendarActivity)
    case codex(CodexActivity)
    case openCode(OpenCodeActivity)
    case claudeCode(ClaudeCodeActivity)

    var id: String {
        switch self {
        case .nowPlaying: return "nowPlaying"
        case .charging: return "charging"
        case .notification: return "notification"
        case .focus: return "focus"
        case .weather: return "weather"
        case .calendar: return "calendar"
        case .codex: return "codex"
        case .openCode: return "openCode"
        case .claudeCode: return "claudeCode"
        }
    }
}

struct NowPlayingActivity: Equatable {
    var title: String
    var artist: String
    var album: String = ""
    var appName: String = "Music"
    var isPlaying: Bool
    var elapsed: TimeInterval = 0
    var duration: TimeInterval = 0
    var artworkData: Data?
    var upNext: [UpNextItem] = []
    /// Fallback rail when the queue is hidden (catalog/autoplay playback):
    /// Music's own recent plays, tap to replay. From PlaybackSessions.
    var recent: [PlaybackHistoryMonitor.Track] = []

    var progress: Double {
        guard duration > 0 else { return 0 }
        return min(1, max(0, elapsed / duration))
    }
}

struct UpNextItem: Equatable {
    var title: String
    var artist: String
    /// Remote thumbnail URL for catalog/session rows. Downloaded after delivery.
    var artworkURL: String? = nil
    /// Embedded artwork bytes for playlist rows or downloaded catalog artwork.
    var artData: Data? = nil
    /// Library-context replay address (scripting tier): playlist + index.
    var playlistID: String? = nil
    var trackIndex: Int? = nil
    /// Catalog deep link (session tier): music://… opens the track page.
    var url: String? = nil
}

struct ChargingActivity: Equatable {
    var level: Double
    var isPluggedIn: Bool
    var timeRemainingText: String?
}

struct NotificationActivity: Equatable {
    var appName: String
    var sender: String
    var body: String
    var icon: String
    /// Real app icon PNG bytes when resolvable; view falls back to `icon`.
    var appIconData: Data? = nil
}

struct FocusActivity: Equatable {
    var mode: String
    /// SF symbol name, or raw emoji/text when custom. Rendered via
    /// FocusMonitor.isSFSymbol check.
    var symbol: String = "moon.fill"
}
struct WeatherActivity: Equatable {
    var temperatureC: Int
    var condition: String
    var symbol: String
    var windKph: Int = 0
    var highC: Int? = nil
    var lowC: Int? = nil
    var isDay: Bool = true
}

// MARK: - Center

final class HaloCenter: ObservableObject {
    @Published var activities: [HaloActivity] = []
    @Published var expandedId: String?
    /// Persistent explicit activity selection from a user menu/action. It
    /// controls the collapsed pill and expanded card until another explicit
    /// choice replaces it or the activity is removed.
    @Published private(set) var manualOverrideID: String?
    /// Latest battery fraction for pills that show it (focus trailing).
    @Published var batteryLevel: Double?
    var deliver: ((HaloActivity) -> Void)?

    /// Priority (higher = shows on top). Ambient order: music > calendar/focus >
    /// charging > weather. Transient notifications pin above — say so to change.
    static func rank(of activity: HaloActivity) -> Int {
        switch activity {
        case .notification: return 4
        case .nowPlaying: return 3
        case .focus: return 2
        case .calendar: return 2
        case .codex: return 3
        case .openCode: return 3
        case .claudeCode: return 3
        case .charging: return 1
        case .weather: return 0
        }
    }

    /// Media-key callbacks, wired by the app to the real Now Playing monitor.
    var onPlayPause: (() -> Void)?
    var onNextTrack: (() -> Void)?
    var onPreviousTrack: (() -> Void)?
    /// Seek callback (seconds), wired to the monitor's transport.
    var onSeek: ((TimeInterval) -> Void)?
    /// Play a queued track in place, wired by the app delegate.
    var onPlayQueued: ((UpNextItem) -> Void)?
    /// Tap on a played-recently row; app decides how to replay.
    var onReplayRecent: ((PlaybackHistoryMonitor.Track) -> Void)?
    /// Complete a reminder from the expanded Calendar activity.
    var onCompleteReminder: ((String) -> Void)?
    /// Open the exact Calendar or Reminders item for an expanded row.
    var onOpenCalendarItem: ((CalendarItem) -> Void)?
    /// Open an EventKit location in Apple Maps.
    var onOpenCalendarLocation: ((String) -> Void)?
    /// Open an event's external meeting or reference URL.
    var onOpenCalendarURL: ((URL) -> Void)?
    /// Codex developer activity callbacks. The expanded card stays inside
    /// Halo's fixed geometry; the monitor owns the app-server transport.
    var onSelectCodexChat: ((String) -> Void)?
    var onNewCodexChat: (() -> Void)?
    var onRefreshCodex: (() -> Void)?
    var onSendCodex: ((String) -> Void)?
    var onInterruptCodex: (() -> Void)?
    var onResolveCodexApproval: ((CodexApprovalDecision) -> Void)?
    /// OpenCode developer activity callbacks. OpenCode uses its own local
    /// HTTP/SSE transport and its own value types, kept separate from Codex.
    var onSelectOpenCodeSession: ((String) -> Void)?
    var onNewOpenCodeSession: (() -> Void)?
    var onRefreshOpenCode: (() -> Void)?
    var onSendOpenCode: ((String) -> Void)?
    var onInterruptOpenCode: (() -> Void)?
    var onResolveOpenCodePermission: ((OpenCodePermissionDecision) -> Void)?
    /// Claude Code developer activity callbacks. Claude owns authentication,
    /// permissions, and transcript persistence; Halo only starts its local
    /// print-mode stream and renders the value model.
    var onSelectClaudeCodeSession: ((String) -> Void)?
    var onNewClaudeCodeSession: (() -> Void)?
    var onRefreshClaudeCode: (() -> Void)?
    var onSendClaudeCode: ((String) -> Void)?
    var onInterruptClaudeCode: (() -> Void)?

    private var autoDismissWorkItems: [String: DispatchWorkItem] = [:]
    private var collapseWorkItems: [String: DispatchWorkItem] = [:]
    private var autoDismissGenerations: [String: UInt64] = [:]
    private var collapseGenerations: [String: UInt64] = [:]
    private var tickTimer: Timer?

    deinit {
        tickTimer?.invalidate()
        autoDismissWorkItems.values.forEach { $0.cancel() }
        collapseWorkItems.values.forEach { $0.cancel() }
    }

    /// Tick while music is playing (for smooth second-by-second progress).
    /// Previously a 1Hz timer ran forever even when idle — a pointless
    /// wakeup 99% of the time.
    private func ensureTicking() {
        var needsTick = false
        for activity in activities {
            if case let .nowPlaying(n) = activity, n.isPlaying, n.duration > 0 {
                needsTick = true
                break
            }
        }
        if needsTick {
            if tickTimer == nil {
                tickTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
                    self?.tick()
                }
            }
        } else {
            tickTimer?.invalidate()
            tickTimer = nil
        }
    }

    /// Update or present an activity through the shared expansion policy.
    /// Ordinary monitor updates use `.update`; only an explicit intent may
    /// change the expanded card.
    func present(
        _ activity: HaloActivity,
        autoDismissAfter seconds: TimeInterval? = 8,
        intent: HaloPresentationIntent = .update,
        collapseAfter collapse: TimeInterval? = nil
    ) {
        let idx: Int
        if let existing = activities.firstIndex(where: { $0.id == activity.id }) {
            activities[existing] = activity
            idx = existing
        } else {
            // Ordered insert: higher rank sits closer to the top (end).
            let pos = activities.firstIndex { Self.rank(of: $0) > Self.rank(of: activity) } ?? activities.endIndex
            activities.insert(activity, at: pos)
            if activities.count > 4 { activities.removeFirst(activities.count - 4) }
            guard let inserted = activities.firstIndex(where: { $0.id == activity.id }) else { return }
            idx = inserted
        }
        // Fresh nowPlaying cards carry no history (independent source);
        // re-attach the cached recents so the fallback rail survives.
        if case var .nowPlaying(n) = activities[idx], n.recent.isEmpty, !latestRecent.isEmpty {
            n.recent = latestRecent
            activities[idx] = .nowPlaying(n)
        }

        // A capped activity can remove the card that used to be expanded.
        // Clear that stale target before evaluating the new request.
        if let expandedId,
           !activities.contains(where: { $0.id == expandedId }) {
            self.expandedId = nil
        }
        if let manualOverrideID,
           !activities.contains(where: { $0.id == manualOverrideID }) {
            self.manualOverrideID = nil
        }
        if HaloPresentationPolicy.shouldExpand(
            intent: intent,
            currentExpandedID: expandedId,
            targetID: activity.id,
            manualOverrideID: manualOverrideID
        ) {
            expandedId = activity.id
            if case .expand(.user) = intent {
                manualOverrideID = activity.id
            }
        }

        invalidateAutoDismiss(for: activity.id)
        if let seconds {
            scheduleAutoDismiss(for: activity.id, after: seconds)
        }
        invalidateCollapse(for: activity.id)
        if let collapse {
            scheduleCollapse(for: activity.id, after: collapse)
        }
        ensureTicking()
    }

    /// Compatibility shim for focused model tests and older call sites. New
    /// production code should pass a typed presentation intent instead of a
    /// boolean that loses the reason for expansion.
    func present(
        _ activity: HaloActivity,
        autoDismissAfter seconds: TimeInterval? = 8,
        expand: Bool,
        collapseAfter collapse: TimeInterval? = nil
    ) {
        present(
            activity,
            autoDismissAfter: seconds,
            // The old boolean API represents a generic expansion. Explicit
            // menu/admin actions use the typed `.user` intent above.
            intent: expand ? .expand(.pillTap) : .update,
            collapseAfter: collapse
        )
    }

    /// Collapse an expanded card back to its pill, keeping both the activity
    /// and any explicit selection override live.
    func collapse(_ id: String) {
        invalidateCollapse(for: id)
        if expandedId == id { expandedId = nil }
    }

    func dismiss(_ id: String) {
        invalidateAutoDismiss(for: id)
        invalidateCollapse(for: id)
        activities.removeAll { $0.id == id }
        if manualOverrideID == id { manualOverrideID = nil }
        if expandedId == id { expandedId = HaloPresentationPolicy.topActivityID(activities) }
        if let manualOverrideID,
           !activities.contains(where: { $0.id == manualOverrideID }) {
            self.manualOverrideID = nil
        }
        ensureTicking()
    }

    func dismissAll() {
        autoDismissWorkItems.values.forEach { $0.cancel() }
        autoDismissWorkItems.removeAll()
        autoDismissGenerations.removeAll()
        collapseWorkItems.values.forEach { $0.cancel() }
        collapseWorkItems.removeAll()
        collapseGenerations.removeAll()
        activities.removeAll()
        expandedId = nil
        manualOverrideID = nil
        ensureTicking()
    }

    func toggleExpand(_ id: String) {
        if expandedId == id {
            collapse(id)
        } else {
            _ = requestExpansion(for: id, source: .pillTap)
        }
    }

    @discardableResult
    func requestExpansion(for id: String, source: HaloExpansionSource) -> Bool {
        guard activities.contains(where: { $0.id == id }) else { return false }
        guard HaloPresentationPolicy.shouldExpand(
            intent: .expand(source),
            currentExpandedID: expandedId,
            targetID: id,
            manualOverrideID: manualOverrideID
        ) else { return false }
        expandedId = id
        if source == .user { manualOverrideID = id }
        return true
    }

    /// Automatic alerts may expand only when the surface is currently
    /// collapsed, or when they belong to the card already on screen. A
    /// background provider update must never replace a user's active view.
    func canAutomaticallyExpand(_ id: String) -> Bool {
        HaloPresentationPolicy.shouldExpand(
            intent: .expand(.automatic),
            currentExpandedID: expandedId,
            targetID: id,
            manualOverrideID: manualOverrideID
        )
    }

    /// Pin an activity to the top regardless of rank (plug-in override).
    func moveToTop(_ id: String) {
        guard let idx = activities.firstIndex(where: { $0.id == id }) else { return }
        let a = activities.remove(at: idx)
        activities.append(a)
    }

    /// Restore rank order (stable: same-rank keeps current relative order).
    /// Used after a temporary override expires.
    func applyPriorityOrder() {
        activities = activities.enumerated()
            .sorted {
                let r0 = Self.rank(of: $0.element), r1 = Self.rank(of: $1.element)
                if r0 != r1 { return r0 < r1 }
                return $0.offset < $1.offset
            }
            .map(\.element)
        // Restoring rank order must never replace the card the user is
        // currently viewing. Only fall back if that activity was removed.
        if let manualOverrideID,
           !activities.contains(where: { $0.id == manualOverrideID }) {
            self.manualOverrideID = nil
        }
        if let exp = expandedId,
           !activities.contains(where: { $0.id == exp }) {
            expandedId = HaloPresentationPolicy.topActivityID(activities)
        }
    }

    func toggleExpandTop() {
        guard let selectedID = HaloPresentationPolicy.selectedActivityID(
            activities,
            manualOverrideID: manualOverrideID
        ) else { return }
        toggleExpand(selectedID)
    }

    /// Cache the latest battery level for pills (focus trailing shows it).
    func updateBatteryLevel(_ level: Double) {
        if batteryLevel != level { batteryLevel = level }
    }

    /// Attach late-arriving artwork (e.g. downloaded URLs) without
    /// re-expanding or resetting the collapse timer.
    func updateNowPlayingArtwork(_ data: Data) {
        guard let idx = activities.firstIndex(where: { $0.id == "nowPlaying" }),
              case var .nowPlaying(n) = activities[idx] else { return }
        n.artworkData = data
        activities[idx] = .nowPlaying(n)
    }

    /// Attach the Up Next queue silently (arrives after the card pops).
    func updateNowPlayingQueue(_ items: [UpNextItem]) {
        guard let idx = activities.firstIndex(where: { $0.id == "nowPlaying" }),
              case var .nowPlaying(n) = activities[idx] else { return }
        if n.upNext != items {
            n.upNext = items
            activities[idx] = .nowPlaying(n)
        }
    }

    /// Latest recent-tracks list. The history source is independent of the
    /// music poll, so every fresh nowPlaying card starts without it — cache
    /// here and re-attach in present() or the rail vanishes on track change.
    private var latestRecent: [PlaybackHistoryMonitor.Track] = []

    /// Attach recent plays silently (fallback rail for hidden queues).
    func updateNowPlayingRecent(_ tracks: [PlaybackHistoryMonitor.Track]) {
        latestRecent = tracks
        applyRecentToCard(tracks)
    }

    private func applyRecentToCard(_ tracks: [PlaybackHistoryMonitor.Track]) {
        guard let idx = activities.firstIndex(where: { $0.id == "nowPlaying" }),
              case var .nowPlaying(n) = activities[idx] else { return }
        // The newest archive often IS the current track — drop it so the
        // rail only shows what came before the card's song.
        let filtered = tracks.filter { $0.title != n.title }
        if n.recent != filtered {
            n.recent = filtered
            activities[idx] = .nowPlaying(n)
        }
    }

    /// Silent progress correction from the monitor's adaptive poll. Updates the
    /// halo's copy in place — never expands, never hijacks.
    func updateNowPlayingProgress(elapsed: TimeInterval, duration: TimeInterval, isPlaying: Bool) {
        guard let idx = activities.firstIndex(where: { $0.id == "nowPlaying" }),
              case var .nowPlaying(n) = activities[idx] else { return }
        // Ignore tiny jitter so the 1Hz local tick stays smooth.
        if abs(n.elapsed - elapsed) < 1.5 && n.duration == duration && n.isPlaying == isPlaying { return }
        n.elapsed = elapsed
        n.duration = duration
        n.isPlaying = isPlaying
        activities[idx] = .nowPlaying(n)
        ensureTicking()
    }

    private func nextGeneration(for id: String, in generations: inout [String: UInt64]) -> UInt64 {
        let next = (generations[id] ?? 0) &+ 1
        generations[id] = next
        return next
    }

    private func invalidateAutoDismiss(for id: String) {
        autoDismissWorkItems[id]?.cancel()
        autoDismissWorkItems.removeValue(forKey: id)
        _ = nextGeneration(for: id, in: &autoDismissGenerations)
    }

    private func invalidateCollapse(for id: String) {
        collapseWorkItems[id]?.cancel()
        collapseWorkItems.removeValue(forKey: id)
        _ = nextGeneration(for: id, in: &collapseGenerations)
    }

    private func scheduleAutoDismiss(for id: String, after seconds: TimeInterval) {
        let generation = nextGeneration(for: id, in: &autoDismissGenerations)
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.autoDismissGenerations[id] == generation else { return }
            self.dismiss(id)
        }
        autoDismissWorkItems[id] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    private func scheduleCollapse(for id: String, after seconds: TimeInterval) {
        let generation = nextGeneration(for: id, in: &collapseGenerations)
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.collapseGenerations[id] == generation else { return }
            self.collapse(id)
        }
        collapseWorkItems[id] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    private func tick() {
        for idx in activities.indices {
            if case var .nowPlaying(n) = activities[idx], n.isPlaying, n.duration > 0 {
                // Local 1Hz interpolation so seconds + bar move smoothly
                // between the monitor's adaptive corrections.
                let next = min(n.duration, n.elapsed + 1)
                if next != n.elapsed {
                    n.elapsed = next
                    activities[idx] = .nowPlaying(n)
                }
            }
        }
    }
}

// MARK: - Window controller

/// The halo stays non-activating so it does not steal focus just because the
/// user moves over it. Once the user explicitly clicks the Codex composer,
/// however, the panel must be able to become key and deliver keyboard input.
private final class HaloPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

final class HaloWindowController: NSObject {
    private var window: HaloPanel?
    let center = HaloCenter()
    var actions = HaloActions()
    private var hoverWork: DispatchWorkItem?
    private var hoverTimer: Timer?
    private var hoverInside = false
    /// Context-menu selection briefly owns the surface while AppKit dismisses
    /// the menu. Without this handoff window, the cursor can be classified as
    /// outside the newly expanded card before the user can reach it.
    private var pointerExitSuppressedUntil: Date?
    private var recentMouse: [(time: Date, point: NSPoint)] = []
    private var pollCount = 0
    private var mouseMonitor: Any?
    private var screenObserver: NSObjectProtocol?

    deinit {
        hoverTimer?.invalidate()
        hoverWork?.cancel()
        if let m = mouseMonitor { NSEvent.removeMonitor(m) }
        if let o = screenObserver { NotificationCenter.default.removeObserver(o) }
    }

    /// Visible content rect in screen coordinates: pill strip when settled,
    /// full card when open. Everything else is transparent glass.
    private func visibleContentRect() -> NSRect? {
        guard let window else { return nil }
        let f = window.frame
        let isOpen: Bool = {
            if let id = center.expandedId, center.activities.contains(where: { $0.id == id }) { return true }
            return false
        }()
        let closedW = haloClosedWidth()
        let w: CGFloat = isOpen ? haloOpenSize.width : (center.activities.isEmpty ? closedW : closedW + 60)
        let h: CGFloat = isOpen ? haloOpenSize.height : haloClosedHeight
        // Content is top-center anchored in the fixed window.
        let x = f.midX - w / 2
        let y = f.maxY - h
        return NSRect(x: x - 6, y: y - 8, width: w + 12, height: h + 14)
    }

    /// Owns `ignoresMouseEvents`: glass passes everything through, shape
    /// interacts. Called from the event fast path and the poll backstop.
    private func updateEventRouting() {
        guard let window else { return }
        let over = visibleContentRect().map { $0.contains(NSEvent.mouseLocation) } ?? false
        if window.ignoresMouseEvents == over {
            window.ignoresMouseEvents = !over
        }
    }

    func install(contextMenu: NSMenu? = nil) {
        let panel = HaloPanel(
            contentRect: NSRect(x: 0, y: 0, width: haloWindowSize.width, height: haloWindowSize.height),
            styleMask: [.borderless, .nonactivatingPanel, .utilityWindow, .hudWindow],
            backing: .buffered,
            defer: false
        )
        panel.title = "Halo"
        // Above the menu bar but below screen-lock UI.
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.acceptsMouseMovedEvents = true
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.ignoresMouseEvents = true // glass until proven shape (see below)
        panel.isReleasedWhenClosed = false
        panel.appearance = NSAppearance(named: .darkAqua)

        let host = NSHostingView(rootView: HaloView(center: center, actions: actions))
        host.autoresizingMask = [.width, .height]
        host.translatesAutoresizingMaskIntoConstraints = true
        host.frame = NSRect(x: 0, y: 0, width: haloWindowSize.width, height: haloWindowSize.height)
        host.wantsLayer = true
        host.layer?.backgroundColor = .clear
        panel.contentView = host
        host.menu = contextMenu

        positionAtTopSurface(panel, width: haloWindowSize.width, height: haloWindowSize.height)
        panel.orderFrontRegardless()
        window = panel
        updateEventRouting()

        // Fast path: flip pass-through on every cursor move (O(1) rect test).
        if mouseMonitor == nil {
            mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved) { [weak self] _ in
                self?.updateEventRouting()
            }
        }
        // Screen attach/detach, fullscreen changes: re-pin the fixed window.
        if screenObserver == nil {
            screenObserver = NotificationCenter.default.addObserver(
                forName: NSApplication.didChangeScreenParametersNotification,
                object: nil, queue: .main
            ) { [weak self] _ in
                guard let self, let window = self.window else { return }
                self.positionAtTopSurface(window, width: haloWindowSize.width, height: haloWindowSize.height)
                self.updateEventRouting()
            }
        }

        // 10Hz hover poll: mouse events are unreliable inside the top surface
        // dead-zone, so hit-test the cursor position directly. Doubles as
        // the routing backstop (card opening under a parked cursor).
        hoverTimer?.invalidate()
        hoverTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            self?.pollHover()
        }
    }

    func show(
        _ activity: HaloActivity,
        autoDismissAfter seconds: TimeInterval? = 8,
        intent: HaloPresentationIntent = .update,
        collapseAfter collapse: TimeInterval? = nil
    ) {
        if case .expand(.user) = intent {
            // A context-menu action can change the visible geometry while the
            // pointer is already outside it. Cancel stale work and force the
            // next hover poll to re-evaluate the new surface.
            hoverWork?.cancel()
            hoverWork = nil
            hoverInside = true
            pointerExitSuppressedUntil = Date().addingTimeInterval(0.75)
        }
        center.present(activity, autoDismissAfter: seconds, intent: intent, collapseAfter: collapse)
        // A fresh card under a parked cursor must still take clicks.
        updateEventRouting()
    }
    func expandTop() { center.toggleExpandTop(); updateEventRouting() }
    func dismissAll() { center.dismissAll(); updateEventRouting() }

    // MARK: Hover to open

    private func pollHover() {
        guard let window else { return }
        pollCount &+= 1
        // Backstop for event routing (card opening under a parked cursor).
        updateEventRouting()
        // Watchdog is expensive (NSScreen.screens is cross-process), so run it
        // at ~1Hz, not 10Hz. Hover hit-testing stays at 10Hz.
        // %10==1 includes the very first poll so a bad launch frame snaps fast.
        if pollCount % 10 == 1 {
            let onAnyScreen = NSScreen.screens.contains { $0.frame.intersects(window.frame) }
            if !onAnyScreen {
                positionAtTopSurface(window, width: haloWindowSize.width, height: haloWindowSize.height)
                return
            }
        }
        // No activities: nothing to hover-open. Skip mouseLocation work.
        if center.activities.isEmpty { return }
        // Motion history (1s window): hover-open must come from the cursor
        // moving onto the pill — never from geometry changing under a
        // parked cursor (e.g. the pill elongating as a song starts).
        let now = Date()
        let loc = NSEvent.mouseLocation
        recentMouse.append((now, loc))
        recentMouse.removeAll { now.timeIntervalSince($0.time) > 1.0 }
        // Visible shape only — never transparent glass.
        let hit = visibleContentRect() ?? window.frame
        let inside = hit.contains(loc)
        if let suppressedUntil = pointerExitSuppressedUntil {
            guard now >= suppressedUntil else { return }
            pointerExitSuppressedUntil = nil
        }
        if inside != hoverInside {
            hoverInside = inside
            if inside { hoverEntered() } else { hoverExited() }
        }
    }

    private func hoverEntered() {
        hoverWork?.cancel()
        hoverWork = nil
        guard HaloSettings.shared.hoverToExpand,
              !center.activities.isEmpty,
              center.expandedId == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self, HaloSettings.shared.hoverToExpand else { return }
            let loc = NSEvent.mouseLocation
            let inHit = self.visibleContentRect().map { $0.contains(loc) } ?? false
            let moved = self.mouseMovedRecently(threshold: 4)
            guard let top = HaloPresentationPolicy.selectedActivity(
                self.center.activities,
                manualOverrideID: self.center.manualOverrideID
            ), inHit, moved else { return }
            guard self.center.requestExpansion(for: top.id, source: .hover) else { return }
            NSLog("[Halo] ui: hover-open %@", top.id)
            self.updateEventRouting()
        }
        hoverWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    /// True if the cursor moved more than `threshold` points within the
    /// recorded 1s history.
    private func mouseMovedRecently(threshold: CGFloat) -> Bool {
        guard let first = recentMouse.first else { return false }
        var minX = first.point.x, maxX = first.point.x
        var minY = first.point.y, maxY = first.point.y
        for sample in recentMouse {
            minX = min(minX, sample.point.x); maxX = max(maxX, sample.point.x)
            minY = min(minY, sample.point.y); maxY = max(maxY, sample.point.y)
        }
        return max(maxX - minX, maxY - minY) > threshold
    }

    private func hoverExited() {
        hoverWork?.cancel()
        hoverWork = nil
        guard HaloPresentationPolicy.shouldCollapseOnPointerExit(
            expandedID: center.expandedId,
            collapseOnMouseLeave: HaloSettings.shared.collapseOnMouseLeave
        ) else { return }
        guard let id = center.expandedId else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self, HaloSettings.shared.collapseOnMouseLeave else { return }
            self.center.collapse(id)
            self.updateEventRouting()
        }
        hoverWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    private func topSurfaceInfo() -> (minX: CGFloat, maxX: CGFloat, menuBarHeight: CGFloat)? {
        guard let screen = NSScreen.main else { return nil }
        let frame = screen.frame
        let visible = screen.visibleFrame
        let menuBarHeight = frame.maxY - visible.maxY
        let auxLeft = screen.auxiliaryTopLeftArea
        let auxRight = screen.auxiliaryTopRightArea
        if let left = auxLeft, let right = auxRight, left.maxX < right.minX {
            let inset: CGFloat = 2
            return (left.maxX + inset, right.minX - inset, menuBarHeight)
        }
        return (visible.minX, visible.maxX, menuBarHeight)
    }

    private func positionAtTopSurface(_ panel: NSPanel, width: CGFloat, height: CGFloat) {
        guard let topSurface = topSurfaceInfo(), let screen = NSScreen.main else { return }
        let frame = screen.frame
        let o = Self.haloOrigin(width: Double(width), height: Double(height),
                                  screenMidX: Double(frame.midX),
                                  menuBarHeight: Double(topSurface.menuBarHeight),
                                  screenMaxY: Double(frame.maxY))
        panel.setFrame(NSRect(x: o.x, y: o.y, width: width, height: height), display: true)
    }

    /// Pure positioning math: always centered on the screen axis with the top
    /// edge pinned to the screen top. One center for every size — the halo
    /// can grow/shrink but its center mathematically cannot move.
    /// Separated for unit testing.
    static func haloOrigin(width w: Double, height h: Double,
                             screenMidX: Double, menuBarHeight: Double,
                             screenMaxY: Double) -> CGPoint {
        let x = screenMidX - w / 2
        let y = screenMaxY - menuBarHeight - (h - menuBarHeight)
        return CGPoint(x: x, y: y)
    }
}

// MARK: - SwiftUI view

/// Actions reachable from the halo's right-click menu.
/// Wired by the app delegate; default no-ops keep previews/tests safe.
struct HaloActions {
    var showNowPlaying: () -> Void = {}
    var showCharging: () -> Void = {}
    var showNotification: () -> Void = {}
    var showWeather: () -> Void = {}
    var showFocus: () -> Void = {}
    var showCalendar: () -> Void = {}
    var showCodex: () -> Void = {}
    var showOpenCode: () -> Void = {}
    var showClaudeCode: () -> Void = {}
    var previewPillMusic: () -> Void = {}
    var previewPillWeather: () -> Void = {}
    var previewPillCharging: () -> Void = {}
    var previewPillNotify: () -> Void = {}
    var previewPillFocus: () -> Void = {}
    var previewPillCalendar: () -> Void = {}
    var expandTop: () -> Void = {}
    var dismissAll: () -> Void = {}
    var openSettings: () -> Void = {}
    var quit: () -> Void = {}
}

struct HaloView: View {
    @ObservedObject var center: HaloCenter
    var actions: HaloActions = HaloActions()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject private var settings = HaloSettings.shared

    // Halo top-surface dimensions tuned for the built-in display.
    // Closed hugs the camera housing (~185pt on 14-inch displays); open is wide.
    private var topSurfacePillWidth: CGFloat { haloClosedWidth() }
    private let topSurfacePillHeight: CGFloat = 32
    private var expandedWidth: CGFloat { haloOpenSize.width }
    private var expandedHeight: CGFloat { haloOpenSize.height }

    private var isOpen: Bool {
        if let id = center.expandedId, center.activities.contains(where: { $0.id == id }) { return true }
        return false
    }

    private var openSpring: Animation {
        .spring(response: haloOpenResponse, dampingFraction: haloOpenDamping, blendDuration: 0)
    }
    private var closeSpring: Animation {
        .spring(response: haloCloseResponse, dampingFraction: haloCloseDamping, blendDuration: 0)
    }
    private var morphSpring: Animation { isOpen ? openSpring : closeSpring }
    private var motionReduced: Bool { reduceMotion || settings.reduceMotion }

    var body: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .top) {
                // Opaque black pill — no blur/material, no outer stroke.
                HaloSurfaceShape(topRadius: backdropTop, bottomRadius: backdropBottom)
                    .fill(Color.black)

                Group {
                    if center.activities.isEmpty {
                        idleContent
                            .transition(contentSwap)
                    } else if let id = center.expandedId,
                              let activity = center.activities.first(where: { $0.id == id }) {
                        expandedContent(for: activity)
                            .transition(openContentTransition)
                    } else {
                        collapsedInlineView
                            .transition(contentSwap)
                    }
                }
            }
            .frame(width: preferredWidth, height: preferredHeight, alignment: .top)
            // Hides the 1px seam at the very top edge.
            .overlay(alignment: .top) {
                Rectangle()
                    .fill(Color.black)
                    .frame(height: 1)
                    .padding(.horizontal, backdropTop)
            }
            .clipShape(HaloSurfaceShape(topRadius: backdropTop, bottomRadius: backdropBottom))
            .shadow(color: isOpen ? .black.opacity(0.7) : .clear,
                    radius: 6, x: 0, y: 0)
            // Inner breathing room when open, edge-to-edge when closed.
            .padding(.horizontal, isOpen ? 0 : 0)
            .padding([.horizontal, .bottom], isOpen ? 12 : 0)
            .background(Color.black)
            .clipShape(HaloSurfaceShape(topRadius: backdropTop, bottomRadius: backdropBottom))
            .shadow(color: isOpen ? .black.opacity(0.7) : .clear, radius: 6)
        }
        .padding(.bottom, 8)
        // Fill the fixed window, top-anchored: the window never resizes, so
        // this frame is pure layout with no feedback loop.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .compositingGroup()
        // The whole halo is hittable (clicks, right-click menu) — without
        // this, transparent regions (spacers, padding) let clicks fall
        // through to whatever is behind the haloController.
        .contentShape(HaloSurfaceShape(topRadius: backdropTop, bottomRadius: backdropBottom))
        .contextMenu {
            Button("Now Playing") { actions.showNowPlaying() }
            Button("Charging") { actions.showCharging() }
            Button("Notification") { actions.showNotification() }
            Button("Weather Card") { actions.showWeather() }
            Button("Focus Card") { actions.showFocus() }
            Button("Calendar") { actions.showCalendar() }
            Button("Codex · Developer activity") { actions.showCodex() }
            Button("OpenCode · Developer activity") { actions.showOpenCode() }
            Button("Claude Code · Developer activity") { actions.showClaudeCode() }
            Divider()
            Button("Pill · Music") { actions.previewPillMusic() }
            Button("Pill · Weather") { actions.previewPillWeather() }
            Button("Pill · Charging") { actions.previewPillCharging() }
            Button("Pill · Notify") { actions.previewPillNotify() }
            Button("Pill · Focus") { actions.previewPillFocus() }
            Button("Pill · Calendar") { actions.previewPillCalendar() }
            Divider()
            Button("Expand") { actions.expandTop() }
            Button("Dismiss All") { actions.dismissAll() }
            Divider()
            Button("Settings…") { actions.openSettings() }
            Button("Quit Halo") { actions.quit() }
        }
        .preferredColorScheme(.dark)
        // Bouncy open, critically damped close.
        .animation(motionReduced ? nil : morphSpring, value: center.expandedId)
        .animation(motionReduced ? nil : .smooth, value: center.activities.count)
    }

    private var preferredWidth: CGFloat {
        if isOpen { return expandedWidth }
        if center.activities.isEmpty { return topSurfacePillWidth }
        // Elongated pill while live: the topSurface visibly stretches the
        // moment a song starts (~185 -> ~245), then morphs to the card.
        return topSurfacePillWidth + 60
    }

    private var preferredHeight: CGFloat {
        if isOpen { return expandedHeight }
        return topSurfacePillHeight
    }

    /// Fast content crossfade. The backdrop morphs at spring speed while
    /// content swaps underneath it quickly, so nothing smears or slides.
    private var contentSwap: AnyTransition {
        motionReduced ? .opacity : .opacity.animation(.easeOut(duration: 0.12))
    }

    private var openContentTransition: AnyTransition {
        if motionReduced {
            return .opacity
        }
        return .scale(scale: 0.8, anchor: .top).combined(with: .opacity)
            .animation(.smooth(duration: 0.35))
    }

    private var backdropTop: CGFloat { isOpen ? haloRadiiOpen.top : haloRadiiClosed.top }
    private var backdropBottom: CGFloat { isOpen ? haloRadiiOpen.bottom : haloRadiiClosed.bottom }

    // MARK: Idle

    private var idleContent: some View {
        HStack(spacing: 6) {
            Image(systemName: "circle.dashed.inset.filled")
                .foregroundColor(.white.opacity(0.9))
                .font(.system(size: 11, weight: .semibold))
            Text("Halo")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.white.opacity(0.9))
        }
        .frame(width: topSurfacePillWidth - 20, height: haloClosedHeight)
    }

    // MARK: Stack — single inline pill in collapsed mode

    private var collapsedInlineView: some View {
        HStack(spacing: 8) {
            // Both sides reflect the selected activity (same one tap-to-expand
            // opens), falling back to the highest-priority activity. Mixing
            // first/last shows e.g. music art with a battery % when several
            // activities are live.
            if let top = HaloPresentationPolicy.selectedActivity(
                center.activities,
                manualOverrideID: center.manualOverrideID
            ) {
                inlineLeading(for: top)
                Spacer(minLength: 0)
                inlineTrailing(for: top)
            }
        }
        .padding(.horizontal, 10)
        .frame(width: topSurfacePillWidth + 60, height: haloClosedHeight)
        .contentShape(Rectangle())
        .onTapGesture {
            if let selectedID = HaloPresentationPolicy.selectedActivityID(
                center.activities,
                manualOverrideID: center.manualOverrideID
            ) {
                center.toggleExpand(selectedID)
            }
        }
    }

    /// Real player app icon (Music/Spotify), no circle. Nil when the app
    /// can't be resolved — caller falls back to the generic dot.
    private func playerAppIcon(for appName: String, size: CGFloat) -> AnyView? {
        let bundleID: String
        switch appName {
        case "Spotify": bundleID = "com.spotify.client"
        default: bundleID = "com.apple.Music"
        }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        let img = NSWorkspace.shared.icon(forFile: url.path)
        guard let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        return AnyView(
            Image(decorative: cg, scale: 1.0)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: size, height: size)
                .clipShape(RoundedRectangle(cornerRadius: size * 0.22, style: .continuous))
        )
    }

    @ViewBuilder
    private func inlineLeading(for activity: HaloActivity) -> some View {
        switch activity {
        case .nowPlaying(let n):
            if settings.showArtwork, let data = n.artworkData, let img = NSImage(data: data) {
                Image(nsImage: img)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 20, height: 20)
                    .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
            } else {
                inlineDot(for: activity)
            }
        case .charging(let c) where c.isPluggedIn:
            Image(systemName: "bolt.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.green)
                .frame(width: 20, height: 20)
        case .focus(let f):
            focusGlyph(for: f, size: 20)
        case .calendar:
            inlineDot(for: activity)
        case .codex:
            OpenAIMarkView(size: 20)
        case .openCode:
            OpenCodeMarkView(size: 20)
        case .claudeCode:
            ClaudeMarkView(size: 20)
        default:
            inlineDot(for: activity)
        }
    }

    @ViewBuilder
    private func inlineTrailing(for activity: HaloActivity) -> some View {
        switch activity {
        case .nowPlaying(let n):
            SpectrumBars(playing: n.isPlaying)
                .frame(width: 24, height: 20)
        case .charging(let c):
            Text("\(Int((c.level * 100).rounded()))")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.white)
        case .weather(let w):
            Text("\(w.temperatureC)°")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.white)
        case .focus:
            // Battery number, no % — the moon lives on the left.
            if let level = center.batteryLevel {
                Text("\(Int((level * 100).rounded()))")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.white)
            } else {
                inlineDot(for: activity)
            }
        case .calendar(let c):
            if let next = c.nextItem {
                TimelineView(.periodic(from: Date(), by: 60)) { context in
                    Text(CalendarMonitor.compactStatus(for: next, now: context.date))
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.white)
                        .lineLimit(1)
                        .frame(width: 30, alignment: .trailing)
                }
            } else {
                inlineDot(for: activity)
            }
        case .codex(let c):
            Text(c.compactLabel)
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundColor(.white)
                .lineLimit(1)
                .frame(width: 30, alignment: .trailing)
        case .openCode(let c):
            Text(c.compactLabel)
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundColor(.white)
                .lineLimit(1)
                .frame(width: 30, alignment: .trailing)
        case .claudeCode(let c):
            Text(c.compactLabel)
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundColor(.white)
                .lineLimit(1)
                .frame(width: 30, alignment: .trailing)
        default:
            inlineDot(for: activity)
        }
    }

    /// Live focus-mode glyph: SF symbol when valid, raw emoji/text when the
    /// mode uses a custom icon. Always 1:1 with the system mode.
    private func focusGlyph(for activity: FocusActivity, size: CGFloat) -> some View {
        Group {
            if FocusMonitor.isSFSymbol(activity.symbol) {
                Image(systemName: activity.symbol)
                    .font(.system(size: size * 0.5, weight: .semibold))
                    .foregroundColor(.white)
            } else {
                Text(activity.symbol)
                    .font(.system(size: size * 0.6))
            }
        }
        .frame(width: size, height: size)
    }

    private func inlineDot(for activity: HaloActivity) -> some View {
        // Real app icon wins over the generic dot (notifications).
        if case .notification(let n) = activity,
           let data = n.appIconData, let img = NSImage(data: data) {
            return AnyView(
                Image(nsImage: img)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 20, height: 20)
                    .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
            )
        }
        let (iconName, color) = iconSpec(for: activity)
        return AnyView(ZStack {
            Circle().fill(color.opacity(0.95)).frame(width: 18, height: 18)
            Image(systemName: iconName)
                .foregroundColor(.white)
                .font(.system(size: 9, weight: .bold))
        }
        .frame(width: 20, height: 20))
    }

    private func smallSplitPill(for activity: HaloActivity) -> some View {
        inlineDot(for: activity)
    }

    // MARK: Live EQ mark for the collapsed pill

    // MARK: Expanded

    private func expandedContent(for activity: HaloActivity) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            header(for: activity)
                .frame(height: max(24, haloClosedHeight))
            content(for: activity)
                .padding(.top, 10)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20)
        .padding(.top, 8)
        .padding(.bottom, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private func header(for activity: HaloActivity) -> some View {
        HStack(alignment: .center, spacing: 8) {
            icon(for: activity, size: 26)
            Text(title(for: activity))
                .font(.headline)
                .foregroundColor(.white)
            Spacer()
            Button {
                actions.openSettings()
            } label: {
                Image(systemName: "gearshape.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.white.opacity(0.62))
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Open Halo Settings")
            .accessibilityLabel("Open Halo Settings")
        }
    }

    @ViewBuilder
    private func content(for activity: HaloActivity) -> some View {
        switch activity {
        case .nowPlaying(let n): NowPlayingExpandedView(
            activity: n,
            onPlayPause: { center.onPlayPause?() },
            onNext: { center.onNextTrack?() },
            onPrevious: { center.onPreviousTrack?() },
            onSeek: { [weak center] seconds in
                // Jump locally for instant feedback; monitor corrects drift.
                center?.updateNowPlayingProgress(elapsed: seconds, duration: n.duration, isPlaying: n.isPlaying)
                center?.onSeek?(seconds)
            },
            onPlayQueued: { center.onPlayQueued?($0) },
            onReplay: { [weak center] track in
                NSLog("[Halo] ui: replay tapped: %@", track.title)
                center?.onReplayRecent?(track)
            }
        )
        case .charging(let c): ChargingExpandedView(activity: c)
        case .notification(let n): NotificationExpandedView(activity: n)
        case .focus(let f): FocusExpandedView(activity: f)
        case .weather(let w): WeatherExpandedView(activity: w)
        case .calendar(let c): CalendarExpandedView(
            activity: c,
            onOpenItem: { [weak center] item in
                center?.onOpenCalendarItem?(item)
            },
            onCompleteReminder: { [weak center] id in
                NSLog("[Halo] ui: complete reminder tapped: %@", id)
                center?.onCompleteReminder?(id)
            },
            onOpenLocation: { [weak center] location in
                center?.onOpenCalendarLocation?(location)
            },
            onOpenURL: { [weak center] url in
                center?.onOpenCalendarURL?(url)
            }
        )
        case .codex(let c): CodexExpandedView(
            activity: c,
            showWorkActivity: settings.showCodexWorkActivity,
            onSelectChat: { [weak center] id in center?.onSelectCodexChat?(id) },
            onNewChat: { [weak center] in center?.onNewCodexChat?() },
            onRefresh: { [weak center] in center?.onRefreshCodex?() },
            onSend: { [weak center] text in center?.onSendCodex?(text) },
            onInterrupt: { [weak center] in center?.onInterruptCodex?() },
            onResolveApproval: { [weak center] decision in center?.onResolveCodexApproval?(decision) }
        )
        case .openCode(let c): OpenCodeExpandedView(
            activity: c,
            showWorkActivity: settings.showOpenCodeWorkActivity,
            onSelectSession: { [weak center] id in center?.onSelectOpenCodeSession?(id) },
            onNewSession: { [weak center] in center?.onNewOpenCodeSession?() },
            onRefresh: { [weak center] in center?.onRefreshOpenCode?() },
            onSend: { [weak center] text in center?.onSendOpenCode?(text) },
            onInterrupt: { [weak center] in center?.onInterruptOpenCode?() },
            onResolvePermission: { [weak center] decision in center?.onResolveOpenCodePermission?(decision) }
        )
        case .claudeCode(let c): ClaudeCodeExpandedView(
            activity: c,
            showWorkActivity: settings.showClaudeCodeWorkActivity,
            onSelectSession: { [weak center] id in center?.onSelectClaudeCodeSession?(id) },
            onNewSession: { [weak center] in center?.onNewClaudeCodeSession?() },
            onRefresh: { [weak center] in center?.onRefreshClaudeCode?() },
            onSend: { [weak center] text in center?.onSendClaudeCode?(text) },
            onInterrupt: { [weak center] in center?.onInterruptClaudeCode?() }
        )
        }
    }

    // MARK: Shared

    @ViewBuilder
    private func icon(for activity: HaloActivity, size: CGFloat) -> some View {
        if case .nowPlaying(let n) = activity, let img = playerAppIcon(for: n.appName, size: size) {
            img
        } else if case .focus(let f) = activity, !FocusMonitor.isSFSymbol(f.symbol) {
            ZStack {
                Circle().fill(Color.indigo.opacity(0.95)).frame(width: size, height: size)
                Text(f.symbol).font(.system(size: size * 0.55))
            }
        } else if case .notification(let n) = activity,
                  let data = n.appIconData, let img = NSImage(data: data) {
            Image(nsImage: img)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: size, height: size)
                .clipShape(RoundedRectangle(cornerRadius: size * 0.25, style: .continuous))
        } else if case .codex = activity {
            OpenAIMarkView(size: size)
        } else if case .openCode = activity {
            OpenCodeMarkView(size: size)
        } else if case .claudeCode = activity {
            ClaudeMarkView(size: size)
        } else {
            let (name, color) = iconSpec(for: activity)
            ZStack {
                Circle().fill(color.opacity(0.95)).frame(width: size, height: size)
                Image(systemName: name)
                    .foregroundColor(.white)
                    .font(.system(size: size * 0.45, weight: .bold))
            }
        }
    }

    private func iconSpec(for activity: HaloActivity) -> (String, Color) {
        switch activity {
        case .nowPlaying: return ("music.note", .pink)
        case .charging: return ("bolt.fill", .green)
        case .notification: return ("message.fill", .purple)
        case .focus(let f): return (FocusMonitor.isSFSymbol(f.symbol) ? f.symbol : "moon.fill", .indigo)
        case .weather(let w): return (w.symbol, .blue)
        case .calendar: return ("calendar", .orange)
        case .codex: return ("terminal.fill", .gray)
        case .openCode: return ("chevron.left.forwardslash.chevron.right", .gray)
        case .claudeCode: return ("circle.fill", .orange)
        }
    }

    private func title(for activity: HaloActivity) -> String {
        switch activity {
        case .nowPlaying: return "Now Playing"
        case .charging: return "Battery"
        case .notification(let n): return n.appName
        case .focus(let f): return f.mode
        case .weather: return "Weather"
        case .calendar: return "Calendar"
        case .codex: return "Codex"
        case .openCode: return "OpenCode"
        case .claudeCode: return "Claude Code"
        }
    }

    @ViewBuilder
    private func text(for activity: HaloActivity, expanded: Bool, size: CGFloat) -> some View {
        switch activity {
        case .nowPlaying(let n): Text(n.title).font(.system(size: size, weight: .semibold))
        case .charging(let c): Text(expanded ? "Charging" : "\(Int((c.level * 100).rounded()))%").font(.system(size: size, weight: .semibold))
        case .notification(let n): Text(n.sender).font(.system(size: size, weight: .semibold))
        case .focus(let f): Text(f.mode).font(.system(size: size, weight: .semibold))
        case .weather(let w): Text(w.condition).font(.system(size: size, weight: .semibold))
        case .calendar(let c): Text(c.nextItem?.title ?? "Calendar").font(.system(size: size, weight: .semibold))
        case .codex(let c): Text(c.selectedChat?.title ?? "Codex").font(.system(size: size, weight: .semibold))
        case .openCode(let c): Text(c.selectedSession?.title ?? "OpenCode").font(.system(size: size, weight: .semibold))
        case .claudeCode(let c): Text(c.selectedSession?.title ?? "Claude Code").font(.system(size: size, weight: .semibold))
        }
    }

    private func timeString(seconds: Int) -> String {
        let m = seconds / 60
        let s = seconds % 60
        return String(format: "%02d:%02d", m, s)
    }
}

// MARK: - Per-activity expanded views

struct NowPlayingExpandedView: View {
    let activity: NowPlayingActivity
    var onPlayPause: () -> Void = {}
    var onNext: () -> Void = {}
    var onPrevious: () -> Void = {}
    var onSeek: (TimeInterval) -> Void = { _ in }
    var onPlayQueued: (UpNextItem) -> Void = { _ in }
    var onReplay: (PlaybackHistoryMonitor.Track) -> Void = { _ in }
    @State private var dragFraction: Double?
    @ObservedObject private var settings = HaloSettings.shared

    /// Elapsed shown while dragging (instant feedback), else live value.
    private var shownElapsed: TimeInterval {
        if let f = dragFraction { return f * activity.duration }
        return activity.elapsed
    }
    private var shownProgress: Double {
        guard activity.duration > 0 else { return 0 }
        return min(1, max(0, shownElapsed / activity.duration))
    }

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            if settings.showArtwork {
                artwork
                    .frame(width: 90, height: 90)
                    .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(activity.title)
                    .font(.system(size: 15, weight: .bold))
                    .foregroundColor(.white)
                    .lineLimit(1)
                if !activity.artist.isEmpty {
                    Text(activity.artist)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.white.opacity(0.7))
                        .lineLimit(1)
                }
                if activity.duration > 0 {
                    HStack(spacing: 6) {
                        Text(timeString(seconds: Int(shownElapsed)))
                            .font(.system(size: 10, weight: .medium, design: .monospaced))
                            .foregroundColor(.white.opacity(0.6))
                        SeekBar(progress: shownProgress, tint: .red,
                                onScrub: { f in dragFraction = f },
                                onRelease: { f in
                                    NSLog("[Halo] ui: seek to %.1fs", f * activity.duration)
                                    onSeek(f * activity.duration)
                                    dragFraction = nil
                                })
                            .frame(height: 14)
                        Text("-" + timeString(seconds: Int(max(0, activity.duration - shownElapsed))))
                            .font(.system(size: 10, weight: .medium, design: .monospaced))
                            .foregroundColor(.white.opacity(0.6))
                    }
                }
                HStack(spacing: 18) {
                    TransportButton(systemImage: "backward.fill", size: 13) {
                        NSLog("[Halo] ui: previous tapped")
                        onPrevious()
                    }
                    TransportButton(systemImage: activity.isPlaying ? "pause.fill" : "play.fill", size: 15, prominent: true) {
                        NSLog("[Halo] ui: playpause tapped")
                        onPlayPause()
                    }
                    TransportButton(systemImage: "forward.fill", size: 13) {
                        NSLog("[Halo] ui: next tapped")
                        onNext()
                    }
                }
                .padding(.top, 2)
            }
            if settings.showUpNext && !activity.upNext.isEmpty {
                upNextRail
            } else if settings.showRecentlyPlayed && !activity.recent.isEmpty {
                recentRail
            } else {
                Spacer(minLength: 0)
            }
        }
    }

    /// Up Next rail tile: real thumbnail when downloaded, dark note tile
    /// while the playlist artwork read is pending or unavailable.
    private func upNextTile(for item: UpNextItem) -> some View {
        Group {
            if let data = item.artData, let img = NSImage(data: data) {
                Image(nsImage: img)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                LinearGradient(colors: [.white.opacity(0.10), .white.opacity(0.04)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                    .overlay(
                        Image(systemName: "music.note")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(.white.opacity(0.5))
                    )
            }
        }
        .frame(width: 36, height: 36)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
    private var upNextRail: some View {
        HStack(spacing: 0) {
            Spacer(minLength: 0)
            Rectangle()
                .fill(Color.white.opacity(0.12))
                .frame(width: 1)
                .padding(.vertical, 4)
            VStack(alignment: .leading, spacing: 0) {
                Text("UP NEXT")
                    .font(.system(size: 10, weight: .bold))
                    .tracking(1.5)
                    .foregroundColor(.white.opacity(0.5))
                    .padding(.bottom, 8)
                ForEach(Array(activity.upNext.prefix(3).enumerated()), id: \.offset) { _, item in
                    HStack(spacing: 8) {
                        upNextTile(for: item)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(item.title)
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundColor(.white)
                                .lineLimit(1)
                            Text(item.artist)
                                .font(.system(size: 11, weight: .regular))
                                .foregroundColor(.white.opacity(0.55))
                                .lineLimit(1)
                        }
                    }
                    .padding(.bottom, 8)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        NSLog("[Halo] ui: queue tap %@", item.title)
                        onPlayQueued(item)
                    }
                }
                Spacer(minLength: 0)
            }
            .frame(width: 200, alignment: .leading)
            .padding(.leading, 14)
        }
    }

    /// Fallback rail when the queue is hidden (catalog/autoplay playback):
    /// recent plays from Music's session archives, tap to replay.
    private var recentRail: some View {
        HStack(spacing: 0) {
            Spacer(minLength: 0)
            Rectangle()
                .fill(Color.white.opacity(0.12))
                .frame(width: 1)
                .padding(.vertical, 4)
            VStack(alignment: .leading, spacing: 0) {
                Text("PLAYED RECENTLY")
                    .font(.system(size: 10, weight: .bold))
                    .tracking(1.5)
                    .foregroundColor(.white.opacity(0.5))
                    .padding(.bottom, 8)
                ForEach(Array(activity.recent.prefix(3).enumerated()), id: \.offset) { _, item in
                    Button(action: { onReplay(item) }) {
                        HStack(alignment: .center, spacing: 8) {
                            recentArtwork(for: item)
                                .frame(width: 36, height: 36)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(item.title)
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundColor(.white)
                                    .lineLimit(1)
                                    .multilineTextAlignment(.leading)
                                Text(item.artist)
                                    .font(.system(size: 11, weight: .regular))
                                    .foregroundColor(.white.opacity(0.55))
                                    .lineLimit(1)
                                    .multilineTextAlignment(.leading)
                            }
                        }
                        .padding(.bottom, 8)
                    }
                    .buttonStyle(.plain)
                }
                Spacer(minLength: 0)
            }
            .frame(width: 200, alignment: .leading)
            .padding(.leading, 14)
        }
    }

    /// 36pt album art for a history row: CDN thumb when downloaded,
    /// soft gradient note placeholder while it loads / when absent.
    @ViewBuilder
    private func recentArtwork(for item: PlaybackHistoryMonitor.Track) -> some View {
        if let data = item.artworkData, let img = NSImage(data: data) {
            Image(nsImage: img)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: 36, height: 36)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        } else {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(LinearGradient(colors: [.gray.opacity(0.6), .gray.opacity(0.25)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
                .overlay(
                    Image(systemName: "music.note")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.white.opacity(0.6))
                )
        }
    }

    @ViewBuilder
    private var artwork: some View {
        if let data = activity.artworkData, let img = NSImage(data: data) {
            Image(nsImage: img).resizable().aspectRatio(contentMode: .fill)
        } else {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(
                    LinearGradient(colors: [.pink.opacity(0.85), .purple.opacity(0.85)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing)
                )
                .overlay(
                    Image(systemName: "music.note")
                        .font(.system(size: 22, weight: .bold))
                        .foregroundColor(.white)
                )
        }
    }

    private func timeString(seconds: Int) -> String {
        let m = seconds / 60
        let s = seconds % 60
        return String(format: "%d:%02d", m, s)
    }
}

/// Live EQ mark: 4 bars bouncing while playing, flat when paused.
enum SpectrumBarsMode: Equatable {
    case animated
    case still
}

struct SpectrumBars: View {
    let playing: Bool

    /// Playback-state contract used by the view and its regression tests.
    static func mode(for playing: Bool) -> SpectrumBarsMode {
        playing ? .animated : .still
    }

    var body: some View {
        if Self.mode(for: playing) == .animated {
            AnimatedSpectrumBars()
        } else {
            StaticSpectrumBars()
        }
    }
}

/// Kept as a separate view so removing it when playback pauses also tears
/// down the repeat-forever animation state.
private struct AnimatedSpectrumBars: View {
    @State private var phase = false

    private let baseHeights: [CGFloat] = [12, 7, 10, 6]
    private let peakHeights: [CGFloat] = [6, 13, 7, 12]

    var body: some View {
        HStack(spacing: 2.5) {
            ForEach(0..<4, id: \.self) { i in
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(Color.white.opacity(0.9))
                    .frame(width: 3, height: phase ? peakHeights[i] : baseHeights[i])
            }
        }
        .animation(.easeInOut(duration: 0.45).repeatForever(autoreverses: true), value: phase)
        .onAppear { phase = true }
    }
}

/// Paused state has no animated state or animation modifier at all.
private struct StaticSpectrumBars: View {
    var body: some View {
        HStack(spacing: 2.5) {
            ForEach(0..<4, id: \.self) { _ in
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(Color.white.opacity(0.35))
                    .frame(width: 3, height: 5)
            }
        }
    }
}

struct TransportButton: View {    let systemImage: String
    let size: CGFloat
    var prominent: Bool = false
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: size, weight: .semibold))
                .foregroundColor(prominent ? .white : .white.opacity(0.85))
                .frame(width: 32, height: 32)
                .background(Circle().fill(Color.white.opacity(hovering ? 0.15 : 0)))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

struct ChargingExpandedView: View {
    let activity: ChargingActivity

    var body: some View {
        HStack(spacing: 18) {
            BatteryRing(level: activity.level, isCharging: activity.isPluggedIn)
                .frame(width: 64, height: 64)
            VStack(alignment: .leading, spacing: 4) {
                Text("\(Int(activity.level * 100))%")
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                    .foregroundColor(.white)
                    .monospacedDigit()
                Text(activity.isPluggedIn ? "Charging now" : "On battery")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.white.opacity(0.7))
                if activity.isPluggedIn, let eta = activity.timeRemainingText {
                    Text(eta)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.white.opacity(0.5))
                }
            }
            Spacer(minLength: 0)
        }
    }
}

struct NotificationExpandedView: View {
    let activity: NotificationActivity

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            if let data = activity.appIconData, let img = NSImage(data: data) {
                Image(nsImage: img)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 40, height: 40)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            } else {
                ZStack {
                    Circle()
                        .fill(LinearGradient(colors: [.purple, .pink],
                                             startPoint: .topLeading,
                                             endPoint: .bottomTrailing))
                        .frame(width: 40, height: 40)
                    Image(systemName: activity.icon)
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundColor(.white)
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(activity.sender)
                    .font(.system(size: 14, weight: .bold))
                    .foregroundColor(.white)
                Text(activity.body)
                    .font(.system(size: 12, weight: .regular))
                    .foregroundColor(.white.opacity(0.85))
                    .lineLimit(3)
            }
            Spacer(minLength: 0)
        }
    }
}

struct FocusExpandedView: View {
    let activity: FocusActivity

    var body: some View {
        HStack(spacing: 16) {
            ZStack {
                Circle()
                    .fill(LinearGradient(colors: [.indigo, .purple],
                                         startPoint: .topLeading,
                                         endPoint: .bottomTrailing))
                    .frame(width: 56, height: 56)
                if FocusMonitor.isSFSymbol(activity.symbol) {
                    Image(systemName: activity.symbol)
                        .font(.system(size: 24))
                        .foregroundColor(.white)
                } else {
                    Text(activity.symbol)
                        .font(.system(size: 28))
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(activity.mode)
                    .font(.system(size: 18, weight: .bold))
                    .foregroundColor(.white)
                Text("Notifications silenced")
                    .font(.system(size: 12))
                    .foregroundColor(.white.opacity(0.7))
            }
            Spacer(minLength: 0)
        }
    }
}

struct WeatherExpandedView: View {
    let activity: WeatherActivity

    var body: some View {
        HStack(spacing: 24) {
            // Left: big temp + condition, headline style — no gradient blob.
            VStack(alignment: .leading, spacing: 2) {
                Text("\(activity.temperatureC)°")
                    .font(.system(size: 56, weight: .light, design: .rounded))
                    .foregroundColor(.white)
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                Text(activity.condition)
                    .font(.headline)
                    .foregroundColor(.white.opacity(0.85))
                    .lineLimit(1)
                if let hi = activity.highC, let lo = activity.lowC {
                    Text("H:\(hi)°  L:\(lo)°")
                        .font(.subheadline)
                        .foregroundColor(.gray)
                } else if activity.windKph > 0 {
                    Text("Wind \(activity.windKph) km/h")
                        .font(.subheadline)
                        .foregroundColor(.gray)
                }
            }
            Spacer(minLength: 0)
            // Right: single monochrome glyph on a subtle well — fills the
            // wide card without the cheap blue-app-icon look.
            Image(systemName: activity.symbol)
                .font(.system(size: 52, weight: .thin))
                .foregroundColor(.white.opacity(0.92))
                .frame(width: 110, height: 110)
                .background(Color.white.opacity(0.07))
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(Color.white.opacity(0.08), lineWidth: 1)
                )
        }
        .frame(maxWidth: .infinity)
    }
}

struct CalendarExpandedView: View {
    let activity: CalendarActivity
    var onOpenItem: (CalendarItem) -> Void = { _ in }
    var onCompleteReminder: (String) -> Void = { _ in }
    var onOpenLocation: (String) -> Void = { _ in }
    var onOpenURL: (URL) -> Void = { _ in }
    @ObservedObject private var settings = HaloSettings.shared

    var body: some View {
        TimelineView(.periodic(from: Date(), by: 60)) { context in
            calendarContent(now: context.date)
        }
    }

    @ViewBuilder
    private func calendarContent(now: Date) -> some View {
        if let next = activity.nextItem {
            HStack(alignment: .top, spacing: 18) {
                upNextColumn(now: now)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

                Rectangle()
                    .fill(Color.white.opacity(0.12))
                    .frame(width: 1)

                nextItemColumn(next, now: now)
                    .frame(width: 245, alignment: .topLeading)
                    .frame(maxHeight: .infinity, alignment: .topLeading)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        } else {
            Text("No upcoming events or reminders")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.white.opacity(0.65))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        }
    }

    private var upNextItems: [CalendarItem] {
        Array(activity.items.dropFirst())
    }

    @ViewBuilder
    private func upNextColumn(now: Date) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionLabel("UP NEXT")

            if upNextItems.isEmpty {
                Text("Nothing else scheduled")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.white.opacity(0.38))
                    .frame(maxHeight: .infinity, alignment: .topLeading)
            } else {
                HaloScrollView(
                    items: CalendarMonitor.groupedByDate(upNextItems)
                ) { group in
                    VStack(alignment: .leading, spacing: 8) {
                        if let label = CalendarMonitor.dateGroupLabel(for: group.date, relativeTo: now) {
                            Text(label)
                                .font(.system(size: 10, weight: .bold))
                                .tracking(1.2)
                                .foregroundColor(.white.opacity(0.48))
                                .padding(.top, 8)
                                .overlay(alignment: .top) {
                                    Rectangle()
                                        .fill(Color.white.opacity(0.12))
                                        .frame(height: 1)
                                }
                        }

                        ForEach(group.items) { item in
                            calendarRow(item, now: now)
                        }
                    }
                }
            }
        }
    }

    private func nextItemColumn(_ item: CalendarItem, now: Date) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionLabel("NEXT")

            Text(CalendarMonitor.compactStatus(for: item, now: now))
                .font(.system(size: 31, weight: .bold))
                .foregroundColor(item.isReminder ? .orange : .white)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .padding(.top, 1)

            Button {
                onOpenItem(item)
            } label: {
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.title)
                        .font(.system(size: 16, weight: .bold))
                        .foregroundColor(.white)
                        .lineLimit(1)
                        .truncationMode(.tail)

                    HStack(spacing: 5) {
                        Text(settings.calendarShowDuration
                             ? CalendarMonitor.exactTimeRange(for: item, now: now)
                             : CalendarMonitor.exactTime(for: item, now: now))
                            .lineLimit(1)
                        if !item.calendarName.isEmpty {
                            Text("·")
                            Text(item.calendarName)
                                .lineLimit(1)
                        }
                    }
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.white.opacity(0.58))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(item.isReminder ? "Open exact reminder in Reminders" : "Open exact event in Calendar")
            .padding(.top, 6)

            if settings.calendarShowLocations,
               let location = item.location?.trimmingCharacters(in: .whitespacesAndNewlines),
               !location.isEmpty {
                HStack(spacing: 6) {
                    Button {
                        onOpenLocation(location)
                    } label: {
                        Label(location, systemImage: "mappin.and.ellipse")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(.white.opacity(0.5))
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                    .help("Open location in Maps")
                    .accessibilityLabel("Open \(location) in Maps")

                    if let url = CalendarMonitor.externalURL(for: item) {
                        Button {
                            onOpenURL(url)
                        } label: {
                            Image(systemName: "link")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundColor(.white.opacity(0.5))
                                .frame(width: 22, height: 22)
                        }
                        .buttonStyle(.plain)
                        .help("Open event link")
                        .accessibilityLabel("Open event link")
                    }
                }
                .padding(.top, 2)
            } else if let url = CalendarMonitor.externalURL(for: item) {
                Button {
                    onOpenURL(url)
                } label: {
                    Label("Open link", systemImage: "link")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.white.opacity(0.5))
                }
                .buttonStyle(.plain)
                .help("Open event link")
                .padding(.top, 2)
            }
        }
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .bold))
            .tracking(1.5)
            .foregroundColor(.white.opacity(0.5))
    }

    private func calendarRow(_ item: CalendarItem, now: Date) -> some View {
        HStack(spacing: 10) {
            Button {
                onOpenItem(item)
            } label: {
                HStack(spacing: 10) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(item.isReminder ? Color.orange.opacity(0.18) : Color.blue.opacity(0.18))
                            .frame(width: 30, height: 30)
                        Image(systemName: item.isReminder ? "checklist" : "calendar")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(item.isReminder ? .orange : .blue)
                    }

                    VStack(alignment: .leading, spacing: 1) {
                        Text(item.title)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(.white)
                            .lineLimit(1)
                        HStack(spacing: 5) {
                            Text(settings.calendarShowDuration
                                 ? CalendarMonitor.timeRange(for: item)
                                 : CalendarMonitor.timeOnly(for: item))
                            if !item.calendarName.isEmpty {
                                Text("·")
                                Text(item.calendarName)
                                    .lineLimit(1)
                            }
                        }
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.white.opacity(0.55))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(item.isReminder ? "Open exact reminder in Reminders" : "Open exact event in Calendar")

            if settings.calendarShowLocations,
               let location = item.location?.trimmingCharacters(in: .whitespacesAndNewlines),
               !location.isEmpty {
                Button {
                    onOpenLocation(location)
                } label: {
                    Label(location, systemImage: "mappin.and.ellipse")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.white.opacity(0.5))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: 105, alignment: .trailing)
                }
                .buttonStyle(.plain)
                .help("Open location in Maps")
                .accessibilityLabel("Open \(location) in Maps")
            }

            if item.isReminder {
                if item.startDate < now {
                    Text("DUE")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(.orange)
                }

                Button {
                    onCompleteReminder(item.id)
                } label: {
                    Image(systemName: "circle")
                        .font(.system(size: 20, weight: .regular))
                        .foregroundColor(.white.opacity(0.75))
                        .frame(width: 30, height: 30)
                }
                .buttonStyle(.plain)
                .help("Complete reminder")
                .accessibilityLabel("Complete reminder \(item.title)")
            }
        }
        .frame(height: 30)
        .accessibilityElement(children: .contain)
    }
}

// MARK: - Widgets

struct ProgressBar: View {
    let progress: Double
    var tint: Color = .white

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.white.opacity(0.15))
                Capsule()
                    .fill(tint)
                    .frame(width: max(0, min(1, progress)) * geo.size.width)
                    .animation(.spring(response: 0.3, dampingFraction: 1.0), value: progress)
            }
        }
    }
}

/// Scrubbable progress bar: thick invisible hit lane, visible 4px track.
/// Knob appears while hovering so it reads interactive, not decorative.
struct SeekBar: View {
    let progress: Double
    var tint: Color = .white
    var onScrub: (Double) -> Void = { _ in }
    var onRelease: (Double) -> Void = { _ in }
    @State private var hovering = false

    var body: some View {
        GeometryReader { geo in
            let w = max(0, min(1, progress)) * geo.size.width
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.white.opacity(hovering ? 0.25 : 0.15))
                    .frame(height: 4)
                    .frame(maxHeight: .infinity)
                Capsule()
                    .fill(tint)
                    .frame(width: w, height: 4)
                    .animation(.spring(response: 0.3, dampingFraction: 1.0), value: progress)
                Circle()
                    .fill(tint)
                    .frame(width: 10, height: 10)
                    .offset(x: max(0, w - 5))
                    .opacity(hovering ? 1 : 0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        guard geo.size.width > 0 else { return }
                        onScrub(min(1, max(0, value.location.x / geo.size.width)))
                    }
                    .onEnded { value in
                        guard geo.size.width > 0 else { return }
                        onRelease(min(1, max(0, value.location.x / geo.size.width)))
                    }
            )
        }
        .onHover { hovering = $0 }
    }
}

struct CapsuleButton: View {
    let title: String
    let systemImage: String
    let action: () -> Void
    @State private var pressed = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: systemImage)
                Text(title)
            }
            .font(.system(size: 11, weight: .semibold))
            .foregroundColor(.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(
                Capsule().fill(Color.white.opacity(pressed ? 0.20 : 0.12))
            )
            .overlay(
                Capsule().stroke(Color.white.opacity(0.10), lineWidth: 0.5)
            )
            .scaleEffect(pressed ? 0.96 : 1.0)
        }
        .buttonStyle(PressableButtonStyle(pressed: $pressed))
    }
}

struct PressableButtonStyle: ButtonStyle {
    @Binding var pressed: Bool
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .onChange(of: configuration.isPressed) { _, new in
                withAnimation(.spring(response: 0.18, dampingFraction: 1.0)) {
                    pressed = new
                }
            }
    }
}

struct BatteryRing: View {
    let level: Double
    let isCharging: Bool

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.white.opacity(0.12), lineWidth: 6)
            Circle()
                .trim(from: 0, to: max(0.02, level))
                .stroke(
                    LinearGradient(colors: isCharging ? [.green, .mint] : [.green, .yellow],
                                   startPoint: .top, endPoint: .bottom),
                    style: StrokeStyle(lineWidth: 6, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
                .animation(.spring(response: 0.4, dampingFraction: 0.85), value: level)
            VStack(spacing: -2) {
                Text("\(Int(level * 100))%")
                    .font(.system(size: 16, weight: .bold, design: .rounded))
                    .foregroundColor(.white)
                if isCharging {
                    Image(systemName: "bolt.fill")
                        .font(.system(size: 10))
                        .foregroundColor(.green)
                }
            }
        }
    }
}

// MARK: - Shape

/// Camera-housing profile: nearly square top edge, fully round bottom.
/// Top and bottom radii interpolate, so the pill <-> card morph is smooth.
/// Shared geometry for collapsed and expanded Halo surfaces (6/14 closed, 19/24 open).
struct HaloSurfaceShape: Shape {
    var topRadius: CGFloat
    var bottomRadius: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(topRadius, bottomRadius) }
        set {
            topRadius = newValue.first
            bottomRadius = newValue.second
        }
    }

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let t = max(0, min(topRadius, rect.width / 2, rect.height / 2))
        let b = max(0, min(bottomRadius, rect.width / 2, rect.height / 2))
        // Start top-left, work clockwise with quadratic corners.
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addQuadCurve(
            to: CGPoint(x: rect.minX + t, y: rect.minY + t),
            control: CGPoint(x: rect.minX + t, y: rect.minY)
        )
        path.addLine(to: CGPoint(x: rect.minX + t, y: rect.maxY - b))
        path.addQuadCurve(
            to: CGPoint(x: rect.minX + t + b, y: rect.maxY),
            control: CGPoint(x: rect.minX + t, y: rect.maxY)
        )
        path.addLine(to: CGPoint(x: rect.maxX - t - b, y: rect.maxY))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX - t, y: rect.maxY - b),
            control: CGPoint(x: rect.maxX - t, y: rect.maxY)
        )
        path.addLine(to: CGPoint(x: rect.maxX - t, y: rect.minY + t))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX, y: rect.minY),
            control: CGPoint(x: rect.maxX - t, y: rect.minY)
        )
        path.closeSubpath()
        return path
    }
}
