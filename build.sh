#!/bin/sh
# Builds Pip.app (a menu bar app with no Dock icon).
#
#   ./build.sh          build build/Pip.app
#   ./build.sh run      build, then open it
#
# It's a real .app (not a bare binary) so macOS can give it its own Accessibility permission for the
# keyboard reactions. Ad-hoc signed, for this Mac only.
set -e
cd "$(dirname "$0")"
[ "$(uname -s)" = "Darwin" ] || { echo "macOS only."; exit 1; }
xcode-select -p >/dev/null 2>&1 || { echo "Install the Command Line Tools first: xcode-select --install"; exit 1; }

app=build/Pip.app
rm -rf "$app"
mkdir -p "$app/Contents/MacOS"
echo "compiling…"
swiftc -O -swift-version 5 -target "$(uname -m)-apple-macos13" Sources/*.swift -o "$app/Contents/MacOS/Pip"
cp Info.plist "$app/Contents/Info.plist"
# A stable designated requirement (the bundle ID) keeps the Accessibility grant across rebuilds
# more often than a bare ad-hoc signature does.
codesign -s - -f --identifier com.trackpadai.pip -r='designated => identifier "com.trackpadai.pip"' "$app" 2>/dev/null \
  || codesign -s - -f "$app"
echo "built $app"

if [ "$1" = "run" ]; then
  pkill -x Pip 2>/dev/null || true
  while pgrep -x Pip >/dev/null; do sleep 0.2; done   # let the old copy quit first
  open "$app"
fi
