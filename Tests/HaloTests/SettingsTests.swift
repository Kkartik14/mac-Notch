import XCTest
@testable import Halo

final class HaloSettingsTests: XCTestCase {
    func testPreferencesPersistAcrossInstances() {
        let suiteName = "HaloTests.settings.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let first = HaloSettings(defaults: defaults)
        first.automaticallyExpandActivities = false
        first.showRecentlyPlayed = false
        XCTAssertFalse(first.showCodexWorkActivity)
        first.showCodexWorkActivity = true
        first.calendarLookaheadDays = 14
        first.calendarItemLimit = 40
        first.calendarShowDuration = false

        let second = HaloSettings(defaults: defaults)
        XCTAssertFalse(second.automaticallyExpandActivities)
        XCTAssertFalse(second.showRecentlyPlayed)
        XCTAssertTrue(second.showCodexWorkActivity)
        XCTAssertEqual(second.calendarLookaheadDays, 14)
        XCTAssertEqual(second.calendarItemLimit, 40)
        XCTAssertFalse(second.calendarShowDuration)
    }

    func testPermissionRequestLedgerPersistsAcrossInstances() {
        let suiteName = "HaloTests.permissionLedger.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let first = HaloPermissionRequestLedger(defaults: defaults)
        XCTAssertFalse(first.hasRequested(.calendarEvents))
        first.markRequested(.calendarEvents)

        let second = HaloPermissionRequestLedger(defaults: defaults)
        XCTAssertTrue(second.hasRequested(.calendarEvents))
        XCTAssertFalse(second.hasRequested(.reminders))
    }
}
