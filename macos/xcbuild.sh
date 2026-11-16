#!/bin/zsh
# Builds JuleHygge WITH the "JuleHygge Kamera" camera extension (Xcode project, automatic signing with
# the Apple Development certificate) and installs it in /Applications — macOS only activates system
# extensions from there. Afterwards: menu > "Installér JuleHygge Kamera (baggrund i Teams)…".
#
# One-time prerequisite: this Mac must be registered as a device on the team (Xcode can't do that from
# the command line). Open JuleHygge.xcodeproj in Xcode > target JuleHygge > Signing & Capabilities and
# click "Register Device", or add the Mac's Provisioning UDID at developer.apple.com > Devices.
set -euo pipefail
cd "${0:A:h}"
python3 tools/make-xcodeproj.py
# app icon, drawn by the plain build (the Xcode build copies it in)
swift build -c release >/dev/null
rm -rf build/JuleHygge.iconset; mkdir -p build/JuleHygge.iconset
"$(swift build -c release --show-bin-path)/JuleHygge" --icon build/JuleHygge.iconset
iconutil -c icns build/JuleHygge.iconset -o build/JuleHygge.icns
LOG=build/xcodebuild.log
mkdir -p build
if ! xcodebuild -project JuleHygge.xcodeproj -target JuleHygge -configuration Release -allowProvisioningUpdates \
        SYMROOT="$PWD/build/xcode" build > "$LOG" 2>&1; then
    grep -E "error:|failed" "$LOG" | head -20
    echo "Bygget fejlede — intet er installeret (fuld log: $LOG)"
    exit 1
fi
APP=build/xcode/Release/JuleHygge.app
codesign --verify --deep --strict "$APP" || { echo "Signaturen er ikke gyldig — intet er installeret"; exit 1; }

osascript -e 'tell application id "dk.julehygge.JuleHygge" to quit' 2>/dev/null || true
sleep 1
pkill -x JuleHygge 2>/dev/null || true
# The older copy in ~/Applications (from install.sh) is replaced by the one in /Applications.
if [[ -d "$HOME/Applications/JuleHygge.app" ]]; then
    "$HOME/Applications/JuleHygge.app/Contents/MacOS/JuleHygge" --unregister-login || true
    rm -rf "$HOME/Applications/JuleHygge.app"
fi
rm -rf /Applications/JuleHygge.app
cp -R "$APP" /Applications/JuleHygge.app
/Applications/JuleHygge.app/Contents/MacOS/JuleHygge --register-login || true
open /Applications/JuleHygge.app
echo "Installeret: /Applications/JuleHygge.app — vælg 'Installér JuleHygge Kamera' i menuen"
