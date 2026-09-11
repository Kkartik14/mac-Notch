#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"

APP="Halo.app"
DIST_DIR="${HALO_DIST_DIR:-dist}"
NOTARY_PROFILE="${HALO_NOTARY_PROFILE:-}"
SIGNING_IDENTITY="${HALO_SIGNING_IDENTITY:-}"

if [[ -n "$NOTARY_PROFILE" && -z "$SIGNING_IDENTITY" ]]; then
  echo "HALO_NOTARY_PROFILE requires HALO_SIGNING_IDENTITY" >&2
  exit 1
fi

if [[ "${HALO_SKIP_TESTS:-0}" != "1" ]]; then
  swift test
fi

./bundle.sh

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
ZIP_PATH="$DIST_DIR/Halo-${VERSION}.zip"
CHECKSUM_PATH="${ZIP_PATH}.sha256"

mkdir -p "$DIST_DIR"

create_archive() {
  rm -f -- "$ZIP_PATH"
  ditto --norsrc -c -k --keepParent "$APP" "$ZIP_PATH"
}

rm -f -- "$CHECKSUM_PATH"
create_archive

if [[ -n "$NOTARY_PROFILE" ]]; then
  xcrun notarytool submit "$ZIP_PATH" \
    --keychain-profile "$NOTARY_PROFILE" \
    --wait

  xcrun stapler staple "$APP"
  xcrun stapler validate "$APP"
  spctl --assess --type execute --verbose=4 "$APP"

  # Rebuild the archive after stapling so the distributed zip contains the ticket.
  create_archive
fi

(
  cd "$(dirname "$ZIP_PATH")"
  shasum -a 256 "$(basename "$ZIP_PATH")" > "$(basename "$CHECKSUM_PATH")"
)

echo "Release archive: $ZIP_PATH"
echo "Checksum: $CHECKSUM_PATH"
