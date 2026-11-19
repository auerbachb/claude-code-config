#!/usr/bin/env bash
# Session execution-pause gate — PreToolUse hook.
# Blocks every Agent, Workflow, and Monitor launch plus background Bash while
# `/end` or `/pause` is winding down this exact repo/session. Foreground
# Bash remains available for checkpoint, TaskStop bookkeeping, and handoffs.

set -uo pipefail

# Millisecond clock (issue #2433). The retry budget below is measured from the
# hook's own start, so slow preflight (payload parsing, repo resolution) is
# charged against it too. CLOCK_SLACK_MS covers the seconds-only fallback,
# which can under-report elapsed time by up to a second.
CLOCK_SLACK_MS=0
if [[ -z "${EPOCHREALTIME:-}" ]] && ! command -v perl >/dev/null 2>&1; then
  CLOCK_SLACK_MS=1000
fi
now_ms() {
  if [[ -n "${EPOCHREALTIME:-}" ]]; then
    local t="${EPOCHREALTIME/[.,]/}"
    printf '%s' "$(( 10#${t:0:${#t}-3} ))"
  elif command -v perl >/dev/null 2>&1; then
    perl -MTime::HiRes=time -e 'printf "%d", time()*1000'
  else
    printf '%s' "$(( $(date +%s) * 1000 ))"
  fi
}
GATE_START_MS="$(now_ms)"

INPUT="$(cat 2>/dev/null || true)"

field() { printf '%s' "$INPUT" | jq -r "$1 // empty" 2>/dev/null; }

TOOL_NAME="$(field '.tool_name')"
BACKGROUND="$(field '.tool_input.run_in_background')"
case "$TOOL_NAME" in
  Agent|Workflow|Monitor) ;;
  Bash) [[ "$BACKGROUND" == true ]] || exit 0 ;;
  *) exit 0 ;;
esac

SESSION_ID="$(field '.session_id')"
CWD="$(field '.cwd')"
[[ -n "$SESSION_ID" ]] || exit 0

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PAUSE_SH="${SCRIPT_DIR%/hooks}/scripts/execution-pause.sh"
SESSION_STATE_SH="${SCRIPT_DIR%/hooks}/scripts/session-state.sh"

resolve_payload_repo() {
  local key="" payload_examined=0
  if [[ -n "$CWD" && -d "$CWD" && -x "$SESSION_STATE_SH" ]]; then
    payload_examined=1
    if key="$(cd "$CWD" && unset CLAUDE_SESSION_REPO && \
      "$SESSION_STATE_SH" --repo-key 2>/dev/null)"; then
      :
    else
      key=_unknown
    fi
  fi
  if [[ -z "$key" && "$payload_examined" == 0 ]]; then
    key="${CLAUDE_SESSION_REPO:-_unknown}"
  fi
  [[ -n "$key" ]] || key=_unknown
  if [[ "$key" != _unknown && ! "$key" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]]; then
    key=_unknown
  fi
  printf '%s' "$key" | tr '[:upper:]' '[:lower:]'
}
REPO_KEY="$(resolve_payload_repo)"
if [[ ! -x "$PAUSE_SH" ]]; then
  MARKER_DIR="${CLAUDE_EXECUTION_PAUSE_MARKER_DIR:-$HOME/.claude/execution-pause-markers}"
  scope_hash() {
    local digest=""
    if command -v sha256sum >/dev/null 2>&1; then
      digest="$(printf '%s\0%s' "$REPO_KEY" "$SESSION_ID" | sha256sum | awk '{print $1}')"
    elif command -v shasum >/dev/null 2>&1; then
      digest="$(printf '%s\0%s' "$REPO_KEY" "$SESSION_ID" | shasum -a 256 | awk '{print $1}')"
    fi
    [[ "$digest" =~ ^[[:xdigit:]]{64}$ ]] || return 1
    printf '%s' "$digest" | tr '[:upper:]' '[:lower:]'
  }
  SCOPE_HASH="$(scope_hash)" || {
    echo "BLOCKED: execution-pause helper is unavailable and marker scope cannot be resolved; refusing to start $TOOL_NAME." >&2
    exit 2
  }
  MARKER="$MARKER_DIR/claude-execution-pause-v2-$SCOPE_HASH"
  if [[ -f "$MARKER" ]]; then
    echo "BLOCKED: execution-pause helper is unavailable while an active repo/session marker exists; refusing to start $TOOL_NAME." >&2
    exit 2
  fi
  echo "pause-launch-gate.sh: execution-pause.sh unavailable; no active marker found" >&2
  exit 0
fi

# Bounded status retry (issue #2433). The status read stays serialized under
# the state lock — an unlocked read can observe a half-applied activation or
# clear — but a lock that is merely BUSY is retried briefly instead of refusing
# on the first exit 6. Only exit 6 is retried; `active` blocks at once. The
# hook — preflight included, measured from GATE_START_MS at the top — fits
# CLAUDE_PAUSE_GATE_BUDGET_MS (default 3500 ms) under the 5 s host hook
# timeout in global-settings.json. Each attempt waits at most
# CLAUDE_PAUSE_GATE_ATTEMPT_TIMEOUT seconds (default 1) for the lock, and a new
# attempt starts only when a full attempt still fits in the budget. The first
# attempt always runs, so a slow preflight still ends in a verdict.
BUDGET_MS="${CLAUDE_PAUSE_GATE_BUDGET_MS:-3500}"
[[ "$BUDGET_MS" =~ ^[0-9]{1,5}$ ]] || BUDGET_MS=3500
BUDGET_MS=$(( 10#$BUDGET_MS ))
ATTEMPT_TIMEOUT="${CLAUDE_PAUSE_GATE_ATTEMPT_TIMEOUT:-1}"
# One digit 1-4 only: a long digit string could overflow the arithmetic below.
[[ "$ATTEMPT_TIMEOUT" =~ ^[1-4]$ ]] || ATTEMPT_TIMEOUT=1
# Overrides can never outlive the 5 s host timeout: the budget is capped at
# 4000 ms, and a single attempt (the first one included) must fit inside it.
(( BUDGET_MS <= 4000 )) || BUDGET_MS=4000
(( ATTEMPT_TIMEOUT * 1000 <= BUDGET_MS )) || ATTEMPT_TIMEOUT=1

status_attempt() {
  if [[ -n "$CWD" && -d "$CWD" ]]; then
    (cd "$CWD" && CLAUDE_STATE_LOCK_TIMEOUT="$ATTEMPT_TIMEOUT" CLAUDE_EXECUTION_PAUSE_LAUNCH_CHECK=1 \
      "$PAUSE_SH" --repo "$REPO_KEY" --status --session "$SESSION_ID" 2>&1)
  else
    CLAUDE_STATE_LOCK_TIMEOUT="$ATTEMPT_TIMEOUT" CLAUDE_EXECUTION_PAUSE_LAUNCH_CHECK=1 \
      "$PAUSE_SH" --repo "$REPO_KEY" --status --session "$SESSION_ID" 2>&1
  fi
}

STATUS=""
RC=0
ATTEMPTS=0
LAST_DIAG=""
while :; do
  ATTEMPTS=$(( ATTEMPTS + 1 ))
  RC=0
  OUT="$(status_attempt)" || RC=$?
  # stdout carries exactly `active` / `inactive`; anything else is stderr.
  STATUS="$(printf '%s\n' "$OUT" | grep -E '^(active|inactive)$' | tail -n 1)"
  [[ "$RC" -eq 6 ]] || break
  LAST_DIAG="$(printf '%s\n' "$OUT" | grep 'state-lock:' | tail -n 1)"
  ELAPSED=$(( $(now_ms) - GATE_START_MS ))
  # Jittered 100-290 ms back-off, then retry only if a whole attempt still fits.
  JITTER_MS=$(( 100 + RANDOM % 20 * 10 ))
  (( ELAPSED + CLOCK_SLACK_MS + JITTER_MS + ATTEMPT_TIMEOUT * 1000 <= BUDGET_MS )) || break
  sleep "0.$(printf '%03d' "$JITTER_MS")"
done

# A confirmed active state includes the marker-backed fail-closed path when
# session-state.json became unreadable after the pause was armed. Hook parse or
# dependency failures stay fail-open so a malformed payload cannot brick work.
if [[ "$RC" -eq 0 && "$STATUS" == active ]]; then
  echo "BLOCKED: background launches are closed for this session. Finish the wind-down, then run its matching resume command: /end-resume for /end; /pause-resume for /pause. Refusing to start $TOOL_NAME." >&2
  exit 2
fi
if [[ "$RC" -eq 6 ]]; then
  # Three distinct blocking outcomes (paused above, busy, unavailable) — all
  # exit 2, because none of them proves the session is NOT paused.
  if [[ -n "$LAST_DIAG" && "$LAST_DIAG" != *"not contention"* && "$LAST_DIAG" == *"held by pid "* ]]; then
    HOLDER="$(printf '%s' "$LAST_DIAG" | sed -n 's/.*(\(\(last observed \)\{0,1\}held by pid [^ ]* on [^ ]*\).*/\1/p')"
    echo "BLOCKED: pause state is lock-busy (${HOLDER:-holder unknown}) after $ATTEMPTS attempt(s) within ${BUDGET_MS}ms; this is NOT a pause and retrying the launch is safe. Refusing to start $TOOL_NAME. [$LAST_DIAG]" >&2
  else
    echo "BLOCKED: pause status could not be verified (${LAST_DIAG:-no lock diagnostic}) after $ATTEMPTS attempt(s); this is not lock contention. Refusing to start $TOOL_NAME." >&2
  fi
  exit 2
fi
exit 0
