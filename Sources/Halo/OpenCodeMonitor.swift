import Combine
import Foundation

// MARK: - OpenCode activity model

enum OpenCodeConnectionState: Equatable {
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
        case .connected: return "RDY"
        case .unavailable: return "N/A"
        case .failed: return "ERR"
        }
    }
}

enum OpenCodeSessionState: Equatable {
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

    /// Halo's compact surface has room for three characters at the trailing
    /// edge. Keep every OpenCode state legible at that size.
    var compactLabel: String {
        switch self {
        case .idle: return "RDY"
        case .running: return "RUN"
        case .waiting: return "ASK"
        case .failed: return "ERR"
        case .interrupted: return "STP"
        }
    }

    static func fromStatus(_ value: Any?) -> OpenCodeSessionState {
        if let status = value as? String {
            return fromStatusType(status)
        }
        guard let object = value as? [String: Any] else { return .idle }
        return fromStatusType(string(object["type"]) ?? "idle")
    }

    private static func fromStatusType(_ type: String) -> OpenCodeSessionState {
        switch type {
        case "busy", "running": return .running
        case "retry": return .running
        case "error", "failed": return .failed
        case "aborted", "interrupted": return .interrupted
        default: return .idle
        }
    }

    private static func string(_ value: Any?) -> String? {
        if let value = value as? String { return value }
        if let value = value as? NSString { return String(value) }
        return nil
    }
}

struct OpenCodeSession: Identifiable, Equatable {
    let id: String
    var title: String
    var preview: String
    var directory: String
    var createdAt: Date
    var updatedAt: Date
    var state: OpenCodeSessionState
    var agent: String?
    var model: String?

    var repositoryName: String {
        let trimmed = directory.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return trimmed.split(separator: "/").last.map(String.init) ?? "Local workspace"
    }

    static func newest(in sessions: [OpenCodeSession]) -> OpenCodeSession? {
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

enum OpenCodeMessageRole: String, Equatable {
    case user
    case assistant
    case tool
}

struct OpenCodeMessage: Identifiable, Equatable {
    let id: String
    var role: OpenCodeMessageRole
    var text: String
    var detail: String?
    var isStreaming: Bool

    init(
        id: String,
        role: OpenCodeMessageRole,
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

struct OpenCodePermission: Identifiable, Equatable {
    let id: String
    let sessionID: String
    let action: String
    let resources: [String]

    var title: String {
        let readableAction = action.isEmpty ? "continue" : action
        return "Allow OpenCode to \(readableAction)?"
    }

    var detail: String {
        resources.joined(separator: ", ")
    }
}

enum OpenCodePermissionDecision: String {
    case once
    case always
    case reject
}

struct OpenCodeActivity: Equatable {
    var sessions: [OpenCodeSession]
    var selectedSessionID: String?
    var messages: [OpenCodeMessage]
    var connection: OpenCodeConnectionState
    var pendingPermission: OpenCodePermission?
    var errorMessage: String?

    var selectedSession: OpenCodeSession? {
        guard let selectedSessionID else { return OpenCodeSession.newest(in: sessions) }
        return sessions.first(where: { $0.id == selectedSessionID }) ?? OpenCodeSession.newest(in: sessions)
    }

    var selectedState: OpenCodeSessionState {
        selectedSession?.state ?? .idle
    }

    var compactLabel: String {
        if pendingPermission != nil { return "ASK" }
        if selectedSession != nil { return selectedState.compactLabel }
        return connection.compactLabel
    }

    func visibleMessages(showWorkActivity: Bool) -> [OpenCodeMessage] {
        guard !showWorkActivity else { return messages }
        return messages.filter { $0.role != .tool }
    }

    func conversationScrollToken(showWorkActivity: Bool) -> String {
        visibleMessages(showWorkActivity: showWorkActivity)
            .map { message in
                [message.id, message.text, String(message.isStreaming)].joined(separator: "\u{1F}")
            }
            .joined(separator: "\u{1E}")
    }
}

// MARK: - OpenCode local server client

/// Bridges Halo to OpenCode's local HTTP server. OpenCode owns credentials,
/// providers, model selection, permissions, and session persistence. Halo
/// only starts a local server, subscribes to its event stream, and renders
/// the returned value types.
final class OpenCodeMonitor: NSObject, ObservableObject, URLSessionDataDelegate {
    @Published private(set) var sessions: [OpenCodeSession] = []
    @Published private(set) var selectedSessionID: String?
    @Published private(set) var messages: [OpenCodeMessage] = []
    @Published private(set) var connection: OpenCodeConnectionState = .stopped
    @Published private(set) var pendingPermission: OpenCodePermission?
    @Published private(set) var errorMessage: String?

    var onActivity: ((OpenCodeActivity) -> Void)?

    private let ioQueue = DispatchQueue(label: "com.tryhalo.halo.opencode.io")
    private let urlSessionQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .utility
        return queue
    }()

    private var process: Process?
    private var outputHandle: FileHandle?
    private var errorHandle: FileHandle?
    private var serverLogBuffer = ""
    private var serverErrorBuffer = ""
    private var serverURL: URL?
    private var urlSession: URLSession?
    private var eventTask: URLSessionDataTask?
    private var eventBuffer = Data()
    private var reconnectWorkItem: DispatchWorkItem?
    private var processGeneration = 0
    private var isStopping = false
    private var isCreatingSession = false
    private var pendingNewMessage: String?
    private var pendingMessageTexts: [String: String] = [:]
    private var optimisticMessageIDs: [String: String] = [:]
    private var messagesBySession: [String: [OpenCodeMessage]] = [:]
    private var messageRefreshes = RefreshCoalescer<String>()
    private var serverPassword: String?

    var activity: OpenCodeActivity {
        OpenCodeActivity(
            sessions: sessions,
            selectedSessionID: selectedSessionID,
            messages: messages,
            connection: connection,
            pendingPermission: pendingPermission,
            errorMessage: errorMessage
        )
    }

    private var selectedSession: OpenCodeSession? {
        guard let selectedSessionID else { return OpenCodeSession.newest(in: sessions) }
        return sessions.first(where: { $0.id == selectedSessionID }) ?? OpenCodeSession.newest(in: sessions)
    }

    deinit {
        stop()
    }

    // MARK: Lifecycle

    // OpenCode v2's server routes are authenticated when a server password is
    // configured. Halo owns an ephemeral password for the child process and
    // sends it only to that child server over loopback.
    static let localServerArguments = [
        "serve",
        "--hostname", "127.0.0.1",
        "--port", "0"
    ]

    // OpenCode's documented default username is `opencode`. Keeping the
    // username fixed also works with v2.0.1, which ignores a custom username
    // environment value while still honoring the server password.
    private static let localServerUsername = "opencode"

    static func apiPath(_ path: String) -> String {
        "/api\(path)"
    }

    func start() {
        dispatchPrecondition(condition: .onQueue(.main))
        guard process?.isRunning != true else {
            if serverURL == nil { return }
            refresh()
            return
        }

        guard let executable = Self.openCodeExecutable() else {
            connection = .unavailable
            errorMessage = "OpenCode CLI was not found. Install OpenCode and try again."
            publishActivity()
            return
        }

        isStopping = false
        processGeneration &+= 1
        messageRefreshes.reset()
        let generation = processGeneration
        serverURL = nil
        serverPassword = nil
        eventBuffer.removeAll(keepingCapacity: false)
        serverLogBuffer = ""
        serverErrorBuffer = ""
        errorMessage = nil
        connection = .starting
        publishActivity()

        let newProcess = Process()
        newProcess.executableURL = URL(fileURLWithPath: executable)
        // Port zero asks the OS for a free local port. This keeps Halo from
        // colliding with an OpenCode server the user already started.
        newProcess.arguments = Self.localServerArguments
        let password = UUID().uuidString
        var environment = Self.processEnvironment()
        environment["OPENCODE_SERVER_USERNAME"] = Self.localServerUsername
        environment["OPENCODE_SERVER_PASSWORD"] = password
        newProcess.environment = environment
        newProcess.currentDirectoryURL = URL(fileURLWithPath: defaultWorkingDirectory())

        let output = Pipe()
        let error = Pipe()
        newProcess.standardOutput = output
        newProcess.standardError = error

        do {
            try newProcess.run()
        } catch {
            connection = .failed
            errorMessage = "Could not start OpenCode server: \(error.localizedDescription)"
            publishActivity()
            return
        }

        process = newProcess
        serverPassword = password
        outputHandle = output.fileHandleForReading
        errorHandle = error.fileHandleForReading

        outputHandle?.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            self?.ioQueue.async { [weak self] in
                self?.consumeServerOutput(data, generation: generation, isError: false)
            }
        }
        errorHandle?.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            self?.ioQueue.async { [weak self] in
                self?.consumeServerOutput(data, generation: generation, isError: true)
            }
        }
        newProcess.terminationHandler = { [weak self] terminatedProcess in
            let status = terminatedProcess.terminationStatus
            DispatchQueue.main.async { [weak self] in
                self?.handleTermination(status: status, generation: generation)
            }
        }
    }

    func stop() {
        if !Thread.isMainThread {
            DispatchQueue.main.async { [weak self] in self?.stop() }
            return
        }

        isStopping = true
        processGeneration &+= 1
        reconnectWorkItem?.cancel()
        reconnectWorkItem = nil
        eventTask?.cancel()
        eventTask = nil
        urlSession?.invalidateAndCancel()
        urlSession = nil
        outputHandle?.readabilityHandler = nil
        errorHandle?.readabilityHandler = nil
        process?.terminate()
        process = nil
        serverPassword = nil
        outputHandle = nil
        errorHandle = nil
        serverURL = nil
        messageRefreshes.reset()
        pendingPermission = nil
        pendingNewMessage = nil
        pendingMessageTexts.removeAll()
        optimisticMessageIDs.removeAll()
        isCreatingSession = false
        connection = .stopped
        publishActivity()
    }

    func refresh() {
        dispatchPrecondition(condition: .onQueue(.main))
        guard process?.isRunning == true else {
            start()
            return
        }
        guard serverURL != nil else { return }
        requestSessions()
        requestStatuses()
    }

    func selectSession(_ id: String) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard sessions.contains(where: { $0.id == id }) else { return }
        selectedSessionID = id
        messages = messagesBySession[id] ?? []
        pendingPermission = pendingPermission?.sessionID == id ? pendingPermission : nil
        publishActivity()
        loadMessages(for: id)
    }

    func createSession() {
        dispatchPrecondition(condition: .onQueue(.main))
        guard process?.isRunning == true, serverURL != nil else {
            start()
            return
        }
        guard !isCreatingSession else { return }
        isCreatingSession = true
        post(
            path: Self.apiPath("/session"),
            query: [],
            body: [:]
        ) { [weak self] data, status, error in
            guard let self else { return }
            let parsed = data.flatMap(Self.parseSessionResponse)
            DispatchQueue.main.async {
                self.isCreatingSession = false
                guard status >= 200, status < 300, let parsed else {
                    self.errorMessage = Self.requestError(status: status, error: error, fallback: "OpenCode could not create a session.")
                    self.publishActivity()
                    return
                }
                self.upsertSession(parsed, select: true)
                self.messagesBySession[parsed.id] = []
                self.messages = []
                self.errorMessage = nil
                if let text = self.pendingNewMessage {
                    self.pendingNewMessage = nil
                    self.send(text)
                } else {
                    self.publishActivity()
                }
            }
        }
    }

    func send(_ text: String) {
        dispatchPrecondition(condition: .onQueue(.main))
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        guard process?.isRunning == true, serverURL != nil else {
            pendingNewMessage = trimmed
            start()
            return
        }

        guard let sessionID = selectedSessionID else {
            pendingNewMessage = trimmed
            createSession()
            return
        }
        guard selectedSession?.state != .running,
              selectedSession?.state != .waiting else { return }

        let optimisticID = "halo-opencode-user-\(UUID().uuidString)"
        optimisticMessageIDs[sessionID] = optimisticID
        pendingMessageTexts[sessionID] = trimmed
        mergeMessage(
            OpenCodeMessage(id: optimisticID, role: .user, text: trimmed),
            into: sessionID
        )
        updateSessionState(sessionID, state: .running)
        errorMessage = nil
        publishActivity()

        post(
            path: Self.apiPath("/session/\(sessionID)/prompt"),
            query: [],
            body: Self.promptBody(text: trimmed)
        ) { [weak self] _, status, error in
            guard let self else { return }
            guard status >= 200, status < 300 else {
                DispatchQueue.main.async {
                    self.pendingMessageTexts.removeValue(forKey: sessionID)
                    if let optimisticID = self.optimisticMessageIDs.removeValue(forKey: sessionID) {
                        self.removeMessage(optimisticID, from: sessionID)
                    }
                    self.updateSessionState(sessionID, state: .failed)
                    self.errorMessage = Self.requestError(status: status, error: error, fallback: "OpenCode could not send this message.")
                    self.publishActivity()
                }
                return
            }
        }
    }

    func interrupt() {
        dispatchPrecondition(condition: .onQueue(.main))
        guard let sessionID = selectedSessionID,
              selectedSession?.state == .running else { return }
        updateSessionState(sessionID, state: .interrupted)
        publishActivity()
        post(path: Self.apiPath("/session/\(sessionID)/interrupt"), query: [], body: nil) { [weak self] _, status, error in
            guard let self else { return }
            guard status >= 200, status < 300 else {
                DispatchQueue.main.async {
                    self.errorMessage = Self.requestError(status: status, error: error, fallback: "OpenCode could not stop this session.")
                    self.publishActivity()
                }
                return
            }
            DispatchQueue.main.async {
                self.pendingMessageTexts.removeValue(forKey: sessionID)
                self.optimisticMessageIDs.removeValue(forKey: sessionID)
                self.loadMessages(for: sessionID)
            }
        }
    }

    func resolvePermission(_ decision: OpenCodePermissionDecision) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard let permission = pendingPermission else { return }
        pendingPermission = nil
        updateSessionState(permission.sessionID, state: .running)
        publishActivity()
        post(
            path: Self.apiPath("/session/\(permission.sessionID)/permission/\(permission.id)/reply"),
            query: [],
            body: ["reply": decision.rawValue]
        ) { [weak self] _, status, error in
            guard let self else { return }
            guard status >= 200, status < 300 else {
                DispatchQueue.main.async {
                    self.errorMessage = Self.requestError(status: status, error: error, fallback: "OpenCode could not process that permission.")
                    self.publishActivity()
                }
                return
            }
            DispatchQueue.main.async {
                self.loadMessages(for: permission.sessionID)
            }
        }
    }

    // MARK: Pure protocol helpers

    static func parseSession(_ object: [String: Any]) -> OpenCodeSession? {
        guard let id = string(object["id"]), !id.isEmpty else { return nil }
        let directory = string(object["directory"])
            ?? string((object["location"] as? [String: Any])?["directory"])
            ?? string((object["path"] as? [String: Any])?["cwd"])
            ?? ""
        let title = string(object["title"])?.trimmingCharacters(in: .whitespacesAndNewlines)
        let createdAt = date(object["time"].flatMap { ($0 as? [String: Any])?["created"] } ?? object["createdAt"])
        let updatedAt = date(object["time"].flatMap { ($0 as? [String: Any])?["updated"] } ?? object["updatedAt"], fallback: createdAt)
        let modelObject = object["model"] as? [String: Any]
        let model = string(modelObject?["id"])
            ?? string(modelObject?["modelID"])
        let state = OpenCodeSessionState.fromStatus(object["status"] ?? object["state"])
        return OpenCodeSession(
            id: id,
            title: title.flatMap { $0.isEmpty ? nil : $0 } ?? "Untitled OpenCode session",
            preview: string(object["preview"]) ?? "",
            directory: directory,
            createdAt: createdAt,
            updatedAt: updatedAt,
            state: state,
            agent: string(object["agent"]),
            model: model
        )
    }

    static func parseSessions(from data: Data) -> [OpenCodeSession] {
        guard let object = try? JSONSerialization.jsonObject(with: data) else { return [] }
        let raw: [[String: Any]]
        if let array = object as? [[String: Any]] {
            raw = array
        } else if let wrapper = object as? [String: Any],
                  let array = wrapper["data"] as? [[String: Any]] {
            raw = array
        } else {
            return []
        }
        return raw.compactMap(parseSession)
    }

    static func parseSessionResponse(_ data: Data) -> OpenCodeSession? {
        guard let object = try? JSONSerialization.jsonObject(with: data) else { return nil }
        if let object = object as? [String: Any], let data = object["data"] as? [String: Any] {
            return parseSession(data)
        }
        return (object as? [String: Any]).flatMap(parseSession)
    }

    static func parseMessageEntries(from data: Data) -> [[String: Any]] {
        guard let object = try? JSONSerialization.jsonObject(with: data) else { return [] }
        if let array = object as? [[String: Any]] { return array }
        if let wrapper = object as? [String: Any],
           let array = wrapper["data"] as? [[String: Any]] {
            return array
        }
        return []
    }

    static func parseMessages(from entries: [[String: Any]]) -> [OpenCodeMessage] {
        var messages: [OpenCodeMessage] = []
        // The v2 session API returns pages newest-first. Normalize that page
        // before rendering so the conversation remains chronological and the
        // shared follow-the-latest scroll behavior has the right direction.
        let orderedEntries: [[String: Any]]
        if entries.contains(where: { $0["type"] as? String == "assistant" || $0["type"] as? String == "user" }) {
            orderedEntries = entries.reversed()
        } else {
            orderedEntries = entries
        }
        for entry in orderedEntries {
            if let info = entry["info"] as? [String: Any] {
                parseLegacyMessage(info: info, parts: entry["parts"] as? [[String: Any]] ?? [], into: &messages)
            } else {
                parseV2Message(entry, into: &messages)
            }
        }
        return messages
    }

    private static func parseLegacyMessage(
        info: [String: Any],
        parts: [[String: Any]],
        into messages: inout [OpenCodeMessage]
    ) {
        guard let messageID = string(info["id"]),
              let roleValue = string(info["role"]) else { return }

        let text = parts.compactMap { part -> String? in
            guard string(part["type"]) == "text",
                  part["ignored"] as? Bool != true else { return nil }
            return string(part["text"])
        }.joined()
        let detail = errorText(info["error"])
        let completed = (info["time"] as? [String: Any])?["completed"] != nil

        if roleValue == OpenCodeMessageRole.user.rawValue {
            if !text.isEmpty {
                merge(OpenCodeMessage(id: messageID, role: .user, text: text), into: &messages)
            }
        } else if roleValue == OpenCodeMessageRole.assistant.rawValue {
            merge(
                OpenCodeMessage(
                    id: messageID,
                    role: .assistant,
                    text: text.isEmpty && detail != nil ? "OpenCode returned an error." : text,
                    detail: detail,
                    isStreaming: !completed
                ),
                into: &messages
            )
        }

        for part in parts {
            if let work = parseWorkPart(part) {
                merge(work, into: &messages)
            }
        }
    }

    private static func parseV2Message(_ message: [String: Any], into messages: inout [OpenCodeMessage]) {
        guard let messageID = string(message["id"]),
              let type = string(message["type"]) else { return }

        if type == OpenCodeMessageRole.user.rawValue {
            guard let text = string(message["text"]), !text.isEmpty else { return }
            merge(OpenCodeMessage(id: messageID, role: .user, text: text), into: &messages)
            return
        }

        guard type == OpenCodeMessageRole.assistant.rawValue else { return }
        let content = message["content"] as? [[String: Any]] ?? []
        let text = content
            .filter { string($0["type"]) == "text" }
            .compactMap { string($0["text"]) }
            .joined()
        let detail = errorText(message["error"])
        let time = message["time"] as? [String: Any]
        let completed = time?["completed"] != nil || string(message["finish"]) != nil
        merge(
            OpenCodeMessage(
                id: messageID,
                role: .assistant,
                text: text.isEmpty && detail != nil ? "OpenCode returned an error." : text,
                detail: detail,
                isStreaming: !completed
            ),
            into: &messages
        )

        for part in content {
            if let work = parseWorkPart(part) {
                merge(work, into: &messages)
            }
        }
    }

    static func parseWorkPart(_ part: [String: Any]) -> OpenCodeMessage? {
        guard let partID = string(part["id"]), !partID.isEmpty else { return nil }
        let type = string(part["type"]) ?? ""
        switch type {
        case "tool":
            let tool = string(part["tool"]) ?? string(part["name"]) ?? "tool"
            let state = part["state"] as? [String: Any]
            let status = string(state?["status"]) ?? "pending"
            let detail = errorText(state?["error"])
                ?? string(state?["title"])
                ?? prettyStatus(status)
            let workID = string(part["callID"]) ?? partID
            return OpenCodeMessage(
                id: "work-\(workID)",
                role: .tool,
                text: tool,
                detail: detail,
                isStreaming: status == "pending" || status == "streaming" || status == "running"
            )
        case "patch":
            let files = (part["files"] as? [[String: Any]])?.count ?? 0
            return OpenCodeMessage(
                id: "work-\(partID)",
                role: .tool,
                text: files == 1 ? "Changed 1 file" : "Changed \(files) files",
                detail: "Patch"
            )
        case "file":
            let filename = URL(fileURLWithPath: string(part["filename"]) ?? "file").lastPathComponent
            return OpenCodeMessage(id: "work-\(partID)", role: .tool, text: "Attached \(filename)")
        case "subtask":
            let description = string(part["description"]) ?? "Subtask"
            return OpenCodeMessage(id: "work-\(partID)", role: .tool, text: description, detail: "Subtask")
        case "step-start":
            return OpenCodeMessage(id: "work-\(partID)", role: .tool, text: "Step started")
        case "step-finish":
            let reason = string(part["reason"]) ?? "Step finished"
            return OpenCodeMessage(id: "work-\(partID)", role: .tool, text: reason)
        default:
            // Reasoning is intentionally omitted. Halo exposes useful work
            // state without attempting to display private chain-of-thought.
            return nil
        }
    }

    static func parseEvent(_ object: [String: Any]) -> [String: Any] {
        if let payload = object["payload"] as? [String: Any] {
            return parseEvent(payload)
        }
        guard object["properties"] == nil,
              let data = object["data"] as? [String: Any] else { return object }
        var normalized = object
        normalized["properties"] = data
        return normalized
    }

    static func parseSSEEvents(from data: Data) -> [[String: Any]] {
        guard let text = String(data: data, encoding: .utf8) else { return [] }
        return text.components(separatedBy: "\n\n").compactMap { chunk in
            let payload = chunk
                .split(whereSeparator: { $0 == "\n" || $0 == "\r" })
                .filter { $0.hasPrefix("data:") }
                .map { line in String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces) }
                .joined()
            guard let json = payload.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: json) as? [String: Any] else { return nil }
            return parseEvent(object)
        }
    }

    static func promptBody(text: String) -> [String: Any] {
        ["text": text]
    }

    static func permissionBody(_ decision: OpenCodePermissionDecision) -> [String: Any] {
        ["reply": decision.rawValue]
    }

    static func serverURL(from output: String) -> URL? {
        guard let range = output.range(
            of: "http://(127\\.0\\.0\\.1|localhost):[0-9]+",
            options: .regularExpression
        ) else { return nil }
        return URL(string: String(output[range]))
    }

    // MARK: HTTP and SSE transport

    private func consumeServerOutput(_ data: Data, generation: Int, isError: Bool) {
        guard let text = String(data: data, encoding: .utf8) else { return }
        if isError {
            serverErrorBuffer.append(text)
        } else {
            serverLogBuffer.append(text)
        }
        let combined = serverLogBuffer + "\n" + serverErrorBuffer
        guard let discoveredURL = Self.serverURL(from: combined) else { return }
        DispatchQueue.main.async { [weak self] in
            self?.serverDidStart(at: discoveredURL, generation: generation)
        }
    }

    private func serverDidStart(at url: URL, generation: Int) {
        guard generation == processGeneration,
              !isStopping,
              process?.isRunning == true,
              serverURL == nil else { return }
        serverURL = url
        let configuration = URLSessionConfiguration.ephemeral
        // SSE is intentionally long-lived. A short request timeout would
        // turn a quiet OpenCode session into a needless reconnect loop.
        configuration.timeoutIntervalForRequest = 86_400
        configuration.timeoutIntervalForResource = 7 * 86_400
        urlSession = URLSession(configuration: configuration, delegate: self, delegateQueue: urlSessionQueue)
        connection = .starting
        publishActivity()
        connectEventStream()
        requestSessions()
        requestStatuses()
    }

    private func connectEventStream() {
        guard let baseURL = serverURL,
              let session = urlSession,
              eventTask == nil else { return }
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)
        components?.path = Self.apiPath("/event")
        guard let url = components?.url else { return }
        var request = URLRequest(url: url)
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        addAuthorization(to: &request)
        let task = session.dataTask(with: request)
        eventTask = task
        task.resume()
    }

    private func requestSessions() {
        get(path: Self.apiPath("/session"), query: [URLQueryItem(name: "limit", value: "50")]) { [weak self] data, status, error in
            guard let self else { return }
            let parsed = data.map(Self.parseSessions) ?? []
            DispatchQueue.main.async {
                guard status >= 200, status < 300 else {
                    self.errorMessage = Self.requestError(status: status, error: error, fallback: "OpenCode could not list sessions.")
                    self.publishActivity()
                    return
                }
                self.applySessionList(parsed)
            }
        }
    }

    private func requestStatuses() {
        get(path: Self.apiPath("/session/active"), query: []) { [weak self] data, status, error in
            guard let self else { return }
            guard status >= 200, status < 300,
                  let data,
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                if status != 0 && !(error is URLError && (error as? URLError)?.code == .cancelled) {
                    NSLog("[Halo] opencode: status request failed (%d)", status)
                }
                return
            }
            DispatchQueue.main.async {
                let active = (object["data"] as? [String: Any]) ?? object
                let activeIDs = Set(active.keys)
                for session in self.sessions {
                    if activeIDs.contains(session.id) {
                        self.updateSessionState(session.id, state: .running)
                    } else if self.pendingPermission?.sessionID != session.id {
                        self.updateSessionState(session.id, state: .idle)
                    }
                }
                self.publishActivity()
            }
        }
    }

    private func loadMessages(for sessionID: String) {
        guard process?.isRunning == true,
              serverURL != nil,
              messageRefreshes.begin(sessionID) else { return }
        let generation = processGeneration
        get(path: Self.apiPath("/session/\(sessionID)/message"), query: [URLQueryItem(name: "limit", value: "100")]) { [weak self] data, status, error in
            guard let self else { return }
            let parsed = data.map { Self.parseMessages(from: Self.parseMessageEntries(from: $0)) } ?? []
            DispatchQueue.main.async {
                guard generation == self.processGeneration,
                      !self.isStopping,
                      self.serverURL != nil else { return }
                if self.messageRefreshes.finish(sessionID) {
                    self.loadMessages(for: sessionID)
                    return
                }
                guard status >= 200, status < 300 else {
                    self.errorMessage = Self.requestError(status: status, error: error, fallback: "OpenCode could not load this session.")
                    self.publishActivity()
                    return
                }
                self.applyMessages(parsed, for: sessionID)
            }
        }
    }

    private func get(
        path: String,
        query: [URLQueryItem],
        completion: @escaping (Data?, Int, Error?) -> Void
    ) {
        request(method: "GET", path: path, query: query, body: nil, completion: completion)
    }

    private func post(
        path: String,
        query: [URLQueryItem],
        body: [String: Any]?,
        completion: @escaping (Data?, Int, Error?) -> Void
    ) {
        request(method: "POST", path: path, query: query, body: body, completion: completion)
    }

    private func request(
        method: String,
        path: String,
        query: [URLQueryItem],
        body: [String: Any]?,
        completion: @escaping (Data?, Int, Error?) -> Void
    ) {
        guard let baseURL = serverURL,
              let session = urlSession else {
            completion(nil, 0, OpenCodeMonitorError.serverUnavailable)
            return
        }
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)
        components?.path = path
        components?.queryItems = query.isEmpty ? nil : query
        guard let url = components?.url else {
            completion(nil, 0, OpenCodeMonitorError.invalidURL)
            return
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        addAuthorization(to: &request)
        if let body,
           JSONSerialization.isValidJSONObject(body),
           let data = try? JSONSerialization.data(withJSONObject: body) {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = data
        }
        session.dataTask(with: request) { data, response, error in
            completion(data, (response as? HTTPURLResponse)?.statusCode ?? 0, error)
        }.resume()
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard dataTask == eventTask, !isStopping else { return }
        eventBuffer.append(data)
        while let range = nextSSEDelimiter(in: eventBuffer) {
            let payload = eventBuffer.subdata(in: 0..<range.lowerBound)
            eventBuffer.removeSubrange(0..<range.upperBound)
            guard let text = String(data: payload, encoding: .utf8) else { continue }
            let dataLines = text
                .split(whereSeparator: { $0 == "\n" || $0 == "\r" })
                .filter { $0.hasPrefix("data:") }
                .map { String($0.dropFirst(5)).trimmingCharacters(in: .whitespaces) }
                .joined()
            guard let json = dataLines.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: json) as? [String: Any] else { continue }
            let event = Self.parseEvent(object)
            DispatchQueue.main.async { [weak self] in
                self?.handleEvent(event)
            }
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        if dataTask == eventTask {
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.isStopping else { return }
                if (200..<300).contains(status) {
                    self.connection = .connected
                    self.errorMessage = nil
                } else {
                    self.connection = .failed
                    self.errorMessage = Self.requestError(status: status, error: nil, fallback: "OpenCode event stream was rejected.")
                }
                self.publishActivity()
            }
            if !(200..<300).contains(status) {
                completionHandler(.cancel)
                return
            }
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard task == eventTask else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.isStopping else { return }
            self.eventTask = nil
            if let error, (error as NSError).code != NSURLErrorCancelled {
                self.connection = .failed
                self.errorMessage = "OpenCode event stream disconnected. Reconnecting…"
                self.publishActivity()
            }
            self.scheduleReconnect()
        }
    }

    private func scheduleReconnect() {
        guard !isStopping, process?.isRunning == true, eventTask == nil else { return }
        reconnectWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.isStopping else { return }
            self.connection = .starting
            self.publishActivity()
            self.connectEventStream()
            self.requestSessions()
            self.requestStatuses()
        }
        reconnectWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: work)
    }

    private func nextSSEDelimiter(in data: Data) -> Range<Data.Index>? {
        let lf = data.range(of: Data([0x0A, 0x0A]))
        let crlf = data.range(of: Data([0x0D, 0x0A, 0x0D, 0x0A]))
        switch (lf, crlf) {
        case let (lf?, crlf?): return lf.lowerBound < crlf.lowerBound ? lf : crlf
        case let (lf?, nil): return lf
        case let (nil, crlf?): return crlf
        default: return nil
        }
    }

    // MARK: Event handling

    // Module-internal so protocol tests verify the event-to-activity callback.
    func handleEvent(_ rawEvent: [String: Any]) {
        let event = Self.parseEvent(rawEvent)
        guard let type = Self.string(event["type"]),
              let properties = event["properties"] as? [String: Any] else { return }

        switch type {
        case "server.connected":
            connection = .connected
            publishActivity()

        case "session.created", "session.updated":
            let info = (properties["info"] as? [String: Any]) ?? properties
            if let session = Self.parseSession(info) {
                upsertSession(session, select: type == "session.created" && selectedSessionID == nil)
                if selectedSessionID == session.id { loadMessages(for: session.id) }
                publishActivity()
            }

        case "session.deleted":
            guard let sessionID = Self.string(properties["sessionID"]) else { return }
            sessions.removeAll { $0.id == sessionID }
            messagesBySession.removeValue(forKey: sessionID)
            if selectedSessionID == sessionID {
                selectedSessionID = OpenCodeSession.newest(in: sessions)?.id
                messages = selectedSessionID.flatMap { messagesBySession[$0] } ?? []
                if let selectedSessionID { loadMessages(for: selectedSessionID) }
            }
            publishActivity()

        case "session.status":
            guard let sessionID = Self.string(properties["sessionID"]) else { return }
            let state = OpenCodeSessionState.fromStatus(properties["status"])
            updateSessionState(sessionID, state: state)
            publishActivity()

        case "session.execution.started", "session.retry.scheduled":
            guard let sessionID = Self.string(properties["sessionID"]) else { return }
            updateSessionState(sessionID, state: .running)
            publishActivity()

        case "session.execution.succeeded":
            guard let sessionID = Self.string(properties["sessionID"]) else { return }
            updateSessionState(sessionID, state: .idle)
            pendingMessageTexts.removeValue(forKey: sessionID)
            optimisticMessageIDs.removeValue(forKey: sessionID)
            loadMessages(for: sessionID)
            requestSessions()
            publishActivity()

        case "session.execution.interrupted":
            guard let sessionID = Self.string(properties["sessionID"]) else { return }
            updateSessionState(sessionID, state: .interrupted)
            pendingMessageTexts.removeValue(forKey: sessionID)
            optimisticMessageIDs.removeValue(forKey: sessionID)
            loadMessages(for: sessionID)
            publishActivity()

        case "session.execution.failed":
            guard let sessionID = Self.string(properties["sessionID"]) else { return }
            updateSessionState(sessionID, state: .failed)
            errorMessage = Self.errorText(properties["error"]) ?? "OpenCode reported an error."
            publishActivity()

        case "session.idle":
            guard let sessionID = Self.string(properties["sessionID"]) else { return }
            updateSessionState(sessionID, state: .idle)
            pendingMessageTexts.removeValue(forKey: sessionID)
            optimisticMessageIDs.removeValue(forKey: sessionID)
            if pendingPermission?.sessionID == sessionID { pendingPermission = nil }
            loadMessages(for: sessionID)
            requestSessions()
            publishActivity()

        case "session.error":
            guard let sessionID = Self.string(properties["sessionID"]) else { return }
            updateSessionState(sessionID, state: .failed)
            errorMessage = Self.errorText(properties["error"]) ?? "OpenCode reported an error."
            publishActivity()

        case "message.updated":
            let sessionID = Self.string(properties["sessionID"])
                ?? Self.string((properties["info"] as? [String: Any])?["sessionID"])
            if let sessionID {
                loadMessages(for: sessionID)
            }

        case "message.removed", "message.part.removed":
            let sessionID = Self.string(properties["sessionID"])
                ?? Self.string((properties["info"] as? [String: Any])?["sessionID"])
            if let sessionID {
                loadMessages(for: sessionID)
            }

        case "message.part.updated":
            guard let part = properties["part"] as? [String: Any] else { return }
            let sessionID = Self.string(properties["sessionID"])
                ?? Self.string(part["sessionID"])
            guard let sessionID else { return }
            applyPartUpdate(part, for: sessionID)

        case "message.part.delta":
            guard let sessionID = Self.string(properties["sessionID"]),
                  let messageID = Self.string(properties["messageID"]),
                  Self.string(properties["field"]) == "text",
                  let delta = Self.string(properties["delta"]) else { return }
            appendTextDelta(delta, messageID: messageID, sessionID: sessionID)
            updateSessionState(sessionID, state: .running)
            publishActivity()

        case "session.next.text.started":
            if let sessionID = Self.string(properties["sessionID"]),
               let messageID = Self.string(properties["assistantMessageID"]) {
                ensureAssistantMessage(messageID, sessionID: sessionID)
                updateSessionState(sessionID, state: .running)
                publishActivity()
            }

        case "session.next.text.delta":
            if let sessionID = Self.string(properties["sessionID"]),
               let messageID = Self.string(properties["assistantMessageID"]),
               let delta = Self.string(properties["delta"]) {
                appendTextDelta(delta, messageID: messageID, sessionID: sessionID)
                updateSessionState(sessionID, state: .running)
                publishActivity()
            }

        case "session.next.text.ended":
            if let sessionID = Self.string(properties["sessionID"]),
               let messageID = Self.string(properties["assistantMessageID"]) {
                replaceAssistantText(
                    properties["text"] as? String,
                    messageID: messageID,
                    sessionID: sessionID,
                    isStreaming: false
                )
                publishActivity()
            }

        case "session.next.tool.called", "session.next.tool.progress", "session.next.tool.success", "session.next.tool.failed":
            if let sessionID = Self.string(properties["sessionID"]) {
                applyNextToolEvent(type: type, properties: properties, sessionID: sessionID)
                updateSessionState(sessionID, state: .running)
                publishActivity()
            }

        case "permission.asked", "permission.v2.asked":
            guard let permission = Self.parsePermission(properties) else { return }
            pendingPermission = permission
            if sessions.contains(where: { $0.id == permission.sessionID }) {
                selectedSessionID = permission.sessionID
                messages = messagesBySession[permission.sessionID] ?? []
                loadMessages(for: permission.sessionID)
            }
            updateSessionState(permission.sessionID, state: .waiting)
            publishActivity()

        case "permission.replied", "permission.v2.replied":
            if let requestID = Self.string(properties["requestID"]), pendingPermission?.id == requestID {
                pendingPermission = nil
            }
            if let sessionID = Self.string(properties["sessionID"]) {
                updateSessionState(sessionID, state: .running)
            }
            publishActivity()

        default:
            break
        }
    }

    private func applySessionList(_ incoming: [OpenCodeSession]) {
        let oldByID = Dictionary(uniqueKeysWithValues: sessions.map { ($0.id, $0) })
        sessions = incoming.map { incomingSession in
            var session = incomingSession
            if let old = oldByID[session.id], old.state != .idle, session.state == .idle {
                session.state = old.state
            }
            return session
        }.sorted { $0.updatedAt > $1.updatedAt }

        if let selectedSessionID,
           sessions.contains(where: { $0.id == selectedSessionID }) {
            messages = messagesBySession[selectedSessionID] ?? messages
        } else if let latest = OpenCodeSession.newest(in: sessions) {
            selectedSessionID = latest.id
            messages = messagesBySession[latest.id] ?? []
            loadMessages(for: latest.id)
        } else {
            selectedSessionID = nil
            messages = []
        }

        if pendingNewMessage != nil, !isCreatingSession {
            createSession()
        }
        publishActivity()
    }

    private func applyMessages(_ parsed: [OpenCodeMessage], for sessionID: String) {
        var updated = parsed
        if let pending = pendingMessageTexts[sessionID] {
            let hasPersistedMessage = updated.last(where: { $0.role == .user })?.text == pending
            if hasPersistedMessage {
                pendingMessageTexts.removeValue(forKey: sessionID)
                optimisticMessageIDs.removeValue(forKey: sessionID)
            } else if let optimisticID = optimisticMessageIDs[sessionID] {
                Self.merge(OpenCodeMessage(id: optimisticID, role: .user, text: pending), into: &updated)
            }
        }
        messagesBySession[sessionID] = Array(updated.suffix(100))
        if selectedSessionID == sessionID { messages = messagesBySession[sessionID] ?? [] }
        updateSessionPreview(sessionID, from: updated)
        publishActivity()
    }

    private func applyPartUpdate(_ part: [String: Any], for sessionID: String) {
        let type = Self.string(part["type"]) ?? ""
        guard let messageID = Self.string(part["messageID"]) else { return }
        switch type {
        case "text":
            let text = Self.string(part["text"]) ?? ""
            replaceAssistantText(
                text,
                messageID: messageID,
                sessionID: sessionID,
                isStreaming: (part["time"] as? [String: Any])?["end"] == nil
            )
        case "tool", "patch", "file", "subtask", "step-start", "step-finish":
            if let work = Self.parseWorkPart(part) { mergeMessage(work, into: sessionID) }
        default:
            break
        }
        publishActivity()
    }

    private func applyNextToolEvent(type: String, properties: [String: Any], sessionID: String) {
        guard let callID = Self.string(properties["callID"]) else { return }
        let tool = Self.string(properties["tool"]) ?? "tool"
        let detail: String
        switch type {
        case "session.next.tool.called": detail = "Started"
        case "session.next.tool.progress": detail = "Working"
        case "session.next.tool.success": detail = "Completed"
        default: detail = "Failed"
        }
        mergeMessage(
            OpenCodeMessage(
                id: "work-call-\(callID)",
                role: .tool,
                text: tool,
                detail: detail,
                isStreaming: type != "session.next.tool.success" && type != "session.next.tool.failed"
            ),
            into: sessionID
        )
    }

    private func upsertSession(_ incoming: OpenCodeSession, select: Bool = false) {
        var session = incoming
        if let index = sessions.firstIndex(where: { $0.id == session.id }) {
            let old = sessions[index]
            if old.state != .idle, session.state == .idle { session.state = old.state }
            sessions[index] = session
        } else {
            sessions.append(session)
        }
        sessions.sort { $0.updatedAt > $1.updatedAt }
        if select || selectedSessionID == nil { selectedSessionID = session.id }
    }

    private func updateSessionState(_ id: String, state: OpenCodeSessionState) {
        guard let index = sessions.firstIndex(where: { $0.id == id }) else { return }
        sessions[index].state = state
    }

    private func updateSessionPreview(_ id: String, from messages: [OpenCodeMessage]) {
        guard let index = sessions.firstIndex(where: { $0.id == id }) else { return }
        if let latest = messages.last(where: { $0.role == .assistant || $0.role == .user }),
           !latest.text.isEmpty {
            sessions[index].preview = latest.text
        }
    }

    private func mergeMessage(_ message: OpenCodeMessage, into sessionID: String) {
        var current = messagesBySession[sessionID] ?? []
        Self.merge(message, into: &current)
        messagesBySession[sessionID] = Array(current.suffix(100))
        if selectedSessionID == sessionID { messages = messagesBySession[sessionID] ?? [] }
    }

    private func removeMessage(_ id: String, from sessionID: String) {
        messagesBySession[sessionID]?.removeAll { $0.id == id }
        if selectedSessionID == sessionID { messages = messagesBySession[sessionID] ?? [] }
    }

    private func ensureAssistantMessage(_ messageID: String, sessionID: String) {
        var current = messagesBySession[sessionID] ?? []
        guard !current.contains(where: { $0.id == messageID }) else { return }
        current.append(OpenCodeMessage(id: messageID, role: .assistant, text: "", isStreaming: true))
        messagesBySession[sessionID] = Array(current.suffix(100))
        if selectedSessionID == sessionID { messages = messagesBySession[sessionID] ?? [] }
    }

    private func appendTextDelta(_ delta: String, messageID: String, sessionID: String) {
        ensureAssistantMessage(messageID, sessionID: sessionID)
        guard var current = messagesBySession[sessionID],
              let index = current.firstIndex(where: { $0.id == messageID }) else { return }
        current[index].text.append(delta)
        current[index].isStreaming = true
        messagesBySession[sessionID] = Array(current.suffix(100))
        if selectedSessionID == sessionID { messages = messagesBySession[sessionID] ?? [] }
    }

    private func replaceAssistantText(_ text: String?, messageID: String, sessionID: String, isStreaming: Bool) {
        ensureAssistantMessage(messageID, sessionID: sessionID)
        guard var current = messagesBySession[sessionID],
              let index = current.firstIndex(where: { $0.id == messageID }) else { return }
        if let text { current[index].text = text }
        current[index].isStreaming = isStreaming
        messagesBySession[sessionID] = Array(current.suffix(100))
        if selectedSessionID == sessionID { messages = messagesBySession[sessionID] ?? [] }
    }

    private func handleTermination(status: Int32, generation: Int) {
        guard !isStopping, generation == processGeneration else { return }
        process = nil
        serverPassword = nil
        outputHandle = nil
        errorHandle = nil
        eventTask?.cancel()
        eventTask = nil
        urlSession?.invalidateAndCancel()
        urlSession = nil
        serverURL = nil
        messageRefreshes.reset()
        connection = status == 0 ? .stopped : .failed
        if status != 0 {
            let diagnostic = serverErrorBuffer
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .components(separatedBy: .newlines)
                .last
            errorMessage = diagnostic?.isEmpty == false
                ? diagnostic
                : "OpenCode server stopped unexpectedly (\(status))."
        }
        publishActivity()
    }

    private func publishActivity() {
        onActivity?(activity)
    }

    // MARK: Process discovery and parsing

    private func defaultWorkingDirectory() -> String {
        let current = FileManager.default.currentDirectoryPath
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: current, isDirectory: &isDirectory), isDirectory.boolValue {
            return current
        }
        return NSHomeDirectory()
    }

    private static func openCodeExecutable() -> String? {
        let environmentPath = ProcessInfo.processInfo.environment["PATH"] ?? ""
        let home = NSHomeDirectory()
        let candidates = environmentPath.split(separator: ":").map(String.init)
            .map { URL(fileURLWithPath: $0).appendingPathComponent("opencode").path }
            + [
                "\(home)/.opencode/bin/opencode",
                "\(home)/.local/bin/opencode",
                "\(home)/.npm-global/bin/opencode",
                "/opt/homebrew/bin/opencode",
                "/usr/local/bin/opencode"
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
        for path in [
            "\(NSHomeDirectory())/.opencode/bin",
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

    private func addAuthorization(to request: inout URLRequest) {
        guard let password = serverPassword,
              let credentials = "\(Self.localServerUsername):\(password)".data(using: .utf8) else { return }
        request.setValue("Basic \(credentials.base64EncodedString())", forHTTPHeaderField: "Authorization")
    }

    private static func merge(_ message: OpenCodeMessage, into messages: inout [OpenCodeMessage]) {
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

    private static func number(_ value: Any?) -> Double? {
        if let value = value as? NSNumber { return value.doubleValue }
        if let value = value as? String { return Double(value) }
        return nil
    }

    private static func date(_ value: Any?, fallback: Date = Date()) -> Date {
        guard let value = number(value) else { return fallback }
        // OpenCode uses milliseconds in its session timestamps.
        let seconds = value > 100_000_000_000 ? value / 1000 : value
        return Date(timeIntervalSince1970: seconds)
    }

    private static func prettyStatus(_ value: String) -> String {
        switch value {
        case "pending": return "Pending"
        case "running": return "Working"
        case "completed": return "Completed"
        case "error": return "Failed"
        default: return value.capitalized
        }
    }

    private static func errorText(_ value: Any?) -> String? {
        guard let object = value as? [String: Any] else { return string(value) }
        return string(object["message"])
            ?? string(object["name"])
            ?? string(object["error"])
            ?? string(object["data"])
    }

    private static func parsePermission(_ properties: [String: Any]) -> OpenCodePermission? {
        guard let id = string(properties["id"]),
              let sessionID = string(properties["sessionID"]) else { return nil }
        let action = string(properties["permission"]) ?? string(properties["action"]) ?? "continue"
        let resources = (properties["patterns"] as? [String])
            ?? (properties["resources"] as? [String])
            ?? []
        return OpenCodePermission(id: id, sessionID: sessionID, action: action, resources: resources)
    }

    private static func requestError(status: Int, error: Error?, fallback: String) -> String {
        if let error, (error as NSError).code != NSURLErrorCancelled { return error.localizedDescription }
        if status > 0 { return "\(fallback) (HTTP \(status))" }
        return fallback
    }

    private enum OpenCodeMonitorError: LocalizedError {
        case serverUnavailable
        case invalidURL

        var errorDescription: String? {
            switch self {
            case .serverUnavailable: return "OpenCode server is not running."
            case .invalidURL: return "OpenCode returned an invalid local server URL."
            }
        }
    }
}
