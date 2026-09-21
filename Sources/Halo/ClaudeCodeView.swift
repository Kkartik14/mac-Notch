import SwiftUI

/// Claude Code's workspace stays inside Halo's fixed expanded surface. The
/// provider-specific view only renders Claude values; bounded scrolling and
/// stream-to-bottom behavior come from HaloScrollView.
struct ClaudeCodeExpandedView: View {
    let activity: ClaudeCodeActivity
    var showWorkActivity = false
    var onSelectSession: (String) -> Void = { _ in }
    var onNewSession: () -> Void = {}
    var onRefresh: () -> Void = {}
    var onSend: (String) -> Void = { _ in }
    var onInterrupt: () -> Void = {}

    @State private var draft = ""

    private let railWidth: CGFloat = 154

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            sessionRail
                .frame(width: railWidth, alignment: .topLeading)

            Rectangle()
                .fill(Color.white.opacity(0.12))
                .frame(width: 1)

            conversation
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var sessionRail: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                sectionLabel("SESSIONS")
                Spacer(minLength: 0)
                Button(action: onNewSession) {
                    Image(systemName: "plus")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(.white.opacity(0.65))
                        .frame(width: 20, height: 20)
                        .background(Color.white.opacity(0.08), in: Circle())
                }
                .buttonStyle(.plain)
                .help("New Claude Code session")
                .accessibilityLabel("New Claude Code session")
            }

            if activity.sessions.isEmpty {
                Text(emptySessionText)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.white.opacity(0.46))
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxHeight: .infinity, alignment: .topLeading)
            } else {
                HaloScrollView(
                    items: activity.sessions,
                    maximumHeight: 130,
                    rowSpacing: 4
                ) { session in
                    sessionRow(session)
                }
            }
        }
    }

    private var conversation: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 8) {
                ClaudeMarkView(size: 18)

                VStack(alignment: .leading, spacing: 2) {
                    Text(activity.selectedSession?.title ?? "Developer activity")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundColor(.white.opacity(0.94))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Text(conversationSubtitle)
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundColor(.white.opacity(0.46))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Spacer(minLength: 4)

                Text(activity.selectedState.compactLabel)
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundColor(activity.selectedState == .failed ? .red : .white.opacity(0.65))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 4)
                    .background(Color.white.opacity(0.08), in: Capsule())

                Button(action: onRefresh) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.white.opacity(0.55))
                        .frame(width: 20, height: 20)
                }
                .buttonStyle(.plain)
                .help("Refresh Claude Code activity")
                .accessibilityLabel("Refresh Claude Code activity")
            }

            if let errorMessage = activity.errorMessage {
                Text(errorMessage)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.orange.opacity(0.9))
                    .lineLimit(2)
            }

            if visibleMessages.isEmpty {
                Text(emptyConversationText)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.white.opacity(0.42))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
                HaloScrollView(
                    items: visibleMessages,
                    maximumHeight: 82,
                    rowSpacing: 6,
                    scrollToBottomOnChange: true,
                    scrollTrigger: activity.conversationScrollToken(showWorkActivity: showWorkActivity)
                ) { message in
                    messageRow(message)
                }
            }

            composer
        }
    }

    private func sessionRow(_ session: ClaudeCodeSession) -> some View {
        let selected = session.id == activity.selectedSessionID
        return Button {
            onSelectSession(session.id)
        } label: {
            HStack(alignment: .top, spacing: 6) {
                Circle()
                    .fill(statusColor(session.state))
                    .frame(width: 6, height: 6)
                    .padding(.top, 4)

                VStack(alignment: .leading, spacing: 2) {
                    Text(session.title)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.white.opacity(selected ? 0.94 : 0.68))
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    Text(session.repositoryName)
                        .font(.system(size: 8, weight: .medium, design: .monospaced))
                        .foregroundColor(.white.opacity(selected ? 0.48 : 0.32))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity, minHeight: 35, alignment: .leading)
            .background(selected ? Color.white.opacity(0.1) : Color.clear, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .buttonStyle(.plain)
        .help(session.preview.isEmpty ? session.title : session.preview)
        .accessibilityLabel(session.title)
    }

    private func messageRow(_ message: ClaudeCodeMessage) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text(roleLabel(message.role))
                .font(.system(size: 8, weight: .bold, design: .monospaced))
                .foregroundColor(roleColor(message.role))
                .frame(width: 28, alignment: .leading)

            VStack(alignment: .leading, spacing: 2) {
                HaloMarkdownText(
                    text: message.text.isEmpty ? "Working…" : message.text,
                    interpretsMarkdown: message.role == .assistant && !message.text.isEmpty,
                    workspaceRoot: activity.selectedSession?.directory
                )
                    .font(.system(
                        size: 10,
                        weight: message.role == .tool ? .medium : .regular,
                        design: message.role == .tool ? .monospaced : .default
                    ))
                    .foregroundColor(.white.opacity(message.role == .tool ? 0.58 : 0.82))
                    .lineLimit(message.role == .tool ? 1 : 4)
                    .truncationMode(.tail)
                    .textSelection(.enabled)

                if showWorkActivity,
                   message.role == .tool,
                   let detail = message.detail,
                   !detail.isEmpty {
                    Text(detail)
                        .font(.system(size: 8, weight: .regular, design: .monospaced))
                        .foregroundColor(.white.opacity(0.38))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .textSelection(.enabled)
                }
            }

            if message.isStreaming {
                Circle()
                    .fill(Color.white.opacity(0.6))
                    .frame(width: 4, height: 4)
                    .padding(.top, 5)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var composer: some View {
        HStack(spacing: 6) {
            Image(systemName: "chevron.right")
                .font(.system(size: 9, weight: .bold))
                .foregroundColor(.white.opacity(0.35))

            TextField(composerPlaceholder, text: $draft)
                .textFieldStyle(.plain)
                .font(.system(size: 10, weight: .regular))
                .foregroundColor(.white.opacity(0.88))
                .lineLimit(1)
                .submitLabel(.send)
                .onSubmit(submit)
                .disabled(activity.selectedSession == nil || activity.selectedState == .running)

            if activity.selectedState == .running {
                Button(action: onInterrupt) {
                    Image(systemName: "stop.fill")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(.white.opacity(0.65))
                        .frame(width: 20, height: 20)
                }
                .buttonStyle(.plain)
                .help("Stop Claude Code")
                .accessibilityLabel("Stop Claude Code")
            }

            Button(action: submit) {
                Image(systemName: "arrow.up")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(.black)
                    .frame(width: 19, height: 19)
                    .background(Color.white.opacity(0.9), in: Circle())
            }
            .buttonStyle(.plain)
            .disabled(!canSubmit)
            .opacity(canSubmit ? 1 : 0.35)
            .help("Send to Claude Code")
            .accessibilityLabel("Send to Claude Code")
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var visibleMessages: [ClaudeCodeMessage] {
        activity.visibleMessages(showWorkActivity: showWorkActivity)
    }

    private var conversationSubtitle: String {
        guard let session = activity.selectedSession else { return activity.connection.title }
        if let model = session.model, !model.isEmpty { return "\(session.repositoryName) · \(model)" }
        return session.repositoryName
    }

    private var emptySessionText: String {
        switch activity.connection {
        case .starting: return "Loading Claude Code…"
        case .unavailable: return "Claude Code CLI not found."
        case .failed: return "Claude Code is unavailable."
        default: return "No Claude Code sessions yet."
        }
    }

    private var emptyConversationText: String {
        if activity.selectedSession == nil {
            return activity.connection == .connected
                ? "Select a session to inspect its activity."
                : "Start Claude Code to load developer activity."
        }
        return "No visible messages in this session yet."
    }

    private var composerPlaceholder: String {
        if activity.selectedSession == nil { return "Create a session with + first…" }
        if activity.selectedState == .running { return "Claude Code is working…" }
        return "Ask Claude Code…"
    }

    private func submit() {
        let value = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, canSubmit else { return }
        draft = ""
        onSend(value)
    }

    private var canSubmit: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && activity.selectedSession != nil
            && activity.selectedState != .running
    }

    private func roleLabel(_ role: ClaudeCodeMessageRole) -> String {
        switch role {
        case .user: return "YOU"
        case .assistant: return "CLD"
        case .tool: return "WORK"
        }
    }

    private func roleColor(_ role: ClaudeCodeMessageRole) -> Color {
        switch role {
        case .user: return .white.opacity(0.7)
        case .assistant: return Color(red: 1.0, green: 0.58, blue: 0.28).opacity(0.9)
        case .tool: return .orange.opacity(0.8)
        }
    }

    private func statusColor(_ state: ClaudeCodeSessionState) -> Color {
        switch state {
        case .running: return .green
        case .waiting: return .orange
        case .failed: return .red
        case .interrupted: return .yellow.opacity(0.8)
        case .idle: return .white.opacity(0.35)
        }
    }

    private func sectionLabel(_ value: String) -> some View {
        Text(value)
            .font(.system(size: 9, weight: .bold))
            .tracking(1.2)
            .foregroundColor(.white.opacity(0.5))
    }
}
