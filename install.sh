#!/bin/sh
# Installs Bizzy, the desk pet that talks through your trackpad, and opens it.
#
#   curl -fsSL https://raw.githubusercontent.com/inulute/trackpal/main/install.sh | sh
#
# It installs one app, ~/Applications/Bizzy.app. To uninstall:
#   curl -fsSL https://raw.githubusercontent.com/inulute/trackpal/main/install.sh | sh -s -- --uninstall
set -e

fail() {
    printf '\n  trackpal: %s\n\n' "$1" >&2
    exit 1
}

[ "$(uname -s)" = "Darwin" ] || fail "this runs on macOS only (it talks through a Mac's trackpad)."
major=$(sw_vers -productVersion | cut -d. -f1)
[ "$major" -ge 13 ] || fail "Bizzy needs macOS 13 or later."

dest="$HOME/Applications"
app="$dest/Bizzy.app"

quit() {
    for name in "$@"; do
        pkill -x "$name" 2>/dev/null || true
        while pgrep -x "$name" >/dev/null; do sleep 0.2; done
    done
}

if [ "$1" = "--uninstall" ]; then
    quit Bizzy Pip
    rm -rf "$app" "$dest/Pip.app" "$HOME/.trackpal" "$HOME/.trackpadai"
    defaults delete com.trackpal.bizzy >/dev/null 2>&1 || true
    defaults delete com.trackpadai.pip >/dev/null 2>&1 || true
    echo "removed Bizzy, its settings, its memory and any saved API keys."
    exit 0
fi

url="https://github.com/inulute/trackpal/releases/latest/download/Bizzy.zip"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

echo "downloading Bizzy…"
curl -fsSL "$url" -o "$tmp/Bizzy.zip" \
    || fail "the download failed. Check your connection, or get it from github.com/inulute/trackpal/releases"
ditto -x -k "$tmp/Bizzy.zip" "$tmp"
[ -d "$tmp/Bizzy.app" ] || fail "the download didn't contain Bizzy.app."

# Replace an older copy, including the pet's old name (Pip), quitting it first.
quit Bizzy Pip
rm -rf "$dest/Pip.app"
if [ -d "$HOME/.trackpadai" ] && [ ! -e "$HOME/.trackpal" ]; then
    mv "$HOME/.trackpadai" "$HOME/.trackpal"     # keep saved API keys
fi
mkdir -p "$dest"
rm -rf "$app"
mv "$tmp/Bizzy.app" "$app"
# Downloaded with curl it isn't quarantined, but clear the flag in case something added it.
xattr -dr com.apple.quarantine "$app" 2>/dev/null || true
echo "installed ~/Applications/Bizzy.app"

open "$app"
cat <<'MSG'

  Bizzy is on your screen (bottom right).
  - Say "Hey Bizzy" to talk to it. Allow the microphone when macOS asks.
  - Right-click Bizzy for its menu: voices, brains (add a free Gemini key), quit.
  - For the trackpad voice: mute your Mac, put it on a table, hands off the glass.

MSG
