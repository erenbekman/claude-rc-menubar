#!/bin/bash
set -euo pipefail

REPO="erenbekman/claude-rc-menubar"
APP_NAME="Claude RC"
BUNDLE_ID="com.safepluspay.claude-rc"
DEST="${INSTALL_DIR:-/Applications}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "==> Downloading the latest release"
curl -fsSL "https://github.com/$REPO/releases/latest/download/Claude-RC.zip" -o "$TMP/Claude-RC.zip"
ditto -x -k "$TMP/Claude-RC.zip" "$TMP"

if pgrep -x ClaudeRC >/dev/null; then
  echo "==> Quitting the running Claude RC"
  osascript -e "quit app id \"$BUNDLE_ID\"" >/dev/null 2>&1 || true
  for _ in $(seq 1 30); do
    pgrep -x ClaudeRC >/dev/null || break
    sleep 0.5
  done
fi

echo "==> Installing into $DEST"
mkdir -p "$DEST"
rm -rf "$DEST/$APP_NAME.app"
ditto "$TMP/$APP_NAME.app" "$DEST/$APP_NAME.app"
xattr -dr com.apple.quarantine "$DEST/$APP_NAME.app" 2>/dev/null || true

open "$DEST/$APP_NAME.app"
echo "==> Installed: $DEST/$APP_NAME.app"
