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
6. startMonitors connects callbacks and starts every monitor.

The app intentionally has no NSStatusItem. The halo itself is the visible app surface.

## Activity state

HaloActivity has six cases:

- nowPlaying
- charging
- notification
- focus
- weather
- calendar

Each case has a stable identifier, so a source refresh replaces its existing activity instead of adding a duplicate. HaloCenter.activities stores up to four activities. The array is ordered from lowest to highest priority; the last element is the activity shown in the collapsed pill.

The current ranks are:

| Rank | Activity | Reason |
| ---: | --- | --- |
| 4 | Notification | Transient event that should be visible immediately. |
| 3 | Now Playing | Primary live activity. |
| 2 | Focus | Ambient system state. |
| 2 | Calendar | Upcoming time-sensitive events and reminders. |
| 1 | Charging | Ambient power state, with a temporary plug-in override. |
| 0 | Weather | Quiet ambient information. |

Only one activity can be expanded at a time through expandedId. present can update, expand, schedule auto-dismiss, and schedule a later collapse. collapse keeps the activity alive; dismiss removes it.

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

The window is interactive only over the visible shape. Transparent regions pass mouse input through.

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

[CalendarMonitor](../Sources/Halo/CalendarMonitor.swift) owns one `EKEventStore` and keeps Calendar events and incomplete Reminders separate from the rest of the UI as value types. It requests Calendar and Reminders access independently, so granting one does not require the other. Events are fetched from the beginning of today through the next seven days; reminders with due dates are fetched asynchronously and merged into one sorted list capped at five items, so overdue incomplete reminders remain visible until completion. An `EKEventStoreChanged` observer and a one-minute timer cover edits and ordinary clock changes. The monitor also schedules a one-shot timer for the next future timed event, then compares the previous and current value snapshots to emit exactly one start transition. This avoids a high-frequency poller and avoids alerting for an event first seen after the app launches while it is already in progress.

The expanded Calendar card shows the first four items. Relative time is rendered through a SwiftUI `TimelineView`, so the countdown changes without rewriting the EventKit activity. A start transition expands the card once for four seconds and then leaves the live calendar pill in place; it does not create an event or schedule a duplicate system notification. Reminder rows expose a completion button; `completeReminder` resolves the EventKit identifier, saves `isCompleted = true`, and refreshes the activity. Missing permissions, malformed items, and reminders without due dates are ignored quietly.

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
