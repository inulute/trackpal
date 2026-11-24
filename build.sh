#!/bin/sh
# Builds Bizzy.app (a menu bar app with no Dock icon), for Apple Silicon and Intel Macs.
#
#   ./build.sh            build build/Bizzy.app
#   ./build.sh run        build, then open it
#   ./build.sh release    build, then zip it to dist/Bizzy.zip (the file install.sh downloads)
#
# It's a real .app (not a bare binary) so macOS can give it its own permissions (microphone, speech,
# Accessibility). Ad-hoc signed, not notarized.
set -e
cd "$(dirname "$0")"
[ "$(uname -s)" = "Darwin" ] || { echo "macOS only."; exit 1; }
xcode-select -p >/dev/null 2>&1 || { echo "Install the Command Line Tools first: xcode-select --install"; exit 1; }

app=build/Bizzy.app
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" build
echo "compiling for Apple Silicon…"
swiftc -O -swift-version 5 -target arm64-apple-macos13 Sources/*.swift -o build/Bizzy-arm64
echo "compiling for Intel…"
swiftc -O -swift-version 5 -target x86_64-apple-macos13 Sources/*.swift -o build/Bizzy-x86_64
lipo -create build/Bizzy-arm64 build/Bizzy-x86_64 -output "$app/Contents/MacOS/Bizzy"
cp Info.plist "$app/Contents/Info.plist"
# A stable designated requirement (the bundle ID) keeps permissions across rebuilds more often than a bare
# ad-hoc signature does.
codesign -s - -f --identifier com.trackpal.bizzy -r='designated => identifier "com.trackpal.bizzy"' "$app" 2>/dev/null \
  || codesign -s - -f "$app"
echo "built $app ($(lipo -archs "$app/Contents/MacOS/Bizzy"))"

case "$1" in
  run)
    pkill -x Bizzy 2>/dev/null || true
    while pgrep -x Bizzy >/dev/null; do sleep 0.2; done   # let the old copy quit first
    open "$app"
    ;;
  release)
    mkdir -p dist
    rm -f dist/Bizzy.zip
    ditto -c -k --keepParent "$app" dist/Bizzy.zip
    echo "made dist/Bizzy.zip. Publish it with: gh release create v<version> dist/Bizzy.zip"
    ;;
esac
