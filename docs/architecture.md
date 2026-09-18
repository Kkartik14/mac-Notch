# Architecture

## Overview

Halo is organized as a set of source-specific monitors feeding one in-memory activity coordinator:

~~~text
macOS / Music / Spotify / Calendar / Reminders / network
             ↓
        source monitors
             ↓ callbacks
         AppDelegate
             ↓
        HaloCenter
             ↓ @Published state
       HaloWindowController
             ↓
          HaloView
~~~

The main application is defined in [Sources/Halo/App.swift](../Sources/Halo/App.swift). The visual and state layer is concentrated in [Sources/Halo/Halo.swift](../Sources/Halo/Halo.swift).

## Application startup

1. HaloApp exposes a SwiftUI Settings scene.
2. AppDelegate.applicationDidFinishLaunching sets the app to accessory mode.
3. HaloWindowController.install creates a borderless, non-activating NSPanel.
4. The panel is placed on the main screen and kept at a fixed 660×210 size.
5. A right-click menu is attached to the host view.
6. AppDelegate applies persisted display settings and installs the explicit permission actions used by Settings.
7. startMonitors connects callbacks and starts every monitor.

The app intentionally has no NSStatusItem. The halo itself is the visible app surface.

## Settings and permission state

[HaloSettings](../Sources/Halo/HaloSettings.swift) owns typed display preferences. Each value is stored under a namespaced `UserDefaults` key and published to the app. AppDelegate observes the settings object, reconfigures CalendarMonitor's source filters/lookahead/item cap, and dismisses activities that the user hides. Views observe the same singleton, so artwork, music rails, calendar duration/location details, motion, and hover behavior update without relaunching.

Launch-at-login is registered through `SMAppService`; its status is read from macOS each time rather than trusted from a cached boolean. TCC permission grants are never copied into Halo preferences. CalendarMonitor and WeatherMonitor use [`HaloPermissionRequestLedger`](../Sources/Halo/HaloSettings.swift) only to remember that an automatic request was already attempted, while EventKit/Core Location status remains authoritative. Settings can make an explicit request while a capability is undecided or open the matching System Settings privacy pane after a denial.

## Activity state

HaloActivity has eight cases:

- nowPlaying
- charging
- notification
- focus
- weather
- calendar
- codex
- openCode

Each case has a stable identifier, so a source refresh replaces its existing activity instead of adding a duplicate. HaloCenter.activities stores up to four activities. The array is ordered from lowest to highest priority; the last element is the activity shown in the collapsed pill.

The current ranks are:

| Rank | Activity | Reason |
| ---: | --- | --- |
| 4 | Notification | Transient event that should be visible immediately. |
| 3 | Now Playing | Primary live activity. |
| 3 | Codex | Developer work is useful live context, but should not eclipse a transient notification. |
| 3 | OpenCode | Developer work is useful live context, but should not eclipse a transient notification. |
| 2 | Focus | Ambient system state. |
| 2 | Calendar | Upcoming time-sensitive events and reminders. |
| 1 | Charging | Ambient power state, with a temporary plug-in override. |
| 0 | Weather | Quiet ambient information. |

Only one activity can be expanded at a time through expandedId. Presentation
decisions go through [HaloPresentationPolicy](../Sources/Halo/HaloPresentation.swift):
`.update` refreshes an activity without taking ownership of the expanded
surface, `.expand(.user)` represents an explicit user action, `.expand(.hover)`
is allowed only when the surface is already collapsed, and
`.expand(.automatic)` may open an idle surface or refresh the activity that is
already being viewed. `present` also schedules auto-dismiss and settle timers;
generation tokens make an older delayed callback harmless after a newer update.
`collapse` keeps the activity alive; `dismiss` removes it. Priority restoration
never changes the expanded identifier just because the array was reordered.

HaloCenter also owns:

- Playback progress interpolation at 1 Hz while a track is playing.
- Cached recent tracks so a new Now Playing value does not lose the recent rail.
- Silent updates for progress, artwork, queues, and recent tracks.
- Temporary Charging promotion and restoration of priority order.

## Window and interaction model

The window controller uses a fixed transparent glass panel. SwiftUI changes only the content width, height, shape radii, and content transitions. This prevents the window itself from sliding during a pill-to-card morph.

The visible shape is top-center anchored. haloOrigin keeps the horizontal center constant and pins the top edge to the screen. A screen-parameter notification repositions the panel when displays or fullscreen geometry change.

Input routing has two layers:

1. A global mouse-moved monitor quickly checks whether the cursor is over the visible pill/card and toggles ignoresMouseEvents.
2. A 10 Hz poll backstop performs the same hit test and drives hover-open/hover-close behavior.

Hover-open requires the pointer to have moved more than four points onto the
visible shape, then dwell there for 300 ms. Pointer exit schedules a 300 ms
collapse when the setting is enabled. The window is interactive only over the
visible shape; transparent regions pass mouse input through.

## Monitor responsibilities

### Music

[MusicAppMonitor](../Sources/Halo/MusicAppMonitor.swift) reads Music through AppleScript because direct MediaRemote reads are unreliable for Apple Music on recent macOS versions. It uses an adaptive one-shot poll: one second while playing, three seconds while paused, and a fifteen-second backstop while Music is not running. After play/pause/next/previous/seek actions, Music launch/activation/termination, and system wake, it schedules short follow-up probes. AppleScript returns a delimiter-separated snapshot containing title, artist, album, player state, position, and duration. A song change fetches artwork and triggers a visible update; playback-state changes and same-song polls update progress silently. The current-track script is compiled once and reused.

The queue reader performs bounded neighbor reads rather than enumerating an entire library. It verifies that the reported index resolves to the current track before trusting a playlist context. Playlist rows are emitted immediately, then their embedded artwork is read lazily by playlist ID and track index and applied to the existing queue without rebuilding the Now Playing card.

### Spotify

[SpotifyMonitor](../Sources/Halo/SpotifyMonitor.swift) follows the same polling pattern. Spotify reports duration in milliseconds and position in seconds, so duration is normalized before it reaches the UI. Artwork is downloaded asynchronously and applied only if the track signature is still current.

### Generic MediaRemote

[NowPlayingMonitor](../Sources/Halo/NowPlayingMonitor.swift) loads the private MediaRemote framework with dlopen/dlsym. Missing symbols are treated as a no-op. It reads title, artist, album, playback rate, progress, client identifier, and artwork. MediaRemote is the generic fallback; Music and Spotify have dedicated scripting adapters because direct reads can return no data for those apps.

### Transport routing

AppDelegate sends play/pause, next, and previous to the player currently playing. If neither dedicated player is active, the monitor falls back to MediaRemote. Seeking follows the app shown by the card; dedicated Music and Spotify seeking is supported.

### Playback history and queue precedence

[PlaybackHistoryMonitor](../Sources/Halo/PlaybackHistoryMonitor.swift) watches Music's PlaybackSessions directory and polls it every ten seconds as a backstop. It parses:

- contentItem.protobuf.gz for title and artist.
- itemPayload.opackCoder.gz for store ID, catalog URL, and artwork template.
- containerPayload.opackCoder.gz for ordered queue store IDs.

The queue resolver looks at the newest few sessions, walks back when the newest archive is incomplete, and uses the iTunes Lookup API to turn the next three store IDs into displayable queue items. Artwork is downloaded progressively.

AppDelegate applies queue results in this order:

1. A session archive queue wins when its context title matches the track on screen.
2. Music scripting queue data is used when no valid session queue has won.
3. Stale or mismatched results are discarded rather than replacing a known-good queue.

If no queue is available, the UI uses the recent-track list. Queue rows with playlist ID/index are playable directly in Music. Catalog rows open a Music deep link.

### Battery

[BatteryMonitor](../Sources/Halo/BatteryMonitor.swift) reads the first valid IOKit power source. It refreshes every 30 seconds and responds to NSProcessInfoPowerStateDidChange. Callbacks are emitted only when the charge level changes by more than 0.5 percentage points or the plug state changes.

### Weather

[WeatherMonitor](../Sources/Halo/WeatherMonitor.swift) requests location access, obtains a location, and calls Open-Meteo for current conditions plus today's high/low. Requests are throttled to five minutes and the monitor refreshes every ten minutes. Cupertino coordinates are used as a fallback when no location is available.

### Focus

[FocusMonitor](../Sources/Halo/FocusMonitor.swift) reads Assertions.json and ModeConfigurations.json under ~/Library/DoNotDisturb/DB. It matches live assertion UUIDs to invalidation records, then resolves the mode name and icon. It uses both a directory watcher and a ten-second poll. If the files cannot be read, it remains silent.

### Notifications

[NotificationMonitor](../Sources/Halo/NotificationMonitor.swift) opens the usernoted SQLite database read-only. It records the maximum notification ID at startup, then emits only newer rows. Payloads are property lists containing app identifier, title, subtitle, body, and date. A directory watcher and four-second poll cover both normal and atomic database updates.

### Calendar and Reminders

[CalendarMonitor](../Sources/Halo/CalendarMonitor.swift) owns one `EKEventStore` and keeps Calendar events and incomplete Reminders separate from the rest of the UI as value types. It requests Calendar and Reminders access independently, so granting one does not require the other. Events are fetched from the beginning of today through the configured lookahead (seven days by default); reminders with due dates are fetched asynchronously and merged into one sorted list capped at the configured item limit (25 by default), so overdue incomplete reminders remain visible until completion. An `EKEventStoreChanged` observer, a one-minute timer, and system wake/clock/locale observers cover edits, sleep/wake, and ordinary clock changes. The monitor also schedules a one-shot timer for the next future timed event, then compares the previous and current value snapshots to emit exactly one start transition. This avoids a high-frequency poller and avoids alerting for an event first seen after the app launches while it is already in progress.

The expanded Calendar card gives the next item a fixed detail column and places the remaining returned items in a bounded, vertically scrollable Up Next column. All vertical rails use the shared [`HaloScrollView`](../Sources/Halo/HaloScrollView.swift), which owns the `ScrollView`, lazy stack, spacing, viewport limit, and indicator policy; [`HaloScrollMetrics`](../Sources/Halo/HaloScrollView.swift) keeps fixed-row sizing and scroll-threshold calculations pure and testable. Clicking an event or reminder title/time builds the owning app's native item URL (`ical://ekevent/...` or `x-apple-reminderkit://REMCDReminder/...`) and falls back to opening the app if macOS rejects the deep link. Event rows show start/end ranges, location controls open `maps://` searches in Apple Maps, and HTTP(S) EventKit URLs appear as optional meeting-link actions. The completion button remains a separate reminder-only action. Relative time is rendered through a SwiftUI `TimelineView`, so the countdown changes without rewriting the EventKit activity. A start transition expands the card once for four seconds and then leaves the live calendar pill in place; it does not create an event or schedule a duplicate system notification. Reminder rows expose a completion button; `completeReminder` resolves the EventKit identifier, saves `isCompleted = true`, and refreshes the activity. Missing permissions, malformed items, and reminders without due dates are ignored quietly.

### Codex developer activity

[CodexMonitor](../Sources/Halo/CodexMonitor.swift) launches the installed Codex CLI as `codex app-server --stdio` and speaks newline-delimited JSON-RPC. It performs the protocol handshake, lists recent threads, selects the newest-created thread when no chat has been selected, loads up to 100 visible items for the selected thread, and maps app-server lifecycle notifications into Halo value types. `updatedAt` is used only as a tie-breaker for that initial choice. User messages are sent with `turn/start`; stored threads are resumed first, including paginated records whose list response omits direct-input capability, and an explicit New chat action uses `thread/start` in the selected workspace. The resume response is the capability check before a pending message is sent. If the selected thread is already owned by another active Codex session, an active-writer error triggers the experimental `thread/queue/add` handoff instead of being mistaken for a successful resume. Halo keeps the optimistic user message visible, marks the thread `QUE`, and performs a short one-second history refresh for up to two minutes so the separate session's persisted response can appear. If the queue handoff fails, or the server explicitly returns a non-writable capability, `CodexMonitor` keeps that chat read-only/failed and does not silently switch conversations.

The monitor intentionally keeps the protocol boundary separate from SwiftUI. [CodexView.swift](../Sources/Halo/CodexView.swift) renders the same `CodexActivity` in both the compact pill and the fixed expanded card, with a scrollable chat rail, a scrollable visible activity rail, a composer, a stop action, and inline command/file approval controls. Reasoning items are omitted from the UI. User and assistant messages remain visible by default; actionable WORK items are filtered by the Codex WORK activity preference and keep primary text separate from secondary status/context when enabled. Approval prompts remain visible while a turn is waiting so the user can unblock it.

The app-server process inherits the user's Codex environment and configuration. Halo never handles Codex credentials or maintains a second rollout database. If the CLI is missing, the activity reports a recoverable unavailable state. If the server sends an interactive request Halo does not implement, the client returns an explicit JSON-RPC error rather than leaving the turn pending forever.

### OpenCode developer activity

[OpenCodeMonitor](../Sources/Halo/OpenCodeMonitor.swift) launches the installed OpenCode CLI as `opencode serve --hostname 127.0.0.1 --port 0`, sets an ephemeral `OPENCODE_SERVER_PASSWORD` on that child, and uses OpenCode's documented default username `opencode` for its requests. It reads the listening URL from the server output. Port zero lets the operating system choose a free loopback port, so Halo does not collide with an OpenCode server the user already started. The monitor subscribes to `/api/event`, lists the newest 50 sessions from the v2 API, loads up to 100 messages for the selected session, and reads `/api/session/active` so a session that was already active before Halo started can still display as working.

The monitor maps session execution, session-created/updated/deleted, status, idle, message, text-delta, tool, error, and permission events into [OpenCodeActivity](../Sources/Halo/OpenCodeMonitor.swift). Text deltas update the selected conversation immediately; an execution-complete or idle event clears the optimistic prompt and performs one history refresh. User messages go to `POST /api/session/:id/prompt`, interrupt uses `POST /api/session/:id/interrupt`, and permission choices use `POST /api/session/:id/permission/:requestID/reply`. Halo keeps OpenCode's provider credentials, model selection, tool execution, and persisted history outside the app. Question-style interactive requests are currently outside the supported UI surface.

[OpenCodeView.swift](../Sources/Halo/OpenCodeView.swift) renders the session rail, conversation, composer, optional WORK summaries, stop action, and inline permission bar in the same fixed expanded geometry as Codex. It uses the shared [HaloScrollView](../Sources/Halo/HaloScrollView.swift), including the opt-in follow-the-latest-message behavior for streamed assistant output.

## Threading assumptions

UI state and AppleScript operations are expected on the main thread. Network completion handlers parse off-thread where useful and dispatch state changes back to the main queue. Timers, filesystem sources, and monitor callbacks are invalidated in deinit/stop methods.

## Adding a new activity

An activity normally requires changes in these places:

1. Add a model and enum case in Halo.swift.
2. Add a rank and stable ID.
3. Add collapsed leading/trailing content and an expanded view.
4. Add monitor ownership and callbacks in AppDelegate.
5. Add dismiss/collapse semantics appropriate to the source.
6. Add pure parsing/state tests before adding live integration behavior.
