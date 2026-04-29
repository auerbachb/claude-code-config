#!/bin/bash
# Install the macOS launchd watchdog that monitors Claude heartbeat files.

set -euo pipefail
printf '%s\t%s\t%s\n' "$(date -u +%FT%TZ)" "$(basename "$0")" "${*//$'\n'/ }" >> "$HOME/.claude/script-usage.log"

LABEL="com.user.claude-silence-watchdog"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEMPLATE_PLIST="$SCRIPT_DIR/${LABEL}.plist"
LAUNCH_AGENTS_DIR="$HOME/Library/LaunchAgents"
INSTALLED_PLIST="$LAUNCH_AGENTS_DIR/${LABEL}.plist"
LOG_DIR="$HOME/.claude/logs"
GUI_DOMAIN="gui/$(id -u)"

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "FAIL: silence watchdog v1 is macOS-only (launchd + osascript). Linux support is out of scope." >&2
  exit 1
fi

if [[ ! -f "$TEMPLATE_PLIST" ]]; then
  echo "FAIL: plist template not found: $TEMPLATE_PLIST" >&2
  exit 1
fi

if [[ ! -x "$SCRIPT_DIR/silence-watchdog.sh" ]]; then
  chmod +x "$SCRIPT_DIR/silence-watchdog.sh"
fi

mkdir -p "$LOG_DIR" "$LAUNCH_AGENTS_DIR"

escape_sed_replacement() {
  printf '%s' "$1" | sed 's/[&#]/\\&/g'
}

xml_escape() {
  local value="$1"
  value="${value//&/&amp;}"
  value="${value//</&lt;}"
  value="${value//>/&gt;}"
  printf '%s' "$value"
}

ESCAPED_SCRIPT_PATH="$(escape_sed_replacement "$(xml_escape "$SCRIPT_DIR/silence-watchdog.sh")")"
ESCAPED_HOME="$(escape_sed_replacement "$(xml_escape "$HOME")")"

sed \
  -e "s#__SHELL__#/bin/bash#g" \
  -e "s#__SCRIPT_PATH__#$ESCAPED_SCRIPT_PATH#g" \
  -e "s#__HOME__#$ESCAPED_HOME#g" \
  "$TEMPLATE_PLIST" > "$INSTALLED_PLIST"

# Idempotently unload an existing instance before bootstrapping the new plist.
launchctl bootout "$GUI_DOMAIN/$LABEL" >/dev/null 2>&1 || true
launchctl bootstrap "$GUI_DOMAIN" "$INSTALLED_PLIST"
launchctl enable "$GUI_DOMAIN/$LABEL" >/dev/null 2>&1 || true
launchctl kickstart -k "$GUI_DOMAIN/$LABEL" >/dev/null 2>&1 || true

if launchctl list | grep -q "$LABEL"; then
  echo "PASS: $LABEL is running."
  echo "Verify with: launchctl list | grep claude-silence-watchdog"
else
  echo "FAIL: $LABEL did not appear in launchctl list after install." >&2
  exit 1
fi
