import Combine
import Foundation
import ServiceManagement

/// The permissions that Halo may request automatically on first use.
/// Authorization itself is always read from macOS; this ledger only prevents
/// an unanswered request from being retried on every launch.
enum HaloPermissionRequest: String {
    case calendarEvents
    case reminders
    case location
}

final class HaloPermissionRequestLedger {
    static let shared = HaloPermissionRequestLedger()

    private let defaults: UserDefaults
    private let keyPrefix = "Halo.permissionRequest."

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func hasRequested(_ permission: HaloPermissionRequest) -> Bool {
        defaults.bool(forKey: keyPrefix + permission.rawValue)
    }

    func markRequested(_ permission: HaloPermissionRequest) {
        defaults.set(true, forKey: keyPrefix + permission.rawValue)
    }
}

/// Bridges intentional permission actions from the settings window back to
/// the single monitor instances owned by AppDelegate. The settings view never
/// creates a second EventKit or Core Location manager.
final class HaloPermissionActions {
    static let shared = HaloPermissionActions()

    var requestCalendarEventsAccess: (() -> Void)?
    var requestRemindersAccess: (() -> Void)?
    var requestLocationAccess: (() -> Void)?
}

/// User-controlled Halo behavior. Values are intentionally small, typed, and
/// persisted individually so a future setting can be added without a schema
/// migration or a custom preferences file.
final class HaloSettings: ObservableObject {
    static let shared = HaloSettings()

    private enum Key {
        static let automaticallyExpandActivities = "Halo.settings.automaticallyExpandActivities"
        static let hoverToExpand = "Halo.settings.hoverToExpand"
        static let collapseOnMouseLeave = "Halo.settings.collapseOnMouseLeave"
        static let reduceMotion = "Halo.settings.reduceMotion"
        static let showNowPlaying = "Halo.settings.showNowPlaying"
        static let showBattery = "Halo.settings.showBattery"
        static let showNotifications = "Halo.settings.showNotifications"
        static let showWeather = "Halo.settings.showWeather"
        static let showFocus = "Halo.settings.showFocus"
        static let showCalendarEvents = "Halo.settings.showCalendarEvents"
        static let showReminders = "Halo.settings.showReminders"
        static let showCodex = "Halo.settings.showCodex"
        static let showCodexWorkActivity = "Halo.settings.showCodexWorkActivity"
        static let showOpenCode = "Halo.settings.showOpenCode"
        static let showOpenCodeWorkActivity = "Halo.settings.showOpenCodeWorkActivity"
        static let showClaudeCode = "Halo.settings.showClaudeCode"
        static let showClaudeCodeWorkActivity = "Halo.settings.showClaudeCodeWorkActivity"
        static let showArtwork = "Halo.settings.showArtwork"
        static let showUpNext = "Halo.settings.showUpNext"
        static let showRecentlyPlayed = "Halo.settings.showRecentlyPlayed"
        static let calendarLookaheadDays = "Halo.settings.calendarLookaheadDays"
        static let calendarItemLimit = "Halo.settings.calendarItemLimit"
        static let calendarShowDuration = "Halo.settings.calendarShowDuration"
        static let calendarShowLocations = "Halo.settings.calendarShowLocations"
        static let calendarStartAlerts = "Halo.settings.calendarStartAlerts"
    }

    private let defaults: UserDefaults

    @Published var automaticallyExpandActivities: Bool {
        didSet { defaults.set(automaticallyExpandActivities, forKey: Key.automaticallyExpandActivities) }
    }

    @Published var hoverToExpand: Bool {
        didSet { defaults.set(hoverToExpand, forKey: Key.hoverToExpand) }
    }

    @Published var collapseOnMouseLeave: Bool {
        didSet { defaults.set(collapseOnMouseLeave, forKey: Key.collapseOnMouseLeave) }
    }

    @Published var reduceMotion: Bool {
        didSet { defaults.set(reduceMotion, forKey: Key.reduceMotion) }
    }

    @Published var showNowPlaying: Bool {
        didSet { defaults.set(showNowPlaying, forKey: Key.showNowPlaying) }
    }

    @Published var showBattery: Bool {
        didSet { defaults.set(showBattery, forKey: Key.showBattery) }
    }

    @Published var showNotifications: Bool {
        didSet { defaults.set(showNotifications, forKey: Key.showNotifications) }
    }

    @Published var showWeather: Bool {
        didSet { defaults.set(showWeather, forKey: Key.showWeather) }
    }

    @Published var showFocus: Bool {
        didSet { defaults.set(showFocus, forKey: Key.showFocus) }
    }

    @Published var showCalendarEvents: Bool {
        didSet { defaults.set(showCalendarEvents, forKey: Key.showCalendarEvents) }
    }

    @Published var showReminders: Bool {
        didSet { defaults.set(showReminders, forKey: Key.showReminders) }
    }

    @Published var showCodex: Bool {
        didSet { defaults.set(showCodex, forKey: Key.showCodex) }
    }

    @Published var showCodexWorkActivity: Bool {
        didSet { defaults.set(showCodexWorkActivity, forKey: Key.showCodexWorkActivity) }
    }

    @Published var showOpenCode: Bool {
        didSet { defaults.set(showOpenCode, forKey: Key.showOpenCode) }
    }

    @Published var showOpenCodeWorkActivity: Bool {
        didSet { defaults.set(showOpenCodeWorkActivity, forKey: Key.showOpenCodeWorkActivity) }
    }

    @Published var showClaudeCode: Bool {
        didSet { defaults.set(showClaudeCode, forKey: Key.showClaudeCode) }
    }

    @Published var showClaudeCodeWorkActivity: Bool {
        didSet { defaults.set(showClaudeCodeWorkActivity, forKey: Key.showClaudeCodeWorkActivity) }
    }

    @Published var showArtwork: Bool {
        didSet { defaults.set(showArtwork, forKey: Key.showArtwork) }
    }

    @Published var showUpNext: Bool {
        didSet { defaults.set(showUpNext, forKey: Key.showUpNext) }
    }

    @Published var showRecentlyPlayed: Bool {
        didSet { defaults.set(showRecentlyPlayed, forKey: Key.showRecentlyPlayed) }
    }

    @Published var calendarLookaheadDays: Int {
        didSet { defaults.set(calendarLookaheadDays, forKey: Key.calendarLookaheadDays) }
    }

    @Published var calendarItemLimit: Int {
        didSet { defaults.set(calendarItemLimit, forKey: Key.calendarItemLimit) }
    }

    @Published var calendarShowDuration: Bool {
        didSet { defaults.set(calendarShowDuration, forKey: Key.calendarShowDuration) }
    }

    @Published var calendarShowLocations: Bool {
        didSet { defaults.set(calendarShowLocations, forKey: Key.calendarShowLocations) }
    }

    @Published var calendarStartAlerts: Bool {
        didSet { defaults.set(calendarStartAlerts, forKey: Key.calendarStartAlerts) }
    }

    /// This value is read from ServiceManagement, not trusted from a cached
    /// preference. The OS is the source of truth for login-item registration.
    @Published private(set) var launchAtLogin: Bool
    @Published private(set) var launchAtLoginError: String?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.automaticallyExpandActivities = Self.bool(Key.automaticallyExpandActivities, defaults: defaults, fallback: true)
        self.hoverToExpand = Self.bool(Key.hoverToExpand, defaults: defaults, fallback: true)
        self.collapseOnMouseLeave = Self.bool(Key.collapseOnMouseLeave, defaults: defaults, fallback: true)
        self.reduceMotion = Self.bool(Key.reduceMotion, defaults: defaults, fallback: false)
        self.showNowPlaying = Self.bool(Key.showNowPlaying, defaults: defaults, fallback: true)
        self.showBattery = Self.bool(Key.showBattery, defaults: defaults, fallback: true)
        self.showNotifications = Self.bool(Key.showNotifications, defaults: defaults, fallback: true)
        self.showWeather = Self.bool(Key.showWeather, defaults: defaults, fallback: true)
        self.showFocus = Self.bool(Key.showFocus, defaults: defaults, fallback: true)
        self.showCalendarEvents = Self.bool(Key.showCalendarEvents, defaults: defaults, fallback: true)
        self.showReminders = Self.bool(Key.showReminders, defaults: defaults, fallback: true)
        self.showCodex = Self.bool(Key.showCodex, defaults: defaults, fallback: true)
        self.showCodexWorkActivity = Self.bool(Key.showCodexWorkActivity, defaults: defaults, fallback: false)
        self.showOpenCode = Self.bool(Key.showOpenCode, defaults: defaults, fallback: true)
        self.showOpenCodeWorkActivity = Self.bool(Key.showOpenCodeWorkActivity, defaults: defaults, fallback: false)
        self.showClaudeCode = Self.bool(Key.showClaudeCode, defaults: defaults, fallback: true)
        self.showClaudeCodeWorkActivity = Self.bool(Key.showClaudeCodeWorkActivity, defaults: defaults, fallback: false)
        self.showArtwork = Self.bool(Key.showArtwork, defaults: defaults, fallback: true)
        self.showUpNext = Self.bool(Key.showUpNext, defaults: defaults, fallback: true)
        self.showRecentlyPlayed = Self.bool(Key.showRecentlyPlayed, defaults: defaults, fallback: true)
        self.calendarLookaheadDays = Self.integer(Key.calendarLookaheadDays, defaults: defaults, fallback: 7)
        self.calendarItemLimit = Self.integer(Key.calendarItemLimit, defaults: defaults, fallback: 25)
        self.calendarShowDuration = Self.bool(Key.calendarShowDuration, defaults: defaults, fallback: true)
        self.calendarShowLocations = Self.bool(Key.calendarShowLocations, defaults: defaults, fallback: true)
        self.calendarStartAlerts = Self.bool(Key.calendarStartAlerts, defaults: defaults, fallback: true)
        self.launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        launchAtLoginError = nil
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            launchAtLogin = SMAppService.mainApp.status == .enabled
        } catch {
            launchAtLoginError = error.localizedDescription
            launchAtLogin = SMAppService.mainApp.status == .enabled
            NSLog("[Halo] settings: launch-at-login update failed: %@", error.localizedDescription)
        }
    }

    func clearLaunchAtLoginError() {
        launchAtLoginError = nil
    }

    func resetPreferences() {
        setLaunchAtLogin(false)
        automaticallyExpandActivities = true
        hoverToExpand = true
        collapseOnMouseLeave = true
        reduceMotion = false
        showNowPlaying = true
        showBattery = true
        showNotifications = true
        showWeather = true
        showFocus = true
        showCalendarEvents = true
        showReminders = true
        showCodex = true
        showCodexWorkActivity = false
        showOpenCode = true
        showOpenCodeWorkActivity = false
        showClaudeCode = true
        showClaudeCodeWorkActivity = false
        showArtwork = true
        showUpNext = true
        showRecentlyPlayed = true
        calendarLookaheadDays = 7
        calendarItemLimit = 25
        calendarShowDuration = true
        calendarShowLocations = true
        calendarStartAlerts = true
    }

    private static func bool(_ key: String, defaults: UserDefaults, fallback: Bool) -> Bool {
        defaults.object(forKey: key) as? Bool ?? fallback
    }

    private static func integer(_ key: String, defaults: UserDefaults, fallback: Int) -> Int {
        defaults.object(forKey: key) as? Int ?? fallback
    }
}
