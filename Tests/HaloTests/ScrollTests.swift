import XCTest
@testable import Halo

final class HaloScrollMetricsTests: XCTestCase {
    func testExpandedLayoutAllocatesMoreViewportAsTheNotchGrows() {
        let compact = HaloExpandedLayout(size: CGSize(width: 504, height: 98))
        let spacious = HaloExpandedLayout(size: CGSize(width: 760, height: 203))

        XCTAssertLessThan(compact.railWidth, spacious.railWidth)
        XCTAssertLessThan(compact.railViewportHeight, spacious.railViewportHeight)
        XCTAssertLessThan(
            compact.messageViewportHeight(),
            spacious.messageViewportHeight()
        )
    }

    func testExpandedLayoutReservesSecondaryConversationRows() {
        let layout = HaloExpandedLayout(size: HaloExpandedLayout.defaultSize)
        XCTAssertEqual(
            layout.messageViewportHeight(reservedHeight: 34),
            layout.messageViewportHeight() - 34
        )
        XCTAssertGreaterThanOrEqual(
            layout.messageViewportHeight(reservedHeight: 500),
            24
        )
    }

    func testPlayerLayoutUsesAdditionalNotchHeight() {
        let compact = HaloExpandedLayout(size: CGSize(width: 504, height: 98))
        let spacious = HaloExpandedLayout(size: CGSize(width: 760, height: 203))

        XCTAssertLessThan(compact.playerArtworkSize, spacious.playerArtworkSize)
        XCTAssertLessThan(compact.playerRailArtworkSize, spacious.playerRailArtworkSize)
        XCTAssertLessThan(compact.playerRailViewportHeight, spacious.playerRailViewportHeight)
        XCTAssertLessThanOrEqual(spacious.playerArtworkSize, 130)
        XCTAssertLessThanOrEqual(spacious.playerRailArtworkSize, 48)
    }

    func testContentHeightIncludesOnlyBetweenRowSpacing() {
        XCTAssertEqual(
            HaloScrollMetrics.contentHeight(for: 4, rowHeight: 30, rowSpacing: 10),
            150
        )
        XCTAssertEqual(
            HaloScrollMetrics.contentHeight(for: 1, rowHeight: 30, rowSpacing: 10),
            30
        )
    }

    func testEmptyAndNegativeCountsHaveNoHeight() {
        XCTAssertEqual(HaloScrollMetrics.contentHeight(for: 0), 0)
        XCTAssertEqual(HaloScrollMetrics.contentHeight(for: -4), 0)
    }

    func testViewportClampsContentToMaximumHeight() {
        XCTAssertEqual(
            HaloScrollMetrics.viewportHeight(
                for: 3,
                rowHeight: 30,
                rowSpacing: 10,
                maximumHeight: 112
            ),
            110
        )
        XCTAssertEqual(
            HaloScrollMetrics.viewportHeight(
                for: 4,
                rowHeight: 30,
                rowSpacing: 10,
                maximumHeight: 112
            ),
            112
        )
    }

    func testScrollThresholdIsStrictlyAboveViewport() {
        XCTAssertFalse(
            HaloScrollMetrics.needsScroll(
                for: 3,
                rowHeight: 30,
                rowSpacing: 10,
                maximumHeight: 112
            )
        )
        XCTAssertTrue(
            HaloScrollMetrics.needsScroll(
                for: 4,
                rowHeight: 30,
                rowSpacing: 10,
                maximumHeight: 111
            )
        )
    }

    func testInvalidDimensionsAreSanitized() {
        XCTAssertEqual(
            HaloScrollMetrics.contentHeight(for: 2, rowHeight: -20, rowSpacing: -5),
            0
        )
        XCTAssertEqual(
            HaloScrollMetrics.viewportHeight(
                for: 2,
                rowHeight: 30,
                rowSpacing: 10,
                maximumHeight: -1
            ),
            0
        )
    }
}
