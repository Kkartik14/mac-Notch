import XCTest
@testable import Halo

final class CodexProtocolTests: XCTestCase {
    func testActiveApprovalStatusMapsToWaiting() {
        let state = CodexThreadState.fromJSON([
            "type": "active",
            "activeFlags": ["waitingOnApproval"]
        ])

        XCTAssertEqual(state, .waiting)
        XCTAssertEqual(state.compactLabel.count, 3)
    }

    func testThreadMetadataUsesNameThenPreviewAndKeepsRepositoryContext() {
        let named = CodexMonitor.parseChat([
            "id": "thread-1",
            "name": "Fix the player",
            "preview": "A longer first message",
            "cwd": "/Users/test/alcove",
            "gitInfo": ["branch": "feature/codex"],
            "createdAt": 90,
            "updatedAt": 100,
            "status": ["type": "notLoaded"]
        ])
        let fallback = CodexMonitor.parseChat([
            "id": "thread-2",
            "preview": "Use the preview as the title\nwith more context",
            "cwd": "/Users/test/project",
            "createdAt": 90,
            "updatedAt": 100,
            "status": ["type": "idle"]
        ])

        XCTAssertEqual(named?.title, "Fix the player")
        XCTAssertEqual(named?.repositoryName, "alcove")
        XCTAssertEqual(named?.branch, "feature/codex")
        XCTAssertEqual(fallback?.title, "Use the preview as the title")
    }

    func testDefaultChatSelectionUsesNewestCreatedChat() {
        let older = CodexMonitor.parseChat([
            "id": "thread-older",
            "preview": "Older session",
            "cwd": "/Users/test/alcove",
            "createdAt": 100,
            "updatedAt": 300,
            "status": ["type": "idle"]
        ])!
        let latest = CodexMonitor.parseChat([
            "id": "thread-latest",
            "preview": "Latest session",
            "cwd": "/Users/test/alcove",
            "createdAt": 200,
            "updatedAt": 200,
            "status": ["type": "idle"]
        ])!

        let activity = CodexActivity(
            chats: [older, latest],
            selectedChatID: nil,
            messages: [],
            connection: .connected,
            pendingApproval: nil,
            errorMessage: nil
        )

        XCTAssertEqual(CodexChat.newest(in: [older, latest])?.id, "thread-latest")
        XCTAssertEqual(activity.selectedChat?.id, "thread-latest")
    }

    func testPaginatedThreadsCanBeResumedWhenCapabilityIsUnspecified() {
        let chat = CodexMonitor.parseChat([
            "id": "thread-paginated",
            "preview": "A paginated Codex session",
            "cwd": "/Users/test/alcove",
            "historyMode": "paginated",
            "canAcceptDirectInput": NSNull(),
            "status": ["type": "notLoaded"]
        ])

        XCTAssertEqual(chat?.historyMode, .paginated)
        XCTAssertEqual(chat?.canAcceptDirectInput, true)
        XCTAssertEqual(chat?.isReadOnlyHistory, false)
        XCTAssertEqual(chat?.canSendDirectInput, true)
    }

    func testExplicitlyReadOnlyChatRemainsBlocked() {
        let chat = CodexMonitor.parseChat([
            "id": "thread-read-only",
            "preview": "A read-only Codex session",
            "cwd": "/Users/test/alcove",
            "historyMode": "paginated",
            "canAcceptDirectInput": false,
            "status": ["type": "notLoaded"]
        ])

        XCTAssertEqual(chat?.canAcceptDirectInput, false)
        XCTAssertEqual(chat?.isReadOnlyHistory, true)
        XCTAssertEqual(chat?.canSendDirectInput, false)
    }

    func testVisibleConversationItemsExcludePrivateReasoning() {
        let entries: [[String: Any]] = [
            ["item": [
                "type": "userMessage",
                "id": "user-1",
                "content": [["type": "text", "text": "Inspect the app"]]
            ]],
            ["item": [
                "type": "reasoning",
                "id": "reasoning-1",
                "summary": ["private reasoning"]
            ]],
            ["item": [
                "type": "commandExecution",
                "id": "command-1",
                "command": "swift build",
                "status": "completed"
            ]],
            ["item": [
                "type": "agentMessage",
                "id": "agent-1",
                "text": "The build is clean."
            ]]
        ]

        let messages = CodexMonitor.parseMessages(from: entries)

        XCTAssertEqual(messages.map(\.id), ["user-1", "command-1", "agent-1"])
        XCTAssertEqual(messages[1].text, "$ swift build")
        XCTAssertEqual(messages[1].detail, "Completed")
        XCTAssertEqual(messages[2].role, .assistant)
    }

    func testWorkStatusIsKeptAsOptionalSecondaryDetail() {
        let message = CodexMonitor.parseMessage([
            "type": "commandExecution",
            "id": "command-1",
            "command": "swift test",
            "status": "inProgress"
        ])

        XCTAssertEqual(message?.role, .tool)
        XCTAssertEqual(message?.text, "$ swift test")
        XCTAssertEqual(message?.detail, "Working")
    }

    func testWorkActivityCanBeHiddenWithoutHidingConversation() {
        let activity = CodexActivity(
            chats: [],
            selectedChatID: nil,
            messages: [
                CodexMessage(id: "user-1", role: .user, text: "Inspect the app"),
                CodexMessage(id: "work-1", role: .tool, text: "$ swift test", detail: "Completed"),
                CodexMessage(id: "assistant-1", role: .assistant, text: "The tests pass.")
            ],
            connection: .connected,
            pendingApproval: nil,
            errorMessage: nil
        )

        XCTAssertEqual(activity.visibleMessages(showWorkActivity: false).map(\.id), ["user-1", "assistant-1"])
        XCTAssertEqual(activity.visibleMessages(showWorkActivity: true).map(\.id), ["user-1", "work-1", "assistant-1"])
    }

    func testActivityUsesApprovalLabelInCompactPill() {
        let activity = CodexActivity(
            chats: [],
            selectedChatID: nil,
            messages: [],
            connection: .connected,
            pendingApproval: CodexApproval(
                requestKey: "7",
                kind: .command,
                title: "Allow command",
                detail: "swift test"
            ),
            errorMessage: nil
        )

        XCTAssertEqual(activity.compactLabel, "ASK")
    }

    func testCodexSitsAbovePassiveActivityButBelowNotifications() {
        let codex = HaloActivity.codex(CodexActivity(
            chats: [],
            selectedChatID: nil,
            messages: [],
            connection: .connected,
            pendingApproval: nil,
            errorMessage: nil
        ))
        let weather = HaloActivity.weather(WeatherActivity(temperatureC: 20, condition: "Clear", symbol: "sun.max"))
        let notification = HaloActivity.notification(NotificationActivity(appName: "Messages", sender: "A", body: "B", icon: "message"))

        XCTAssertGreaterThan(HaloCenter.rank(of: codex), HaloCenter.rank(of: weather))
        XCTAssertLessThan(HaloCenter.rank(of: codex), HaloCenter.rank(of: notification))
    }
}
