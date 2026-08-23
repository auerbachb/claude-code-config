#!/usr/bin/env bash
# Tests for session-state.sh --cas (compare-and-set), issue #1195.
#
# Verifies:
#   - CAS succeeds (exit 0) when the current value matches --expect
#   - CAS fails (exit 7) when the current value does not match --expect
#   - Exit 7 is distinct from all I/O / lock / usage errors (2/4/5/6)
#   - Two concurrent writers: exactly one wins (exit 0) and one loses (exit 7)
#   - The state file is unmodified on a CAS loss
#   - --expect null matches a genuinely absent (JSON-null) path
#   - JSON deep-equality: object/array --expect values compared structurally
#   - Usage errors: --cas without --expect, --expect without --cas
#
# Each regression test includes a FAILS-WITHOUT-FIX comment so reviewers can
# revert the --cas block in session-state.sh and confirm the test fails.
#
# Run from any directory; uses a throwaway HOME so the real ~/.claude/
# session-state.json is never touched.
set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
SCRIPT="$REPO_ROOT/.claude/scripts/session-state.sh"

TMP_HOME="$(mktemp -d)"
RACE_DIR=""
cleanup() { rm -rf "$TMP_HOME" ${RACE_DIR:+"$RACE_DIR"}; }
trap cleanup EXIT
export HOME="$TMP_HOME"
mkdir -p "$HOME/.claude"
STATE_FILE="$HOME/.claude/session-state.json"

PASS=0
FAIL=0

check_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [[ "$actual" == "$expected" ]]; then
    PASS=$((PASS + 1)); echo "ok   — $desc"
  else
    FAIL=$((FAIL + 1)); echo "FAIL — $desc (expected '$expected', got '$actual')"
  fi
}

run() { bash "$SCRIPT" "$@"; }

reset_state() { rm -f "$STATE_FILE"; }

# ---------------------------------------------------------------------------
echo "== Usage errors =="
# ---------------------------------------------------------------------------

# --cas without --expect must exit 2
run --raw-path --cas '.foo=bar' >/dev/null 2>&1; RC=$?
check_eq "--cas without --expect exits 2" "2" "$RC"

# --expect without --cas must exit 2
run --raw-path --expect null >/dev/null 2>&1; RC=$?
check_eq "--expect without --cas exits 2" "2" "$RC"

# --cas combined with --set must exit 2
run --raw-path --cas '.foo=bar' --expect null --set '.x=y' >/dev/null 2>&1; RC=$?
check_eq "--cas combined with --set exits 2" "2" "$RC"

# --cas with empty path must exit 2
run --raw-path --cas '=bar' --expect null >/dev/null 2>&1; RC=$?
check_eq "--cas with empty path exits 2" "2" "$RC"

# --cas with no = in argument must exit 2
run --raw-path --cas 'noequalssign' --expect null >/dev/null 2>&1; RC=$?
check_eq "--cas with no = exits 2" "2" "$RC"

# --dry-run combined with --cas must exit 2
run --raw-path --dry-run --cas '.foo=bar' --expect null >/dev/null 2>&1; RC=$?
check_eq "--dry-run combined with --cas exits 2" "2" "$RC"

# ---------------------------------------------------------------------------
echo
echo "== CAS win: absent path (JSON null) matches --expect null =="
# ---------------------------------------------------------------------------
# FAILS-WITHOUT-FIX: --cas mode does not exist; script exits 2 (unknown flag)
reset_state
run --raw-path --cas '.mykey="hello"' --expect null
check_eq "CAS win on absent key exits 0" "0" "$?"
check_eq "value was written after CAS win" "hello" \
  "$(jq -r '.mykey' "$STATE_FILE")"

# ---------------------------------------------------------------------------
echo
echo "== CAS win: current value matches --expect (string) =="
# ---------------------------------------------------------------------------
reset_state
run --raw-path --set '.slot=null'
# FAILS-WITHOUT-FIX: --cas mode does not exist
run --raw-path --cas '.slot="claimed"' --expect null
check_eq "CAS win when current is JSON null exits 0" "0" "$?"
check_eq "slot was updated after CAS win" "claimed" \
  "$(jq -r '.slot' "$STATE_FILE")"

# ---------------------------------------------------------------------------
echo
echo "== CAS loss: current value does NOT match --expect =="
# ---------------------------------------------------------------------------
reset_state
run --raw-path --set '.slot="already-claimed"'
# FAILS-WITHOUT-FIX: --cas mode does not exist; even if it did the value would
# be written unconditionally (no compare), corrupting the state
CAS_OUT=$(run --raw-path --cas '.slot="new-claim"' --expect null 2>&1); CAS_RC=$?
check_eq "CAS loss exits 7" "7" "$CAS_RC"
check_eq "state file not modified on CAS loss" "already-claimed" \
  "$(jq -r '.slot' "$STATE_FILE")"
# Exit 7 must be distinct from all error codes (2/4/5/6)
check_eq "exit 7 is not 2" "1" "$([[ "$CAS_RC" -ne 2 ]] && echo 1 || echo 0)"
check_eq "exit 7 is not 4" "1" "$([[ "$CAS_RC" -ne 4 ]] && echo 1 || echo 0)"
check_eq "exit 7 is not 5" "1" "$([[ "$CAS_RC" -ne 5 ]] && echo 1 || echo 0)"
check_eq "exit 7 is not 6" "1" "$([[ "$CAS_RC" -ne 6 ]] && echo 1 || echo 0)"

# ---------------------------------------------------------------------------
echo
echo "== CAS win: --expect with a JSON object (deep equality) =="
# ---------------------------------------------------------------------------
reset_state
INIT_OBJ='{"run_id":null,"awaiting_run":true,"claim_token":"tok-abc"}'
run --raw-path --set ".slot=$INIT_OBJ"
NEW_OBJ='{"run_id":"R-42","awaiting_run":false,"claim_token":"tok-abc"}'
# FAILS-WITHOUT-FIX: without --cas, there is no way to make this atomic
run --raw-path --cas ".slot=$NEW_OBJ" --expect "$INIT_OBJ"
check_eq "CAS win with JSON object --expect exits 0" "0" "$?"
check_eq "slot updated to new object after CAS win" "R-42" \
  "$(jq -r '.slot.run_id' "$STATE_FILE")"

# ---------------------------------------------------------------------------
echo
echo "== CAS loss: --expect JSON object does not match current object =="
# ---------------------------------------------------------------------------
# State still holds NEW_OBJ from above; try to CAS with INIT_OBJ as expected
LOSS_OUT=$(run --raw-path --cas ".slot=null" --expect "$INIT_OBJ" 2>&1); LOSS_RC=$?
check_eq "CAS loss when object does not match exits 7" "7" "$LOSS_RC"
check_eq "state file not modified on JSON-object CAS loss" "R-42" \
  "$(jq -r '.slot.run_id' "$STATE_FILE")"

# ---------------------------------------------------------------------------
echo
echo "== CAS clears a slot atomically (null write) =="
# ---------------------------------------------------------------------------
reset_state
RECORD='{"claim_token":"tok-xyz","awaiting_run":true}'
run --raw-path --set ".slot=$RECORD"
# CAS clears only when the record still matches exactly.
# FAILS-WITHOUT-FIX: without --cas the clear is unconditional (no compare)
run --raw-path --cas '.slot=null' --expect "$RECORD"
check_eq "CAS clear exits 0 when record matches" "0" "$?"
check_eq "slot is null after CAS clear" "null" \
  "$(jq -r '.slot' "$STATE_FILE")"

# ---------------------------------------------------------------------------
echo
echo "== CAS clear loss: record was already replaced (atomic no-op) =="
# ---------------------------------------------------------------------------
reset_state
RECORD_A='{"claim_token":"tok-aaa"}'
RECORD_B='{"claim_token":"tok-bbb"}'
run --raw-path --set ".slot=$RECORD_B"   # someone else already claimed
# Try to clear using RECORD_A as the expected value — should be a mismatch
CAS_CLEAR_OUT=$(run --raw-path --cas '.slot=null' --expect "$RECORD_A" 2>&1); CAS_CLEAR_RC=$?
check_eq "CAS clear loss exits 7 when record was replaced" "7" "$CAS_CLEAR_RC"
check_eq "competitor record left intact after CAS clear loss" "tok-bbb" \
  "$(jq -r '.slot.claim_token' "$STATE_FILE")"

# ---------------------------------------------------------------------------
echo
echo "== Repo scoping: --cas without --raw-path scopes path =="
# ---------------------------------------------------------------------------
reset_state
run --repo test/cas-repo --cas '.prs["99"].phase=A' --expect null
check_eq "scoped CAS win exits 0" "0" "$?"
check_eq "scoped write lands under correct repo key" "A" \
  "$(jq -r '.repos["test/cas-repo"].prs["99"].phase' "$STATE_FILE")"

# A second CAS on the same path with --expect null must lose (value is now "A")
SCOPE_LOSS_RC=0
run --repo test/cas-repo --cas '.prs["99"].phase=B' --expect null 2>/dev/null || SCOPE_LOSS_RC=$?
check_eq "scoped CAS loss exits 7" "7" "$SCOPE_LOSS_RC"
check_eq "scoped CAS loss did not overwrite value" "A" \
  "$(jq -r '.repos["test/cas-repo"].prs["99"].phase' "$STATE_FILE")"

# ---------------------------------------------------------------------------
echo
echo "== Concurrent race: exactly one writer wins =="
# ---------------------------------------------------------------------------
# Two writers both CAS '.race_slot=mine' with --expect null. One acquires the
# lock first and wins (exit 0); the other reads the post-write value that no
# longer matches null and exits 7. Total: exactly one 0 and one 7.
#
# FAILS-WITHOUT-FIX: without the CAS primitive both writers do an independent
# --set (no compare), so both write their value and the final result is
# last-writer-wins — neither returns 7, and neither detects the race.
reset_state
run --raw-path --set '.race_slot=null'

RACE_DIR="$(mktemp -d)"

# Writer function: CAS race_slot from null to a writer-specific value.
# Records exit code in a file for the parent to inspect.
run_writer() {
  local id="$1" out_file="$2"
  local rc=0
  bash "$SCRIPT" --raw-path \
    --cas ".race_slot=\"writer-${id}\"" \
    --expect null 2>/dev/null || rc=$?
  printf '%s' "$rc" > "$out_file"
}

W1_FILE="$RACE_DIR/w1.rc"
W2_FILE="$RACE_DIR/w2.rc"

# Launch both writers in the background, wait for both.
(run_writer 1 "$W1_FILE") &
PID1=$!
(run_writer 2 "$W2_FILE") &
PID2=$!
wait "$PID1" 2>/dev/null || true
wait "$PID2" 2>/dev/null || true

W1_RC="$(cat "$W1_FILE" 2>/dev/null || echo "missing")"
W2_RC="$(cat "$W2_FILE" 2>/dev/null || echo "missing")"

# Exactly one must have exited 0 and the other 7.
WINS=0
LOSSES=0
[[ "$W1_RC" == "0" ]] && WINS=$((WINS+1))
[[ "$W2_RC" == "0" ]] && WINS=$((WINS+1))
[[ "$W1_RC" == "7" ]] && LOSSES=$((LOSSES+1))
[[ "$W2_RC" == "7" ]] && LOSSES=$((LOSSES+1))

check_eq "race: exactly one writer wins (exit 0)" "1" "$WINS"
check_eq "race: exactly one writer loses (exit 7)" "1" "$LOSSES"

# The winning value must be on disk.
RACE_FINAL="$(jq -r '.race_slot' "$STATE_FILE")"
case "$RACE_FINAL" in
  "writer-1"|"writer-2") check_eq "race: winner's value on disk" "1" "1" ;;
  *) check_eq "race: winner's value on disk" "writer-N" "$RACE_FINAL" ;;
esac

# ---------------------------------------------------------------------------
echo
echo "== summary: $PASS passed, $FAIL failed =="
if [[ "$FAIL" -eq 0 ]]; then
  echo "OK: session-state.sh --cas tests passed"
  exit 0
else
  echo "FAILURE: $FAIL session-state.sh --cas test(s) failed"
  exit 1
fi
