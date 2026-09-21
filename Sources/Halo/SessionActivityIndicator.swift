import SwiftUI

/// Shared definition of a session actively streaming a response in Halo.
enum DeveloperSessionActivity {
    static func isStreaming(_ state: CodexThreadState) -> Bool {
        state == .running
    }

    static func isStreaming(_ state: ClaudeCodeSessionState) -> Bool {
        state == .running
    }
}

/// Orange-to-white pulse for a streaming session; inactive sessions stay gray.
struct SessionActivityIndicator: View {
    let isStreaming: Bool
    private let diameter: CGFloat

    @State private var phase = false

    init(isStreaming: Bool, diameter: CGFloat = 6) {
        self.isStreaming = isStreaming
        self.diameter = diameter
    }

    var body: some View {
        Circle()
            .fill(fillColor)
            .frame(width: diameter, height: diameter)
            .animation(
                isStreaming ? .easeInOut(duration: 0.65).repeatForever(autoreverses: true) : nil,
                value: phase
            )
            .onAppear { phase = isStreaming }
            .onChange(of: isStreaming) { _, active in phase = active }
            .accessibilityLabel(isStreaming ? "Streaming" : "Not streaming")
    }

    private var fillColor: Color {
        guard isStreaming else { return .white.opacity(0.35) }
        return phase ? .white : .orange
    }
}
