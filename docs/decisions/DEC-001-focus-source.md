# DEC-001 — Live Focus source

- Status: Accepted
- Date: 2026-09-08

## Context

The Focus activity needs the current macOS Focus mode name and icon. Focus modes may use custom icons, including emoji, so a fixed list of modes or hardcoded SF Symbols is insufficient.

The direct daemon/XPC route was investigated and rejected because the service refuses requests from this app's audit identity. A private API route would also create a fragile entitlement and OS-version dependency.

## Decision

Use a pluggable disk adapter in [FocusMonitor.swift](../../Sources/Alcove/FocusMonitor.swift):

1. Read Assertions.json to identify an asserted, non-invalidated mode.
2. Read ModeConfigurations.json to resolve its name, icon, and tint.
3. Watch the directory for updates and poll every ten seconds as a backstop.
4. Detect readability at runtime.
5. Stay silent when Full Disk Access is unavailable or the files change shape.

The app does not prompt for Full Disk Access automatically.

## Consequences

### Positive

- Users who do not grant Full Disk Access are not blocked or repeatedly prompted.
- Power users can enable live Focus state with one system permission.
- Custom Focus icons can be rendered as either valid SF Symbols or raw text/emoji.
- The monitor is isolated behind a small value type and callback surface.

### Tradeoffs

- The paths and JSON schema are private macOS implementation details and may change.
- Live Focus cannot be guaranteed on every macOS release.
- The current application does not yet provide the planned manual Focus-mode picker. When live data is unavailable, its manual invocation uses a demo Do Not Disturb activity.

## Revisit when

Reconsider this decision if Apple exposes a supported public Focus API, the database paths change, or the product adds a user-facing manual mode selector.
