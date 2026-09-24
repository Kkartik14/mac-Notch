import XCTest
@testable import Halo

final class HaloDestinationTests: XCTestCase {
    func testAvailableDestinationsUseTheStableBarOrder() {
        let suiteName = "HaloTests.destinations.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = HaloSettings(defaults: defaults)

        XCTAssertEqual(
            HaloDestination.available(in: settings),
            [.nowPlaying, .calendar, .codex, .openCode, .claudeCode]
        )
    }

    func testCalendarDestinationCoversEitherCalendarSource() {
        let suiteName = "HaloTests.destinations.calendar.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = HaloSettings(defaults: defaults)
        settings.showCalendarEvents = false
        settings.showReminders = true
        XCTAssertTrue(HaloDestination.calendar.isEnabled(in: settings))

        settings.showReminders = false
        XCTAssertFalse(HaloDestination.calendar.isEnabled(in: settings))
    }

    func testHiddenSourcesLeaveTheirDestinationsOutOfTheBar() {
        let suiteName = "HaloTests.destinations.hidden.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = HaloSettings(defaults: defaults)
        settings.showCodex = false
        settings.showOpenCode = false
        settings.showClaudeCode = false
        settings.showNotifications = false

        XCTAssertEqual(
            HaloDestination.available(in: settings),
            [.nowPlaying, .calendar]
        )
    }

    func testAppsBarVisibilityIsIndependentFromActivityVisibility() {
        let suiteName = "HaloTests.destinations.appsBar.(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = HaloSettings(defaults: defaults)
        settings.showCodexInAppsBar = false
        settings.showOpenCodeInAppsBar = false

        XCTAssertEqual(
            HaloDestination.available(in: settings),
            [.nowPlaying, .calendar, .claudeCode]
        )
        XCTAssertTrue(settings.showCodex)
        XCTAssertTrue(settings.showOpenCode)
    }

    func testAppsBarScaleIsClampedToSafeGeometry() {
        XCTAssertEqual(HaloDestinationBarMetrics.normalizedScale(0.1), HaloDestinationBarMetrics.minimumScale)
        XCTAssertEqual(HaloDestinationBarMetrics.normalizedScale(1.0), HaloDestinationBarMetrics.defaultScale)
        XCTAssertEqual(HaloDestinationBarMetrics.normalizedScale(3.0), HaloDestinationBarMetrics.maximumScale)
        XCTAssertGreaterThan(
            HaloDestinationBarMetrics.height(for: HaloDestinationBarMetrics.maximumScale),
            HaloDestinationBarMetrics.height
        )
    }
}
