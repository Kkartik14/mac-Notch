# Testing

## Toolchain setup

The repository is a Swift Package Manager project with a macOS executable target and an XCTest target. On the current development machine, Command Line Tools provide enough Swift support for swift build but do not provide XCTest or xctest.

Full Xcode is installed at /Applications/Xcode.app. Run tests with:

~~~bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
~~~

Or select Xcode as the system developer directory once:

~~~bash
sudo xcode-select --switch /Applications/Xcode.app/Contents/Developer
swift test
~~~

Useful checks:

~~~bash
xcode-select -p
xcodebuild -version
xcrun --find xctest
~~~

## Standard commands

~~~bash
# Debug compile
swift build

# Release compile
swift build -c release

# Full suite, using Xcode without changing the system selection
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test

# Run one test class or method
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter HaloCenterTests
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter UpNextTests.testParsesNeighborRecords
~~~

## Test coverage

[Tests/HaloTests/HaloTests.swift](../Tests/HaloTests/HaloTests.swift), [CalendarTests.swift](../Tests/HaloTests/CalendarTests.swift), and [SettingsTests.swift](../Tests/HaloTests/SettingsTests.swift) currently cover:

- Initial, collapsed, expanded, auto-dismissed, and capped activity stacks.
- Fixed-window origin math and the anti-slide center/top-edge contract.
- Priority ordering and temporary Charging promotion.
- Battery ETA formatting and a live IOKit reading.
- Weather condition-to-symbol mapping.
- Playback-indicator state: paused playback selects a still indicator, while playing playback selects the animated indicator; progress updates also propagate the paused state.
- Notification property-list decoding and malformed payload rejection.
- Calendar/Reminders filtering, ordering, in-progress event retention, overdue-reminder persistence, relative time labels, start-boundary detection, rail limits, exact native item URLs, Maps links, web-link filtering, and event duration ranges.
- UserDefaults-backed preference restoration and persistence of the automatic permission-request ledger.
- Shared scroll-rail geometry: row spacing, viewport clamping, empty input, invalid dimensions, and the overflow threshold.
- Shared presentation policy: explicit user expansion, hover ownership, automatic alert ownership, pointer-exit collapse, and protection against passive updates hijacking the expanded card.
- Codex app-server parsing and display contracts: approval/waiting state, compact labels, thread metadata, optional WORK activity filtering and status details, private-reasoning omission, and Codex activity priority.
- OpenCode HTTP/SSE parsing and display contracts: session metadata and ordering, millisecond timestamps, message/tool parsing, private-reasoning omission, direct/global SSE payloads, streamed output tokens, permission request bodies, and optional WORK activity filtering.
- Music scripting queue payload parsing.
- Playback progress and recent-track attachment behavior.
- Gzip decoding, protobuf title/artist parsing, archive parsing, JSON extraction, and artwork URL normalization.
- MediaRemote calls failing safely when no player/framework data is available.

## Host-dependent tests

The suite is not entirely hermetic:

- The battery reading test uses the host Mac's actual IOKit power-source data.
- MediaRemote safety is tested against the host's available private framework.
- The app target and UI code require macOS frameworks; tests cannot run on Linux.

The archive, queue, priority, positioning, and parser tests use synthetic or pure data and should be deterministic.

## What is not covered yet

- SwiftUI snapshot or UI automation tests, including the tabbed Settings window.
- End-to-end AppleScript tests against Music and Spotify.
- Live Open-Meteo, iTunes Lookup, Spotify artwork, or CDN tests.
- Full Disk Access success/failure integration tests.
- Live `codex app-server` turns, approvals, and Codex CLI authentication/configuration.
- Live OpenCode server turns, permissions, and OpenCode provider authentication/configuration.
- Multi-display, fullscreen, sleep/wake, and real hover hit-testing automation.

Live integrations should be tested manually on a development Mac, because tests that control media players or depend on TCC state are difficult to make reliable in CI.

## Logs

Runtime diagnostics use NSLog with the [Halo] prefix. During development, inspect them with Console.app or a filtered stream such as:

~~~bash
log stream --info --predicate 'eventMessage CONTAINS "[Halo]"'
~~~

Keep tests focused on pure parsing/state behavior where possible. Monitor tests should inject or isolate external data rather than depending on the user's current media, location, notification history, or Focus state.
