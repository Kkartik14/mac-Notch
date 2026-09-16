# Troubleshooting

## The halo does not appear

- Run the bundled app with open Halo.app; a raw swift build only produces a binary and does not create the normal app bundle metadata.
- Check that the app is not already running as an accessory process.
- Look for [Halo] messages in Console.app or with the command in docs/testing.md.
- The app intentionally has no Dock or menu-bar icon. The black pill at the top of the main display is the primary UI.

## Music or Spotify is not detected

- Start the target app and wait for the monitor's launch probe; while playing, the normal status poll runs once per second.
- Check **System Settings → Privacy & Security → Automation** and allow Halo to control the target app.
- Use the halo's right-click **Now Playing** action to force a refresh.
- Music and Spotify are separate sources. If both are open, transport commands are routed toward the player that is currently playing.

## Play/pause/next works but the card is stale

The monitors update the UI through different paths. Music and Spotify use AppleScript, while some MediaRemote callbacks can arrive asynchronously. Music uses an adaptive poll plus short action/lifecycle probes. Use **Now Playing** from the context menu to force all playback sources to refresh.

## Up Next is empty

Music does not expose a scripting-visible queue for every context. Playlist/library playback can expose direct neighbor tracks; catalog, radio, and curated contexts may require the playback-session archive resolver.

Check that:

- Music has actually played the track on this Mac.
- The Music PlaybackSessions directory exists and contains recent archives.
- Network access is available for the iTunes Lookup metadata request.

An empty queue is an expected result when no trustworthy context can be resolved. The implementation prefers an empty queue to displaying guessed tracks.

## Recently played is empty

The recent rail is sourced from Music playback-session archives, not from Music's visible history UI. It may be empty when:

- Music has not generated session archives yet.
- The archives are incomplete while Music is rewriting them.
- The current track is the only parsed track; it is filtered from its own recent rail.
- The archive has no catalog URL, so the row may not be replayable even if it is displayed.

The monitor scans on startup, watches the directory, and polls every ten seconds.

## Focus is not live

Grant Full Disk Access to the built Halo.app, then restart the app. The monitor reads the two Focus database files directly and remains silent when they are inaccessible. The current fallback is a demo Do Not Disturb activity; there is not yet a manual mode picker.

## Real notifications do not appear

Grant Full Disk Access to the built app and restart it. The notification monitor establishes a baseline at startup, so existing rows are deliberately not replayed. Only newer rows are emitted. The context-menu Notification action is a separate hardcoded demo.

## Weather is missing or looks wrong

- Allow Location Services for Halo.
- Check network access to Open-Meteo.
- Wait for the initial location callback and request completion.
- When no location is available, development fallback coordinates point to Cupertino, California.

Weather refreshes every ten minutes and throttles requests to at most once every five minutes.

## Calendar or Reminders are missing

- Allow Halo under **System Settings → Privacy & Security → Calendars** and/or **Reminders**.
- Restart the built Halo.app after changing access if the activity does not appear.
- Calendar and Reminders are separate permissions; granting Calendar does not grant Reminders.
- Halo shows events from today through the next seven days and incomplete reminders with due dates. Overdue reminders remain until completed; reminders without a due date are intentionally skipped.
- A timed event is shown as a passive pill before it starts and expands once at its start time. Halo does not play a sound or send a duplicate native Calendar notification.
- Tap the circle on an expanded reminder row to mark it complete. The row disappears after EventKit confirms the save.

## Ask Codex does not send

- Confirm the bundled Halo.app can find the authenticated `codex` executable. Halo launches `codex app-server --stdio` locally and does not store Codex credentials.
- Halo attempts `thread/resume` for the selected history before sending, including stored/paginated histories whose list entry does not state whether input is accepted. If Codex explicitly reports that the chat cannot accept direct input, Halo disables that composer instead of silently creating a different chat; click the + New chat button to start a writable chat in the same workspace.
- If the composer does not accept keyboard input, restart the rebuilt Halo.app; the halo panel must become the key window when the composer is clicked.
- If a turn is waiting, resolve the inline command/file approval or use Stop Codex before sending another request.

## Tests cannot find XCTest

Use the full Xcode developer directory:

~~~bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
~~~

If Xcode is installed elsewhere, point DEVELOPER_DIR at its Contents/Developer directory. xcode-select -p should not point only to /Library/Developer/CommandLineTools when running tests.

## The app bundle cannot be distributed

bundle.sh creates an unsigned local bundle only. Follow docs/release.md for signing, notarization, verification, and version updates.
