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
        XCTAssertFalse(first.showClaudeCodeWorkActivity)
        first.showClaudeCodeWorkActivity = true
        first.calendarLookaheadDays = 14
        first.calendarItemLimit = 40
        first.calendarShowDuration = false
        first.showCodexInAppsBar = false
        first.appsBarScale = 1.25
        first.notchWidthScale = 1.15
        first.notchHeightScale = 0.9

        let second = HaloSettings(defaults: defaults)
        XCTAssertFalse(second.automaticallyExpandActivities)
        XCTAssertFalse(second.showRecentlyPlayed)
        XCTAssertTrue(second.showCodexWorkActivity)
        XCTAssertTrue(second.showClaudeCodeWorkActivity)
        XCTAssertEqual(second.calendarLookaheadDays, 14)
        XCTAssertEqual(second.calendarItemLimit, 40)
        XCTAssertFalse(second.calendarShowDuration)
        XCTAssertFalse(second.showCodexInAppsBar)
        XCTAssertEqual(second.appsBarScale, 1.25)
        XCTAssertEqual(second.notchWidthScale, 1.15)
        XCTAssertEqual(second.notchHeightScale, 0.9)
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
