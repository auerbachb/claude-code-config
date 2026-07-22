#!/usr/bin/env bash
# Unit tests for session-state-audit.sh (issue #651).
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
check_eq "array-typed field healed to []" "[]" "$(jq -c '.active_agents' "$STATE_FILE")"
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
check_eq "a malformed entry is reported, never silently indexed" "1" \
  "$([[ "$RC" == "0" || "$RC" == "4" ]] && echo 1 || echo 0)"
check_eq "detection survives a non-object PR entry without aborting" "0" \
  "$(grep -c 'Cannot index' <<<"$OUT")"
if [[ "$RC" == "4" ]]; then
  check_eq "an aborted repair leaves the state file byte-identical" "1" \
    "$([[ "$BEFORE" == "$(cat "$STATE_FILE")" ]] && echo 1 || echo 0)"
  check_eq "an aborted repair still says where the backup is" "1" \
    "$(grep -c 'backup:' <<<"$OUT")"
else
  check_eq "a completed repair conserves the untargeted malformed entry" "1" \
    "$(jq -r 'if (.repos["org/alpha"].prs["80"] // null) != null then 1 else 0 end' "$STATE_FILE")"
fi

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
