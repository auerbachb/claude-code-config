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
# `.prs` is repo-scoped since issue #638, so the guard now fires on
# `.repos["<repo>"].prs` — the same contract, one level down. --repo pins the
# scope so the assertions do not depend on the checkout running the test.
reset_state
OUT=$(run --repo test/repo --set '.prs=[1,2,3]' 2>&1); RC=$?
check_eq "array-for-object rejected (exit 4)" "4" "$RC"
check_eq "error names the scoped prs and the object/array types" "1" "$(grep -c "field '.repos\[\"test/repo\"\].prs' would become type 'array' but must be 'object'" <<<"$OUT")"
check_eq "prs was never created by the rejected write" "1" "$([[ ! -f "$STATE_FILE" ]] && echo 1 || echo 0)"

run --repo test/repo --set '.prs["287"].reviewer=greptile'
check_eq "valid nested object write to prs exits 0" "0" "$?"
check_eq "scoped prs holds the nested write" '{"287":{"reviewer":"greptile"}}' "$(jq -c '.repos["test/repo"].prs' "$STATE_FILE")"
check_eq "no flat top-level .prs is created" "null" "$(jq -c '.prs' "$STATE_FILE")"

run --repo test/repo --set '.prs["287"].blocker=null'
check_eq "nulling a nested prs field does not trip the object-type guard" "0" "$?"
check_eq "scoped prs stays an object with the null applied" '{"287":{"reviewer":"greptile","blocker":null}}' "$(jq -c '.repos["test/repo"].prs' "$STATE_FILE")"

echo
echo "== Repo scoping: same PR number in two repos does not collide (issue #638) =="
reset_state
run --repo org/a --set '.prs["84"].phase=B'
run --repo org/b --set '.prs["84"].phase=C'
check_eq "repo A keeps its own PR 84" "B" "$(run --repo org/a --get '.prs["84"].phase')"
check_eq "repo B keeps its own PR 84" "C" "$(run --repo org/b --get '.prs["84"].phase')"
check_eq "a third repo sees neither" "null" "$(run --repo org/c --get '.prs["84"].phase')"
check_eq "root_repo is per-repo, not one global scalar" "null" "$(jq -c '.root_repo' "$STATE_FILE")"
run --repo org/a --set '.root_repo=/tmp/a'
run --repo org/b --set '.root_repo=/tmp/b'
check_eq "each repo keeps its own root_repo" '["/tmp/a","/tmp/b"]' "$(jq -c '[.repos["org/a"].root_repo, .repos["org/b"].root_repo]' "$STATE_FILE")"

echo
echo "== --raw-path addresses the document root verbatim =="
check_eq "raw-path reads the real top-level shape" '"org/a","org/b"' "$(run --raw-path --get '.repos | keys | @csv')"

echo
echo "== Write-time guard: per-PR nested field contract (issue #640) =="
# Paths are scoped per repo since issue #638: callers still write `.prs["999"]`,
# but it lands at `.repos["test/repo"].prs["999"]`, and the guard names it there.
reset_state
OUT=$(run --repo test/repo --set '.prs["999"].last_cron_action=some bare string' 2>&1); RC=$?
check_eq "bare-string last_cron_action rejected (exit 4)" "4" "$RC"
check_eq "error names the nested field and both types" "1" "$(grep -c "field '.repos\[\"test/repo\"\].prs\[\"999\"\].last_cron_action' would become type 'string' but must be 'object'" <<<"$OUT")"
check_eq "state file never created for a rejected nested write" "1" "$([[ ! -f "$STATE_FILE" ]] && echo 1 || echo 0)"

run --repo test/repo --set '.prs["999"].last_cron_action={"type":"create","at":"2026-04-29T13:55:00Z","interval":"1m"}'
check_eq "well-formed last_cron_action object accepted" "0" "$?"
check_eq "last_cron_action holds the written object" '{"type":"create","at":"2026-04-29T13:55:00Z","interval":"1m"}' "$(jq -c '.repos["test/repo"].prs["999"].last_cron_action' "$STATE_FILE")"

OUT=$(run --repo test/repo --set '.prs["999"].last_cron_action=overwritten with a bad string' 2>&1); RC=$?
check_eq "a subsequent bad overwrite is still rejected (exit 4)" "4" "$RC"
check_eq "the prior good value is untouched by the rejected overwrite" '{"type":"create","at":"2026-04-29T13:55:00Z","interval":"1m"}' "$(jq -c '.repos["test/repo"].prs["999"].last_cron_action' "$STATE_FILE")"

run --repo test/repo --set '.prs["999"].reviewer=greptile'
check_eq "a nested field NOT on the known list stays unvalidated" "0" "$?"
check_eq "the unknown nested field is written as given" '"greptile"' "$(jq -c '.repos["test/repo"].prs["999"].reviewer' "$STATE_FILE")"

OUT=$(run --repo test/repo --set '.prs["999"].babysit.active=true' 2>&1); RC=$?
check_eq "sub-path write into a known object-typed nested field is accepted" "0" "$RC"
check_eq "babysit ends up an object with the sub-path write applied" '{"active":true}' "$(jq -c '.repos["test/repo"].prs["999"].babysit' "$STATE_FILE")"

run --repo test/repo --set '.prs["999"].cr_explicit_triggers=["2026-04-29T22:30:00Z"]'
check_eq "well-formed array cr_explicit_triggers accepted" "0" "$?"
OUT=$(run --repo test/repo --set '.prs["999"].cr_explicit_triggers=2' 2>&1); RC=$?
check_eq "number-for-array cr_explicit_triggers rejected (exit 4)" "4" "$RC"
check_eq "error names cr_explicit_triggers and both types" "1" "$(grep -c "field '.repos\[\"test/repo\"\].prs\[\"999\"\].cr_explicit_triggers' would become type 'number' but must be 'array'" <<<"$OUT")"
check_eq "prior valid cr_explicit_triggers array is untouched" '["2026-04-29T22:30:00Z"]' "$(jq -c '.repos["test/repo"].prs["999"].cr_explicit_triggers' "$STATE_FILE")"

OUT=$(run --repo test/repo --set '.prs["998"].digest_streak=not-a-number' 2>&1); RC=$?
check_eq "string-for-number digest_streak rejected (exit 4)" "4" "$RC"
run --repo test/repo --set '.prs["998"].digest_streak=3'
check_eq "well-formed number digest_streak accepted" "0" "$?"
check_eq "digest_streak holds the written number" "3" "$(jq -c '.repos["test/repo"].prs["998"].digest_streak' "$STATE_FILE")"

# allow_nonauthor (issue #1266) gates a safety guard: polling-state-gate.sh
# forwards --allow-nonauthor to merge-gate.sh when it reads the literal boolean
# true, so a string "true" must be refused at write time rather than stored and
# later compared as if it were the boolean.
run --repo test/repo --set '.prs["998"].allow_nonauthor=true'
check_eq "boolean allow_nonauthor accepted" "0" "$?"
check_eq "allow_nonauthor stored as a JSON boolean" "boolean" \
  "$(jq -r '.repos["test/repo"].prs["998"].allow_nonauthor | type' "$STATE_FILE")"
OUT=$(run --repo test/repo --set '.prs["998"].allow_nonauthor="true"' 2>&1); RC=$?
check_eq "string-for-boolean allow_nonauthor rejected (exit 4)" "4" "$RC"
check_eq "error names allow_nonauthor and both types" "1" "$(grep -c "field '.repos\[\"test/repo\"\].prs\[\"998\"\].allow_nonauthor' would become type 'string' but must be 'boolean'" <<<"$OUT")"
check_eq "prior valid allow_nonauthor boolean is untouched" "true" \
  "$(jq -c '.repos["test/repo"].prs["998"].allow_nonauthor' "$STATE_FILE")"
run --repo test/repo --set '.prs["998"].allow_nonauthor=false'
check_eq "clearing allow_nonauthor to false accepted" "0" "$?"
check_eq "allow_nonauthor holds the cleared boolean" "false" \
  "$(jq -c '.repos["test/repo"].prs["998"].allow_nonauthor' "$STATE_FILE")"

echo
echo "== Write-time guard: whole-PR-entry writes (issue #640, CodeAnt finding on PR #654) =="
reset_state
OUT=$(run --repo test/repo --set '.prs["999"]={"phase":"B","last_cron_action":"bare string","digest_streak":"not-a-number"}' 2>&1); RC=$?
check_eq "whole-entry write embedding a malformed known field rejected (exit 4)" "4" "$RC"
check_eq "error names the embedded nested field" "1" "$(grep -c "field '.repos\[\"test/repo\"\].prs\[\"999\"\].last_cron_action' would become type 'string' but must be 'object'" <<<"$OUT")"
check_eq "state file never created for a rejected whole-entry write" "1" "$([[ ! -f "$STATE_FILE" ]] && echo 1 || echo 0)"

run --repo test/repo --set '.prs["999"]={"phase":"B","last_cron_action":{"type":"create","at":"2026-01-01T00:00:00Z"},"digest_streak":3,"reviewer":"greptile"}'
check_eq "well-formed whole-entry write accepted" "0" "$?"
check_eq "whole-entry write applied correctly" '{"phase":"B","last_cron_action":{"type":"create","at":"2026-01-01T00:00:00Z"},"digest_streak":3,"reviewer":"greptile"}' "$(jq -c '.repos["test/repo"].prs["999"]' "$STATE_FILE")"

run --repo test/repo --set '.prs["1000"]={"phase":"A","reviewer":"cr"}'
check_eq "whole-entry write with no known nested fields at all accepted" "0" "$?"
check_eq "entry with no known fields written as given" '{"phase":"A","reviewer":"cr"}' "$(jq -c '.repos["test/repo"].prs["1000"]' "$STATE_FILE")"

echo
echo "== Write-time guard: unknown fields stay unvalidated (forward-compat) =="
run --set '.monitoring_active=true' --set '.some_future_field=/tmp/foo'
check_eq "unknown-field batch write exits 0" "0" "$?"
check_eq "unknown fields written as given" '{"monitoring_active":true,"some_future_field":"/tmp/foo"}' "$(jq -c '{monitoring_active, some_future_field}' "$STATE_FILE")"

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
echo "== --session-view: repo-scoped projection of the whole document (issue #687) =="
# Two repos + global fields + an orphan/unattributable agent in one file.
cat > "$STATE_FILE" <<'JSON'
{
  "schema_version": 2,
  "monitoring_active": true,
  "greptile_daily": {"date":"2026-07-21","reviews_used":3,"budget":40},
  "active_agents": [
    {"id":"a-mine","task":"PR #84 Phase B","pr":84,"phase":"B"},
    {"id":"a-other","task":"PR #200 Phase A","pr":200,"phase":"A"},
    {"id":"a-orphan","task":"PR #999 Phase C","pr":999,"phase":"C"},
    {"id":"a-nopr","task":"scan backlog"}
  ],
  "repos": {
    "org/a": {"prs": {"84": {"phase":"B","reviewer":"cr"}}, "root_repo":"/tmp/a"},
    "org/b": {"prs": {"200": {"phase":"A","reviewer":"cr"}}, "root_repo":"/tmp/b"}
  }
}
JSON
VIEW_A="$(run --repo org/a --session-view)"
check_eq "scoped view exits 0" "0" "$?"
check_eq "prs is scoped to this repo only" '{"84":{"phase":"B","reviewer":"cr"}}' "$(jq -c '.prs' <<<"$VIEW_A")"
check_eq "root_repo is this repo's" "/tmp/a" "$(jq -r '.root_repo' <<<"$VIEW_A")"
check_eq ".repos aggregate is removed from the view" "null" "$(jq -c '.repos' <<<"$VIEW_A")"
check_eq ".repo names the resolved key" "org/a" "$(jq -r '.repo' <<<"$VIEW_A")"
check_eq "global fields pass through (monitoring_active)" "true" "$(jq -c '.monitoring_active' <<<"$VIEW_A")"
check_eq "global fields pass through (greptile_daily)" "3" "$(jq -c '.greptile_daily.reviews_used' <<<"$VIEW_A")"

echo
echo "== --session-view: active_agents scoped by PR-number attribution =="
# Keep: this repo's PR (a-mine), an unattributable PR tracked by no repo
# (a-orphan), and an entry with no .pr (a-nopr). Drop: another repo's PR (a-other).
check_eq "keeps mine + unattributable + no-pr, drops other-repo agents" '["a-mine","a-orphan","a-nopr"]' "$(jq -c '[.active_agents[].id]' <<<"$VIEW_A")"
# Reciprocal: org/b keeps only its own PR-200 agent.
VIEW_B="$(run --repo org/b --session-view)"
check_eq "reciprocal: org/b prs scoped to 200" '{"200":{"phase":"A","reviewer":"cr"}}' "$(jq -c '.prs' <<<"$VIEW_B")"
check_eq "reciprocal: org/b keeps a-other + unattributable, drops a-mine" '["a-other","a-orphan","a-nopr"]' "$(jq -c '[.active_agents[].id]' <<<"$VIEW_B")"

echo
echo "== --session-view --all-repos: explicit cross-repo opt-in (AC6) =="
VIEW_ALL="$(run --repo org/a --session-view --all-repos)"
check_eq "all-repos keeps the full .repos aggregate" '["org/a","org/b"]' "$(jq -c '.repos | keys' <<<"$VIEW_ALL")"
check_eq "all-repos does not flatten .prs to one repo" "null" "$(jq -c '.prs' <<<"$VIEW_ALL")"
check_eq "all-repos keeps every active_agent" '["a-mine","a-other","a-orphan","a-nopr"]' "$(jq -c '[.active_agents[].id]' <<<"$VIEW_ALL")"

echo
echo "== --session-view: repo resolved via \$CLAUDE_SESSION_REPO when no --repo (AC5) =="
VIEW_ENV="$(CLAUDE_SESSION_REPO=org/b run --session-view)"
check_eq "env-var repo scopes the view without --repo" '{"200":{"phase":"A","reviewer":"cr"}}' "$(jq -c '.prs' <<<"$VIEW_ENV")"
check_eq "env-var repo names the key" "org/b" "$(jq -r '.repo' <<<"$VIEW_ENV")"
# --repo overrides $CLAUDE_SESSION_REPO (precedence order).
VIEW_OVERRIDE="$(CLAUDE_SESSION_REPO=org/b run --repo org/a --session-view)"
check_eq "--repo wins over \$CLAUDE_SESSION_REPO" "org/a" "$(jq -r '.repo' <<<"$VIEW_OVERRIDE")"

echo
echo "== --session-view: same PR number in two repos + explicit owner_repo (issue #687) =="
# PR 84 is tracked by BOTH repos. An un-tagged agent {pr:84} is therefore
# ambiguous and dropped from the scoped view; an agent carrying owner_repo is
# attributed exactly regardless of the collision.
cat > "$STATE_FILE" <<'JSON'
{
  "active_agents": [
    {"id":"ambiguous-84","pr":84},
    {"id":"tagged-a","pr":84,"owner_repo":"org/a"},
    {"id":"tagged-b","pr":84,"owner_repo":"org/b"},
    {"id":"tagged-a-nopr","owner_repo":"org/a"}
  ],
  "repos": {
    "org/a": {"prs": {"84": {"phase":"A"}}},
    "org/b": {"prs": {"84": {"phase":"B"}}}
  }
}
JSON
VIEW_COLLIDE_A="$(run --repo org/a --session-view)"
check_eq "ambiguous same-PR agent dropped; owner_repo attributed exactly (org/a)" '["tagged-a","tagged-a-nopr"]' "$(jq -c '[.active_agents[].id]' <<<"$VIEW_COLLIDE_A")"
check_eq "collision: org/a prs still scoped to its own PR 84 entry" '{"84":{"phase":"A"}}' "$(jq -c '.prs' <<<"$VIEW_COLLIDE_A")"
VIEW_COLLIDE_B="$(run --repo org/b --session-view)"
check_eq "reciprocal: org/b keeps only its owner_repo-tagged agent" '["tagged-b"]' "$(jq -c '[.active_agents[].id]' <<<"$VIEW_COLLIDE_B")"

echo
echo "== --session-view: legacy flat file is migrated in memory then scoped =="
# A pre-#638 flat file carrying owner_repo attribution should scope correctly
# without the read rewriting the file (migration is in-memory for reads).
cat > "$STATE_FILE" <<'JSON'
{"prs": {"84": {"phase":"B","owner_repo":"org/a"}, "200": {"phase":"A","owner_repo":"org/b"}}}
JSON
VIEW_LEGACY="$(run --repo org/a --session-view)"
check_eq "legacy file: scoped prs contains only org/a's PR" "84" "$(jq -r '.prs | keys | join(",")' <<<"$VIEW_LEGACY")"
check_eq "legacy file: read did not rewrite the file (still flat .prs)" '{"84":{"phase":"B","owner_repo":"org/a"},"200":{"phase":"A","owner_repo":"org/b"}}' "$(jq -c '.prs' "$STATE_FILE")"

echo
echo "== --session-view: missing state file exits 3 (matches --get) =="
reset_state
OUT=$(run --session-view 2>/dev/null); RC=$?
check_eq "missing file exits 3" "3" "$RC"

echo
echo "== --session-view: empty-but-valid file yields an empty scoped view =="
printf '%s\n' '{}' > "$STATE_FILE"
VIEW_EMPTY="$(run --repo org/none --session-view)"
check_eq "empty file exits 0 with empty prs" "{}" "$(jq -c '.prs' <<<"$VIEW_EMPTY")"
check_eq "empty file: active_agents defaults to []" "[]" "$(jq -c '.active_agents' <<<"$VIEW_EMPTY")"
check_eq "empty file: root_repo is null" "null" "$(jq -c '.root_repo' <<<"$VIEW_EMPTY")"

echo
echo "== --session-view: _unknown does not mask PR attribution (issue #712) =="
# Three cases for active_agents entries (no owner_repo, correlated by .pr):
#   PR 501 — lives ONLY under _unknown         → agent retained (unattributed)
#   PR 502 — lives under a real other repo     → agent dropped  (other repo wins)
#   PR 503 — lives under BOTH _unknown and a   → agent dropped  (real repo wins
#              real other repo                    even when _unknown also has it)
cat > "$STATE_FILE" <<'JSON'
{
  "active_agents": [
    {"id":"only-unknown","pr":501},
    {"id":"real-other","pr":502},
    {"id":"both-unknown-and-real","pr":503}
  ],
  "repos": {
    "org/invoking": {"prs": {"600": {"phase":"A"}}},
    "org/other":    {"prs": {"502": {"phase":"B"}, "503": {"phase":"C"}}},
    "_unknown":     {"prs": {"501": {"phase":"A"}, "503": {"phase":"A"}}}
  }
}
JSON
VIEW_712="$(run --repo org/invoking --session-view)"
check_eq "#712: agent with PR only in _unknown is retained" '["only-unknown"]' \
  "$(jq -c '[.active_agents[].id]' <<<"$VIEW_712")"
check_eq "#712: agent with PR in a real other repo is dropped" "0" \
  "$(jq '[.active_agents[].id] | map(select(. == "real-other")) | length' <<<"$VIEW_712")"
check_eq "#712: agent with PR in both _unknown and a real other repo is dropped" "0" \
  "$(jq '[.active_agents[].id] | map(select(. == "both-unknown-and-real")) | length' <<<"$VIEW_712")"
# Confirm the invoking repo's own PRs still scope correctly alongside.
check_eq "#712: invoking repo prs unaffected" '{"600":{"phase":"A"}}' \
  "$(jq -c '.prs' <<<"$VIEW_712")"

echo
echo "== --set: value type coercion (issue #853) =="
# The literal-vs-string probe must accept exactly what `--argjson` accepts.
# `jq -e .` keys off output truthiness, so `false`/`null` fail it and become the
# strings "false"/"null" ("false" is truthy in jq). `jq empty` overshoots the
# other way: it accepts empty and whitespace-only input that `--argjson` then
# rejects, hard-failing the write. Probing with `--argjson` itself gets both
# ends right. session-state.sh already resisted the false/null half of this;
# these tests pin the whole contract so neither end regresses.
reset_state
run --repo test/repo --set '.prs["853"].merge_gate_met=false'
check_eq "--set false exits 0" "0" "$?"
check_eq "false stored as boolean" "boolean" \
  "$(jq -r '.repos["test/repo"].prs["853"].merge_gate_met | type' "$STATE_FILE")"
check_eq "stored false is falsy in jq" "not-taken" \
  "$(jq -r 'if .repos["test/repo"].prs["853"].merge_gate_met then "taken" else "not-taken" end' "$STATE_FILE")"

run --repo test/repo --set '.prs["853"].blocker=null'
check_eq "null stored as null type" "null" \
  "$(jq -r '.repos["test/repo"].prs["853"].blocker | type' "$STATE_FILE")"

run --repo test/repo --set '.prs["853"].ci_green=true'
check_eq "true stored as boolean" "boolean" \
  "$(jq -r '.repos["test/repo"].prs["853"].ci_green | type' "$STATE_FILE")"

run --repo test/repo --set '.prs["853"].digest_streak=7'
check_eq "number stored as number" "number" \
  "$(jq -r '.repos["test/repo"].prs["853"].digest_streak | type' "$STATE_FILE")"

run --repo test/repo --set '.prs["853"].phase=B'
check_eq "bare word stored as string" "string" \
  "$(jq -r '.repos["test/repo"].prs["853"].phase | type' "$STATE_FILE")"
check_eq "bare word value round-trips" "B" \
  "$(jq -r '.repos["test/repo"].prs["853"].phase' "$STATE_FILE")"

run --repo test/repo --set '.prs["853"].reviewer="quoted"'
check_eq "quoted JSON string decoded exactly once" "quoted" \
  "$(jq -r '.repos["test/repo"].prs["853"].reviewer' "$STATE_FILE")"

run --repo test/repo --set '.prs["853"].blocker='
check_eq "--set empty value exits 0" "0" "$?"
check_eq "empty value stored as empty string" "string" \
  "$(jq -r '.repos["test/repo"].prs["853"].blocker | type' "$STATE_FILE")"

run --repo test/repo --set '.prs["853"].blocker= '
check_eq "--set single-space value exits 0 (not a write failure)" "0" "$?"
check_eq "single space stored as string" "string" \
  "$(jq -r '.repos["test/repo"].prs["853"].blocker | type' "$STATE_FILE")"
check_eq "single space preserved verbatim" " " \
  "$(jq -r '.repos["test/repo"].prs["853"].blocker' "$STATE_FILE")"

run --repo test/repo --set ".prs[\"853\"].blocker=$(printf '\t')"
check_eq "--set tab-only value exits 0" "0" "$?"
check_eq "tab preserved verbatim" "$(printf '\t')" \
  "$(jq -r '.repos["test/repo"].prs["853"].blocker' "$STATE_FILE")"

echo
echo "== Telemetry must never change the exit contract (issue #1430) =="
# The usage-log append ran unguarded inside the CLAUDE_SCRIPT_USAGE_LOG
# conditional: with no ~/.claude under HOME, `set -e` killed the script at
# that line before argument parsing. It must fall through silently instead
# (stderr-first ordering per issue #1406). This block covers HOME set to a
# directory with no ~/.claude in it; the unset-HOME contract is pinned
# separately below (issue #1434).
NOHOME="$TMP_HOME/no-such-home"
RC=0
ERR="$(HOME="$NOHOME" bash "$SCRIPT" --help 2>&1 >/dev/null)" || RC=$?
check_eq "--help exits 0 when \$HOME/.claude is missing" "0" "$RC"
check_eq "no stderr diagnostic when the log dir is missing" "" "$ERR"

echo
echo "== Unset HOME: cheap paths answer, load-bearing paths fail named (issue #1434) =="
# These assertions CHANGED deliberately in issue #1434. Issue #1430 guarded the
# telemetry line but left the STATE_FILE assignment one statement below it
# expanding ${HOME} unconditionally under `set -u`, so --help still died with
# `HOME: unbound variable` — which the probes here used to pin as the contract.
# The contract is now: --help (and every usage error, and --repo-key) answers
# without HOME; only modes that actually open the state file require it, and
# they fail with ONE named line and exit 8 rather than a bash trace.
RC=0
ERR="$(env -u HOME bash "$SCRIPT" --help 2>&1 >/dev/null)" || RC=$?
check_eq "unset HOME: --help exits 0" "0" "$RC"
check_eq "unset HOME: --help writes nothing to stderr" "" "$ERR"

# A usage error needs nothing from HOME either — it must still be exit 2.
RC=0
ERR="$(env -u HOME bash "$SCRIPT" --bogus-flag 2>&1 >/dev/null)" || RC=$?
check_eq "unset HOME: usage error still exits 2, not the HOME code" "2" "$RC"
check_eq "unset HOME: usage error names the flag, not HOME" "1" \
  "$(grep -c 'unknown flag: --bogus-flag' <<<"$ERR")"

# --repo-key resolves from --repo/\$CLAUDE_SESSION_REPO/cwd origin and never
# opens the state file, so it must not require HOME either.
RC=0
ERR="$(env -u HOME bash "$SCRIPT" --repo test/repo --repo-key 2>&1 >/dev/null)" || RC=$?
check_eq "unset HOME: --repo-key exits 0 (never opens the state file)" "0" "$RC"

# A HOME-REQUIRING run: --get must open ~/.claude/session-state.json.
RC=0
ERR="$(env -u HOME bash "$SCRIPT" --get '.active_agents' 2>&1 >/dev/null)" || RC=$?
check_eq "unset HOME: --get exits 8 (documented HOME-unset code)" "8" "$RC"
check_eq "unset HOME: --get emits the named error line" "1" \
  "$(grep -c 'session-state.sh: HOME is unset; cannot resolve ~/.claude/session-state.json' <<<"$ERR")"
check_eq "unset HOME: --get emits exactly one stderr line" "1" \
  "$(printf '%s\n' "$ERR" | grep -c .)"
check_eq "unset HOME: no bash unbound-variable trace survives" "0" \
  "$(grep -c 'unbound variable' <<<"$ERR")"
check_eq "unset HOME: the telemetry line is never the failure site" "0" \
  "$(grep -c 'script-usage.log' <<<"$ERR")"

# --set takes the same guard before it can create or lock anything.
RC=0
ERR="$(env -u HOME bash "$SCRIPT" --set '.active_agents=[]' 2>&1 >/dev/null)" || RC=$?
check_eq "unset HOME: --set exits 8 before any write is attempted" "8" "$RC"
check_eq "unset HOME: --set emits the named error line" "1" \
  "$(grep -c 'HOME is unset; cannot resolve' <<<"$ERR")"

# Positive control: append still lands when ~/.claude exists and the
# opt-out is not engaged.
: > "$HOME/.claude/script-usage.log"
bash "$SCRIPT" --help >/dev/null 2>&1
check_eq "append still lands when ~/.claude exists" "1" \
  "$(grep -c 'session-state.sh' "$HOME/.claude/script-usage.log")"

echo
echo "== summary: $PASS passed, $FAIL failed =="
if [[ "$FAIL" -eq 0 ]]; then
  echo "OK: session-state.sh field-type contract tests passed"
  exit 0
else
  echo "FAILURE: $FAIL session-state.sh test(s) failed"
  exit 1
fi
