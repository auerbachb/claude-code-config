#!/usr/bin/env bash
# Unit tests for session-state.sh's field-type contract (issue #625 — a
# caller passed an unevaluated jq filter expression as a --set value; since
# it wasn't valid JSON it silently fell into the --arg (string) branch and
# corrupted .active_agents into a literal string). Uses a temporary HOME so
# it never touches the real ~/.claude/. Requires jq. Run from repo root:
#   bash .claude/scripts/tests/session-state.test.sh
set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
SCRIPT="$REPO_ROOT/.claude/scripts/session-state.sh"

TMP_HOME="$(mktemp -d)"
cleanup() { rm -rf "$TMP_HOME"; }
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

echo "== Write-time guard: reject the exact ticket reproduction =="
reset_state
OUT=$(run --set '.active_agents=(.active_agents // [] | map(select(.pr_number != 71)))' 2>&1); RC=$?
check_eq "unevaluated jq filter rejected (exit 4)" "4" "$RC"
check_eq "error names the field and both types" "1" "$(grep -c "field '.active_agents' would become type 'string' but must be 'array'" <<<"$OUT")"
check_eq "state file never created for a rejected write" "1" "$([[ ! -f "$STATE_FILE" ]] && echo 1 || echo 0)"

echo
echo "== Write-time guard: accepting a valid array write =="
reset_state
run --set '.active_agents=[{"id":"a1","pr":71}]'
check_eq "valid array write exits 0" "0" "$?"
check_eq "active_agents holds the written array" '[{"id":"a1","pr":71}]' "$(jq -c '.active_agents' "$STATE_FILE")"

echo
echo "== Write-time guard: rejecting a wrong-type (object) write to an array field =="
OUT=$(run --set '.active_agents={"oops":true}' 2>&1); RC=$?
check_eq "object-for-array rejected (exit 4)" "4" "$RC"
check_eq "prior valid array data is untouched after the rejected write" '[{"id":"a1","pr":71}]' "$(jq -c '.active_agents' "$STATE_FILE")"

echo
echo "== Write-time guard: rejecting a wrong-type (bare scalar string) write to an array field =="
OUT=$(run --set '.active_agents=notjson' 2>&1); RC=$?
check_eq "scalar-for-array rejected (exit 4)" "4" "$RC"
check_eq "prior valid array data is still untouched" '[{"id":"a1","pr":71}]' "$(jq -c '.active_agents' "$STATE_FILE")"

echo
echo "== Write-time guard: element/sub-path writes validated against the FINAL field type =="
reset_state
run --set '.active_agents=[{"id":"pmm-fix-71","pr":71}]'
run --set '.active_agents[0].status="done"'
check_eq "sub-path write on a known array field exits 0" "0" "$?"
check_eq "sub-path write preserved array-ness and applied the edit" '[{"id":"pmm-fix-71","pr":71,"status":"done"}]' "$(jq -c '.active_agents' "$STATE_FILE")"

echo
echo "== Write-time guard: bracket-notation top-level paths are not a bypass (CodeAnt finding, PR #630) =="
reset_state
OUT=$(run --set '.["active_agents"]=corrupted string value' 2>&1); RC=$?
check_eq "bracket-notation write rejected (exit 4)" "4" "$RC"
check_eq "error still names active_agents" "1" "$(grep -c "field '.active_agents' would become type 'string' but must be 'array'" <<<"$OUT")"
check_eq "state file never created for a rejected bracket-notation write" "1" "$([[ ! -f "$STATE_FILE" ]] && echo 1 || echo 0)"

run --set '.["active_agents"]=[{"id":"a1"}]'
check_eq "valid array write via bracket notation exits 0" "0" "$?"
check_eq "bracket-notation write applied correctly" '[{"id":"a1"}]' "$(jq -c '.active_agents' "$STATE_FILE")"

echo
echo "== Read-time guard: bracket-notation top-level paths are not a bypass (CodeAnt finding, PR #630) =="
printf '%s\n' '{"active_agents": "corrupted string value"}' > "$STATE_FILE"
ERR_FILE="$(mktemp)"
OUT=$(run --get '.["active_agents"]' 2>"$ERR_FILE"); RC=$?
check_eq "bracket-notation corrupted --get still exits 0" "0" "$RC"
check_eq "bracket-notation corrupted --get returns the safe default '[]'" "[]" "$OUT"
check_eq "bracket-notation corrupted --get warns on stderr" "1" "$(grep -c "field '.\[\"active_agents\"\]' is corrupted — expected array but found string" "$ERR_FILE")"
rm -f "$ERR_FILE"

echo
echo "== Write-time guard: object-typed field (prs) contract, not just active_agents-specific =="
reset_state
OUT=$(run --set '.prs=[1,2,3]' 2>&1); RC=$?
check_eq "array-for-object rejected (exit 4)" "4" "$RC"
check_eq "error names prs and the object/array types" "1" "$(grep -c "field '.prs' would become type 'array' but must be 'object'" <<<"$OUT")"
check_eq "prs was never created by the rejected write" "1" "$([[ ! -f "$STATE_FILE" ]] && echo 1 || echo 0)"

run --set '.prs["287"].reviewer=greptile'
check_eq "valid nested object write to prs exits 0" "0" "$?"
check_eq "prs holds the nested write" '{"287":{"reviewer":"greptile"}}' "$(jq -c '.prs' "$STATE_FILE")"

run --set '.prs["287"].blocker=null'
check_eq "nulling a nested prs field does not trip the object-type guard" "0" "$?"
check_eq "prs stays an object with the null applied" '{"287":{"reviewer":"greptile","blocker":null}}' "$(jq -c '.prs' "$STATE_FILE")"

echo
echo "== Write-time guard: per-PR nested field contract (issue #640) =="
reset_state
OUT=$(run --set '.prs["999"].last_cron_action=some bare string' 2>&1); RC=$?
check_eq "bare-string last_cron_action rejected (exit 4)" "4" "$RC"
check_eq "error names the nested field and both types" "1" "$(grep -c "field '.prs\[\"999\"\].last_cron_action' would become type 'string' but must be 'object'" <<<"$OUT")"
check_eq "state file never created for a rejected nested write" "1" "$([[ ! -f "$STATE_FILE" ]] && echo 1 || echo 0)"

run --set '.prs["999"].last_cron_action={"type":"create","at":"2026-04-29T13:55:00Z","interval":"1m"}'
check_eq "well-formed last_cron_action object accepted" "0" "$?"
check_eq "last_cron_action holds the written object" '{"type":"create","at":"2026-04-29T13:55:00Z","interval":"1m"}' "$(jq -c '.prs["999"].last_cron_action' "$STATE_FILE")"

OUT=$(run --set '.prs["999"].last_cron_action=overwritten with a bad string' 2>&1); RC=$?
check_eq "a subsequent bad overwrite is still rejected (exit 4)" "4" "$RC"
check_eq "the prior good value is untouched by the rejected overwrite" '{"type":"create","at":"2026-04-29T13:55:00Z","interval":"1m"}' "$(jq -c '.prs["999"].last_cron_action' "$STATE_FILE")"

run --set '.prs["999"].reviewer=greptile'
check_eq "a nested field NOT on the known list stays unvalidated" "0" "$?"
check_eq "the unknown nested field is written as given" '"greptile"' "$(jq -c '.prs["999"].reviewer' "$STATE_FILE")"

OUT=$(run --set '.prs["999"].babysit.active=true' 2>&1); RC=$?
check_eq "sub-path write into a known object-typed nested field is accepted" "0" "$RC"
check_eq "babysit ends up an object with the sub-path write applied" '{"active":true}' "$(jq -c '.prs["999"].babysit' "$STATE_FILE")"

run --set '.prs["999"].cr_explicit_triggers=["2026-04-29T22:30:00Z"]'
check_eq "well-formed array cr_explicit_triggers accepted" "0" "$?"
OUT=$(run --set '.prs["999"].cr_explicit_triggers=2' 2>&1); RC=$?
check_eq "number-for-array cr_explicit_triggers rejected (exit 4)" "4" "$RC"
check_eq "error names cr_explicit_triggers and both types" "1" "$(grep -c "field '.prs\[\"999\"\].cr_explicit_triggers' would become type 'number' but must be 'array'" <<<"$OUT")"
check_eq "prior valid cr_explicit_triggers array is untouched" '["2026-04-29T22:30:00Z"]' "$(jq -c '.prs["999"].cr_explicit_triggers' "$STATE_FILE")"

OUT=$(run --set '.prs["998"].digest_streak=not-a-number' 2>&1); RC=$?
check_eq "string-for-number digest_streak rejected (exit 4)" "4" "$RC"
run --set '.prs["998"].digest_streak=3'
check_eq "well-formed number digest_streak accepted" "0" "$?"
check_eq "digest_streak holds the written number" "3" "$(jq -c '.prs["998"].digest_streak' "$STATE_FILE")"

echo
echo "== Write-time guard: whole-PR-entry writes (issue #640, CodeAnt finding on PR #654) =="
reset_state
OUT=$(run --set '.prs["999"]={"phase":"B","last_cron_action":"bare string","digest_streak":"not-a-number"}' 2>&1); RC=$?
check_eq "whole-entry write embedding a malformed known field rejected (exit 4)" "4" "$RC"
check_eq "error names the embedded nested field" "1" "$(grep -c "field '.prs\[\"999\"\].last_cron_action' would become type 'string' but must be 'object'" <<<"$OUT")"
check_eq "state file never created for a rejected whole-entry write" "1" "$([[ ! -f "$STATE_FILE" ]] && echo 1 || echo 0)"

run --set '.prs["999"]={"phase":"B","last_cron_action":{"type":"create","at":"2026-01-01T00:00:00Z"},"digest_streak":3,"reviewer":"greptile"}'
check_eq "well-formed whole-entry write accepted" "0" "$?"
check_eq "whole-entry write applied correctly" '{"phase":"B","last_cron_action":{"type":"create","at":"2026-01-01T00:00:00Z"},"digest_streak":3,"reviewer":"greptile"}' "$(jq -c '.prs["999"]' "$STATE_FILE")"

run --set '.prs["1000"]={"phase":"A","reviewer":"cr"}'
check_eq "whole-entry write with no known nested fields at all accepted" "0" "$?"
check_eq "entry with no known fields written as given" '{"phase":"A","reviewer":"cr"}' "$(jq -c '.prs["1000"]' "$STATE_FILE")"

echo
echo "== Write-time guard: unknown fields stay unvalidated (forward-compat) =="
run --set '.monitoring_active=true' --set '.root_repo=/tmp/foo'
check_eq "unknown-field batch write exits 0" "0" "$?"
check_eq "unknown fields written as given" '{"monitoring_active":true,"root_repo":"/tmp/foo"}' "$(jq -c '{monitoring_active, root_repo}' "$STATE_FILE")"

echo
echo "== Read-time guard: --get on a pre-corrupted known array field =="
printf '%s\n' '{"active_agents": "corrupted string value"}' > "$STATE_FILE"
ERR_FILE="$(mktemp)"
OUT=$(run --get '.active_agents' 2>"$ERR_FILE"); RC=$?
check_eq "corrupted --get still exits 0 (self-healing default, not an error)" "0" "$RC"
check_eq "corrupted --get returns the safe default '[]'" "[]" "$OUT"
check_eq "corrupted --get warns on stderr naming the field and types" "1" "$(grep -c "field '.active_agents' is corrupted — expected array but found string" "$ERR_FILE")"
rm -f "$ERR_FILE"

echo
echo "== Read-time guard: --get on an absent (null) known field is NOT treated as corruption =="
printf '%s\n' '{}' > "$STATE_FILE"
OUT=$(run --get '.active_agents' 2>&1); RC=$?
check_eq "absent field --get still exits 0" "0" "$RC"
check_eq "absent field --get returns literal 'null' (existing caller idiom, unchanged)" "null" "$OUT"

echo
echo "== Read-time guard: self-healing via the documented read-filter-write pattern =="
printf '%s\n' '{"active_agents": [{"id":"pmm-fix-71","pr":71},{"id":"pmm-fix-99","pr":99}]}' > "$STATE_FILE"
CURRENT_AGENTS=$(run --get '.active_agents' 2>/dev/null || echo null)
[ "$CURRENT_AGENTS" = "null" ] && CURRENT_AGENTS='[]'
FILTERED_AGENTS=$(jq --arg id "pmm-fix-71" '[.[] | select(.id != $id)]' <<<"$CURRENT_AGENTS")
run --set ".active_agents=$FILTERED_AGENTS"
check_eq "read-filter-write round trip exits 0" "0" "$?"
check_eq "read-filter-write round trip removed the targeted entry" '[{"id":"pmm-fix-99","pr":99}]' "$(jq -c '.active_agents' "$STATE_FILE")"

echo
echo "== summary: $PASS passed, $FAIL failed =="
if [[ "$FAIL" -eq 0 ]]; then
  echo "OK: session-state.sh field-type contract tests passed"
  exit 0
else
  echo "FAILURE: $FAIL session-state.sh test(s) failed"
  exit 1
fi
