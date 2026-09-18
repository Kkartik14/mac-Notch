# Halo

Halo is a native macOS 14 app that provides a compact live activity surface at the top of the screen. It is a small, accessory-style Swift application: the Halo surface is the main UI, and there is intentionally no Dock or menu-bar status item.

The current implementation is a development snapshot. It reads local macOS and media-app state, renders live activity cards, and provides playback controls, but it is not yet a signed, notarized, or production-distribution build.

## Download

Published app builds should be attached to the repository's GitHub Releases rather than committed to the source tree. Until a Developer ID-signed release is available, label downloads clearly as **unsigned beta** builds.

To install an unsigned beta:

1. Download the `Halo-<version>.zip` asset and its `.sha256` checksum from a GitHub Release.
2. Verify the checksum with `shasum -a 256 -c Halo-<version>.zip.sha256`.
3. Unzip the archive and move `Halo.app` to `/Applications`.
4. Right-click `Halo.app`, choose **Open**, and confirm the macOS warning. This is a one-time approval for the downloaded app; do not disable Gatekeeper globally.
5. Grant Automation, Location Services, and Full Disk Access only for the features you want to use. See [permissions and privacy](docs/permissions.md).

Once a valid Developer ID certificate and notarization credentials are available, the same release workflow can produce a signed and notarized build. See [docs/release.md](docs/release.md).

## Features

- A fixed, top-pinned black pill/card that morphs in SwiftUI without moving the underlying window.
- Now Playing from Apple Music, Spotify, or the system MediaRemote service.
- Album artwork, progress, seeking, previous/play/pause/next controls, and app-aware transport routing.
- Music Up Next support, including direct playlist playback where Music exposes a playlist context.
- Recently played Music tracks read from Music playback-session archives.
- Battery level, charging state, and time-until-full information.
- Upcoming Calendar events and incomplete Reminders, with one-tap reminder completion.
- Weather from CoreLocation and Open-Meteo.
- Live Focus mode and icon when the macOS Focus database is readable.
- New notification activities from the macOS usernoted database when it is readable.
- Codex developer activity through the local `codex app-server`: recent chats, repository/branch context, live work updates, approval prompts, and a composer for sending turns.
- OpenCode developer activity through its local HTTP/SSE server: recent sessions, repository context, live streamed replies, permission prompts, and a composer for continuing sessions.
- An app-like Settings window with persistent behavior, activity, playback, calendar, appearance, and permission controls.
- Right-click actions and preview pills for exercising each activity design.

## Requirements

- macOS 14 or later.
- Swift/Xcode capable of building the macOS target.
- Full Xcode is required to run XCTest on the current development machine. Command Line Tools alone can build the executable but do not provide xctest there.
- Music and Spotify are optional. Weather requires network access; Apple Music metadata/artwork and Spotify artwork also use network requests.

## Build and run

From the repository root:

~~~bash
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
./bundle.sh
open Halo.app
~~~

The script performs a release build and creates Halo.app at the repository root. The generated app bundle is ignored by Git. For a debug build, use:

~~~bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build
~~~

To create a tested release archive, use:

~~~bash
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
./release.sh
~~~

This writes `dist/Halo-<version>.zip` and a matching SHA-256 checksum. Without `HALO_SIGNING_IDENTITY`, the archive is unsigned. Optional signing and notarization variables are documented in [docs/release.md](docs/release.md).

The repository also includes CI and an optional unsigned beta release workflow. After these workflow files are committed, pushing a tag such as `v1.0` builds the archive and publishes it as a GitHub Release. The workflow intentionally does not sign or notarize the app.

If Xcode is installed elsewhere, update DEVELOPER_DIR accordingly. To select Xcode permanently for the machine:

~~~bash
sudo xcode-select --switch /Applications/Xcode.app/Contents/Developer
~~~

## Tests

Run the test suite with the full Xcode developer directory selected:

~~~bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
~~~

The tests cover activity-stack behavior, fixed-window positioning, priority ordering, battery formatting, notification decoding, Music queue decoding, playback-session archive parsing, artwork URL handling, and MediaRemote safety. See docs/testing.md for the test matrix and limitations.

## Runtime behavior

The app starts with an idle Halo pill. Monitors then update a shared activity stack. The highest-priority activity is shown in the collapsed pill:

~~~text
        Notification → Codex/OpenCode/Now Playing → Calendar/Focus → Charging → Weather
~~~

Activities are updated in place by identifier, and the stack is capped at four entries. Track changes and Focus activation pop open their cards briefly before settling back to a live pill. A fresh plug-in temporarily promotes Charging. Notifications are transient; Music, Spotify, Calendar, Focus, Battery, and Weather remain available until their source clears or the user dismisses them.

Calendar and Reminders are read through EventKit. Halo keeps a configurable lookahead (seven days by default) and incomplete reminders, including overdue reminders until they are completed, with up to 25 items by default available to the expanded agenda. EventKit and system-change observers plus a one-minute refresh keep the activity current; a one-shot timer catches the next event start without high-frequency polling. Upcoming times become relative when useful, and a real event start gently expands the Calendar card once before settling back to its pill. The expanded card gives the next item visual weight and places the remaining returned items in a shared scrollable Up Next rail. Clicking an event or reminder title/time opens that exact item in Calendar or Reminders, event rows show their start/end range, and location controls open the place in Apple Maps. EventKit web links are exposed as optional meeting-link actions. Tapping the circle beside a reminder marks it complete in the Reminders database. Halo does not create events or send a second system notification.

The collapsed pill can be clicked to open the top activity. Hover-open requires
cursor movement onto the visible shape, a 300 ms dwell, and no other card
already being expanded. Moving away schedules a 300 ms collapse when enabled.
Transparent space around the pill/card passes input through to the application
underneath.

## Codex developer activity

When the Codex activity source is enabled, Halo starts the local `codex app-server` over its standard JSONL transport. It reads the recent thread list, opens the newest-created chat by default, loads that thread's latest visible items, and listens for status, turn, item, and agent-message-delta events. The expanded Codex activity uses the existing fixed 640×190 content surface: chats stay in the left rail, the selected conversation is on the right, and the composer resumes the selected stored thread before sending a normal `turn/start` request. This includes stored and paginated histories whose list response does not yet expose direct-input capability; the app-server resolves that capability during `thread/resume`. If another Codex session currently owns the thread, Halo uses the installed app-server's experimental `thread/queue/add` handoff so the message is delivered to that active session, rather than creating a duplicate chat or sending a turn to an unrelated server thread. Halo shows `QUE` while the handoff is pending and briefly refreshes the thread history to catch the persisted message. If the server explicitly marks a chat as unable to accept input, Halo leaves it read-only and keeps + New chat as the explicit fallback; it does not silently create another chat.

The compact Codex pill uses the official OpenAI Blossom mark only as provider attribution. The OpenAI mark remains OpenAI property, and its use does not imply sponsorship or endorsement of Halo.

Codex remains responsible for authentication, model selection, rollout history, approvals, sandboxing, and network access. Halo does not read an API key, scrape terminal output, or create a second Codex history store. Command and file-change approval requests are shown inline with Allow/No actions; unsupported interactive requests are rejected explicitly so a turn cannot remain silently blocked. WORK activity is hidden by default to keep the conversation calm; Settings → Live Activities → Codex WORK activity reveals the WORK actions, secondary status/context, and approval explanation when needed. Approval prompts remain visible because Codex may be waiting for a decision. The activity currently loads the newest 50 chats and the newest 100 visible items for the selected chat.

## OpenCode developer activity

When the OpenCode activity source is enabled, Halo launches `opencode serve --hostname 127.0.0.1 --port 0` on a free loopback port, gives that child an ephemeral local HTTP password, and subscribes to its `/api/event` SSE stream. The temporary password is used only between Halo and its own loopback server; it is not an OpenCode provider credential and does not bypass OpenCode's provider authentication or permission configuration. Halo loads the newest 50 sessions, opens the newest session by default, and loads up to 100 messages for the selected session. OpenCode live events update the conversation immediately; Halo does not poll the server on a fixed timer. The expanded activity uses the same fixed 640×190 surface: sessions stay in the left rail, the selected conversation stays on the right, and the composer sends a prompt into the selected stored session.

OpenCode remains responsible for provider authentication, model selection, tool execution, sandboxing, and persisted session history. Halo does not read or store OpenCode credentials. Permission requests appear inline with Allow/No actions; WORK activity is hidden by default and can be enabled from Settings → Live Activities → OpenCode WORK activity. The current integration supports session history, text streaming, tool summaries, interrupt, and permission responses. OpenCode's richer question-style interactive requests are not yet rendered in Halo.

## Music and recently played behavior

Music is read through AppleScript because direct MediaRemote reads are unreliable for Apple Music on recent macOS versions. On a track change Halo reads the title, artist, album, player state, position, duration, and artwork. Live status uses an adaptive poll: once per second while playing, every three seconds while paused, and a low-power fifteen-second backstop while Music is not running. User actions and Music lifecycle events use short follow-up probes so the card catches up quickly without making AppleScript calls continuously. It then tries to resolve the next three tracks:

1. The current playlist, verified against the current track.
2. Music's library playlist, also verified.
3. No scripting queue for catalog/radio contexts.

For catalog contexts, Halo uses Music playback-session archives to recover the true queue order. It resolves store IDs through the public iTunes Lookup API, downloads small artwork thumbnails, and protects the visible card from stale session contexts.

An Up Next playlist row is played directly through Music using its playlist persistent ID and track index. Playlist rows appear immediately with their title and artist, then fill in artwork from Music's embedded track artwork when available. A catalog row cannot be addressed reliably by AppleScript, so it opens a music:// track URL instead. If no queue is available, the card shows a recently-played rail from Music's session archives. Tapping a recent track opens its music:// URL when one was recorded.

The detailed source and precedence rules are in docs/architecture.md.

## Settings and persistence

Open **Settings…** from Halo's right-click menu. The settings window uses a tabbed, app-like layout for startup, pointer behavior, live activity visibility, Codex/OpenCode WORK activity visibility, music rails, Calendar/Reminders presentation, motion, permissions, and project information.

Display preferences are stored in macOS `UserDefaults` and are restored on relaunch. Launch-at-login is read from `SMAppService`, so macOS remains the source of truth for that registration. Permission grants are managed by macOS TCC; Halo reads the current status and stores only whether it has already made an automatic request, preventing repeated launch-time prompts. The Permissions tab offers an intentional retry or a direct link to the relevant System Settings pane.

## Permissions and privacy

Some capabilities depend on macOS TCC permissions:

- Apple Events/Automation for reading and controlling Music and Spotify.
- Location access for location-based weather.
- Full Disk Access for live Focus state and the notification store.
- Calendar and Reminders access for upcoming events, due reminders, and reminder completion.

Halo does not run a backend or maintain its own activity database. It stores preferences in macOS `UserDefaults`, keeps runtime activity state in memory, reads selected local macOS/media files, sends coordinates to Open-Meteo, and sends Music store IDs to the iTunes Lookup API when resolving queue metadata. See docs/permissions.md.

## Repository map

| Path | Purpose |
| --- | --- |
| Package.swift | macOS 14 Swift Package Manager manifest and framework links. |
| Sources/Halo/App.swift | Application startup, monitor wiring, command routing, and context menu. |
| Sources/Halo/Halo.swift | Activity models, state center, window controller, animations, and SwiftUI views. |
| Sources/Halo/MusicAppMonitor.swift | Apple Music AppleScript integration and playlist queue parsing. |
| Sources/Halo/SpotifyMonitor.swift | Spotify AppleScript integration and artwork download. |
| Sources/Halo/NowPlayingMonitor.swift | Runtime bridge to the private MediaRemote framework. |
| Sources/Halo/PlaybackHistoryMonitor.swift | Music playback-session archive, queue, metadata, and artwork handling. |
| Sources/Halo/BatteryMonitor.swift | IOKit power-source monitor. |
| Sources/Halo/WeatherMonitor.swift | CoreLocation/Open-Meteo weather monitor. |
| Sources/Halo/FocusMonitor.swift | Focus database reader and mode/icon decoder. |
| Sources/Halo/NotificationMonitor.swift | Read-only SQLite notification-store adapter. |
| Sources/Halo/CalendarMonitor.swift | EventKit events/reminders adapter and reminder completion. |
| Sources/Halo/CodexMonitor.swift / CodexView.swift | Local Codex app-server client, chat/activity model, and fixed-size Codex workspace UI. |
| Sources/Halo/OpenCodeMonitor.swift / OpenCodeView.swift | Local OpenCode HTTP/SSE client, session/activity model, and fixed-size OpenCode workspace UI. |
| Sources/Halo/HaloSettings.swift | Persisted preferences, login-item state, and permission request ledger. |
| Sources/Halo/SettingsRootView.swift | App-like tabbed Settings and permissions UI. |
| Tests/HaloTests/HaloTests.swift / CalendarTests.swift / SettingsTests.swift | Unit and lightweight host integration tests. |
| bundle.sh | Release build and unsigned app-bundle creation. |
| release.sh | Tested release archive creation with optional signing and notarization. |
| Halo.entitlements / Sources/Halo/Resources/Info.plist | Runtime entitlements and bundle metadata. |

## Known limitations

- Calendar shows events through the configured lookahead and incomplete reminders with due dates, limited to the configured item cap (seven days and 25 items by default). A real event start expands the card once for four seconds; Halo does not currently create events, edit events, or send native calendar notifications.
- Calendar and Reminders require separate macOS permissions. If either permission is denied, Halo continues with the source that remains available.
- The Focus fallback displays a demo Do Not Disturb activity when live Focus data is unavailable. A manual Focus-mode picker is not implemented yet.
- The context-menu Notification action is demo data. The notification monitor only emits rows created after it establishes its startup baseline.
- Codex requires the Codex CLI to be installed and authenticated on the Mac. Halo currently supports visible chat history, continuing stored chats, normal text turns, command/file approvals, and the common app-server lifecycle events; richer interactive requests such as tool questionnaires are reported as unsupported. A chat explicitly reported as unable to accept direct input remains read-only; use + New chat when that happens.
- OpenCode requires the OpenCode CLI to be installed and configured on the Mac. Halo currently supports visible session history, continuing stored sessions, streamed text prompts, tool summaries, interrupt, and permission responses; richer question-style interactive requests are not yet rendered. Disable OpenCode developer activity in Settings when the CLI is not installed or when its local server should not run.
- Recent-track replay currently opens a Music deep link. The stored catalog ID is reserved for a future MusicKit-based playback path.
- MediaRemote is a private framework and may change across macOS releases.
- Public distribution still requires a Developer ID signature and notarization. `release.sh` supports those steps when credentials are available; otherwise it creates an unsigned beta archive. See docs/release.md.

## Further documentation

- Architecture: docs/architecture.md
- Permissions and privacy: docs/permissions.md
- Testing: docs/testing.md
- Troubleshooting: docs/troubleshooting.md
- Contributing: CONTRIBUTING.md
- Release process: docs/release.md
- Changelog: CHANGELOG.md
