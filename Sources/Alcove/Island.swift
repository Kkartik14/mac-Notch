import AppKit
import SwiftUI
import Combine

/// Morph timing: bouncy open, critically-damped close. SwiftUI owns all
/// motion now; the window never animates (Plan B).
private let islandOpenResponse = 0.42
private let islandOpenDamping: Double = 0.8
private let islandCloseResponse = 0.45
private let islandCloseDamping: Double = 1.0

/// Fixed window geometry (Plan B): the window never resizes or moves after
/// placement. 640 content + shadow room. All morphing is SwiftUI content
/// inside stationary glass — slide and lag have no mechanism left.
private let islandWindowSize = CGSize(width: 660, height: 210)

/// Container sizes for content inside the fixed window.
private let islandOpenSize = CGSize(width: 640, height: 190)
private let islandClosedFallbackWidth: CGFloat = 185
private let islandClosedHeight: CGFloat = 32
private let islandRadiiOpen = (top: CGFloat(19), bottom: CGFloat(24))
private let islandRadiiClosed = (top: CGFloat(6), bottom: CGFloat(14))

/// Closed pill width tracks the real camera housing when available.
func islandClosedWidth() -> CGFloat {
    guard let screen = NSScreen.main,
          let left = screen.auxiliaryTopLeftArea,
          let right = screen.auxiliaryTopRightArea,
          left.maxX < right.minX
    else { return islandClosedFallbackWidth }
    return screen.frame.width - left.width - right.width + 4
}

// MARK: - Activity types

enum IslandActivity: Equatable, Identifiable {
    case timer(TimerActivity)
    case nowPlaying(NowPlayingActivity)
    case charging(ChargingActivity)
    case notification(NotificationActivity)
    case focus(FocusActivity)
    case weather(WeatherActivity)

    var id: String {
        switch self {
        case .timer: return "timer"
        case .nowPlaying: return "nowPlaying"
        case .charging: return "charging"
        case .notification: return "notification"
        case .focus: return "focus"
        case .weather: return "weather"
        }
    }
}

struct TimerActivity: Equatable {
    var totalSeconds: Int
    var remainingSeconds: Int
    var endDate: Date?
    var label: String
    var isPaused: Bool = false

    init(seconds: Int, label: String = "Timer") {
        self.totalSeconds = seconds
        self.remainingSeconds = seconds
        self.label = label
    }

    var progress: Double {
        guard totalSeconds > 0 else { return 0 }
        return Double(totalSeconds - remainingSeconds) / Double(totalSeconds)
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

    var progress: Double {
        guard duration > 0 else { return 0 }
        return min(1, max(0, elapsed / duration))
    }
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

final class IslandCenter: ObservableObject {
    @Published var islands: [IslandActivity] = []
    @Published var expandedId: String?
    /// Latest battery fraction for pills that show it (focus trailing).
    @Published var batteryLevel: Double?
    var deliver: ((IslandActivity) -> Void)?

    /// Priority (higher = shows on top). Ambient order: music > focus >
    /// charging > weather. Timer countdown and transient notifications pin
    /// above — say so to change.
    static func rank(of activity: IslandActivity) -> Int {
        switch activity {
        case .notification: return 5
        case .timer: return 4
        case .nowPlaying: return 3
        case .focus: return 2
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

    private var autoDismissWorkItems: [String: DispatchWorkItem] = [:]
    private var collapseWorkItems: [String: DispatchWorkItem] = [:]
    private var tickTimer: Timer?

    deinit {
        tickTimer?.invalidate()
        autoDismissWorkItems.values.forEach { $0.cancel() }
        collapseWorkItems.values.forEach { $0.cancel() }
    }

    /// Tick while a live timer exists OR music is playing (for smooth
    /// second-by-second progress). Previously a 1Hz timer ran forever even
    /// when idle — a pointless wakeup 99% of the time.
    private func ensureTicking() {
        var needsTick = false
        for island in islands {
            switch island {
            case let .timer(t) where !t.isPaused && t.endDate != nil:
                needsTick = true
            case let .nowPlaying(n) where n.isPlaying && n.duration > 0:
                needsTick = true
            default:
                break
            }
            if needsTick { break }
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

    /// Present an activity. Passive monitor refreshes must pass `expand: false`
    /// so they never hijack the island; new user-visible events pass
    /// `expand: true` with `collapseAfter` so the card opens, then settles
    /// back to its pill while the activity stays live.
    func present(_ activity: IslandActivity, autoDismissAfter seconds: TimeInterval? = 8, expand: Bool = true, collapseAfter collapse: TimeInterval? = nil) {
        if let idx = islands.firstIndex(where: { $0.id == activity.id }) {
            islands[idx] = activity
        } else {
            // Ordered insert: higher rank sits closer to the top (end).
            let pos = islands.firstIndex { Self.rank(of: $0) > Self.rank(of: activity) } ?? islands.endIndex
            islands.insert(activity, at: pos)
            if islands.count > 4 { islands.removeFirst(islands.count - 4) }
        }
        if expand { expandedId = activity.id }
        autoDismissWorkItems[activity.id]?.cancel()
        autoDismissWorkItems.removeValue(forKey: activity.id)
        if let seconds {
            scheduleAutoDismiss(for: activity.id, after: seconds)
        }
        collapseWorkItems[activity.id]?.cancel()
        collapseWorkItems.removeValue(forKey: activity.id)
        if let collapse {
            let work = DispatchWorkItem { [weak self] in self?.collapse(activity.id) }
            collapseWorkItems[activity.id] = work
            DispatchQueue.main.asyncAfter(deadline: .now() + collapse, execute: work)
        }
        ensureTicking()
    }

    /// Collapse an expanded card back to its pill, keeping the activity live.
    func collapse(_ id: String) {
        collapseWorkItems[id]?.cancel()
        collapseWorkItems.removeValue(forKey: id)
        if expandedId == id { expandedId = nil }
    }

    func dismiss(_ id: String) {
        autoDismissWorkItems[id]?.cancel()
        autoDismissWorkItems.removeValue(forKey: id)
        collapseWorkItems[id]?.cancel()
        collapseWorkItems.removeValue(forKey: id)
        islands.removeAll { $0.id == id }
        if expandedId == id { expandedId = islands.last?.id }
        ensureTicking()
    }

    func dismissAll() {
        autoDismissWorkItems.values.forEach { $0.cancel() }
        autoDismissWorkItems.removeAll()
        collapseWorkItems.values.forEach { $0.cancel() }
        collapseWorkItems.removeAll()
        islands.removeAll()
        expandedId = nil
        ensureTicking()
    }

    func toggleExpand(_ id: String) {
        expandedId = (expandedId == id) ? nil : id
    }

    /// Pin an activity to the top regardless of rank (plug-in override).
    func moveToTop(_ id: String) {
        guard let idx = islands.firstIndex(where: { $0.id == id }) else { return }
        let a = islands.remove(at: idx)
        islands.append(a)
    }

    /// Restore rank order (stable: same-rank keeps current relative order).
    /// Used after a temporary override expires.
    func applyPriorityOrder() {
        islands = islands.enumerated()
            .sorted {
                let r0 = Self.rank(of: $0.element), r1 = Self.rank(of: $1.element)
                if r0 != r1 { return r0 < r1 }
                return $0.offset < $1.offset
            }
            .map(\.element)
        // If the expanded card is no longer on top, settle it to the top.
        if let exp = expandedId, islands.last?.id != exp {
            expandedId = islands.last?.id
        }
    }

    func toggleExpandTop() {
        guard let top = islands.last else { return }
        toggleExpand(top.id)
    }

    // MARK: Timer controls (device-clock based)

    /// Pause/resume the live timer. Resume re-anchors `endDate` to the device
    /// clock so the countdown stays accurate across pauses and sleep.
    func pauseResumeTimer() {
        guard let idx = islands.firstIndex(where: { $0.id == "timer" }),
              case var .timer(t) = islands[idx] else { return }
        if t.isPaused {
            t.isPaused = false
            t.endDate = Date().addingTimeInterval(TimeInterval(max(0, t.remainingSeconds)))
        } else {
            if let end = t.endDate {
                t.remainingSeconds = max(0, Int(end.timeIntervalSince(Date()).rounded(.up)))
            }
            t.isPaused = true
        }
        islands[idx] = .timer(t)
        ensureTicking()
    }

    func addMinuteToTimer() {
        guard let idx = islands.firstIndex(where: { $0.id == "timer" }),
              case var .timer(t) = islands[idx] else { return }
        t.totalSeconds += 60
        t.remainingSeconds += 60
        if !t.isPaused {
            t.endDate = (t.endDate ?? Date()).addingTimeInterval(60)
        }
        islands[idx] = .timer(t)
    }

    func cancelTimer() { dismiss("timer") }

    /// Cache the latest battery level for pills (focus trailing shows it).
    func updateBatteryLevel(_ level: Double) {
        if batteryLevel != level { batteryLevel = level }
    }

    /// Attach late-arriving artwork (e.g. downloaded URLs) without
    /// re-expanding or resetting the collapse timer.
    func updateNowPlayingArtwork(_ data: Data) {
        guard let idx = islands.firstIndex(where: { $0.id == "nowPlaying" }),
              case var .nowPlaying(n) = islands[idx] else { return }
        n.artworkData = data
        islands[idx] = .nowPlaying(n)
    }

    /// Silent progress correction from the monitor (3s poll). Updates the
    /// island's copy in place — never expands, never hijacks.
    func updateNowPlayingProgress(elapsed: TimeInterval, duration: TimeInterval, isPlaying: Bool) {
        guard let idx = islands.firstIndex(where: { $0.id == "nowPlaying" }),
              case var .nowPlaying(n) = islands[idx] else { return }
        // Ignore tiny jitter so the 1Hz local tick stays smooth.
        if abs(n.elapsed - elapsed) < 1.5 && n.duration == duration && n.isPlaying == isPlaying { return }
        n.elapsed = elapsed
        n.duration = duration
        n.isPlaying = isPlaying
        islands[idx] = .nowPlaying(n)
        ensureTicking()
    }

    private func scheduleAutoDismiss(for id: String, after seconds: TimeInterval) {
        autoDismissWorkItems[id]?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.dismiss(id) }
        autoDismissWorkItems[id] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    private func tick() {
        let now = Date()
        var toDismiss: String?
        for idx in islands.indices {
            switch islands[idx] {
            case var .timer(t) where !t.isPaused:
                guard let end = t.endDate else { continue }
                let remaining = max(0, Int(end.timeIntervalSince(now).rounded(.up)))
                if remaining != t.remainingSeconds {
                    t.remainingSeconds = remaining
                    islands[idx] = .timer(t)
                }
                if remaining == 0 { toDismiss = islands[idx].id }
            case var .nowPlaying(n) where n.isPlaying && n.duration > 0:
                // Local 1Hz interpolation so seconds + bar move smoothly
                // between the monitor's 3s corrections.
                let next = min(n.duration, n.elapsed + 1)
                if next != n.elapsed {
                    n.elapsed = next
                    islands[idx] = .nowPlaying(n)
                }
            default:
                break
            }
        }
        if let id = toDismiss { dismiss(id) }
    }
}

// MARK: - Window controller

final class IslandWindowController: NSObject {
    private var window: NSPanel?
    let center = IslandCenter()
    var actions = IslandActions()
    private var hoverWork: DispatchWorkItem?
    private var hoverOpenedId: String?
    private var hoverTimer: Timer?
    private var hoverInside = false
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
            if let id = center.expandedId, center.islands.contains(where: { $0.id == id }) { return true }
            return false
        }()
        let closedW = islandClosedWidth()
        let w: CGFloat = isOpen ? islandOpenSize.width : (center.islands.isEmpty ? closedW : closedW + 60)
        let h: CGFloat = isOpen ? islandOpenSize.height : islandClosedHeight
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
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: islandWindowSize.width, height: islandWindowSize.height),
            styleMask: [.borderless, .nonactivatingPanel, .utilityWindow, .hudWindow],
            backing: .buffered,
            defer: false
        )
        panel.title = "Alcove"
        // Above the menu bar but below screen-lock UI, like the reference.
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = false
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.ignoresMouseEvents = true // glass until proven shape (see below)
        panel.isReleasedWhenClosed = false
        panel.appearance = NSAppearance(named: .darkAqua)

        let host = NSHostingView(rootView: IslandView(center: center, actions: actions))
        host.autoresizingMask = [.width, .height]
        host.translatesAutoresizingMaskIntoConstraints = true
        host.frame = NSRect(x: 0, y: 0, width: islandWindowSize.width, height: islandWindowSize.height)
        host.wantsLayer = true
        host.layer?.backgroundColor = .clear
        panel.contentView = host
        host.menu = contextMenu

        positionInNotch(panel, width: islandWindowSize.width, height: islandWindowSize.height)
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
                self.positionInNotch(window, width: islandWindowSize.width, height: islandWindowSize.height)
                self.updateEventRouting()
            }
        }

        // 10Hz hover poll: mouse events are unreliable inside the notch
        // dead-zone, so hit-test the cursor position directly. Doubles as
        // the routing backstop (card opening under a parked cursor).
        hoverTimer?.invalidate()
        hoverTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            self?.pollHover()
        }
    }

    func show(_ activity: IslandActivity, autoDismissAfter seconds: TimeInterval? = 8, expand: Bool = true, collapseAfter collapse: TimeInterval? = nil) {
        center.present(activity, autoDismissAfter: seconds, expand: expand, collapseAfter: collapse)
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
                positionInNotch(window, width: islandWindowSize.width, height: islandWindowSize.height)
                return
            }
        }
        // No activities: nothing to hover-open. Skip mouseLocation work.
        if center.islands.isEmpty { return }
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
        if inside != hoverInside {
            hoverInside = inside
            if inside { hoverEntered() } else { hoverExited() }
        }
    }

    private func hoverEntered() {
        hoverWork?.cancel()
        hoverWork = nil
        guard !center.islands.isEmpty, center.expandedId == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let loc = NSEvent.mouseLocation
            let inHit = self.visibleContentRect().map { $0.contains(loc) } ?? false
            let moved = self.mouseMovedRecently(threshold: 4)
            guard self.center.expandedId == nil,
                  let top = self.center.islands.last,
                  inHit, moved else { return }
            NSLog("[Alcove] ui: hover-open %@", top.id)
            self.hoverOpenedId = top.id
            self.center.expandedId = top.id
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
        // Hover-away always settles the island: whatever is expanded
        // collapses shortly after the mouse leaves (re-enter cancels).
        // Track-change cards additionally settle on their own 3s timer.
        guard let id = center.expandedId else { return }
        let work = DispatchWorkItem { [weak self] in
            self?.center.collapse(id)
            self?.hoverOpenedId = nil
            self?.updateEventRouting()
        }
        hoverWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    private func notchInfo() -> (minX: CGFloat, maxX: CGFloat, menuBarHeight: CGFloat)? {
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

    private func positionInNotch(_ panel: NSPanel, width: CGFloat, height: CGFloat) {
        guard let notch = notchInfo(), let screen = NSScreen.main else { return }
        let frame = screen.frame
        let o = Self.islandOrigin(width: Double(width), height: Double(height),
                                  screenMidX: Double(frame.midX),
                                  menuBarHeight: Double(notch.menuBarHeight),
                                  screenMaxY: Double(frame.maxY))
        panel.setFrame(NSRect(x: o.x, y: o.y, width: width, height: height), display: true)
    }

    /// Pure positioning math: always centered on the screen axis with the top
    /// edge pinned to the screen top. One center for every size — the island
    /// can grow/shrink but its center mathematically cannot move.
    /// Separated for unit testing.
    static func islandOrigin(width w: Double, height h: Double,
                             screenMidX: Double, menuBarHeight: Double,
                             screenMaxY: Double) -> CGPoint {
        let x = screenMidX - w / 2
        let y = screenMaxY - menuBarHeight - (h - menuBarHeight)
        return CGPoint(x: x, y: y)
    }
}

// MARK: - SwiftUI view

/// Actions reachable from the island's right-click menu.
/// Wired by the app delegate; default no-ops keep previews/tests safe.
struct IslandActions {
    var showTimer: () -> Void = {}
    var showNowPlaying: () -> Void = {}
    var showCharging: () -> Void = {}
    var showNotification: () -> Void = {}
    var showWeather: () -> Void = {}
    var showFocus: () -> Void = {}
    var previewPillMusic: () -> Void = {}
    var previewPillWeather: () -> Void = {}
    var previewPillCharging: () -> Void = {}
    var previewPillTimer: () -> Void = {}
    var previewPillNotify: () -> Void = {}
    var previewPillFocus: () -> Void = {}
    var expandTop: () -> Void = {}
    var dismissAll: () -> Void = {}
    var openSettings: () -> Void = {}
    var quit: () -> Void = {}
}

struct IslandView: View {
    @ObservedObject var center: IslandCenter
    var actions: IslandActions = IslandActions()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    // Apple-accurate Dynamic Island dimensions.
    // Closed hugs the camera housing (dynamic, ~185pt on 14"); open is wide.
    private var notchPillWidth: CGFloat { islandClosedWidth() }
    private let notchPillHeight: CGFloat = 32
    private var expandedWidth: CGFloat { islandOpenSize.width }
    private var expandedHeight: CGFloat { islandOpenSize.height }

    private var isOpen: Bool {
        if let id = center.expandedId, center.islands.contains(where: { $0.id == id }) { return true }
        return false
    }

    private var openSpring: Animation {
        .spring(response: islandOpenResponse, dampingFraction: islandOpenDamping, blendDuration: 0)
    }
    private var closeSpring: Animation {
        .spring(response: islandCloseResponse, dampingFraction: islandCloseDamping, blendDuration: 0)
    }
    private var morphSpring: Animation { isOpen ? openSpring : closeSpring }

    var body: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .top) {
                // Opaque black pill — no blur/material, no outer stroke.
                NotchShape(topRadius: backdropTop, bottomRadius: backdropBottom)
                    .fill(Color.black)

                Group {
                    if center.islands.isEmpty {
                        idleContent
                            .transition(contentSwap)
                    } else if let id = center.expandedId,
                              let activity = center.islands.first(where: { $0.id == id }) {
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
            .clipShape(NotchShape(topRadius: backdropTop, bottomRadius: backdropBottom))
            .shadow(color: isOpen ? .black.opacity(0.7) : .clear,
                    radius: 6, x: 0, y: 0)
            // Inner breathing room when open, edge-to-edge when closed.
            .padding(.horizontal, isOpen ? 0 : 0)
            .padding([.horizontal, .bottom], isOpen ? 12 : 0)
            .background(Color.black)
            .clipShape(NotchShape(topRadius: backdropTop, bottomRadius: backdropBottom))
            .shadow(color: isOpen ? .black.opacity(0.7) : .clear, radius: 6)
        }
        .padding(.bottom, 8)
        // Fill the fixed window, top-anchored: the window never resizes, so
        // this frame is pure layout with no feedback loop.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .compositingGroup()
        // The whole island is hittable (clicks, right-click menu) — without
        // this, transparent regions (spacers, padding) let clicks fall
        // through to whatever is behind the island.
        .contentShape(NotchShape(topRadius: backdropTop, bottomRadius: backdropBottom))
        .contextMenu {
            Button("Timer · 60s") { actions.showTimer() }
            Button("Now Playing") { actions.showNowPlaying() }
            Button("Charging") { actions.showCharging() }
            Button("Notification") { actions.showNotification() }
            Button("Weather Card") { actions.showWeather() }
            Button("Focus Card") { actions.showFocus() }
            Divider()
            Button("Pill · Music") { actions.previewPillMusic() }
            Button("Pill · Weather") { actions.previewPillWeather() }
            Button("Pill · Charging") { actions.previewPillCharging() }
            Button("Pill · Timer") { actions.previewPillTimer() }
            Button("Pill · Notify") { actions.previewPillNotify() }
            Button("Pill · Focus") { actions.previewPillFocus() }
            Divider()
            Button("Expand") { actions.expandTop() }
            Button("Dismiss All") { actions.dismissAll() }
            Divider()
            Button("Settings…") { actions.openSettings() }
            Button("Quit Alcove") { actions.quit() }
        }
        .preferredColorScheme(.dark)
        // Bouncy open, critically-damped close — matches the reference feel.
        .animation(morphSpring, value: center.expandedId)
        .animation(.smooth, value: center.islands.count)
    }

    private var preferredWidth: CGFloat {
        if isOpen { return expandedWidth }
        if center.islands.isEmpty { return notchPillWidth }
        // Elongated pill while live: the notch visibly stretches the
        // moment a song starts (~185 -> ~245), then morphs to the card.
        return notchPillWidth + 60
    }

    private var preferredHeight: CGFloat {
        if isOpen { return expandedHeight }
        return notchPillHeight
    }

    /// Fast content crossfade. The backdrop morphs at spring speed while
    /// content swaps underneath it quickly, so nothing smears or slides.
    private var contentSwap: AnyTransition {
        .opacity.animation(.easeOut(duration: 0.12))
    }

    private var openContentTransition: AnyTransition {
        .scale(scale: 0.8, anchor: .top).combined(with: .opacity)
            .animation(.smooth(duration: 0.35))
    }

    private var backdropTop: CGFloat { isOpen ? islandRadiiOpen.top : islandRadiiClosed.top }
    private var backdropBottom: CGFloat { isOpen ? islandRadiiOpen.bottom : islandRadiiClosed.bottom }

    // MARK: Idle

    private var idleContent: some View {
        HStack(spacing: 6) {
            Image(systemName: "circle.dashed.inset.filled")
                .foregroundColor(.white.opacity(0.9))
                .font(.system(size: 11, weight: .semibold))
            Text("Alcove")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.white.opacity(0.9))
        }
        .frame(width: notchPillWidth - 20, height: islandClosedHeight)
    }

    // MARK: Stack — single inline pill like the reference closed notch

    private var collapsedInlineView: some View {
        HStack(spacing: 8) {
            // Both sides reflect the TOP activity (same one tap-to-expand
            // opens). Mixing first/last shows e.g. music art with a
            // battery % when several activities are live.
            if let top = center.islands.last {
                inlineLeading(for: top)
                Spacer(minLength: 0)
                inlineTrailing(for: top)
            }
        }
        .padding(.horizontal, 10)
        .frame(width: notchPillWidth + 60, height: islandClosedHeight)
        .contentShape(Rectangle())
        .onTapGesture {
            if let top = center.islands.last { center.toggleExpand(top.id) }
        }
    }

    @ViewBuilder
    private func inlineLeading(for activity: IslandActivity) -> some View {
        switch activity {
        case .nowPlaying(let n):
            if let data = n.artworkData, let img = NSImage(data: data) {
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
        default:
            inlineDot(for: activity)
        }
    }

    @ViewBuilder
    private func inlineTrailing(for activity: IslandActivity) -> some View {
        switch activity {
        case .nowPlaying(let n):
            SpectrumBars(playing: n.isPlaying)
                .frame(width: 24, height: 20)
        case .timer(let t):
            Text(timeString(seconds: t.remainingSeconds))
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundColor(.white.opacity(0.85))
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

    private func inlineDot(for activity: IslandActivity) -> some View {
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

    private func smallSplitPill(for activity: IslandActivity) -> some View {
        inlineDot(for: activity)
    }

    // MARK: Live EQ mark for the collapsed pill

    // MARK: Expanded

    private func expandedContent(for activity: IslandActivity) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            header(for: activity)
                .frame(height: max(24, islandClosedHeight))
            content(for: activity)
                .padding(.top, 10)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20)
        .padding(.top, 8)
        .padding(.bottom, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private func header(for activity: IslandActivity) -> some View {
        HStack(alignment: .center, spacing: 8) {
            icon(for: activity, size: 26)
            Text(title(for: activity))
                .font(.headline)
                .foregroundColor(.white)
            Spacer()
            Button(action: { center.dismiss(activity.id) }) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundColor(.white.opacity(0.45))
                    .font(.system(size: 18))
            }
            .buttonStyle(.plain)
        }
    }

    @ViewBuilder
    private func content(for activity: IslandActivity) -> some View {
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
            }
        )
        case .timer(let t): TimerExpandedView(
            activity: t,
            onCancel: { center.cancelTimer() },
            onPauseResume: { center.pauseResumeTimer() },
            onAddMinute: { center.addMinuteToTimer() }
        )
        case .charging(let c): ChargingExpandedView(activity: c)
        case .notification(let n): NotificationExpandedView(activity: n)
        case .focus(let f): FocusExpandedView(activity: f)
        case .weather(let w): WeatherExpandedView(activity: w)
        }
    }

    // MARK: Shared

    @ViewBuilder
    private func icon(for activity: IslandActivity, size: CGFloat) -> some View {
        if case .focus(let f) = activity, !FocusMonitor.isSFSymbol(f.symbol) {
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

    private func iconSpec(for activity: IslandActivity) -> (String, Color) {
        switch activity {
        case .timer: return ("timer", .orange)
        case .nowPlaying: return ("music.note", .pink)
        case .charging: return ("bolt.fill", .green)
        case .notification: return ("message.fill", .purple)
        case .focus(let f): return (FocusMonitor.isSFSymbol(f.symbol) ? f.symbol : "moon.fill", .indigo)
        case .weather(let w): return (w.symbol, .blue)
        }
    }

    private func title(for activity: IslandActivity) -> String {
        switch activity {
        case .timer: return "Timer"
        case .nowPlaying: return "Now Playing"
        case .charging: return "Battery"
        case .notification(let n): return n.appName
        case .focus(let f): return f.mode
        case .weather: return "Weather"
        }
    }

    @ViewBuilder
    private func text(for activity: IslandActivity, expanded: Bool, size: CGFloat) -> some View {
        switch activity {
        case .timer(let t): Text(t.label).font(.system(size: size, weight: .semibold))
        case .nowPlaying(let n): Text(n.title).font(.system(size: size, weight: .semibold))
        case .charging(let c): Text(expanded ? "Charging" : "\(Int((c.level * 100).rounded()))%").font(.system(size: size, weight: .semibold))
        case .notification(let n): Text(n.sender).font(.system(size: size, weight: .semibold))
        case .focus(let f): Text(f.mode).font(.system(size: size, weight: .semibold))
        case .weather(let w): Text(w.condition).font(.system(size: size, weight: .semibold))
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
    @State private var dragFraction: Double?

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
            artwork
                .frame(width: 90, height: 90)
                .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
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
                        SeekBar(progress: shownProgress,
                                onScrub: { f in dragFraction = f },
                                onRelease: { f in
                                    NSLog("[Alcove] ui: seek to %.1fs", f * activity.duration)
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
                        NSLog("[Alcove] ui: previous tapped")
                        onPrevious()
                    }
                    TransportButton(systemImage: activity.isPlaying ? "pause.fill" : "play.fill", size: 15, prominent: true) {
                        NSLog("[Alcove] ui: playpause tapped")
                        onPlayPause()
                    }
                    TransportButton(systemImage: "forward.fill", size: 13) {
                        NSLog("[Alcove] ui: next tapped")
                        onNext()
                    }
                }
                .padding(.top, 2)
            }
            Spacer(minLength: 0)
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
struct SpectrumBars: View {
    let playing: Bool
    @State private var phase = false

    private let baseHeights: [CGFloat] = [12, 7, 10, 6]
    private let peakHeights: [CGFloat] = [6, 13, 7, 12]

    var body: some View {
        HStack(spacing: 2.5) {
            ForEach(0..<4, id: \.self) { i in
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(Color.white.opacity(playing ? 0.9 : 0.35))
                    .frame(width: 3, height: playing ? (phase ? peakHeights[i] : baseHeights[i]) : 5)
            }
        }
        .animation(playing ? .easeInOut(duration: 0.45).repeatForever(autoreverses: true) : .default, value: phase)
        .onAppear { phase = playing }
        .onChange(of: playing) { _, isPlaying in
            if isPlaying { phase.toggle() } else { phase = false }
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

struct TimerExpandedView: View {
    let activity: TimerActivity
    var onCancel: () -> Void = {}
    var onPauseResume: () -> Void = {}
    var onAddMinute: () -> Void = {}

    var body: some View {
        VStack(spacing: 12) {
            Text(timeString(seconds: activity.remainingSeconds))
                .font(.system(size: 44, weight: .light, design: .rounded))
                .foregroundColor(.white)
                .monospacedDigit()
            ProgressBar(progress: activity.progress)
                .frame(height: 4)
            HStack(spacing: 10) {
                CapsuleButton(title: "Cancel", systemImage: "xmark", action: onCancel)
                CapsuleButton(title: "+1 Min", systemImage: "plus", action: onAddMinute)
                CapsuleButton(title: activity.isPaused ? "Resume" : "Pause",
                              systemImage: activity.isPaused ? "play.fill" : "pause.fill",
                              action: onPauseResume)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func timeString(seconds: Int) -> String {
        let m = seconds / 60
        let s = seconds % 60
        return String(format: "%02d:%02d", m, s)
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
/// Same geometry family as the reference notch apps (6/14 closed, 19/24 open).
struct NotchShape: Shape {
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