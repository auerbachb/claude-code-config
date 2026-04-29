#!/bin/bash
# Uninstall the macOS launchd watchdog for Claude heartbeat files.
#
# macOS-only v1. Linux/systemd support is intentionally out of scope.

set -euo pipefail

LABEL="com.user.claude-silence-watchdog"
PLIST_DEST="$HOME/Library/LaunchAgents/${LABEL}.plist"
STATE_FILE="$HOME/.claude/logs/watchdog-state.json"

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "claude-silence-watchdog is macOS-only in v1; Linux support is out of scope."
  exit 0
fi

remove_state=false
if [[ "${1:-}" == "--remove-state" ]]; then
  remove_state=true
elif [[ $# -gt 0 ]]; then
  echo "Usage: $0 [--remove-state]" >&2
  exit 1
fi

echo "Unloading ${LABEL}..."
launchctl bootout "gui/$(id -u)/${LABEL}" 2>/dev/null || true
launchctl bootout "gui/$(id -u)" "$PLIST_DEST" 2>/dev/null || true

echo "Removing LaunchAgent plist..."
rm -f "$PLIST_DEST"

if [[ "$remove_state" == true ]]; then
  echo "Removing watchdog state file..."
  rm -f "$STATE_FILE"
fi

if launchctl list | grep -q "$LABEL"; then
  echo "FAIL: ${LABEL} still appears in launchctl list." >&2
  exit 1
fi

echo "PASS: ${LABEL} unloaded and plist removed."
if [[ "$remove_state" != true && -f "$STATE_FILE" ]]; then
  echo "State file retained at ${STATE_FILE}; rerun with --remove-state to remove it."
fi
