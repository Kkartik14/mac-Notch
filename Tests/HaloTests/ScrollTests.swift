import XCTest
@testable import Halo

final class HaloScrollMetricsTests: XCTestCase {
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
