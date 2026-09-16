import Combine
import Foundation

// MARK: - Codex activity model

/// The small amount of Codex state Halo needs to render the developer
/// activity. The app-server protocol remains behind CodexMonitor so the UI
/// never needs to know about JSON-RPC or rollout storage.
enum CodexConnectionState: Equatable {
    case stopped
    case starting
    case connected
    case unavailable
    case failed

    var title: String {
        switch self {
        case .stopped: return "Stopped"
        case .starting: return "Connecting"
        case .connected: return "Connected"
        case .unavailable: return "Unavailable"
        case .failed: return "Connection error"
        }
    }

    var compactLabel: String {
        switch self {
        case .stopped: return "OFF"
        case .starting: return "..."
        case .connected: return "COD"
        case .unavailable: return "N/A"
        case .failed: return "ERR"
        }
    }
}

enum CodexThreadState: Equatable {
    case idle
    case running
    case queued
    case waiting
    case completed
    case failed
    case interrupted

    var title: String {
        switch self {
        case .idle: return "Ready"
        case .running: return "Working"
        case .queued: return "Queued"
        case .waiting: return "Needs your decision"
        case .completed: return "Completed"
        case .failed: return "Failed"
        case .interrupted: return "Interrupted"
        }
    }

    /// Kept to three characters because this is also used in Halo's compact
    /// top-surface pill.
    var compactLabel: String {
        switch self {
        case .idle: return "RDY"
        case .running: return "RUN"
        case .queued: return "QUE"
        case .waiting: return "ASK"
        case .completed: return "OK"
        case .failed: return "ERR"
        case .interrupted: return "STP"
        }
    }

    static func fromJSON(_ value: Any?) -> CodexThreadState {
        guard let object = value as? [String: Any],
              let type = object["type"] as? String else {
            return .idle
        }

        switch type {
        case "active":
            let flags = object["activeFlags"] as? [String] ?? []
            if flags.contains("waitingOnApproval") || flags.contains("waitingOnUserInput") {
                return .waiting
            }
            return .running
        case "systemError": return .failed
        case "idle": return .idle
        case "notLoaded": return .idle
        default: return .idle
        }
    }

    static func fromTurnJSON(_ value: Any?) -> CodexThreadState? {
        guard let status = value as? String else { return nil }
        switch status {
        case "inProgress": return .running
        case "completed": return .completed
        case "failed": return .failed
        case "interrupted": return .interrupted
        default: return nil
        }
    }
}

enum CodexHistoryMode: String, Equatable {
    case legacy
    case paginated
}

struct CodexChat: Identifiable, Equatable {
    let id: String
    var title: String
    var preview: String
    var cwd: String
    var branch: String?
    var createdAt: Date
    var updatedAt: Date
    var state: CodexThreadState
    var canAcceptDirectInput: Bool
    var model: String?
    var historyMode: CodexHistoryMode?

    /// A list response may omit this capability for an unloaded history. Halo
    /// lets the app-server resolve that state through thread/resume instead of
    /// treating every paginated record as permanently read-only.
    var isReadOnlyHistory: Bool { !canAcceptDirectInput }
    var canSendDirectInput: Bool { canAcceptDirectInput && !isReadOnlyHistory }

    static func newest(in chats: [CodexChat]) -> CodexChat? {
        chats.max {
            if $0.createdAt != $1.createdAt {
                return $0.createdAt < $1.createdAt
            }
            if $0.updatedAt != $1.updatedAt {
                return $0.updatedAt < $1.updatedAt
            }
            return $0.id < $1.id
        }
    }

    var repositoryName: String {
        let trimmed = cwd.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return trimmed.split(separator: "/").last.map(String.init) ?? "Local workspace"
    }
}

enum CodexMessageRole: String, Equatable {
    case user
    case assistant
    case tool
}

struct CodexMessage: Identifiable, Equatable {
    let id: String
    var role: CodexMessageRole
    var text: String
    /// Secondary context such as a command status. The view can keep this
    /// hidden in the compact WORK presentation without losing the data.
    var detail: String? = nil
    var isStreaming: Bool = false
}

enum CodexApprovalKind: String, Equatable {
    case command
    case fileChange
}

struct CodexApproval: Identifiable, Equatable {
    let requestKey: String
    let kind: CodexApprovalKind
    let title: String
    let detail: String

    var id: String { requestKey }
}

enum CodexApprovalDecision: String {
    case accept
    case decline
    case cancel
}

struct CodexActivity: Equatable {
    var chats: [CodexChat]
    var selectedChatID: String?
    var messages: [CodexMessage]
    var connection: CodexConnectionState
    var pendingApproval: CodexApproval?
    var errorMessage: String?

    var selectedChat: CodexChat? {
        guard let selectedChatID else { return CodexChat.newest(in: chats) }
        return chats.first(where: { $0.id == selectedChatID }) ?? CodexChat.newest(in: chats)
    }

    var selectedState: CodexThreadState {
        selectedChat?.state ?? .idle
    }

    var compactLabel: String {
        if pendingApproval != nil { return "ASK" }
        if selectedChat != nil { return selectedState.compactLabel }
        return connection.compactLabel
    }

    func visibleMessages(showWorkActivity: Bool) -> [CodexMessage] {
        guard !showWorkActivity else { return messages }
        return messages.filter { $0.role != .tool }
    }

    /// A small content token lets the shared scroll container distinguish a
    /// streaming delta from an unchanged message list and keep the newest
    /// Codex output in view.
    func conversationScrollToken(showWorkActivity: Bool) -> String {
        visibleMessages(showWorkActivity: showWorkActivity)
            .map { message in
                [message.id, message.text, String(message.isStreaming)].joined(separator: "\u{1F}")
            }
            .joined(separator: "\u{1E}")
    }
}

// MARK: - Codex app-server client

/// A deliberately small JSONL client for `codex app-server`.
///
/// Codex owns authentication, model access, approvals, and rollout history.
/// Halo only hosts the local app-server process and renders the events it
/// publishes. No API key is read or stored by Halo.
final class CodexMonitor: ObservableObject {
    @Published private(set) var chats: [CodexChat] = []
    @Published private(set) var selectedChatID: String?
    @Published private(set) var messages: [CodexMessage] = []
    @Published private(set) var connection: CodexConnectionState = .stopped
    @Published private(set) var pendingApproval: CodexApproval?
    @Published private(set) var errorMessage: String?

    var onActivity: ((CodexActivity) -> Void)?

    private let ioQueue = DispatchQueue(label: "com.tryhalo.halo.codex.io")
    private let writeQueue = DispatchQueue(label: "com.tryhalo.halo.codex.write")
    private var process: Process?
    private var inputHandle: FileHandle?
    private var outputHandle: FileHandle?
    private var errorHandle: FileHandle?
    private var outputBuffer = Data()
    private var nextRequestID = 1
    private var pendingRequests: [String: PendingRequest] = [:]
    private var pendingTurnText: [String: String] = [:]
    private var queuedMessageTexts: [String: [String]] = [:]
    private var queuedThreadIDs = Set<String>()
    private var externalHandoffMessageTexts: [String: [String]] = [:]
    private var externalHandoffBaselineMessageIDs: [String: Set<String>] = [:]
    private var externalReplySeen = Set<String>()
    private var queuedRefreshTimer: Timer?
    private var queuedRefreshThreadIDs = Set<String>()
    private var queuedRefreshDeadlines: [String: Date] = [:]
    private var loadedThreadIDs = Set<String>()
    private var currentTurnIDs: [String: String] = [:]
    private var messagesByThread: [String: [CodexMessage]] = [:]
    private var serverRequestIDs: [String: Any] = [:]
    private var isStopping = false
    private var stderrBuffer = ""
    private var processGeneration = 0

    private struct PendingRequest {
        var method: String
        var threadID: String?
    }

    var activity: CodexActivity {
        CodexActivity(
            chats: chats,
            selectedChatID: selectedChatID,
            messages: messages,
            connection: connection,
            pendingApproval: pendingApproval,
            errorMessage: errorMessage
        )
    }

    private var selectedChat: CodexChat? {
        guard let selectedChatID else { return CodexChat.newest(in: chats) }
        return chats.first(where: { $0.id == selectedChatID }) ?? CodexChat.newest(in: chats)
    }

    deinit {
        stop()
    }

    // MARK: Lifecycle

    func start() {
        dispatchPrecondition(condition: .onQueue(.main))
        guard process?.isRunning != true else {
            refresh()
            return
        }

        guard let executable = Self.codexExecutable() else {
            connection = .unavailable
            errorMessage = "Codex CLI was not found. Install Codex and try again."
            publishActivity()
            return
        }

        isStopping = false
        processGeneration &+= 1
        let generation = processGeneration
        errorMessage = nil
        connection = .starting
        publishActivity()

        let newProcess = Process()
        newProcess.executableURL = URL(fileURLWithPath: executable)
        newProcess.arguments = ["app-server", "--stdio"]
        newProcess.environment = Self.processEnvironment()
        newProcess.currentDirectoryURL = URL(fileURLWithPath: defaultWorkingDirectory())

        let input = Pipe()
        let output = Pipe()
        let error = Pipe()
        newProcess.standardInput = input
        newProcess.standardOutput = output
        newProcess.standardError = error

        do {
            try newProcess.run()
        } catch {
            connection = .failed
            errorMessage = "Could not start Codex app-server: \(error.localizedDescription)"
            publishActivity()
            return
        }

        process = newProcess
        inputHandle = input.fileHandleForWriting
        outputHandle = output.fileHandleForReading
        errorHandle = error.fileHandleForReading

        outputHandle?.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                self?.ioQueue.async { [weak self] in self?.handleOutputClosed() }
                return
            }
            self?.ioQueue.async { [weak self] in self?.consumeOutput(data) }
        }
        errorHandle?.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            self?.ioQueue.async { [weak self] in
                guard let text = String(data: data, encoding: .utf8) else { return }
                self?.stderrBuffer.append(text)
            }
        }
        newProcess.terminationHandler = { [weak self] terminatedProcess in
            let status = terminatedProcess.terminationStatus
            DispatchQueue.main.async { [weak self] in
                self?.handleTermination(status: status, generation: generation)
            }
        }

        sendRequest(
            method: "initialize",
            params: [
                "clientInfo": [
                    "name": "halo",
                    "title": "Halo",
                    "version": Self.clientVersion
                ],
                "capabilities": ["experimentalApi": true]
            ]
        )
    }

    func stop() {
        if !Thread.isMainThread {
            DispatchQueue.main.async { [weak self] in self?.stop() }
            return
        }

        isStopping = true
        processGeneration &+= 1
        outputHandle?.readabilityHandler = nil
        errorHandle?.readabilityHandler = nil
        inputHandle?.closeFile()
        process?.terminate()
        process = nil
        inputHandle = nil
        outputHandle = nil
        errorHandle = nil
        pendingRequests.removeAll()
        pendingTurnText.removeAll()
        queuedMessageTexts.removeAll()
        queuedThreadIDs.removeAll()
        externalHandoffMessageTexts.removeAll()
        externalHandoffBaselineMessageIDs.removeAll()
        externalReplySeen.removeAll()
        queuedRefreshTimer?.invalidate()
        queuedRefreshTimer = nil
        queuedRefreshThreadIDs.removeAll()
        queuedRefreshDeadlines.removeAll()
        loadedThreadIDs.removeAll()
        currentTurnIDs.removeAll()
        serverRequestIDs.removeAll()
        pendingApproval = nil
        connection = .stopped
        publishActivity()
    }

    func refresh() {
        dispatchPrecondition(condition: .onQueue(.main))
        guard process?.isRunning == true else {
            start()
            return
        }
        guard connection == .connected else { return }
        requestThreadList()
    }

    func selectChat(_ id: String) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard chats.contains(where: { $0.id == id }) else { return }
        selectedChatID = id
        messages = messagesByThread[id] ?? []
        pendingApproval = nil
        publishActivity()
        loadMessages(for: id)
    }

    func createChat() {
        dispatchPrecondition(condition: .onQueue(.main))
        guard process?.isRunning == true else {
            start()
            return
        }

        let params: [String: Any] = [
            "cwd": selectedChat?.cwd ?? defaultWorkingDirectory()
        ]
        // An explicit model is intentionally omitted. Codex should use the
        // user's configured model and approval policy for a new thread.
        _ = request(method: "thread/start", params: params, threadID: nil)
    }

    func send(_ text: String) {
        dispatchPrecondition(condition: .onQueue(.main))
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard process?.isRunning == true, connection == .connected else {
            pendingTurnText["__new__"] = trimmed
            start()
            return
        }

        guard let threadID = selectedChatID else {
            pendingTurnText["__new__"] = trimmed
            createChat()
            return
        }

        if let chat = selectedChat, !chat.canSendDirectInput {
            errorMessage = "This Codex chat is not accepting direct input. Click + to start a new chat."
            publishActivity()
            return
        }

        guard pendingTurnText[threadID] == nil else { return }
        mergeMessage(
            CodexMessage(id: "halo-user-\(UUID().uuidString)", role: .user, text: trimmed),
            into: threadID
        )
        pendingTurnText[threadID] = trimmed

        if loadedThreadIDs.contains(threadID) {
            sendTurn(threadID: threadID, text: trimmed)
        } else {
            _ = request(
                method: "thread/resume",
                params: ["threadId": threadID, "excludeTurns": true],
                threadID: threadID
            )
        }
        updateThreadState(threadID, state: .running)
        publishActivity()
    }

    func interrupt() {
        dispatchPrecondition(condition: .onQueue(.main))
        guard let threadID = selectedChatID,
              let turnID = currentTurnIDs[threadID] else { return }
        _ = request(
            method: "turn/interrupt",
            params: ["threadId": threadID, "turnId": turnID],
            threadID: threadID
        )
    }

    func resolveApproval(_ decision: CodexApprovalDecision) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard let approval = pendingApproval,
              let rawID = serverRequestIDs.removeValue(forKey: approval.requestKey) else { return }

        sendResponse(id: rawID, result: ["decision": decision.rawValue])
        pendingApproval = nil
        publishActivity()
    }

    // MARK: Protocol parsing helpers (also regression-tested)

    static let clientVersion = "1.0"

    static func parseChat(_ object: [String: Any]) -> CodexChat? {
        guard let id = object["id"] as? String, !id.isEmpty else { return nil }
        let preview = string(object["preview"]) ?? ""
        let explicitName = string(object["name"])?.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = (explicitName?.isEmpty == false ? explicitName! : firstLine(of: preview))
        let cwd = string(object["cwd"]) ?? ""
        let gitInfo = object["gitInfo"] as? [String: Any]
        let branch = string(gitInfo?["branch"])
        let updatedAt = number(object["updatedAt"]).map { Date(timeIntervalSince1970: $0) } ?? Date()
        let createdAt = number(object["createdAt"]).map { Date(timeIntervalSince1970: $0) } ?? updatedAt
        let historyMode = CodexHistoryMode(rawValue: string(object["historyMode"]) ?? "")
        // The list endpoint commonly omits this field for unloaded stored
        // threads. Resume is the capability check; only an explicit false is
        // a hard read-only result.
        let canAccept = (object["canAcceptDirectInput"] as? Bool) ?? true
        return CodexChat(
            id: id,
            title: title.isEmpty ? "Untitled chat" : title,
            preview: preview,
            cwd: cwd,
            branch: branch,
            createdAt: createdAt,
            updatedAt: updatedAt,
            state: CodexThreadState.fromJSON(object["status"]),
            canAcceptDirectInput: canAccept,
            model: string(object["model"]),
            historyMode: historyMode
        )
    }

    static func parseMessages(from entries: [[String: Any]]) -> [CodexMessage] {
        var messages: [CodexMessage] = []
        for entry in entries {
            guard let item = entry["item"] as? [String: Any],
                  let message = parseMessage(item) else { continue }
            merge(message, into: &messages)
        }
        return messages
    }

    static func parseMessage(_ item: [String: Any]) -> CodexMessage? {
        guard let id = string(item["id"]), !id.isEmpty,
              let type = string(item["type"]) else { return nil }

        switch type {
        case "userMessage":
            let content = item["content"] as? [[String: Any]] ?? []
            let text = content.compactMap { string($0["text"]) }.joined()
            guard !text.isEmpty else { return nil }
            return CodexMessage(id: id, role: .user, text: text)

        case "agentMessage":
            return CodexMessage(id: id, role: .assistant, text: string(item["text"]) ?? "")

        case "plan":
            guard let text = string(item["text"]), !text.isEmpty else { return nil }
            return CodexMessage(id: id, role: .assistant, text: text)

        // Deliberately do not surface reasoning content. The activity card
        // shows useful work, not private chain-of-thought.
        case "reasoning":
            return nil

        case "commandExecution":
            let command = string(item["command"]) ?? "command"
            let status = string(item["status"]) ?? "in progress"
            return CodexMessage(id: id, role: .tool, text: "$ " + command, detail: prettyStatus(status))

        case "fileChange":
            let changes = item["changes"] as? [[String: Any]] ?? []
            let count = changes.count
            return CodexMessage(
                id: id,
                role: .tool,
                text: count == 1 ? "Changed 1 file" : "Changed \(count) files"
            )

        case "mcpToolCall":
            let server = string(item["server"]) ?? "MCP"
            let tool = string(item["tool"]) ?? "tool"
            let status = string(item["status"]) ?? "in progress"
            return CodexMessage(id: id, role: .tool, text: server + " · " + tool, detail: prettyStatus(status))

        case "dynamicToolCall":
            let tool = string(item["tool"]) ?? "tool"
            let status = string(item["status"]) ?? "in progress"
            return CodexMessage(id: id, role: .tool, text: tool, detail: prettyStatus(status))

        case "collabAgentToolCall":
            let tool = string(item["tool"]) ?? "agent"
            let status = string(item["status"]) ?? "in progress"
            return CodexMessage(id: id, role: .tool, text: "Agent · " + tool, detail: prettyStatus(status))

        case "webSearch":
            let query = string(item["query"]) ?? "web search"
            return CodexMessage(id: id, role: .tool, text: "Search · " + query)

        case "imageView":
            let path = string(item["path"]) ?? "image"
            return CodexMessage(id: id, role: .tool, text: "Viewed · \(URL(fileURLWithPath: path).lastPathComponent)")

        case "imageGeneration":
            return CodexMessage(id: id, role: .tool, text: "Image generation")

        case "sleep":
            return CodexMessage(id: id, role: .tool, text: "Waiting")

        case "enteredReviewMode":
            return CodexMessage(id: id, role: .tool, text: "Entered review mode")

        case "exitedReviewMode":
            return CodexMessage(id: id, role: .tool, text: "Exited review mode")

        case "contextCompaction":
            return CodexMessage(id: id, role: .tool, text: "Compacted context")

        default:
            return nil
        }
    }

    static func requestKey(_ value: Any?) -> String? {
        if let value = value as? String, !value.isEmpty { return value }
        if let value = value as? NSNumber { return value.stringValue }
        return nil
    }

    static func isActiveWriterError(_ message: String) -> Bool {
        message.lowercased().contains("active writer")
    }

    static func queueParams(threadID: String, text: String, clientUserMessageID: String) -> [String: Any] {
        [
            "threadId": threadID,
            "clientUserMessageId": clientUserMessageID,
            "input": [["type": "text", "text": text]]
        ]
    }

    static func hasNewAssistantReply(
        in messages: [CodexMessage],
        afterUserText userTexts: [String],
        excluding baselineMessageIDs: Set<String>
    ) -> Bool {
        guard let userIndex = messages.lastIndex(where: {
            $0.role == .user && userTexts.contains($0.text)
        }) else { return false }

        return messages.dropFirst(userIndex + 1).contains {
            $0.role == .assistant
                && !baselineMessageIDs.contains($0.id)
                && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    // MARK: JSONL transport

    private func consumeOutput(_ data: Data) {
        outputBuffer.append(data)
        while let newline = outputBuffer.firstIndex(of: 0x0A) {
            let line = outputBuffer[..<newline]
            outputBuffer.removeSubrange(...newline)
            guard !line.isEmpty,
                  let object = try? JSONSerialization.jsonObject(with: Data(line)),
                  let message = object as? [String: Any] else { continue }
            DispatchQueue.main.async { [weak self] in
                self?.handleMessage(message)
            }
        }
    }

    private func handleOutputClosed() {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.process?.isRunning != true, !self.isStopping else { return }
            self.handleTermination(status: self.process?.terminationStatus ?? 1)
        }
    }

    private func handleMessage(_ message: [String: Any]) {
        if let method = message["method"] as? String {
            let params = message["params"] as? [String: Any] ?? [:]
            if message["id"] != nil {
                handleServerRequest(id: message["id"], method: method, params: params)
            } else {
                handleNotification(method: method, params: params)
            }
            return
        }

        guard let requestKey = Self.requestKey(message["id"]),
              let request = pendingRequests.removeValue(forKey: requestKey) else { return }
        if let error = message["error"] as? [String: Any] {
            handleRequestError(error, request: request)
            return
        }
        handleResponse(message["result"] as? [String: Any] ?? [:], request: request)
    }

    private func handleResponse(_ result: [String: Any], request: PendingRequest) {
        switch request.method {
        case "initialize":
            connection = .connected
            sendNotification(method: "initialized")
            requestThreadList()

        case "thread/list":
            let objects = result["data"] as? [[String: Any]] ?? []
            let parsed = objects.compactMap(Self.parseChat)
            chats = parsed.sorted { $0.updatedAt > $1.updatedAt }.map { chat in
                guard queuedThreadIDs.contains(chat.id) else { return chat }
                var queued = chat
                queued.state = .queued
                return queued
            }
            if let selectedChatID,
               chats.contains(where: { $0.id == selectedChatID }) {
                messages = messagesByThread[selectedChatID] ?? messages
            } else if let latest = CodexChat.newest(in: chats) {
                selectedChatID = latest.id
                messages = messagesByThread[latest.id] ?? []
                loadMessages(for: latest.id)
            }
            if pendingTurnText["__new__"] != nil,
               !pendingRequests.values.contains(where: { $0.method == "thread/start" }) {
                createChat()
            }
            finishExternalHandoffsIfIdle()
            publishActivity()

        case "thread/items/list":
            guard let threadID = request.threadID else { return }
            let entries = result["data"] as? [[String: Any]] ?? []
            // The request asks for descending order so the newest work is
            // cheap to fetch; reverse it back into conversation order.
            var parsed = Self.parseMessages(from: entries.reversed())
            reconcileQueuedMessages(for: threadID, messages: &parsed)
            observeExternalReply(for: threadID, messages: parsed)
            messagesByThread[threadID] = parsed
            if selectedChatID == threadID { messages = parsed }
            publishActivity()

        case "thread/resume":
            guard let threadID = request.threadID else { return }
            if let thread = result["thread"] as? [String: Any],
               let parsed = Self.parseChat(thread) {
                upsertChat(parsed)
                if !parsed.canSendDirectInput {
                    pendingTurnText.removeValue(forKey: threadID)
                    errorMessage = "Codex cannot continue this chat. Click + to start a new chat."
                    updateThreadState(threadID, state: .failed)
                    publishActivity()
                    return
                }
            }
            loadedThreadIDs.insert(threadID)
            errorMessage = nil
            loadMessages(for: threadID)
            if let text = pendingTurnText[threadID] {
                sendTurn(threadID: threadID, text: text)
            }
            publishActivity()

        case "thread/queue/add":
            guard let threadID = request.threadID,
                  let submission = result["queuedSubmission"] as? [String: Any],
                  let submissionID = Self.string(submission["id"]),
                  !submissionID.isEmpty else {
                if let threadID = request.threadID {
                    pendingTurnText.removeValue(forKey: threadID)
                    queuedThreadIDs.remove(threadID)
                    updateThreadState(threadID, state: .failed)
                }
                errorMessage = "Codex accepted the handoff without returning a queue entry."
                publishActivity()
                return
            }

            let text = pendingTurnText.removeValue(forKey: threadID) ?? ""
            if !text.isEmpty {
                queuedMessageTexts[threadID, default: []].append(text)
                externalHandoffMessageTexts[threadID, default: []].append(text)
            }
            queuedMessageTexts[threadID]?.removeAll { $0.isEmpty }
            queuedThreadIDs.insert(threadID)
            queuedRefreshThreadIDs.insert(threadID)
            queuedRefreshDeadlines[threadID] = Date().addingTimeInterval(120)
            startQueuedRefreshTimerIfNeeded()
            errorMessage = "Message queued for the active Codex session."
            updateThreadState(threadID, state: .queued)
            publishActivity()

        case "thread/start":
            guard let thread = result["thread"] as? [String: Any],
                  let parsed = Self.parseChat(thread) else {
                errorMessage = "Codex created a chat without returning its metadata."
                publishActivity()
                return
            }
            loadedThreadIDs.insert(parsed.id)
            upsertChat(parsed)
            selectedChatID = parsed.id
            messages = []
            errorMessage = nil
            if let text = pendingTurnText.removeValue(forKey: "__new__") {
                mergeMessage(CodexMessage(id: "halo-user-\(UUID().uuidString)", role: .user, text: text), into: parsed.id)
                pendingTurnText[parsed.id] = text
                sendTurn(threadID: parsed.id, text: text)
            }
            publishActivity()

        case "turn/start":
            if let threadID = request.threadID,
               let turn = result["turn"] as? [String: Any],
               let turnID = Self.string(turn["id"]) {
                currentTurnIDs[threadID] = turnID
                updateThreadState(threadID, state: .running)
                publishActivity()
            }

        default:
            break
        }
    }

    private func handleRequestError(_ error: [String: Any], request: PendingRequest) {
        let message = Self.string(error["message"]) ?? "Codex request failed."
        if request.method == "thread/items/list" {
            // A stored/paginated thread may reject a history read until it is
            // resumed. Keep any pending composer text alive so thread/resume
            // can still continue the selected conversation.
            if pendingTurnText[request.threadID ?? ""] == nil {
                errorMessage = message
                publishActivity()
            }
            return
        }
        if let threadID = request.threadID,
           (request.method == "thread/resume" || request.method == "turn/start"),
           Self.isActiveWriterError(message) {
            queuePendingMessage(threadID: threadID)
            return
        }
        if request.method == "thread/start" {
            pendingTurnText.removeValue(forKey: "__new__")
        } else if let threadID = request.threadID {
            pendingTurnText.removeValue(forKey: threadID)
            if request.method == "thread/queue/add" {
                queuedThreadIDs.remove(threadID)
                queuedRefreshThreadIDs.remove(threadID)
                queuedRefreshDeadlines.removeValue(forKey: threadID)
                stopQueuedRefreshTimerIfNeeded()
            }
        }
        errorMessage = message
        if let threadID = request.threadID { updateThreadState(threadID, state: .failed) }
        publishActivity()
    }

    private func handleNotification(method: String, params: [String: Any]) {
        switch method {
        case "thread/status/changed":
            guard let threadID = Self.string(params["threadId"]) else { return }
            updateThreadState(threadID, state: CodexThreadState.fromJSON(params["status"]))
            publishActivity()

        case "turn/started":
            guard let threadID = Self.string(params["threadId"]),
                  let turn = params["turn"] as? [String: Any],
                  let turnID = Self.string(turn["id"]) else { return }
            currentTurnIDs[threadID] = turnID
            updateThreadState(threadID, state: .running)
            publishActivity()

        case "turn/completed":
            guard let threadID = Self.string(params["threadId"]),
                  let turn = params["turn"] as? [String: Any] else { return }
            currentTurnIDs.removeValue(forKey: threadID)
            pendingTurnText.removeValue(forKey: threadID)
            if let state = CodexThreadState.fromTurnJSON(turn["status"]) {
                updateThreadState(threadID, state: state)
            }
            loadMessages(for: threadID)
            requestThreadList()
            publishActivity()

        case "item/started", "item/completed":
            guard let threadID = Self.string(params["threadId"]),
                  let item = params["item"] as? [String: Any],
                  let message = Self.parseMessage(item) else { return }
            var updated = message
            if method == "item/started" { updated.isStreaming = true }
            mergeMessage(updated, into: threadID)

        case "item/agentMessage/delta":
            guard let threadID = Self.string(params["threadId"]),
                  let itemID = Self.string(params["itemId"]),
                  let delta = Self.string(params["delta"]) else { return }
            appendDelta(delta, itemID: itemID, threadID: threadID)

        case "thread/name/updated":
            guard let threadID = Self.string(params["threadId"]) else { return }
            let name = Self.string(params["threadName"]) ?? Self.string(params["name"])
            if let name, !name.isEmpty { updateChatTitle(threadID, title: name) }
            publishActivity()

        case "thread/started":
            if let thread = params["thread"] as? [String: Any],
               let parsed = Self.parseChat(thread) {
                upsertChat(parsed)
                if selectedChatID == nil { selectedChatID = parsed.id }
                publishActivity()
            }

        case "thread/queue/changed":
            guard let threadID = Self.string(params["threadId"]) else { return }
            loadMessages(for: threadID)

        case "error":
            errorMessage = Self.string(params["message"]) ?? "Codex reported an error."
            publishActivity()

        default:
            break
        }
    }

    private func handleServerRequest(id: Any?, method: String, params: [String: Any]) {
        guard let requestKey = Self.requestKey(id) else { return }
        switch method {
        case "item/commandExecution/requestApproval":
            let command = Self.string(params["command"]) ?? "Command"
            let reason = Self.string(params["reason"])
            serverRequestIDs[requestKey] = id as Any
            pendingApproval = CodexApproval(
                requestKey: requestKey,
                kind: .command,
                title: "Allow Codex to run this command?",
                detail: reason.map { "\(command)\n\($0)" } ?? command
            )
            if let threadID = Self.string(params["threadId"]) { updateThreadState(threadID, state: .waiting) }
            publishActivity()

        case "item/fileChange/requestApproval":
            let reason = Self.string(params["reason"]) ?? "Codex wants to change files in this workspace."
            serverRequestIDs[requestKey] = id as Any
            pendingApproval = CodexApproval(
                requestKey: requestKey,
                kind: .fileChange,
                title: "Allow Codex to change files?",
                detail: reason
            )
            if let threadID = Self.string(params["threadId"]) { updateThreadState(threadID, state: .waiting) }
            publishActivity()

        default:
            // Unsupported interactive requests must receive a response or
            // the app-server turn would remain blocked indefinitely.
            sendError(id: id, code: -32601, message: "Halo does not support \(method) yet.")
            errorMessage = "Codex requested an unsupported interactive action: \(method)."
            publishActivity()
        }
    }

    private func handleTermination(status: Int32, generation: Int? = nil) {
        guard !isStopping else { return }
        if let generation, generation != processGeneration { return }
        process = nil
        inputHandle = nil
        outputHandle = nil
        errorHandle = nil
        connection = status == 0 ? .stopped : .failed
        if status != 0 {
            let stderr = stderrBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
            errorMessage = stderr.isEmpty
                ? "Codex app-server stopped unexpectedly (\(status))."
                : stderr.components(separatedBy: .newlines).last
        }
        publishActivity()
    }

    private func requestThreadList() {
        guard !pendingRequests.values.contains(where: { $0.method == "thread/list" }) else { return }
        _ = request(
            method: "thread/list",
            params: ["limit": 50, "sortKey": "updated_at", "sortDirection": "desc"],
            threadID: nil
        )
    }

    private func loadMessages(for threadID: String) {
        guard process?.isRunning == true,
              !pendingRequests.values.contains(where: {
                  $0.method == "thread/items/list" && $0.threadID == threadID
              }) else { return }
        _ = request(
            method: "thread/items/list",
            params: [
                "threadId": threadID,
                "limit": 100,
                "sortDirection": "desc"
            ],
            threadID: threadID
        )
    }

    private func sendTurn(threadID: String, text: String) {
        let params: [String: Any] = [
            "threadId": threadID,
            "input": [["type": "text", "text": text]]
        ]
        _ = request(method: "turn/start", params: params, threadID: threadID)
    }

    private func queuePendingMessage(threadID: String) {
        guard let text = pendingTurnText[threadID], !text.isEmpty else {
            errorMessage = "Codex reported an active session, but Halo has no pending message to queue."
            publishActivity()
            return
        }
        guard !pendingRequests.values.contains(where: {
            $0.method == "thread/queue/add" && $0.threadID == threadID
        }) else { return }

        if externalHandoffBaselineMessageIDs[threadID] == nil {
            externalHandoffBaselineMessageIDs[threadID] = Set(
                (messagesByThread[threadID] ?? []).map(\.id)
            )
        }
        queuedThreadIDs.insert(threadID)
        updateThreadState(threadID, state: .queued)
        _ = request(
            method: "thread/queue/add",
            params: Self.queueParams(
                threadID: threadID,
                text: text,
                clientUserMessageID: UUID().uuidString
            ),
            threadID: threadID
        )
        errorMessage = "Sending to the active Codex session…"
        publishActivity()
    }

    private func reconcileQueuedMessages(for threadID: String, messages: inout [CodexMessage]) {
        guard let queued = queuedMessageTexts[threadID], !queued.isEmpty else { return }
        var remaining: [String] = []
        for (index, text) in queued.enumerated() {
            if messages.contains(where: { $0.role == .user && $0.text == text }) {
                continue
            }
            Self.merge(
                CodexMessage(
                    id: "halo-queued-\(threadID)-\(index)",
                    role: .user,
                    text: text
                ),
                into: &messages
            )
            remaining.append(text)
        }

        if remaining.isEmpty {
            queuedMessageTexts.removeValue(forKey: threadID)
            queuedThreadIDs.remove(threadID)
            if selectedChatID == threadID {
                if errorMessage == "Message queued for the active Codex session." {
                    errorMessage = nil
                }
                updateThreadState(threadID, state: .running)
            }
        } else {
            queuedMessageTexts[threadID] = remaining
        }
    }

    private func observeExternalReply(for threadID: String, messages: [CodexMessage]) {
        guard let userTexts = externalHandoffMessageTexts[threadID], !userTexts.isEmpty else { return }
        let baseline = externalHandoffBaselineMessageIDs[threadID] ?? []
        if Self.hasNewAssistantReply(
            in: messages,
            afterUserText: userTexts,
            excluding: baseline
        ) {
            externalReplySeen.insert(threadID)
        }
    }

    private func finishExternalHandoffsIfIdle() {
        for threadID in Array(externalReplySeen) {
            guard let chat = chats.first(where: { $0.id == threadID }),
                  chat.state != .running,
                  chat.state != .waiting,
                  chat.state != .queued else { continue }
            finishExternalHandoff(for: threadID)
        }
    }

    private func finishExternalHandoff(for threadID: String) {
        externalHandoffMessageTexts.removeValue(forKey: threadID)
        externalHandoffBaselineMessageIDs.removeValue(forKey: threadID)
        externalReplySeen.remove(threadID)
        queuedMessageTexts.removeValue(forKey: threadID)
        queuedThreadIDs.remove(threadID)
        queuedRefreshThreadIDs.remove(threadID)
        queuedRefreshDeadlines.removeValue(forKey: threadID)
        if selectedChatID == threadID,
           errorMessage == "Message queued for the active Codex session." {
            errorMessage = nil
        }
        stopQueuedRefreshTimerIfNeeded()
    }

    private func startQueuedRefreshTimerIfNeeded() {
        guard queuedRefreshTimer == nil else { return }
        queuedRefreshTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.refreshQueuedThreads()
        }
    }

    private func stopQueuedRefreshTimerIfNeeded() {
        guard queuedRefreshThreadIDs.isEmpty else { return }
        queuedRefreshTimer?.invalidate()
        queuedRefreshTimer = nil
    }

    private func refreshQueuedThreads() {
        guard process?.isRunning == true, connection == .connected else {
            queuedRefreshTimer?.invalidate()
            queuedRefreshTimer = nil
            return
        }

        let now = Date()
        var expired: [String] = []
        for threadID in queuedRefreshThreadIDs {
            if queuedRefreshDeadlines[threadID].map({ $0 <= now }) == true {
                expired.append(threadID)
            } else {
                loadMessages(for: threadID)
            }
        }
        requestThreadList()
        for threadID in expired {
            let wasStillQueued = queuedMessageTexts[threadID] != nil
            let replyWasSeen = externalReplySeen.contains(threadID)
            queuedRefreshThreadIDs.remove(threadID)
            queuedRefreshDeadlines.removeValue(forKey: threadID)
            queuedThreadIDs.remove(threadID)
            externalHandoffMessageTexts.removeValue(forKey: threadID)
            externalHandoffBaselineMessageIDs.removeValue(forKey: threadID)
            externalReplySeen.remove(threadID)
            if selectedChatID == threadID {
                updateThreadState(threadID, state: .running)
                errorMessage = replyWasSeen
                    ? nil
                    : wasStillQueued
                        ? "Message is still queued in the active Codex session. Refresh to check it."
                        : "Codex is still working in the active session. Refresh to check it."
                publishActivity()
            }
        }
        stopQueuedRefreshTimerIfNeeded()
    }

    @discardableResult
    private func request(method: String, params: [String: Any], threadID: String?) -> Int {
        let id = nextRequestID
        nextRequestID += 1
        pendingRequests[String(id)] = PendingRequest(method: method, threadID: threadID)
        sendRaw(["method": method, "id": id, "params": params])
        return id
    }

    private func sendRequest(method: String, params: [String: Any]) {
        let id = nextRequestID
        nextRequestID += 1
        pendingRequests[String(id)] = PendingRequest(method: method, threadID: nil)
        sendRaw(["method": method, "id": id, "params": params])
    }

    private func sendNotification(method: String) {
        sendRaw(["method": method])
    }

    private func sendResponse(id: Any, result: [String: Any]) {
        sendRaw(["id": id, "result": result])
    }

    private func sendError(id: Any?, code: Int, message: String) {
        var response: [String: Any] = [
            "error": ["code": code, "message": message]
        ]
        if let id { response["id"] = id }
        sendRaw(response)
    }

    private func sendRaw(_ object: [String: Any]) {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object),
              var line = String(data: data, encoding: .utf8) else { return }
        line.append("\n")
        let bytes = Data(line.utf8)
        writeQueue.async { [weak self] in
            guard let self, let inputHandle = self.inputHandle else { return }
            try? inputHandle.write(contentsOf: bytes)
        }
    }

    // MARK: State helpers

    private func upsertChat(_ chat: CodexChat) {
        if let index = chats.firstIndex(where: { $0.id == chat.id }) {
            chats[index] = chat
        } else {
            chats.append(chat)
            chats.sort { $0.updatedAt > $1.updatedAt }
        }
    }

    private func updateThreadState(_ id: String, state: CodexThreadState) {
        guard let index = chats.firstIndex(where: { $0.id == id }) else { return }
        chats[index].state = state
    }

    private func updateChatTitle(_ id: String, title: String) {
        guard let index = chats.firstIndex(where: { $0.id == id }) else { return }
        chats[index].title = title
    }

    private func mergeMessage(_ message: CodexMessage, into threadID: String) {
        var threadMessages = messagesByThread[threadID] ?? []
        Self.merge(message, into: &threadMessages)
        messagesByThread[threadID] = Array(threadMessages.suffix(100))
        if selectedChatID == threadID { messages = messagesByThread[threadID] ?? [] }
        publishActivity()
    }

    private func appendDelta(_ delta: String, itemID: String, threadID: String) {
        var threadMessages = messagesByThread[threadID] ?? []
        if let index = threadMessages.firstIndex(where: { $0.id == itemID }) {
            threadMessages[index].text.append(delta)
            threadMessages[index].isStreaming = true
        } else {
            threadMessages.append(CodexMessage(id: itemID, role: .assistant, text: delta, isStreaming: true))
        }
        messagesByThread[threadID] = Array(threadMessages.suffix(100))
        if selectedChatID == threadID { messages = messagesByThread[threadID] ?? [] }
        publishActivity()
    }

    private func publishActivity() {
        onActivity?(activity)
    }

    // MARK: Process discovery

    private func defaultWorkingDirectory() -> String {
        let current = FileManager.default.currentDirectoryPath
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: current, isDirectory: &isDirectory), isDirectory.boolValue {
            return current
        }
        return NSHomeDirectory()
    }

    private static func codexExecutable() -> String? {
        let environmentPath = ProcessInfo.processInfo.environment["PATH"] ?? ""
        let home = NSHomeDirectory()
        let candidates = environmentPath.split(separator: ":").map { String($0) }
            .map { URL(fileURLWithPath: $0).appendingPathComponent("codex").path }
            + [
                "\(home)/.local/bin/codex",
                "\(home)/.npm-global/bin/codex",
                "/opt/homebrew/bin/codex",
                "/usr/local/bin/codex"
            ]
        var seen = Set<String>()
        for candidate in candidates where seen.insert(candidate).inserted {
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }

    private static func processEnvironment() -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        var paths = (environment["PATH"] ?? "").split(separator: ":").map(String.init)
        for path in ["\(NSHomeDirectory())/.local/bin", "\(NSHomeDirectory())/.npm-global/bin", "/opt/homebrew/bin", "/usr/local/bin"] {
            if !paths.contains(path) { paths.append(path) }
        }
        environment["PATH"] = paths.joined(separator: ":")
        return environment
    }

    // MARK: Pure parsing helpers

    private static func merge(_ message: CodexMessage, into messages: inout [CodexMessage]) {
        if let index = messages.firstIndex(where: { $0.id == message.id }) {
            messages[index] = message
        } else {
            messages.append(message)
        }
    }

    private static func string(_ value: Any?) -> String? {
        if let value = value as? String { return value }
        if let value = value as? NSString { return String(value) }
        return nil
    }

    private static func number(_ value: Any?) -> TimeInterval? {
        if let value = value as? NSNumber { return value.doubleValue }
        return nil
    }

    private static func firstLine(of value: String) -> String {
        value.components(separatedBy: .newlines).first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private static func prettyStatus(_ value: String) -> String {
        switch value {
        case "inProgress": return "Working"
        case "completed": return "Completed"
        case "failed": return "Failed"
        case "declined": return "Declined"
        default: return value
        }
    }

}
