import AppKit
import CoreLocation
import EventKit
import SwiftUI

private enum HaloSettingsSection: String, CaseIterable, Identifiable {
    case general
    case gestures
    case liveActivities
    case music
    case calendar
    case appearance
    case permissions
    case about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return "General"
        case .gestures: return "Gestures"
        case .liveActivities: return "Live Activities"
        case .music: return "Music"
        case .calendar: return "Calendar"
        case .appearance: return "Appearance"
        case .permissions: return "Permissions"
        case .about: return "About"
        }
    }

    var subtitle: String {
        switch self {
        case .general: return "Startup and defaults"
        case .gestures: return "Pointer behavior"
        case .liveActivities: return "What Halo shows"
        case .music: return "Playback surfaces"
        case .calendar: return "Events and reminders"
        case .appearance: return "Motion and presentation"
        case .permissions: return "macOS access"
        case .about: return "The project"
        }
    }

    var symbol: String {
        switch self {
        case .general: return "gearshape.fill"
        case .gestures: return "hand.tap.fill"
        case .liveActivities: return "rectangle.3.group.fill"
        case .music: return "music.note.list"
        case .calendar: return "calendar"
        case .appearance: return "paintpalette.fill"
        case .permissions: return "lock.shield.fill"
        case .about: return "info.circle.fill"
        }
    }
}

private enum HaloPermissionState {
    case granted
    case needsDecision
    case denied
    case managed

    var title: String {
        switch self {
        case .granted: return "Granted"
        case .needsDecision: return "Not requested"
        case .denied: return "Needs attention"
        case .managed: return "Managed by macOS"
        }
    }

    var symbol: String {
        switch self {
        case .granted: return "checkmark.circle.fill"
        case .needsDecision: return "questionmark.circle.fill"
        case .denied: return "exclamationmark.triangle.fill"
        case .managed: return "gearshape.2.fill"
        }
    }

    var color: Color {
        switch self {
        case .granted: return .green
        case .needsDecision: return .orange
        case .denied: return .red
        case .managed: return .secondary
        }
    }
}

struct SettingsRootView: View {
    @ObservedObject private var settings = HaloSettings.shared
    @State private var selectedSection: HaloSettingsSection = .general
    @State private var permissionRefresh = 0

    var body: some View {
        VStack(spacing: 0) {
            Text(selectedSection.title)
                .font(.system(size: 22, weight: .semibold))
                .foregroundColor(.white.opacity(0.92))
                .frame(maxWidth: .infinity)
                .padding(.top, 22)
                .padding(.bottom, 8)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(HaloSettingsSection.allCases) { section in
                        settingsTabButton(section)
                    }
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 12)
            }
            .frame(height: 104)

            Divider()
                .overlay(Color.white.opacity(0.08))

            ScrollView(.vertical, showsIndicators: false) {
                sectionContent
                    .frame(maxWidth: 920, alignment: .topLeading)
                    .padding(.horizontal, 38)
                    .padding(.vertical, 30)
            }
        }
        .frame(minWidth: 900, idealWidth: 980, minHeight: 620, idealHeight: 700)
        .background(Color(nsColor: .windowBackgroundColor))
        .preferredColorScheme(.dark)
        .onAppear {
            permissionRefresh += 1
        }
    }

    @ViewBuilder
    private var sectionContent: some View {
        switch selectedSection {
        case .general: generalContent
        case .gestures: gesturesContent
        case .liveActivities: liveActivitiesContent
        case .music: musicContent
        case .calendar: calendarContent
        case .appearance: appearanceContent
        case .permissions: permissionsContent
        case .about: aboutContent
        }
    }

    private func settingsTabButton(_ section: HaloSettingsSection) -> some View {
        let selected = section == selectedSection
        return Button {
            selectedSection = section
        } label: {
            VStack(spacing: 7) {
                Image(systemName: section.symbol)
                    .font(.system(size: 22, weight: .medium))
                    .foregroundColor(selected ? .accentColor : .white.opacity(0.62))
                Text(section.title)
                    .font(.system(size: 12, weight: selected ? .semibold : .medium))
                    .foregroundColor(selected ? .accentColor : .white.opacity(0.62))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .frame(width: 96, height: 72)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(selected ? Color.white.opacity(0.08) : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(selected ? Color.white.opacity(0.16) : Color.clear, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(section.title)
        .accessibilityHint(section.subtitle)
    }

    private func pageHeader(_ eyebrow: String, title: String, description: String) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(eyebrow.uppercased())
                .font(.system(size: 11, weight: .bold))
                .tracking(1.5)
                .foregroundColor(.accentColor)
            Text(title)
                .font(.system(size: 28, weight: .bold))
                .foregroundColor(.white.opacity(0.94))
            Text(description)
                .font(.system(size: 14, weight: .regular))
                .foregroundColor(.white.opacity(0.58))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func sectionTitle(_ title: String, description: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(.white.opacity(0.9))
            if let description {
                Text(description)
                    .font(.system(size: 12))
                    .foregroundColor(.white.opacity(0.5))
            }
        }
    }

    private func settingsCard<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .padding(20)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color.white.opacity(0.045))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(Color.white.opacity(0.075), lineWidth: 1)
            )
    }

    private func settingToggle(
        _ title: String,
        description: String,
        isOn: Binding<Bool>
    ) -> some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(.white.opacity(0.88))
                Text(description)
                    .font(.system(size: 12))
                    .foregroundColor(.white.opacity(0.48))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 16)
            Toggle("", isOn: isOn)
                .labelsHidden()
                .toggleStyle(.switch)
        }
        .padding(.vertical, 9)
    }

    private func divider() -> some View {
        Rectangle()
            .fill(Color.white.opacity(0.08))
            .frame(height: 1)
    }

    private var generalContent: some View {
        VStack(alignment: .leading, spacing: 24) {
            pageHeader(
                "Halo settings",
                title: "A calm control center for your Mac",
                description: "Choose how Halo starts and keep your preferences across relaunches. Changes take effect immediately."
            )

            settingsCard {
                VStack(alignment: .leading, spacing: 4) {
                    sectionTitle("Startup", description: "Halo remains a background activity surface until you need it.")
                    divider().padding(.vertical, 8)
                    settingToggle(
                        "Launch Halo at login",
                        description: "Start automatically when you sign in to macOS.",
                        isOn: Binding(
                            get: { settings.launchAtLogin },
                            set: { settings.setLaunchAtLogin($0) }
                        )
                    )
                    if let error = settings.launchAtLoginError {
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundColor(.orange)
                            Text(error)
                                .font(.system(size: 11))
                                .foregroundColor(.orange.opacity(0.9))
                            Spacer()
                            Button("Dismiss") { settings.clearLaunchAtLoginError() }
                                .buttonStyle(.borderless)
                        }
                        .padding(.top, 4)
                    }
                }
            }

            settingsCard {
                VStack(alignment: .leading, spacing: 12) {
                    sectionTitle("Reset", description: "Restore Halo's built-in display defaults. macOS permission decisions are never changed here.")
                    HStack {
                        Spacer()
                        Button("Reset preferences") {
                            settings.resetPreferences()
                        }
                        .buttonStyle(.bordered)
                    }
                }
            }
        }
    }

    private var gesturesContent: some View {
        VStack(alignment: .leading, spacing: 24) {
            pageHeader(
                "Interaction",
                title: "Make the halo feel natural",
                description: "These controls only affect how the surface responds to your pointer. Clicking the pill always remains available."
            )

            settingsCard {
                VStack(alignment: .leading, spacing: 4) {
                    sectionTitle("Pointer behavior")
                    divider().padding(.vertical, 8)
                    settingToggle(
                        "Hover to expand",
                        description: "Open the top activity after the pointer rests over the pill.",
                        isOn: $settings.hoverToExpand
                    )
                    settingToggle(
                        "Collapse when the pointer leaves",
                        description: "Settle an expanded card after the pointer moves away.",
                        isOn: $settings.collapseOnMouseLeave
                    )
                }
            }
        }
    }

    private var liveActivitiesContent: some View {
        VStack(alignment: .leading, spacing: 24) {
            pageHeader(
                "Live surface",
                title: "Choose what Halo can surface",
                description: "Turning an activity off hides it and stops its calendar source from being queried. The underlying macOS data remains untouched."
            )

            settingsCard {
                VStack(alignment: .leading, spacing: 4) {
                    sectionTitle("Behavior", description: "Automatic updates can stay quiet or open the card when something changes.")
                    divider().padding(.vertical, 8)
                    settingToggle(
                        "Automatically expand activities",
                        description: "Open the card for new playback, focus, charging, and calendar alerts.",
                        isOn: $settings.automaticallyExpandActivities
                    )
                }
            }

            settingsCard {
                VStack(alignment: .leading, spacing: 4) {
                    sectionTitle("Activity sources")
                    divider().padding(.vertical, 8)
                    settingToggle("Now Playing", description: "Music, Spotify, and system media state.", isOn: $settings.showNowPlaying)
                    settingToggle("Battery", description: "Charging state and current battery level.", isOn: $settings.showBattery)
                    settingToggle("Notifications", description: "New notifications when Full Disk Access allows it.", isOn: $settings.showNotifications)
                    settingToggle("Weather", description: "Current conditions from your approximate location.", isOn: $settings.showWeather)
                    settingToggle("Focus", description: "The active Focus mode when its local state is readable.", isOn: $settings.showFocus)
                    settingToggle("Calendar events", description: "Upcoming events from the calendars you allow.", isOn: $settings.showCalendarEvents)
                    settingToggle("Reminders", description: "Incomplete reminders, with completion from Halo.", isOn: $settings.showReminders)
                    settingToggle("Codex developer activity", description: "Recent Codex chats, live work, approvals, and a local composer.", isOn: $settings.showCodex)
                    settingToggle(
                        "Codex WORK activity",
                        description: "Show Codex WORK actions and their secondary details. Approval prompts remain visible. Off by default.",
                        isOn: $settings.showCodexWorkActivity
                    )
                    settingToggle("OpenCode developer activity", description: "Recent OpenCode sessions, live work, permissions, and a local composer.", isOn: $settings.showOpenCode)
                    settingToggle(
                        "OpenCode WORK activity",
                        description: "Show OpenCode WORK actions and their secondary details. Permission prompts remain visible. Off by default.",
                        isOn: $settings.showOpenCodeWorkActivity
                    )
                }
            }
        }
    }

    private var musicContent: some View {
        VStack(alignment: .leading, spacing: 24) {
            pageHeader(
                "Playback",
                title: "Keep the music card useful",
                description: "Halo reads playback from the active player and keeps the queue and history rails lightweight."
            )

            settingsCard {
                VStack(alignment: .leading, spacing: 4) {
                    sectionTitle("Music card")
                    divider().padding(.vertical, 8)
                    settingToggle("Album artwork", description: "Show artwork in the pill and expanded player.", isOn: $settings.showArtwork)
                    settingToggle("Up Next", description: "Show the upcoming queue when the player provides one.", isOn: $settings.showUpNext)
                    settingToggle("Played Recently", description: "Use playback history when a live queue is unavailable.", isOn: $settings.showRecentlyPlayed)
                }
            }

            settingsCard {
                HStack(alignment: .top, spacing: 14) {
                    Image(systemName: "waveform")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundColor(.accentColor)
                        .frame(width: 28)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Playback stays local")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(.white.opacity(0.88))
                        Text("Halo does not maintain a second music library. It displays the state exposed by macOS and the player you are using.")
                            .font(.system(size: 12))
                            .foregroundColor(.white.opacity(0.52))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    private var calendarContent: some View {
        VStack(alignment: .leading, spacing: 24) {
            pageHeader(
                "Planning",
                title: "Shape your Up Next view",
                description: "Calendar and Reminders are read through EventKit. Halo only writes when you explicitly complete a reminder."
            )

            settingsCard {
                VStack(alignment: .leading, spacing: 4) {
                    sectionTitle("Sources")
                    divider().padding(.vertical, 8)
                    settingToggle("Calendar events", description: "Include events in the Up Next list.", isOn: $settings.showCalendarEvents)
                    settingToggle("Reminders", description: "Include incomplete reminders in the Up Next list.", isOn: $settings.showReminders)
                }
            }

            settingsCard {
                VStack(alignment: .leading, spacing: 4) {
                    sectionTitle("Presentation")
                    divider().padding(.vertical, 8)
                    settingToggle("Show event duration", description: "Display start and end times for timed events.", isOn: $settings.calendarShowDuration)
                    settingToggle("Show locations", description: "Make locations tappable so they open in Apple Maps.", isOn: $settings.calendarShowLocations)
                    settingToggle("Alert when an event starts", description: "Expand the calendar card when a newly observed event begins.", isOn: $settings.calendarStartAlerts)
                }
            }

            settingsCard {
                VStack(alignment: .leading, spacing: 14) {
                    sectionTitle("Lookahead", description: "Limit the amount of future data Halo asks EventKit to inspect.")
                    divider()
                    settingStepper(
                        title: "Days ahead",
                        description: "Search from today through this many days.",
                        value: $settings.calendarLookaheadDays,
                        range: 1...30,
                        suffix: "days"
                    )
                    settingStepper(
                        title: "Maximum items",
                        description: "Keep the list bounded while still allowing it to scroll.",
                        value: $settings.calendarItemLimit,
                        range: 1...50,
                        suffix: "items"
                    )
                }
            }
        }
    }

    private func settingStepper(
        title: String,
        description: String,
        value: Binding<Int>,
        range: ClosedRange<Int>,
        suffix: String
    ) -> some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(.white.opacity(0.88))
                Text(description)
                    .font(.system(size: 12))
                    .foregroundColor(.white.opacity(0.48))
            }
            Spacer(minLength: 16)
            Stepper(value: value, in: range) {
                Text("\(value.wrappedValue) \(suffix)")
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundColor(.white.opacity(0.78))
                    .frame(minWidth: 68, alignment: .trailing)
            }
        }
        .padding(.vertical, 4)
    }

    private var appearanceContent: some View {
        VStack(alignment: .leading, spacing: 24) {
            pageHeader(
                "Presentation",
                title: "Keep the motion comfortable",
                description: "Halo follows the system appearance and is designed for a dark top-surface environment."
            )

            settingsCard {
                VStack(alignment: .leading, spacing: 4) {
                    sectionTitle("Motion")
                    divider().padding(.vertical, 8)
                    settingToggle(
                        "Reduce motion",
                        description: "Use direct transitions and avoid the spring morph when you prefer less movement.",
                        isOn: $settings.reduceMotion
                    )
                }
            }

            settingsCard {
                HStack(alignment: .top, spacing: 14) {
                    Image(systemName: "circle.dashed.inset.filled")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundColor(.accentColor)
                        .frame(width: 28)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Top-surface first")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(.white.opacity(0.88))
                        Text("Halo intentionally has no extra menu-bar icon. Its pill and right-click menu are the primary controls.")
                            .font(.system(size: 12))
                            .foregroundColor(.white.opacity(0.52))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    private var permissionsContent: some View {
        VStack(alignment: .leading, spacing: 24) {
            pageHeader(
                "Privacy",
                title: "Permissions stay in your hands",
                description: "macOS is always the source of truth. Halo remembers that it already asked so a declined or unanswered prompt does not return on every launch."
            )

            settingsCard {
                VStack(alignment: .leading, spacing: 4) {
                    sectionTitle("Calendar and Reminders", description: "EventKit access is separate for each data type.")
                    divider().padding(.vertical, 8)
                    permissionRow(
                        title: "Calendar events",
                        description: "Read upcoming events and open the exact item in Calendar.",
                        state: calendarPermissionState,
                        actionTitle: permissionActionTitle(calendarPermissionState),
                        action: { calendarPermissionAction(for: .event) }
                    )
                    permissionRow(
                        title: "Reminders",
                        description: "Read incomplete reminders and complete them from Halo.",
                        state: reminderPermissionState,
                        actionTitle: permissionActionTitle(reminderPermissionState),
                        action: { calendarPermissionAction(for: .reminder) }
                    )
                }
            }

            settingsCard {
                VStack(alignment: .leading, spacing: 4) {
                    sectionTitle("Local system stores", description: "These readers are silent unless macOS makes the data available.")
                    divider().padding(.vertical, 8)
                    permissionRow(
                        title: "Location Services",
                        description: "Used only for approximate weather coordinates.",
                        state: locationPermissionState,
                        actionTitle: locationPermissionActionTitle,
                        action: locationPermissionAction
                    )
                    permissionRow(
                        title: "Full Disk Access",
                        description: "Enables Focus and notification activity from protected local stores.",
                        state: fullDiskAccessState,
                        actionTitle: "Open System Settings",
                        action: { openPrivacyPane("AllFiles") }
                    )
                    permissionRow(
                        title: "Automation",
                        description: "Player controls are governed by the individual app and macOS.",
                        state: .managed,
                        actionTitle: "Open System Settings",
                        action: { openPrivacyPane("Automation") }
                    )
                }
            }

            HStack {
                Text("Statuses are read again when you press refresh.")
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.42))
                Spacer()
                Button {
                    permissionRefresh += 1
                } label: {
                    Label("Refresh statuses", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
            }
            .id(permissionRefresh)
        }
        .id(permissionRefresh)
    }

    private func permissionRow(
        title: String,
        description: String,
        state: HaloPermissionState,
        actionTitle: String?,
        action: @escaping () -> Void
    ) -> some View {
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: state.symbol)
                .font(.system(size: 19, weight: .semibold))
                .foregroundColor(state.color)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(.white.opacity(0.88))
                Text(description)
                    .font(.system(size: 12))
                    .foregroundColor(.white.opacity(0.48))
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 12)

            VStack(alignment: .trailing, spacing: 7) {
                Text(state.title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(state.color)
                if let actionTitle {
                    Button(actionTitle, action: action)
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
            }
        }
        .padding(.vertical, 10)
    }

    private func permissionActionTitle(_ state: HaloPermissionState) -> String? {
        switch state {
        case .granted, .managed: return "Open System Settings"
        case .needsDecision: return "Request access"
        case .denied: return "Open System Settings"
        }
    }

    private var calendarPermissionState: HaloPermissionState {
        permissionState(for: CalendarMonitor.authorizationStatus(for: .event))
    }

    private var reminderPermissionState: HaloPermissionState {
        permissionState(for: CalendarMonitor.authorizationStatus(for: .reminder))
    }

    private func permissionState(for status: EKAuthorizationStatus) -> HaloPermissionState {
        switch status {
        case .fullAccess, .authorized: return .granted
        case .notDetermined: return .needsDecision
        case .writeOnly: return .denied
        case .denied, .restricted: return .denied
        @unknown default: return .denied
        }
    }

    private var locationPermissionState: HaloPermissionState {
        switch WeatherMonitor.authorizationStatus() {
        case .authorized, .authorizedAlways: return .granted
        case .notDetermined: return .needsDecision
        case .denied, .restricted: return .denied
        @unknown default: return .denied
        }
    }

    private var locationPermissionActionTitle: String? {
        switch locationPermissionState {
        case .needsDecision: return "Request access"
        default: return "Open System Settings"
        }
    }

    private var fullDiskAccessState: HaloPermissionState {
        NotificationMonitor.hasAccess && FocusMonitor.hasAccess ? .granted : .denied
    }

    private func calendarPermissionAction(for type: EKEntityType) {
        let state = permissionState(for: CalendarMonitor.authorizationStatus(for: type))
        if state == .needsDecision {
            if type == .event {
                HaloPermissionActions.shared.requestCalendarEventsAccess?()
            } else {
                HaloPermissionActions.shared.requestRemindersAccess?()
            }
            refreshPermissionsSoon()
        } else {
            openPrivacyPane(type == .event ? "Calendars" : "Reminders")
        }
    }

    private func locationPermissionAction() {
        if locationPermissionState == .needsDecision {
            HaloPermissionActions.shared.requestLocationAccess?()
            refreshPermissionsSoon()
        } else {
            openPrivacyPane("LocationServices")
        }
    }

    private func refreshPermissionsSoon() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            permissionRefresh += 1
        }
    }

    private func openPrivacyPane(_ pane: String) {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_\(pane)") else { return }
        NSWorkspace.shared.open(url)
    }

    private var aboutContent: some View {
        VStack(alignment: .leading, spacing: 24) {
            pageHeader(
                "About Halo",
                title: "A small surface for the things happening now",
                description: "Halo is an open-source macOS activity surface: music, battery, weather, focus, notifications, calendar, and reminders in one calm place."
            )

            settingsCard {
                HStack(spacing: 16) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(Color.white.opacity(0.08))
                            .frame(width: 58, height: 58)
                        Image(systemName: "circle.dashed.inset.filled")
                            .font(.system(size: 27, weight: .semibold))
                            .foregroundColor(.accentColor)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Halo")
                            .font(.system(size: 20, weight: .bold))
                            .foregroundColor(.white.opacity(0.92))
                        Text(versionText)
                            .font(.system(size: 12, weight: .medium, design: .monospaced))
                            .foregroundColor(.white.opacity(0.48))
                    }
                    Spacer()
                }
            }

            settingsCard {
                VStack(alignment: .leading, spacing: 12) {
                    sectionTitle("Design principles")
                    aboutBullet("Local-first", "Use the data already on your Mac and keep the UI quiet when there is nothing to say.")
                    aboutBullet("Reversible", "Settings hide or reshape the surface without deleting your Calendar, Reminder, or playback data.")
                    aboutBullet("macOS-native", "Privacy decisions, apps, and system services remain under macOS control.")
                }
            }
        }
    }

    private func aboutBullet(_ title: String, _ description: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "checkmark")
                .font(.system(size: 11, weight: .bold))
                .foregroundColor(.accentColor)
                .frame(width: 18, height: 18)
                .background(Circle().fill(Color.accentColor.opacity(0.14)))
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.white.opacity(0.84))
                Text(description)
                    .font(.system(size: 12))
                    .foregroundColor(.white.opacity(0.5))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var versionText: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        return "Version \(version ?? "Development build")"
    }
}
