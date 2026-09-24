import XCTest
@testable import Halo

final class ClaudeCodeProtocolTests: XCTestCase {
    func testCommandArgumentsUseStructuredStreamingAndResumeTheSelectedSession() {
        let arguments = ClaudeCodeMonitor.commandArguments(
            sessionID: "session-1",
            prompt: "Continue this session"
        )

        XCTAssertEqual(arguments.first, "-p")
        XCTAssertTrue(arguments.contains("--output-format"))
        XCTAssertTrue(arguments.contains("stream-json"))
        XCTAssertTrue(arguments.contains("--include-partial-messages"))
        XCTAssertTrue(arguments.contains("--permission-mode"))
        XCTAssertTrue(arguments.contains("manual"))
        XCTAssertEqual(arguments.suffix(3), ["--resume", "session-1", "Continue this session"])
    }

    func testNewSessionArgumentsCarryAValidRequestedSessionID() {
        let arguments = ClaudeCodeMonitor.commandArguments(
            sessionID: nil,
            prompt: "Inspect the project",
            requestedSessionID: "session-requested"
        )

        XCTAssertTrue(arguments.contains("--session-id"))
        XCTAssertTrue(arguments.contains("session-requested"))
        XCTAssertEqual(arguments.last, "Inspect the project")
        XCTAssertFalse(arguments.contains("--resume"))
    }

    func testStreamingTextDeltaIsParsedWithoutTerminalScraping() {
        let event: [String: Any] = [
            "type": "stream_event",
            "event": [
                "type": "content_block_delta",
                "delta": [
                    "type": "text_delta",
                    "text": "hello"
                ]
            ]
        ]

        XCTAssertEqual(ClaudeCodeMonitor.parseStreamTextDelta(event), "hello")
    }

    func testStreamingToolStartProducesAVisibleWorkMessage() {
        let event: [String: Any] = [
            "type": "stream_event",
            "event": [
                "type": "content_block_start",
                "content_block": [
                    "type": "tool_use",
                    "id": "tool-1",
                    "name": "Bash",
                    "input": ["command": "swift test"]
                ]
            ]
        ]

        let message = ClaudeCodeMonitor.parseStreamToolUse(event)

        XCTAssertEqual(message?.id, "tool-1")
        XCTAssertEqual(message?.role, .tool)
        XCTAssertEqual(message?.text, "$ swift test")
        XCTAssertEqual(message?.detail, "swift test")
        XCTAssertTrue(message?.isStreaming == true)
    }

    func testConversationScrollTokenChangesAsAssistantTextStreams() {
        let session = ClaudeCodeSession(
            id: "session-1",
            title: "Chat",
            preview: "",
            directory: "/tmp/halo",
            createdAt: Date(timeIntervalSince1970: 1),
            updatedAt: Date(timeIntervalSince1970: 2),
            state: .running,
            model: "sonnet"
        )
        var activity = ClaudeCodeActivity(
            sessions: [session],
            selectedSessionID: session.id,
            messages: [ClaudeCodeMessage(id: "assistant-1", role: .assistant, text: "Hello", isStreaming: true)],
            connection: .connected,
            errorMessage: nil
        )
        let beforeDelta = activity.conversationScrollToken(showWorkActivity: false)

        activity.messages[0].text += " there"

        XCTAssertNotEqual(
            activity.conversationScrollToken(showWorkActivity: false),
            beforeDelta
        )
    }

    func testLiveTextDeltaPublishesUpdatedActivity() throws {
        let monitor = ClaudeCodeMonitor()
        var published: [ClaudeCodeActivity] = []
        monitor.onActivity = { published.append($0) }

        monitor.handleStreamObject([
            "type": "system",
            "subtype": "init",
            "session_id": "session-live",
            "cwd": "/tmp",
            "model": "sonnet"
        ])
        let previous = try XCTUnwrap(published.last)
        let previousToken = previous.conversationScrollToken(showWorkActivity: false)
        let previousCount = published.count

        monitor.handleStreamObject([
            "type": "stream_event",
            "event": [
                "type": "content_block_delta",
                "delta": ["type": "text_delta", "text": "hello"]
            ]
        ])

        let updated = try XCTUnwrap(published.last)
        XCTAssertGreaterThan(published.count, previousCount)
        XCTAssertEqual(updated.messages.last?.text, "hello")
        XCTAssertNotEqual(
            updated.conversationScrollToken(showWorkActivity: false),
            previousToken
        )
    }

    func testExternalTranscriptChangesRefreshSelectedConversation() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("HaloClaudeTranscript-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("projects", isDirectory: true)
        let projectDirectory = root.appendingPathComponent("fixture-project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDirectory, withIntermediateDirectories: true)
        let transcriptURL = projectDirectory.appendingPathComponent("session-live.jsonl")

        func line(_ uuid: String, _ text: String, sessionID: String = "session-live") throws -> Data {
            var data = try JSONSerialization.data(withJSONObject: [
                "type": "user",
                "uuid": uuid,
                "sessionId": sessionID,
                "message": ["role": "user", "content": text]
            ])
            data.append(0x0A)
            return data
        }

        try line("user-1", "first prompt").write(to: transcriptURL)

        let monitor = ClaudeCodeMonitor(transcriptRootURL: root)
        let firstLoad = expectation(description: "initial external transcript loaded")
        let updatedLoad = expectation(description: "external transcript refreshes after append")
        let newSession = expectation(description: "new external transcript appears in the session list")
        let deletedSession = expectation(description: "deleted external transcript leaves the session list")
        var sawFirstLoad = false
        var sawUpdatedLoad = false
        var sawNewSession = false
        var sawDeletedSession = false
        monitor.onActivity = { activity in
            if !sawFirstLoad, activity.messages.contains(where: { $0.text == "first prompt" }) {
                sawFirstLoad = true
                firstLoad.fulfill()
            }
            if !sawUpdatedLoad, activity.messages.contains(where: { $0.text == "second prompt" }) {
                sawUpdatedLoad = true
                updatedLoad.fulfill()
            }
            if !sawNewSession, activity.sessions.contains(where: { $0.id == "session-new" }) {
                sawNewSession = true
                newSession.fulfill()
            }
            if sawNewSession,
               !sawDeletedSession,
               !activity.sessions.contains(where: { $0.id == "session-new" }) {
                sawDeletedSession = true
                deletedSession.fulfill()
            }
        }

        monitor.refreshSessions()
        wait(for: [firstLoad], timeout: 5)

        let handle = try FileHandle(forWritingTo: transcriptURL)
        try handle.seekToEnd()
        try handle.write(contentsOf: line("user-2", "second prompt"))
        try handle.close()
        wait(for: [updatedLoad], timeout: 8)

        let newTranscriptURL = projectDirectory.appendingPathComponent("session-new.jsonl")
        try line("user-new", "new session prompt", sessionID: "session-new").write(to: newTranscriptURL)
        wait(for: [newSession], timeout: 8)

        try FileManager.default.removeItem(at: newTranscriptURL)
        wait(for: [deletedSession], timeout: 8)

        if Thread.isMainThread {
            monitor.stop()
        } else {
            DispatchQueue.main.sync { monitor.stop() }
        }
        try FileManager.default.removeItem(at: root.deletingLastPathComponent())
    }

    func testTranscriptParserKeepsConversationAndUsefulToolWorkButOmitsThinking() {
        let entries: [[String: Any]] = [
            [
                "type": "user",
                "uuid": "user-1",
                "message": ["role": "user", "content": "Inspect the app"]
            ],
            [
                "type": "assistant",
                "uuid": "assistant-1",
                "message": [
                    "id": "message-1",
                    "role": "assistant",
                    "content": [
                        ["type": "thinking", "thinking": "private reasoning"],
                        ["type": "text", "text": "I found the issue."],
                        [
                            "type": "tool_use",
                            "id": "tool-1",
                            "name": "Bash",
                            "input": ["command": "swift test"]
                        ]
                    ]
                ]
            ]
        ]

        let messages = ClaudeCodeMonitor.parseTranscriptMessages(from: entries)

        XCTAssertEqual(messages.map(\.role), [.user, .assistant, .tool])
        XCTAssertEqual(messages[0].text, "Inspect the app")
        XCTAssertEqual(messages[1].text, "I found the issue.")
        XCTAssertEqual(messages[2].text, "$ swift test")
        XCTAssertEqual(messages[2].detail, "swift test")
        XCTAssertFalse(messages.contains(where: { $0.text.contains("private reasoning") }))
    }

    func testSessionMetadataUsesCustomTitleAndLatestPrompt() {
        let entries: [[String: Any]] = [
            [
                "type": "system",
                "sessionId": "session-1",
                "cwd": "/Users/test/halo",
                "timestamp": "2026-09-19T10:00:00.000Z"
            ],
            [
                "type": "user",
                "sessionId": "session-1",
                "timestamp": "2026-09-19T10:01:00.000Z",
                "message": ["role": "user", "content": "First prompt"]
            ],
            [
                "type": "custom-title",
                "sessionId": "session-1",
                "customTitle": "Halo Claude work"
            ],
            [
                "type": "user",
                "sessionId": "session-1",
                "timestamp": "2026-09-19T10:03:00.000Z",
                "message": ["role": "user", "content": "Continue the fix"]
            ]
        ]

        let session = ClaudeCodeMonitor.parseSessionMetadata(
            from: entries,
            sessionID: "fallback",
            transcriptPath: "/tmp/session.jsonl",
            fileDate: Date(timeIntervalSince1970: 0)
        )

        XCTAssertEqual(session?.id, "session-1")
        XCTAssertEqual(session?.title, "Halo Claude work")
        XCTAssertEqual(session?.preview, "Continue the fix")
        XCTAssertEqual(session?.repositoryName, "halo")
        XCTAssertEqual(session?.transcriptPath, "/tmp/session.jsonl")
    }

    func testPermissionDenialsExposeToolNamesForAUsefulError() {
        let denials = ClaudeCodeMonitor.parsePermissionDenials([
            ["tool_name": "Bash", "reason": "not allowed"],
            ["toolName": "Edit"]
        ])

        XCTAssertEqual(denials, ["Bash", "Edit"])
    }

    func testWorkActivityCanBeHiddenWithoutHidingConversation() {
        let session = ClaudeCodeSession(
            id: "session-1",
            title: "Chat",
            preview: "",
            directory: "/tmp/halo",
            createdAt: Date(timeIntervalSince1970: 1),
            updatedAt: Date(timeIntervalSince1970: 2),
            state: .idle,
            model: "sonnet"
        )
        let activity = ClaudeCodeActivity(
            sessions: [session],
            selectedSessionID: session.id,
            messages: [
                ClaudeCodeMessage(id: "user", role: .user, text: "Hi"),
                ClaudeCodeMessage(id: "work", role: .tool, text: "$ swift test"),
                ClaudeCodeMessage(id: "assistant", role: .assistant, text: "Done")
            ],
            connection: .connected,
            errorMessage: nil
        )

        XCTAssertEqual(activity.visibleMessages(showWorkActivity: false).map(\.role), [.user, .assistant])
        XCTAssertEqual(activity.visibleMessages(showWorkActivity: true).count, 3)
        XCTAssertEqual(activity.compactLabel, "RDY")
    }
}
