# Permissions and privacy

Alcove is an accessory app with an unsandboxed entitlement configuration. That avoids imposing a sandbox on the local adapters, but macOS TCC controls still apply to protected data and Apple Events.

## Permission matrix

| Capability | macOS permission | Used by | Behavior without access |
| --- | --- | --- | --- |
| Music/Spotify control and metadata | Automation / Apple Events | MusicAppMonitor, SpotifyMonitor | Scripts fail or return no track; generic MediaRemote may still work for transport. |
| Weather | Location Services | WeatherMonitor | The monitor uses Cupertino fallback coordinates when no location is available. |
| Weather/artwork/queue metadata | Network access | Weather, Music history, Spotify | Existing local UI remains, but requests cannot refresh or fill artwork/metadata. |
| Live Focus state | Full Disk Access | FocusMonitor | Focus monitor stays silent. The current UI fallback shows demo Do Not Disturb data when invoked manually. |
| New notification rows | Full Disk Access | NotificationMonitor | Real notification monitor stays silent; the context-menu demo remains available. |

## Automation

Music and Spotify are read and controlled with NSAppleScript. The first operation may cause macOS to ask whether Alcove can control the target app.

To review access:

1. Open System Settings.
2. Go to **Privacy & Security → Automation**.
3. Allow Alcove to control Music and/or Spotify.

The bundle declares NSAppleEventsUsageDescription in [Info.plist](../Sources/Alcove/Resources/Info.plist). Automation prompts are controlled by macOS and may need to be reset if permissions were previously denied.

## Location

The app requests When In Use location access only when weather starts. The purpose string is declared in [Info.plist](../Sources/Alcove/Resources/Info.plist). Weather is fetched from Open-Meteo using latitude, longitude, and automatic timezone selection.

If location is denied or unavailable, the monitor does not block the rest of the app. It attempts Cupertino fallback coordinates so the weather card can still show useful data during development.

## Full Disk Access

Full Disk Access is needed on the tested macOS setup for these paths:

~~~text
~/Library/DoNotDisturb/DB/Assertions.json
~/Library/DoNotDisturb/DB/ModeConfigurations.json
~/Library/Group Containers/group.com.apple.usernoted/db2/db
~~~

Alcove does not request or open the System Settings pane automatically. It tests whether the files/database are readable and logs a single diagnostic message, then degrades quietly.

Music playback-session archives are read separately from:

~~~text
~/Library/Application Support/Music/PlaybackSessions/
~~~

The implementation treats that location as user-readable and does not use it as a reason to prompt for Full Disk Access.

## Network destinations

The current source makes requests to:

- api.open-meteo.com for weather.
- itunes.apple.com for Music queue metadata.
- Artwork URLs supplied by Spotify or Apple Music CDN data.

There is no Alcove backend, analytics service, account system, or persistent application database. Track titles and playback state are processed locally; Music store IDs are sent to the iTunes Lookup endpoint only when the session queue needs display metadata.

## Changes to permission behavior

When adding a new protected data source:

- Add the smallest required usage-description key to Info.plist.
- Detect readability at runtime instead of assuming the permission exists.
- Keep the monitor silent or use a safe fallback when access is missing.
- Document the exact path, destination, and user-facing behavior here.
