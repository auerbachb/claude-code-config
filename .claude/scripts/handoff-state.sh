#!/usr/bin/env bash
# handoff-state.sh — Locked read/write helper for ~/.claude/handoffs/pr-{N}-handoff.json.
#
# PURPOSE
#   Serializes the WHOLE read-modify-write cycle of every writer that touches
#   a per-PR handoff file (issue #682 — follow-up to #639). Without this lock
#   two concurrent orchestrators (/babysit-pr, /pr-monitor-and-manage, Phase B
#   subagents) can each read, each append, and each write back, silently losing
#   one of the two appends. The individual write was already atomic (mktemp + mv
#   in polling-state-gate.sh), but the surrounding RMW cycle was not protected.
#
#   This helper is the SINGLE WRITE PATH for all handoff writers. Every writer
#   — polling-state-gate.sh, dismiss-stale-bot-changes.sh, Phase A/B agent
#   prompts, parent/wrap deletes — routes through this script so only one lock
#   path exists. A lock only one writer respects is not a lock (lesson from #639).
#
# USAGE
#   handoff-state.sh --get    <pr_number>                     # lock-free read
#   handoff-state.sh --create <pr_number> <json-body>         # locked create/overwrite
#   handoff-state.sh --set    <pr_number> <jq-path>=<value>   # locked scalar update
#   handoff-state.sh --append <pr_number> <field> <value>     # locked array append
#   handoff-state.sh --delete <pr_number>                     # locked delete
#
# CONCURRENCY MODEL
#   The lock is a `mkdir`-based advisory lock directory at
#   <handoff-file>.lock/, reusing the same state-lock.sh library as
#   session-state.sh (#639). Every writer acquires state_lock_acquire before
#   reading the file; the mv back is already atomic. Reads (--get, Phase C,
#   require_handoff_and_state) are lock-free because mv is atomic on POSIX.
#
#   Lock path: ~/.claude/handoffs/pr-{N}-handoff.json.lock/
#   Same stale-holder recovery (dead pid, age > STALE_AGE), timeout
#   (CLAUDE_STATE_LOCK_TIMEOUT, default 30s), and re-entrancy rules as the
#   parent library. Full contract: state-lock.sh header.
#
#   A writer that cannot acquire the lock exits STATE_LOCK_EXIT_TIMEOUT (6)
#   having written nothing — treat 6 as "unchanged, retry".
#
# KNOWN LIMITATION
#   The handoff file name is still global (issue #655 — two repos at the same PR
#   number share one file). That scoping gap is deliberately deferred; the
#   write-lock is correct within the current single-name scheme.
#
# DEDUP CONTRACT (from handoff-files.md)
#   --append enforces:
#     • String arrays: dedup by exact value (unique elements).
#     • findings_dismissed: dedup by .id (object identity).
#   Unknown fields are always preserved (forward compatibility).
#
# EXIT CODES
#   0  Success.
#   2  Usage error (missing args, unknown flag, malformed path=value).
#   3  Handoff file not found (--get only; other modes create/seed from {}).
#   4  jq parse or evaluation failure.
#   5  Write failure (mktemp / mv).
#   6  Lock timeout (STATE_LOCK_EXIT_TIMEOUT from state-lock.sh).
#
# DEPENDENCIES
#   jq, mktemp, mv (POSIX), .claude/scripts/state-lock.sh (sibling library).

set -uo pipefail
printf '%s\t%s\t%s\n' "$(date -u +%FT%TZ)" "$(basename "$0")" "${*//$'\n'/ }" \
  >> "${HOME}/.claude/script-usage.log" 2>/dev/null || true

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LOCK_LIB="${SCRIPT_DIR}/state-lock.sh"
HANDOFF_DIR="${HOME}/.claude/handoffs"

# ---------------------------------------------------------------------------
# Load the lock library (required for all write paths).
# ---------------------------------------------------------------------------
if [[ ! -f "$LOCK_LIB" ]]; then
  echo "handoff-state.sh: state-lock.sh not found at $LOCK_LIB" >&2
  exit 5
fi
# shellcheck source=state-lock.sh
source "$LOCK_LIB"

# ---------------------------------------------------------------------------
# Argument parsing.
# ---------------------------------------------------------------------------
MODE=""
PR_NUMBER=""
JQ_PATH_VALUE=""
ARRAY_FIELD=""
ARRAY_VALUE=""
JSON_BODY=""

print_usage() {
  sed -n '2,60p' "$0" | sed 's/^# \{0,1\}//'
}

if [[ $# -eq 0 ]]; then
  print_usage >&2; exit 2
fi

case "$1" in
  --get)
    MODE="get"
    PR_NUMBER="${2:-}"
    if [[ -z "$PR_NUMBER" ]]; then
      echo "handoff-state.sh: --get requires <pr_number>" >&2; exit 2
    fi
    ;;
  --create)
    MODE="create"
    PR_NUMBER="${2:-}"
    JSON_BODY="${3:-}"
    if [[ -z "$PR_NUMBER" || -z "$JSON_BODY" ]]; then
      echo "handoff-state.sh: --create requires <pr_number> <json-body>" >&2; exit 2
    fi
    ;;
  --set)
    MODE="set"
    PR_NUMBER="${2:-}"
    JQ_PATH_VALUE="${3:-}"
    if [[ -z "$PR_NUMBER" || -z "$JQ_PATH_VALUE" ]]; then
      echo "handoff-state.sh: --set requires <pr_number> <jq-path>=<value>" >&2; exit 2
    fi
    if [[ "$JQ_PATH_VALUE" != *"="* ]]; then
      echo "handoff-state.sh: --set argument must contain '=': $JQ_PATH_VALUE" >&2; exit 2
    fi
    ;;
  --append)
    MODE="append"
    PR_NUMBER="${2:-}"
    ARRAY_FIELD="${3:-}"
    ARRAY_VALUE="${4:-}"
    if [[ -z "$PR_NUMBER" || -z "$ARRAY_FIELD" || -z "$ARRAY_VALUE" ]]; then
      echo "handoff-state.sh: --append requires <pr_number> <field> <value>" >&2; exit 2
    fi
    ;;
  --delete)
    MODE="delete"
    PR_NUMBER="${2:-}"
    if [[ -z "$PR_NUMBER" ]]; then
      echo "handoff-state.sh: --delete requires <pr_number>" >&2; exit 2
    fi
    ;;
  -h|--help)
    print_usage; exit 0
    ;;
  *)
    echo "handoff-state.sh: unknown mode: $1" >&2; exit 2
    ;;
esac

if ! [[ "$PR_NUMBER" =~ ^[0-9]+$ ]]; then
  echo "handoff-state.sh: pr_number must be a positive integer (got: $PR_NUMBER)" >&2; exit 2
fi

HANDOFF_FILE="${HANDOFF_DIR}/pr-${PR_NUMBER}-handoff.json"

# ---------------------------------------------------------------------------
# --get: lock-free read (mv is atomic on POSIX, so readers always see a
# complete document — never a partial write). Matches the read-doesn't-lock
# rule from session-state.sh and handoff-files.md.
# ---------------------------------------------------------------------------
if [[ "$MODE" == "get" ]]; then
  if [[ ! -f "$HANDOFF_FILE" ]]; then
    echo "handoff-state.sh: handoff file not found: $HANDOFF_FILE" >&2; exit 3
  fi
  cat "$HANDOFF_FILE"
  exit 0
fi

# ---------------------------------------------------------------------------
# All write modes: ensure the directory exists, then acquire the lock.
# ---------------------------------------------------------------------------
mkdir -p "$HANDOFF_DIR"

state_lock_acquire "$HANDOFF_FILE" || exit "$STATE_LOCK_EXIT_TIMEOUT"

# Atomic write using a same-directory temp so mv is on the same filesystem
# (the POSIX guarantee that mv is atomic only holds within one filesystem).
# The lock is already held, so competing writers are serialized before they
# reach this helper — the same-dir mktemp is belt-and-suspenders atomicity.
_atomic_write() {
  local content="$1"
  local tmp
  tmp="$(mktemp "${HANDOFF_DIR}/.pr-${PR_NUMBER}-handoff.XXXXXX")" || {
    echo "handoff-state.sh: mktemp failed in ${HANDOFF_DIR}" >&2
    state_lock_release
    exit 5
  }
  printf '%s\n' "$content" > "$tmp" || {
    rm -f "$tmp" 2>/dev/null || true
    echo "handoff-state.sh: write to temp file failed" >&2
    state_lock_release
    exit 5
  }
  if ! mv "$tmp" "$HANDOFF_FILE"; then
    rm -f "$tmp" 2>/dev/null || true
    echo "handoff-state.sh: mv to $HANDOFF_FILE failed" >&2
    state_lock_release
    exit 5
  fi
}

# ---------------------------------------------------------------------------
# --create: create or overwrite the handoff file with the supplied JSON body.
# ---------------------------------------------------------------------------
if [[ "$MODE" == "create" ]]; then
  if ! printf '%s\n' "$JSON_BODY" | jq -e . >/dev/null 2>&1; then
    echo "handoff-state.sh: --create body is not valid JSON" >&2
    state_lock_release; exit 4
  fi
  _atomic_write "$JSON_BODY"
  state_lock_release; exit 0
fi

# ---------------------------------------------------------------------------
# --delete: lock-guarded delete to prevent a delete from racing a still-running
# writer on the same PR. Idempotent — deleting an absent file exits 0.
# ---------------------------------------------------------------------------
if [[ "$MODE" == "delete" ]]; then
  if [[ -f "$HANDOFF_FILE" ]]; then
    rm -f "$HANDOFF_FILE" 2>/dev/null || {
      echo "handoff-state.sh: rm failed for $HANDOFF_FILE" >&2
      state_lock_release; exit 5
    }
  fi
  state_lock_release; exit 0
fi

# ---------------------------------------------------------------------------
# --set / --append: read-modify-write (lock is already held above).
# Seed from the existing file when present; otherwise start from {}.
# ---------------------------------------------------------------------------
CURRENT="{}"
if [[ -f "$HANDOFF_FILE" ]]; then
  if ! CURRENT="$(jq -e . "$HANDOFF_FILE" 2>/dev/null)"; then
    echo "handoff-state.sh: existing handoff is not valid JSON: $HANDOFF_FILE" >&2
    state_lock_release; exit 4
  fi
fi

if [[ "$MODE" == "set" ]]; then
  JQ_PATH="${JQ_PATH_VALUE%%=*}"
  JQ_VAL="${JQ_PATH_VALUE#*=}"
  # Detect whether the value is a valid JSON literal or a bare string.
  if printf '%s' "$JQ_VAL" | jq -e . >/dev/null 2>&1; then
    UPDATED="$(printf '%s\n' "$CURRENT" | jq --argjson v "$JQ_VAL" "${JQ_PATH} = \$v")" || {
      echo "handoff-state.sh: jq --set failed on path $JQ_PATH" >&2
      state_lock_release; exit 4
    }
  else
    UPDATED="$(printf '%s\n' "$CURRENT" | jq --arg v "$JQ_VAL" "${JQ_PATH} = \$v")" || {
      echo "handoff-state.sh: jq --set (string) failed on path $JQ_PATH" >&2
      state_lock_release; exit 4
    }
  fi
  _atomic_write "$UPDATED"
  state_lock_release; exit 0
fi

if [[ "$MODE" == "append" ]]; then
  # findings_dismissed deduplicates by .id; all other arrays dedup by exact value.
  if [[ "$ARRAY_FIELD" == "findings_dismissed" ]]; then
    if ! printf '%s' "$ARRAY_VALUE" | jq -e 'type == "object" and has("id")' >/dev/null 2>&1; then
      echo "handoff-state.sh: findings_dismissed elements must be JSON objects with an .id field" >&2
      state_lock_release; exit 4
    fi
    UPDATED="$(printf '%s\n' "$CURRENT" | jq \
      --argjson elem "$ARRAY_VALUE" \
      --arg field "$ARRAY_FIELD" \
      '.[$field] = (((.[$field] // []) + [$elem]) | unique_by(.id))')" || {
      echo "handoff-state.sh: jq append (findings_dismissed) failed" >&2
      state_lock_release; exit 4
    }
  else
    # String array: detect whether value is JSON or bare string.
    if printf '%s' "$ARRAY_VALUE" | jq -e . >/dev/null 2>&1; then
      UPDATED="$(printf '%s\n' "$CURRENT" | jq \
        --argjson elem "$ARRAY_VALUE" \
        --arg field "$ARRAY_FIELD" \
        '.[$field] = (((.[$field] // []) + [$elem]) | unique)')" || {
        echo "handoff-state.sh: jq append (json value) failed for field $ARRAY_FIELD" >&2
        state_lock_release; exit 4
      }
    else
      UPDATED="$(printf '%s\n' "$CURRENT" | jq \
        --arg elem "$ARRAY_VALUE" \
        --arg field "$ARRAY_FIELD" \
        '.[$field] = (((.[$field] // []) + [$elem]) | unique)')" || {
        echo "handoff-state.sh: jq append (string) failed for field $ARRAY_FIELD" >&2
        state_lock_release; exit 4
      }
    fi
  fi
  _atomic_write "$UPDATED"
  state_lock_release; exit 0
fi

# Should never reach here.
echo "handoff-state.sh: internal error — unhandled mode: $MODE" >&2
state_lock_release; exit 2
