#!/bin/sh
# Installs Pip, the desk pet that talks through your trackpad, and opens it.
#
#   curl -fsSL https://raw.githubusercontent.com/inulute/trackpal/main/install.sh | sh
#
# It installs one app, ~/Applications/Pip.app. To uninstall:
#   curl -fsSL https://raw.githubusercontent.com/inulute/trackpal/main/install.sh | sh -s -- --uninstall
set -e

fail() {
    printf '\n  trackpal: %s\n\n' "$1" >&2
    exit 1
}

[ "$(uname -s)" = "Darwin" ] || fail "this runs on macOS only (it talks through a Mac's trackpad)."
major=$(sw_vers -productVersion | cut -d. -f1)
[ "$major" -ge 13 ] || fail "Pip needs macOS 13 or later."

dest="$HOME/Applications"
app="$dest/Pip.app"

if [ "$1" = "--uninstall" ]; then
    pkill -x Pip 2>/dev/null || true
    rm -rf "$app" "$HOME/.trackpadai"
    defaults delete com.trackpadai.pip >/dev/null 2>&1 || true
    echo "removed Pip, its settings, its memory and any saved API keys."
    exit 0
fi

url="https://github.com/inulute/trackpal/releases/latest/download/Pip.zip"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

echo "downloading Pip…"
curl -fsSL "$url" -o "$tmp/Pip.zip" \
    || fail "the download failed. Check your connection, or get it from github.com/inulute/trackpal/releases"
ditto -x -k "$tmp/Pip.zip" "$tmp"
[ -d "$tmp/Pip.app" ] || fail "the download didn't contain Pip.app."

# Replace an older copy (quit it first so it isn't running from a deleted folder).
pkill -x Pip 2>/dev/null || true
while pgrep -x Pip >/dev/null; do sleep 0.2; done
mkdir -p "$dest"
rm -rf "$app"
mv "$tmp/Pip.app" "$app"
# Downloaded with curl it isn't quarantined, but clear the flag in case something added it.
xattr -dr com.apple.quarantine "$app" 2>/dev/null || true
echo "installed ~/Applications/Pip.app"

open "$app"
cat <<'EOF'

  Pip is on your screen (bottom right).
  - Say "Hey Pip" to talk to it. Allow the microphone when macOS asks.
  - Right-click Pip for its menu: voices, brains (add a free Gemini key), quit.
  - For the trackpad voice: mute your Mac, put it on a table, hands off the glass.

EOF
