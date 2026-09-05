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
# `.active_agents` is object-typed since issue #1631 (it was an array), so the
# ticket's unevaluated-jq-filter value is rejected as a string-for-OBJECT now.
# The array branch of the same contract is exercised below against
# `.polling_jobs`, which is still array-typed — the guard is per-field, and
# dropping the last array-typed case would leave that branch untested.
reset_state
OUT=$(run --set '.active_agents=(.active_agents // [] | map(select(.pr_number != 71)))' 2>&1); RC=$?
check_eq "unevaluated jq filter rejected (exit 4)" "4" "$RC"
check_eq "error names the field and both types" "1" "$(grep -c "field '.active_agents' would become type 'string' but must be 'object'" <<<"$OUT")"
check_eq "state file never created for a rejected write" "1" "$([[ ! -f "$STATE_FILE" ]] && echo 1 || echo 0)"

echo
echo "== Write-time guard: the array branch still fires (polling_jobs) =="
reset_state
OUT=$(run --set '.polling_jobs=(.polling_jobs // [] | map(select(.id != "x")))' 2>&1); RC=$?
check_eq "unevaluated jq filter on an array field rejected (exit 4)" "4" "$RC"
check_eq "error names polling_jobs and both types" "1" "$(grep -c "field '.polling_jobs' would become type 'string' but must be 'array'" <<<"$OUT")"
run --set '.polling_jobs=[{"id":"j1"}]'
check_eq "valid array write exits 0" "0" "$?"
check_eq "polling_jobs holds the written array" '[{"id":"j1"}]' "$(jq -c '.polling_jobs' "$STATE_FILE")"
OUT=$(run --set '.polling_jobs={"oops":true}' 2>&1); RC=$?
check_eq "object-for-array rejected (exit 4)" "4" "$RC"
check_eq "prior valid array data is untouched after the rejected write" '[{"id":"j1"}]' "$(jq -c '.polling_jobs' "$STATE_FILE")"

echo
echo "== Write-time guard: accepting a valid map write to active_agents =="
reset_state
run --set '.active_agents={"a1":{"id":"a1","pr":71}}'
check_eq "valid map write exits 0" "0" "$?"
check_eq "active_agents holds the written map" '{"a1":{"id":"a1","pr":71}}' "$(jq -c '.active_agents' "$STATE_FILE")"

echo
echo "== Write-time guard: rejecting a wrong-type (array) write to the map field =="
OUT=$(run --set '.active_agents=[{"id":"a1"}]' 2>&1); RC=$?
check_eq "array-for-object rejected (exit 4)" "4" "$RC"
check_eq "prior valid map data is untouched after the rejected write" '{"a1":{"id":"a1","pr":71}}' "$(jq -c '.active_agents' "$STATE_FILE")"

echo
echo "== Write-time guard: rejecting a wrong-type (bare scalar string) write to the map field =="
OUT=$(run --set '.active_agents=notjson' 2>&1); RC=$?
check_eq "scalar-for-object rejected (exit 4)" "4" "$RC"
check_eq "prior valid map data is still untouched" '{"a1":{"id":"a1","pr":71}}' "$(jq -c '.active_agents' "$STATE_FILE")"

echo
echo "== Write-time guard: element/sub-path writes validated against the FINAL field type =="
reset_state
run --set '.active_agents={"pmm-fix-71":{"id":"pmm-fix-71","pr":71}}'
run --set '.active_agents["pmm-fix-71"].status="done"'
check_eq "sub-path write on a known map field exits 0" "0" "$?"
check_eq "sub-path write preserved map-ness and applied the edit" '{"pmm-fix-71":{"id":"pmm-fix-71","pr":71,"status":"done"}}' "$(jq -c '.active_agents' "$STATE_FILE")"

echo
echo "== Write-time guard: bracket-notation top-level paths are not a bypass (CodeAnt finding, PR #630) =="
reset_state
OUT=$(run --set '.["active_agents"]=corrupted string value' 2>&1); RC=$?
check_eq "bracket-notation write rejected (exit 4)" "4" "$RC"
check_eq "error still names active_agents" "1" "$(grep -c "field '.active_agents' would become type 'string' but must be 'object'" <<<"$OUT")"
check_eq "state file never created for a rejected bracket-notation write" "1" "$([[ ! -f "$STATE_FILE" ]] && echo 1 || echo 0)"

run --set '.["active_agents"]={"a1":{"id":"a1"}}'
check_eq "valid map write via bracket notation exits 0" "0" "$?"
check_eq "bracket-notation write applied correctly" '{"a1":{"id":"a1"}}' "$(jq -c '.active_agents' "$STATE_FILE")"

echo
echo "== Read-time guard: bracket-notation top-level paths are not a bypass (CodeAnt finding, PR #630) =="
printf '%s\n' '{"active_agents": "corrupted string value"}' > "$STATE_FILE"
ERR_FILE="$(mktemp)"
OUT=$(run --get '.["active_agents"]' 2>"$ERR_FILE"); RC=$?
check_eq "bracket-notation corrupted --get still exits 0" "0" "$RC"
check_eq "bracket-notation corrupted --get returns the safe default '{}'" "{}" "$OUT"
check_eq "bracket-notation corrupted --get warns on stderr" "1" "$(grep -c "field '.\[\"active_agents\"\]' is corrupted — expected object but found string" "$ERR_FILE")"
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
echo "== Read-time guard: --get on a pre-corrupted known map field =="
printf '%s\n' '{"active_agents": "corrupted string value"}' > "$STATE_FILE"
ERR_FILE="$(mktemp)"
OUT=$(run --get '.active_agents' 2>"$ERR_FILE"); RC=$?
check_eq "corrupted --get still exits 0 (self-healing default, not an error)" "0" "$RC"
check_eq "corrupted --get returns the safe default '{}'" "{}" "$OUT"
check_eq "corrupted --get warns on stderr naming the field and types" "1" "$(grep -c "field '.active_agents' is corrupted — expected object but found string" "$ERR_FILE")"
rm -f "$ERR_FILE"

echo
echo "== Read-time guard: --get on an absent (null) known field is NOT treated as corruption =="
printf '%s\n' '{}' > "$STATE_FILE"
OUT=$(run --get '.active_agents' 2>&1); RC=$?
check_eq "absent field --get still exits 0" "0" "$RC"
check_eq "absent field --get returns literal 'null' (existing caller idiom, unchanged)" "null" "$OUT"

echo
echo "== Removing one agent: --remove-agent, the documented replacement for read-filter-write =="
# Before issue #1631 this was a --get, a local filter, and a --set of the whole
# array — two lock windows, so a sibling thread's append between them was lost.
# The targeted delete is now the only supported way to drop an agent record.
printf '%s\n' '{"active_agents": [{"id":"pmm-fix-71","pr":71},{"id":"pmm-fix-99","pr":99}]}' > "$STATE_FILE"
run --remove-agent "pmm-fix-71"
check_eq "--remove-agent exits 0" "0" "$?"
check_eq "--remove-agent removed the targeted entry and migrated the legacy array" \
  '{"pmm-fix-99":{"id":"pmm-fix-99","pr":99}}' "$(jq -c '.active_agents' "$STATE_FILE")"

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
check_eq "empty file: active_agents defaults to {}" "{}" "$(jq -c '.active_agents' <<<"$VIEW_EMPTY")"
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
echo "== Write-time guard: three uncovered write shapes (issue #1340) =="
# FAILS-WITHOUT-FIX: on origin/main every "rejected" assertion below returns 0
# and the malformed value is committed. Verified by running this block against
# the pre-fix session-state.sh; the two controls at the end of the block are
# rejected on both copies, so they prove the harness itself is sound.
SEEDED_PRS='{"schema_version":2,"repos":{"test/repo":{"prs":{"1":{"phase":"A"}}}}}'
seed_prs() { printf '%s\n' "$SEEDED_PRS" > "$STATE_FILE"; }

# --- Gap 1: a whole-entry write may carry a known field as an explicit null.
# The old scan skipped any key whose FINAL type was "null", which cannot tell
# an omitted key from one written as null — while the single-path write of the
# same null was (and still is) rejected. Presence is now decided with has().
seed_prs
BEFORE_DOC="$(cat "$STATE_FILE")"
OUT=$(run --repo test/repo --set '.prs["999"]={"phase":"B","last_cron_action":null}' 2>&1); RC=$?
check_eq "gap 1: whole-entry write with an explicit-null known field rejected (exit 4)" "4" "$RC"
check_eq "gap 1: error names the field and 'null' as the offending type" "1" \
  "$(grep -c "field '.repos\[\"test/repo\"\].prs\[\"999\"\].last_cron_action' would become type 'null' but must be 'object'" <<<"$OUT")"
check_eq "gap 1: state file byte-unchanged after the rejected whole-entry write" "$BEFORE_DOC" \
  "$(cat "$STATE_FILE")"

# The other half of the contract: OMITTING a known field is not corruption.
seed_prs
run --repo test/repo --set '.prs["999"]={"phase":"B","reviewer":"cr"}'
check_eq "gap 1: a whole-entry write that omits known fields is still accepted" "0" "$?"
check_eq "gap 1: the omitting write applied as given" '{"phase":"B","reviewer":"cr"}' \
  "$(jq -c '.repos["test/repo"].prs["999"]' "$STATE_FILE")"

# Clearing a whole entry to null is not corruption either — there is no entry
# left to scan. Pinned so the has() change cannot quietly outlaw it.
seed_prs
run --repo test/repo --set '.prs["1"]=null'
check_eq "gap 1: clearing a whole entry to null is still accepted" "0" "$?"

# A non-object entry cannot hold known fields at all, so it is reported as the
# entry's own type violation rather than as a bare-empty type.
seed_prs
OUT=$(run --repo test/repo --set '.prs["7"]=42' 2>&1); RC=$?
check_eq "gap 1: a non-object whole-entry write rejected (exit 4)" "4" "$RC"
check_eq "gap 1: error names the entry itself and 'object'" "1" \
  "$(grep -c "field '.repos\[\"test/repo\"\].prs\[\"7\"\]' would become type 'number' but must be 'object'" <<<"$OUT")"

# --- Gap 2: --raw-path writes to an explicitly-scoped per-PR field. The old
# helpers matched only a leading `.prs`, so a fully-spelled `.repos[...]` path
# classified as touching top-level `repos` and the nested field went unchecked.
seed_prs
BEFORE_DOC="$(cat "$STATE_FILE")"
OUT=$(run --raw-path --set '.repos["test/repo"].prs["1"].last_cron_action=bad' 2>&1); RC=$?
check_eq "gap 2: --raw-path scoped nested write rejected (exit 4)" "4" "$RC"
check_eq "gap 2: error names the scoped nested field" "1" \
  "$(grep -c "field '.repos\[\"test/repo\"\].prs\[\"1\"\].last_cron_action' would become type 'string' but must be 'object'" <<<"$OUT")"
check_eq "gap 2: state file byte-unchanged after the rejected --raw-path write" "$BEFORE_DOC" \
  "$(cat "$STATE_FILE")"

# The all-bracket spelling session-scheduling-reconcile.sh renders from a jq
# path array (`as_path`, line ~247) is the live shape of this gap.
seed_prs
OUT=$(run --raw-path --set '.["repos"]["test/repo"]["prs"]["1"]["last_cron_action"]=bad' 2>&1); RC=$?
check_eq "gap 2: bracket-spelled scoped nested write rejected (exit 4)" "4" "$RC"
check_eq "gap 2: error names the bracket-spelled path" "1" \
  "$(grep -c "field '.\[\"repos\"\]\[\"test/repo\"\]\[\"prs\"\]\[\"1\"\].last_cron_action' would become type 'string' but must be 'object'" <<<"$OUT")"

# Positive control for the same call site: the two writes it actually makes
# leave `babysit` an object, so the newly-reached guard must accept them.
seed_prs
run --raw-path --set '.["repos"]["test/repo"]["prs"]["1"]["babysit"]["active"]=false' \
    --set '.["repos"]["test/repo"]["prs"]["1"]["babysit"]["cron_job_id"]=null'
check_eq "gap 2: session-scheduling-reconcile's own writes still accepted" "0" "$?"
check_eq "gap 2: babysit stayed an object with both edits applied" '{"active":false,"cron_job_id":null}' \
  "$(jq -c '.repos["test/repo"].prs["1"].babysit' "$STATE_FILE")"

# overrun-check.sh writes a fully-spelled scoped path to a field that is NOT in
# the contract; the newly-reached classifier must leave it unvalidated.
seed_prs
run --raw-path --set '.repos["test/repo"].prs["1"].overrun=anything-at-all'
check_eq "gap 2: an unknown nested field on a scoped path stays unvalidated" "0" "$?"

# jq's optional-index `?` is a legal spelling of the same node, and
# scope_path() has always scoped it — so a `?` anywhere along the path must not
# make the write invisible to the classifier (CodeRabbit, local review).
seed_prs
OUT=$(run --repo test/repo --set '.prs?["1"].last_cron_action=bad' 2>&1); RC=$?
check_eq "gap 2: optional-index on the map segment still classified (exit 4)" "4" "$RC"
check_eq "gap 2: error names the optional-index path verbatim" "1" \
  "$(grep -c "field '.repos\[\"test/repo\"\].prs?\[\"1\"\].last_cron_action' would become type 'string' but must be 'object'" <<<"$OUT")"
seed_prs
RC=0; run --repo test/repo --set '.prs["1"]?.last_cron_action=bad' >/dev/null 2>&1 || RC=$?
check_eq "gap 2: optional-index on the entry segment still classified (exit 4)" "4" "$RC"
seed_prs
RC=0; run --raw-path --set '.repos["test/repo"]?.prs["1"].last_cron_action=bad' >/dev/null 2>&1 || RC=$?
check_eq "gap 2: optional-index on the repo segment still classified (exit 4)" "4" "$RC"
seed_prs
run --repo test/repo --set '.prs?["1"].babysit.active=true'
check_eq "gap 2: a well-typed optional-index write is still accepted" "0" "$?"

# --- Gap 3: replacing the whole `.prs` map. With no PR-number selector nothing
# classified the write, so only the `.repos[*].prs`-is-an-object check ran and
# malformed entries inside the replacement committed.
seed_prs
BEFORE_DOC="$(cat "$STATE_FILE")"
OUT=$(run --repo test/repo --set '.prs={"999":{"last_cron_action":"bad"}}' 2>&1); RC=$?
check_eq "gap 3: whole-map replacement with a malformed entry rejected (exit 4)" "4" "$RC"
check_eq "gap 3: error names the offending entry inside the replacement" "1" \
  "$(grep -c "field '.repos\[\"test/repo\"\].prs\[\"999\"\].last_cron_action' would become type 'string' but must be 'object'" <<<"$OUT")"
check_eq "gap 3: state file byte-unchanged after the rejected whole-map write" "$BEFORE_DOC" \
  "$(cat "$STATE_FILE")"

seed_prs
OUT=$(run --raw-path --set '.repos["test/repo"].prs={"998":{"digest_streak":"nope"}}' 2>&1); RC=$?
check_eq "gap 3: --raw-path whole-map replacement rejected (exit 4)" "4" "$RC"
check_eq "gap 3: error names the offending entry and both types" "1" \
  "$(grep -c "field '.repos\[\"test/repo\"\].prs\[\"998\"\].digest_streak' would become type 'string' but must be 'number'" <<<"$OUT")"

seed_prs
OUT=$(run --repo test/repo --set '.prs={"7":42}' 2>&1); RC=$?
check_eq "gap 3: a non-object entry inside a replacement rejected (exit 4)" "4" "$RC"
check_eq "gap 3: error names that entry and 'object'" "1" \
  "$(grep -c "field '.repos\[\"test/repo\"\].prs\[\"7\"\]' would become type 'number' but must be 'object'" <<<"$OUT")"

# A clean replacement still lands, and still replaces (the prior entry is gone).
seed_prs
run --repo test/repo --set '.prs={"999":{"phase":"C","digest_streak":4,"last_cron_action":{"type":"delete"}}}'
check_eq "gap 3: a well-formed whole-map replacement is accepted" "0" "$?"
check_eq "gap 3: the replacement is applied wholesale" '{"999":{"phase":"C","digest_streak":4,"last_cron_action":{"type":"delete"}}}' \
  "$(jq -c '.repos["test/repo"].prs' "$STATE_FILE")"

# Ordering regression: the per-PR scans now run after issue #638's scope check,
# so a non-object `.prs` must still be reported by #638 and not by the scan.
seed_prs
OUT=$(run --repo test/repo --set '.prs=[1,2,3]' 2>&1); RC=$?
check_eq "gap 3: a non-object .prs is still #638's message, not the entry scan's" "1" \
  "$(grep -c "field '.repos\[\"test/repo\"\].prs' would become type 'array' but must be 'object' (see issue #638)" <<<"$OUT")"
check_eq "gap 3: non-object .prs still exits 4" "4" "$RC"

# --- Controls: rejected on the pre-fix copy too, so a green run of the block
# above cannot be an artifact of a broken harness.
seed_prs
OUT=$(run --repo test/repo --set '.prs["999"]={"last_cron_action":"bad"}' 2>&1); RC=$?
check_eq "control: whole-entry write with a bare-string known field rejected" "4" "$RC"
seed_prs
OUT=$(run --repo test/repo --set '.prs["1"].last_cron_action=null' 2>&1); RC=$?
check_eq "control: single-path write of null to a known field rejected" "4" "$RC"

echo
echo "== Write-time guard: a nested tail this tokenizer cannot decompose (CodeAnt, PR #1573) =="
# FAILS-WITHOUT-FIX: `.prs["1"]."last_cron_action"` is valid jq and really does
# write the field, but `."key"` is a spelling path_take_segment() does not
# model. PR_PATH_KEY came back empty, pr_record_write_target() skipped the write
# outright, and the malformed value committed (exit 0) — the guard bypassed by
# nothing more than an alternate spelling. The classifier now marks that tail
# opaque and falls back to scanning the whole entry, which knows every known
# field regardless of how the write named it.
seed_prs
BEFORE_DOC="$(cat "$STATE_FILE")"
OUT=$(run --repo test/repo --set '.prs["1"]."last_cron_action"="bad"' 2>&1); RC=$?
check_eq "opaque tail: dot-quoted nested write rejected (exit 4)" "4" "$RC"
check_eq "opaque tail: error names the field via the entry scan" "1" \
  "$(grep -c "field '.repos\[\"test/repo\"\].prs\[\"1\"\].last_cron_action' would become type 'string' but must be 'object'" <<<"$OUT")"
check_eq "opaque tail: state file byte-unchanged after the rejected write" "$BEFORE_DOC" \
  "$(cat "$STATE_FILE")"

# The fallback adds coverage; it must not refuse the same spelling when the
# value is well-typed.
seed_prs
run --repo test/repo --set '.prs["1"]."last_cron_action"={"type":"delete"}'
check_eq "opaque tail: a well-typed dot-quoted write is still accepted" "0" "$?"
check_eq "opaque tail: the well-typed write applied as given" '{"type":"delete"}' \
  "$(jq -c '.repos["test/repo"].prs["1"].last_cron_action' "$STATE_FILE")"

# ...and a field outside the contract stays unvalidated, as on every other path.
seed_prs
run --repo test/repo --set '.prs["1"]."reviewer"=cr'
check_eq "opaque tail: an unknown nested field stays unvalidated" "0" "$?"

# The same hole on the --raw-path spelling.
seed_prs
OUT=$(run --raw-path --set '.repos["test/repo"].prs["1"]."digest_streak"=nope' 2>&1); RC=$?
check_eq "opaque tail: --raw-path dot-quoted nested write rejected (exit 4)" "4" "$RC"
check_eq "opaque tail: --raw-path error names the field and both types" "1" \
  "$(grep -c "field '.repos\[\"test/repo\"\].prs\[\"1\"\].digest_streak' would become type 'string' but must be 'number'" <<<"$OUT")"

# A numeric-index tail is the OTHER empty-PR_PATH_KEY case and must stay
# distinct: tokenizing succeeds, there is genuinely no field name, and jq itself
# rejects indexing an object with a number (exit 5, not the guard's 4).
seed_prs
RC=0; run --repo test/repo --set '.prs["1"][0]=x' >/dev/null 2>&1 || RC=$?
check_eq "opaque tail: a numeric-index tail is not treated as opaque (jq's exit 5)" "5" "$RC"

echo
echo "== Field-type contract: a malformed pr_nested degrades, it does not refuse (CodeAnt, PR #1573) =="
# FAILS-WITHOUT-FIX: `_field_types.pr_nested` set to something that PARSES but
# is not an object (a string, an array) was cached verbatim and handed to
# `to_entries` inside the entry scan. That scan fails closed by design, so a
# malformed schema turned every whole-entry / whole-map write into a refusal
# instead of the documented "type guard disabled for this run" degradation
# (issue #640) that a missing or unparseable schema already gets.
#
# Sandboxed because SCHEMA_FILE is resolved relative to the script, so the only
# way to vary the schema is to copy the tree.
SB="$TMP_HOME/malformed-schema"
mkdir -p "$SB/scripts/lib" "$SB/reference" "$SB/home/.claude"
cp "$SCRIPT" "$REPO_ROOT/.claude/scripts/state-lock.sh" "$SB/scripts/"
cp -R "$REPO_ROOT/.claude/scripts/lib/." "$SB/scripts/lib/"
cp "$REPO_ROOT/.claude/reference/session-state-schema.json" "$SB/schema.orig"
SB_SCHEMA="$SB/reference/session-state-schema.json"

# $1 installs the schema: "" pristine, "ABSENT" removed, anything else a jq
# mutation of the pristine copy. Remaining args go to session-state.sh.
sb_run() {
  local mutate="$1"; shift
  case "$mutate" in
    ABSENT) rm -f "$SB_SCHEMA" ;;
    "")     cp "$SB/schema.orig" "$SB_SCHEMA" ;;
    *)      jq "$mutate" "$SB/schema.orig" > "$SB_SCHEMA" ;;
  esac
  printf '%s\n' "$SEEDED_PRS" > "$SB/home/.claude/session-state.json"
  HOME="$SB/home" bash "$SB/scripts/session-state.sh" "$@" >/dev/null 2>&1
}

SB_MALFORMED='.prs["999"]={"phase":"B","last_cron_action":"bad"}'
SB_CLEAN='.prs["999"]={"phase":"B","reviewer":"cr"}'

# Negative control FIRST: with the real schema the sandbox must still enforce.
# Without this every "accepted" assertion below could pass vacuously — a broken
# sandbox accepts everything and looks exactly like a working degradation.
sb_run "" --repo test/repo --set "$SB_MALFORMED"
check_eq "schema tri-state: pristine schema still REJECTS a malformed entry" "4" "$?"
sb_run "" --repo test/repo --set "$SB_CLEAN"
check_eq "schema tri-state: pristine schema accepts a clean entry" "0" "$?"

# A missing schema is the documented degradation, and stays unchanged.
sb_run ABSENT --repo test/repo --set "$SB_CLEAN"
check_eq "schema tri-state: absent schema accepts (guard disabled)" "0" "$?"

# A malformed-but-parseable pr_nested must degrade the same way, not refuse.
sb_run '._field_types.pr_nested = "oops"' --repo test/repo --set "$SB_CLEAN"
check_eq "schema tri-state: string pr_nested accepts a clean entry (was exit 4)" "0" "$?"
sb_run '._field_types.pr_nested = ["a","b"]' --repo test/repo --set "$SB_CLEAN"
check_eq "schema tri-state: array pr_nested accepts a clean entry (was exit 4)" "0" "$?"

# Degraded means disabled, not half-enforcing: with no usable contract the scan
# cannot judge the malformed entry either, and must not pretend otherwise.
sb_run '._field_types.pr_nested = "oops"' --repo test/repo --set "$SB_MALFORMED"
check_eq "schema tri-state: string pr_nested disables the entry scan outright" "0" "$?"

# The whole-map write takes the other scan and must degrade identically.
sb_run '._field_types.pr_nested = "oops"' --repo test/repo \
  --set '.prs={"999":{"last_cron_action":"bad"}}'
check_eq "schema tri-state: string pr_nested degrades the whole-map scan too" "0" "$?"

echo
echo "== --get-json: four stored shapes stay distinct (issue #1629) =="
# Raw --get is lossy by contract: an absent path, a stored JSON null, and a
# stored JSON STRING "null" all print the same four characters, and a stored ""
# prints nothing. Every pause-source reader compares stdout to the literal
# `null` to mean "absent", so a slot corrupted into the string "null" was read
# as "nothing parked" — a damaged board reported as an empty one.
#
# NEGATIVE CONTROL FIRST: assert the conflation --get really does produce, so
# the --get-json assertions below are measured against a demonstrated defect
# rather than an assumed one. These --get rows must keep passing forever: the
# raw mode is the default and every existing caller depends on it.
reset_state
SEED_KEY="test/getjson"
jq -n --arg k "$SEED_KEY" '{repos: {($k): {
  jnull: null, snull: "null", empty: "", rec: {"s1":{"active":true}}, num: 7 }}}' \
  > "$STATE_FILE"
gj() { run --raw-path --get-json ".repos[\"$SEED_KEY\"].$1"; }
gr() { run --raw-path --get      ".repos[\"$SEED_KEY\"].$1"; }

check_eq "--get conflates a stored JSON null with absent"       "null" "$(gr jnull)"
check_eq "--get conflates the STRING \"null\" with absent"      "null" "$(gr snull)"
check_eq "--get prints nothing for a slot holding \"\""         ""     "$(gr empty)"
check_eq "--get on a genuinely absent path also prints null"    "null" "$(gr nope)"
# The defect stated as one assertion: three genuinely different stored values,
# one indistinguishable output.
check_eq "--get: absent, JSON null and the string \"null\" are one output" "1" \
  "$([[ "$(gr nope)" == "$(gr jnull)" && "$(gr jnull)" == "$(gr snull)" ]] && echo 1 || echo 0)"

# --get-json separates them. Fails against the pre-change tree, where the flag
# is an unknown-flag usage error (exit 2) and every row below reads empty.
check_eq "--get-json prints bare null for a stored JSON null"   "null"   "$(gj jnull)"
check_eq "--get-json prints a QUOTED \"null\" for the string"   '"null"' "$(gj snull)"
check_eq "--get-json prints \"\" for a slot holding the empty string" '""' "$(gj empty)"
check_eq "--get-json prints bare null for an absent path"       "null"   "$(gj nope)"
check_eq "--get-json: the string \"null\" is distinct from absent" "1" \
  "$([[ "$(gj snull)" != "$(gj nope)" ]] && echo 1 || echo 0)"
check_eq "--get-json: the empty string is distinct from absent"  "1" \
  "$([[ "$(gj empty)" != "$(gj nope)" ]] && echo 1 || echo 0)"
# An absent path and a stored JSON null still coincide — as they do in jq
# itself. The distinction this mode owes its callers is absent-vs-CORRUPT.
check_eq "--get-json still reads an absent path as the stored JSON null" "1" \
  "$([[ "$(gj nope)" == "$(gj jnull)" ]] && echo 1 || echo 0)"

# Structured and scalar values keep their JSON form (compact, one line).
check_eq "--get-json emits compact JSON for an object" '{"s1":{"active":true}}' "$(gj rec)"
check_eq "--get-json emits a number unquoted"          "7"                      "$(gj num)"
check_eq "--get still pretty-prints an object (unchanged)" "1" \
  "$(gr rec | grep -c '"s1": {')"

echo
echo "== --get-json: exit codes match --get exactly =="
reset_state
run --get-json '.anything' >/dev/null 2>&1
check_eq "missing state file exits 3 (same as --get)" "3" "$?"
run --get '.anything' >/dev/null 2>&1
check_eq "…and --get still exits 3 there too" "3" "$?"

printf '%s' '{' > "$STATE_FILE"
run --get-json '.anything' >/dev/null 2>&1
check_eq "unparseable state file exits 4 (same as --get)" "4" "$?"
run --get '.anything' >/dev/null 2>&1
check_eq "…and --get still exits 4 there too" "4" "$?"

printf '%s' '[1,2]' > "$STATE_FILE"
run --get-json '.[0]' >/dev/null 2>&1
check_eq "non-object top-level state file exits 4" "4" "$?"

reset_state
OUT=$(run --get-json 2>&1); RC=$?
check_eq "--get-json with no jq path is a usage error (exit 2)" "2" "$RC"
check_eq "…and the message names --get-json, not --get" "1" \
  "$(grep -c -- '--get-json requires a jq path' <<<"$OUT")"
OUT=$(run --get-json '.a' --get-json '.b' 2>&1); RC=$?
check_eq "--get-json twice is a usage error (exit 2)" "2" "$RC"
check_eq "…and names --get-json" "1" "$(grep -c -- '--get-json may only be given once' <<<"$OUT")"
OUT=$(run --get '.a' --get-json '.b' 2>&1); RC=$?
check_eq "--get + --get-json together is a usage error (exit 2)" "2" "$RC"
check_eq "…and says they are mutually exclusive" "1" \
  "$(grep -c -- '--get and --get-json are mutually exclusive' <<<"$OUT")"
OUT=$(run --get-json '.a' --session-view 2>&1); RC=$?
check_eq "--get-json + --session-view is a usage error (exit 2)" "2" "$RC"
OUT=$(run 2>&1); RC=$?
check_eq "the no-mode usage message advertises --get-json" "1" \
  "$(grep -c -- '--get-json' <<<"$OUT")"

echo
echo "== --get-json: shares every --get guard, not a parallel copy =="
# Repo scoping: an unprefixed .prs path is rewritten into the active repo's
# scope for --get-json exactly as it is for --get.
reset_state
run --repo org/a --set '.prs["84"].phase=B' >/dev/null
check_eq "--get-json is repo-scoped like --get" '"B"' "$(run --repo org/a --get-json '.prs["84"].phase')"
check_eq "…and the raw mode still prints it unquoted" "B" "$(run --repo org/a --get '.prs["84"].phase')"
check_eq "--get-json on another repo's scope reads absent" "null" \
  "$(run --repo org/b --get-json '.prs["84"].phase')"

# Field-type self-heal (issue #625): a corrupt known top-level field returns a
# safe default with exit 0 — and that default must be valid JSON in this mode.
reset_state
jq -n '{active_agents: "corrupt-string"}' > "$STATE_FILE"
OUT=$(run --get-json '.active_agents' 2>/dev/null); RC=$?
check_eq "--get-json inherits the field-type self-heal default" "{}" "$OUT"
check_eq "…still exiting 0" "0" "$RC"
check_eq "…and the default parses as JSON" "0" "$(printf '%s' "$OUT" | jq -e . >/dev/null 2>&1; echo $?)"

# Legacy-layout migration runs in memory for both modes.
reset_state
jq -n '{prs: {"84": {phase: "A", owner_repo: "org/legacy"}}}' > "$STATE_FILE"
check_eq "--get-json sees a legacy entry through the in-memory migration" '"A"' \
  "$(run --repo org/legacy --get-json '.prs["84"].phase')"
check_eq "…and the read did not rewrite the file" "1" \
  "$(jq -e 'has("prs")' "$STATE_FILE" >/dev/null && echo 1 || echo 0)"

echo
echo "== --get-json: the pause-slot shapes the readers must tell apart =="
# The end-to-end reason this mode exists. Seeded exactly as a damaged pause
# board looks, read exactly as the three readers now read it.
reset_state
PK="org/pause"
jq -n --arg k "$PK" '{repos: {($k): {pauses: "null"}}}' > "$STATE_FILE"
SLOT_JSON="$(run --raw-path --get-json ".repos[\"$PK\"].pauses")"
check_eq "a pauses slot corrupted to the string \"null\" reads as a JSON string" \
  "string" "$(printf '%s' "$SLOT_JSON" | jq -r 'type')"
check_eq "…so it is NOT the absent value the readers key on" "1" \
  "$([[ "$SLOT_JSON" != "null" ]] && echo 1 || echo 0)"
jq -n --arg k "$PK" '{repos: {($k): {pauses: null}}}' > "$STATE_FILE"
check_eq "a genuinely absent pauses slot still reads as JSON null" "null" \
  "$(run --raw-path --get-json ".repos[\"$PK\"].pauses" | jq -r 'type')"

echo
echo "== summary: $PASS passed, $FAIL failed =="
if [[ "$FAIL" -eq 0 ]]; then
  echo "OK: session-state.sh field-type contract tests passed"
  exit 0
else
  echo "FAILURE: $FAIL session-state.sh test(s) failed"
  exit 1
fi
