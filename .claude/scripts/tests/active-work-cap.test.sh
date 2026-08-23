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

# Isolate from caller-set overrides — assertions that rely on a built-in
# default must not silently inherit a different number from the environment.
# This must list EVERY tunable the script reads: the cap (default-cap cases)
# and the agent TTL (the stale-agent cases stamp an entry four hours old and
# expect the 7200s default to expire it, which a caller-set TTL would flip in
# either direction). Keep in step with the script's TUNING block.
unset CLAUDE_ACTIVE_WORK_CAP
unset CLAUDE_ACTIVE_WORK_AGENT_TTL_S

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
            CLAUDE_ACTIVE_WORK_HANDOFF_DIR CLAUDE_CHIP_OFFER_REGISTRY_SH; do
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

echo "OK: active-work-cap.sh tests passed"
