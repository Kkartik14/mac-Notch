import SwiftUI

/// Fixed geometry shared by the expanded surface and its destination bar.
/// Keeping the slot height here prevents individual screens from painting
/// underneath navigation when their content is taller than the card.
enum HaloDestinationBarMetrics {
    static let height: CGFloat = 22
    static let buttonWidth: CGFloat = 22
    static let buttonHeight: CGFloat = 20
    static let glyphSize: CGFloat = 12
    static let minimumScale: CGFloat = 0.75
    static let maximumScale: CGFloat = 1.35
    static let defaultScale: CGFloat = 1.0

    static func normalizedScale(_ value: Double) -> CGFloat {
        min(max(CGFloat(value), minimumScale), maximumScale)
    }

    static func height(for scale: CGFloat) -> CGFloat {
        max(height, buttonHeight(for: scale) + 2)
    }

    static func buttonWidth(for scale: CGFloat) -> CGFloat {
        buttonWidth * scale
    }

    static func buttonHeight(for scale: CGFloat) -> CGFloat {
        buttonHeight * scale
    }

    static func glyphSize(for scale: CGFloat) -> CGFloat {
        glyphSize * scale
    }

    static func spacing(for scale: CGFloat) -> CGFloat {
        max(1, 2 * scale)
    }
}

/// User-facing destinations that can be selected from the expanded Halo
/// surface. Battery remains an ambient status card rather than a destination.
enum HaloDestination: String, CaseIterable, Equatable, Identifiable {
    case nowPlaying
    case calendar
    case codex
    case openCode
    case claudeCode

    var id: String { rawValue }

    var title: String {
        switch self {
        case .nowPlaying: return "Music"
        case .calendar: return "Calendar and Reminders"
        case .codex: return "Codex"
        case .openCode: return "OpenCode"
        case .claudeCode: return "Claude Code"
        }
    }

    var isDeveloperTool: Bool {
        switch self {
        case .codex, .openCode, .claudeCode: return true
        default: return false
        }
    }

    /// The bar follows the user's activity-source settings. Calendar and
    /// Reminders share one destination because they share one expanded card.
    static func available(in settings: HaloSettings) -> [HaloDestination] {
        allCases.filter { $0.isEnabled(in: settings) }
    }

    func isEnabled(in settings: HaloSettings) -> Bool {
        switch self {
        case .nowPlaying: return settings.showNowPlaying && settings.showMusicInAppsBar
        case .calendar: return (settings.showCalendarEvents || settings.showReminders) && settings.showCalendarInAppsBar
        case .codex: return settings.showCodex && settings.showCodexInAppsBar
        case .openCode: return settings.showOpenCode && settings.showOpenCodeInAppsBar
        case .claudeCode: return settings.showClaudeCode && settings.showClaudeCodeInAppsBar
        }
    }
}

/// Compact icon-only navigation for the fixed expanded surface.
struct HaloDestinationBar: View {
    let destinations: [HaloDestination]
    let selectedID: String?
    let activities: [HaloActivity]
    let scale: CGFloat
    let onSelect: (HaloDestination) -> Void

    init(
        destinations: [HaloDestination],
        selectedID: String?,
        activities: [HaloActivity],
        scale: CGFloat = HaloDestinationBarMetrics.defaultScale,
        onSelect: @escaping (HaloDestination) -> Void
    ) {
        self.destinations = destinations
        self.selectedID = selectedID
        self.activities = activities
        self.scale = min(max(scale, HaloDestinationBarMetrics.minimumScale), HaloDestinationBarMetrics.maximumScale)
        self.onSelect = onSelect
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                Spacer(minLength: 0)

                // Keep the complete destination group fixed-size. Equal
                // flexible space on both sides makes centering independent
                // of the selected destination or provider mark.
                HStack(spacing: HaloDestinationBarMetrics.spacing(for: scale)) {
                    destinationButtons(destinations)
                }
                .fixedSize(horizontal: true, vertical: true)

                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity)
        }
        .frame(height: HaloDestinationBarMetrics.height(for: scale))
        .clipped()
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Halo apps")
    }

    @ViewBuilder
    private func destinationButtons(_ values: [HaloDestination]) -> some View {
        ForEach(values) { destination in
            destinationButton(destination)
        }
    }

    private func destinationButton(_ destination: HaloDestination) -> some View {
        let activity = activities.first { $0.id == destination.id }
        let isSelected = selectedID == destination.id

        return Button {
            onSelect(destination)
        } label: {
            ZStack {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(isSelected ? Color.white.opacity(0.14) : Color.clear)
                    .frame(
                        width: HaloDestinationBarMetrics.buttonWidth(for: scale),
                        height: HaloDestinationBarMetrics.buttonHeight(for: scale)
                    )

                HaloDestinationGlyph(
                    destination: destination,
                    activity: activity,
                    size: HaloDestinationBarMetrics.glyphSize(for: scale)
                )
            }
            .frame(
                width: HaloDestinationBarMetrics.buttonWidth(for: scale),
                height: HaloDestinationBarMetrics.buttonHeight(for: scale)
            )
            .fixedSize(horizontal: true, vertical: true)
            .clipped()
            .overlay(alignment: .bottomTrailing) {
                    if isStreaming(activity) {
                    SessionActivityIndicator(isStreaming: true, diameter: max(2, 2.5 * scale))
                        .padding(max(1, 2 * scale))
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .buttonStyle(.plain)
        .help(destination.title)
        .accessibilityLabel(destination.title)
        .accessibilityValue(isSelected ? "Selected" : "")
    }

    private func isStreaming(_ activity: HaloActivity?) -> Bool {
        guard let activity else { return false }
        switch activity {
        case .codex(let value):
            return DeveloperSessionActivity.isStreaming(value.selectedState)
        case .openCode(let value):
            return value.selectedState == .running
        case .claudeCode(let value):
            return DeveloperSessionActivity.isStreaming(value.selectedState)
        default:
            return false
        }
    }
}

private struct HaloDestinationGlyph: View {
    let destination: HaloDestination
    let activity: HaloActivity?
    let size: CGFloat

    var body: some View {
        Group {
            switch destination {
            case .nowPlaying:
                HaloAppleAppIconView(application: .music, size: size)
            case .calendar:
                HaloAppleAppIconView(application: .calendar, size: size)
            case .codex:
                OpenAIMarkView(size: size)
            case .openCode:
                OpenCodeMarkView(size: size)
            case .claudeCode:
                ClaudeMarkView(size: size)
            }
        }
        .foregroundColor(.white.opacity(0.86))
        .font(.system(size: size, weight: .semibold))
        .frame(width: size, height: size)
    }

}
