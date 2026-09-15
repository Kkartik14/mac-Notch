import Foundation
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

/// Reads upcoming Calendar events and incomplete Reminders through EventKit.
///
/// Calendar and Reminders are independent permissions. If the user grants
/// only one of them, Halo still shows the data from the granted source.
final class CalendarMonitor: NSObject {
    static let lookaheadDays = 7
    static let maximumItems = 5
    static let startAlertDuration: TimeInterval = 4

    private let store = EKEventStore()
    private var refreshTimer: Timer?
    private var eventStartTimer: Timer?
    private var eventStoreObserver: NSObjectProtocol?
    private var permissionTask: Task<Void, Never>?
    private var refreshGeneration = 0
    private var lastItems: [CalendarItem] = []
    private var lastObservedItems: [CalendarItem] = []
    private var eventAccess = false
    private var reminderAccess = false
    private var warnedNoAccess = false

    private(set) var current: CalendarActivity?
    private var onUpdate: ((CalendarActivity) -> Void)?
    private var onClear: (() -> Void)?
    private var onEventStart: ((CalendarActivity, CalendarItem) -> Void)?

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

        updateAccessState()
        refresh()
        requestAccessIfNeeded()
    }

    func stop() {
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
        refreshGeneration &+= 1
        lastObservedItems.removeAll()
    }

    /// Re-read the current EventKit state. This is also used by the manual
    /// Calendar context-menu action after a permission decision.
    func refresh() {
        updateAccessState()
        refreshGeneration &+= 1
        let generation = refreshGeneration
        let now = Date()
        let eventSearchStart = Calendar.current.startOfDay(for: now)
        let through = Calendar.current.date(byAdding: .day, value: Self.lookaheadDays, to: now)
            ?? now.addingTimeInterval(TimeInterval(Self.lookaheadDays) * 24 * 60 * 60)

        var items: [CalendarItem] = []
        if eventAccess {
            // Start at the beginning of today so an event already in progress
            // is not lost just because its start time has passed.
            let predicate = store.predicateForEvents(withStart: eventSearchStart, end: through, calendars: nil)
            items.append(contentsOf: store.events(matching: predicate).compactMap(Self.item(from:)))
        }

        guard reminderAccess else {
            publish(
                Self.upcomingItems(items, now: now, through: through, limit: Self.maximumItems),
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
                    limit: Self.maximumItems
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

    /// Activity IDs are namespaced to keep event and reminder rows distinct;
    /// EventKit expects the original calendar-item identifier when saving.
    static func eventKitIdentifier(for activityID: String) -> String {
        activityID.hasPrefix("reminder:")
            ? String(activityID.dropFirst("reminder:".count))
            : activityID
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
            .sorted { lhs, rhs in
                if lhs.startDate != rhs.startDate {
                    return lhs.startDate < rhs.startDate
                }
                // If an event and reminder share a due time, show the event
                // first and keep the ordering deterministic.
                if lhs.kind != rhs.kind {
                    return lhs.kind == .event
                }
                return lhs.id < rhs.id
            }
            .prefix(limit)
            .map { $0 }
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

    private static func hasFullAccess(to type: EKEntityType) -> Bool {
        switch EKEventStore.authorizationStatus(for: type) {
        case .fullAccess, .authorized:
            return true
        default:
            return false
        }
    }

    private func requestAccessIfNeeded() {
        let needsEvents = EKEventStore.authorizationStatus(for: .event) == .notDetermined
        let needsReminders = EKEventStore.authorizationStatus(for: .reminder) == .notDetermined
        guard needsEvents || needsReminders else { return }

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
            isCompleted: false
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
            location: nil,
            calendarName: reminder.calendar?.title ?? "",
            kind: .reminder,
            isCompleted: reminder.isCompleted
        )
    }
}
