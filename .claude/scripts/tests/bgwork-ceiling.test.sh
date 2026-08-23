#!/usr/bin/env bash
# Tests for bgwork-ceiling.sh — the hard ceiling on chat silence while
# background work runs (issue #803).
#
# Every marker this script touches is redirected into a temp dir via
# CLAUDE_BGWORK_MARKER_DIR, and the log via CLAUDE_BGWORK_LOG_DIR, so the suite
# never reads or writes real session state in /tmp or ~/.claude.
set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
SCRIPT="$REPO_ROOT/.claude/scripts/bgwork-ceiling.sh"

TMP_DIR="$(mktemp -d)"
export CLAUDE_BGWORK_MARKER_DIR="$TMP_DIR/markers"
export CLAUDE_BGWORK_LOG_DIR="$TMP_DIR/logs"
mkdir -p "$CLAUDE_BGWORK_MARKER_DIR" "$CLAUDE_BGWORK_LOG_DIR"
cleanup() { chmod -R u+w "$TMP_DIR" 2>/dev/null || true; rm -rf "$TMP_DIR"; }
trap cleanup EXIT

# Isolate from a caller-set override — the default-ceiling assertions below
# must not silently inherit a different number from the environment.
unset CLAUDE_BGWORK_CEILING_S

fail() { echo "FAIL: $*" >&2; exit 1; }
ok() { echo "ok   — $*"; }

SID="ceiling-test-$$-$RANDOM"
hb() { printf '%s/claude-heartbeat-%s' "$CLAUDE_BGWORK_MARKER_DIR" "$SID"; }

# Relative timestamps (BSD/macOS then GNU date) — never a hard-coded calendar
# date, which flips future/past depending on when the suite runs.
stamp_minutes_ago() {
  date -v-"$1"M +%Y%m%d%H%M 2>/dev/null || date -d "$1 minutes ago" +%Y%m%d%H%M
}

# --- 1. The ceiling number lives here and nowhere else ------------------------
CEILING=$("$SCRIPT" --ceiling-seconds)
[[ "$CEILING" == "1200" ]] || fail "--ceiling-seconds should be 1200 (20 min), got '$CEILING'"
ok "--ceiling-seconds reports the 20-minute ceiling"

# --- 2. Derived timing invariant: a breach is always REPORTED inside the
#        ceiling, poll granularity included. This is the property that makes
#        the guarantee true; trip/poll are derived from the ceiling, never
#        tuned independently. --------------------------------------------------
STATUS=$("$SCRIPT" --status --session "$SID")
TRIP=$(printf '%s' "$STATUS" | jq -r '.trip_s')
POLL=$(printf '%s' "$STATUS" | jq -r '.poll_s')
(( TRIP < CEILING )) || fail "trip point ($TRIP) must be below the ceiling ($CEILING)"
(( TRIP + POLL <= CEILING )) || \
  fail "worst-case detection ($((TRIP + POLL))s = trip $TRIP + poll $POLL) must not exceed the ceiling ($CEILING)"
ok "trip + poll ($((TRIP + POLL))s) stays inside the ceiling (${CEILING}s)"

# --- 3. --check: nothing started means nothing to guard -----------------------
"$SCRIPT" --check --session "$SID"
[[ $? -eq 0 ]] || fail "--check should exit 0 when no background work has started"
ok "--check passes when no background work has started"

# --- 4. --check fails closed once background work is in flight ---------------
"$SCRIPT" --note-started Agent --session "$SID" || fail "--note-started should succeed"
"$SCRIPT" --check --session "$SID"
[[ $? -eq 1 ]] || fail "--check should exit 1 with background work in flight and no armed ceiling"
ok "--check fails (exit 1) with background work in flight and unarmed"

# --- 5. --note-started is idempotent -----------------------------------------
"$SCRIPT" --note-started Agent --session "$SID"
"$SCRIPT" --note-started Agent --session "$SID"
KINDS=$("$SCRIPT" --status --session "$SID" | jq -r '.background_work | length')
[[ "$KINDS" == "1" ]] || fail "repeated --note-started Agent should record one kind, got $KINDS"
ok "--note-started is idempotent per kind"

# --- 6. Arming satisfies the gate --------------------------------------------
"$SCRIPT" --record-armed --session "$SID" || fail "--record-armed should succeed"
"$SCRIPT" --check --session "$SID"
[[ $? -eq 0 ]] || fail "--check should pass once the ceiling is armed"
ok "--record-armed satisfies --check"

# --- 7. The arm command carries the sentinel the arm hook matches ------------
ARM_CMD=$("$SCRIPT" --arm-command --session "$SID")
[[ "$ARM_CMD" == *"bgwork-ceiling.sh --tick"* ]] || \
  fail "arm command must contain the '--tick' sentinel, got: $ARM_CMD"
[[ "$ARM_CMD" == *"--session $SID"* ]] || \
  fail "arm command must pin the resolved session id, got: $ARM_CMD"
[[ "$ARM_CMD" == *"sleep $POLL"* ]] || \
  fail "arm command must poll at the derived interval ($POLL), got: $ARM_CMD"
ok "--arm-command embeds the sentinel, session id, and derived poll interval"

# --- 8. --tick is silent with no heartbeat to measure from -------------------
OUT=$("$SCRIPT" --tick --session "$SID")
[[ -z "$OUT" ]] || fail "--tick with no heartbeat file should print nothing, got: '$OUT'"
ok "--tick is silent when there is no heartbeat to measure from"

# --- 9. --tick is silent for a healthy thread (the no-spurious-message case) --
touch "$(hb)"
OUT=$("$SCRIPT" --tick --session "$SID")
[[ -z "$OUT" ]] || fail "--tick on a fresh heartbeat should print nothing, got: '$OUT'"
# ...and still silent just under the trip point.
touch -t "$(stamp_minutes_ago 15)" "$(hb)"
OUT=$("$SCRIPT" --tick --session "$SID")
[[ -z "$OUT" ]] || fail "--tick below the trip point should print nothing, got: '$OUT'"
ok "--tick stays silent while the thread is heartbeating normally"

# --- 10. --tick breaches past the trip point, references Liveness section ----
touch -t "$(stamp_minutes_ago 25)" "$(hb)"
OUT=$("$SCRIPT" --tick --session "$SID")
[[ "$OUT" == *"CEILING BREACH"* ]] || fail "--tick past the trip point should breach, got: '$OUT'"
[[ "$OUT" == *"Liveness"* ]] || \
  fail "breach line must point at the monitor-mode.md Liveness section, got: '$OUT'"
[[ "$OUT" == *"nothing new"* ]] || \
  fail "breach line must authorise a nothing-new heartbeat, got: '$OUT'"
LINES=$(printf '%s' "$OUT" | wc -l | tr -d ' ')
[[ "$LINES" -le 1 ]] || fail "breach output should be a single line, got $LINES newlines"
ok "--tick emits a single one-line status instruction on breach"

# --- 11. Breaches are deduped per stretch of silence ------------------------
OUT=$("$SCRIPT" --tick --session "$SID")
[[ -z "$OUT" ]] || fail "second --tick at the same heartbeat mtime should be deduped, got: '$OUT'"
ok "--tick emits once per stretch of silence, not once per poll"

# --- 12. A new stretch of silence is reportable again -----------------------
touch "$(hb)"                                   # agent spoke; Stop hook re-stamps
OUT=$("$SCRIPT" --tick --session "$SID")
[[ -z "$OUT" ]] || fail "--tick after the agent spoke should be silent, got: '$OUT'"
touch -t "$(stamp_minutes_ago 30)" "$(hb)"      # goes quiet again
OUT=$("$SCRIPT" --tick --session "$SID")
[[ "$OUT" == *"CEILING BREACH"* ]] || fail "a fresh stretch of silence should breach again, got: '$OUT'"
ok "dedupe resets once the agent speaks, so the next silence still breaches"

# --- 13. --tick never exits non-zero (a watch that exits stops watching) -----
"$SCRIPT" --tick --session "$SID" >/dev/null
[[ $? -eq 0 ]] || fail "--tick must always exit 0 so the watch loop survives"
ok "--tick always exits 0"

# --- 14. Ceiling override is honoured, and derived timing follows it ---------
OVR=$(CLAUDE_BGWORK_CEILING_S=600 "$SCRIPT" --status --session "$SID")
[[ "$(printf '%s' "$OVR" | jq -r '.ceiling_s')" == "600" ]] || fail "override should set ceiling_s=600"
OVR_TRIP=$(printf '%s' "$OVR" | jq -r '.trip_s')
OVR_POLL=$(printf '%s' "$OVR" | jq -r '.poll_s')
(( OVR_TRIP + OVR_POLL <= 600 )) || fail "derived timing must respect an overridden ceiling"
ok "CLAUDE_BGWORK_CEILING_S override keeps the timing invariant"

# --- 15. A nonsense override warns and falls back, never silently applies ----
ERR=$(CLAUDE_BGWORK_CEILING_S=abc "$SCRIPT" --status --session "$SID" 2>&1 >/dev/null)
[[ "$ERR" == *"ignoring invalid"* ]] || fail "invalid override should warn on stderr, got: '$ERR'"
VAL=$(CLAUDE_BGWORK_CEILING_S=abc "$SCRIPT" --status --session "$SID" 2>/dev/null | jq -r '.ceiling_s')
[[ "$VAL" == "1200" ]] || fail "invalid override should fall back to the default, got '$VAL'"
# A value at or below the margin would invert the trip point — reject it too.
VAL=$(CLAUDE_BGWORK_CEILING_S=10 "$SCRIPT" --status --session "$SID" 2>/dev/null | jq -r '.ceiling_s')
[[ "$VAL" == "1200" ]] || fail "an override below the margin should fall back, got '$VAL'"
ok "invalid ceiling overrides warn and fall back to the default"

# --- 16. Usage errors exit 2 -------------------------------------------------
"$SCRIPT" >/dev/null 2>&1;                       [[ $? -eq 2 ]] || fail "no mode should exit 2"
"$SCRIPT" --nope >/dev/null 2>&1;                [[ $? -eq 2 ]] || fail "unknown flag should exit 2"
"$SCRIPT" --check --status >/dev/null 2>&1;      [[ $? -eq 2 ]] || fail "two modes should exit 2"
"$SCRIPT" --note-started >/dev/null 2>&1;        [[ $? -eq 2 ]] || fail "--note-started without kind should exit 2"
"$SCRIPT" --note-started --check >/dev/null 2>&1; [[ $? -eq 2 ]] || fail "--note-started must not swallow the next flag as its kind"
ok "usage errors exit 2"

# --- 17. --clear resets the session ------------------------------------------
"$SCRIPT" --clear --session "$SID"
"$SCRIPT" --check --session "$SID"
[[ $? -eq 0 ]] || fail "--check should pass after --clear"
ok "--clear resets session markers"

# --- 18. An unwritable marker dir fails CLOSED (exit 5), never silently -----
RO_DIR="$TMP_DIR/readonly"
mkdir -p "$RO_DIR"
chmod a-w "$RO_DIR"
# The probe runs in a subshell so the redirection failure itself is captured —
# `: > file 2>/dev/null` still lets bash print its own "Permission denied".
if ( : > "$RO_DIR/probe" ) 2>/dev/null; then
  rm -f "$RO_DIR/probe"
  echo "skip — running with write access to a mode-555 dir (root?); cannot test the unwritable path"
else
  ERR=$(CLAUDE_BGWORK_MARKER_DIR="$RO_DIR" "$SCRIPT" --note-started Agent --session "$SID" 2>&1 >/dev/null)
  RC=$?
  [[ $RC -eq 5 ]] || fail "unwritable marker dir should exit 5 (fail closed), got $RC"
  [[ "$ERR" == *"cannot write"* ]] || fail "unwritable marker dir should say so on stderr, got: '$ERR'"
  ok "an unwritable marker dir fails closed (exit 5) and is visible on stderr"
fi
chmod u+w "$RO_DIR"

echo "OK: bgwork-ceiling.sh tests passed"
