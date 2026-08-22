#!/usr/bin/env bash
# Tests for active-work-cap.sh — the repo-wide budget for simultaneously
# active coding work (issue #1191).
#
# Every source the script reads is redirected into a temp dir: the chip logs
# via CLAUDE_ACTIVE_WORK_HANDOFF_DIR, session-state via HOME, the cap via a
# throwaway git repo carrying its own .claude/pm-config.md, and GitHub via a
# fake `gh` placed first on PATH. The suite never reads live state and never
# makes a network call.
set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
SCRIPT="$REPO_ROOT/.claude/scripts/active-work-cap.sh"

TMP_DIR="$(mktemp -d)"
cleanup() { chmod -R u+w "$TMP_DIR" 2>/dev/null || true; rm -rf "$TMP_DIR"; }
trap cleanup EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }
ok() { echo "ok   — $*"; }

# Isolate from a caller-set override — the default-cap assertions below must
# not silently inherit a different number from the environment.
unset CLAUDE_ACTIVE_WORK_CAP

export CLAUDE_ACTIVE_WORK_HANDOFF_DIR="$TMP_DIR/handoffs"
export HOME="$TMP_DIR/home"
mkdir -p "$CLAUDE_ACTIVE_WORK_HANDOFF_DIR" "$HOME/.claude"

SLUG="testowner/testrepo"

# --- fake gh -----------------------------------------------------------------
# Dispatches on the subcommand pair only, never on the full argument string:
# a fake that matches exact arg order breaks silently the next time a flag is
# added (feedback_test_fake_pitfalls.md). Anything it does not recognise is a
# HARD ERROR, never an empty success — a default branch that absorbs an
# unmatched call lets the code under test fall back and ship green having
# never run the path (feedback_test_stub_absorbs_unmatched_call.md).
BIN="$TMP_DIR/bin"
mkdir -p "$BIN"
cat > "$BIN/gh" <<'GHEOF'
#!/usr/bin/env bash
# Dispatch on the subcommand, then ASSERT the flags the correctness of the cap
# depends on. A fake that ignores everything past $1 $2 keeps passing after the
# implementation drops `--author @me` or the repo scoping, so the suite would
# certify author- and repo-scoped counting it never actually checked.
ARGS=" $* "
need() {
  case "$ARGS" in
    *" $1 "*) ;;
    *) echo "fake gh: expected '$1' in: $*" >&2; exit 96 ;;
  esac
}
case "$1 $2" in
  "repo view")
    [[ -n "${GH_FAKE_SLUG:-}" ]] || { echo "fake gh: GH_FAKE_SLUG unset" >&2; exit 1; }
    need "--json"
    printf '%s\n' "$GH_FAKE_SLUG" ;;
  "pr list")
    if [[ "${GH_FAKE_PR_FAIL:-0}" == "1" ]]; then
      echo "fake gh: simulated API failure" >&2; exit 1
    fi
    # Author scoping (#732/#733) and the closing-issue field (double-count fix)
    # are both load-bearing; losing either silently corrupts the count.
    need "--state"; need "open"; need "--author"; need "@me"
    case "$ARGS" in
      *"closingIssuesReferences"*) ;;
      *) echo "fake gh: pr list must request closingIssuesReferences: $*" >&2; exit 96 ;;
    esac
    # When set, the PR listing MUST be scoped to this repo. Without this the
    # suite cannot tell a correctly-scoped fetch from one that silently ran
    # against the caller's checkout.
    if [[ -n "${GH_FAKE_REQUIRE_REPO:-}" ]]; then
      need "--repo"; need "$GH_FAKE_REQUIRE_REPO"
    fi
    printf '%s\n' "${GH_FAKE_PRS:-[]}" ;;
  "api graphql")
    if [[ "${GH_FAKE_ISSUE_FAIL:-0}" == "1" ]]; then
      echo "fake gh: simulated API failure" >&2; exit 1
    fi
    # GitHub can answer 200 with PARTIAL data plus an `errors` array, and gh
    # does not always exit non-zero for it. Reading the resolved half as the
    # whole answer would silently drop chips and free capacity.
    if [[ "${GH_FAKE_GQL_PARTIAL:-0}" == "1" ]]; then
      printf '{"data":{"repository":null},"errors":[{"message":"Something went wrong"}]}\n'
      exit 0
    fi
    # Answer only for the issue numbers actually asked about — a fake that
    # returned every open issue regardless would hide a caller that queried the
    # wrong set.
    Q=""
    while [[ $# -gt 0 ]]; do
      case "$1" in query=*) Q="${1#query=}" ;; esac
      shift
    done
    [[ -n "$Q" ]] || { echo "fake gh: graphql call carried no query" >&2; exit 96; }
    OPEN_SET=" $(printf '%s' "${GH_FAKE_OPEN_ISSUES:-}" | tr '\n' ' ') "
    printf '{"data":{"repository":{'
    FIRST=1
    for N in $(printf '%s' "$Q" | grep -oE 'issue\(number: [0-9]+\)' | grep -oE '[0-9]+'); do
      case "$OPEN_SET" in
        *" $N "*) STATE="OPEN" ;;
        *)        STATE="CLOSED" ;;
      esac
      [[ $FIRST -eq 1 ]] || printf ','
      FIRST=0
      printf '"n%s":{"number":%s,"state":"%s"}' "$N" "$N" "$STATE"
    done
    printf '}}}\n' ;;
  *)
    echo "fake gh: unstubbed call: $*" >&2; exit 97 ;;
esac
GHEOF
chmod +x "$BIN/gh"
export PATH="$BIN:$PATH"
export GH_FAKE_SLUG="$SLUG"

# --- fixture helpers ---------------------------------------------------------

# A throwaway git repo so repo-root.sh resolves to a config we control.
FIXTURE_REPO="$TMP_DIR/repo"
mkdir -p "$FIXTURE_REPO/.claude"
git -C "$FIXTURE_REPO" init -q 2>/dev/null || fail "could not init fixture repo"

set_cap_config() {  # $1 = full section body, or empty to remove the file
  if [[ -z "${1:-}" ]]; then
    rm -f "$FIXTURE_REPO/.claude/pm-config.md"
    return
  fi
  printf '# PM Config\n\n## Active work\n\n%s\n\n## Notes\n\nend\n' "$1" \
    > "$FIXTURE_REPO/.claude/pm-config.md"
}

# n open PRs, as the JSON array `gh pr list --json number,closingIssuesReferences`
# returns. $2 (optional) is a JSON array of issue numbers the FIRST PR closes.
set_open_prs() {
  GH_FAKE_PRS="$(jq -cn --argjson n "$1" --argjson closes "${2:-[]}" \
    '[range($n) | {number: (.+1000),
                   closingIssuesReferences:
                     (if . == 0 then [$closes[] | {number: .}] else [] end)}]')"
  export GH_FAKE_PRS
}

# Newline-separated issue numbers, as `gh issue list --jq '.[].number'` returns.
set_open_issues() { GH_FAKE_OPEN_ISSUES="$1"; export GH_FAKE_OPEN_ISSUES; }

write_chip_log() {  # $1 = log name, $2 = issues[] JSON
  printf '{"issues":%s}\n' "$2" > "$CLAUDE_ACTIVE_WORK_HANDOFF_DIR/issue-maker-$1-log.json"
}

chip_entry() {  # number, repo-slug ("" = no url), status, task-id ("null" = none)
  jq -cn --argjson n "$1" --arg r "$2" --arg s "$3" --arg t "$4" \
    '{number: $n, status: $s,
      chip_task_id: (if $t == "null" then null else $t end)}
     + (if $r == "" then {} else {url: "https://github.com/\($r)/issues/\($n)"} end)'
}

set_pipelines() {  # $1 = active_agents JSON array
  jq -cn --argjson a "$1" --arg k "$SLUG" \
    '{repos: {($k): {prs: {}}}, active_agents: $a}' > "$HOME/.claude/session-state.json"
}

run() { ( cd "$FIXTURE_REPO" && "$SCRIPT" "$@" ); }

# Baseline: nothing anywhere.
set_cap_config ""
set_open_prs 0
set_open_issues ""
set_pipelines '[]'

# --- 1. Default cap when no config and no override ---------------------------
CAP=$(run --cap) || fail "--cap failed with no config present"
[[ "$CAP" == "6" ]] || fail "default cap should be 6, got '$CAP'"
ok "no config and no override resolves the built-in default (6)"

# A repo with no pm-config.md at all is the normal portable case (#1189) and
# must be SILENT — a warning here would fire on every repo that never set one.
ERR=$(run --cap 2>&1 >/dev/null)
[[ -z "$ERR" ]] || fail "absent config should warn nothing, got: '$ERR'"
ok "an absent cap is silent, not a warning"

# --- 2. The knob is read from pm-config (KEY=value, the ## Wave precedent) ----
set_cap_config '```ini
ACTIVE_WORK_CAP=8
```'
CAP=$(run --cap) || fail "--cap failed reading the config"
[[ "$CAP" == "8" ]] || fail "config cap should be 8, got '$CAP'"
ok "ACTIVE_WORK_CAP=8 is read from pm-config"

# --- 3. Test Plan case 1: cap 8, 2 open PRs, 12 fit issues -> FREE == 6 -------
# The 12 candidate issues are the emitter's input, not the script's: the
# script's job is to say how many of them may be offered.
set_open_prs 2
JSON=$(run --json) || fail "--json failed"
FREE=$(printf '%s' "$JSON" | jq -r '.free')
ACTIVE=$(printf '%s' "$JSON" | jq -r '.active')
[[ "$ACTIVE" == "2" ]] || fail "2 open PRs should be 2 active, got '$ACTIVE'"
[[ "$FREE" == "6" ]] || fail "cap 8 minus 2 active should leave 6 free, got '$FREE'"
ok "Test Plan case 1: cap 8, 2 open PRs -> FREE=6 (12 candidates, at most 6 offered)"

# --- 4. Test Plan case 2: the colon form, and the limit follows the config ---
# `active_work_cap: 5` is the shape the ticket used; both must resolve.
set_cap_config 'active_work_cap: 5'
CAP=$(run --cap) || fail "--cap failed on the colon form"
[[ "$CAP" == "5" ]] || fail "colon form should resolve 5, got '$CAP'"
FREE=$(run --free) || fail "--free failed"
[[ "$FREE" == "3" ]] || fail "cap 5 minus 2 active should leave 3 free, got '$FREE'"
ok "Test Plan case 2: active_work_cap: 5 changes the observed limit with no code change"

# --- 5. Prose that NAMES the key is not a value -------------------------------
# pm-config.md documents the knob in bullets directly under it; a parser that
# matched mid-line would read the documentation instead of the setting.
set_cap_config '```ini
ACTIVE_WORK_CAP=7
```

- **ACTIVE_WORK_CAP** — repo-wide cap: your open PRs + chips. Default is 6.'
CAP=$(run --cap) || fail "--cap failed with prose present"
[[ "$CAP" == "7" ]] || fail "prose bullets must not shadow the ini value; got '$CAP'"
ok "a prose bullet naming ACTIVE_WORK_CAP never shadows the real value"

# --- 6. Env override wins over config ----------------------------------------
CAP=$(CLAUDE_ACTIVE_WORK_CAP=2 run --cap) || fail "--cap failed with env override"
[[ "$CAP" == "2" ]] || fail "env override should win, got '$CAP'"
ok "CLAUDE_ACTIVE_WORK_CAP overrides the config value"

# --- 7. Invalid and out-of-range fall back LOUDLY ----------------------------
# Silent fallback is the failure mode this guards: a typo'd knob that reads as
# "the default" with no signal looks identical to never having set one.
for BAD in "abc" "0" "99" "-3"; do
  OUT=$(CLAUDE_ACTIVE_WORK_CAP="$BAD" run --cap 2>"$TMP_DIR/err") || \
    fail "a bad cap ('$BAD') should fall back, not exit non-zero"
  [[ "$OUT" == "6" ]] || fail "bad cap '$BAD' should fall back to 6, got '$OUT'"
  [[ -s "$TMP_DIR/err" ]] || fail "bad cap '$BAD' must warn on stderr, but stderr was empty"
done
ok "unparseable / zero / over-max / negative caps all fall back to 6 and warn"

set_cap_config '```ini
ACTIVE_WORK_CAP=6
```'

# --- 8. Chips count only for THIS repo ---------------------------------------
# The logs are per capture-thread and span every repo worked in; counting them
# all would gate one repo on another's backlog.
write_chip_log "alpha" "[$(chip_entry 11 "$SLUG" open t1),$(chip_entry 12 other/elsewhere open t2)]"
set_open_issues "11
12"
JSON=$(run --json) || fail "--json failed with cross-repo chips"
CHIPS=$(printf '%s' "$JSON" | jq -r '.live_chips')
[[ "$CHIPS" == "1" ]] || fail "only the same-repo chip should count, got '$CHIPS'"
ok "a chip logged against another repo is not counted"

# --- 9. A chip whose issue is CLOSED is finished work, not pending work -------
# chip_task_id is cleared only on an explicit retract, so without this the
# count is a monotonic high-water mark that pins FREE at 0 forever.
set_open_issues "11"   # issue 12 closed; 13 below is closed too
write_chip_log "alpha" "[$(chip_entry 11 "$SLUG" open t1),$(chip_entry 13 "$SLUG" open t3)]"
CHIPS=$(run --json | jq -r '.live_chips') || fail "--json failed"
[[ "$CHIPS" == "1" ]] || fail "a chip for a closed issue must not count, got '$CHIPS'"
ok "a chip survives in the log after its issue closes, but stops counting"

# --- 10. A retracted chip (null task id) never counts -------------------------
write_chip_log "alpha" "[$(chip_entry 11 "$SLUG" open null)]"
CHIPS=$(run --json | jq -r '.live_chips') || fail "--json failed"
[[ "$CHIPS" == "0" ]] || fail "a null chip_task_id must not count, got '$CHIPS'"
ok "a retracted chip (chip_task_id: null) is not live"

# --- 11. Chips are de-duplicated across logs ---------------------------------
# Two capture threads can both hold an entry for the same issue; that is one
# offer, not two.
write_chip_log "alpha" "[$(chip_entry 11 "$SLUG" open t1)]"
write_chip_log "beta"  "[$(chip_entry 11 "$SLUG" open t9)]"
CHIPS=$(run --json | jq -r '.live_chips') || fail "--json failed"
[[ "$CHIPS" == "1" ]] || fail "the same issue in two logs is one chip, got '$CHIPS'"
ok "the same issue offered in two capture logs counts once"
rm -f "$CLAUDE_ACTIVE_WORK_HANDOFF_DIR/issue-maker-beta-log.json"

# --- 12. An unattributable chip is counted, and says so ----------------------
# Over-counting narrows offers (safe); under-counting widens them (the failure
# this script exists to prevent), so an entry with no usable url counts.
write_chip_log "alpha" "[$(chip_entry 11 "" open t1)]"
ERR=$(run --json 2>&1 >/dev/null)
CHIPS=$(run --json 2>/dev/null | jq -r '.live_chips')
[[ "$CHIPS" == "1" ]] || fail "an unattributable chip should be counted, got '$CHIPS'"
[[ "$ERR" == *"no attributable repo url"* ]] || \
  fail "an unattributable chip must be visible on stderr, got: '$ERR'"
ok "a chip with no usable url is counted AND warned about"

# --- 12b. A clicked chip is not counted twice --------------------------------
# The log entry survives the click; the issue stays open until the PR merges.
# Counting both the PR and its chip would halve the effective cap.
write_chip_log "alpha" "[$(chip_entry 31 "$SLUG" open t1),$(chip_entry 32 "$SLUG" open t2)]"
set_open_issues "31
32"
set_open_prs 1 '[31]'          # PR #1000 closes issue 31 — chip 31 is that PR
set_pipelines '[]'
JSON=$(run --json) || fail "--json failed with a clicked chip"
CHIPS=$(printf '%s' "$JSON" | jq -r '.live_chips')
ACTIVE=$(printf '%s' "$JSON" | jq -r '.active')
[[ "$CHIPS" == "1" ]] || fail "the chip whose issue an open PR closes must not count, got '$CHIPS'"
[[ "$ACTIVE" == "2" ]] || fail "1 PR + 1 uncovered chip should be 2 active, not 3, got '$ACTIVE'"
ok "a clicked chip whose PR is open counts once, not twice"

# --- 12c. An unattributed chip survives the PR subtraction -------------------
# An unattributed chip's number is a guess, counted conservatively against this
# repo. Matching that guess against this repo's PR-closed issues would turn the
# deliberate over-count into an under-count on a bare number collision.
write_chip_log "alpha" "[$(chip_entry 41 "" open t1)]"   # no url -> unattributed
set_open_issues "41"
set_open_prs 1 '[41]'        # an open PR here closes #41 — same number, different thing
set_pipelines '[]'
JSON=$(run --json 2>/dev/null) || fail "--json failed with an unattributed chip"
CHIPS=$(printf '%s' "$JSON" | jq -r '.live_chips')
[[ "$CHIPS" == "1" ]] || fail "an unattributed chip must survive the PR subtraction, got '$CHIPS'"
ok "an unattributed chip is exempt from the PR subtraction (a number collision cannot free a slot)"

# The attributed chip in the same position IS subtracted — the exemption is
# about attribution, not about disabling the double-count fix.
write_chip_log "alpha" "[$(chip_entry 41 "$SLUG" open t1)]"
CHIPS=$(run --json | jq -r '.live_chips') || fail "--json failed"
[[ "$CHIPS" == "0" ]] || fail "an ATTRIBUTED chip closed by an open PR must still subtract, got '$CHIPS'"
ok "the same chip, attributed, is still subtracted — the exemption is attribution-scoped"

# --- 13. Inline pipelines: only those not yet at a PR ------------------------
# An entry gains .pr when its pipeline opens one, at which point the open-PR
# source counts it; counting both would double-count the same work.
write_chip_log "alpha" "[]"
set_open_issues ""
set_open_prs 0
set_pipelines '[{"id":"a1","phase":"A"},{"id":"a2","phase":"B","pr":1234},{"id":"a3","phase":"A","pr":null}]'
JSON=$(run --json) || fail "--json failed with pipelines"
PIPES=$(printf '%s' "$JSON" | jq -r '.inline_pipelines')
[[ "$PIPES" == "2" ]] || fail "only the two agents with no PR should count, got '$PIPES'"
ok "active_agents entries at a PR are excluded; pre-PR ones count"

# --- 13b. An orphaned pre-PR agent stops consuming capacity ------------------
# active_agents records what was LAUNCHED, not what is alive; a crashed session
# leaves an entry behind, and an orphan that counts forever pins FREE at 0 and
# blocks all work. There is no status field to filter on, so age is the guard.
NOW_ISO=$(date -u +%Y-%m-%dT%H:%M:%SZ)
OLD_ISO=$(date -u -v-4H +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d '4 hours ago' +%Y-%m-%dT%H:%M:%SZ)
set_open_prs 0
set_open_issues ""
rm -f "$CLAUDE_ACTIVE_WORK_HANDOFF_DIR"/issue-maker-*-log.json
set_pipelines "[{\"id\":\"fresh\",\"phase\":\"A\",\"last_seen_at\":\"$NOW_ISO\"},
                {\"id\":\"orphan\",\"phase\":\"A\",\"last_seen_at\":\"$OLD_ISO\"}]"
PIPES=$(run --json | jq -r '.inline_pipelines') || fail "--json failed with a stale agent"
[[ "$PIPES" == "1" ]] || fail "a 4h-stale agent must not consume a slot, got '$PIPES' pipelines"
ok "an orphaned pre-PR agent ages out instead of pinning capacity forever"

# An entry with no timestamp at all is KEPT — unknown age must not read as
# expired, which would silently hand back a slot that may be in use.
set_pipelines '[{"id":"no-stamp","phase":"A"}]'
PIPES=$(run --json | jq -r '.inline_pipelines') || fail "--json failed"
[[ "$PIPES" == "1" ]] || fail "an agent with no timestamp should still count, got '$PIPES'"
ok "an agent with no timestamp counts (unknown age is never treated as expired)"

# --- 13c. Chip liveness has no open-issue horizon ----------------------------
# The previous implementation listed the N newest open issues and treated that
# as the complete set, so a chip on an older issue vanished from the count and
# RAISED free slots — the unsafe direction, on exactly the busiest repos. The
# lookup now asks about the chip numbers themselves, so issue age is irrelevant.
set_pipelines '[]'
write_chip_log "alpha" "[$(chip_entry 7 "$SLUG" open t1)]"
set_open_issues "7"        # #7 is old, and the only thing asked about
CHIPS=$(run --json | jq -r '.live_chips') || fail "--json failed"
[[ "$CHIPS" == "1" ]] || fail "a chip on an old issue must still count, got '$CHIPS'"
ok "chip liveness asks about the chip's own issue, with no newest-N horizon"

# --- 14. The three sources sum, and FREE clamps at zero ----------------------
# Every source is set explicitly here rather than inherited from section 13:
# a fixture that leans on a previous section's leftovers stops testing what it
# says the moment sections are reordered or removed
# (feedback_test_fixture_must_build_its_own_premise.md).
set_open_prs 3
write_chip_log "alpha" "[$(chip_entry 21 "$SLUG" open t1),$(chip_entry 22 "$SLUG" open t2)]"
set_open_issues "21
22"
set_pipelines '[{"id":"b1","phase":"A"},{"id":"b2","phase":"A","pr":null}]'
JSON=$(run --json) || fail "--json failed"
ACTIVE=$(printf '%s' "$JSON" | jq -r '.active')
FREE=$(printf '%s' "$JSON" | jq -r '.free')
[[ "$ACTIVE" == "7" ]] || fail "3 PRs + 2 chips + 2 pipelines should be 7 active, got '$ACTIVE'"
[[ "$FREE" == "0" ]] || fail "active past the cap must clamp FREE to 0, never negative, got '$FREE'"
ok "the three sources sum (3+2+2=7) and FREE clamps at 0 when over cap"

# Derived relationship, asserted rather than the literals: FREE is exactly the
# headroom, so retuning the default can never silently break the arithmetic.
CAPV=$(printf '%s' "$JSON" | jq -r '.cap')
EXPECTED=$(( CAPV - ACTIVE )); (( EXPECTED < 0 )) && EXPECTED=0
[[ "$FREE" == "$EXPECTED" ]] || fail "FREE ($FREE) should equal max(0, cap-active) ($EXPECTED)"
ok "FREE is exactly max(0, CAP - ACTIVE)"

# --- 15. A source that cannot be READ fails loudly, never as zero ------------
# A fabricated zero reads as "nothing active" and would silently uncap the
# gate (feedback_fabricated_sentinel_stable_signature.md).
OUT=$(GH_FAKE_PR_FAIL=1 run --json 2>"$TMP_DIR/err"); RC=$?
[[ $RC -eq 5 ]] || fail "a gh pr list failure should exit 5, got $RC"
[[ -z "$OUT" ]] || fail "a read failure must print nothing on stdout, got: '$OUT'"
grep -q "gh pr list" "$TMP_DIR/err" || fail "the gh failure should name the call on stderr"
ok "a failed open-PR read exits 5 and prints no count"

write_chip_log "alpha" "[$(chip_entry 21 "$SLUG" open t1)]"
set_open_issues "21"
OUT=$(GH_FAKE_ISSUE_FAIL=1 run --json 2>"$TMP_DIR/err"); RC=$?
[[ $RC -eq 5 ]] || fail "a gh issue list failure should exit 5, got $RC"
[[ -z "$OUT" ]] || fail "a read failure must print nothing on stdout"
ok "a failed open-issue read exits 5 rather than counting chips as stale-free"

# A GraphQL 200 carrying `errors` is a failed read, not an empty set — counting
# the resolved half would drop chips and hand back capacity that is in use.
write_chip_log "alpha" "[$(chip_entry 21 "$SLUG" open t1)]"
set_open_issues "21"
OUT=$(GH_FAKE_GQL_PARTIAL=1 run --json 2>"$TMP_DIR/err"); RC=$?
[[ $RC -eq 5 ]] || fail "a GraphQL errors response should exit 5, got $RC"
[[ -z "$OUT" ]] || fail "a GraphQL errors response must print no count, got: '$OUT'"
grep -qi "graphql returned errors" "$TMP_DIR/err" || \
  fail "the GraphQL errors response should name itself on stderr, got: $(cat "$TMP_DIR/err")"
ok "a GraphQL 200-with-errors exits 5 instead of counting the partial answer"

printf 'this is not json\n' > "$CLAUDE_ACTIVE_WORK_HANDOFF_DIR/issue-maker-broken-log.json"
OUT=$(run --json 2>"$TMP_DIR/err"); RC=$?
[[ $RC -eq 5 ]] || fail "a malformed chip log should exit 5, got $RC"
grep -q "UNKNOWN" "$TMP_DIR/err" || \
  fail "a malformed chip log must say its contents are unknown, not zero"
ok "a malformed chip log exits 5 and is never read as 'no chips'"
rm -f "$CLAUDE_ACTIVE_WORK_HANDOFF_DIR/issue-maker-broken-log.json"

# Valid JSON of the WRONG SHAPE is the dangerous case: `.issues[]?` yields no
# rows at exit 0 for all of these, which is indistinguishable from a log that
# genuinely holds no chips — a fabricated zero that would uncap the gate.
for SHAPE in '{}' '{"issues":null}' '{"issues":"garbage"}' '[]' '"a string"'; do
  printf '%s\n' "$SHAPE" > "$CLAUDE_ACTIVE_WORK_HANDOFF_DIR/issue-maker-shape-log.json"
  OUT=$(run --json 2>"$TMP_DIR/err"); RC=$?
  [[ $RC -eq 5 ]] || fail "wrong-shape chip log '$SHAPE' should exit 5, got $RC"
  [[ -z "$OUT" ]] || fail "wrong-shape chip log '$SHAPE' must print no count"
done
rm -f "$CLAUDE_ACTIVE_WORK_HANDOFF_DIR/issue-maker-shape-log.json"
ok "valid-JSON-but-wrong-shape chip logs exit 5 instead of counting as zero"

# ...while a real, empty log is a legitimate zero and must still pass.
write_chip_log "empty" "[]"
set_open_prs 0
set_open_issues ""
OUT=$(run --json) || fail "an empty-but-well-formed chip log must not fail"
[[ "$(printf '%s' "$OUT" | jq -r '.live_chips')" == "0" ]] || fail "an empty log should be 0 chips"
ok "a well-formed empty chip log is a legitimate zero"
rm -f "$CLAUDE_ACTIVE_WORK_HANDOFF_DIR/issue-maker-empty-log.json"

# --- 16. Missing state is empty, not broken ----------------------------------
rm -f "$HOME/.claude/session-state.json"
rm -f "$CLAUDE_ACTIVE_WORK_HANDOFF_DIR"/issue-maker-*-log.json
set_open_prs 0
set_open_issues ""
JSON=$(run --json) || fail "--json should succeed with no state files at all"
[[ "$(printf '%s' "$JSON" | jq -r '.active')" == "0" ]] || fail "a clean slate should be 0 active"
[[ "$(printf '%s' "$JSON" | jq -r '.free')" == "6" ]] || fail "a clean slate should leave the full cap free"
ok "no session-state and no chip logs is 0 active, not a failure"

# --- 16b. --path from a DIFFERENT caller directory scopes every source -------
# Every other section runs from inside the fixture repo, so a PR fetch that
# silently used the caller's checkout would look identical to a correct one.
# This runs from an unrelated directory and makes the fake refuse any `pr list`
# that is not scoped to the resolved target, so cap, PRs, chips, and pipelines
# are proven to come from one repo rather than two.
OUTSIDE="$TMP_DIR/elsewhere"
mkdir -p "$OUTSIDE"
git -C "$OUTSIDE" init -q 2>/dev/null || fail "could not init the outside dir"
set_cap_config '```ini
ACTIVE_WORK_CAP=4
```'
set_open_prs 1
set_open_issues ""
set_pipelines '[]'
rm -f "$CLAUDE_ACTIVE_WORK_HANDOFF_DIR"/issue-maker-*-log.json

JSON=$( cd "$OUTSIDE" && GH_FAKE_REQUIRE_REPO="$SLUG" "$SCRIPT" --path "$FIXTURE_REPO" --json ) \
  || fail "--path from an outside directory failed (pr list was not scoped to $SLUG)"
[[ "$(printf '%s' "$JSON" | jq -r '.cap')" == "4" ]] || \
  fail "--path should read the TARGET repo's cap (4), got '$(printf '%s' "$JSON" | jq -r '.cap')'"
[[ "$(printf '%s' "$JSON" | jq -r '.open_prs')" == "1" ]] || \
  fail "--path should count the target repo's PRs, got '$(printf '%s' "$JSON" | jq -r '.open_prs')'"
ok "--path from an unrelated cwd scopes the cap AND the PR count to the same repo"

# Restore the baseline this section borrowed — a later assertion reads the cap
# and would otherwise inherit the 4 set above.
set_cap_config '```ini
ACTIVE_WORK_CAP=6
```'
set_open_prs 0

# --- 17. --cap makes no network call -----------------------------------------
# Emitters that only need the knob must not pay for (or fail on) the count.
CAP=$(PATH="$TMP_DIR/empty-bin:$PATH" GH_FAKE_PR_FAIL=1 run --cap) || \
  fail "--cap should not depend on the count sources"
[[ "$CAP" == "6" ]] || fail "--cap should still resolve 6, got '$CAP'"
ok "--cap resolves the knob without touching gh or session-state"

# --- 18. Usage errors ---------------------------------------------------------
run --json --free >/dev/null 2>&1; RC=$?
[[ $RC -eq 2 ]] || fail "conflicting output modes should exit 2, got $RC"
run --nope >/dev/null 2>&1; RC=$?
[[ $RC -eq 2 ]] || fail "an unknown flag should exit 2, got $RC"
run --repo 'not a slug' >/dev/null 2>&1; RC=$?
[[ $RC -eq 2 ]] || fail "a malformed --repo should exit 2, got $RC"
run --repo >/dev/null 2>&1; RC=$?
[[ $RC -eq 2 ]] || fail "--repo with no value should exit 2, got $RC"
ok "conflicting modes, unknown flags, and malformed/missing --repo all exit 2"

run --help >/dev/null 2>&1 || fail "--help should exit 0"
ok "--help exits 0"

echo "OK: active-work-cap.sh tests passed"
