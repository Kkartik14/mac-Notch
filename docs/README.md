# Alcove documentation

This directory contains the maintained technical documentation for Alcove.

## Documents

- [Architecture](architecture.md) — runtime flow, state model, monitor responsibilities, queue precedence, and extension points.
- [Permissions and privacy](permissions.md) — TCC requirements, local paths, network destinations, and fallback behavior.
- [Testing](testing.md) — toolchain setup, commands, coverage, host-dependent tests, and logging.
- [Troubleshooting](troubleshooting.md) — common runtime, media, queue, permission, weather, and test issues.
- [Release process](release.md) — versioning, local bundles, signing, notarization, and release checklist.
- [Focus source decision](decisions/DEC-001-focus-source.md) — why Focus state uses a guarded disk adapter.

The repository root contains the user-facing [README](../README.md), [contribution guide](../CONTRIBUTING.md), and [changelog](../CHANGELOG.md).

## Documentation maintenance

Update documentation when any of these change:

- A command, minimum OS, build requirement, or release artifact.
- A permission, local filesystem path, network destination, or privacy behavior.
- Activity priority, card timing, media routing, queue/replay behavior, or fallback behavior.
- A public-facing feature or a known limitation.

The local directory is intentionally ignored and contains scratch notes, previews, and backups. Important decisions should be copied into this tracked documentation directory.
