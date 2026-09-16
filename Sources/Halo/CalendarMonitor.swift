import Foundation
import AppKit
@preconcurrency import EventKit

enum CalendarItemKind: Equatable {
    case event
    case reminder
}

/// A small, UI-safe representation of an EventKit item.
///
/// EventKit objects stay inside CalendarMonitor. The rest of Halo only sees
/// value types, which keeps the activity state easy to render and test.
struct CalendarItem: Equatable, Identifiable {
    let id: String
    let title: String
    let startDate: Date
    let endDate: Date?
    let isAllDay: Bool
    let location: String?
    let calendarName: String
    let kind: CalendarItemKind
    let isCompleted: Bool
    let externalURL: URL?

    init(
        id: String,
        title: String,
        startDate: Date,
        endDate: Date?,
        isAllDay: Bool,
        location: String?,
        calendarName: String,
        kind: CalendarItemKind,
        isCompleted: Bool,
        externalURL: URL? = nil
    ) {
        self.id = id
        self.title = title
        self.startDate = startDate
        self.endDate = endDate
        self.isAllDay = isAllDay
        self.location = location
        self.calendarName = calendarName
        self.kind = kind
        self.isCompleted = isCompleted
        self.externalURL = externalURL
    }

    var isReminder: Bool {
        kind == .reminder
    }
}

struct CalendarActivity: Equatable {
    let items: [CalendarItem]

    var nextItem: CalendarItem? {
        items.first
    }
}

struct CalendarDateGroup: Equatable, Identifiable {
    let date: Date
    let items: [CalendarItem]

    var id: Date {
        date
    }
}

/// Reads upcoming Calendar events and incomplete Reminders through EventKit.
///
/// Calendar and Reminders are independent permissions. If the user grants
/// only one of them, Halo still shows the data from the granted source.
final class CalendarMonitor: NSObject {
    static let lookaheadDays = 7
    static let maximumItems = 25
    static let startAlertDuration: TimeInterval = 4

    private let store = EKEventStore()
    private let permissionLedger: HaloPermissionRequestLedger
    private var refreshTimer: Timer?
    private var eventStartTimer: Timer?
    private var eventStoreObserver: NSObjectProtocol?
    private var systemObservers: [(center: NotificationCenter, token: NSObjectProtocol)] = []
    private var permissionTask: Task<Void, Never>?
    private var refreshGeneration = 0
    private var lastItems: [CalendarItem] = []
    private var lastObservedItems: [CalendarItem] = []
    private var eventAccess = false
    private var reminderAccess = false
    private var warnedNoAccess = false
    private var isStarted = false
    private var includeEvents = true
    private var includeReminders = true
    private var configuredLookaheadDays = CalendarMonitor.lookaheadDays
    private var configuredMaximumItems = CalendarMonitor.maximumItems

    private(set) var current: CalendarActivity?
    private var onUpdate: ((CalendarActivity) -> Void)?
    private var onClear: (() -> Void)?
    private var onEventStart: ((CalendarActivity, CalendarItem) -> Void)?

    init(permissionLedger: HaloPermissionRequestLedger = .shared) {
        self.permissionLedger = permissionLedger
        super.init()
    }

    deinit {
        stop()
    }

    func start(
        onUpdate: @escaping (CalendarActivity) -> Void,
        onClear: @escaping () -> Void,
        onEventStart: @escaping (CalendarActivity, CalendarItem) -> Void = { _, _ in }
    ) {
        self.onUpdate = onUpdate
        self.onClear = onClear
        self.onEventStart = onEventStart
        isStarted = true

        refreshTimer?.invalidate()
        eventStartTimer?.invalidate()
        eventStartTimer = nil
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            self?.refresh()
        }

        if eventStoreObserver == nil {
            eventStoreObserver = NotificationCenter.default.addObserver(
                forName: .EKEventStoreChanged,
                object: store,
                queue: .main
            ) { [weak self] _ in
                self?.refresh()
            }
        }
        installSystemObservers()

        updateAccessState()
        refresh()
        requestAccessIfNeeded()
    }

    func stop() {
        isStarted = false
        permissionTask?.cancel()
        permissionTask = nil
        refreshTimer?.invalidate()
        refreshTimer = nil
        eventStartTimer?.invalidate()
        eventStartTimer = nil
        if let eventStoreObserver {
            NotificationCenter.default.removeObserver(eventStoreObserver)
            self.eventStoreObserver = nil
        }
        removeSystemObservers()
        refreshGeneration &+= 1
        lastObservedItems.removeAll()
    }

    /// Applies persisted display/filter preferences without replacing the
    /// EventKit store. The monitor remains safe to configure before start.
    func configure(
        includeEvents: Bool,
        includeReminders: Bool,
        lookaheadDays: Int,
        maximumItems: Int
    ) {
        self.includeEvents = includeEvents
        self.includeReminders = includeReminders
        configuredLookaheadDays = min(30, max(1, lookaheadDays))
        configuredMaximumItems = min(50, max(1, maximumItems))
        if isStarted {
            refresh()
        }
    }

    /// Re-read the current EventKit state. This is also used by the manual
    /// Calendar context-menu action after a permission decision.
    func refresh() {
        updateAccessState()
        refreshGeneration &+= 1
        let generation = refreshGeneration
        let now = Date()
        let eventSearchStart = Calendar.current.startOfDay(for: now)
        let through = Calendar.current.date(byAdding: .day, value: configuredLookaheadDays, to: now)
            ?? now.addingTimeInterval(TimeInterval(configuredLookaheadDays) * 24 * 60 * 60)

        var items: [CalendarItem] = []
        if eventAccess && includeEvents {
            // Start at the beginning of today so an event already in progress
            // is not lost just because its start time has passed.
            let predicate = store.predicateForEvents(withStart: eventSearchStart, end: through, calendars: nil)
            items.append(contentsOf: store.events(matching: predicate).compactMap(Self.item(from:)))
        }

        guard reminderAccess && includeReminders else {
            publish(
                Self.upcomingItems(items, now: now, through: through, limit: configuredMaximumItems),
                observedItems: items,
                now: now
            )
            return
        }

        let predicate = store.predicateForReminders(in: nil)
        store.fetchReminders(matching: predicate) { [weak self] reminders in
            let reminderItems = (reminders ?? []).compactMap(Self.item(from:))
            DispatchQueue.main.async {
                guard let self, generation == self.refreshGeneration else { return }
                var combined = items
                combined.append(contentsOf: reminderItems)
                self.publish(Self.upcomingItems(
                    combined,
                    now: now,
                    through: through,
                    limit: self.configuredMaximumItems
                ), observedItems: combined, now: now)
            }
        }
    }

    /// Complete an incomplete reminder from the expanded Halo card.
    func completeReminder(id: String) {
        let calendarItemID = Self.eventKitIdentifier(for: id)
        guard reminderAccess,
              let reminder = store.calendarItem(withIdentifier: calendarItemID) as? EKReminder
        else { return }

        reminder.isCompleted = true
        do {
            try store.save(reminder, commit: true)
            refresh()
        } catch {
            NSLog("[Halo] calendar: failed to complete reminder %@: %@", calendarItemID, error.localizedDescription)
        }
    }

    /// Allows the Permissions page to retry an explicitly requested access
    /// decision. Automatic startup requests use the one-time ledger below.
    func requestAccess() {
        requestAccessIfNeeded(force: true)
    }

    /// Requests only the EventKit entity selected by the user in Settings.
    /// Calendar and Reminders remain independent TCC decisions.
    func requestAccess(for type: EKEntityType) {
        requestAccessIfNeeded(force: true, only: type)
    }

    /// Activity IDs are namespaced to keep event and reminder rows distinct;
    /// EventKit expects the original calendar-item identifier when saving.
    static func eventKitIdentifier(for activityID: String) -> String {
        if activityID.hasPrefix("reminder:") {
            return String(activityID.dropFirst("reminder:".count))
        }
        if activityID.hasPrefix("event:") {
            return String(activityID.dropFirst("event:".count))
        }
        return activityID
    }

    /// Native macOS URLs that open the selected item in its owning app.
    /// Calendar and Reminders handle these URLs themselves; no AppleScript
    /// automation permission is needed.
    static func nativeURL(for item: CalendarItem) -> URL? {
        let identifier = eventKitIdentifier(for: item.id)
        guard !identifier.isEmpty else { return nil }

        var allowedCharacters = CharacterSet.urlPathAllowed
        allowedCharacters.remove(charactersIn: "/")
        let escapedIdentifier = identifier.addingPercentEncoding(
            withAllowedCharacters: allowedCharacters
        ) ?? identifier

        var components = URLComponents()
        components.scheme = item.isReminder ? "x-apple-reminderkit" : "ical"
        components.host = item.isReminder ? "REMCDReminder" : "ekevent"
        components.percentEncodedPath = "/\(escapedIdentifier)"
        if !item.isReminder {
            components.queryItems = [
                URLQueryItem(name: "method", value: "show"),
                URLQueryItem(name: "options", value: "more")
            ]
        }
        return components.url
    }

    /// Creates a URL that opens a location search in Apple Maps.
    static func mapsURL(for location: String) -> URL? {
        let trimmed = location.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        var components = URLComponents(string: "maps://")
        components?.queryItems = [URLQueryItem(name: "q", value: trimmed)]
        return components?.url
    }

    /// EventKit URLs can point at an online meeting or another useful web
    /// resource. Native item URLs are handled separately by nativeURL(for:).
    static func externalURL(for item: CalendarItem) -> URL? {
        externalURL(for: item.externalURL)
    }

    static func externalURL(for url: URL?) -> URL? {
        guard let url,
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https"
        else { return nil }
        return url
    }

    /// Pure selection logic shared by the live monitor and unit tests.
    static func upcomingItems(
        _ items: [CalendarItem],
        now: Date,
        through: Date,
        limit: Int
    ) -> [CalendarItem] {
        guard limit > 0 else { return [] }

        return items
            .filter { item in
                guard !item.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      !item.isCompleted,
                      item.startDate <= through
                else { return false }

                switch item.kind {
                case .event:
                    // Keep an event that is already in progress visible until
                    // it ends, while excluding events that have finished.
                    return (item.endDate ?? item.startDate) >= now
                case .reminder:
                    // An incomplete reminder stays visible after its due date
                    // until the user completes it from Halo or Reminders.
                    return true
                }
            }
            .sorted(by: itemComesBefore)
            .prefix(limit)
            .map { $0 }
    }

    /// Groups already-selected items by their local calendar day while
    /// preserving the deterministic time/type ordering within each group.
    static func groupedByDate(
        _ items: [CalendarItem],
        calendar: Calendar = .current
    ) -> [CalendarDateGroup] {
        let grouped = Dictionary(grouping: items) { calendar.startOfDay(for: $0.startDate) }
        return grouped.keys.sorted().compactMap { date in
            guard let items = grouped[date] else { return nil }
            return CalendarDateGroup(date: date, items: items.sorted(by: itemComesBefore))
        }
    }

    /// Returns nil for today's group so today's rows stay compact. Later
    /// groups carry the date once in the section header.
    static func dateGroupLabel(
        for date: Date,
        relativeTo now: Date = Date(),
        calendar: Calendar = .current
    ) -> String? {
        let day = calendar.startOfDay(for: date)
        let today = calendar.startOfDay(for: now)
        guard !calendar.isDate(day, inSameDayAs: today) else { return nil }

        var dateStyle = Date.FormatStyle().month(.abbreviated).day()
        dateStyle.calendar = calendar
        dateStyle.timeZone = calendar.timeZone
        let dateText = day.formatted(dateStyle).uppercased()

        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: today),
           calendar.isDate(day, inSameDayAs: tomorrow) {
            return "TOMORROW · \(dateText)"
        }

        if day < today {
            return "OVERDUE · \(dateText)"
        }

        var weekdayStyle = Date.FormatStyle().weekday(.abbreviated)
        weekdayStyle.calendar = calendar
        weekdayStyle.timeZone = calendar.timeZone
        return "\(day.formatted(weekdayStyle).uppercased()) · \(dateText)"
    }

    private static func formattedTime(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .shortened)
    }

    /// Row metadata intentionally omits the date; dateGroupLabel supplies it
    /// once per non-today section in the expanded Up Next rail.
    static func timeOnly(for item: CalendarItem) -> String {
        guard !item.isAllDay else { return "All day" }
        return formattedTime(item.startDate)
    }

    /// A compact start/end range used in rows and the expanded detail panel.
    /// Showing both endpoints makes the event duration visible at a glance.
    static func timeRange(for item: CalendarItem) -> String {
        guard !item.isAllDay else { return "All day" }

        let start = timeOnly(for: item)
        guard item.kind == .event,
              let endDate = item.endDate,
              endDate > item.startDate
        else { return start }

        return "\(start)–\(formattedTime(endDate))"
    }

    /// Full date plus start/end range for the primary detail column.
    static func exactTimeRange(for item: CalendarItem, now: Date = Date()) -> String {
        guard !item.isAllDay else { return "All day" }
        let range = timeRange(for: item)
        let calendar = Calendar.current
        if calendar.isDate(item.startDate, inSameDayAs: now) {
            return range
        }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now),
           calendar.isDate(item.startDate, inSameDayAs: tomorrow) {
            return "Tomorrow \(range)"
        }

        let date = item.startDate.formatted(
            .dateTime.weekday(.abbreviated).month(.abbreviated).day()
        )
        return "\(date) \(range)"
    }

    private static func itemComesBefore(_ lhs: CalendarItem, _ rhs: CalendarItem) -> Bool {
        if lhs.startDate != rhs.startDate {
            return lhs.startDate < rhs.startDate
        }
        // If an event and reminder share a due time, show the event first and
        // keep the ordering deterministic.
        if lhs.kind != rhs.kind {
            return lhs.kind == .event
        }
        return lhs.id < rhs.id
    }

    /// Returns only events that crossed their start boundary between two
    /// snapshots. An event first seen after it started is deliberately not
    /// treated as a new alert; that avoids surprising popups on app launch.
    static func eventsStarting(
        previous: [CalendarItem],
        current: [CalendarItem],
        now: Date
    ) -> [CalendarItem] {
        var previousEvents: [String: CalendarItem] = [:]
        for item in previous where item.kind == .event {
            previousEvents[item.id] = item
        }

        return current.compactMap { item in
            guard item.kind == .event,
                  !item.isAllDay,
                  item.startDate <= now,
                  let previous = previousEvents[item.id],
                  previous.startDate > now,
                  (item.endDate ?? item.startDate) >= now
            else { return nil }
            return item
        }
        .sorted { lhs, rhs in
            if lhs.startDate != rhs.startDate {
                return lhs.startDate < rhs.startDate
            }
            return lhs.id < rhs.id
        }
    }

    static func displayTime(for item: CalendarItem, now: Date = Date()) -> String {
        if item.isReminder, !item.isAllDay, item.startDate < now {
            return "Overdue"
        }

        if item.isAllDay {
            return "All day"
        }

        if item.kind == .event,
           item.startDate <= now,
           (item.endDate ?? item.startDate) >= now {
            return "Now"
        }

        let secondsUntilStart = item.startDate.timeIntervalSince(now)
        if secondsUntilStart > 0, secondsUntilStart <= 60 * 60 {
            let minutes = max(1, Int(ceil(secondsUntilStart / 60)))
            return "in \(minutes)m"
        }

        return exactTime(for: item, now: now)
    }

    /// Full event time used in the expanded card's metadata.
    static func exactTime(for item: CalendarItem, now: Date = Date()) -> String {
        if item.isAllDay {
            return "All day"
        }

        let time = item.startDate.formatted(date: .omitted, time: .shortened)
        let calendar = Calendar.current
        if calendar.isDate(item.startDate, inSameDayAs: now) {
            return time
        }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now),
           calendar.isDate(item.startDate, inSameDayAs: tomorrow) {
            return "Tomorrow \(time)"
        }

        let date = item.startDate.formatted(
            .dateTime.weekday(.abbreviated).month(.abbreviated).day()
        )
        return "\(date) \(time)"
    }

    /// Compact status for the narrow collapsed pill. Keep this intentionally
    /// short: the expanded card carries the full title and time.
    static func compactStatus(for item: CalendarItem, now: Date = Date()) -> String {
        if item.isReminder, item.startDate < now {
            return "DUE"
        }

        if item.isAllDay {
            return "DAY"
        }

        if item.kind == .event,
           item.startDate <= now,
           (item.endDate ?? item.startDate) >= now {
            return "NOW"
        }

        let secondsUntilStart = item.startDate.timeIntervalSince(now)
        guard secondsUntilStart > 0 else { return "NOW" }

        if secondsUntilStart < 60 * 60 {
            let minutes = max(1, Int(ceil(secondsUntilStart / 60)))
            return "\(minutes)m"
        }

        if secondsUntilStart < 24 * 60 * 60 {
            let hours = max(1, Int(ceil(secondsUntilStart / (60 * 60))))
            return "\(hours)h"
        }

        let days = max(1, Int(ceil(secondsUntilStart / (24 * 60 * 60))))
        return "\(days)d"
    }

    // MARK: - EventKit mapping and permissions

    private func updateAccessState() {
        eventAccess = Self.hasFullAccess(to: .event)
        reminderAccess = Self.hasFullAccess(to: .reminder)
    }

    /// Timers do not provide a reliable boundary after sleep or a system clock
    /// change. Refresh immediately so the next item and its start timer are
    /// rebuilt from the new wall-clock state.
    private func installSystemObservers() {
        guard systemObservers.isEmpty else { return }

        let workspaceCenter = NSWorkspace.shared.notificationCenter
        let defaultCenter = NotificationCenter.default

        let wake = workspaceCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.refreshAfterSystemChange("wake")
        }
        let session = workspaceCenter.addObserver(
            forName: NSWorkspace.sessionDidBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.refreshAfterSystemChange("session active")
        }
        let clock = defaultCenter.addObserver(
            forName: .NSSystemClockDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.refreshAfterSystemChange("system clock change")
        }
        let locale = defaultCenter.addObserver(
            forName: NSLocale.currentLocaleDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.refreshAfterSystemChange("locale or time-zone change")
        }

        systemObservers = [
            (workspaceCenter, wake),
            (workspaceCenter, session),
            (defaultCenter, clock),
            (defaultCenter, locale)
        ]
    }

    private func removeSystemObservers() {
        for (center, token) in systemObservers {
            center.removeObserver(token)
        }
        systemObservers.removeAll()
    }

    private func refreshAfterSystemChange(_ reason: String) {
        NSLog("[Halo] calendar: refreshing after %@", reason)
        refresh()
    }

    private static func hasFullAccess(to type: EKEntityType) -> Bool {
        switch authorizationStatus(for: type) {
        case .fullAccess, .authorized:
            return true
        default:
            return false
        }
    }

    static func authorizationStatus(for type: EKEntityType) -> EKAuthorizationStatus {
        EKEventStore.authorizationStatus(for: type)
    }

    private func requestAccessIfNeeded(force: Bool = false, only: EKEntityType? = nil) {
        let wantsEvents = only == nil || only == .event
        let wantsReminders = only == nil || only == .reminder
        let needsEvents = wantsEvents && Self.authorizationStatus(for: .event) == .notDetermined
            && (force || (includeEvents && !permissionLedger.hasRequested(.calendarEvents)))
        let needsReminders = wantsReminders && Self.authorizationStatus(for: .reminder) == .notDetermined
            && (force || (includeReminders && !permissionLedger.hasRequested(.reminders)))
        guard needsEvents || needsReminders else { return }

        if needsEvents {
            permissionLedger.markRequested(.calendarEvents)
        }
        if needsReminders {
            permissionLedger.markRequested(.reminders)
        }

        permissionTask?.cancel()
        permissionTask = Task { @MainActor [weak self] in
            guard let self else { return }

            if needsEvents {
                do {
                    _ = try await self.store.requestFullAccessToEvents()
                } catch {
                    NSLog("[Halo] calendar: event permission request failed: %@", error.localizedDescription)
                }
            }

            if needsReminders {
                do {
                    _ = try await self.store.requestFullAccessToReminders()
                } catch {
                    NSLog("[Halo] calendar: reminder permission request failed: %@", error.localizedDescription)
                }
            }

            self.updateAccessState()
            self.refresh()
            self.permissionTask = nil
        }
    }

    private func publish(_ items: [CalendarItem], observedItems: [CalendarItem], now: Date) {
        let startingEvents = Self.eventsStarting(
            previous: lastObservedItems,
            current: observedItems,
            now: now
        )
        lastObservedItems = observedItems

        let changed = items != lastItems
        lastItems = items

        if changed {
            if items.isEmpty {
                current = nil
                if !warnedNoAccess && !eventAccess && !reminderAccess {
                    warnedNoAccess = true
                    NSLog("[Halo] calendar: Calendar and Reminders are unavailable or permission was denied")
                }
                onClear?()
            } else {
                warnedNoAccess = false
                let activity = CalendarActivity(items: items)
                current = activity
                onUpdate?(activity)
            }
        }

        scheduleNextEventStart(from: observedItems, now: now)

        guard !startingEvents.isEmpty else { return }
        let activity = CalendarActivity(items: items)
        for event in startingEvents {
            onEventStart?(activity, event)
        }
    }

    /// A one-shot clock wake-up makes event starts timely without turning the
    /// calendar monitor into a high-frequency poller. The regular one-minute
    /// refresh remains the recovery path for sleep/wake and stale stores.
    private func scheduleNextEventStart(from items: [CalendarItem], now: Date) {
        eventStartTimer?.invalidate()
        eventStartTimer = nil

        guard let nextStart = items
            .filter({ $0.kind == .event && !$0.isAllDay && $0.startDate > now })
            .map(\.startDate)
            .min()
        else { return }

        let timer = Timer(
            timeInterval: max(0.25, nextStart.timeIntervalSince(now)),
            repeats: false
        ) { [weak self] _ in
            self?.eventStartTimer = nil
            self?.refresh()
        }
        eventStartTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private static func item(from event: EKEvent) -> CalendarItem? {
        guard let startDate = event.startDate else { return nil }
        let title = event.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !title.isEmpty else { return nil }

        return CalendarItem(
            id: "event:\(event.eventIdentifier ?? event.calendarItemIdentifier)",
            title: title,
            startDate: startDate,
            endDate: event.endDate,
            isAllDay: event.isAllDay,
            location: event.location?.trimmingCharacters(in: .whitespacesAndNewlines),
            calendarName: event.calendar?.title ?? "",
            kind: .event,
            isCompleted: false,
            externalURL: event.url
        )
    }

    private static func item(from reminder: EKReminder) -> CalendarItem? {
        guard let dueDate = reminder.dueDateComponents?.date else { return nil }
        let title = reminder.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !title.isEmpty else { return nil }

        return CalendarItem(
            id: "reminder:\(reminder.calendarItemIdentifier)",
            title: title,
            startDate: dueDate,
            endDate: nil,
            isAllDay: reminder.dueDateComponents?.hour == nil,
            location: reminder.location?.trimmingCharacters(in: .whitespacesAndNewlines),
            calendarName: reminder.calendar?.title ?? "",
            kind: .reminder,
            isCompleted: reminder.isCompleted,
            externalURL: reminder.url
        )
    }
}
