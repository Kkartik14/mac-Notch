# Contributing to Halo

Thanks for helping improve Halo. The project is a native Swift Package Manager macOS app, so changes should preserve the app's lightweight, source-adapter architecture and graceful behavior when permissions or external apps are unavailable.

## Before changing code

Read:

- [README.md](README.md) for user-facing behavior.
- [docs/architecture.md](docs/architecture.md) for state flow and source precedence.
- [docs/testing.md](docs/testing.md) for the available test commands and host dependencies.

Keep unrelated working-tree changes intact. Generated .build output and Halo.app are ignored and should not be committed.

## Development workflow

~~~bash
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
swift build
swift test
~~~

Run the app from a freshly generated bundle when validating TCC permissions or AppleScript behavior:

~~~bash
./bundle.sh
open Halo.app
~~~

## Design rules

- Keep UI state on the main thread.
- Use expand: false for passive refreshes so polling does not hijack the halo.
- Use the HaloCenter silent update methods for progress, artwork, queue, and recent-track changes; do not re-present an activity just to attach late data.
- Cancel timers, dispatch sources, URL tasks, and notification observers in stop/deinit paths.
- Treat AppleScript, private MediaRemote, filesystem layouts, and network responses as unreliable external interfaces.
- Fail soft when permission is absent or a payload changes shape. A missing activity is preferable to a fabricated one.
- Keep Music queue reads bounded. Do not enumerate a user's entire library for a small Up Next rail.
- Avoid adding network or persistent-storage dependencies unless the user-facing value and privacy impact are documented.
- Add pure parser/state tests before relying on live integration tests.

## Adding a monitor

A monitor should generally:

1. Own its polling/watching resources.
2. Expose a small value type and callback surface.
3. Store its latest valid value for manual refresh actions where appropriate.
4. Deduplicate unchanged updates.
5. Dispatch UI-facing callbacks on the main queue.
6. Log failures with the [Halo] prefix without spamming every poll.
7. Provide a deterministic parser or formatter that can be unit tested.

Then wire it in AppDelegate.startMonitors, add the corresponding activity case/view, and document its permission and fallback behavior.

## Tests and validation

At minimum, run:

~~~bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build -c release
~~~

For changes to media or window behavior, manually check:

- Track change, pause/resume, next/previous, and seek.
- Music playlist queue rows and catalog rows.
- Recently played loading, artwork arrival, and deep-link replay.
- Multiple activities and priority restoration.
- Plug-in promotion and unplug dismissal.
- Hover and click routing over transparent and visible regions.
- Missing permissions and stopped target apps.

## Commit and pull-request expectations

- Keep commits focused and describe behavior changes clearly.
- Include tests for new pure logic or parsing.
- Update README/docs when behavior, permissions, commands, or release requirements change.
- Do not include generated app bundles, build directories, personal paths, credentials, screenshots containing private data, or TCC database copies.
- Mention any manual macOS verification that could not be automated.

## License and support

No license or public support address is currently defined in the repository. Establish those before accepting outside contributions or distributing the app publicly.
