import XCTest
@testable import Halo

final class SessionActivityTests: XCTestCase {
    func testOnlyRunningCodexChatsAreMarkedAsStreaming() {
        XCTAssertTrue(DeveloperSessionActivity.isStreaming(CodexThreadState.running))

        for state: CodexThreadState in [.idle, .queued, .waiting, .completed, .failed, .interrupted] {
            XCTAssertFalse(DeveloperSessionActivity.isStreaming(state), "\(state) is not a streaming state")
        }
    }

    func testOnlyRunningClaudeSessionsAreMarkedAsStreaming() {
        XCTAssertTrue(DeveloperSessionActivity.isStreaming(ClaudeCodeSessionState.running))

        for state: ClaudeCodeSessionState in [.idle, .waiting, .failed, .interrupted] {
            XCTAssertFalse(DeveloperSessionActivity.isStreaming(state), "\(state) is not a streaming state")
        }
    }
}
