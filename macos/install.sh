#!/bin/zsh
# Builds JuleHygge, installs it in ~/Applications and turns on "Start ved login".
# The login item points at the installed copy, so later builds in build/ do not break it.
set -euo pipefail
cd "${0:A:h}"
./build.sh
DEST="$HOME/Applications/JuleHygge.app"
osascript -e 'tell application id "dk.julehygge.JuleHygge" to quit' 2>/dev/null || true
sleep 1
pkill -x JuleHygge 2>/dev/null || true
sleep 1
mkdir -p "$HOME/Applications"
rm -rf "$DEST"
cp -R build/JuleHygge.app "$DEST"
# Plain login item; the app's own supervisor restarts it after a crash.
"$DEST/Contents/MacOS/JuleHygge" --register-login || echo "Kunne ikke slå start ved login til (se Systemindstillinger > Generelt > Login-emner)"
open "$DEST"
echo "Installeret: $DEST (start ved login og genstart efter crash er slået til)"
