#!/usr/bin/env bash
# Unit tests for session-state-audit.sh (issue #651).
# catalog: tests — Tests for `session-state-audit.sh`
#
# The script both REPORTS and DELETES, so the properties pinned here are mostly
# about restraint:
#   - detection never mutates the file
#   - every repair category is opt-in; --apply alone is a usage error
#   - a backup exists before any mutation and restores to a valid document
#   - the integrity re-check refuses a write that would drop an untargeted entry
#   - entries carrying unactioned wrap_sweep notes are withheld from pruning
#     until the caller explicitly opts in
#   - attribution is by commit SHA and refuses to guess: zero matches or two
#     matches both leave the entry in `_unknown`
#
# Network is stubbed, not mocked at the call site: a fake `gh` earlier on $PATH
# answers the two subcommands the script uses. The stub must never dispatch
# through `command -v gh` — that resolves back to itself and recurses.
#
# Uses a temporary HOME so it never touches the real ~/.claude/. Requires jq.
# Run from repo root:
#   bash .claude/scripts/tests/session-state-audit.test.sh
set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
SCRIPT="$REPO_ROOT/.claude/scripts/session-state-audit.sh"

TMP_HOME="$(mktemp -d)"
STUB_DIR="$(mktemp -d)"
cleanup() { rm -rf "$TMP_HOME" "$STUB_DIR"; }
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

# --- gh stub ---------------------------------------------------------------
# repos/<owner>/<name>/commits/<sha>  -> exit 0 iff the pair is in COMMIT_MAP
# pr list                            -> emits PR_LIST_JSON for the named repo
# COMMIT_MAP entries are "<owner>/<name> <sha>" lines; anything absent 404s.
cat > "$STUB_DIR/gh" <<'STUB'
#!/usr/bin/env bash
# Deliberately no `command -v gh` dispatch: this stub IS gh on $PATH, so
# forwarding that way would re-invoke itself forever.
if [[ "${1:-}" == "api" ]]; then
  target="${2:-}"
  sha="${target##*/}"
  repo="${target#repos/}"; repo="${repo%%/commits/*}"
  grep -qxF "$repo $sha" "$COMMIT_MAP_FILE" 2>/dev/null && exit 0
  echo '{"message":"No commit found for SHA"}' >&2
  exit 1
fi
if [[ "${1:-}" == "pr" && "${2:-}" == "list" ]]; then
  repo=""
  while [[ $# -gt 0 ]]; do
    [[ "$1" == "--repo" ]] && repo="$2"
    shift
  done
  jq -c --arg r "$repo" '.[$r] // []' "$PR_LIST_FILE" 2>/dev/null || echo '[]'
  exit 0
fi
exit 0
STUB
chmod +x "$STUB_DIR/gh"
export PATH="$STUB_DIR:$PATH"
export COMMIT_MAP_FILE="$STUB_DIR/commits.txt"
export PR_LIST_FILE="$STUB_DIR/prlist.json"
: > "$COMMIT_MAP_FILE"
echo '{}' > "$PR_LIST_FILE"

# A state file with: one attributed scope, one `_unknown` scope holding an
# entry that IS attributable by SHA, one that is not, and one carrying
# unactioned sweep notes.
write_state() {
  cat > "$STATE_FILE" <<'JSON'
{
  "schema_version": 2,
  "active_agents": [],
  "repos": {
    "org/alpha": {
      "root_repo": "/tmp/alpha",
      "prs": { "10": { "phase": "B", "head_sha": "aaaaaaaaaaaa" } }
    },
    "org/beta": {
      "prs": { "20": { "phase": "C" } }
    },
    "_unknown": {
      "prs": {
        "30": { "head_sha": "beefbeefbeef" },
        "31": { "preflight_trigger_head_sha": "cafecafecafe" },
        "32": { "phase": "A" },
        "33": { "head_sha": "d00dd00dd00d" }
      }
    }
  }
}
JSON
}

echo "== Usage: every repair category is opt-in =="
write_state
OUT=$(run --apply 2>&1); RC=$?
check_eq "--apply with no category is a usage error (exit 3)" "3" "$RC"
check_eq "usage error names the required flags" "1" \
  "$(grep -c -- "--apply needs at least one of" <<<"$OUT")"
OUT=$(run --apply --prune-with-notes 2>&1); RC=$?
check_eq "--prune-with-notes without --prune is a usage error" "3" "$RC"
OUT=$(run --retention-days -5 2>&1); RC=$?
check_eq "negative --retention-days rejected" "3" "$RC"

echo
echo "== Environment errors are distinct from findings =="
rm -f "$STATE_FILE"
OUT=$(run --offline 2>&1); RC=$?
check_eq "missing state file exits 4, not 2" "4" "$RC"
printf '{}\n{}\n' > "$STATE_FILE"
OUT=$(run --offline 2>&1); RC=$?
check_eq "multi-document state file exits 4" "4" "$RC"

echo
echo "== Detection never mutates =="
write_state
BEFORE="$(cat "$STATE_FILE")"
run --offline >/dev/null 2>&1
check_eq "--check leaves the file byte-identical" "1" \
  "$([[ "$BEFORE" == "$(cat "$STATE_FILE")" ]] && echo 1 || echo 0)"
check_eq "--check leaves no backup behind" "0" \
  "$(find "$HOME/.claude" -name 'session-state.json.bak.*' | wc -l | tr -d ' ')"

echo
echo "== Detection: census and exit codes =="
write_state
OUT=$(run --offline --json 2>/dev/null); RC=$?
check_eq "findings present exits 2" "2" "$RC"
check_eq "counts every PR entry across scopes" "6" "$(jq -r '.summary.total_prs' <<<"$OUT")"
check_eq "counts the unattributed entries" "4" "$(jq -r '.summary.unattributed_prs' <<<"$OUT")"
check_eq "clean type contract reports zero violations" "0" "$(jq -r '.summary.type_violations' <<<"$OUT")"
check_eq "offline run reports itself as offline" "true" "$(jq -r '.offline' <<<"$OUT")"

cat > "$STATE_FILE" <<'JSON'
{ "schema_version": 2, "repos": { "org/alpha": { "prs": {} } } }
JSON
run --offline >/dev/null 2>&1
check_eq "a file with nothing to report exits 0" "0" "$?"

echo
echo "== Type-contract detection: top level, per-PR nested, and scope shape =="
cat > "$STATE_FILE" <<'JSON'
{
  "schema_version": 2,
  "active_agents": "(.active_agents // [] | map(select(.pr != 71)))",
  "repos": {
    "org/alpha": {
      "prs": { "10": { "last_cron_action": "a bare string", "digest_streak": "3" } }
    }
  }
}
JSON
OUT=$(run --offline --json 2>/dev/null)
check_eq "detects the issue #625 corruption shape" "1" \
  "$(jq -r '[.type_violations[] | select(.path == ".active_agents" and .found == "string")] | length' <<<"$OUT")"
check_eq "detects a malformed per-PR nested object field" "1" \
  "$(jq -r '[.type_violations[] | select(.path | endswith(".last_cron_action"))] | length' <<<"$OUT")"
check_eq "detects a malformed per-PR nested number field" "1" \
  "$(jq -r '[.type_violations[] | select(.path | endswith(".digest_streak"))] | length' <<<"$OUT")"

echo
echo "== --heal-types resets containers and refuses to invent a number =="
OUT=$(run --apply --heal-types --offline 2>&1); RC=$?
check_eq "heal run exits 0" "0" "$RC"
check_eq "object-typed field healed to {}" "{}" "$(jq -c '.active_agents' "$STATE_FILE")"
check_eq "object-typed nested field healed to {}" "{}" \
  "$(jq -c '.repos["org/alpha"].prs["10"].last_cron_action' "$STATE_FILE")"
check_eq "number-typed field left alone (no safe empty value to invent)" '"3"' \
  "$(jq -c '.repos["org/alpha"].prs["10"].digest_streak' "$STATE_FILE")"
check_eq "backup was written before mutating" "1" \
  "$(find "$HOME/.claude" -name 'session-state.json.bak.*' | wc -l | tr -d ' ')"
BACKUP_PATH="$(find "$HOME/.claude" -name 'session-state.json.bak.*' | head -1)"
check_eq "backup is a valid single JSON object" "0" \
  "$(jq -s -e 'length == 1 and (.[0] | type == "object")' "$BACKUP_PATH" >/dev/null 2>&1; echo $?)"
check_eq "backup still holds the PRE-repair (corrupt) value" '"(.active_agents // [] | map(select(.pr != 71)))"' \
  "$(jq -c '.active_agents' "$BACKUP_PATH")"
cp "$BACKUP_PATH" "$STATE_FILE"
check_eq "backup restores by plain copy" '"(.active_agents // [] | map(select(.pr != 71)))"' \
  "$(jq -c '.active_agents' "$STATE_FILE")"
rm -f "$HOME"/.claude/session-state.json.bak.*

echo
echo "== active_agents map: a null entry is a violation, healed key-by-key (issue #1631) =="
# FAILS WITHOUT FIX: without the per-entry pass, a `null` value under an
# active_agents key is invisible — `.active_agents` itself is a valid object,
# so the whole-field check passes and the corruption stays on disk.
cat > "$STATE_FILE" <<'JSON'
{
  "schema_version": 2,
  "active_agents": {
    "live-a": { "id": "live-a", "phase": "B" },
    "clobbered": null,
    "live-b": { "id": "live-b", "phase": "C" },
    "wrong-type": "a bare string"
  },
  "repos": {}
}
JSON
OUT=$(run --offline --json 2>/dev/null)
check_eq "detects a null value under an active_agents key" "1" \
  "$(jq -r '[.type_violations[] | select(.path == ".active_agents[\"clobbered\"]" and .found == "null")] | length' <<<"$OUT")"
check_eq "detects a non-object value under an active_agents key" "1" \
  "$(jq -r '[.type_violations[] | select(.path == ".active_agents[\"wrong-type\"]" and .found == "string")] | length' <<<"$OUT")"
check_eq "the whole field is NOT reported — only the offending keys" "0" \
  "$(jq -r '[.type_violations[] | select(.path == ".active_agents")] | length' <<<"$OUT")"

run --apply --heal-types --offline >/dev/null 2>&1
check_eq "heal drops only the offending keys" '["live-a","live-b"]' \
  "$(jq -c '.active_agents | keys' "$STATE_FILE")"
check_eq "heal preserved a valid sibling verbatim" '{"id":"live-b","phase":"C"}' \
  "$(jq -c '.active_agents["live-b"]' "$STATE_FILE")"
rm -f "$HOME"/.claude/session-state.json.bak.*

echo
echo "== active_agents legacy ARRAY is a migration, never a --heal-types reset (issue #1631) =="
# FAILS WITHOUT FIX (of the carve-out): with the array reported as a plain
# type violation, --heal-types resets the field to {} and every live agent in
# it is gone — the exact loss #1631 exists to stop, arriving through the
# repair tool instead of through a racing writer.
cat > "$STATE_FILE" <<'JSON'
{
  "schema_version": 2,
  "active_agents": [ { "id": "still-running", "phase": "B" } ],
  "repos": {}
}
JSON
OUT=$(run --offline --json 2>/dev/null)
check_eq "a legacy array is not a type violation" "0" \
  "$(jq -r '[.type_violations[] | select(.path | startswith(".active_agents"))] | length' <<<"$OUT")"
check_eq "a legacy array is reported as a legacy key instead" "1" \
  "$(jq -r '[.legacy_keys[] | select(. == "active_agents (array)")] | length' <<<"$OUT")"
run --apply --heal-types --offline >/dev/null 2>&1
check_eq "--heal-types did not reset the legacy array to {}" '[{"id":"still-running","phase":"B"}]' \
  "$(jq -c '.active_agents' "$STATE_FILE")"
rm -f "$HOME"/.claude/session-state.json.bak.*

echo
echo "== a FALSE container value is healed, not silently declined (issue #1631) =="
# FAILS WITHOUT FIX: the heal re-validation read the target as `$d[$f] // null`,
# and jq's `//` treats `false` as EMPTY — so a literal `false` looked like
# "another writer already repaired it", the heal was dropped from the plan, and
# --heal-types exited reporting success with the invalid value still on disk.
# `false` trips no other guard: `false != null` is true, so detection reports
# the violation correctly and only the repair declines it (CodeAnt, PR #1637).
write_state
jq '.active_agents = false' "$STATE_FILE" > "$STATE_FILE.tmp" && mv "$STATE_FILE.tmp" "$STATE_FILE"
OUT=$(run --offline --json 2>/dev/null)
check_eq "a false active_agents IS reported as a type violation" "boolean" \
  "$(jq -r '[.type_violations[] | select(.path == ".active_agents")][0].found' <<<"$OUT")"
run --apply --heal-types --offline >/dev/null 2>&1
check_eq "--heal-types actually resets a false active_agents to {}" '{}' \
  "$(jq -c '.active_agents' "$STATE_FILE")"

# The `.pr == null` and per-PR branches carry the same `has`-based fix, but a
# false-valued REPO scope cannot be pinned end-to-end here: the LOST integrity
# check that runs before the write does `.repos[$r].prs` unguarded and dies with
# "Cannot index boolean with string" first, so the repair aborts (file left
# untouched, backup kept) for a reason unrelated to the heal plan. That crash is
# a separate pre-existing defect in a different code path; tracked separately
# rather than widened into this issue. What IS pinned is that the abort is loud
# and non-destructive, which is the property that matters for a repair tool.
write_state
jq '.repos["auerbachb/claude-code-config"] = false' "$STATE_FILE" > "$STATE_FILE.tmp" && mv "$STATE_FILE.tmp" "$STATE_FILE"
BEFORE_FALSE_SCOPE="$(cat "$STATE_FILE")"
OUT=$(run --apply --heal-types --offline 2>&1); RC=$?
check_eq "a false repo scope aborts the repair rather than half-writing" \
  "nonzero" "$([[ "$RC" -ne 0 ]] && echo nonzero || echo "zero($RC)")"
check_eq "the aborted repair left the file byte-identical" \
  "$BEFORE_FALSE_SCOPE" "$(cat "$STATE_FILE")"
rm -f "$HOME"/.claude/session-state.json.bak.*

echo
echo "== Backups never overwrite an earlier snapshot =="
write_state
run --apply --heal-types --offline >/dev/null 2>&1
run --apply --heal-types --offline >/dev/null 2>&1
check_eq "a second repair in the same second adds a suffix, not a clobber" "2" \
  "$(find "$HOME/.claude" -name 'session-state.json.bak.*' | wc -l | tr -d ' ')"
rm -f "$HOME"/.claude/session-state.json.bak.*

echo
echo "== Attribution: by commit SHA, and only when unambiguous =="
write_state
# PR 30's SHA lives in org/alpha only; PR 31's in org/beta only; PR 33's SHA is
# in BOTH (ambiguous); PR 32 records no SHA at all.
cat > "$COMMIT_MAP_FILE" <<'MAP'
org/alpha beefbeefbeef
org/beta cafecafecafe
org/alpha d00dd00dd00d
org/beta d00dd00dd00d
MAP
OUT=$(run --json 2>/dev/null)
# Assert the attribution block actually RAN before asserting what it found. If
# it is skipped (no gh, or a guard that misfires on another bash version) every
# check below fails with an empty result and the cause is invisible — which is
# exactly how a bash-3.2-only array guard passed locally and failed on CI.
check_eq "attribution ran (not silently skipped as offline)" "false" \
  "$(jq -r '.offline' <<<"$OUT")"
check_eq "candidate repos were discovered" "2" \
  "$(jq -r '.scopes | map(select(.attributed)) | length' <<<"$OUT")"
check_eq "single-repo SHA match is attributable" "org/alpha" \
  "$(jq -r '.reattributable[] | select(.pr == "30") | .repo' <<<"$OUT")"
check_eq "attribution follows preflight_trigger_head_sha too" "org/beta" \
  "$(jq -r '.reattributable[] | select(.pr == "31") | .repo' <<<"$OUT")"
check_eq "an entry with no recorded SHA is not attributed" "no recorded commit SHA" \
  "$(jq -r '.unattributable[] | select(.pr == "32") | .reason' <<<"$OUT")"
check_eq "a SHA found in two repos is refused, not guessed" "1" \
  "$(jq -r '[.unattributable[] | select(.pr == "33" and (.reason | startswith("ambiguous")))] | length' <<<"$OUT")"
check_eq "exactly two entries are confidently attributable" "2" "$(jq -r '.summary.reattributable' <<<"$OUT")"

echo
echo "== --reattribute moves entries and leaves the rest alone =="
OUT=$(run --apply --reattribute 2>&1); RC=$?
check_eq "reattribute run exits 0" "0" "$RC"
check_eq "attributed entry now lives in its real scope" "beefbeefbeef" \
  "$(jq -r '.repos["org/alpha"].prs["30"].head_sha' "$STATE_FILE")"
check_eq "attributed entry is gone from _unknown" "null" \
  "$(jq -r '.repos["_unknown"].prs["30"] // "null"' "$STATE_FILE")"
check_eq "the second attributed entry moved to its own scope" "cafecafecafe" \
  "$(jq -r '.repos["org/beta"].prs["31"].preflight_trigger_head_sha' "$STATE_FILE")"
check_eq "unattributable entries stay in _unknown" "2" \
  "$(jq -r '.repos["_unknown"].prs | length' "$STATE_FILE")"
check_eq "a pre-existing entry in the destination scope is untouched" "B" \
  "$(jq -r '.repos["org/alpha"].prs["10"].phase' "$STATE_FILE")"
check_eq "total PR entries are conserved by a move" "6" \
  "$(jq -r '[.repos[] | (.prs // {}) | length] | add' "$STATE_FILE")"

echo "== An uppercase SHA is still a valid SHA (CodeAnt, #651) =="
cat > "$STATE_FILE" <<'JSON'
{
  "schema_version": 2,
  "repos": {
    "org/alpha": { "prs": { "34": { "phase": "B" } } },
    "_unknown":  { "prs": { "35": { "head_sha": "ABCDEF1234AB" } } }
  }
}
JSON
# The stub matches the lowercase form, so this only passes if the audit
# normalizes before asking — a case-sensitive filter would drop the entry
# entirely and report it as having no usable SHA.
echo "org/alpha abcdef1234ab" > "$COMMIT_MAP_FILE"
echo '{}' > "$PR_LIST_FILE"
OUT=$(run --json 2>/dev/null)
check_eq "uppercase SHA is attributed, not discarded" "org/alpha" \
  "$(jq -r '.reattributable[] | select(.pr == "35") | .repo' <<<"$OUT")"
check_eq "uppercase SHA is not reported as missing" "0" \
  "$(jq -r '[.unattributable[] | select(.pr == "35")] | length' <<<"$OUT")"

echo
echo "== An emptied _unknown scope is dropped entirely =="
write_state
cat > "$COMMIT_MAP_FILE" <<'MAP'
org/alpha beefbeefbeef
org/alpha cafecafecafe
org/alpha d00dd00dd00d
MAP
# PR 32 has no SHA, so remove it first — then every remaining _unknown entry is
# attributable and the bucket should disappear rather than linger empty.
jq 'del(.repos["_unknown"].prs["32"])' "$STATE_FILE" > "$STATE_FILE.t" && mv "$STATE_FILE.t" "$STATE_FILE"
run --apply --reattribute >/dev/null 2>&1
check_eq "fully drained _unknown scope is removed" "null" \
  "$(jq -r '.repos["_unknown"] // "null"' "$STATE_FILE")"
check_eq "the drained entries all landed in the real scope" "4" \
  "$(jq -r '.repos["org/alpha"].prs | length' "$STATE_FILE")"

echo
echo "== Merge conflict rule: the destination entry wins =="
cat > "$STATE_FILE" <<'JSON'
{
  "schema_version": 2,
  "repos": {
    "org/alpha": { "prs": { "40": { "phase": "C", "head_sha": "aaaaaaaaaaaa" } } },
    "_unknown":  { "prs": { "40": { "phase": "A", "reviewer": "cr", "head_sha": "aaaaaaaaaaaa" } } }
  }
}
JSON
echo "org/alpha aaaaaaaaaaaa" > "$COMMIT_MAP_FILE"
run --apply --reattribute >/dev/null 2>&1
check_eq "destination field wins on conflict" "C" "$(jq -r '.repos["org/alpha"].prs["40"].phase' "$STATE_FILE")"
check_eq "fields only the moved entry had are preserved" "cr" \
  "$(jq -r '.repos["org/alpha"].prs["40"].reviewer' "$STATE_FILE")"

echo
echo "== Staleness: retention window and the sweep-note guard =="
OLD="$(date -u -v-90d +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d '90 days ago' +%Y-%m-%dT%H:%M:%SZ)"
RECENT="$(date -u -v-2d +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d '2 days ago' +%Y-%m-%dT%H:%M:%SZ)"
cat > "$STATE_FILE" <<'JSON'
{
  "schema_version": 2,
  "repos": {
    "org/alpha": {
      "prs": {
        "50": { "phase": "C" },
        "51": { "phase": "C" },
        "52": { "phase": "C",
                "wrap_sweep": { "needs_decision": ["an unanswered follow-up question"] } },
        "53": { "phase": "B" }
      }
    }
  }
}
JSON
jq -n --arg old "$OLD" --arg recent "$RECENT" '{
  "org/alpha": [
    {number: 50, state: "MERGED", closedAt: $old},
    {number: 51, state: "MERGED", closedAt: $recent},
    {number: 52, state: "MERGED", closedAt: $old},
    {number: 53, state: "OPEN",   closedAt: null}
  ]}' > "$PR_LIST_FILE"
: > "$COMMIT_MAP_FILE"
OUT=$(run --json 2>/dev/null)
check_eq "a long-merged entry with no notes is prunable" "1" \
  "$(jq -r '[.stale_prunable[] | select(.pr == "50")] | length' <<<"$OUT")"
check_eq "an entry merged inside the retention window is not stale" "0" \
  "$(jq -r '[(.stale_prunable + .stale_withheld)[] | select(.pr == "51")] | length' <<<"$OUT")"
check_eq "a long-merged entry WITH unactioned notes is withheld" "1" \
  "$(jq -r '[.stale_withheld[] | select(.pr == "52")] | length' <<<"$OUT")"
check_eq "the withheld entry's notes are surfaced for reading" "an unanswered follow-up question" \
  "$(jq -r '.stale_withheld[] | select(.pr == "52") | .notes[0]' <<<"$OUT")"
check_eq "an open PR is never stale" "0" \
  "$(jq -r '[(.stale_prunable + .stale_withheld)[] | select(.pr == "53")] | length' <<<"$OUT")"

echo
echo "== --prune honors the withhold; --prune-with-notes overrides it =="
run --apply --prune >/dev/null 2>&1
check_eq "prunable entry deleted" "null" "$(jq -r '.repos["org/alpha"].prs["50"] // "null"' "$STATE_FILE")"
check_eq "withheld entry survives a plain --prune" "C" \
  "$(jq -r '.repos["org/alpha"].prs["52"].phase' "$STATE_FILE")"
check_eq "in-window entry survives" "C" "$(jq -r '.repos["org/alpha"].prs["51"].phase' "$STATE_FILE")"
check_eq "open-PR entry survives" "B" "$(jq -r '.repos["org/alpha"].prs["53"].phase' "$STATE_FILE")"
run --apply --prune --prune-with-notes >/dev/null 2>&1
check_eq "withheld entry deleted only after explicit opt-in" "null" \
  "$(jq -r '.repos["org/alpha"].prs["52"] // "null"' "$STATE_FILE")"

echo
echo "== Retention window is configurable =="
cat > "$STATE_FILE" <<'JSON'
{ "schema_version": 2, "repos": { "org/alpha": { "prs": { "51": { "phase": "C" } } } } }
JSON
OUT=$(run --json --retention-days 1 2>/dev/null)
check_eq "a shorter window makes a recent merge stale" "1" \
  "$(jq -r '[.stale_prunable[] | select(.pr == "51")] | length' <<<"$OUT")"
OUT=$(run --json --retention-days 365 2>/dev/null)
check_eq "a longer window spares it" "0" "$(jq -r '.summary.stale_prunable' <<<"$OUT")"

echo
echo "== Repairs are additive: an unrelated field is never disturbed =="
cat > "$STATE_FILE" <<'JSON'
{
  "schema_version": 2,
  "monitoring_active": true,
  "greptile_daily": { "reviews_used": 12, "date": "2026-03-16", "budget": 40 },
  "some_future_field": { "written": "by a newer version" },
  "repos": {
    "org/alpha": { "prs": { "60": { "phase": "B" } } },
    "_unknown":  { "prs": { "61": { "head_sha": "abcabcabcabc" } } }
  }
}
JSON
echo "org/alpha abcabcabcabc" > "$COMMIT_MAP_FILE"
echo '{}' > "$PR_LIST_FILE"
run --apply --reattribute >/dev/null 2>&1
check_eq "unknown forward-compat field preserved verbatim" '{"written":"by a newer version"}' \
  "$(jq -c '.some_future_field' "$STATE_FILE")"
check_eq "account-level field preserved" "12" "$(jq -r '.greptile_daily.reviews_used' "$STATE_FILE")"
check_eq "unrelated scalar preserved" "true" "$(jq -r '.monitoring_active' "$STATE_FILE")"
check_eq "last_updated refreshed by the repair" "1" \
  "$(jq -r 'if (.last_updated // "") | test("^[0-9]{4}-") then 1 else 0 end' "$STATE_FILE")"

echo "== Integrity check actually runs (it must never pass by erroring) =="
# A repair whose integrity check dies would leave its output empty, which reads
# exactly like "nothing was lost" — the guard would pass BY failing. This ran
# live during issue #651: `index(.pr)` resolved `.pr` against the array being
# searched rather than the element, printing a jq error while the write went
# through unchecked. The negative control is a state file with a repo scope
# whose value is an array, which the pairs() walk cannot index.
cat > "$STATE_FILE" <<'JSON'
{
  "schema_version": 2,
  "repos": {
    "org/alpha": { "prs": { "70": { "phase": "B" } } },
    "_unknown":  { "prs": { "71": { "head_sha": "feedfeedfeed" } } }
  }
}
JSON
echo "org/alpha feedfeedfeed" > "$COMMIT_MAP_FILE"
echo '{}' > "$PR_LIST_FILE"
OUT=$(run --apply --reattribute 2>&1); RC=$?
check_eq "a healthy repair reports no integrity error" "0" "$RC"
check_eq "no raw jq error leaks to the caller" "0" "$(grep -c 'Cannot index' <<<"$OUT")"
check_eq "the entry really moved" "feedfeedfeed" \
  "$(jq -r '.repos["org/alpha"].prs["71"].head_sha' "$STATE_FILE")"

# Positive control. The check above only proves the guard is quiet on a healthy
# repair — which a guard that silently errors also is. This drives the failure
# path for real: a PR entry that is an ARRAY rather than an object is something
# the pairs() walk cannot index, so the integrity jq dies. The run must abort
# with the environment-error code and leave the file untouched, NOT sail past a
# check that produced no output because it crashed.
cat > "$STATE_FILE" <<'JSON'
{
  "schema_version": 2,
  "repos": {
    "org/alpha": { "prs": { "80": ["not", "an", "object"] } },
    "_unknown":  { "prs": { "81": { "head_sha": "b0b0b0b0b0b0" } } }
  }
}
JSON
echo "org/alpha b0b0b0b0b0b0" > "$COMMIT_MAP_FILE"
BEFORE="$(cat "$STATE_FILE")"
OUT=$(run --apply --reattribute 2>&1); RC=$?
# Assert ONE outcome, not "0 or 4". Accepting either lets a regression in
# whichever branch is not taken pass unnoticed — the same can't-fail assertion
# shape this whole section exists to catch (CodeAnt, #651). The contract is
# specific: a malformed entry is data to be reported, so the run COMPLETES.
check_eq "a malformed entry does not abort the repair" "0" "$RC"
check_eq "detection survives a non-object PR entry without aborting" "0" \
  "$(grep -c 'Cannot index' <<<"$OUT")"
check_eq "the untargeted malformed entry is conserved, not dropped" "array" \
  "$(jq -r '.repos["org/alpha"].prs["80"] | type' "$STATE_FILE")"
check_eq "the attributable entry still moved despite the malformed sibling" "b0b0b0b0b0b0" \
  "$(jq -r '.repos["org/alpha"].prs["81"].head_sha' "$STATE_FILE")"
check_eq "the malformed entry is surfaced as a type violation" "1" \
  "$(run --offline --json 2>/dev/null | jq -r '[.type_violations[] | select(.pr == "80" and .want == "object" and .found == "array")] | length')"

echo "== Malformed repo SCOPE never aborts the audit (CodeAnt, #651) =="
# One level up from the PR-entry guard: a scope whose value is an array or a
# string would make every `.value.prs` dereference abort the whole jq program,
# taking down the audit that exists to report exactly this corruption.
cat > "$STATE_FILE" <<'JSON'
{
  "schema_version": 2,
  "repos": {
    "org/alpha": { "prs": { "90": { "phase": "B" } } },
    "org/broken": ["not", "an", "object"],
    "org/alsobroken": "a bare string",
    "_unknown": { "prs": { "91": { "head_sha": "cabcabcabcab" } } }
  }
}
JSON
OUT=$(run --offline --json 2>/dev/null); RC=$?
check_eq "audit still produces findings despite malformed scopes" "2" "$RC"
check_eq "malformed scopes are REPORTED, not fatal" "2" \
  "$(jq -r '[.type_violations[] | select(.path | startswith(".repos[")) | select(.pr == null)] | length' <<<"$OUT")"
check_eq "a malformed scope counts as zero PRs rather than crashing" "0" \
  "$(jq -r '.scopes[] | select(.repo == "org/broken") | .pr_count' <<<"$OUT")"
check_eq "healthy scopes are still counted correctly" "2" \
  "$(jq -r '.summary.total_prs' <<<"$OUT")"
check_eq "no jq index error reaches the caller" "0" \
  "$(run --offline 2>&1 >/dev/null | grep -c 'Cannot index')"

echo
echo "== Repair plan is re-validated under the lock (CodeAnt, #651) =="
# Detection runs before the lock (its network calls would otherwise stall every
# other writer). A target that changed in that window must be DROPPED, not
# applied to state it was never computed from.
cat > "$STATE_FILE" <<'JSON'
{
  "schema_version": 2,
  "repos": {
    "org/alpha": { "prs": { "95": { "phase": "B" } } },
    "_unknown":  { "prs": { "96": { "head_sha": "d1d1d1d1d1d1" } } }
  }
}
JSON
echo "org/alpha d1d1d1d1d1d1" > "$COMMIT_MAP_FILE"
echo '{}' > "$PR_LIST_FILE"
# Simulate the concurrent writer: a gh stub that removes the move target the
# moment attribution reads it, i.e. between detection and the lock.
cat > "$STUB_DIR/gh" <<'STUB'
#!/usr/bin/env bash
if [[ "${1:-}" == "api" ]]; then
  target="${2:-}"; sha="${target##*/}"
  repo="${target#repos/}"; repo="${repo%%/commits/*}"
  if grep -qxF "$repo $sha" "$COMMIT_MAP_FILE" 2>/dev/null; then
    if [[ -n "${RACE_STATE_FILE:-}" && -f "$RACE_STATE_FILE" ]]; then
      jq 'del(.repos["_unknown"].prs["96"])' "$RACE_STATE_FILE" > "$RACE_STATE_FILE.race" \
        && mv "$RACE_STATE_FILE.race" "$RACE_STATE_FILE"
    fi
    exit 0
  fi
  exit 1
fi
if [[ "${1:-}" == "pr" && "${2:-}" == "list" ]]; then echo '[]'; exit 0; fi
exit 0
STUB
chmod +x "$STUB_DIR/gh"
export RACE_STATE_FILE="$STATE_FILE"
OUT=$(run --apply --reattribute 2>&1); RC=$?
check_eq "a target that vanished mid-flight does not fail the run" "0" "$RC"
check_eq "the stale move is dropped, not applied" "null" \
  "$(jq -r '.repos["org/alpha"].prs["96"] // "null"' "$STATE_FILE")"
check_eq "the drop is reported, never silent" "1" \
  "$([[ "$OUT" == *"changed between detection and the lock"* ]] && echo 1 || echo 0)"
check_eq "untargeted state is untouched by the aborted move" "B" \
  "$(jq -r '.repos["org/alpha"].prs["95"].phase' "$STATE_FILE")"
unset RACE_STATE_FILE

# Restore the standard stub for any later section.
cat > "$STUB_DIR/gh" <<'STUB'
#!/usr/bin/env bash
if [[ "${1:-}" == "api" ]]; then
  target="${2:-}"; sha="${target##*/}"
  repo="${target#repos/}"; repo="${repo%%/commits/*}"
  grep -qxF "$repo $sha" "$COMMIT_MAP_FILE" 2>/dev/null && exit 0
  exit 1
fi
if [[ "${1:-}" == "pr" && "${2:-}" == "list" ]]; then
  repo=""
  while [[ $# -gt 0 ]]; do [[ "$1" == "--repo" ]] && repo="$2"; shift; done
  jq -c --arg r "$repo" '.[$r] // []' "$PR_LIST_FILE" 2>/dev/null || echo '[]'
  exit 0
fi
if [[ "${1:-}" == "pr" && "${2:-}" == "view" ]]; then
  num="${3:-}"
  jq -c --arg n "$num" '[.[][]] | map(select((.number|tostring) == $n)) | .[0] // empty' "$PR_LIST_FILE" 2>/dev/null
  exit 0
fi
exit 0
STUB
chmod +x "$STUB_DIR/gh"

echo
echo "== A prune target that gained sweep notes mid-flight is withheld =="
OLD2="$(date -u -v-90d +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d '90 days ago' +%Y-%m-%dT%H:%M:%SZ)"
cat > "$STATE_FILE" <<'JSON'
{ "schema_version": 2, "repos": { "org/alpha": { "prs": { "97": { "phase": "C" } } } } }
JSON
jq -n --arg old "$OLD2" '{"org/alpha":[{number:97,state:"MERGED",closedAt:$old}]}' > "$PR_LIST_FILE"
: > "$COMMIT_MAP_FILE"
OUT=$(run --json 2>/dev/null)
check_eq "entry is prunable before the race" "1" \
  "$(jq -r '[.stale_prunable[] | select(.pr == "97")] | length' <<<"$OUT")"
# A writer adds an unactioned follow-up after detection but before the lock.
jq '.repos["org/alpha"].prs["97"].wrap_sweep = {"needs_decision":["added after detection"]}' \
  "$STATE_FILE" > "$STATE_FILE.t" && mv "$STATE_FILE.t" "$STATE_FILE"
run --apply --prune >/dev/null 2>&1
check_eq "re-validation re-withholds it instead of deleting the note" "C" \
  "$(jq -r '.repos["org/alpha"].prs["97"].phase // "GONE"' "$STATE_FILE")"

echo
echo "== Concurrent-writer safety: the repair takes the shared state lock =="
write_state
: > "$COMMIT_MAP_FILE"
echo '{}' > "$PR_LIST_FILE"
mkdir -p "$STATE_FILE.lock"
# A live holder whose lock is too young to be stale: the repair must give up
# (exit 6) rather than write unserialized.
{
  printf 'pid=%s\n' "$$"
  printf 'host=%s\n' "$(hostname)"
  printf 'epoch=%s\n' "$(date +%s)"
  printf 'cmd=%s\n' "fake-holder"
} > "$STATE_FILE.lock/owner"
BEFORE="$(cat "$STATE_FILE")"
OUT=$(CLAUDE_STATE_LOCK_TIMEOUT=1 run --apply --heal-types --offline 2>&1); RC=$?
check_eq "a held lock makes the repair exit 6, not write" "6" "$RC"
check_eq "state file untouched when the lock could not be taken" "1" \
  "$([[ "$BEFORE" == "$(cat "$STATE_FILE")" ]] && echo 1 || echo 0)"
rm -rf "$STATE_FILE.lock"

echo
echo "== summary: $PASS passed, $FAIL failed =="
if [[ "$FAIL" -gt 0 ]]; then
  echo "FAILED: session-state-audit.sh tests" >&2
  exit 1
fi
echo "OK: session-state-audit.sh tests passed"
