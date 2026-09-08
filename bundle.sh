#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release

APP="Alcove.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
mkdir -p "$APP/Contents/Resources"

cp .build/release/Alcove "$APP/Contents/MacOS/Alcove"
cp Sources/Alcove/Resources/Info.plist "$APP/Contents/Info.plist"

echo "Built $APP"
echo "Run with: open $APP"