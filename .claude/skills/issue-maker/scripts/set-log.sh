#!/usr/bin/env bash
# Atomically apply a jq filter to an issue-maker session log,
# refreshing .last_updated_at in the same operation.
#
# Usage: set-log.sh LOG_FILE JQ_FILTER [jq-args...]
#
# All jq-args are forwarded verbatim to jq (e.g. --arg, --argjson).
# Exits 1 if the write fails; leaves LOG_FILE unchanged on failure.
#
# Example:
#   set-log.sh "$LOG" '.mode = $v' --arg v rapid-fire
#   set-log.sh "$LOG" '.target_repo = $v' --arg v "owner/repo"

set -euo pipefail

if (( $# < 2 )); then
  echo "Usage: set-log.sh LOG_FILE JQ_FILTER [jq-args...]" >&2
  exit 2
fi

LOG="$1"; shift
FILTER="$1"; shift

# A missing log is the loudest symptom of a session key that moved mid-batch
# (issue #1572): jq would fail here anyway, but naming the path turns "the write
# failed" into "the write went to a log that does not exist". Exit code
# unchanged — 1, the same non-zero every other write failure returns.
if [ ! -f "$LOG" ]; then
  echo "WARN: failed to update session log ($FILTER) — no such log file: $LOG" >&2
  exit 1
fi

NOW=$(date -u +'%Y-%m-%dT%H:%M:%SZ')
TMP=$(mktemp)

if jq "$@" --arg __now "$NOW" "$FILTER | .last_updated_at = \$__now" "$LOG" > "$TMP"; then
  mv "$TMP" "$LOG"
else
  rm -f "$TMP"
  echo "WARN: failed to update session log ($FILTER)" >&2
  exit 1
fi
