import XCTest
@testable import Halo

final class RefreshCoalescerTests: XCTestCase {
    func testConcurrentRequestsCollapseIntoOneFollowUp() {
        var coalescer = RefreshCoalescer<String>()

        XCTAssertTrue(coalescer.begin("session"))
        XCTAssertFalse(coalescer.begin("session"))
        XCTAssertFalse(coalescer.begin("session"))

        XCTAssertTrue(coalescer.finish("session"))
        XCTAssertTrue(coalescer.begin("session"))
        XCTAssertFalse(coalescer.finish("session"))
    }

    func testDifferentSessionsRefreshIndependently() {
        var coalescer = RefreshCoalescer<String>()

        XCTAssertTrue(coalescer.begin("one"))
        XCTAssertTrue(coalescer.begin("two"))
        XCTAssertFalse(coalescer.begin("one"))
        XCTAssertTrue(coalescer.finish("one"))
        XCTAssertTrue(coalescer.begin("one"))
        XCTAssertFalse(coalescer.finish("one"))
        XCTAssertFalse(coalescer.finish("two"))
    }

    func testResetInvalidatesInflightAndPendingState() {
        var coalescer = RefreshCoalescer<String>()
        XCTAssertTrue(coalescer.begin("session"))
        XCTAssertFalse(coalescer.begin("session"))

        coalescer.reset()

        XCTAssertTrue(coalescer.begin("session"))
        XCTAssertFalse(coalescer.finish("session"))
    }
}
