import Combine
import Foundation

// MARK: - Claude Code activity model

enum ClaudeCodeConnectionState: Equatable {
    case stopped
    case starting
    case connected
    case unavailable
    case failed

    var title: String {
        switch self {
        case .stopped: return "Stopped"
        case .starting: return "Connecting"
        case .connected: return "Ready"
        case .unavailable: return "Unavailable"
        case .failed: return "Connection error"
        }
    }

    var compactLabel: String {
        switch self {
        case .stopped: return "OFF"
        case .starting: return "..."
        case .connected: return "RDY"
        case .unavailable: return "N/A"
        case .failed: return "ERR"
        }
    }
}

enum ClaudeCodeSessionState: Equatable {
    case idle
    case running
    case waiting
    case failed
    case interrupted

    var title: String {
        switch self {
        case .idle: return "Ready"
        case .running: return "Working"
        case .waiting: return "Needs your decision"
        case .failed: return "Failed"
        case .interrupted: return "Interrupted"
        }
    }

    var compactLabel: String {
        switch self {
        case .idle: return "RDY"
        case .running: return "RUN"
        case .waiting: return "ASK"
        case .failed: return "ERR"
        case .interrupted: return "STP"
        }
    }
}

struct ClaudeCodeSession: Identifiable, Equatable {
    let id: String
    var title: String
    var preview: String
    var directory: String
    var createdAt: Date
    var updatedAt: Date
    var state: ClaudeCodeSessionState
    var model: String?
    var transcriptPath: String?
    var isSynthetic: Bool = false

    var repositoryName: String {
        let trimmed = directory.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return trimmed.split(separator: "/").last.map(String.init) ?? "Local workspace"
    }

    static func newest(in sessions: [ClaudeCodeSession]) -> ClaudeCodeSession? {
        sessions.max {
            if $0.createdAt != $1.createdAt {
                return $0.createdAt < $1.createdAt
            }
            if $0.updatedAt != $1.updatedAt {
                return $0.updatedAt < $1.updatedAt
            }
            return $0.id < $1.id
        }
    }
}

enum ClaudeCodeMessageRole: String, Equatable {
    case user
    case assistant
    case tool
}

struct ClaudeCodeMessage: Identifiable, Equatable {
    let id: String
    var role: ClaudeCodeMessageRole
    var text: String
    var detail: String?
    var isStreaming: Bool

    init(
        id: String,
        role: ClaudeCodeMessageRole,
        text: String,
        detail: String? = nil,
        isStreaming: Bool = false
    ) {
        self.id = id
        self.role = role
        self.text = text
        self.detail = detail
        self.isStreaming = isStreaming
    }
}

struct ClaudeCodeActivity: Equatable {
    var sessions: [ClaudeCodeSession]
    var selectedSessionID: String?
    var messages: [ClaudeCodeMessage]
    var connection: ClaudeCodeConnectionState
    var errorMessage: String?

    var selectedSession: ClaudeCodeSession? {
        guard let selectedSessionID else { return ClaudeCodeSession.newest(in: sessions) }
        return sessions.first(where: { $0.id == selectedSessionID })
            ?? ClaudeCodeSession.newest(in: sessions)
    }

    var selectedState: ClaudeCodeSessionState {
        selectedSession?.state ?? .idle
    }

    var compactLabel: String {
        if selectedSession != nil { return selectedState.compactLabel }
        return connection.compactLabel
    }

    func visibleMessages(showWorkActivity: Bool) -> [ClaudeCodeMessage] {
        guard showWorkActivity else { return messages.filter { $0.role != .tool } }
        return messages
    }

    func conversationScrollToken(showWorkActivity: Bool) -> String {
        visibleMessages(showWorkActivity: showWorkActivity)
            .map { message in
                [message.id, message.text, String(message.isStreaming)].joined(separator: "\u{1F}")
            }
            .joined(separator: "\u{1E}")
    }
}

// MARK: - Claude Code CLI client

/// Bridges Halo to Claude Code's print-mode JSON stream. Claude Code owns
/// authentication, provider configuration, permissions, and transcript
/// persistence; Halo only starts a local CLI process and renders its events.
final class ClaudeCodeMonitor: NSObject, ObservableObject {
    @Published private(set) var sessions: [ClaudeCodeSession] = []
    @Published private(set) var selectedSessionID: String?
    @Published private(set) var messages: [ClaudeCodeMessage] = []
    @Published private(set) var connection: ClaudeCodeConnectionState = .stopped
    @Published private(set) var errorMessage: String?

    var onActivity: ((ClaudeCodeActivity) -> Void)?

    private let ioQueue = DispatchQueue(label: "com.tryhalo.halo.claudecode.io")
    private let transcriptRootURL: URL
    private var transcriptWatcher: ClaudeTranscriptWatcher!
    private var transcriptRefreshWorkItem: DispatchWorkItem?
    private var pendingTranscriptPaths = Set<String>()
    private var pendingFullTranscriptRefresh = false
    private var process: Process?
    private var outputHandle: FileHandle?
    private var errorHandle: FileHandle?
    private var outputBuffer = Data()
    private var stderrBuffer = ""
    private var processGeneration = 0
    private var isStopping = false
    private var isInterrupting = false
    private var activeSessionID: String?
    private var activePlaceholderID: String?
    private var activeTurnID: String?
    private var streamingAssistantID: String?
    private var messagesBySession: [String: [ClaudeCodeMessage]] = [:]

    init(transcriptRootURL: URL? = nil) {
        self.transcriptRootURL = transcriptRootURL
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".claude", isDirectory: true)
                .appendingPathComponent("projects", isDirectory: true)
        super.init()
        transcriptWatcher = ClaudeTranscriptWatcher(queue: ioQueue) { [weak self] paths in
            DispatchQueue.main.async { [weak self] in
                self?.scheduleTranscriptRefresh(changedPaths: paths)
            }
        }
    }

    var activity: ClaudeCodeActivity {
        ClaudeCodeActivity(
            sessions: sessions,
            selectedSessionID: selectedSessionID,
            messages: messages,
            connection: connection,
            errorMessage: errorMessage
        )
    }

    deinit {
        transcriptRefreshWorkItem?.cancel()
        transcriptWatcher.stop()
        outputHandle?.readabilityHandler = nil
        errorHandle?.readabilityHandler = nil
        process?.terminate()
    }

    // MARK: Lifecycle

    func start() {
        dispatchPrecondition(condition: .onQueue(.main))
        guard process?.isRunning != true else { return }
        isStopping = false
        isInterrupting = false

        guard Self.executablePath() != nil else {
            connection = .unavailable
            errorMessage = "Claude Code CLI was not found. Install it, then refresh Halo."
            publishActivity()
            return
        }

        connection = .starting
        errorMessage = nil
        publishActivity()
        refreshSessions()
    }

    func stop() {
        dispatchPrecondition(condition: .onQueue(.main))
        isStopping = true
        processGeneration &+= 1
        transcriptRefreshWorkItem?.cancel()
        transcriptRefreshWorkItem = nil
        pendingTranscriptPaths.removeAll()
        pendingFullTranscriptRefresh = false
        transcriptWatcher.stop()
        outputHandle?.readabilityHandler = nil
        errorHandle?.readabilityHandler = nil
        process?.terminate()
        process = nil
        outputHandle = nil
        errorHandle = nil
        isInterrupting = false
        activeSessionID = nil
        activePlaceholderID = nil
        activeTurnID = nil
        streamingAssistantID = nil
        connection = .stopped
        publishActivity()
    }

    func refresh() {
        dispatchPrecondition(condition: .onQueue(.main))
        guard Self.executablePath() != nil else {
            connection = .unavailable
            errorMessage = "Claude Code CLI was not found."
            publishActivity()
            return
        }
        refreshSessions()
    }

    func selectSession(_ id: String) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard let session = sessions.first(where: { $0.id == id }) else { return }
        let activeID = activeSessionID ?? activePlaceholderID
        if process?.isRunning == true, activeID != id {
            errorMessage = "Claude Code is still working in the current session. Wait for the turn to finish."
            publishActivity()
            return
        }
        selectedSessionID = id
        errorMessage = nil
        messages = messagesBySession[id] ?? []
        if let transcriptPath = session.transcriptPath, !session.isSynthetic {
            loadMessages(for: id, transcriptPath: transcriptPath)
        }
        publishActivity()
    }

    func createSession() {
        dispatchPrecondition(condition: .onQueue(.main))
        guard process?.isRunning != true else {
            errorMessage = "Claude Code is still working. Wait for the current turn to finish."
            publishActivity()
            return
        }
        let now = Date()
        let id = "new-\(UUID().uuidString.lowercased())"
        let session = ClaudeCodeSession(
            id: id,
            title: "New Claude session",
            preview: "",
            directory: Self.defaultWorkingDirectory(),
            createdAt: now,
            updatedAt: now,
            state: .idle,
            model: nil,
            transcriptPath: nil,
            isSynthetic: true
        )
        sessions.removeAll { $0.isSynthetic }
        sessions.insert(session, at: 0)
        selectedSessionID = id
        messages = []
        errorMessage = nil
        publishActivity()
    }

    func send(_ text: String) {
        dispatchPrecondition(condition: .onQueue(.main))
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        if process?.isRunning == true {
            errorMessage = "Claude Code is still working. Wait for the current turn to finish."
            publishActivity()
            return
        }

        if selectedSessionID == nil {
            createSession()
        }
        guard let selectedID = selectedSessionID,
              let session = sessions.first(where: { $0.id == selectedID }) else { return }

        activePlaceholderID = session.isSynthetic ? session.id : nil
        activeSessionID = session.isSynthetic ? nil : session.id
        activeTurnID = UUID().uuidString.lowercased()
        streamingAssistantID = nil
        isInterrupting = false
        stderrBuffer = ""
        outputBuffer.removeAll(keepingCapacity: true)
        errorMessage = nil
        updateState(sessionID: session.id, state: .running)
        mergeMessage(
            ClaudeCodeMessage(
                id: "halo-user-\(UUID().uuidString)",
                role: .user,
                text: trimmed
            ),
            into: session.id
        )
        publishActivity()

        let requestedSessionID = session.isSynthetic
            ? UUID().uuidString.lowercased()
            : nil
        launch(
            prompt: trimmed,
            session: session,
            requestedSessionID: requestedSessionID
        )
    }

    func interrupt() {
        dispatchPrecondition(condition: .onQueue(.main))
        guard process?.isRunning == true,
              let activeID = activeSessionID ?? activePlaceholderID else { return }
        isInterrupting = true
        updateState(sessionID: activeID, state: .interrupted)
        process?.terminate()
        publishActivity()
    }

    // MARK: Tested protocol helpers

    static func commandArguments(
        sessionID: String?,
        prompt: String,
        requestedSessionID: String? = nil
    ) -> [String] {
        var arguments = [
            "-p",
            "--output-format", "stream-json",
            "--verbose",
            "--include-partial-messages",
            "--permission-mode", "manual"
        ]
        if let requestedSessionID {
            arguments += ["--session-id", requestedSessionID]
        }
        if let sessionID {
            arguments += ["--resume", sessionID]
        }
        arguments.append(prompt)
        return arguments
    }

    static func parseTranscriptMessages(from entries: [[String: Any]]) -> [ClaudeCodeMessage] {
        var messages: [ClaudeCodeMessage] = []

        for entry in entries {
            guard entry["isSidechain"] as? Bool != true else { continue }
            let type = string(entry["type"]) ?? ""
            let eventID = string(entry["uuid"]) ?? UUID().uuidString
            let message = entry["message"] as? [String: Any]

            switch type {
            case "user":
                guard let message,
                      let text = userText(from: message["content"]),
                      !text.isEmpty else { continue }
                merge(
                    ClaudeCodeMessage(id: eventID, role: .user, text: text),
                    into: &messages
                )

            case "assistant":
                guard let message else { continue }
                let messageID = string(message["id"]) ?? eventID
                for (index, block) in contentBlocks(from: message["content"]).enumerated() {
                    let blockType = string(block["type"]) ?? ""
                    switch blockType {
                    case "text":
                        guard let text = string(block["text"]), !text.isEmpty else { continue }
                        merge(
                            ClaudeCodeMessage(
                                id: "\(messageID)-text-\(index)",
                                role: .assistant,
                                text: text
                            ),
                            into: &messages
                        )
                    case "tool_use":
                        let name = string(block["name"]) ?? "tool"
                        merge(
                            ClaudeCodeMessage(
                                id: string(block["id"]) ?? "\(messageID)-tool-\(index)",
                                role: .tool,
                                text: toolTitle(name: name, input: block["input"]),
                                detail: toolDetail(name: name, input: block["input"])
                            ),
                            into: &messages
                        )
                    default:
                        // Thinking and signature blocks are intentionally not
                        // surfaced as activity or conversation text.
                        continue
                    }
                }

            default:
                continue
            }
        }

        return Array(messages.suffix(120))
    }

    static func parseSessionMetadata(
        from entries: [[String: Any]],
        sessionID fallbackID: String,
        transcriptPath: String? = nil,
        fileDate: Date = Date()
    ) -> ClaudeCodeSession? {
        var sessionID = fallbackID
        var directory = ""
        var title: String?
        var aiTitle: String?
        var firstUserText: String?
        var latestUserText: String?
        var model: String?
        var createdAt: Date?
        var updatedAt: Date?

        for entry in entries {
            guard entry["isSidechain"] as? Bool != true else { continue }
            if let value = string(entry["sessionId"]), !value.isEmpty { sessionID = value }
            if let cwd = string(entry["cwd"]), !cwd.isEmpty { directory = cwd }
            if let date = isoDate(entry["timestamp"]) {
                createdAt = min(createdAt ?? date, date)
                updatedAt = max(updatedAt ?? date, date)
            }

            switch string(entry["type"]) {
            case "custom-title":
                title = string(entry["customTitle"])
            case "ai-title":
                aiTitle = string(entry["aiTitle"])
            case "assistant":
                if let message = entry["message"] as? [String: Any] {
                    model = string(message["model"]) ?? model
                }
            case "user":
                if let message = entry["message"] as? [String: Any],
                   let text = userText(from: message["content"]),
                   !text.isEmpty {
                    firstUserText = firstUserText ?? text
                    latestUserText = text
                }
            default:
                break
            }
        }

        guard !firstUserText.isNilOrEmpty else { return nil }
        let fallbackTitle = firstLine(of: firstUserText ?? "")
        let resolvedTitle = [title, aiTitle, fallbackTitle]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first(where: { !$0.isEmpty }) ?? "Claude session"
        let updated = updatedAt ?? fileDate
        return ClaudeCodeSession(
            id: sessionID,
            title: resolvedTitle,
            preview: firstLine(of: latestUserText ?? firstUserText ?? ""),
            directory: directory.isEmpty ? "Local workspace" : directory,
            createdAt: createdAt ?? updated,
            updatedAt: updated,
            state: .idle,
            model: model,
            transcriptPath: transcriptPath
        )
    }

    static func parseStreamTextDelta(_ object: [String: Any]) -> String? {
        guard string(object["type"]) == "stream_event",
              let event = object["event"] as? [String: Any],
              string(event["type"]) == "content_block_delta",
              let delta = event["delta"] as? [String: Any],
              string(delta["type"]) == "text_delta" else { return nil }
        return string(delta["text"])
    }

    static func parseStreamToolUse(_ object: [String: Any]) -> ClaudeCodeMessage? {
        guard string(object["type"]) == "stream_event",
              let event = object["event"] as? [String: Any],
              string(event["type"]) == "content_block_start",
              let block = event["content_block"] as? [String: Any],
              string(block["type"]) == "tool_use" else { return nil }
        return toolMessage(from: block, fallbackID: nil)
    }

    static func parsePermissionDenials(_ value: Any?) -> [String] {
        guard let values = value as? [[String: Any]] else { return [] }
        return values.compactMap { object in
            string(object["tool_name"])
                ?? string(object["toolName"])
                ?? string(object["reason"])
        }
    }

    // MARK: CLI process

    private func launch(
        prompt: String,
        session: ClaudeCodeSession,
        requestedSessionID: String?
    ) {
        guard let executable = Self.executablePath() else {
            connection = .unavailable
            errorMessage = "Claude Code CLI was not found."
            updateState(sessionID: session.id, state: .failed)
            publishActivity()
            return
        }

        processGeneration &+= 1
        let generation = processGeneration
        let newProcess = Process()
        let output = Pipe()
        let error = Pipe()
        newProcess.executableURL = URL(fileURLWithPath: executable)
        newProcess.arguments = Self.commandArguments(
            sessionID: session.isSynthetic ? nil : session.id,
            prompt: prompt,
            requestedSessionID: requestedSessionID
        )
        let directory = FileManager.default.fileExists(atPath: session.directory)
            ? session.directory
            : Self.defaultWorkingDirectory()
        newProcess.currentDirectoryURL = URL(fileURLWithPath: directory, isDirectory: true)
        newProcess.environment = Self.processEnvironment()
        newProcess.standardOutput = output
        newProcess.standardError = error

        do {
            try newProcess.run()
        } catch {
            connection = .failed
            errorMessage = "Could not start Claude Code: \(error.localizedDescription)"
            updateState(sessionID: session.id, state: .failed)
            publishActivity()
            return
        }

        process = newProcess
        outputHandle = output.fileHandleForReading
        errorHandle = error.fileHandleForReading
        outputHandle?.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            self?.ioQueue.async { [weak self] in
                self?.consumeOutput(data, generation: generation)
            }
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
    }

    private func consumeOutput(_ data: Data, generation: Int) {
        guard generation == processGeneration else { return }
        outputBuffer.append(data)
        while let newline = outputBuffer.firstIndex(of: 0x0A) {
            let line = outputBuffer[..<newline]
            outputBuffer.removeSubrange(...newline)
            let cleanLine = line.last == 0x0D ? line.dropLast() : line[...]
            guard !cleanLine.isEmpty,
                  let object = try? JSONSerialization.jsonObject(with: Data(cleanLine)) as? [String: Any]
            else { continue }
            DispatchQueue.main.async { [weak self] in
                self?.handleStreamObject(object)
            }
        }
    }

    // Module-internal so protocol tests verify the event-to-activity callback.
    func handleStreamObject(_ object: [String: Any]) {
        let type = Self.string(object["type"]) ?? ""
        let eventSessionID = Self.string(object["session_id"]) ?? Self.string(object["sessionId"])

        switch type {
        case "system":
            handleSystemEvent(object, sessionID: eventSessionID)
        case "stream_event":
            var didUpdateVisibleActivity = false
            if let delta = Self.parseStreamTextDelta(object) {
                appendAssistantDelta(delta)
                didUpdateVisibleActivity = !delta.isEmpty
            }
            if let toolMessage = Self.parseStreamToolUse(object) {
                appendToolMessage(toolMessage)
                didUpdateVisibleActivity = true
            }
            if didUpdateVisibleActivity {
                markActiveState(.running)
                publishActivity()
            }
        case "assistant":
            handleAssistantEvent(object)
        case "user":
            handleUserEvent(object)
        case "result":
            handleResultEvent(object, sessionID: eventSessionID)
        default:
            break
        }
    }

    private func handleSystemEvent(_ object: [String: Any], sessionID: String?) {
        let subtype = Self.string(object["subtype"]) ?? ""
        switch subtype {
        case "init":
            let resolvedID = sessionID ?? activeSessionID ?? activePlaceholderID
            let cwd = Self.string(object["cwd"])
            let model = Self.string(object["model"])
            if let resolvedID {
                adoptSessionIDIfNeeded(resolvedID, cwd: cwd, model: model)
                updateSessionMetadata(id: activeSessionID ?? resolvedID, cwd: cwd, model: model)
                activeSessionID = activeSessionID ?? resolvedID
                updateState(sessionID: resolvedID, state: .running)
            }
            connection = .connected
            publishActivity()

        case "api_retry":
            let attempt = Self.string(object["attempt"]) ?? "?"
            errorMessage = "Claude Code is retrying the API request (attempt \(attempt))."
            publishActivity()

        case "permission_denied":
            let tool = Self.string(object["tool_name"]) ?? "a tool"
            errorMessage = "Claude Code denied permission for \(tool). Review permissions in Claude Code."
            publishActivity()

        case "error":
            errorMessage = Self.string(object["error"]) ?? Self.string(object["message"]) ?? "Claude Code reported an error."
            publishActivity()

        default:
            break
        }
    }

    private func handleAssistantEvent(_ object: [String: Any]) {
        guard let message = object["message"] as? [String: Any] else { return }
        let messageID = Self.string(message["id"]) ?? UUID().uuidString
        for (index, block) in Self.contentBlocks(from: message["content"]).enumerated() {
            switch Self.string(block["type"]) {
            case "text":
                guard let text = Self.string(block["text"]), !text.isEmpty else { continue }
                replaceStreamingAssistant(text, fallbackID: "\(messageID)-text-\(index)")
            case "tool_use":
                appendToolBlock(block, fallbackID: "\(messageID)-tool-\(index)")
            default:
                continue
            }
        }
        markActiveState(.running)
        publishActivity()
    }

    private func handleUserEvent(_ object: [String: Any]) {
        guard let message = object["message"] as? [String: Any],
              let text = Self.userText(from: message["content"]),
              !text.isEmpty else { return }
        // The optimistic composer row already represents this prompt. Avoid
        // rendering the CLI acknowledgement as a duplicate user message.
        guard let sessionID = activeSessionID else { return }
        let list = messagesBySession[sessionID] ?? []
        guard !list.contains(where: { $0.role == .user && $0.text == text }) else { return }
        mergeMessage(
            ClaudeCodeMessage(id: Self.string(object["uuid"]) ?? UUID().uuidString, role: .user, text: text),
            into: sessionID
        )
        publishActivity()
    }

    private func handleResultEvent(_ object: [String: Any], sessionID: String?) {
        if let sessionID { adoptSessionIDIfNeeded(sessionID, cwd: nil, model: nil) }
        let result = Self.string(object["result"])?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !result.isEmpty { replaceStreamingAssistant(result, fallbackID: "claude-result-\(activeTurnID ?? UUID().uuidString)") }
        let denials = Self.parsePermissionDenials(object["permission_denials"])
        if !denials.isEmpty {
            errorMessage = "Claude Code denied: \(denials.joined(separator: ", ")). Review permissions in Claude Code."
        }
        let isError = (object["is_error"] as? Bool) == true
        let subtype = Self.string(object["subtype"]) ?? ""
        let state: ClaudeCodeSessionState
        if subtype.contains("interrupt") { state = .interrupted }
        else if isError || subtype.contains("error") || subtype.contains("fail") { state = .failed }
        else { state = .idle }
        finishStreamingMessages()
        markActiveState(state)
        publishActivity()
    }

    private func handleTermination(status: Int32, generation: Int) {
        guard generation == processGeneration, !isStopping else { return }
        let wasInterrupting = isInterrupting
        isInterrupting = false
        process = nil
        outputHandle?.readabilityHandler = nil
        errorHandle?.readabilityHandler = nil
        outputHandle = nil
        errorHandle = nil

        let stderr = ioQueue.sync { stderrBuffer.trimmingCharacters(in: .whitespacesAndNewlines) }
        if wasInterrupting {
            finishStreamingMessages()
            markActiveState(.interrupted)
            connection = .connected
        } else if status != 0 {
            let message = stderr.components(separatedBy: .newlines).last(where: { !$0.isEmpty })
            errorMessage = message ?? "Claude Code stopped unexpectedly (\(status))."
            markActiveState(.failed)
            connection = .failed
        } else {
            finishStreamingMessages()
            if let activeSessionID,
               sessions.first(where: { $0.id == activeSessionID })?.state == .running {
                markActiveState(.idle)
            }
            connection = .connected
        }
        activeTurnID = nil
        streamingAssistantID = nil
        publishActivity()
        refreshSessions()
    }

    // MARK: Transcript discovery

    func refreshSessions() {
        let generation = processGeneration
        ioQueue.async { [weak self] in
            guard let self else { return }
            let discovered = self.scanSessions()
            DispatchQueue.main.async { [weak self] in
                guard let self,
                      generation == self.processGeneration,
                      !self.isStopping else { return }
                self.applyDiscoveredSessions(discovered)
            }
        }
    }

    private func scanSessions() -> [ClaudeCodeSession] {
        let root = transcriptRootURL.standardizedFileURL
        var isDirectory: ObjCBool = false
        let rootExists = FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory)
            && isDirectory.boolValue
        let parent = root.deletingLastPathComponent()
        let parentExists = FileManager.default.fileExists(atPath: parent.path, isDirectory: &isDirectory)
            && isDirectory.boolValue
        if rootExists {
            transcriptWatcher.start(watching: root)
        } else if parentExists {
            // Watch ~/.claude so a later-created projects directory is seen,
            // without polling the user's home directory.
            transcriptWatcher.start(watching: parent)
        } else {
            transcriptWatcher.stop()
        }
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var candidates: [(url: URL, modifiedAt: Date)] = []
        for case let url as URL in enumerator {
            guard url.pathExtension == "jsonl",
                  !url.path.contains("/subagents/") else { continue }
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey])
            guard values?.isRegularFile != false else { continue }
            let modifiedAt = values?.contentModificationDate ?? .distantPast
            candidates.append((url, modifiedAt))
        }

        // The UI exposes the newest 50 sessions. Parsing a bounded recent
        // window keeps startup responsive even when Claude has years of old
        // transcript history; the extra headroom handles duplicate files
        // for the same session without needing to read the whole archive.
        var byID: [String: ClaudeCodeSession] = [:]
        for candidate in candidates.sorted(by: { $0.modifiedAt > $1.modifiedAt }).prefix(100) {
            guard let data = try? Data(contentsOf: candidate.url), !data.isEmpty else { continue }
            let entries = Self.parseJSONLines(data)
            let fallbackID = candidate.url.deletingPathExtension().lastPathComponent
            let fileDate = candidate.modifiedAt == .distantPast ? Date() : candidate.modifiedAt
            guard let session = Self.parseSessionMetadata(
                from: entries,
                sessionID: fallbackID,
                transcriptPath: candidate.url.path,
                fileDate: fileDate
            ) else { continue }
            if let previous = byID[session.id], previous.updatedAt >= session.updatedAt { continue }
            byID[session.id] = session
        }
        return byID.values.sorted {
            if $0.updatedAt != $1.updatedAt { return $0.updatedAt > $1.updatedAt }
            return $0.id < $1.id
        }.prefix(50).map { $0 }
    }

    private func scheduleTranscriptRefresh(changedPaths: [String]) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard !isStopping, process?.isRunning != true else { return }

        var transcriptPaths = Set<String>()
        var needsFullRefresh = changedPaths.isEmpty
        var directoryChanged = false
        for path in changedPaths where !path.contains("/subagents/") {
            if URL(fileURLWithPath: path).pathExtension.lowercased() == "jsonl" {
                transcriptPaths.insert(path)
            } else {
                var isDirectory: ObjCBool = false
                if FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) {
                    if isDirectory.boolValue { directoryChanged = true }
                    else { needsFullRefresh = true }
                } else {
                    needsFullRefresh = true
                }
            }
        }
        if transcriptPaths.isEmpty, directoryChanged {
            needsFullRefresh = true
        }
        if transcriptPaths.isEmpty, !changedPaths.isEmpty, !needsFullRefresh {
            return
        }

        pendingTranscriptPaths.formUnion(transcriptPaths)
        pendingFullTranscriptRefresh = pendingFullTranscriptRefresh || needsFullRefresh
        transcriptRefreshWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.isStopping, self.process?.isRunning != true else { return }
            let paths = self.pendingTranscriptPaths
            let refreshAll = self.pendingFullTranscriptRefresh
            self.pendingTranscriptPaths.removeAll()
            self.pendingFullTranscriptRefresh = false
            if refreshAll {
                self.refreshSessions()
            } else if !paths.isEmpty {
                self.refreshTranscriptFiles(at: paths)
            }
        }
        transcriptRefreshWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
    }

    private struct TranscriptSnapshot {
        var session: ClaudeCodeSession
        var messages: [ClaudeCodeMessage]
    }

    private func refreshTranscriptFiles(at paths: Set<String>) {
        let generation = processGeneration
        ioQueue.async { [weak self] in
            guard let self else { return }
            var snapshots: [TranscriptSnapshot] = []
            var deletedPaths = Set<String>()
            for path in paths {
                if let snapshot = self.readTranscript(at: path) {
                    snapshots.append(snapshot)
                } else if !FileManager.default.fileExists(atPath: path) {
                    deletedPaths.insert(path)
                }
            }
            DispatchQueue.main.async { [weak self] in
                guard let self,
                      generation == self.processGeneration,
                      !self.isStopping else { return }
                self.applyTranscriptChanges(snapshots, deletedPaths: deletedPaths)
            }
        }
    }

    private func readTranscript(at path: String) -> TranscriptSnapshot? {
        let url = URL(fileURLWithPath: path)
        guard !path.contains("/subagents/"),
              let data = try? Data(contentsOf: url),
              !data.isEmpty else { return nil }
        let entries = Self.parseJSONLines(data)
        let attributes = try? FileManager.default.attributesOfItem(atPath: path)
        let fileDate = attributes?[.modificationDate] as? Date ?? Date()
        guard let session = Self.parseSessionMetadata(
            from: entries,
            sessionID: url.deletingPathExtension().lastPathComponent,
            transcriptPath: path,
            fileDate: fileDate
        ) else { return nil }
        return TranscriptSnapshot(
            session: session,
            messages: Self.parseTranscriptMessages(from: entries)
        )
    }

    private func applyTranscriptChanges(_ snapshots: [TranscriptSnapshot], deletedPaths: Set<String>) {
        for path in deletedPaths {
            guard let deleted = sessions.first(where: { $0.transcriptPath == path }) else { continue }
            sessions.removeAll { $0.id == deleted.id }
            messagesBySession.removeValue(forKey: deleted.id)
        }

        for snapshot in snapshots {
            var session = snapshot.session
            if let index = sessions.firstIndex(where: { $0.id == session.id }) {
                session.state = sessions[index].state
                sessions[index] = session
            } else {
                sessions.append(session)
            }
            messagesBySession[session.id] = snapshot.messages
            if selectedSessionID == session.id, process?.isRunning != true {
                messages = snapshot.messages
            }
        }
        sessions.sort {
            if $0.updatedAt != $1.updatedAt { return $0.updatedAt > $1.updatedAt }
            return $0.id < $1.id
        }

        if let selectedSessionID,
           !sessions.contains(where: { $0.id == selectedSessionID }) {
            self.selectedSessionID = ClaudeCodeSession.newest(in: sessions)?.id
            messages = self.selectedSessionID.flatMap { messagesBySession[$0] } ?? []
        } else if selectedSessionID == nil,
                  let newest = ClaudeCodeSession.newest(in: sessions) {
            selectedSessionID = newest.id
            messages = messagesBySession[newest.id] ?? []
        }
        publishActivity()
    }

    private func applyDiscoveredSessions(_ discovered: [ClaudeCodeSession]) {
        let activeIDs = Set(sessions.filter { $0.isSynthetic }.map(\.id))
        var merged = discovered
        for existing in sessions where existing.isSynthetic || activeIDs.contains(existing.id) {
            if !merged.contains(where: { $0.id == existing.id }) { merged.append(existing) }
        }
        for existing in sessions where existing.id == activeSessionID {
            if let index = merged.firstIndex(where: { $0.id == existing.id }) {
                var preserved = merged[index]
                preserved.state = existing.state
                merged[index] = preserved
            }
        }
        sessions = merged.sorted {
            if $0.updatedAt != $1.updatedAt { return $0.updatedAt > $1.updatedAt }
            return $0.id < $1.id
        }
        connection = .connected

        if let selectedSessionID,
           let session = sessions.first(where: { $0.id == selectedSessionID }) {
            if !session.isSynthetic, process?.isRunning != true,
               let path = session.transcriptPath {
                loadMessages(for: session.id, transcriptPath: path)
            }
        } else if let newest = ClaudeCodeSession.newest(in: sessions) {
            selectedSessionID = newest.id
            if let path = newest.transcriptPath {
                loadMessages(for: newest.id, transcriptPath: path)
            }
        }
        publishActivity()
    }

    private func loadMessages(for sessionID: String, transcriptPath: String) {
        ioQueue.async { [weak self] in
            guard let self,
                  let data = try? Data(contentsOf: URL(fileURLWithPath: transcriptPath)) else { return }
            let parsed = Self.parseTranscriptMessages(from: Self.parseJSONLines(data))
            DispatchQueue.main.async { [weak self] in
                guard let self,
                      self.selectedSessionID == sessionID,
                      self.process?.isRunning != true else { return }
                self.messagesBySession[sessionID] = parsed
                self.messages = parsed
                self.publishActivity()
            }
        }
    }

    // MARK: State and message helpers

    private func adoptSessionIDIfNeeded(_ id: String, cwd: String?, model: String?) {
        guard !id.isEmpty else { return }
        if let placeholder = activePlaceholderID,
           let index = sessions.firstIndex(where: { $0.id == placeholder }) {
            let old = sessions[index]
            let replacement = ClaudeCodeSession(
                id: id,
                title: old.title,
                preview: old.preview,
                directory: cwd ?? old.directory,
                createdAt: old.createdAt,
                updatedAt: Date(),
                state: .running,
                model: model ?? old.model,
                transcriptPath: old.transcriptPath,
                isSynthetic: false
            )
            sessions[index] = replacement
            messagesBySession[id] = messagesBySession.removeValue(forKey: placeholder) ?? messages
            if selectedSessionID == placeholder { selectedSessionID = id }
            activePlaceholderID = nil
        }
        activeSessionID = id
        if !sessions.contains(where: { $0.id == id }) {
            let now = Date()
            sessions.insert(
                ClaudeCodeSession(
                    id: id,
                    title: "Claude session",
                    preview: "",
                    directory: cwd ?? Self.defaultWorkingDirectory(),
                    createdAt: now,
                    updatedAt: now,
                    state: .running,
                    model: model,
                    transcriptPath: nil
                ),
                at: 0
            )
            selectedSessionID = id
        }
    }

    private func updateSessionMetadata(id: String, cwd: String?, model: String?) {
        guard let index = sessions.firstIndex(where: { $0.id == id }) else { return }
        var session = sessions[index]
        if let cwd, !cwd.isEmpty { session.directory = cwd }
        if let model, !model.isEmpty { session.model = model }
        session.updatedAt = Date()
        sessions[index] = session
    }

    private func updateState(sessionID: String, state: ClaudeCodeSessionState) {
        guard let index = sessions.firstIndex(where: { $0.id == sessionID }) else { return }
        sessions[index].state = state
        sessions[index].updatedAt = Date()
    }

    private func markActiveState(_ state: ClaudeCodeSessionState) {
        if let activeSessionID { updateState(sessionID: activeSessionID, state: state) }
        else if let activePlaceholderID { updateState(sessionID: activePlaceholderID, state: state) }
    }

    private func mergeMessage(_ message: ClaudeCodeMessage, into sessionID: String) {
        var list = messagesBySession[sessionID] ?? []
        Self.merge(message, into: &list)
        messagesBySession[sessionID] = Array(list.suffix(120))
        if selectedSessionID == sessionID { messages = messagesBySession[sessionID] ?? [] }
    }

    private func appendAssistantDelta(_ delta: String) {
        guard !delta.isEmpty, let sessionID = activeSessionID ?? activePlaceholderID else { return }
        let id = streamingAssistantID ?? "claude-stream-\(activeTurnID ?? UUID().uuidString)"
        streamingAssistantID = id
        var list = messagesBySession[sessionID] ?? []
        if let index = list.firstIndex(where: { $0.id == id }) {
            list[index].text += delta
            list[index].isStreaming = true
        } else {
            list.append(ClaudeCodeMessage(id: id, role: .assistant, text: delta, isStreaming: true))
        }
        messagesBySession[sessionID] = Array(list.suffix(120))
        if selectedSessionID == sessionID { messages = messagesBySession[sessionID] ?? [] }
    }

    private func replaceStreamingAssistant(_ text: String, fallbackID: String) {
        guard let sessionID = activeSessionID ?? activePlaceholderID else { return }
        var list = messagesBySession[sessionID] ?? []
        if let streamingAssistantID,
           let index = list.firstIndex(where: { $0.id == streamingAssistantID }) {
            list[index].text = text
            list[index].isStreaming = true
            messagesBySession[sessionID] = list
            if selectedSessionID == sessionID { messages = list }
            return
        }
        let message = ClaudeCodeMessage(id: fallbackID, role: .assistant, text: text, isStreaming: true)
        Self.merge(message, into: &list)
        streamingAssistantID = fallbackID
        messagesBySession[sessionID] = Array(list.suffix(120))
        if selectedSessionID == sessionID { messages = messagesBySession[sessionID] ?? [] }
    }

    private func finishStreamingMessages() {
        guard let sessionID = activeSessionID ?? activePlaceholderID else { return }
        var list = messagesBySession[sessionID] ?? []
        for index in list.indices where list[index].isStreaming {
            list[index].isStreaming = false
        }
        messagesBySession[sessionID] = list
        if selectedSessionID == sessionID { messages = list }
    }

    private func appendToolBlock(_ block: [String: Any], fallbackID: String? = nil) {
        appendToolMessage(Self.toolMessage(from: block, fallbackID: fallbackID))
    }

    private func appendToolMessage(_ message: ClaudeCodeMessage) {
        guard let sessionID = activeSessionID ?? activePlaceholderID else { return }
        mergeMessage(message, into: sessionID)
    }

    private static func toolMessage(
        from block: [String: Any],
        fallbackID: String?
    ) -> ClaudeCodeMessage {
        let name = Self.string(block["name"]) ?? "tool"
        let id = Self.string(block["id"]) ?? fallbackID ?? "claude-tool-\(UUID().uuidString)"
        return ClaudeCodeMessage(
            id: id,
            role: .tool,
            text: Self.toolTitle(name: name, input: block["input"]),
            detail: Self.toolDetail(name: name, input: block["input"]),
            isStreaming: true
        )
    }

    private func publishActivity() {
        dispatchPrecondition(condition: .onQueue(.main))
        onActivity?(activity)
    }

    // MARK: Shared parsing and process helpers

    private static func parseJSONLines(_ data: Data) -> [[String: Any]] {
        guard let text = String(data: data, encoding: .utf8) else { return [] }
        return text.split(whereSeparator: \.isNewline).compactMap { line in
            guard let data = String(line).data(using: .utf8) else { return nil }
            return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        }
    }

    private static func contentBlocks(from value: Any?) -> [[String: Any]] {
        if let blocks = value as? [[String: Any]] { return blocks }
        if let block = value as? [String: Any] { return [block] }
        return []
    }

    private static func userText(from value: Any?) -> String? {
        if let value = string(value) { return value.trimmingCharacters(in: .whitespacesAndNewlines) }
        let text = contentBlocks(from: value)
            .filter { string($0["type"]) == "text" }
            .compactMap { string($0["text"]) }
            .joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    private static func merge(_ message: ClaudeCodeMessage, into messages: inout [ClaudeCodeMessage]) {
        if let index = messages.firstIndex(where: { $0.id == message.id }) {
            messages[index] = message
        } else {
            messages.append(message)
        }
    }

    private static func string(_ value: Any?) -> String? {
        if let value = value as? String { return value }
        if let value = value as? NSString { return String(value) }
        if let value = value as? NSNumber { return value.stringValue }
        return nil
    }

    private static func isoDate(_ value: Any?) -> Date? {
        guard let value = string(value) else { return nil }
        return ISO8601DateFormatter().date(from: value)
    }

    private static func firstLine(of value: String) -> String {
        value.split(whereSeparator: \.isNewline).first.map(String.init) ?? value
    }

    private static func toolTitle(name: String, input: Any?) -> String {
        if name.lowercased() == "bash", let command = string((input as? [String: Any])?["command"]) {
            return "$ \(command)"
        }
        return "Tool · \(name)"
    }

    private static func toolDetail(name: String, input: Any?) -> String? {
        guard let object = input as? [String: Any] else { return nil }
        for key in ["description", "command", "file_path", "path", "pattern", "query"] {
            if let value = string(object[key]), !value.isEmpty { return value }
        }
        return nil
    }

    private static func executablePath() -> String? {
        let environmentPath = ProcessInfo.processInfo.environment["PATH"] ?? ""
        let candidates = environmentPath.split(separator: ":").map(String.init)
            .map { URL(fileURLWithPath: $0).appendingPathComponent("claude").path }
            + [
                "\(NSHomeDirectory())/.local/bin/claude",
                "\(NSHomeDirectory())/.npm-global/bin/claude",
                "/opt/homebrew/bin/claude",
                "/usr/local/bin/claude"
            ]
        var seen = Set<String>()
        return candidates.first {
            seen.insert($0).inserted && FileManager.default.isExecutableFile(atPath: $0)
        }
    }

    private static func processEnvironment() -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        var paths = (environment["PATH"] ?? "").split(separator: ":").map(String.init)
        for path in [
            "\(NSHomeDirectory())/.local/bin",
            "\(NSHomeDirectory())/.npm-global/bin",
            "/opt/homebrew/bin",
            "/usr/local/bin"
        ] where !paths.contains(path) {
            paths.append(path)
        }
        environment["PATH"] = paths.joined(separator: ":")
        return environment
    }

    private static func defaultWorkingDirectory() -> String {
        let candidates = [
            ProcessInfo.processInfo.environment["PWD"],
            FileManager.default.currentDirectoryPath,
            NSHomeDirectory()
        ].compactMap { $0 }
        return candidates.first(where: { FileManager.default.fileExists(atPath: $0) }) ?? NSHomeDirectory()
    }
}

private extension Optional where Wrapped == String {
    var isNilOrEmpty: Bool { self?.isEmpty != false }
}
