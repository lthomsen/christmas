#!/bin/zsh
# Builds build/JuleHygge.app (ad-hoc signed). The app icon is drawn by the app itself, so the repo has no image files.
set -euo pipefail
cd "${0:A:h}"
# UNIVERSAL=1 builds one binary for both Apple Silicon and Intel (used by the GitHub release workflow).
ARCHS=()
if [[ "${UNIVERSAL:-0}" == 1 ]]; then ARCHS=(--arch arm64 --arch x86_64); fi
swift build -c release "${ARCHS[@]}"
BIN="$(swift build -c release "${ARCHS[@]}" --show-bin-path)/JuleHygge"
APP=build/JuleHygge.app
ICONSET=build/JuleHygge.iconset
rm -rf "$APP" "$ICONSET"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$ICONSET"
cp "$BIN" "$APP/Contents/MacOS/JuleHygge"
cp Info.plist "$APP/Contents/Info.plist"
"$BIN" --icon "$ICONSET"
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/JuleHygge.icns"
codesign --force --sign - "$APP" >/dev/null
echo "Bygget: $PWD/$APP"
