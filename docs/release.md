# Release process

## Current state

[bundle.sh](../bundle.sh) creates a local Halo.app. It is unsigned by default, but signs the app automatically when `HALO_SIGNING_IDENTITY` is set. [release.sh](../release.sh) runs the tests, creates a versioned zip and checksum, and can optionally submit the archive for notarization. Neither script publishes the release for you. The checked-in bundle metadata currently uses:

- Bundle identifier: com.tryhalo.halo
- Short version: 1.0
- Bundle version: 1

Before a public release, decide the support contact, license, update/distribution channel, and whether the private MediaRemote dependency is acceptable for the target audience.

## Local app build

~~~bash
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
./bundle.sh
open Halo.app
~~~

Without `HALO_SIGNING_IDENTITY`, this creates an unsigned app for local development or beta distribution. The generated `Halo.app` is ignored by Git.

## Release archive

Create a tested archive and checksum:

~~~bash
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
./release.sh
~~~

The output is:

~~~text
dist/Halo-1.0.zip
dist/Halo-1.0.zip.sha256
~~~

Set `HALO_DIST_DIR` to use another output directory. Set `HALO_SKIP_TESTS=1` only when the tests have already been run separately. Do not commit `dist/`.

For a GitHub Release, upload both the zip and checksum as assets. Keep the release notes user-facing and identify unsigned builds explicitly.

The repository includes [CI](../.github/workflows/ci.yml) and an [unsigned beta release workflow](../.github/workflows/unsigned-release.yml). Once those workflow files are committed and pushed, create a tag after updating the bundle version:

~~~bash
git tag v1.0
git push origin v1.0
~~~

The workflow runs `release.sh`, verifies the checksum, and publishes the zip and checksum with the repository's GitHub token. It deliberately does not sign or notarize the app. Do not use this workflow for a production release until the signing and notarization path below is configured.

## Versioning

Update CFBundleShortVersionString and CFBundleVersion in [Sources/Halo/Resources/Info.plist](../Sources/Halo/Resources/Info.plist) before building. Keep the user-facing release notes in [CHANGELOG.md](../CHANGELOG.md).

The package manifest does not currently define a version or an Xcode project; the app bundle plist is the source of the product version.

## Signing

The signing identity is never stored in the repository. First check whether a usable certificate and private key are installed locally:

~~~bash
security find-identity -v -p codesigning
~~~

Look for an identity beginning with `Developer ID Application:`. Set that exact value only in your shell environment:

~~~bash
export HALO_SIGNING_IDENTITY="Developer ID Application: YOUR NAME (TEAMID)"
./release.sh
~~~

`bundle.sh` uses the identity to enable the hardened runtime, apply [Halo.entitlements](../Halo.entitlements), and verify the resulting signature. If no identity is set, the output is explicitly unsigned. If an identity is set but is expired, revoked, or lacks its private key, signing fails.

Do not commit certificates, private keys, `.p12` exports, notarization credentials, or user-specific provisioning files. If signing in CI later, store the certificate and private key in the CI secret store and provide the identity through `HALO_SIGNING_IDENTITY`.

## Notarization

Notarization requires an active Apple developer account/team and a valid Developer ID signature. Store a notarytool keychain profile locally, then pass only the profile name to the script:

~~~bash
export HALO_SIGNING_IDENTITY="Developer ID Application: YOUR NAME (TEAMID)"
export HALO_NOTARY_PROFILE="halo-notary"
./release.sh
~~~

`release.sh` submits the archive, waits for Apple’s result, staples the ticket to `Halo.app`, validates the staple, verifies Gatekeeper assessment, then recreates the zip so the distributed archive contains the stapled app.

The equivalent manual commands are:

~~~bash
xcrun notarytool submit dist/Halo-1.0.zip \
  --keychain-profile YOUR_PROFILE \
  --wait

xcrun stapler staple Halo.app
xcrun stapler validate Halo.app
spctl --assess --type execute --verbose=4 Halo.app
~~~

Verify the final artifact on a clean Mac with no development certificate or source checkout. Apple’s [macOS distribution guidance](https://developer.apple.com/macos/distribution/) and [notarization guidance](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution) describe the account and Gatekeeper requirements.

## Release checklist

- [ ] Confirm the intended macOS minimum version.
- [ ] Update bundle version fields and CHANGELOG.md.
- [ ] Run swift test with full Xcode selected.
- [ ] Build a clean release bundle.
- [ ] Test Music, Spotify, battery, weather, hover, fullscreen, and multi-display behavior.
- [ ] Test missing Automation, Location, and Full Disk Access behavior.
- [ ] Sign with the intended Developer ID identity.
- [ ] Verify the signature.
- [ ] Notarize and staple the app.
- [ ] Verify Gatekeeper assessment on a clean system.
- [ ] Archive the exact zip and release notes.
- [ ] Upload the zip and checksum to the intended release channel.
- [ ] Do not commit Halo.app, dist/, .build, credentials, or local TCC artifacts.
