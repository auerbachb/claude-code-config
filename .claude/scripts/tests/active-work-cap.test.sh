#!/usr/bin/env bash
# Tests for active-work-cap.sh — the repo-wide budget for simultaneously
# catalog: tests — Tests for `active-work-cap.sh` — cap resolution, the three count sources, and fail-loud read errors
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

# Isolate from caller-set overrides — assertions that rely on a built-in
# default must not silently inherit a different number from the environment.
# This must list EVERY tunable the script reads: the cap (default-cap cases)
# and the agent TTL (the stale-agent cases stamp an entry four hours old and
# expect the 7200s default to expire it, which a caller-set TTL would flip in
# either direction). Keep in step with the script's TUNING block.
unset CLAUDE_ACTIVE_WORK_CAP
unset CLAUDE_ACTIVE_WORK_AGENT_TTL_S
unset CLAUDE_ACTIVE_WORK_MERGED_PR_LIMIT

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
# Answered in the real banner shape so the version parse is actually exercised
# rather than always falling through to its unknown-version path (#1335).
if [[ "${1:-}" == "--version" || "${1:-}" == "version" ]]; then
  _V="${GH_FAKE_VERSION:-2.98.0}"
  printf 'gh version %s (2026-08-20)\nhttps://github.com/cli/cli/releases/tag/v%s\n' "$_V" "$_V"
  exit 0
fi
case "$1 $2" in
  "repo view")
    [[ -n "${GH_FAKE_SLUG:-}" ]] || { echo "fake gh: GH_FAKE_SLUG unset" >&2; exit 1; }
    need "--json"
    printf '%s\n' "$GH_FAKE_SLUG" ;;
  "pr list")
    if [[ "${GH_FAKE_PR_FAIL:-0}" == "1" ]]; then
      echo "fake gh: simulated API failure" >&2; exit 1
    fi
    # An unknown-field error naming some OTHER field, with
    # closingIssuesReferences present in the Available list. This is the shape
    # that tempts a detector into reading its own catalogue as the capability
    # gap, and it must stay a hard read failure (#1335).
    if [[ "${GH_FAKE_UNKNOWN_OTHER_FIELD:-0}" == "1" ]]; then
      printf 'Unknown JSON field: "someOtherField"\nAvailable fields:\n  body\n  closingIssuesReferences\n  mergedAt\n  number\n' >&2
      exit 1
    fi
    # Author scoping (#732/#733) and the closing-issue field (double-count fix)
    # are both load-bearing; losing either silently corrupts the count.
    # --state is required; its value (open|merged) governs which fixture to use.
    need "--state"; need "--author"; need "@me"
    # old gh mode (#1335): reject closingIssuesReferences exactly as gh does
    # — client-side, before any network call, naming the field on the first
    # line and then listing the fields it DOES know. Reproducing the available
    # list matters: a detector that searched the whole message unanchored would
    # match that catalogue on a modern gh and degrade a healthy client.
    if [[ "${GH_FAKE_NO_CLOSING_REFS:-0}" == "1" ]]; then
      case "$ARGS" in
        *"closingIssuesReferences"*)
          printf 'Unknown JSON field: "closingIssuesReferences"\nAvailable fields:\n  body\n  mergedAt\n  number\n  title\n' >&2
          exit 1 ;;
      esac
      # The degraded retry must ask for body instead — a fake that served the
      # fixture regardless would certify a fallback that never read one.
      case "$ARGS" in
        *"body"*) ;;
        *) echo "fake gh: degraded pr list must request body: $*" >&2; exit 96 ;;
      esac
    else
      case "$ARGS" in
        *"closingIssuesReferences"*) ;;
        *) echo "fake gh: pr list must request closingIssuesReferences: $*" >&2; exit 96 ;;
      esac
    fi
    # When set, the PR listing MUST be scoped to this repo. Without this the
    # suite cannot tell a correctly-scoped fetch from one that silently ran
    # against the caller's checkout.
    if [[ -n "${GH_FAKE_REQUIRE_REPO:-}" ]]; then
      need "--repo"; need "$GH_FAKE_REQUIRE_REPO"
    fi
    # In old gh mode the fixtures carry `body` instead of the API field, so
    # the suite exercises the keyword parse rather than handing the code the
    # very structure it is supposed to reconstruct.
    _OPEN_FIXTURE="${GH_FAKE_PRS:-[]}"
    _MERGED_FIXTURE="${GH_FAKE_MERGED_PRS:-[]}"
    if [[ "${GH_FAKE_NO_CLOSING_REFS:-0}" == "1" ]]; then
      _OPEN_FIXTURE="${GH_FAKE_PRS_BODY:-[]}"
      _MERGED_FIXTURE="${GH_FAKE_MERGED_PRS_BODY:-[]}"
    fi
    # Dispatch on the --state value so both `open` and `merged` fetches work
    # (the merged-PR leak fix fetches recently-merged PRs via --state merged).
    case "$ARGS" in
      *" open "*)   printf '%s\n' "$_OPEN_FIXTURE" ;;
      *" merged "*)
        # GH_FAKE_FORBID_MERGED=1 marks tests that must NOT invoke gh pr list
        # --state merged (e.g. limit=0 short-circuit). Fail hard so a broken
        # code path that calls gh anyway still receives an empty fixture and
        # the test result doesn't turn into a false positive.
        if [[ "${GH_FAKE_FORBID_MERGED:-0}" == "1" ]]; then
          echo "fake gh: gh pr list --state merged must NOT be called in this test: $*" >&2
          exit 96
        fi
        # mergedAt is required for client-side sort ordering; fail hard if absent.
        case "$ARGS" in
          *"mergedAt"*) ;;
          *) echo "fake gh: pr list --state merged must request mergedAt for ordering: $*" >&2; exit 96 ;;
        esac
        # Enforce --limit so tests can verify that fetch_merged_prs requests a
        # wider candidate set (limit*3) and that the over-fetch is what enables
        # detection of an older-created, recently-merged PR (test 26).
        _FAKE_LIMIT=""
        if [[ "$ARGS" =~ --limit[[:space:]]+([0-9]+) ]]; then
          _FAKE_LIMIT="${BASH_REMATCH[1]}"
        fi
        if [[ -n "$_FAKE_LIMIT" ]]; then
          printf '%s' "$_MERGED_FIXTURE" | jq --argjson n "$_FAKE_LIMIT" '.[0:$n]'
        else
          printf '%s\n' "$_MERGED_FIXTURE"
        fi ;;
      *)
        echo "fake gh: pr list --state must be 'open' or 'merged' in: $*" >&2
        exit 96 ;;
    esac ;;
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

# n recently-merged PRs (for the merged-PR leak fix, AC#1 — #1285).
# $2 (optional) is a JSON array of issue numbers the FIRST merged PR closes.
# PR numbers start at 2000 to be distinct from open PR numbers (1000+).
set_merged_prs() {
  GH_FAKE_MERGED_PRS="$(jq -cn --argjson n "$1" --argjson closes "${2:-[]}" \
    '[range($n) | {number: (.+2000),
                   mergedAt: "2026-08-23T20:00:00Z",
                   closingIssuesReferences:
                     (if . == 0 then [$closes[] | {number: .}] else [] end)}]')"
  export GH_FAKE_MERGED_PRS
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

# $1 is an array of agent records, for readability at the call sites — it is
# written to disk in the keyed-map shape `.active_agents` has carried since
# issue #1631, so every case below exercises the real shape rather than the
# legacy array the migration would rescue.
set_pipelines() {  # $1 = active_agents JSON array of records
  jq -cn --argjson a "$1" --arg k "$SLUG" \
    '{repos: {($k): {prs: {}}},
      active_agents: (reduce ($a | to_entries[]) as $e ({};
        .[($e.value.id // ("_unkeyed_" + ($e.key | tostring)))] = $e.value))}' \
    > "$HOME/.claude/session-state.json"
}

run() { ( cd "$FIXTURE_REPO" && "$SCRIPT" "$@" ); }

# Baseline: nothing anywhere.
set_cap_config ""
set_open_prs 0
set_merged_prs 0
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
# States its own premise rather than inheriting section 9's open-issue set: the
# retracted-chip filter must be the ONLY reason this reads 0
# (feedback_test_fixture_must_build_its_own_premise.md).
set_open_issues "11"
write_chip_log "alpha" "[$(chip_entry 11 "$SLUG" open null)]"
CHIPS=$(run --json | jq -r '.live_chips') || fail "--json failed"
[[ "$CHIPS" == "0" ]] || fail "a null chip_task_id must not count, got '$CHIPS'"
ok "a retracted chip (chip_task_id: null) is not live"

# --- 11. Chips are de-duplicated across logs ---------------------------------
# Two capture threads can both hold an entry for the same issue; that is one
# offer, not two. Premise set explicitly so dedupe is the only thing under test.
set_open_issues "11"
write_chip_log "alpha" "[$(chip_entry 11 "$SLUG" open t1)]"
write_chip_log "beta"  "[$(chip_entry 11 "$SLUG" open t9)]"
CHIPS=$(run --json | jq -r '.live_chips') || fail "--json failed"
[[ "$CHIPS" == "1" ]] || fail "the same issue in two logs is one chip, got '$CHIPS'"
ok "the same issue offered in two capture logs counts once"
rm -f "$CLAUDE_ACTIVE_WORK_HANDOFF_DIR/issue-maker-beta-log.json"

# --- 12. An unattributable chip is counted, and says so ----------------------
# Over-counting narrows offers (safe); under-counting widens them (the failure
# this script exists to prevent), so an entry with no usable url counts.
set_open_issues "11"
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

# The case the section above CANNOT catch: there, the guessed chip's number was
# also an open issue here, so it survived the intersection for the wrong reason.
# A guessed number is meaningless outside its repo, so it will usually NOT be an
# open issue in this one — and an intersection applied to it drops every such
# chip. That is the under-count this whole exemption exists to prevent.
write_chip_log "alpha" "[$(chip_entry 777 "" open t1)]"   # unattributed
set_open_issues ""                                         # #777 is NOT open here
set_open_prs 0
set_pipelines '[]'
CHIPS=$(run --json 2>/dev/null | jq -r '.live_chips') || fail "--json failed"
[[ "$CHIPS" == "1" ]] || \
  fail "a guessed chip whose number is not an open issue here must still count, got '$CHIPS'"
ok "a guessed chip survives the open-issue intersection too, not just the PR subtraction"

# ...and the attributed equivalent is still dropped when its issue is not open,
# so the exemption did not disable the liveness check for real chips.
write_chip_log "alpha" "[$(chip_entry 777 "$SLUG" open t1)]"
CHIPS=$(run --json | jq -r '.live_chips') || fail "--json failed"
[[ "$CHIPS" == "0" ]] || \
  fail "an ATTRIBUTED chip on a non-open issue must not count, got '$CHIPS'"
ok "an attributed chip on a closed/absent issue is still dropped"

# A guessed chip ALONGSIDE a surviving attributed one. The two cases above both
# leave `sure` empty and exit through an early return, so neither reaches the
# final total — only a mixed set proves the guessed count is actually added to
# the intersection result rather than replacing it.
write_chip_log "alpha" "[$(chip_entry 55 "$SLUG" open t1),$(chip_entry 777 "" open t2)]"
set_open_issues "55"        # 55 is open here; 777 is a foreign number
CHIPS=$(run --json 2>/dev/null | jq -r '.live_chips') || fail "--json failed"
[[ "$CHIPS" == "2" ]] || \
  fail "1 attributed-and-open + 1 guessed should be 2 chips, got '$CHIPS'"
ok "guessed chips are added to the intersection result, not replaced by it"

# --- 12d. Slug comparison is case-insensitive --------------------------------
# GitHub repo identities are case-insensitive, so a URL recorded as Owner/Repo
# names the same repo as a slug resolved as owner/repo. A literal compare would
# call it unattributable, which sends it down the guessed path and exempts it
# from BOTH filters — a stale chip would keep consuming capacity after its
# issue closed.
UPPER_SLUG="TestOwner/TestRepo"
write_chip_log "alpha" "[$(chip_entry 61 "$UPPER_SLUG" open t1)]"
set_open_issues ""          # #61 is NOT open, so an attributed chip must drop
set_open_prs 0
set_pipelines '[]'
CHIPS=$(run --json 2>/dev/null | jq -r '.live_chips') || fail "--json failed"
[[ "$CHIPS" == "0" ]] || \
  fail "a differently-cased slug must be recognised as this repo (and dropped as closed), got '$CHIPS'"
ok "chip slugs compare case-insensitively, as GitHub identities do"

# --- 12e. One issue in two logs, attributed once and not the other -----------
# Deduping `sure` and `guessed` independently kept the same offer in both
# classes, so it consumed two slots. Attribution wins: an entry naming this
# repo is better evidence than one naming nothing.
write_chip_log "alpha" "[$(chip_entry 62 "$SLUG" open t1)]"   # attributed
write_chip_log "beta"  "[$(chip_entry 62 "" open t2)]"        # same issue, no url
set_open_issues "62"
CHIPS=$(run --json 2>/dev/null | jq -r '.live_chips') || fail "--json failed"
[[ "$CHIPS" == "1" ]] || \
  fail "one issue recorded in both attribution classes is one chip, got '$CHIPS'"
ok "an issue attributed in one log and not another counts once, not twice"
rm -f "$CLAUDE_ACTIVE_WORK_HANDOFF_DIR/issue-maker-beta-log.json"

# --- 12f. One chip covering many issues is ONE offer, not N ------------------
# /issue-maker writes one log entry per issue it filed, all carrying the SAME
# chip_task_id, because it offers one hand-off per capture session covering
# every issue (issue-maker/SKILL.md Step 9c). Counting entries let one 24-issue
# capture session report ACTIVE=24 against a CAP=6 board on a repo with no open
# PRs and no pipelines, pinning FREE at 0 and silently stalling every chip
# emitter. Shape taken from the real auerbachb/inventory log that surfaced it:
# issues 555-578, one chip, task_a85e2e4d (#1247).
BIG_ENTRIES=""
BIG_OPEN=""
N=555
while [[ $N -le 578 ]]; do
  [[ -z "$BIG_ENTRIES" ]] || BIG_ENTRIES="$BIG_ENTRIES,"
  BIG_ENTRIES="$BIG_ENTRIES$(chip_entry "$N" "$SLUG" open task_a85e2e4d)"
  BIG_OPEN="$BIG_OPEN$N
"
  N=$(( N + 1 ))
done
# The fixture must actually be the reported shape, or this passes for the wrong
# reason — 24 entries, exactly one distinct chip id.
ENTRY_COUNT=$(printf '[%s]' "$BIG_ENTRIES" | jq 'length')
ID_COUNT=$(printf '[%s]' "$BIG_ENTRIES" | jq '[.[].chip_task_id] | unique | length')
[[ "$ENTRY_COUNT" == "24" && "$ID_COUNT" == "1" ]] || \
  fail "fixture is not 24 entries under 1 chip id (got $ENTRY_COUNT entries, $ID_COUNT ids)"
write_chip_log "alpha" "[$BIG_ENTRIES]"
set_open_issues "$BIG_OPEN"
set_open_prs 0
set_pipelines '[]'
JSON=$(run --json) || fail "--json failed on a 24-issue chip log"
CHIPS=$(printf '%s' "$JSON" | jq -r '.live_chips')
ACTIVE=$(printf '%s' "$JSON" | jq -r '.active')
FREE=$(printf '%s' "$JSON" | jq -r '.free')
[[ "$CHIPS" == "1" ]] || fail "24 entries under one chip_task_id is 1 chip, got '$CHIPS'"
[[ "$ACTIVE" == "1" ]] || fail "one chip on an otherwise idle repo is 1 active, got '$ACTIVE'"
[[ "$FREE" == "5" ]] || fail "an idle CAP=6 repo holding one chip has 5 free, got '$FREE'"
ok "a 24-issue capture session counts as one chip, not 24 (#1247)"

# --- 12g. Distinct chips still count distinctly ------------------------------
# The common case must not regress: one issue per capture session is still one
# chip each. A fix that collapsed every entry into a single count would pass
# 12f while quietly uncapping the board.
write_chip_log "alpha" \
  "[$(chip_entry 71 "$SLUG" open t1),$(chip_entry 72 "$SLUG" open t2),$(chip_entry 73 "$SLUG" open t3)]"
set_open_issues "71
72
73"
CHIPS=$(run --json | jq -r '.live_chips') || fail "--json failed"
[[ "$CHIPS" == "3" ]] || fail "three single-issue chips are 3, got '$CHIPS'"
ok "single-issue-per-chip logs still count 1 each"

# Two MULTI-issue chips are 2 — the de-duplication is per chip id, not a global
# collapse to 1.
write_chip_log "alpha" \
  "[$(chip_entry 71 "$SLUG" open tA),$(chip_entry 72 "$SLUG" open tA),$(chip_entry 73 "$SLUG" open tB),$(chip_entry 74 "$SLUG" open tB)]"
set_open_issues "71
72
73
74"
CHIPS=$(run --json | jq -r '.live_chips') || fail "--json failed"
[[ "$CHIPS" == "2" ]] || fail "two chips of two issues each are 2, got '$CHIPS'"
ok "two multi-issue chips count 2 — de-duplication is per chip, not global"

# The same chip id split across two capture logs is still one chip.
write_chip_log "alpha" "[$(chip_entry 91 "$SLUG" open tZ)]"
write_chip_log "beta"  "[$(chip_entry 92 "$SLUG" open tZ)]"
set_open_issues "91
92"
CHIPS=$(run --json | jq -r '.live_chips') || fail "--json failed"
[[ "$CHIPS" == "1" ]] || fail "one chip id across two logs is 1 chip, got '$CHIPS'"
ok "one chip id recorded in two capture logs counts once"
rm -f "$CLAUDE_ACTIVE_WORK_HANDOFF_DIR/issue-maker-beta-log.json"

# One chip spanning BOTH attribution classes is still one chip. Attributed and
# unattributable entries take different paths through the narrowings and are
# only reunited at the distinct-chip step, so a build that counted each class
# separately and summed them would report 2 here.
write_chip_log "alpha" "[$(chip_entry 95 "$SLUG" open tY),$(chip_entry 96 "" open tY)]"
set_open_issues "95"           # 96 has no url, so it never reaches this list
set_open_prs 0
CHIPS=$(run --json 2>/dev/null | jq -r '.live_chips') || fail "--json failed"
[[ "$CHIPS" == "1" ]] || \
  fail "one chip with an attributed and an unattributable entry is 1, got '$CHIPS'"
ok "a chip spanning both attribution classes counts once"

# --- 12h. Partial absorption: a chip counts 1 until ALL its issues are gone ---
# Clicking a half-absorbed chip still opens one thread with real work left, so
# it keeps its slot. Absorption by an open PR first.
#
# THREE issues, not two: with two, "one surviving issue" and "one surviving
# chip" are the same number, so the old entry-counting build would pass this for
# the wrong reason (feedback_exemption_test_must_use_a_discriminating_value.md).
# With three and one absorbed, entry-counting says 2 and chip-counting says 1.
write_chip_log "alpha" \
  "[$(chip_entry 81 "$SLUG" open tA),$(chip_entry 82 "$SLUG" open tA),$(chip_entry 87 "$SLUG" open tA)]"
set_open_issues "81
82
87"
set_open_prs 1 '[81]'          # PR #1000 covers 81; 82 and 87 are still unclaimed
JSON=$(run --json) || fail "--json failed on a partially absorbed chip"
CHIPS=$(printf '%s' "$JSON" | jq -r '.live_chips')
ACTIVE=$(printf '%s' "$JSON" | jq -r '.active')
[[ "$CHIPS" == "1" ]] || fail "a chip with issues left unabsorbed still counts 1, got '$CHIPS'"
[[ "$ACTIVE" == "2" ]] || fail "1 open PR + 1 half-absorbed chip is 2 active, got '$ACTIVE'"
ok "a chip with a mix of absorbed and unabsorbed issues counts 1"

# Every issue absorbed -> the chip is finished work and counts 0. Without this
# the assertion above would also pass on a build that de-duplicated BEFORE the
# narrowings, where one absorbed issue could still speak for its whole chip.
set_open_prs 1 '[81,82,87]'
JSON=$(run --json) || fail "--json failed on a fully absorbed chip"
CHIPS=$(printf '%s' "$JSON" | jq -r '.live_chips')
ACTIVE=$(printf '%s' "$JSON" | jq -r '.active')
[[ "$CHIPS" == "0" ]] || fail "a chip whose every issue an open PR covers is 0, got '$CHIPS'"
[[ "$ACTIVE" == "1" ]] || fail "the PR alone should remain, got '$ACTIVE'"
ok "a chip whose issues are all absorbed by open PRs counts 0"

# The same boundary via the OTHER narrowing — closed issues rather than PRs —
# so neither filter is doing the work alone.
set_open_prs 0
set_open_issues "82
87"                              # 81 has closed; 82 and 87 are still open
CHIPS=$(run --json | jq -r '.live_chips') || fail "--json failed"
[[ "$CHIPS" == "1" ]] || fail "a chip with issues still open counts 1, got '$CHIPS'"
set_open_issues ""             # all three closed
CHIPS=$(run --json | jq -r '.live_chips') || fail "--json failed"
[[ "$CHIPS" == "0" ]] || fail "a chip whose every issue has closed is 0, got '$CHIPS'"
ok "partial and full absorption behave the same way through the closed-issue filter"

# --- 12i. De-duplication runs AFTER the narrowings, not before ---------------
# If chips collapsed first, one surviving issue would carry its whole chip past
# the filters — or one absorbed issue would drop issues that are still live.
# Two three-issue chips, each thinned by a DIFFERENT filter, must still total 2:
# entry-counting reports 4 here, so the assertion discriminates.
write_chip_log "alpha" \
  "[$(chip_entry 83 "$SLUG" open tA),$(chip_entry 84 "$SLUG" open tA),$(chip_entry 87 "$SLUG" open tA),$(chip_entry 85 "$SLUG" open tB),$(chip_entry 86 "$SLUG" open tB),$(chip_entry 88 "$SLUG" open tB)]"
set_open_issues "84
85
86
87
88"                              # 83 closed
set_open_prs 1 '[85]'          # 85 covered by a PR; 84/87 and 86/88 remain
JSON=$(run --json) || fail "--json failed"
CHIPS=$(printf '%s' "$JSON" | jq -r '.live_chips')
[[ "$CHIPS" == "2" ]] || \
  fail "two chips each keeping live issues are 2, got '$CHIPS'"
ok "de-duplication is applied after both narrowings, not before"

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
# Assert the property directly instead of trying to engineer `gh` off PATH.
# Removing it is not portable — CI runners ship a real gh in a system bin, so
# an "empty" PATH prefix still reaches one and the isolation silently stops
# isolating (which is exactly what the previous attempt did, and what CI
# caught). A decoy that FAILS when invoked cannot be fooled by any environment:
# if `--cap` succeeds with this first on PATH, gh was genuinely never called.
DECOY="$TMP_DIR/decoy-bin"
mkdir -p "$DECOY"
cat > "$DECOY/gh" <<'DECOYEOF'
#!/usr/bin/env bash
echo "decoy gh: --cap must not invoke gh, but it did: $*" >&2
exit 98
DECOYEOF
chmod +x "$DECOY/gh"
CAP=$(PATH="$DECOY:$PATH" run --cap 2>"$TMP_DIR/decoyerr"); RC=$?
[[ $RC -eq 0 ]] || fail "--cap invoked gh (decoy fired): $(cat "$TMP_DIR/decoyerr")"
[[ "$CAP" == "6" ]] || fail "--cap should still resolve 6, got '$CAP'"
ok "--cap resolves the knob without invoking gh at all (decoy never fired)"

# The decoy is only meaningful if it would actually fire — a --json run makes
# the network calls --cap skips, so it must trip.
OUT=$(PATH="$DECOY:$PATH" run --json 2>/dev/null); RC=$?
[[ $RC -ne 0 ]] || fail "the decoy never fires, so the assertion above proves nothing"
ok "the same decoy does trip on --json, so the --cap result is meaningful"

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

# Exit code alone would pass for a --help that prints nothing. Assert the
# sections and every flag, so a header that stops short of the usage block (or
# a flag added without documenting it) fails here.
HELP=$(run --help 2>/dev/null) || fail "--help should exit 0"
for SECTION in USAGE MODES FLAGS TUNING OUTPUT "EXIT STATUS"; do
  [[ "$HELP" == *"$SECTION"* ]] || fail "--help omits the $SECTION section"
done
for FLAG in -- --json --free --cap --repo --path \
            CLAUDE_ACTIVE_WORK_CAP CLAUDE_ACTIVE_WORK_AGENT_TTL_S \
            CLAUDE_ACTIVE_WORK_HANDOFF_DIR CLAUDE_CHIP_OFFER_REGISTRY_SH \
            CLAUDE_ACTIVE_WORK_MERGED_PR_LIMIT; do
  [[ "$FLAG" == "--" ]] && continue
  [[ "$HELP" == *"$FLAG"* ]] || fail "--help does not document $FLAG"
done
ok "--help prints every documented section, flag, and tunable"

# --- 19. Registry chips (from /pm, /prompt, /wave) count toward the cap ------
# Before this fix, chips offered by /pm and /prompt were invisible to the count
# because only the issue-maker log was read. Now the registry covers all emitters.
#
# Use a real chip-offer-registry.sh (via a minimal fake session-state) so that
# registry entries are counted. The fake registry script mimics the --list output
# with a static JSON array held in an env var so no disk I/O is needed.
FAKE_REG="$TMP_DIR/bin/chip-offer-registry.sh"
cat > "$FAKE_REG" <<'REGEOF'
#!/usr/bin/env bash
# Minimal fake for chip-offer-registry.sh.
# --list: return REG_FAKE_LIST as-is.
# --count: count offered/running entries respecting TTL (mirrors count_active_offers).
case "$*" in
  *"--list"*) printf '%s\n' "${REG_FAKE_LIST:-[]}" ;;
  *"--count"*)
    ttl_s="${CLAUDE_CHIP_OFFER_TTL_S:-86400}"
    [[ "$ttl_s" =~ ^[0-9]+$ ]] || ttl_s=86400
    now="$(date -u +%s)"
    n="$(printf '%s\n' "${REG_FAKE_LIST:-[]}" | jq -r \
      --argjson now "$now" --argjson ttl "$ttl_s" '
      [ .[]
        | select(.state == "offered" or .state == "running")
        | select(
            (.offered_at // "") as $t
            | if $t == "" then true
              else ($t | fromdateiso8601? // null) as $e
                   | if $e == null then true else ($now - $e) < $ttl end
              end
          )
      ] | length')"
    printf '%s\n' "$n"
    ;;
  *) echo "fake registry: unsupported call: $*" >&2; exit 97 ;;
esac
REGEOF
chmod +x "$FAKE_REG"
export CLAUDE_CHIP_OFFER_REGISTRY_SH="$FAKE_REG"

set_open_prs 0
set_open_issues ""
rm -f "$CLAUDE_ACTIVE_WORK_HANDOFF_DIR"/issue-maker-*-log.json
set_pipelines '[]'

# A /pm chip in the registry (offered state) — no issue-maker log entry.
NOW_REG="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
export REG_FAKE_LIST="$(jq -cn --arg now "$NOW_REG" \
  '[{task_id:"tid-pm-1",emitter:"pm",issue:101,state:"offered",offered_at:$now,
     expires_at:$now,pr:null,last_updated:$now}]')"
JSON=$(run --json) || fail "19: --json failed with a pm registry chip"
CHIPS=$(printf '%s' "$JSON" | jq -r '.live_chips')
[[ "$CHIPS" == "1" ]] || fail "19: /pm chip in registry should count as 1, got '$CHIPS'"
ok "a chip offered by /pm through the registry is counted toward the cap"

# A /prompt chip in running state also counts.
export REG_FAKE_LIST="$(jq -cn --arg now "$NOW_REG" \
  '[{task_id:"tid-p-2",emitter:"prompt",issue:102,state:"running",offered_at:$now,
     expires_at:$now,pr:null,last_updated:$now}]')"
CHIPS=$(run --json | jq -r '.live_chips') || fail "19: --json failed for running state"
[[ "$CHIPS" == "1" ]] || fail "19: /prompt chip in 'running' state should count, got '$CHIPS'"
ok "a chip in 'running' state (clicked, no PR yet) is counted"

# A /wave chip in pr-backed state is NOT counted (its PR is already in source 1).
export REG_FAKE_LIST="$(jq -cn --arg now "$NOW_REG" \
  '[{task_id:"tid-w-3",emitter:"wave",issue:103,state:"pr-backed",offered_at:$now,
     expires_at:$now,pr:1234,last_updated:$now}]')"
CHIPS=$(run --json | jq -r '.live_chips') || fail "19: --json failed for pr-backed state"
[[ "$CHIPS" == "0" ]] || fail "19: pr-backed chip must not count (PR source covers it), got '$CHIPS'"
ok "a 'pr-backed' chip is excluded from the registry count (open-PR source covers it)"

# An expired registry chip is not counted.
OLD_REG="$(date -u -v-48H +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d '48 hours ago' +%Y-%m-%dT%H:%M:%SZ)"
export REG_FAKE_LIST="$(jq -cn --arg old "$OLD_REG" \
  '[{task_id:"tid-exp-4",emitter:"pm",issue:104,state:"offered",offered_at:$old,
     expires_at:$old,pr:null,last_updated:$old}]')"
CHIPS=$(CLAUDE_CHIP_OFFER_TTL_S=86400 run --json | jq -r '.live_chips') || fail "19: --json failed for expired entry"
[[ "$CHIPS" == "0" ]] || fail "19: an expired registry chip must not count, got '$CHIPS'"
ok "a registry chip older than the TTL is treated as expired and not counted"

# Batch entry: one registry entry covers multiple issues; load_registry_source
# must count it as 1, and every issue it covers must be excluded from the
# legacy log (so a log entry for one of those issues doesn't double-count).
export REG_FAKE_LIST="$(jq -cn --arg now "$NOW_REG" \
  '[{task_id:"tid-batch-6",emitter:"wave",issue:500,issues:[500,501,502],
     state:"offered",offered_at:$now,expires_at:$now,pr:null,last_updated:$now}]')"
write_chip_log "batch-dedup" "[$(chip_entry 501 "$SLUG" open t-batch)]"
set_open_issues "500 501 502"
set_open_prs 0
set_pipelines '[]'
JSON=$(run --json) || fail "19-batch: --json failed for batch registry entry"
CHIPS=$(printf '%s' "$JSON" | jq -r '.live_chips')
[[ "$CHIPS" == "1" ]] || fail "19-batch: batch entry (3 issues) must count as 1 chip, got '$CHIPS'"
ok "a batch registry entry covering 3 issues counts as 1 chip slot"
rm -f "$CLAUDE_ACTIVE_WORK_HANDOFF_DIR/issue-maker-batch-dedup-log.json"
export REG_FAKE_LIST=""

# Reset to empty registry for subsequent tests.
export REG_FAKE_LIST="[]"

# --- 20. Cross-emitter dedup: same issue in registry AND issue-maker log ------
# An issue offered by /pm (registry) and also recorded in an issue-maker log
# (legacy) must count once, not twice. Premise set explicitly.
export REG_FAKE_LIST="$(jq -cn --arg now "$NOW_REG" \
  '[{task_id:"tid-pm-5",emitter:"pm",issue:201,state:"offered",offered_at:$now,
     expires_at:$now,pr:null,last_updated:$now}]')"
write_chip_log "alpha" "[$(chip_entry 201 "$SLUG" open t5)]"
set_open_issues "201"
set_open_prs 0
set_pipelines '[]'
CHIPS=$(run --json 2>/dev/null | jq -r '.live_chips') || fail "20: --json failed with cross-emitter dedup"
[[ "$CHIPS" == "1" ]] || fail "20: same issue in registry and log must count once, not twice; got '$CHIPS'"
ok "same issue in registry and legacy log counts once (cross-emitter dedup)"
rm -f "$CLAUDE_ACTIVE_WORK_HANDOFF_DIR/issue-maker-alpha-log.json"

# --- 21. Registry degraded: missing script contributes 0, not failure --------
# A missing registry script (DEGRADED) falls back to 0 with a warning, because
# the legacy log is still read and the registry is additive.
unset CLAUDE_CHIP_OFFER_REGISTRY_SH
export CLAUDE_CHIP_OFFER_REGISTRY_SH=""   # empty = skip registry read
set_open_prs 0
set_open_issues ""
rm -f "$CLAUDE_ACTIVE_WORK_HANDOFF_DIR"/issue-maker-*-log.json
set_pipelines '[]'
JSON=$(run --json) || fail "21: --json should succeed when registry is skipped"
[[ "$(printf '%s' "$JSON" | jq -r '.live_chips')" == "0" ]] || fail "21: empty registry should yield 0 chips"
ok "an empty CLAUDE_CHIP_OFFER_REGISTRY_SH skips the registry; count succeeds"

# Restore default env (no CLAUDE_CHIP_OFFER_REGISTRY_SH) for subsequent tests.
unset CLAUDE_CHIP_OFFER_REGISTRY_SH

# --- 22. Merged-PR leak fix (AC#1 — #1285) ------------------------------------
# A chip's issue stops counting once it is referenced by a MERGED PR, not only
# while that PR is open. Before #1285, chips_covered_by_prs() only checked open
# PRs; after a PR merged, the exclusion disappeared and the chip re-entered the
# active count even though the work was done.
#
# Scenario: issue 301 is open; a chip log entry exists for it; the PR that
# closed it has already merged. Expected: chip count = 0.
set_cap_config ""
set_open_prs 0
set_merged_prs 1 '[301]'   # one merged PR whose closingIssuesReferences includes 301
set_open_issues "301"       # issue stays open (e.g. re-opened after merge)
rm -f "$CLAUDE_ACTIVE_WORK_HANDOFF_DIR"/issue-maker-*-log.json
write_chip_log "merged-pr-test" "[$(chip_entry 301 "$SLUG" open t-mpl)]"
set_pipelines '[]'
CHIPS22=$(run --json | jq -r '.live_chips') || fail "22: --json failed"
[[ "$CHIPS22" == "0" ]] \
  || fail "22: chip covered by a merged PR must not count (got $CHIPS22, expected 0)"
ok "merged-PR leak fix (AC#1): chip for issue closed by a merged PR is excluded"

# Countercheck: the same setup with NO merged PRs would see the chip count.
# The chip log is still present; only merged PR coverage changes.
set_merged_prs 0
CHIPS22b=$(run --json | jq -r '.live_chips') || fail "22b: --json failed (no merged PR)"
[[ "$CHIPS22b" == "1" ]] \
  || fail "22b: without a merged PR the chip should count; got $CHIPS22b"
ok "merged-PR leak fix (AC#1): countercheck — same chip counts when no merged PR covers it"
# Clean up the chip log only after both checks are done.
rm -f "$CLAUDE_ACTIVE_WORK_HANDOFF_DIR/issue-maker-merged-pr-test-log.json"

# --- 23. Self-referential double-count fix (AC#2 — #1285) ---------------------
# When a thread accepts an offer and a live pipeline entry already exists for
# the same issue, the work must count ONCE (pipeline), not twice (pipeline +
# chip). Before #1285, REG_CHIP_COUNT was not reduced for pipeline issues, so
# both CHIPS and PIPELINES contributed +1 for the same work.
#
# Scenario: registry has a "running" chip for issue 401 (clicked, session
# started, no PR yet); active_agents has an entry for issue 401 with no .pr.
# Expected: live_chips=0, inline_pipelines=1, active=1.
export CLAUDE_CHIP_OFFER_REGISTRY_SH="$FAKE_REG"
NOW_REG23="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
export REG_FAKE_LIST="$(jq -cn --arg now "$NOW_REG23" \
  '[{task_id:"tid-sr-401",emitter:"wave",issue:401,state:"running",offered_at:$now,
     expires_at:$now,pr:null,last_updated:$now}]')"
set_open_prs 0
set_merged_prs 0
set_open_issues "401"
rm -f "$CLAUDE_ACTIVE_WORK_HANDOFF_DIR"/issue-maker-*-log.json
# active_agents entry for issue 401, no pr field → counts as pipeline
set_pipelines "$(jq -cn --arg now "$NOW_REG23" \
  '[{task_id:"tid-sr-401",issue:401,status:"running",launched:$now}]')"
JSON23=$(run --json) || fail "23: --json failed for self-referential double-count test"
CHIPS23=$(printf '%s' "$JSON23" | jq -r '.live_chips')
PIPELINES23=$(printf '%s' "$JSON23" | jq -r '.inline_pipelines')
ACTIVE23=$(printf '%s' "$JSON23" | jq -r '.active')
[[ "$CHIPS23" == "0" ]] \
  || fail "23: accepted chip must not count once pipeline takes it over (chips=$CHIPS23)"
[[ "$PIPELINES23" == "1" ]] \
  || fail "23: pipeline entry for issue 401 must count (pipelines=$PIPELINES23)"
[[ "$ACTIVE23" == "1" ]] \
  || fail "23: total ACTIVE should be 1 not 2 (active=$ACTIVE23)"
ok "self-referential fix (AC#2): accepted chip + running pipeline count once, not twice"
export REG_FAKE_LIST="[]"
unset CLAUDE_CHIP_OFFER_REGISTRY_SH

# --- 24. CLAUDE_ACTIVE_WORK_MERGED_PR_LIMIT=0 disables merged-PR check --------
# When the limit is 0, fetch_merged_prs must return an empty result WITHOUT
# invoking `gh pr list --state merged`. The fake gh's GH_FAKE_FORBID_MERGED=1
# flag causes the merged branch to fail hard, so any code path that calls gh
# with --state merged despite limit=0 turns into an immediate test failure
# rather than a false positive from the fixture returning an empty array.
#
# Scenario: a chip log entry for issue 301 exists; GH_FAKE_FORBID_MERGED=1
# makes any merged-PR gh call a hard failure. With limit=0 the chip must still
# count (no merged PR covers it) — and gh must never be called for merged PRs.
set_cap_config ""
set_open_prs 0
set_open_issues "301"
rm -f "$CLAUDE_ACTIVE_WORK_HANDOFF_DIR"/issue-maker-*-log.json
write_chip_log "limit0-test" "[$(chip_entry 301 "$SLUG" open t-l0)]"
set_pipelines '[]'
CHIPS24=$(GH_FAKE_FORBID_MERGED=1 CLAUDE_ACTIVE_WORK_MERGED_PR_LIMIT=0 run --json \
  | jq -r '.live_chips') \
  || fail "24: --json failed with MERGED_PR_LIMIT=0 (merged-PR gh call may have fired)"
[[ "$CHIPS24" == "1" ]] \
  || fail "24: with limit=0, merged-PR check is disabled; chip should count (got $CHIPS24)"
ok "CLAUDE_ACTIVE_WORK_MERGED_PR_LIMIT=0 disables the merged-PR check without calling gh"
rm -f "$CLAUDE_ACTIVE_WORK_HANDOFF_DIR/issue-maker-limit0-test-log.json"

# --- 25. Per-entry registry overlap: batch entry + unrelated entry -------------
# Regression for the cardinality subtraction bug: a batch registry entry
# A=[401,402] in running state and pipelines for 401+402 must remove only entry A,
# leaving unrelated entry B=[403] as 1 offered slot. The old code subtracted 2
# overlapping issues from entry count 2, yielding 0 — incorrectly removing B.
export CLAUDE_CHIP_OFFER_REGISTRY_SH="$FAKE_REG"
NOW_REG25="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
export REG_FAKE_LIST="$(jq -cn --arg now "$NOW_REG25" \
  '[{task_id:"batch-A25","emitter":"wave","issue":401,"issues":[401,402],
     "state":"running","offered_at":$now,"expires_at":$now,"pr":null,"last_updated":$now},
    {task_id:"single-B25","emitter":"wave","issue":403,
     "state":"offered","offered_at":$now,"expires_at":$now,"pr":null,"last_updated":$now}]')"
set_open_prs 0
set_merged_prs 0
set_open_issues "401 402 403"
rm -f "$CLAUDE_ACTIVE_WORK_HANDOFF_DIR"/issue-maker-*-log.json
# Pipelines for 401 and 402 only — 403 has no pipeline.
set_pipelines "$(jq -cn --arg now "$NOW_REG25" \
  '[{task_id:"pipe-401",issue:401,status:"running",launched:$now},
    {task_id:"pipe-402",issue:402,status:"running",launched:$now}]')"
JSON25=$(run --json) || fail "25: --json failed for batch-entry pipeline overlap"
CHIPS25=$(printf '%s' "$JSON25" | jq -r '.live_chips')
REG25=$(printf '%s' "$JSON25" | jq -r '.registry_baseline')
[[ "$CHIPS25" == "1" ]] \
  || fail "25: entry B=[403] must survive pipeline filter; expected live_chips=1, got $CHIPS25"
[[ "$REG25" == "1" ]] \
  || fail "25: registry_baseline must reflect 1 surviving entry, got $REG25"
ok "per-entry registry pipeline filter: batch A=[401,402] removed; unrelated B=[403] survives"
export REG_FAKE_LIST="[]"
unset CLAUDE_CHIP_OFFER_REGISTRY_SH

# --- 26. merged-PR ordering: older-created, recently-merged PR is detected -----
# gh pr list returns by createdAt descending. Without mergedAt-based client-side
# sorting an older PR (low number, created long ago) that merged recently can be
# missed when a newer-created PR fills the limit slot first.
set_cap_config ""
set_open_prs 0
set_open_issues "301"
rm -f "$CLAUDE_ACTIVE_WORK_HANDOFF_DIR"/issue-maker-*-log.json
write_chip_log "ordering-test" "[$(chip_entry 301 "$SLUG" open t-ord)]"
# PR 2001 was created long ago but merged recently; PR 2002 was created after
# but merged earlier. With limit=1 and createdAt order, the naive fetch would
# return only PR 2002 (newer creation), missing PR 2001 and failing to exclude
# the chip. The fix fetches more candidates, sorts by mergedAt, and applies limit.
GH_FAKE_MERGED_PRS="$(jq -cn '[
  {number:2002, mergedAt:"2026-08-22T10:00:00Z",
   closingIssuesReferences:[]},
  {number:2001, mergedAt:"2026-08-23T20:30:00Z",
   closingIssuesReferences:[{number:301}]}
]')"
export GH_FAKE_MERGED_PRS
set_pipelines '[]'
CHIPS26=$(CLAUDE_ACTIVE_WORK_MERGED_PR_LIMIT=1 run --json | jq -r '.live_chips') \
  || fail "26: --json failed for ordering test"
[[ "$CHIPS26" == "0" ]] \
  || fail "26: PR 2001 (most recently merged) closes issue 301; chip must be excluded (got $CHIPS26)"
ok "merged-PR ordering: recently-merged older-created PR detected via mergedAt sort"
rm -f "$CLAUDE_ACTIVE_WORK_HANDOFF_DIR/issue-maker-ordering-test-log.json"
unset GH_FAKE_MERGED_PRS

# --- 27. partial-batch offered_issue_nums excludes pipeline-covered issues -----
# A batch entry [401,402] partially covered by pipeline [401] survives the per-
# entry filter (REG_CHIP_COUNT=1) because 402 is not pipeline-owned. However,
# offered_issue_nums must list only 402, not 401, since 401 is already counted
# through inline_pipelines, not the offered-work term.
export CLAUDE_CHIP_OFFER_REGISTRY_SH="$FAKE_REG"
NOW_REG27="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
export REG_FAKE_LIST="$(jq -cn --arg now "$NOW_REG27" \
  '[{task_id:"partial-A27","emitter":"wave","issue":401,"issues":[401,402],
     "state":"running","offered_at":$now,"expires_at":$now,"pr":null,"last_updated":$now}]')"
set_open_prs 0
set_merged_prs 0
set_open_issues "401 402"
rm -f "$CLAUDE_ACTIVE_WORK_HANDOFF_DIR"/issue-maker-*-log.json
set_pipelines "$(jq -cn --arg now "$NOW_REG27" \
  '[{task_id:"pipe-401-27",issue:401,status:"running",launched:$now}]')"
JSON27=$(run --json) || fail "27: --json failed for partial-batch offered_issue_nums test"
REG27=$(printf '%s' "$JSON27" | jq -r '.registry_baseline')
OFF27=$(printf '%s' "$JSON27" | jq -r '[.offered_issue_nums[] | tostring] | sort | join(",")')
[[ "$REG27" == "1" ]] \
  || fail "27: batch entry [401,402] partially covered by pipeline — registry_baseline must be 1 (got $REG27)"
[[ "$OFF27" == "402" ]] \
  || fail "27: offered_issue_nums must be [402] only (pipeline covers 401); got $OFF27"
ok "partial-batch offered_issue_nums: pipeline-covered issue 401 excluded; 402 retained"
export REG_FAKE_LIST="[]"
unset CLAUDE_CHIP_OFFER_REGISTRY_SH

# --- 28-35. old gh lacks closingIssuesReferences on `pr list` (#1335) ------
# The old client rejects the field client-side. That used to reach die_read and
# exit 5, and /pm Step 0 reads a non-zero exit as FREE=0 — so a stale gh froze
# chip offers repo-wide with no hint the remedy was a client upgrade. The gap
# must now degrade to closing keywords parsed from PR bodies, loudly, without
# ever under-counting.

# Body-carrying fixtures, mirroring set_open_prs / set_merged_prs but writing
# the closing reference as prose the way a real PR body carries it.
set_open_prs_body() {  # $1 = count, $2 = body text for the FIRST PR
  GH_FAKE_PRS_BODY="$(jq -cn --argjson n "$1" --arg b "${2:-}" \
    '[range($n) | {number: (.+1000), body: (if . == 0 then $b else "" end)}]')"
  export GH_FAKE_PRS_BODY
}
set_merged_prs_body() {  # $1 = count, $2 = body text for the FIRST merged PR
  GH_FAKE_MERGED_PRS_BODY="$(jq -cn --argjson n "$1" --arg b "${2:-}" \
    '[range($n) | {number: (.+2000), mergedAt: "2026-08-23T20:00:00Z",
                   body: (if . == 0 then $b else "" end)}]')"
  export GH_FAKE_MERGED_PRS_BODY
}

reset_old_gh_case() {
  set_cap_config ""
  set_open_prs 0
  set_merged_prs 0
  set_open_prs_body 0
  set_merged_prs_body 0
  set_open_issues ""
  set_pipelines '[]'
  rm -f "$CLAUDE_ACTIVE_WORK_HANDOFF_DIR"/issue-maker-*-log.json
}

# --- 28. an old gh no longer exits 5 -----------------------------------------
# The regression itself. Before the fix this run died at fetch_open_prs.
reset_old_gh_case
set_open_prs_body 2
set_merged_prs_body 0
OUT28=""; RC28=0
OUT28=$(GH_FAKE_NO_CLOSING_REFS=1 run 2>/dev/null) || RC28=$?
[[ "$RC28" == "0" ]] \
  || fail "28: a gh lacking closingIssuesReferences must not fail the census (exit $RC28)"
[[ "$OUT28" == "CAP=6 ACTIVE=2 FREE=4" ]] \
  || fail "28: degraded census must still count the 2 open PRs; got '$OUT28'"
ok "old gh: census succeeds instead of exiting 5, and open PRs still count"

# --- 29. the degradation is LOUD, and says what to do about it ----------------
ERR29=$(GH_FAKE_NO_CLOSING_REFS=1 GH_FAKE_VERSION=2.48.0 run 2>&1 >/dev/null)
case "$ERR29" in
  *"DEGRADED"*) ;;
  *) fail "29: degraded run must print a DEGRADED line; got '$ERR29'" ;;
esac
case "$ERR29" in
  *"2.72.0"*) ;;
  *) fail "29: the DEGRADED line must name the minimum gh version; got '$ERR29'" ;;
esac
# The DETECTED version too, so the operator can tell which client is stale —
# and so the version parse is proven to work rather than silently reporting
# "unknown" on every machine.
case "$ERR29" in
  *"gh 2.48.0"*) ;;
  *) fail "29: the DEGRADED line must name the detected gh version; got '$ERR29'" ;;
esac
case "$ERR29" in
  *"brew upgrade gh"*) ;;
  *) fail "29: the DEGRADED line must name the remedy; got '$ERR29'" ;;
esac
# Both call sites degrade, but the operator should be told once, not twice.
N29=$(printf '%s\n' "$ERR29" | grep -c "DEGRADED")
[[ "$N29" == "1" ]] \
  || fail "29: the DEGRADED line must be printed exactly once per run, got $N29"
ok "old gh: one DEGRADED line naming the field, the minimum version and the remedy"

# --- 30. the fallback actually subtracts, matching the API path ---------------
# A chip for issue 501 whose work is already an open PR. On the API path the
# closingIssuesReferences entry suppresses it; on the degraded path the same
# suppression has to come out of the body text, or the count would drift.
reset_old_gh_case
set_open_issues "501"
write_chip_log "old-gh-30" "[$(chip_entry 501 "$SLUG" open t-30)]"
set_open_prs_body 1 "Adds the thing.

Closes #501"
JSON30=$(GH_FAKE_NO_CLOSING_REFS=1 run --json 2>/dev/null) || fail "30: degraded --json failed"
CH30=$(printf '%s' "$JSON30" | jq -r '.live_chips')
[[ "$CH30" == "0" ]] \
  || fail "30: a body saying Closes #501 must suppress the chip for 501 (live_chips=$CH30)"
# Negative control: the same fixtures with NO closing keyword must keep it.
set_open_prs_body 1 "Adds the thing. See #501 for background."
JSON30B=$(GH_FAKE_NO_CLOSING_REFS=1 run --json 2>/dev/null) || fail "30: control --json failed"
CH30B=$(printf '%s' "$JSON30B" | jq -r '.live_chips')
[[ "$CH30B" == "1" ]] \
  || fail "30: a bare mention (no keyword) must NOT suppress the chip (live_chips=$CH30B)"
ok "old gh: body keywords subtract PR-covered chips; a bare mention does not"

# --- 31. cross-repo references never subtract this repo's issue --------------
# The one way the fallback could UNDER-count: adopting another repo`s
# `owner/repo#N`. Under-counting widens offers, which is the failure the whole
# script exists to prevent, so this is the load-bearing case.
reset_old_gh_case
set_open_issues "502"
write_chip_log "old-gh-31" "[$(chip_entry 502 "$SLUG" open t-31)]"
set_open_prs_body 1 "Closes otherowner/otherrepo#502"
JSON31=$(GH_FAKE_NO_CLOSING_REFS=1 run --json 2>/dev/null) || fail "31: degraded --json failed"
CH31=$(printf '%s' "$JSON31" | jq -r '.live_chips')
[[ "$CH31" == "1" ]] \
  || fail "31: another repo's #502 must not suppress this repo's chip (live_chips=$CH31)"
# The same-repo shorthand and URL forms, however, must both be honoured.
set_open_prs_body 1 "Closes $SLUG#502"
CH31B=$(GH_FAKE_NO_CLOSING_REFS=1 run --json 2>/dev/null | jq -r '.live_chips') \
  || fail "31: shorthand-form --json failed"
[[ "$CH31B" == "0" ]] \
  || fail "31: same-repo shorthand $SLUG#502 must suppress the chip (live_chips=$CH31B)"
set_open_prs_body 1 "Resolved https://github.com/$SLUG/issues/502"
CH31C=$(GH_FAKE_NO_CLOSING_REFS=1 run --json 2>/dev/null | jq -r '.live_chips') \
  || fail "31: URL-form --json failed"
[[ "$CH31C" == "0" ]] \
  || fail "31: same-repo issue URL must suppress the chip (live_chips=$CH31C)"
ok "old gh: cross-repo refs ignored; same-repo shorthand and URL forms honoured"

# --- 32. every keyword family, case-insensitively -----------------------------
reset_old_gh_case
set_open_issues "601 602 603 604 605 606 607 608 609"
write_chip_log "old-gh-32" "[$(chip_entry 601 "$SLUG" open t-32a),$(chip_entry 609 "$SLUG" open t-32b)]"
set_open_prs_body 1 "close #601 CLOSES #602 Closed #603 fix #604 FIXES #605
fixed #606 resolve #607 Resolves #608 RESOLVED #609"
CH32=$(GH_FAKE_NO_CLOSING_REFS=1 run --json 2>/dev/null | jq -r '.live_chips') \
  || fail "32: keyword-family --json failed"
[[ "$CH32" == "0" ]] \
  || fail "32: all nine keyword forms must be recognised (live_chips=$CH32)"
# And near-misses must not be. `unfixes`/`closely` fail the word boundary, and
# `Closes#610` fails the required separator — a form GitHub does not document
# and that no PR in the 60-PR sample uses, so matching it would subtract a chip
# no PR covers.
reset_old_gh_case
set_open_issues "610"
write_chip_log "old-gh-32c" "[$(chip_entry 610 "$SLUG" open t-32c)]"
set_open_prs_body 1 "unfixes #610 and closely #610 and Closes#610 and fixed#610"
CH32B=$(GH_FAKE_NO_CLOSING_REFS=1 run --json 2>/dev/null | jq -r '.live_chips') \
  || fail "32: near-miss --json failed"
[[ "$CH32B" == "1" ]] \
  || fail "32: unfixes/closely/separator-less forms are not references (live_chips=$CH32B)"
# The separator itself may be a colon, a tab, or spaces around a colon.
reset_old_gh_case
set_open_issues "611"
write_chip_log "old-gh-32d" "[$(chip_entry 611 "$SLUG" open t-32d)]"
printf -v BODY32 'Closes:\t#611'
set_open_prs_body 1 "$BODY32"
CH32C=$(GH_FAKE_NO_CLOSING_REFS=1 run --json 2>/dev/null | jq -r '.live_chips') \
  || fail "32: separator-variant --json failed"
[[ "$CH32C" == "0" ]] \
  || fail "32: a colon-plus-tab separator must still match (live_chips=$CH32C)"
# A NEWLINE is not a separator. GitHub does not link across one, so matching it
# would subtract a chip no PR covers — the same under-counting direction as the
# separator-less form, from a shape that occurs whenever a keyword happens to
# end a line above an unrelated issue number.
reset_old_gh_case
set_open_issues "612"
write_chip_log "old-gh-32e" "[$(chip_entry 612 "$SLUG" open t-32e)]"
set_open_prs_body 1 'The word Closes
#612 begins the next line and is not a reference.'
CH32D=$(GH_FAKE_NO_CLOSING_REFS=1 run --json 2>/dev/null | jq -r '.live_chips') \
  || fail "32: newline-separator --json failed"
[[ "$CH32D" == "1" ]] \
  || fail "32: a keyword separated from #612 by a newline must not subtract (live_chips=$CH32D)"
ok "old gh: all nine keyword forms match; boundary, separator and newline misses do not"

# --- 33. --json names the source, on both paths -------------------------------
reset_old_gh_case
SRC33=$(GH_FAKE_NO_CLOSING_REFS=1 run --json 2>/dev/null | jq -r '.closing_refs_source') \
  || fail "33: degraded --json failed"
[[ "$SRC33" == "body-keywords" ]] \
  || fail "33: degraded --json must report closing_refs_source=body-keywords, got '$SRC33'"
SRC33B=$(run --json | jq -r '.closing_refs_source') || fail "33: normal --json failed"
[[ "$SRC33B" == "api" ]] \
  || fail "33: a modern gh must report closing_refs_source=api, got '$SRC33B'"
ok "--json reports closing_refs_source: body-keywords when degraded, api otherwise"

# --- 34. the merged-PR fetch degrades too ------------------------------------
# fetch_merged_prs requests mergedAt as well, so its degraded call has to keep
# that field or the client-side ordering silently loses its key.
reset_old_gh_case
set_open_issues "701"
write_chip_log "old-gh-34" "[$(chip_entry 701 "$SLUG" open t-34)]"
set_merged_prs_body 1 "Fixes #701"
CH34=$(GH_FAKE_NO_CLOSING_REFS=1 run --json 2>/dev/null | jq -r '.live_chips') \
  || fail "34: degraded merged-PR --json failed"
[[ "$CH34" == "0" ]] \
  || fail "34: a MERGED PR body closing 701 must suppress the chip (live_chips=$CH34)"
# The mergedAt ORDERING must survive the degraded round-trip too — test 26's
# scenario on the fallback path. PR 2001 was created first but merged last, so
# with limit=1 only the mergedAt sort surfaces it. If synthesis dropped or
# mangled mergedAt the sort would pick 2002 and the chip would not be excluded,
# which the fake cannot catch on its own: it asserts the field was REQUESTED,
# not that it survived into the sorted result.
reset_old_gh_case
set_open_issues "702"
write_chip_log "old-gh-34b" "[$(chip_entry 702 "$SLUG" open t-34b)]"
# Fixture ORDER is the whole discrimination here. `sort_by` is stable, so with
# the closing PR listed second a dropped mergedAt would sort to the same answer
# and this test would pass while proving nothing. Listed FIRST, a null mergedAt
# leaves input order, and reverse then picks 2002 — the wrong PR — so the
# assertion below actually fails when the field does not survive synthesis.
GH_FAKE_MERGED_PRS_BODY="$(jq -cn '[
  {number:2001, mergedAt:"2026-08-23T20:30:00Z", body:"Closes #702"},
  {number:2002, mergedAt:"2026-08-22T10:00:00Z", body:"Unrelated work."}
]')"
export GH_FAKE_MERGED_PRS_BODY
CH34B=$(CLAUDE_ACTIVE_WORK_MERGED_PR_LIMIT=1 GH_FAKE_NO_CLOSING_REFS=1 \
        run --json 2>/dev/null | jq -r '.live_chips') \
  || fail "34: degraded merged-PR ordering --json failed"
[[ "$CH34B" == "0" ]] \
  || fail "34: mergedAt ordering must survive synthesis; PR 2001 closes 702 (live_chips=$CH34B)"
ok "old gh: the merged-PR fetch degrades too, and mergedAt ordering survives it"

# --- 35. every other gh failure still exits 5 (fail-closed preserved) ---------
# The degradation must be narrow. A rate limit, an auth error, or a DIFFERENT
# missing field are read failures, and a fabricated zero there would uncap the
# gate outright.
reset_old_gh_case
RC35=0
GH_FAKE_NO_CLOSING_REFS=1 GH_FAKE_PR_FAIL=1 run >/dev/null 2>&1 || RC35=$?
[[ "$RC35" == "5" ]] \
  || fail "35: a real gh failure must still exit 5 even in old-gh mode (got $RC35)"
# An unknown-field error naming some OTHER field is not this capability gap.
# The catalogue gh prints alongside it LISTS closingIssuesReferences, so a
# detector that searched the whole message would read its own error text as the
# gap and degrade a healthy client. Driven through the real script rather than
# a re-implementation of the matcher: a test that restates the logic it is
# checking passes whatever the shipped code does.
RC35B=0
GH_FAKE_UNKNOWN_OTHER_FIELD=1 run >/dev/null 2>&1 || RC35B=$?
[[ "$RC35B" == "5" ]] \
  || fail "35: an unknown-field error for a DIFFERENT field must still exit 5 (got $RC35B)"
# And it must NOT have been mistaken for the capability gap on the way there.
ERR35B=$(GH_FAKE_UNKNOWN_OTHER_FIELD=1 run 2>&1 >/dev/null)
case "$ERR35B" in
  *"DEGRADED"*) fail "35: another field's unknown-field error must not trigger the fallback" ;;
esac
ok "old gh: real failures still exit 5; another field's error is not the gap"

# --- 36. keywords quoted as code or comments are not references ---------------
# Measured, not hypothetical: over 60 real merged PRs on this repo the keyword
# parse matched the API field on 59 and disagreed on exactly one — a PR ABOUT
# closing-keyword parsing, whose body quoted nine keyword examples as code
# spans. GitHub links none of them, and each phantom reference would have
# SUBTRACTED a chip. Over-subtraction is the under-counting direction that
# widens offers, so this is the case that keeps the fallback error
# one-directional. Stripping code spans, fences and HTML comments took the
# same 60-PR comparison to 60/60.
reset_old_gh_case
set_open_issues "801"
write_chip_log "old-gh-36" "[$(chip_entry 801 "$SLUG" open t-36)]"
BODY36='Discussion of the parser.

Inline: the old code treated `Closes #801` as a trailer.

```
Closes #801
```

<!-- template hint: Closes #801 -->

Nothing above should count.'
set_open_prs_body 1 "$BODY36"
CH36=$(GH_FAKE_NO_CLOSING_REFS=1 run --json 2>/dev/null | jq -r '.live_chips') \
  || fail "36: code-span --json failed"
[[ "$CH36" == "1" ]] \
  || fail "36: keywords inside code spans, fences and HTML comments must not subtract (live_chips=$CH36)"
# Control: the very same body plus a real trailer DOES subtract, so the strip
# cannot be passing by simply matching nothing.
set_open_prs_body 1 "$BODY36

Closes #801"
CH36B=$(GH_FAKE_NO_CLOSING_REFS=1 run --json 2>/dev/null | jq -r '.live_chips') \
  || fail "36: trailer-control --json failed"
[[ "$CH36B" == "0" ]] \
  || fail "36: a real trailer alongside quoted examples must still subtract (live_chips=$CH36B)"
# An UNTERMINATED comment runs to the end of the body on GitHub and links
# nothing inside it. Matching only the terminated form would leave the trailing
# keyword visible and subtract a chip that is not covered — the under-counting
# direction, from the one shape a PR template slip actually produces.
reset_old_gh_case
set_open_issues "802"
write_chip_log "old-gh-36c" "[$(chip_entry 802 "$SLUG" open t-36c)]"
set_open_prs_body 1 'Body text.

<!-- template hint, never closed: Closes #802'
CH36C=$(GH_FAKE_NO_CLOSING_REFS=1 run --json 2>/dev/null | jq -r '.live_chips') \
  || fail "36: unterminated-comment --json failed"
[[ "$CH36C" == "1" ]] \
  || fail "36: a keyword inside an unterminated HTML comment must not subtract (live_chips=$CH36C)"
# Control: a trailer BEFORE the unterminated comment is still live text.
set_open_prs_body 1 'Closes #802

<!-- template hint, never closed: Closes #999'
CH36D=$(GH_FAKE_NO_CLOSING_REFS=1 run --json 2>/dev/null | jq -r '.live_chips') \
  || fail "36: pre-comment trailer --json failed"
[[ "$CH36D" == "0" ]] \
  || fail "36: a trailer ABOVE an unterminated comment must still subtract (live_chips=$CH36D)"
ok "old gh: quoted keywords do not subtract; real trailers in the same body do"

# --- 37. fence and span DELIMITER LENGTH is load-bearing ----------------------
# Three ways a naive strip leaks a quoted reference back into the scan, each
# measured against the previous implementation of this code:
#   a. a longer fence quoting a shorter one — toggling on any ``` ends the
#      block at the INNER delimiter and exposes the rest (leaked 901);
#   b. a double-backtick span — matching only single backticks eats the two
#      delimiters as an empty span and leaves the contents bare (leaked 902);
#   c. the opposite failure: letting a span run across newlines, where a stray
#      backtick pairs with one lines later and swallows the real trailer in
#      between (ate a genuine Closes on a real PR, 60-PR parity 60/60 -> 59/60).
# a and b under-count, which widens offers; c over-counts. Both directions are
# pinned here because the fix for one is what broke the other.
reset_old_gh_case
set_open_issues "901 902 903"
write_chip_log "old-gh-37" \
  "[$(chip_entry 901 "$SLUG" open t-37a),$(chip_entry 902 "$SLUG" open t-37b),$(chip_entry 903 "$SLUG" open t-37c)]"
BODY37='Longer fence quoting a shorter one:

````
```
Closes #901
```
````

A double-backtick span: ``Closes #902`` and a tilde fence:

~~~
Closes #903
~~~

None of the three may count.'
set_open_prs_body 1 "$BODY37"
CH37=$(GH_FAKE_NO_CLOSING_REFS=1 run --json 2>/dev/null | jq -r '.live_chips') \
  || fail "37: delimiter-length --json failed"
[[ "$CH37" == "3" ]] \
  || fail "37: nested fences and double-backtick spans must not subtract; all 3 chips must survive (live_chips=$CH37)"
# c. A stray backtick well before a real trailer must not swallow it. The
# opening backtick here is unpaired ON ITS LINE, exactly the shape that made a
# newline-crossing span eat a genuine reference.
reset_old_gh_case
set_open_issues "904"
write_chip_log "old-gh-37c" "[$(chip_entry 904 "$SLUG" open t-37d)]"
BODY37C='A line with a stray `backtick and no closer on this line.

Some more prose, then `another` paired span.

Closes #904'
set_open_prs_body 1 "$BODY37C"
CH37C=$(GH_FAKE_NO_CLOSING_REFS=1 run --json 2>/dev/null | jq -r '.live_chips') \
  || fail "37: cross-line span --json failed"
[[ "$CH37C" == "0" ]] \
  || fail "37: a stray backtick must not swallow the real trailer below it (live_chips=$CH37C)"
ok "old gh: fence/span delimiter length respected, and spans never cross a newline"

reset_old_gh_case

echo "OK: active-work-cap.sh tests passed"
