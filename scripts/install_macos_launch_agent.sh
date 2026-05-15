#!/usr/bin/env bash
set -euo pipefail

LABEL="gov.nih.nichd.benchvault.backup"
HOUR="2"
MINUTE="0"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --hour)
      HOUR="${2:?missing value for --hour}"
      shift 2
      ;;
    --minute)
      MINUTE="${2:?missing value for --minute}"
      shift 2
      ;;
    --label)
      LABEL="${2:?missing value for --label}"
      shift 2
      ;;
    *)
      echo "Unknown option: $1" >&2
      exit 2
      ;;
  esac
done

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "This LaunchAgent installer is macOS-only." >&2
  exit 1
fi

if ! [[ "$HOUR" =~ ^[0-9]+$ ]] || (( HOUR < 0 || HOUR > 23 )); then
  echo "--hour must be an integer from 0 to 23." >&2
  exit 2
fi

if ! [[ "$MINUTE" =~ ^[0-9]+$ ]] || (( MINUTE < 0 || MINUTE > 59 )); then
  echo "--minute must be an integer from 0 to 59." >&2
  exit 2
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd -P)"
PLIST_DIR="$HOME/Library/LaunchAgents"
PLIST_PATH="$PLIST_DIR/$LABEL.plist"
LOG_DIR="$REPO_ROOT/local_credentials"
STDOUT_LOG="$LOG_DIR/launch_agent_stdout.log"
STDERR_LOG="$LOG_DIR/launch_agent_stderr.log"

mkdir -p "$PLIST_DIR" "$LOG_DIR"
chmod 700 "$LOG_DIR"

cat > "$PLIST_PATH" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "https://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>$LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>/usr/bin/env</string>
    <string>dart</string>
    <string>run</string>
    <string>tool/backup_once.dart</string>
  </array>
  <key>WorkingDirectory</key>
  <string>$REPO_ROOT</string>
  <key>StandardOutPath</key>
  <string>$STDOUT_LOG</string>
  <key>StandardErrorPath</key>
  <string>$STDERR_LOG</string>
  <key>StartCalendarInterval</key>
  <dict>
    <key>Hour</key>
    <integer>$HOUR</integer>
    <key>Minute</key>
    <integer>$MINUTE</integer>
  </dict>
  <key>RunAtLoad</key>
  <false/>
</dict>
</plist>
PLIST

chmod 600 "$PLIST_PATH"

launchctl bootout "gui/$(id -u)" "$PLIST_PATH" >/dev/null 2>&1 || true
launchctl bootstrap "gui/$(id -u)" "$PLIST_PATH"
launchctl enable "gui/$(id -u)/$LABEL"

echo "Installed $LABEL"
echo "Schedule: daily at $(printf '%02d:%02d' "$HOUR" "$MINUTE")"
echo "Plist: $PLIST_PATH"
echo "Logs: $STDOUT_LOG and $STDERR_LOG"
