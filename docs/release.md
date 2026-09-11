# Release process

## Current state

[bundle.sh](../bundle.sh) creates a local unsigned Alcove.app. It does not sign, notarize, staple, package, or publish the application. The checked-in bundle metadata currently uses:

- Bundle identifier: com.tryalcove.alcove
- Short version: 1.0
- Bundle version: 1

Before a public release, decide the support contact, license, update/distribution channel, and whether the private MediaRemote dependency is acceptable for the target audience.

## Local release build

~~~bash
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
./bundle.sh
open Alcove.app
~~~

Run the tests before packaging:

~~~bash
swift test
~~~

If Xcode is not the active developer directory, retain the DEVELOPER_DIR export for both commands.

## Versioning

Update CFBundleShortVersionString and CFBundleVersion in [Sources/Alcove/Resources/Info.plist](../Sources/Alcove/Resources/Info.plist) before building. Keep the user-facing release notes in [CHANGELOG.md](../CHANGELOG.md).

The package manifest does not currently define a version or an Xcode project; the app bundle plist is the source of the product version.

## Signing

For a Developer ID distribution build, sign with an Apple Developer ID Application certificate and the repository entitlements. Replace the identity placeholder with the exact certificate name installed in the keychain:

~~~bash
codesign --force --deep --options runtime \
  --entitlements Alcove.entitlements \
  --sign "Developer ID Application: YOUR NAME (TEAMID)" \
  Alcove.app

codesign --verify --deep --strict --verbose=2 Alcove.app
~~~

Use a clean release build for signing. Do not commit certificates, private keys, notarization credentials, or user-specific provisioning files.

## Notarization

Create a zip with the app bundle as its top-level item:

~~~bash
ditto -c -k --keepParent Alcove.app Alcove.zip
~~~

Submit using an already configured notarytool keychain profile:

~~~bash
xcrun notarytool submit Alcove.zip \
  --keychain-profile YOUR_PROFILE \
  --wait

xcrun stapler staple Alcove.app
xcrun stapler validate Alcove.app
spctl --assess --type execute --verbose=4 Alcove.app
~~~

The exact signing/notarization options may change with Apple's tooling. Verify the final artifact on a clean Mac with no development certificate or source checkout.

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
- [ ] Do not commit Alcove.app, .build, credentials, or local TCC artifacts.
