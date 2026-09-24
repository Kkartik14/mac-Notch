import XCTest
@testable import Halo

final class OpenCodeProtocolTests: XCTestCase {
    func testLocalServerUsesLoopbackServerModeAndV2Routes() {
        XCTAssertEqual(
            OpenCodeMonitor.localServerArguments,
            ["serve", "--hostname", "127.0.0.1", "--port", "0"]
        )
        XCTAssertEqual(OpenCodeMonitor.apiPath("/session"), "/api/session")
        XCTAssertEqual(OpenCodeConnectionState.connected.compactLabel, "RDY")
    }

    func testBusyAndPermissionStatusesMapToUsefulStates() {
        XCTAssertEqual(OpenCodeSessionState.fromStatus(["type": "busy"]), .running)
        XCTAssertEqual(OpenCodeSessionState.fromStatus(["type": "retry"]), .running)
        XCTAssertEqual(OpenCodeSessionState.fromStatus(["type": "idle"]), .idle)
        XCTAssertEqual(OpenCodeSessionState.running.compactLabel, "RUN")
        XCTAssertEqual(OpenCodeSessionState.waiting.compactLabel, "ASK")
    }

    func testSessionMetadataUsesTitleAndMilliseconds() {
        let session = OpenCodeMonitor.parseSession([
            "id": "ses_new",
            "title": "Fix the activity rail",
            "directory": "/tmp/halo",
            "time": [
                "created": 1_700_000_000_000,
                "updated": 1_700_000_000_500
            ],
            "model": ["id": "gpt-5", "providerID": "openai"]
        ])

        XCTAssertEqual(session?.title, "Fix the activity rail")
        XCTAssertEqual(session?.repositoryName, "halo")
        XCTAssertEqual(session?.model, "gpt-5")
        XCTAssertEqual(session?.createdAt.timeIntervalSince1970 ?? 0, 1_700_000_000, accuracy: 0.001)
        XCTAssertEqual(session?.updatedAt.timeIntervalSince1970 ?? 0, 1_700_000_000.5, accuracy: 0.001)
    }

    func testNewestSessionUsesCreationThenUpdateTime() {
        let older = OpenCodeSession(
            id: "ses_old",
            title: "Older",
            preview: "",
            directory: "/tmp/old",
            createdAt: Date(timeIntervalSince1970: 10),
            updatedAt: Date(timeIntervalSince1970: 20),
            state: .idle,
            agent: nil,
            model: nil
        )
        let newer = OpenCodeSession(
            id: "ses_new",
            title: "Newer",
            preview: "",
            directory: "/tmp/new",
            createdAt: Date(timeIntervalSince1970: 30),
            updatedAt: Date(timeIntervalSince1970: 31),
            state: .idle,
            agent: nil,
            model: nil
        )

        XCTAssertEqual(OpenCodeSession.newest(in: [older, newer])?.id, "ses_new")
    }

    func testMessagesKeepConversationAndExposeOptionalWork() {
        let entries: [[String: Any]] = [[
            "info": [
                "id": "msg_user",
                "role": "user",
                "time": ["created": 1]
            ],
            "parts": [[
                "id": "prt_user",
                "messageID": "msg_user",
                "sessionID": "ses_1",
                "type": "text",
                "text": "Inspect the app"
            ]]
        ], [
            "info": [
                "id": "msg_assistant",
                "role": "assistant",
                "time": ["created": 2, "completed": 3]
            ],
            "parts": [
                [
                    "id": "prt_text",
                    "messageID": "msg_assistant",
                    "sessionID": "ses_1",
                    "type": "text",
                    "text": "I found the issue."
                ],
                [
                    "id": "prt_tool",
                    "messageID": "msg_assistant",
                    "sessionID": "ses_1",
                    "type": "tool",
                    "callID": "call_1",
                    "tool": "bash",
                    "state": ["status": "completed", "title": "Completed"]
                ],
                [
                    "id": "prt_reasoning",
                    "messageID": "msg_assistant",
                    "sessionID": "ses_1",
                    "type": "reasoning",
                    "text": "private reasoning"
                ]
            ]
        ]]

        let messages = OpenCodeMonitor.parseMessages(from: entries)
        XCTAssertEqual(messages.map(\.role), [.user, .assistant, .tool])
        XCTAssertEqual(messages[0].text, "Inspect the app")
        XCTAssertEqual(messages[1].text, "I found the issue.")
        XCTAssertEqual(messages[2].text, "bash")
        XCTAssertEqual(messages[2].detail, "Completed")
        XCTAssertFalse(messages.contains(where: { $0.text == "private reasoning" }))
    }

    func testSessionAndMessageResponsesAcceptLegacyAndWrappedShapes() throws {
        let sessions = try XCTUnwrap("""
        [{"id":"ses_1","title":"One","directory":"/tmp/one","time":{"created":1700000000000,"updated":1700000000000}}]
        """.data(using: .utf8))
        XCTAssertEqual(OpenCodeMonitor.parseSessions(from: sessions).count, 1)

        let wrappedMessages = try XCTUnwrap("""
        {"data":[{"info":{"id":"msg_1","role":"user","time":{"created":1}},"parts":[{"id":"prt_1","messageID":"msg_1","sessionID":"ses_1","type":"text","text":"hello"}]}]}
        """.data(using: .utf8))
        XCTAssertEqual(OpenCodeMonitor.parseMessageEntries(from: wrappedMessages).count, 1)

        let v2Session = try XCTUnwrap("""
        {"data":[{"id":"ses_v2","title":"V2 session","location":{"directory":"/tmp/v2"},"time":{"created":1700000000000,"updated":1700000000500}}]}
        """.data(using: .utf8))
        XCTAssertEqual(OpenCodeMonitor.parseSessions(from: v2Session).first?.directory, "/tmp/v2")

        let v2Messages = try XCTUnwrap("""
        {"data":[
          {"id":"msg_v2_assistant","type":"assistant","time":{"created":2,"completed":3},"finish":"stop","content":[{"type":"text","text":"done"},{"type":"tool","id":"call_v2","name":"bash","state":{"status":"completed","title":"Completed"},"time":{"created":2}}]},
          {"id":"msg_v2_user","type":"user","time":{"created":1},"text":"inspect"}
        ]}
        """.data(using: .utf8))
        let parsedV2Messages = OpenCodeMonitor.parseMessages(from: OpenCodeMonitor.parseMessageEntries(from: v2Messages))
        XCTAssertEqual(parsedV2Messages.map(\.role), [.user, .assistant, .tool])
        XCTAssertEqual(parsedV2Messages[0].text, "inspect")
        XCTAssertEqual(parsedV2Messages[1].text, "done")
        XCTAssertEqual(parsedV2Messages[2].text, "bash")
    }

    func testSSEPayloadSupportsDirectAndGlobalEventShapes() throws {
        let data = try XCTUnwrap("""
        data: {"id":"evt_1","type":"session.idle","properties":{"sessionID":"ses_1"}}

        data: {"payload":{"id":"evt_2","type":"session.status","properties":{"sessionID":"ses_1","status":{"type":"busy"}}}}

        data: {"id":"evt_3","type":"server.connected","data":{}}

        """.data(using: .utf8))

        let events = OpenCodeMonitor.parseSSEEvents(from: data)
        XCTAssertEqual(events.count, 3)
        XCTAssertEqual(events[0]["type"] as? String, "session.idle")
        XCTAssertEqual(events[1]["type"] as? String, "session.status")
        XCTAssertNotNil(events[2]["properties"] as? [String: Any])
    }

    func testPromptAndPermissionBodiesMatchOpenCodeRoutes() {
        let prompt = OpenCodeMonitor.promptBody(text: "Continue this session")
        XCTAssertEqual(prompt["text"] as? String, "Continue this session")

        let permission = OpenCodeMonitor.permissionBody(.once)
        XCTAssertEqual(permission["reply"] as? String, "once")
    }

    func testActivityFiltersWorkAndUsesStreamingToken() {
        let session = OpenCodeSession(
            id: "ses_1",
            title: "Chat",
            preview: "",
            directory: "/tmp/halo",
            createdAt: Date(),
            updatedAt: Date(),
            state: .idle,
            agent: nil,
            model: nil
        )
        let initial = OpenCodeActivity(
            sessions: [session],
            selectedSessionID: session.id,
            messages: [
                OpenCodeMessage(id: "user", role: .user, text: "Hi"),
                OpenCodeMessage(id: "work", role: .tool, text: "bash"),
                OpenCodeMessage(id: "assistant", role: .assistant, text: "Working", isStreaming: true)
            ],
            connection: .connected,
            pendingPermission: nil,
            errorMessage: nil
        )
        var changed = initial
        changed.messages[2].text = "Working more"

        XCTAssertEqual(initial.visibleMessages(showWorkActivity: false).map(\.role), [.user, .assistant])
        XCTAssertEqual(initial.visibleMessages(showWorkActivity: true).count, 3)
        XCTAssertNotEqual(
            initial.conversationScrollToken(showWorkActivity: false),
            changed.conversationScrollToken(showWorkActivity: false)
        )
    }

    func testLiveTextDeltaPublishesUpdatedActivity() throws {
        let monitor = OpenCodeMonitor()
        var published: [OpenCodeActivity] = []
        monitor.onActivity = { published.append($0) }

        monitor.handleEvent([
            "type": "session.created",
            "properties": ["info": ["id": "session-live", "title": "Live chat", "directory": "/tmp"]]
        ])
        let previous = try XCTUnwrap(published.last)
        let previousToken = previous.conversationScrollToken(showWorkActivity: false)
        let previousCount = published.count

        monitor.handleEvent([
            "type": "session.next.text.delta",
            "properties": [
                "sessionID": "session-live",
                "assistantMessageID": "message-live",
                "delta": "hello"
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
}
