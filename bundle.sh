#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release

APP="Halo.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
mkdir -p "$APP/Contents/Resources"

cp .build/release/Halo "$APP/Contents/MacOS/Halo"
cp Sources/Halo/Resources/Info.plist "$APP/Contents/Info.plist"

if [[ -n "${HALO_SIGNING_IDENTITY:-}" ]]; then
  codesign \
    --force \
    --options runtime \
    --timestamp \
    --entitlements Halo.entitlements \
    --sign "$HALO_SIGNING_IDENTITY" \
    "$APP"
  codesign --verify --deep --strict --verbose=2 "$APP"
  echo "Built and signed $APP"
else
  echo "Built unsigned $APP"
fi

echo "Run with: open $APP"
