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
- Weather from CoreLocation and Open-Meteo.
- Live Focus mode and icon when the macOS Focus database is readable.
- New notification activities from the macOS usernoted database when it is readable.
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
Notification → Now Playing → Focus → Charging → Weather
~~~

Activities are updated in place by identifier, and the stack is capped at four entries. Track changes and Focus activation pop open their cards briefly before settling back to a live pill. A fresh plug-in temporarily promotes Charging. Notifications are transient; Music, Spotify, Focus, Battery, and Weather remain available until their source clears or the user dismisses them.

The collapsed pill can be clicked to open the top activity. Hover-open requires cursor movement onto the visible shape. Transparent space around the pill/card passes input through to the application underneath.

## Music and recently played behavior

Music is read through AppleScript because direct MediaRemote reads are unreliable for Apple Music on recent macOS versions. On a track change Halo reads the title, artist, album, player state, position, duration, and artwork. Live status uses an adaptive poll: once per second while playing, every three seconds while paused, and a low-power fifteen-second backstop while Music is not running. User actions and Music lifecycle events use short follow-up probes so the card catches up quickly without making AppleScript calls continuously. It then tries to resolve the next three tracks:

1. The current playlist, verified against the current track.
2. Music's library playlist, also verified.
3. No scripting queue for catalog/radio contexts.

For catalog contexts, Halo uses Music playback-session archives to recover the true queue order. It resolves store IDs through the public iTunes Lookup API, downloads small artwork thumbnails, and protects the visible card from stale session contexts.

An Up Next playlist row is played directly through Music using its playlist persistent ID and track index. Playlist rows appear immediately with their title and artist, then fill in artwork from Music's embedded track artwork when available. A catalog row cannot be addressed reliably by AppleScript, so it opens a music:// track URL instead. If no queue is available, the card shows a recently-played rail from Music's session archives. Tapping a recent track opens its music:// URL when one was recorded.

The detailed source and precedence rules are in docs/architecture.md.

## Permissions and privacy

Some capabilities depend on macOS TCC permissions:

- Apple Events/Automation for reading and controlling Music and Spotify.
- Location access for location-based weather.
- Full Disk Access for live Focus state and the notification store.

Halo does not run a backend or maintain its own database. It stores runtime state in memory, reads selected local macOS/media files, sends coordinates to Open-Meteo, and sends Music store IDs to the iTunes Lookup API when resolving queue metadata. See docs/permissions.md.

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
| Sources/Halo/SettingsRootView.swift | Current minimal Settings window. |
| Tests/HaloTests/HaloTests.swift | Unit and lightweight host integration tests. |
| bundle.sh | Release build and unsigned app-bundle creation. |
| release.sh | Tested release archive creation with optional signing and notarization. |
| Halo.entitlements / Sources/Halo/Resources/Info.plist | Runtime entitlements and bundle metadata. |

## Known limitations

- The Settings window is currently informational; there are no persisted user settings.
- The Focus fallback displays a demo Do Not Disturb activity when live Focus data is unavailable. A manual Focus-mode picker is not implemented yet.
- The context-menu Notification action is demo data. The notification monitor only emits rows created after it establishes its startup baseline.
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
