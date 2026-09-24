import SwiftUI

/// OpenCode's activity workspace stays inside Halo's existing fixed expanded
/// surface. Its UI is intentionally provider-specific while the scroll
/// mechanics remain shared with Calendar, Codex, and other bounded rails.
struct OpenCodeExpandedView: View {
    let activity: OpenCodeActivity
    var showWorkActivity = false
    var onSelectSession: (String) -> Void = { _ in }
    var onNewSession: () -> Void = {}
    var onRefresh: () -> Void = {}
    var onSend: (String) -> Void = { _ in }
    var onInterrupt: () -> Void = {}
    var onResolvePermission: (OpenCodePermissionDecision) -> Void = { _ in }

    @State private var draft = ""
    @Environment(\.haloExpandedLayout) private var layout

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            sessionRail(maximumHeight: layout.railViewportHeight)
                .frame(width: layout.railWidth, alignment: .topLeading)

            Rectangle()
                .fill(Color.white.opacity(0.12))
                .frame(width: 1)

            conversation
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func sessionRail(maximumHeight: CGFloat) -> some View {
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
                .help("New OpenCode session")
                .accessibilityLabel("New OpenCode session")
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
                    maximumHeight: maximumHeight,
                    rowSpacing: 4
                ) { session in
                    sessionRow(session)
                }
            }
        }
        .frame(maxHeight: .infinity, alignment: .topLeading)
    }

    private var conversation: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 8) {
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

                Text(activity.pendingPermission == nil
                     ? activity.selectedState.compactLabel
                     : "ASK")
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
                .help("Refresh OpenCode activity")
                .accessibilityLabel("Refresh OpenCode activity")
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
                    maximumHeight: layout.messageViewportHeight(reservedHeight: conversationReservedHeight),
                    rowSpacing: 6,
                    scrollToBottomOnChange: true,
                    scrollTrigger: activity.conversationScrollToken(showWorkActivity: showWorkActivity)
                ) { message in
                    messageRow(message)
                }
            }

            if let permission = activity.pendingPermission {
                permissionBar(permission)
            }

            composer
        }
        .frame(maxHeight: .infinity, alignment: .topLeading)
    }

    private var conversationReservedHeight: CGFloat {
        (activity.errorMessage == nil ? 0 : 22)
            + (activity.pendingPermission == nil ? 0 : 34)
    }

    private func sessionRow(_ session: OpenCodeSession) -> some View {
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

    private func messageRow(_ message: OpenCodeMessage) -> some View {
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
                    .font(.system(size: 10, weight: message.role == .tool ? .medium : .regular, design: message.role == .tool ? .monospaced : .default))
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

    private func permissionBar(_ permission: OpenCodePermission) -> some View {
        HStack(alignment: .center, spacing: 6) {
            Image(systemName: "lock.open")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.orange)

            VStack(alignment: .leading, spacing: 1) {
                Text(permission.title)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(.white.opacity(0.78))
                    .lineLimit(1)

                if showWorkActivity, !permission.detail.isEmpty {
                    Text(permission.detail)
                        .font(.system(size: 8, weight: .regular))
                        .foregroundColor(.white.opacity(0.42))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }

            Spacer(minLength: 0)

            Button("Allow") { onResolvePermission(.once) }
                .font(.system(size: 9, weight: .semibold))
                .buttonStyle(.borderedProminent)
                .controlSize(.mini)
                .help(permission.detail)

            Button("No") { onResolvePermission(.reject) }
                .font(.system(size: 9, weight: .semibold))
                .buttonStyle(.bordered)
                .controlSize(.mini)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .help(permission.detail)
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
                .disabled(
                    activity.selectedSession == nil
                        || activity.selectedState == .running
                        || activity.selectedState == .waiting
                )

            if activity.selectedState == .running {
                Button(action: onInterrupt) {
                    Image(systemName: "stop.fill")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(.white.opacity(0.65))
                        .frame(width: 20, height: 20)
                }
                .buttonStyle(.plain)
                .help("Stop OpenCode")
                .accessibilityLabel("Stop OpenCode")
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
            .help("Send to OpenCode")
            .accessibilityLabel("Send to OpenCode")
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var conversationSubtitle: String {
        guard let session = activity.selectedSession else { return activity.connection.title }
        if let model = session.model, !model.isEmpty { return "\(session.repositoryName) · \(model)" }
        if let agent = session.agent, !agent.isEmpty { return "\(session.repositoryName) · \(agent)" }
        return session.repositoryName
    }

    private var visibleMessages: [OpenCodeMessage] {
        activity.visibleMessages(showWorkActivity: showWorkActivity)
    }

    private var emptySessionText: String {
        switch activity.connection {
        case .starting: return "Connecting to OpenCode…"
        case .unavailable: return "OpenCode CLI not found."
        case .failed: return "OpenCode is unavailable."
        default: return "No OpenCode sessions yet."
        }
    }

    private var emptyConversationText: String {
        if activity.selectedSession == nil {
            return activity.connection == .connected ? "Select a session to inspect its activity." : "Start OpenCode to load developer activity."
        }
        return "No visible messages in this session yet."
    }

    private var composerPlaceholder: String {
        if activity.selectedSession == nil { return "Create a session with + first…" }
        if activity.selectedState == .running { return "OpenCode is working…" }
        if activity.selectedState == .waiting { return "Resolve the permission above…" }
        return "Ask OpenCode…"
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
            && activity.selectedState != .waiting
    }

    private func roleLabel(_ role: OpenCodeMessageRole) -> String {
        switch role {
        case .user: return "YOU"
        case .assistant: return "OPEN"
        case .tool: return "WORK"
        }
    }

    private func roleColor(_ role: OpenCodeMessageRole) -> Color {
        switch role {
        case .user: return .white.opacity(0.7)
        case .assistant: return .green.opacity(0.8)
        case .tool: return .orange.opacity(0.8)
        }
    }

    private func statusColor(_ state: OpenCodeSessionState) -> Color {
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
