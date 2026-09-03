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
#   - Composition (issue #1445): one --cas may carry --set writes; the compare
#     gates the whole batch, so a win writes all of them and a loss writes none
#     of them and still exits 7. The remaining exclusivity rules are unchanged.
#
# Each regression test includes a FAILS-WITHOUT-FIX comment so reviewers can
# revert the --cas block in session-state.sh and confirm the test fails.
#
# Run from any directory; uses a throwaway HOME so the real ~/.claude/
# session-state.json is never touched.
set -uo pipefail

# Resolve the repo root relative to this script so the test works regardless
# of the caller's working directory.
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && git rev-parse --show-toplevel)"
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

# --cas combined with --set is the SUPPORTED composition since issue #1445 (its
# behaviour is pinned in the composition section at the end of this file). What
# must still be a usage error is a SECOND --cas, a second --expect, and any other
# mode paired with either flag — the composition widened one rule, not all of them.
run --raw-path --cas '.a=1' --expect null --cas '.b=2' >/dev/null 2>&1; RC=$?
check_eq "a second --cas still exits 2" "2" "$RC"

run --raw-path --cas '.a=1' --expect null --expect null >/dev/null 2>&1; RC=$?
check_eq "a second --expect still exits 2" "2" "$RC"

run --raw-path --cas '.a=1' --expect null --get '.a' >/dev/null 2>&1; RC=$?
check_eq "--cas combined with --get still exits 2" "2" "$RC"

run --raw-path --set '.a=1' --get '.a' >/dev/null 2>&1; RC=$?
check_eq "--set combined with --get still exits 2" "2" "$RC"

run --raw-path --set '.a=1' --migrate >/dev/null 2>&1; RC=$?
check_eq "--set combined with --migrate still exits 2" "2" "$RC"

run --raw-path --cas '.a=1' --expect null --session-view >/dev/null 2>&1; RC=$?
check_eq "--cas combined with --session-view still exits 2" "2" "$RC"

# --cas with empty path must exit 2
run --raw-path --cas '=bar' --expect null >/dev/null 2>&1; RC=$?
check_eq "--cas with empty path exits 2" "2" "$RC"

# --cas with no = in argument must exit 2
run --raw-path --cas 'noequalssign' --expect null >/dev/null 2>&1; RC=$?
check_eq "--cas with no = exits 2" "2" "$RC"

# --dry-run combined with --cas must exit 2
run --raw-path --dry-run --cas '.foo=bar' --expect null >/dev/null 2>&1; RC=$?
check_eq "--dry-run combined with --cas exits 2" "2" "$RC"

# ...and composing --set onto it does not buy a way past that guard.
run --raw-path --dry-run --cas '.foo=bar' --expect null --set '.x=y' >/dev/null 2>&1; RC=$?
check_eq "--dry-run with a composed --cas still exits 2" "2" "$RC"

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
echo "== Field-type contract: --cas rejects a wrong-typed value (issue #1283) =="
# ---------------------------------------------------------------------------
# FAILS-WITHOUT-FIX: before #1283 the --cas path ran no field-type check at
# all, so a matching compare wrote the bad-typed value unconditionally — the
# CAS exited 0 and `cr_explicit_triggers` ended up the number 2 where every
# consumer expects an array. --set has rejected exactly this since #640.
reset_state
GOOD_TRIGGERS='["2026-04-29T22:30:00Z"]'
run --repo test/repo --set ".prs[\"999\"].cr_explicit_triggers=$GOOD_TRIGGERS"
check_eq "seed: well-formed array accepted by --set" "0" "$?"

BEFORE_DOC="$(cat "$STATE_FILE")"
TYPE_OUT=$(run --repo test/repo --cas '.prs["999"].cr_explicit_triggers=2' \
  --expect "$GOOD_TRIGGERS" 2>&1); TYPE_RC=$?
check_eq "number-for-array via --cas rejected (exit 4)" "4" "$TYPE_RC"
check_eq "error names cr_explicit_triggers and both types" "1" \
  "$(grep -c "field '.repos\[\"test/repo\"\].prs\[\"999\"\].cr_explicit_triggers' would become type 'number' but must be 'array'" <<<"$TYPE_OUT")"
check_eq "state file byte-unchanged after a rejected --cas write" "$BEFORE_DOC" \
  "$(cat "$STATE_FILE")"
check_eq "prior valid array untouched" "$GOOD_TRIGGERS" \
  "$(jq -c '.repos["test/repo"].prs["999"].cr_explicit_triggers' "$STATE_FILE")"
# A type violation must stay distinguishable from a lost CAS race (7) and
# from jq/write mechanics (5) — exit 4 is the --set contract's own code.
check_eq "type rejection is not a CAS mismatch (7)" "1" \
  "$([[ "$TYPE_RC" -ne 7 ]] && echo 1 || echo 0)"
check_eq "type rejection is not a write failure (5)" "1" \
  "$([[ "$TYPE_RC" -ne 5 ]] && echo 1 || echo 0)"

# Parity control: the same violation through --set produces the same code and
# the same message, which is the whole point of #1283.
SET_OUT=$(run --repo test/repo --set '.prs["999"].cr_explicit_triggers=2' 2>&1); SET_RC=$?
check_eq "--set rejects the identical value with the identical code" "$TYPE_RC" "$SET_RC"
check_eq "--set and --cas emit the identical rejection message" "$SET_OUT" "$TYPE_OUT"

# A well-typed CAS write on the same known-typed field must still succeed —
# the guard rejects wrong types, it does not block the field.
NEW_TRIGGERS='["2026-04-29T22:30:00Z","2026-04-29T23:30:00Z"]'
run --repo test/repo --cas ".prs[\"999\"].cr_explicit_triggers=$NEW_TRIGGERS" \
  --expect "$GOOD_TRIGGERS"
check_eq "well-typed array via --cas exits 0" "0" "$?"
check_eq "well-typed array was written" "$NEW_TRIGGERS" \
  "$(jq -c '.repos["test/repo"].prs["999"].cr_explicit_triggers' "$STATE_FILE")"

# ---------------------------------------------------------------------------
echo
echo "== Field-type contract: --cas whole-PR-entry and top-level writes =="
# ---------------------------------------------------------------------------
# FAILS-WITHOUT-FIX: without #1283 both writes below are committed verbatim.
reset_state
run --repo test/repo --set '.prs["999"].phase=A'
BEFORE_DOC="$(cat "$STATE_FILE")"
ENTRY_OUT=$(run --repo test/repo \
  --cas '.prs["999"]={"phase":"B","last_cron_action":"bare string"}' \
  --expect '{"phase":"A"}' 2>&1); ENTRY_RC=$?
check_eq "whole-entry --cas embedding a malformed known field rejected (exit 4)" "4" "$ENTRY_RC"
check_eq "error names the embedded nested field" "1" \
  "$(grep -c "field '.repos\[\"test/repo\"\].prs\[\"999\"\].last_cron_action' would become type 'string' but must be 'object'" <<<"$ENTRY_OUT")"
check_eq "state file byte-unchanged after a rejected whole-entry --cas" "$BEFORE_DOC" \
  "$(cat "$STATE_FILE")"

reset_state
run --raw-path --set '.active_agents=[]'
BEFORE_DOC="$(cat "$STATE_FILE")"
TOP_OUT=$(run --raw-path --cas '.active_agents=not-an-array' --expect '[]' 2>&1); TOP_RC=$?
check_eq "string-for-array top-level field via --cas rejected (exit 4)" "4" "$TOP_RC"
check_eq "error names active_agents and both types" "1" \
  "$(grep -c "field '.active_agents' would become type 'string' but must be 'array'" <<<"$TOP_OUT")"
check_eq "state file byte-unchanged after a rejected top-level --cas" "$BEFORE_DOC" \
  "$(cat "$STATE_FILE")"

# ---------------------------------------------------------------------------
echo
echo "== Field-type contract: --cas parity for the three shapes of issue #1340 =="
# ---------------------------------------------------------------------------
# FAILS-WITHOUT-FIX: on origin/main all three --cas writes below are committed.
# #1283's promise is that --set and --cas enforce the same contract, so each
# gap closed for --set has to be closed here too — pinned per shape.

# Gap 1 — whole-entry --cas carrying a known field as an explicit null.
reset_state
run --repo test/repo --set '.prs["999"].phase=A'
BEFORE_DOC="$(cat "$STATE_FILE")"
G1_OUT=$(run --repo test/repo \
  --cas '.prs["999"]={"phase":"B","last_cron_action":null}' \
  --expect '{"phase":"A"}' 2>&1); G1_RC=$?
check_eq "gap 1: whole-entry --cas with an explicit-null known field rejected (exit 4)" "4" "$G1_RC"
check_eq "gap 1: error names the field and 'null' as the offending type" "1" \
  "$(grep -c "field '.repos\[\"test/repo\"\].prs\[\"999\"\].last_cron_action' would become type 'null' but must be 'object'" <<<"$G1_OUT")"
check_eq "gap 1: state file byte-unchanged after the rejected --cas" "$BEFORE_DOC" \
  "$(cat "$STATE_FILE")"

# Gap 2 — --raw-path --cas to an explicitly-scoped per-PR field.
reset_state
run --raw-path --set '.repos["test/repo"].prs["1"].phase=A'
BEFORE_DOC="$(cat "$STATE_FILE")"
G2_OUT=$(run --raw-path \
  --cas '.repos["test/repo"].prs["1"].last_cron_action=bad' \
  --expect null 2>&1); G2_RC=$?
check_eq "gap 2: --raw-path scoped nested --cas rejected (exit 4)" "4" "$G2_RC"
check_eq "gap 2: error names the scoped nested field" "1" \
  "$(grep -c "field '.repos\[\"test/repo\"\].prs\[\"1\"\].last_cron_action' would become type 'string' but must be 'object'" <<<"$G2_OUT")"
check_eq "gap 2: state file byte-unchanged after the rejected --cas" "$BEFORE_DOC" \
  "$(cat "$STATE_FILE")"

# Positive control: the same shape overrun-check.sh writes — a fully-spelled
# scoped path to a field outside the contract — must still win its CAS.
reset_state
run --repo test/repo --set '.prs["1"].phase=A'
run --cas '.repos["test/repo"].prs["1"].overrun={"alerted_at":"2026-09-02T00:00:00Z","bound_min":30}' \
  --expect null
check_eq "gap 2: overrun-check's scoped --cas claim still wins" "0" "$?"
check_eq "gap 2: the untyped claim was written as given" '{"alerted_at":"2026-09-02T00:00:00Z","bound_min":30}' \
  "$(jq -c '.repos["test/repo"].prs["1"].overrun' "$STATE_FILE")"

# Gap 3 — --cas replacing the whole `.prs` map.
reset_state
run --repo test/repo --set '.prs["1"].phase=A'
BEFORE_DOC="$(cat "$STATE_FILE")"
G3_OUT=$(run --repo test/repo \
  --cas '.prs={"9":{"last_cron_action":"bad"}}' \
  --expect '{"1":{"phase":"A"}}' 2>&1); G3_RC=$?
check_eq "gap 3: whole-map --cas with a malformed entry rejected (exit 4)" "4" "$G3_RC"
check_eq "gap 3: error names the offending entry inside the replacement" "1" \
  "$(grep -c "field '.repos\[\"test/repo\"\].prs\[\"9\"\].last_cron_action' would become type 'string' but must be 'object'" <<<"$G3_OUT")"
check_eq "gap 3: state file byte-unchanged after the rejected --cas" "$BEFORE_DOC" \
  "$(cat "$STATE_FILE")"

# A well-formed whole-map --cas still wins, so the guard did not narrow --cas.
run --repo test/repo --cas '.prs={"9":{"phase":"C","digest_streak":2}}' \
  --expect '{"1":{"phase":"A"}}'
check_eq "gap 3: a well-formed whole-map --cas still wins" "0" "$?"
check_eq "gap 3: the replacement is applied wholesale" '{"9":{"phase":"C","digest_streak":2}}' \
  "$(jq -c '.repos["test/repo"].prs' "$STATE_FILE")"

# Opaque nested tail (CodeAnt, PR #1573) — `."key"` is valid jq that
# path_take_segment() cannot decompose, so the single-path check had no path to
# check and the write committed. --set and --cas share pr_record_write_target(),
# so the entry-scan fallback has to reach both; pinned here per #1283.
reset_state
run --repo test/repo --set '.prs["1"].phase=A'
BEFORE_DOC="$(cat "$STATE_FILE")"
G4_OUT=$(run --repo test/repo \
  --cas '.prs["1"]."last_cron_action"="bad"' \
  --expect null 2>&1); G4_RC=$?
check_eq "opaque tail: dot-quoted nested --cas rejected (exit 4)" "4" "$G4_RC"
check_eq "opaque tail: error names the field via the entry scan" "1" \
  "$(grep -c "field '.repos\[\"test/repo\"\].prs\[\"1\"\].last_cron_action' would become type 'string' but must be 'object'" <<<"$G4_OUT")"
check_eq "opaque tail: state file byte-unchanged after the rejected --cas" "$BEFORE_DOC" \
  "$(cat "$STATE_FILE")"

# The well-typed value in the same spelling must still win its CAS.
run --repo test/repo --cas '.prs["1"]."last_cron_action"={"type":"delete"}' --expect null
check_eq "opaque tail: a well-typed dot-quoted --cas still wins" "0" "$?"
check_eq "opaque tail: the well-typed --cas was applied as given" '{"type":"delete"}' \
  "$(jq -c '.repos["test/repo"].prs["1"].last_cron_action' "$STATE_FILE")"

# ---------------------------------------------------------------------------
echo
echo "== Field-type contract: untyped fields stay unvalidated under --cas =="
# ---------------------------------------------------------------------------
# `.release.in_flight` — the claim slot --cas was built for (issue #1195) — is
# not in the schema's typed-field maps, so #1283 is a no-op for it: any JSON
# value still writes. This pins that the new guard did not narrow --cas.
reset_state
run --raw-path --cas '.release.in_flight={"claim":"mine"}' --expect null
check_eq "untyped object claim still accepted" "0" "$?"
run --raw-path --cas '.release.in_flight=42' --expect '{"claim":"mine"}'
check_eq "untyped field accepts a differently-typed value" "0" "$?"
check_eq "untyped value written as given" "42" \
  "$(jq -c '.release.in_flight' "$STATE_FILE")"

# The exact shape release-decide.sh writes: a scoped claim addressed with
# --raw-path. `repos` IS a known object-typed top-level key, so this path now
# runs the top-level and repo-scope checks — it must still round-trip.
reset_state
CLAIM='{"pr":42,"mechanism":"tag","awaiting_run":true,"claim_token":"tok-1"}'
run --raw-path --cas ".repos[\"org/repo\"].release.in_flight=$CLAIM" --expect null
check_eq "release-decide claim shape still wins" "0" "$?"
check_eq "claim record written under the repo scope" "$CLAIM" \
  "$(jq -c '.repos["org/repo"].release.in_flight' "$STATE_FILE")"
run --raw-path --cas '.repos["org/repo"].release.in_flight=null' --expect "$CLAIM"
check_eq "release-decide claim release still wins" "0" "$?"
check_eq "claim slot cleared" "null" \
  "$(jq -c '.repos["org/repo"].release.in_flight' "$STATE_FILE")"

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
echo "== Composition: one --cas carrying --set writes (issue #1445) =="
# ---------------------------------------------------------------------------
# `/pm` 2D.7 needs claim-plus-metadata to be ONE write. This script locks per
# invocation, so a --cas followed by a separate --set is two lock holds with a
# race between them; composition moves the --set writes inside the hold the
# compare already takes. The contract under test: on a match every assignment
# lands, on a mismatch NONE of them do and the exit code is still 7.
#
# FAILS-WITHOUT-FIX for every case below: before #1445 the parser rejected
# --cas and --set in one invocation with exit 2, so each composed call would
# return 2 and write nothing — the win cases below would all report 2, and the
# loss cases would pass vacuously (nothing written for the wrong reason), which
# is why each loss case also asserts the PRIOR value survived.

reset_state
run --raw-path --set '.day={"cause":null,"kind":null,"fires":null,"hits":0}'
COMPOSED_RC=0
run --raw-path --cas '.day.cause="preemptive"' --expect null \
  --set '.day.kind=rolling_window' \
  --set '.day.fires=12' \
  --set '.day.hits=1' || COMPOSED_RC=$?
check_eq "composed CAS win exits 0" "0" "$COMPOSED_RC"
check_eq "composed win: CAS target and every companion landed together" \
  '{"cause":"preemptive","kind":"rolling_window","fires":12,"hits":1}' \
  "$(jq -c '.day' "$STATE_FILE")"
# One invocation is one write, so the timestamp refresh happens once, in the
# same jq pipeline as the assignments.
COMPOSED_TS="$(jq -r '.last_updated' "$STATE_FILE")"
check_eq "composed win: last_updated refreshed by the same write" "1" \
  "$([[ "$COMPOSED_TS" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]] && echo 1 || echo 0)"

# The all-or-nothing half: a lost compare must leave the companions unwritten.
BEFORE_DOC="$(cat "$STATE_FILE")"
MISS_RC=0
run --raw-path --cas '.day.cause="second-claimant"' --expect null \
  --set '.day.kind=CLOBBERED' \
  --set '.day.newfield=should-not-exist' >/dev/null 2>&1 || MISS_RC=$?
check_eq "composed CAS miss exits 7" "7" "$MISS_RC"
check_eq "composed miss: state file byte-unchanged" "$BEFORE_DOC" "$(cat "$STATE_FILE")"
check_eq "composed miss: companion did not overwrite an existing field" "rolling_window" \
  "$(jq -r '.day.kind' "$STATE_FILE")"
check_eq "composed miss: companion did not create a new field" "null" \
  "$(jq -r '.day.newfield' "$STATE_FILE")"

# Flag order is not significant: --cas owns the mode whichever side it arrives on.
reset_state
ORDER_RC=0
run --raw-path --set '.first=1' --cas '.claim="mine"' --expect null --set '.second=2' || ORDER_RC=$?
check_eq "--set before --cas is accepted (order-independent)" "0" "$ORDER_RC"
check_eq "order: CAS target written" "mine" "$(jq -r '.claim' "$STATE_FILE")"
check_eq "order: companions on both sides written" "1 2" \
  "$(jq -r '[(.first|tostring), (.second|tostring)] | join(" ")' "$STATE_FILE")"

# The CAS target is assigned FIRST in the pipeline, so a --set naming that same
# path wins over the compared value — in either flag order. Pinned because the
# header documents it as the resolution rule.
reset_state
SAMEPATH_RC=0
run --raw-path --set '.claim="from-set"' --cas '.claim="from-cas"' --expect null || SAMEPATH_RC=$?
check_eq "a --set on the CAS path is accepted" "0" "$SAMEPATH_RC"
check_eq "a --set on the CAS path wins over the compared value" "from-set" \
  "$(jq -r '.claim' "$STATE_FILE")"
reset_state
run --raw-path --cas '.claim="from-cas"' --expect null --set '.claim="from-set"'
check_eq "...and it wins with --cas written first too" "from-set" \
  "$(jq -r '.claim' "$STATE_FILE")"

# An ANCESTOR --set is the one composition whose exit code would lie: assigned
# after the claim, it replaces the subtree holding it, so the command would exit
# 0 reporting a won claim that is no longer in the file. Refused at the usage
# stage instead (exit 2, nothing written).
reset_state
ANC_RC=0
run --raw-path --cas '.outer.claim="mine"' --expect null --set '.outer={"wiped":true}' || ANC_RC=$?
check_eq "a --set on an ancestor of the CAS path exits 2" "2" "$ANC_RC"
check_eq "ancestor rejection writes nothing" "absent" \
  "$(if [[ -e "$STATE_FILE" ]]; then echo present; else echo absent; fi)"
reset_state
ANC_ORDER_RC=0
run --raw-path --set '.outer={"wiped":true}' --cas '.outer.claim="mine"' --expect null || ANC_ORDER_RC=$?
check_eq "...rejected in the other flag order too" "2" "$ANC_ORDER_RC"
# Bracket boundary: `.repos` is an ancestor of `.repos["k"].x`.
reset_state
ANC_BRACKET_RC=0
run --raw-path --cas '.repos["k"].claim="mine"' --expect null --set '.repos={}' || ANC_BRACKET_RC=$?
check_eq "ancestor detection spans a [ segment boundary" "2" "$ANC_BRACKET_RC"

# Negative control: a shared textual prefix that is NOT a segment boundary must
# still be accepted, or the guard above would be rejecting unrelated siblings.
reset_state
SIBLING_RC=0
run --raw-path --cas '.ab="claimed"' --expect null --set '.abc=1' || SIBLING_RC=$?
check_eq "a prefix that is not a path boundary is still accepted" "0" "$SIBLING_RC"
check_eq "prefix control: CAS target survived" "claimed" "$(jq -r '.ab' "$STATE_FILE")"

# A DESCENDANT companion refines the claim rather than dropping it, so it stays
# legal — the guard must not over-reach into the reverse direction.
reset_state
DESC_RC=0
run --raw-path --cas '.outer={"claim":"mine"}' --expect null --set '.outer.extra=1' || DESC_RC=$?
check_eq "a --set on a descendant of the CAS path is accepted" "0" "$DESC_RC"
check_eq "descendant: claim survives alongside the refinement" "mine 1" \
  "$(jq -r '[.outer.claim, (.outer.extra|tostring)] | join(" ")' "$STATE_FILE")"

# A plain --cas with no composed --set is the normal single-flag case and must
# stay unaffected by the composition machinery (an empty companion list).
reset_state
NOSETS_RC=0
run --raw-path --cas '.lonely="claimed"' --expect null || NOSETS_RC=$?
check_eq "a --cas with no --set companions still exits 0" "0" "$NOSETS_RC"
check_eq "a --cas with no --set companions still writes" "claimed" \
  "$(jq -r '.lonely' "$STATE_FILE")"

# The field-type contract reaches every assignment in the batch, not just the
# CAS target — one wrong-typed companion rejects the WHOLE invocation.
reset_state
run --raw-path --set '.active_agents=[]'
BEFORE_DOC="$(cat "$STATE_FILE")"
COMP_TYPE_OUT=$(run --raw-path --cas '.slot="claimed"' --expect null \
  --set '.active_agents=not-an-array' 2>&1); COMP_TYPE_RC=$?
check_eq "wrong-typed companion rejects the whole composed write (exit 4)" "4" "$COMP_TYPE_RC"
check_eq "composed type rejection names the companion field" "1" \
  "$(grep -c "field '.active_agents' would become type 'string' but must be 'array'" <<<"$COMP_TYPE_OUT")"
check_eq "composed type rejection left the file byte-unchanged" "$BEFORE_DOC" "$(cat "$STATE_FILE")"
check_eq "composed type rejection did not write the CAS target" "null" \
  "$(jq -r '.slot // "null"' "$STATE_FILE")"

# ...and the mirror: a wrong-typed CAS target takes its valid companion down too.
reset_state
GOOD_ARR='["2026-04-29T22:30:00Z"]'
run --repo test/repo --set ".prs[\"999\"].cr_explicit_triggers=$GOOD_ARR"
BEFORE_DOC="$(cat "$STATE_FILE")"
COMP_T2_RC=0
run --repo test/repo --cas '.prs["999"].cr_explicit_triggers=2' --expect "$GOOD_ARR" \
  --set '.prs["999"].phase=B' >/dev/null 2>&1 || COMP_T2_RC=$?
check_eq "wrong-typed CAS target rejects its valid companion too (exit 4)" "4" "$COMP_T2_RC"
check_eq "composed target rejection left the file byte-unchanged" "$BEFORE_DOC" "$(cat "$STATE_FILE")"
check_eq "composed target rejection did not write the valid companion" "null" \
  "$(jq -r '.repos["test/repo"].prs["999"].phase // "null"' "$STATE_FILE")"

# A composed --set is repo-scoped exactly as a standalone --set is (issue #638):
# built by the same helper, so it cannot land at the document root instead.
reset_state
SCOPE_RC=0
run --repo test/cas-repo --cas '.prs["7"].phase=A' --expect null \
  --set '.prs["7"].reviewer=cr' || SCOPE_RC=$?
check_eq "composed scoped write exits 0" "0" "$SCOPE_RC"
check_eq "composed companion landed under the repo scope" "cr" \
  "$(jq -r '.repos["test/cas-repo"].prs["7"].reviewer' "$STATE_FILE")"
check_eq "composed companion did NOT land at the document root" "null" \
  "$(jq -r '.prs // "null"' "$STATE_FILE")"

# Under real contention: exactly one composed claimant wins, and the loser's
# companions are absent — the all-or-nothing property across processes, not
# just serially. The two writers carry DIFFERENT companion values, so a mixed
# record (one path's cause beside the other path's metadata) is detectable.
reset_state
run --raw-path --set '.rec={"cause":null,"kind":null,"hits":0}'
CW1="$RACE_DIR/cw1.rc"; CW2="$RACE_DIR/cw2.rc"
( bash "$SCRIPT" --raw-path --cas '.rec.cause="alpha"' --expect null \
    --set '.rec.kind=alpha-kind' --set '.rec.hits=1' >/dev/null 2>&1; printf '%s' "$?" > "$CW1" ) &
( bash "$SCRIPT" --raw-path --cas '.rec.cause="beta"' --expect null \
    --set '.rec.kind=beta-kind' --set '.rec.hits=99' >/dev/null 2>&1; printf '%s' "$?" > "$CW2" ) &
wait
CW1_RC="$(cat "$CW1" 2>/dev/null || printf 'missing')"
CW2_RC="$(cat "$CW2" 2>/dev/null || printf 'missing')"
CWINS=0; CLOSSES=0
[[ "$CW1_RC" == "0" ]] && CWINS=$((CWINS+1)); [[ "$CW1_RC" == "7" ]] && CLOSSES=$((CLOSSES+1))
[[ "$CW2_RC" == "0" ]] && CWINS=$((CWINS+1)); [[ "$CW2_RC" == "7" ]] && CLOSSES=$((CLOSSES+1))
check_eq "composed race: exactly one writer wins" "1" "$CWINS"
check_eq "composed race: exactly one writer gets CAS-loss 7" "1" "$CLOSSES"
RACE_REC="$(jq -c '.rec' "$STATE_FILE")"
case "$RACE_REC" in
  '{"cause":"alpha","kind":"alpha-kind","hits":1}'|'{"cause":"beta","kind":"beta-kind","hits":99}')
    PASS=$((PASS + 1)); echo "ok   — composed race: the surviving record is entirely one writer's" ;;
  *)
    FAIL=$((FAIL + 1)); echo "FAIL — composed race: record mixes both writers or is partial ($RACE_REC)" ;;
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
