#!/bin/sh
# Builds a release Dobby.app into ./build (ad-hoc signed).
set -eu
cd "$(dirname "$0")/.."

swift build -c release
BIN_DIR="$(swift build -c release --show-bin-path)"
APP="build/Dobby.app"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN_DIR/Dobby" "$APP/Contents/MacOS/Dobby"
# Root helper, started on demand via the admin password prompt.
cp "$BIN_DIR/DobbyHelper" "$APP/Contents/MacOS/DobbyHelper"
cp Resources/Info.plist "$APP/Contents/Info.plist"
codesign --force --sign - "$APP/Contents/MacOS/DobbyHelper"
codesign --force --sign - "$APP"

echo "Built $APP"
