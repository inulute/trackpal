#!/bin/sh
# Builds Pip.app (a menu bar app with no Dock icon), for Apple Silicon and Intel Macs.
#
#   ./build.sh            build build/Pip.app
#   ./build.sh run        build, then open it
#   ./build.sh release    build, then zip it to dist/Pip.zip (the file install.sh downloads)
#
# It's a real .app (not a bare binary) so macOS can give it its own permissions (microphone, speech,
# Accessibility). Ad-hoc signed, not notarized.
set -e
cd "$(dirname "$0")"
[ "$(uname -s)" = "Darwin" ] || { echo "macOS only."; exit 1; }
xcode-select -p >/dev/null 2>&1 || { echo "Install the Command Line Tools first: xcode-select --install"; exit 1; }

app=build/Pip.app
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" build
echo "compiling for Apple Silicon…"
swiftc -O -swift-version 5 -target arm64-apple-macos13 Sources/*.swift -o build/Pip-arm64
echo "compiling for Intel…"
swiftc -O -swift-version 5 -target x86_64-apple-macos13 Sources/*.swift -o build/Pip-x86_64
lipo -create build/Pip-arm64 build/Pip-x86_64 -output "$app/Contents/MacOS/Pip"
cp Info.plist "$app/Contents/Info.plist"
# A stable designated requirement (the bundle ID) keeps permissions across rebuilds more often than a bare
# ad-hoc signature does.
codesign -s - -f --identifier com.trackpadai.pip -r='designated => identifier "com.trackpadai.pip"' "$app" 2>/dev/null \
  || codesign -s - -f "$app"
echo "built $app ($(lipo -archs "$app/Contents/MacOS/Pip"))"

case "$1" in
  run)
    pkill -x Pip 2>/dev/null || true
    while pgrep -x Pip >/dev/null; do sleep 0.2; done   # let the old copy quit first
    open "$app"
    ;;
  release)
    mkdir -p dist
    rm -f dist/Pip.zip
    ditto -c -k --keepParent "$app" dist/Pip.zip
    echo "made dist/Pip.zip. Publish it with: gh release create v<version> dist/Pip.zip"
    ;;
esac
