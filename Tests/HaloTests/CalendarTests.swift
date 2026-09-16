import XCTest
@testable import Halo

final class CalendarMonitorTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func event(
        id: String,
        title: String,
        offset: TimeInterval,
        duration: TimeInterval = 3_600
    ) -> CalendarItem {
        CalendarItem(
            id: "event:\(id)",
            title: title,
            startDate: now.addingTimeInterval(offset),
            endDate: now.addingTimeInterval(offset + duration),
            isAllDay: false,
            location: nil,
            calendarName: "Work",
            kind: .event,
            isCompleted: false
        )
    }

    private func reminder(
        id: String,
        title: String,
        offset: TimeInterval,
        completed: Bool = false
    ) -> CalendarItem {
        CalendarItem(
            id: "reminder:\(id)",
            title: title,
            startDate: now.addingTimeInterval(offset),
            endDate: nil,
            isAllDay: false,
            location: nil,
            calendarName: "Personal",
            kind: .reminder,
            isCompleted: completed
        )
    }

    func testUpcomingItemsSortsEventsAndRemindersAndCapsTheRail() {
        let items = [
            reminder(id: "later", title: "Later", offset: 4 * 60 * 60),
            event(id: "first", title: "First", offset: 60 * 60),
            reminder(id: "second", title: "Second", offset: 2 * 60 * 60),
            event(id: "third", title: "Third", offset: 3 * 60 * 60)
        ]

        let result = CalendarMonitor.upcomingItems(
            items,
            now: now,
            through: now.addingTimeInterval(24 * 60 * 60),
            limit: 3
        )

        XCTAssertEqual(result.map(\.title), ["First", "Second", "Third"])
    }

    func testDefaultRailCapAllowsTwentyFiveItems() {
        let items = (0..<30).map { index in
            event(id: "event-\(index)", title: "Event \(index)", offset: TimeInterval(index + 1) * 60)
        }

        let result = CalendarMonitor.upcomingItems(
            items,
            now: now,
            through: now.addingTimeInterval(24 * 60 * 60),
            limit: CalendarMonitor.maximumItems
        )

        XCTAssertEqual(CalendarMonitor.maximumItems, 25)
        XCTAssertEqual(result.count, 25)
        XCTAssertEqual(result.last?.title, "Event 24")
    }

    func testGroupedByDatePreservesDayAndItemOrder() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let items = [
            event(id: "later", title: "Later", offset: 2 * 24 * 60 * 60),
            event(id: "tomorrow", title: "Tomorrow", offset: 24 * 60 * 60),
            event(id: "today", title: "Today", offset: 60),
            event(id: "tomorrow-early", title: "Tomorrow early", offset: 24 * 60 * 60 + 60)
        ]

        let groups = CalendarMonitor.groupedByDate(items, calendar: calendar)

        XCTAssertEqual(groups.count, 3)
        XCTAssertEqual(groups.map { $0.items.map(\.title) }, [
            ["Today"],
            ["Tomorrow", "Tomorrow early"],
            ["Later"]
        ])
    }

    func testDateGroupLabelOmitsTodayAndNamesLaterDays() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let today = calendar.startOfDay(for: now)
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: today)!
        let later = calendar.date(byAdding: .day, value: 2, to: today)!

        XCTAssertNil(CalendarMonitor.dateGroupLabel(for: today, relativeTo: now, calendar: calendar))
        XCTAssertTrue(
            CalendarMonitor.dateGroupLabel(for: tomorrow, relativeTo: now, calendar: calendar)?
                .hasPrefix("TOMORROW ·") == true
        )
        XCTAssertTrue(
            CalendarMonitor.dateGroupLabel(for: later, relativeTo: now, calendar: calendar)?
                .contains(" · ") == true
        )
    }

    func testCompletedAndPastItemsAreNotShown() {
        let items = [
            event(id: "past", title: "Finished", offset: -2 * 60 * 60, duration: 60),
            reminder(id: "done", title: "Done", offset: 60 * 60, completed: true),
            reminder(id: "future", title: "Future", offset: 2 * 60 * 60)
        ]

        let result = CalendarMonitor.upcomingItems(
            items,
            now: now,
            through: now.addingTimeInterval(24 * 60 * 60),
            limit: CalendarMonitor.maximumItems
        )

        XCTAssertEqual(result.map(\.title), ["Future"])
    }

    func testOngoingEventRemainsVisibleUntilItsEnd() {
        let item = event(id: "ongoing", title: "In progress", offset: -1_800, duration: 3_600)

        let result = CalendarMonitor.upcomingItems(
            [item],
            now: now,
            through: now.addingTimeInterval(24 * 60 * 60),
            limit: CalendarMonitor.maximumItems
        )

        XCTAssertEqual(result.map(\.title), ["In progress"])
    }

    func testIncompleteReminderRemainsVisibleAfterDueDate() {
        let item = reminder(id: "overdue", title: "Still needed", offset: -3_600)

        let result = CalendarMonitor.upcomingItems(
            [item],
            now: now,
            through: now.addingTimeInterval(24 * 60 * 60),
            limit: CalendarMonitor.maximumItems
        )

        XCTAssertEqual(result.map(\.title), ["Still needed"])
    }

    func testEventsStartingOnlyReportsARealStartTransition() {
        let previous = event(id: "meeting", title: "Meeting", offset: 60)
        let started = event(id: "meeting", title: "Meeting", offset: -60)

        XCTAssertEqual(
            CalendarMonitor.eventsStarting(previous: [previous], current: [started], now: now)
                .map(\.title),
            ["Meeting"]
        )
        XCTAssertTrue(
            CalendarMonitor.eventsStarting(previous: [started], current: [started], now: now).isEmpty,
            "an already-started event must not alert again"
        )
        XCTAssertTrue(
            CalendarMonitor.eventsStarting(previous: [], current: [started], now: now).isEmpty,
            "an event first seen in progress must not alert on launch"
        )
    }

    func testDisplayTimeUsesRelativeStates() {
        let soon = event(id: "soon", title: "Soon", offset: 7 * 60)
        let ongoing = event(id: "ongoing", title: "Ongoing", offset: -60, duration: 3_600)
        let overdue = reminder(id: "overdue", title: "Overdue", offset: -60)

        XCTAssertEqual(CalendarMonitor.displayTime(for: soon, now: now), "in 7m")
        XCTAssertEqual(CalendarMonitor.displayTime(for: ongoing, now: now), "Now")
        XCTAssertEqual(CalendarMonitor.displayTime(for: overdue, now: now), "Overdue")
    }

    func testCompactStatusFitsTheCollapsedPill() {
        let soon = event(id: "soon", title: "Soon", offset: 17 * 60)
        let later = event(id: "later", title: "Later", offset: 2 * 60 * 60)
        let ongoing = event(id: "ongoing", title: "Ongoing", offset: -60, duration: 3_600)
        let overdue = reminder(id: "overdue", title: "Overdue", offset: -60)

        let statuses = [
            CalendarMonitor.compactStatus(for: soon, now: now),
            CalendarMonitor.compactStatus(for: later, now: now),
            CalendarMonitor.compactStatus(for: ongoing, now: now),
            CalendarMonitor.compactStatus(for: overdue, now: now)
        ]

        XCTAssertEqual(statuses, ["17m", "2h", "NOW", "DUE"])
        XCTAssertTrue(statuses.allSatisfy { $0.count <= 3 })
    }

    func testEmptyTitlesAreIgnored() {
        let item = CalendarItem(
            id: "event:empty",
            title: "   ",
            startDate: now.addingTimeInterval(60),
            endDate: now.addingTimeInterval(3_660),
            isAllDay: false,
            location: nil,
            calendarName: "Work",
            kind: .event,
            isCompleted: false
        )

        XCTAssertTrue(CalendarMonitor.upcomingItems(
            [item],
            now: now,
            through: now.addingTimeInterval(24 * 60 * 60),
            limit: CalendarMonitor.maximumItems
        ).isEmpty)
    }

    func testReminderActivityIDConvertsBackToEventKitID() {
        XCTAssertEqual(CalendarMonitor.eventKitIdentifier(for: "reminder:abc"), "abc")
        XCTAssertEqual(CalendarMonitor.eventKitIdentifier(for: "abc"), "abc")
    }
}
