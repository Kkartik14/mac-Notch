# Changelog

This file records user-visible changes. The project is currently in active development and does not yet follow a formal release cadence.

## Current development snapshot — 2026-09-16

- Added Apple Music and Spotify Now Playing adapters with playback controls and seeking.
- Added Music playlist Up Next handling with direct playlist-row playback.
- Added playback-session archive parsing for recently played tracks and true queue order.
- Added progressive Apple Music/Spotify artwork and queue thumbnails.
- Added fixed-window halo morphing and pass-through input routing.
- Added battery, weather, Focus, and notification monitors.
- Added EventKit Calendar and Reminders support with one-tap reminder completion.
- Added relative calendar timing, overdue reminder persistence, and a safe one-shot event-start card transition without duplicate native notifications.
- Redesigned the expanded Calendar card with a fixed next-item panel and scrollable Up Next agenda.
- Raised the Calendar agenda cap to 25 items and added shared row actions plus wake/clock-change recovery.
- Added exact Calendar/Reminders item opening, event start/end ranges, Apple Maps location actions, and optional meeting links.
- Added Codex developer activity through the local Codex app-server, including recent chats, repository context, live work events, a fixed-size chat workspace, composer, stop action, and inline command/file approvals.
- Added an opt-in Codex WORK activity preference; WORK actions stay hidden by default while secondary status/context and approval explanations remain available in Settings.
- Codex now opens the newest-created chat by default, independent of the server's returned thread order.
- Codex stored and paginated histories can be continued through `thread/resume`; chats explicitly marked read-only no longer create a new chat implicitly.
- Added a persistent, app-like Settings window for startup, interaction, activity visibility, music rails, calendar presentation, motion, and permission status.
- Added a macOS-aware permission request ledger so automatic EventKit and location prompts happen once while intentional retries remain available from Settings.
- Added activity priority, collapse, dismissal, and progress interpolation behavior.
- Added parser, state, positioning, and host-safety tests.
- Added tested release archive creation with checksum output and optional Developer ID signing/notarization hooks.

## Planned / not yet complete

- Manual Focus-mode selection.
- MusicKit-based direct replay for catalog recent tracks.
- UI automation and snapshot coverage.
- Public signed/notarized distribution.
