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
}
