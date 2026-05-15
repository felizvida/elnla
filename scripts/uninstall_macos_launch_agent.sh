#!/usr/bin/env bash
set -euo pipefail

LABEL="${1:-gov.nih.nichd.benchvault.backup}"
PLIST_PATH="$HOME/Library/LaunchAgents/$LABEL.plist"

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "This LaunchAgent uninstaller is macOS-only." >&2
  exit 1
fi

launchctl bootout "gui/$(id -u)" "$PLIST_PATH" >/dev/null 2>&1 || true
rm -f "$PLIST_PATH"

echo "Uninstalled $LABEL"
