#!/bin/zsh
# Builds JuleHygge, installs it in ~/Applications and turns on "Start ved login".
# The login item points at the installed copy, so later builds in build/ do not break it.
set -euo pipefail
cd "${0:A:h}"
./build.sh
DEST="$HOME/Applications/JuleHygge.app"
pkill -x JuleHygge 2>/dev/null || true
sleep 1
mkdir -p "$HOME/Applications"
rm -rf "$DEST"
cp -R build/JuleHygge.app "$DEST"
open "$DEST" --args --login=on
echo "Installeret: $DEST (start ved login er slået til)"
