import XCTest
@testable import Halo

final class HaloPresentationPolicyTests: XCTestCase {
    func testExpansionSourcesHaveDifferentOwnershipRules() {
        XCTAssertFalse(HaloPresentationPolicy.shouldExpand(
            intent: .update,
            currentExpandedID: nil,
            targetID: "openCode"
        ))
        XCTAssertTrue(HaloPresentationPolicy.shouldExpand(
            intent: .expand(.user),
            currentExpandedID: "codex",
            targetID: "openCode"
        ))
        XCTAssertTrue(HaloPresentationPolicy.shouldExpand(
            intent: .expand(.pillTap),
            currentExpandedID: nil,
            targetID: "openCode"
        ))
        XCTAssertFalse(HaloPresentationPolicy.shouldExpand(
            intent: .expand(.pillTap),
            currentExpandedID: "codex",
            targetID: "openCode"
        ))
        XCTAssertFalse(HaloPresentationPolicy.shouldExpand(
            intent: .expand(.pillTap),
            currentExpandedID: nil,
            targetID: "openCode",
            manualOverrideID: "codex"
        ))
        XCTAssertTrue(HaloPresentationPolicy.shouldExpand(
            intent: .expand(.pillTap),
            currentExpandedID: nil,
            targetID: "codex",
            manualOverrideID: "codex"
        ))
        XCTAssertTrue(HaloPresentationPolicy.shouldExpand(
            intent: .expand(.hover),
            currentExpandedID: nil,
            targetID: "openCode"
        ))
        XCTAssertFalse(HaloPresentationPolicy.shouldExpand(
            intent: .expand(.hover),
            currentExpandedID: "codex",
            targetID: "openCode"
        ))
        XCTAssertTrue(HaloPresentationPolicy.shouldExpand(
            intent: .expand(.automatic),
            currentExpandedID: nil,
            targetID: "openCode"
        ))
        XCTAssertTrue(HaloPresentationPolicy.shouldExpand(
            intent: .expand(.automatic),
            currentExpandedID: "openCode",
            targetID: "openCode"
        ))
        XCTAssertFalse(HaloPresentationPolicy.shouldExpand(
            intent: .expand(.automatic),
            currentExpandedID: "codex",
            targetID: "openCode"
        ))
        XCTAssertFalse(HaloPresentationPolicy.shouldExpand(
            intent: .expand(.automatic),
            currentExpandedID: nil,
            targetID: "openCode",
            manualOverrideID: "codex"
        ))
        XCTAssertTrue(HaloPresentationPolicy.shouldExpand(
            intent: .expand(.automatic),
            currentExpandedID: nil,
            targetID: "codex",
            manualOverrideID: "codex"
        ))
    }

    func testPointerExitOnlyCollapsesWhenEnabledAndExpanded() {
        XCTAssertTrue(HaloPresentationPolicy.shouldCollapseOnPointerExit(
            expandedID: "openCode",
            collapseOnMouseLeave: true
        ))
        XCTAssertFalse(HaloPresentationPolicy.shouldCollapseOnPointerExit(
            expandedID: nil,
            collapseOnMouseLeave: true
        ))
        XCTAssertFalse(HaloPresentationPolicy.shouldCollapseOnPointerExit(
            expandedID: "openCode",
            collapseOnMouseLeave: false
        ))
    }

    func testManualSelectionWinsCollapsedResolutionOverPriority() {
        let openCode = HaloActivity.openCode(OpenCodeActivity(
            sessions: [], selectedSessionID: nil, messages: [], connection: .connected,
            pendingPermission: nil, errorMessage: nil
        ))
        let codex = HaloActivity.codex(CodexActivity(
            chats: [], selectedChatID: nil, messages: [], connection: .connected,
            pendingApproval: nil, errorMessage: nil
        ))
        let activities = [openCode, codex]

        XCTAssertEqual(
            HaloPresentationPolicy.selectedActivityID(activities, manualOverrideID: "openCode"),
            "openCode"
        )
        XCTAssertEqual(
            HaloPresentationPolicy.selectedActivity(activities, manualOverrideID: nil)?.id,
            "codex"
        )
        XCTAssertEqual(
            HaloPresentationPolicy.selectedActivityID(activities, manualOverrideID: "missing"),
            "codex",
            "a stale override must fall back to priority"
        )
    }
}
