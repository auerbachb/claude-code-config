#!/bin/bash
# uninstall-config-sync.sh — remove the launchd LaunchAgent installed by
# catalog: scheduling-monitoring — Unload and remove the config-sync LaunchAgent; `--remove-state` also drops its state, logs and marker
# install-config-sync.sh (issue #1524).
#
# macOS-only, mirroring uninstall-silence-watchdog.sh. A no-op with exit 0 on
# any other platform, so a shared dotfiles teardown can call it unconditionally.
#
# Usage: uninstall-config-sync.sh [--remove-state] [--help]
#
#   --remove-state   Also delete the durable sync state, run log, event log and
#                    the restart/failure marker. Off by default: the state is
#                    the record of what the job did, and a reinstall should pick
#                    up where it left off.
#   --help           Print this usage and exit 0
#
# EXIT CODES
#   0  unloaded and removed (also the non-macOS no-op)
#   1  the job still appears in launchctl list after the bootout
#   2  usage error
#
# DEPENDENCIES
#   bash, launchctl, id, rm (all base macOS)

set -euo pipefail

LABEL="com.user.claude-config-sync"

usage() {
  cat <<'EOF'
Usage: uninstall-config-sync.sh [--remove-state] [--help]

  Unloads and removes the com.user.claude-config-sync LaunchAgent installed by
  install-config-sync.sh. A no-op with exit 0 on non-macOS hosts.

OPTIONS
  --remove-state   Also delete the sync state, logs, and restart/failure marker
  --help           Print this usage and exit 0

EXIT CODES
  0  unloaded and removed, or a non-macOS no-op
  1  the job still appears in launchctl list after the bootout
  2  usage error
EOF
}

# Captured before the parsing loop shifts them away — the telemetry line below
# is meant to record what the caller actually passed.
ORIGINAL_ARGS="$*"

remove_state=false
while (( $# > 0 )); do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --remove-state) remove_state=true ;;
    *)
      echo "uninstall-config-sync.sh: unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
  shift
done

# Platform check BEFORE any $HOME expansion: on a non-Darwin host with HOME
# unset, `set -u` would abort at PLIST_DEST below instead of taking this
# documented exit-0 path (issue #1430).
if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "claude-config-sync is macOS-only; nothing to uninstall on this platform."
  exit 0
fi

printf '%s\t%s\t%s\n' "$(date -u +%FT%TZ)" "$(basename "$0")" "${ORIGINAL_ARGS//$'\n'/ }" 2>/dev/null >> "$HOME/.claude/script-usage.log" || true

PLIST_DEST="$HOME/Library/LaunchAgents/${LABEL}.plist"
STATE_FILE="$HOME/.claude/logs/claude-config-sync-state.json"
LOG_FILE="$HOME/.claude/logs/claude-config-sync.log"
EVENTS_FILE="$HOME/.claude/logs/claude-config-sync-events.jsonl"
# Written by launchd from the plist's StandardOutPath / StandardErrorPath keys.
# Keep these in step with com.user.claude-config-sync.plist.
LAUNCHD_OUT_LOG="$HOME/.claude/logs/config-sync-stdout.log"
LAUNCHD_ERR_LOG="$HOME/.claude/logs/config-sync-stderr.log"
MARKER_FILE="$HOME/.claude/sync-restart-recommended.json"

echo "Unloading ${LABEL}..."
launchctl bootout "gui/$(id -u)/${LABEL}" 2>/dev/null || true
launchctl bootout "gui/$(id -u)" "$PLIST_DEST" 2>/dev/null || true

echo "Removing LaunchAgent plist..."
rm -f "$PLIST_DEST"

if [[ "$remove_state" == true ]]; then
  echo "Removing sync state, logs and marker..."
  # LAUNCHD_OUT_LOG / LAUNCHD_ERR_LOG are written by launchd itself, from the
  # StandardOutPath and StandardErrorPath keys in the plist — not by the sync
  # script — so they are easy to miss here. Leaving them behind contradicts the
  # "logs" this flag promises to remove.
  rm -f "$STATE_FILE" "$LOG_FILE" "$EVENTS_FILE" "$MARKER_FILE" \
        "$LAUNCHD_OUT_LOG" "$LAUNCHD_ERR_LOG"
fi

# Capture first, match from a here-string — a `launchctl list | grep -q` pipeline
# reports failure on a SUCCESSFUL match under pipefail (see the note in
# install-config-sync.sh). Capture the command's OWN status too: swallowing a
# failed `launchctl list` as an empty listing would print PASS below without
# having verified anything — fail closed instead.
launchctl_rc=0
launchctl_list="$(launchctl list 2>/dev/null)" || launchctl_rc=$?
if (( launchctl_rc != 0 )); then
  echo "FAIL: could not verify the unload — 'launchctl list' itself failed (rc=$launchctl_rc). The plist is removed, but ${LABEL} may still be loaded; check with: launchctl list" >&2
  exit 1
fi
# Whole-label match, for the same reason as the install-side check: the label is
# the last field of "PID<TAB>Status<TAB>Label", and a substring grep would let an
# unrelated agent whose label merely contains ours report this teardown as
# failed. Comparing the field literally also avoids escaping the label's dots.
if awk -v want="$LABEL" '$NF == want { found = 1 } END { exit !found }' <<< "$launchctl_list"; then
  echo "FAIL: ${LABEL} still appears in launchctl list." >&2
  exit 1
fi

echo "PASS: ${LABEL} unloaded and plist removed."
if [[ "$remove_state" != true && -f "$STATE_FILE" ]]; then
  echo "State retained at ${STATE_FILE}; rerun with --remove-state to remove it."
fi
