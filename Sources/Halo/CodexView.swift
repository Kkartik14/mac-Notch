import SwiftUI

/// The Codex activity stays inside Halo's existing expanded geometry. It is
/// intentionally a two-column workspace: the left rail gives context across
/// chats, while the right side keeps the selected conversation and composer
/// close to the top surface.
struct CodexExpandedView: View {
    let activity: CodexActivity
    var showWorkActivity = false
    var onSelectChat: (String) -> Void = { _ in }
    var onNewChat: () -> Void = {}
    var onRefresh: () -> Void = {}
    var onSend: (String) -> Void = { _ in }
    var onInterrupt: () -> Void = {}
    var onResolveApproval: (CodexApprovalDecision) -> Void = { _ in }

    @State private var draft = ""

    private let railWidth: CGFloat = 154

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            chatRail
                .frame(width: railWidth, alignment: .topLeading)

            Rectangle()
                .fill(Color.white.opacity(0.12))
                .frame(width: 1)

            conversation
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var chatRail: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                sectionLabel("CHATS")
                Spacer(minLength: 0)
                Button(action: onNewChat) {
                    Image(systemName: "plus")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(.white.opacity(0.65))
                        .frame(width: 20, height: 20)
                        .background(Color.white.opacity(0.08), in: Circle())
                }
                .buttonStyle(.plain)
                .help("New Codex chat")
                .accessibilityLabel("New Codex chat")
            }

            if activity.chats.isEmpty {
                Text(emptyChatText)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.white.opacity(0.46))
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxHeight: .infinity, alignment: .topLeading)
            } else {
                HaloScrollView(
                    items: activity.chats,
                    maximumHeight: 130,
                    rowSpacing: 4
                ) { chat in
                    chatRow(chat)
                }
            }
        }
    }

    private var conversation: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(activity.selectedChat?.title ?? "Developer activity")
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

                Text(activity.pendingApproval == nil
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
                .help("Refresh Codex activity")
                .accessibilityLabel("Refresh Codex activity")
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
                    rowSpacing: 6
                ) { message in
                    messageRow(message)
                }
            }

            if let approval = activity.pendingApproval {
                approvalBar(approval)
            }

            composer
        }
    }

    private func chatRow(_ chat: CodexChat) -> some View {
        let selected = chat.id == activity.selectedChatID
        return Button {
            onSelectChat(chat.id)
        } label: {
            HStack(alignment: .top, spacing: 6) {
                Circle()
                    .fill(statusColor(chat.state))
                    .frame(width: 6, height: 6)
                    .padding(.top, 4)

                VStack(alignment: .leading, spacing: 2) {
                    Text(chat.title)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.white.opacity(selected ? 0.94 : 0.68))
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    Text(chat.branch.map { "\(chat.repositoryName) · \($0)" } ?? chat.repositoryName)
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
        .help(chat.preview.isEmpty ? chat.title : chat.preview)
        .accessibilityLabel(chat.title)
    }

    private func messageRow(_ message: CodexMessage) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text(roleLabel(message.role))
                .font(.system(size: 8, weight: .bold, design: .monospaced))
                .foregroundColor(roleColor(message.role))
                .frame(width: 28, alignment: .leading)

            VStack(alignment: .leading, spacing: 2) {
                Text(message.text.isEmpty ? "Working…" : message.text)
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

    private func approvalBar(_ approval: CodexApproval) -> some View {
        HStack(alignment: .center, spacing: 6) {
            Image(systemName: approval.kind == .command ? "terminal" : "doc.badge.gearshape")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.orange)

            VStack(alignment: .leading, spacing: 1) {
                Text(approval.title)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(.white.opacity(0.78))
                    .lineLimit(1)

                if showWorkActivity {
                    Text(approval.detail)
                        .font(.system(size: 8, weight: .regular))
                        .foregroundColor(.white.opacity(0.42))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }

            Spacer(minLength: 0)

            Button("Allow") { onResolveApproval(.accept) }
                .font(.system(size: 9, weight: .semibold))
                .buttonStyle(.borderedProminent)
                .controlSize(.mini)
                .help(approval.detail)

            Button("No") { onResolveApproval(.decline) }
                .font(.system(size: 9, weight: .semibold))
                .buttonStyle(.bordered)
                .controlSize(.mini)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .help(approval.detail)
    }

    private var composer: some View {
        HStack(spacing: 6) {
            Image(systemName: "chevron.right")
                .font(.system(size: 9, weight: .bold))
                .foregroundColor(.white.opacity(0.35))

            // This is deliberately a single-line field. The expanded surface
            // is fixed-size, and Return should submit instead of inserting a
            // newline that makes the tiny composer appear unresponsive.
            TextField(activity.selectedChat?.canSendDirectInput == false
                      ? "This chat cannot accept input — click + for a new chat"
                      : "Ask Codex…", text: $draft)
                .textFieldStyle(.plain)
                .font(.system(size: 10, weight: .regular))
                .foregroundColor(.white.opacity(0.88))
                .lineLimit(1)
                .submitLabel(.send)
                .onSubmit(submit)
                .disabled(activity.selectedChat?.canSendDirectInput == false)

            if activity.selectedState == .running {
                Button(action: onInterrupt) {
                    Image(systemName: "stop.fill")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(.white.opacity(0.65))
                        .frame(width: 20, height: 20)
                }
                .buttonStyle(.plain)
                .help("Stop Codex")
                .accessibilityLabel("Stop Codex")
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
            .help("Send to Codex")
            .accessibilityLabel("Send to Codex")
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var conversationSubtitle: String {
        guard let chat = activity.selectedChat else { return activity.connection.title }
        if let branch = chat.branch { return "\(chat.repositoryName) · \(branch)" }
        return chat.repositoryName
    }

    private var visibleMessages: [CodexMessage] {
        activity.visibleMessages(showWorkActivity: showWorkActivity)
    }

    private var emptyChatText: String {
        switch activity.connection {
        case .starting: return "Connecting to Codex…"
        case .unavailable: return "Codex CLI not found."
        case .failed: return "Codex is unavailable."
        default: return "No Codex chats yet."
        }
    }

    private var emptyConversationText: String {
        if activity.selectedChat == nil {
            return activity.connection == .connected ? "Select a chat to inspect its activity." : "Start Codex to load developer activity."
        }
        return "No visible messages in this chat yet."
    }

    private func submit() {
        let value = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, activity.selectedChat?.canSendDirectInput == true else { return }
        draft = ""
        onSend(value)
    }

    private var canSubmit: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && activity.selectedChat?.canSendDirectInput == true
    }

    private func roleLabel(_ role: CodexMessageRole) -> String {
        switch role {
        case .user: return "YOU"
        case .assistant: return "CODEX"
        case .tool: return "WORK"
        }
    }

    private func roleColor(_ role: CodexMessageRole) -> Color {
        switch role {
        case .user: return .white.opacity(0.7)
        case .assistant: return .green.opacity(0.8)
        case .tool: return .orange.opacity(0.8)
        }
    }

    private func statusColor(_ state: CodexThreadState) -> Color {
        switch state {
        case .running: return .green
        case .waiting: return .orange
        case .failed: return .red
        case .completed: return .white.opacity(0.7)
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
