#!/bin/bash
# uninstall-backfill-review.sh — remove the launchd LaunchAgent installed by
# install-backfill-review.sh (issue #1941).
# catalog: scheduling-monitoring — Unload and remove the backfill-review LaunchAgent; always keeps the ledger (`~/.claude/unreviewed-merges.json`), locks and logs
#
# macOS-only. Unlike uninstall-config-sync.sh it exits 1 on any other platform
# (issue #1941 AC): there is no launchd job there to remove, and a silent
# success would hide a teardown aimed at the wrong machine.
#
# The ledger at ~/.claude/unreviewed-merges.json is never touched: it is the
# record of which merges still need a review, written by the no-review override
# whether or not this job is scheduled. There is deliberately no --remove-state.
#
# Usage: uninstall-backfill-review.sh [--help]
#
# EXIT CODES
#   0  unloaded and removed
#   1  not macOS, or the job still appears in launchctl list after the bootout
#   2  usage error
#
# DEPENDENCIES
#   bash, launchctl, id, rm (all base macOS)

set -euo pipefail

LABEL="com.user.claude-backfill-review"

usage() {
  cat <<'EOF'
Usage: uninstall-backfill-review.sh [--help]

  Unloads and removes the com.user.claude-backfill-review LaunchAgent installed
  by install-backfill-review.sh. The ledger (~/.claude/unreviewed-merges.json),
  its locks and the logs are always kept.

OPTIONS
  --help   Print this usage and exit 0

EXIT CODES
  0  unloaded and removed
  1  not macOS, or the job still appears in launchctl list after the bootout
  2  usage error
EOF
}

# Captured before the parsing loop shifts them away — the telemetry line below
# is meant to record what the caller actually passed.
ORIGINAL_ARGS="$*"

while (( $# > 0 )); do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    *)
      echo "uninstall-backfill-review.sh: unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
  shift
done

# Platform check BEFORE any $HOME expansion (issue #1430).
if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "FAIL: the backfill-review LaunchAgent is macOS-only (launchd); nothing to uninstall here." >&2
  exit 1
fi

printf '%s\t%s\t%s\n' "$(date -u +%FT%TZ)" "$(basename "$0")" "${ORIGINAL_ARGS//$'\n'/ }" 2>/dev/null >> "$HOME/.claude/script-usage.log" || true

PLIST_DEST="$HOME/Library/LaunchAgents/${LABEL}.plist"
LEDGER_FILE="$HOME/.claude/unreviewed-merges.json"

echo "Unloading ${LABEL}..."
launchctl bootout "gui/$(id -u)/${LABEL}" 2>/dev/null || true
launchctl bootout "gui/$(id -u)" "$PLIST_DEST" 2>/dev/null || true

echo "Removing LaunchAgent plist..."
rm -f "$PLIST_DEST"

# Fail closed on an unverifiable listing, and match the whole label as the last
# field — both for the reasons given in uninstall-config-sync.sh.
launchctl_rc=0
launchctl_list="$(launchctl list 2>/dev/null)" || launchctl_rc=$?
if (( launchctl_rc != 0 )); then
  echo "FAIL: could not verify the unload — 'launchctl list' itself failed (rc=$launchctl_rc). The plist is removed, but ${LABEL} may still be loaded; check with: launchctl list" >&2
  exit 1
fi
if awk -v want="$LABEL" '$NF == want { found = 1 } END { exit !found }' <<< "$launchctl_list"; then
  echo "FAIL: ${LABEL} still appears in launchctl list." >&2
  exit 1
fi

echo "PASS: ${LABEL} unloaded and plist removed."
if [[ -f "$LEDGER_FILE" ]]; then
  echo "Ledger kept at ${LEDGER_FILE}."
fi
