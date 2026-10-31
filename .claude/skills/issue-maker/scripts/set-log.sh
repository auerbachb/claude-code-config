#!/usr/bin/env bash
# Atomically apply a jq filter to an issue-maker session log,
# refreshing .last_updated_at in the same operation.
#
# Usage: set-log.sh LOG_FILE JQ_FILTER [jq-args...]
#
# All jq-args are forwarded verbatim to jq (e.g. --arg, --argjson).
# Serializes the full read/modify/write with the bundled state-lock library.
# jq guards therefore compare against current state while holding the lock.
# Exits nonzero on lock/write failure; leaves LOG_FILE unchanged on failure.
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

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
LOCK_LIB="$SCRIPT_DIR/../../../scripts/state-lock.sh"
[ -r "$LOCK_LIB" ] || { echo "ERROR: state-lock.sh missing beside the selected skill installation" >&2; exit 1; }
# shellcheck source=../../../scripts/state-lock.sh
source "$LOCK_LIB"
state_lock_acquire "$LOG" || exit "$STATE_LOCK_EXIT_TIMEOUT"
TMP=""
trap '[ -z "$TMP" ] || rm -f "$TMP"; state_lock_release' EXIT

NOW=$(date -u +'%Y-%m-%dT%H:%M:%SZ')
TMP=$(mktemp "${LOG}.tmp.XXXXXX")

if jq -e "$@" --arg __now "$NOW" "$FILTER | .last_updated_at = \$__now" "$LOG" > "$TMP"; then
  if ! jq -e -s 'length == 1 and (.[0] | type == "object")' "$TMP" >/dev/null || ! state_lock_assert_held || ! mv "$TMP" "$LOG"; then
    rm -f "$TMP"
    echo "WARN: failed to atomically replace session log: $LOG" >&2
    exit 1
  fi
else
  rm -f "$TMP"
  echo "WARN: failed to update session log ($FILTER)" >&2
  exit 1
fi
