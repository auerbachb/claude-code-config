#!/usr/bin/env bash
# Tests for the reactive subagent-thread usage-limit park — issue #1618.
#
# WHAT IS UNDER TEST
#   The REAL fenced bash in `.claude/reference/subagent-thread-limit-park.md`
#   and `.claude/skills/go-on/SKILL.md`, pulled out at run time by
#   `lib/skill-bash.sh` through the `<!-- test-anchor: … -->` markers and run
#   against a real `session-state.sh` driven by a throwaway $HOME. Nothing here
#   is a transcription: edit the document and this suite runs the edit. Same
#   principle as `pm-day-horizon.test.sh` and `pmm-wake-step-4a.test.sh`.
#
#     subagent-limit-classify        limit-vs-crash detection + horizon class
#     subagent-limit-park-claim      the compare-and-set park claim / adoption
#     subagent-limit-pipeline-record the per-PR phase record /go-on resumes from
#     subagent-limit-wake-arm        thrash guard, weekly branch, wake deadline
#     subagent-limit-wake-publish    the wake identity pair (ok/superseded)
#     subagent-limit-park-recovery   session-start / post-compaction re-arm
#     go-on-limit-generation-gate    stale-wake rejection
#     go-on-limit-park-probe         probe F: which pipelines resume, at which phase
#
# WHY (issue #1618)
#   On 2026-09-03 a Phase B loop on PR #1616 died with "Session limit reached".
#   The parent had only the crash path — report and ask — so the siblings kept
#   running into the same exhausted window and nothing woke when it reopened.
#   Three properties have to hold and none is visible from prose review: a
#   TEXT-only "limit" must never park (that is context exhaustion's shape too);
#   a park that day mode or a sibling thread already opened must be ADOPTED, not
#   duplicated; and an unreadable park record must fail closed rather than read
#   as "not parked".
#
# NON-VACUITY
#   Every assertion can fail. The park assertions read the state file back
#   rather than trusting what a block printed — a claim block that printed "won"
#   while writing nothing would pass a printed-output-only test — and each
#   detection case carries its negative control (a crash shape, a stale
#   breadcrumb, a prose-only banner).
#
# Requires: bash 3.2+ (macOS system bash), jq. Offline: no gh, no git, no network.
set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TEST_DIR/../../.." && pwd)"
DOC="$REPO_ROOT/.claude/reference/subagent-thread-limit-park.md"
GO_ON="$REPO_ROOT/.claude/skills/go-on/SKILL.md"
SUBAGENT="$REPO_ROOT/.claude/skills/subagent/SKILL.md"
PAUSE_RESUME="$REPO_ROOT/.claude/skills/pause-resume/SKILL.md"
SCHEMA="$REPO_ROOT/.claude/reference/session-state-schema.json"
RULES="$REPO_ROOT/.claude/rules"
SESSION_STATE_SH="$REPO_ROOT/.claude/scripts/session-state.sh"

# shellcheck source=lib/skill-bash.sh
source "$TEST_DIR/lib/skill-bash.sh"

TMP_HOME="$(mktemp -d)"
STUB_DIR="$(mktemp -d)"
cleanup() { rm -rf "$TMP_HOME" "$STUB_DIR"; }
trap cleanup EXIT
export HOME="$TMP_HOME"
mkdir -p "$HOME/.claude"
STATE_FILE="$HOME/.claude/session-state.json"
BREADCRUMB="$HOME/.claude/usage-limit-last.json"
REPO_KEY="auerbachb/claude-code-config"
export SESSION_STATE_SH REPO_KEY

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
check_true() {
  local desc="$1" cond="$2"
  if [[ "$cond" == true ]]; then
    PASS=$((PASS + 1)); echo "ok   — $desc"
  else
    FAIL=$((FAIL + 1)); echo "FAIL — $desc"
  fi
}
require_text() {
  local desc="$1" file="$2" pattern="$3"
  if grep -Eq -- "$pattern" "$file"; then
    PASS=$((PASS + 1)); echo "ok   — $desc"
  else
    FAIL=$((FAIL + 1)); echo "FAIL — $desc (no match for /$pattern/ in $(basename "$file"))"
  fi
}
refute_text() {
  local desc="$1" file="$2" pattern="$3"
  if grep -Eq -- "$pattern" "$file"; then
    FAIL=$((FAIL + 1)); echo "FAIL — $desc (unexpected match for /$pattern/ in $(basename "$file"))"
  else
    PASS=$((PASS + 1)); echo "ok   — $desc"
  fi
}
field() { printf '%s\n' "$1" | sed -n "s/^$2=//p" | head -1; }

# Extract every anchored block once. A failed extraction is FATAL, never
# skipped: a suite that silently runs zero lines of the document passes green
# forever, which is the whole failure class `lib/skill-bash.sh` exists to end.
BLOCK_CLASSIFY="$(extract_skill_bash "$DOC" subagent-limit-classify)"        || exit 1
BLOCK_CLAIM="$(extract_skill_bash    "$DOC" subagent-limit-park-claim)"      || exit 1
BLOCK_PIPELINE="$(extract_skill_bash "$DOC" subagent-limit-pipeline-record)" || exit 1
BLOCK_WAKE="$(extract_skill_bash     "$DOC" subagent-limit-wake-arm)"        || exit 1
BLOCK_PUBLISH="$(extract_skill_bash  "$DOC" subagent-limit-wake-publish)"    || exit 1
BLOCK_RECOVERY="$(extract_skill_bash "$DOC" subagent-limit-park-recovery)"   || exit 1
BLOCK_GEN="$(extract_skill_bash    "$GO_ON" go-on-limit-generation-gate)"    || exit 1
BLOCK_PROBE="$(extract_skill_bash  "$GO_ON" go-on-limit-park-probe)"         || exit 1

iso_to_epoch() {
  date -u -d "$1" +%s 2>/dev/null || date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "$1" '+%s'
}
epoch_to_iso() {
  date -u -d "@$1" +%FT%TZ 2>/dev/null || date -u -r "$1" +%FT%TZ
}
day_get() { jq -r --arg k "$REPO_KEY" ".repos[\$k].day.$1" "$STATE_FILE"; }
pr_get()  { jq -r --arg k "$REPO_KEY" --arg n "$1" ".repos[\$k].prs[\$n].$2" "$STATE_FILE"; }

# A day block shaped like 2D.2's init write, with no park recorded.
seed_unparked() {
  jq -n --arg k "$REPO_KEY" '{repos: {($k): {day: {
      active: true, parked_until: null, limit_kind: null, limit_cause: null,
      limit_probe_fires_remaining: null, limit_resume_task_id: null,
      limit_resume_generation: null, consecutive_limit_hits: 0}}}}' > "$STATE_FILE"
}
# A board day mode (or a sibling thread) already parked.
# <task_id> is a RAW JSON value ('"task-x"' or 'null'), matching how the publish
# block interpolates LIMIT_MONITOR_TASK_ID into its jq path expression.
seed_existing_park() {  # seed_existing_park <cause> <parked_until> <task_id-json>
  jq -n --arg k "$REPO_KEY" --arg cause "$1" --arg until "$2" --argjson task "$3" \
    '{repos: {($k): {day: {
      active: true, parked_until: $until, limit_kind: "rolling_window",
      limit_cause: $cause, limit_probe_fires_remaining: null,
      limit_resume_task_id: $task, limit_resume_generation: "limit-existing",
      consecutive_limit_hits: 1}}}}' > "$STATE_FILE"
}

# ---------------------------------------------------------------------------
echo "== Detection: a structured signal parks, a crash does not (AC 2, AC 3) =="
# ---------------------------------------------------------------------------

run_classify() {  # run_classify <failure-json> [breadcrumb-path]
  FAILURE_JSON="$1" BREADCRUMB="${2:-$STUB_DIR/no-such-breadcrumb.json}" \
    bash -c "$BLOCK_CLASSIFY" 2>/dev/null
}

# The three structured shapes named in §1, each on its own field.
OUT=$(run_classify '{"error":"rate_limit"}')
check_eq "error==rate_limit is a limit"        "true"           "$(field "$OUT" LIMIT_SIGNAL)"
check_eq "  and names its source"              "signal:rate_limit" "$(field "$OUT" LIMIT_SOURCE)"
OUT=$(run_classify '{"error":{"type":"rate_limit_error","message":"x"}}')
check_eq "error.type==rate_limit_error"        "true" "$(field "$OUT" LIMIT_SIGNAL)"
OUT=$(run_classify '{"error_type":"rate_limit_error"}')
check_eq "error_type==rate_limit_error"        "true" "$(field "$OUT" LIMIT_SIGNAL)"
OUT=$(run_classify '{"failure_code":"session_limit_reached"}')
check_eq "harness session_limit_reached code"  "true" "$(field "$OUT" LIMIT_SIGNAL)"

# The crash controls. Each of these WOULD park under a text match, which is the
# misclassification the structured rule exists to prevent.
OUT=$(run_classify '{"error":"context_length_exceeded","message":"out of tokens; limit reached"}')
check_eq "context exhaustion is NOT a limit"   "false" "$(field "$OUT" LIMIT_SIGNAL)"
OUT=$(run_classify '{"message":"Background agent failed · Session limit reached"}')
check_eq "prose banner alone is NOT a limit"   "false" "$(field "$OUT" LIMIT_SIGNAL)"
OUT=$(run_classify '{"error":"api_error","status":500}')
check_eq "a 500 is NOT a limit"                "false" "$(field "$OUT" LIMIT_SIGNAL)"
OUT=$(run_classify '')
check_eq "no payload at all is NOT a limit"    "false" "$(field "$OUT" LIMIT_SIGNAL)"
OUT=$(run_classify 'not json at all')
check_eq "unparseable payload is NOT a limit"  "false" "$(field "$OUT" LIMIT_SIGNAL)"
# A bare string payload would make an unguarded `.error.type` chain a jq ERROR,
# taking the whole program non-zero and discarding the string shape's own signal.
OUT=$(run_classify '"rate_limit"')
check_eq "a bare JSON string is NOT a limit"   "false" "$(field "$OUT" LIMIT_SIGNAL)"

# ---------------------------------------------------------------------------
echo "== Detection: the breadcrumb corroborates, and never supplies a reset =="
# ---------------------------------------------------------------------------

NOW=$(date -u +%s)
make_breadcrumb() {  # make_breadcrumb <reason> <age-seconds>
  jq -n --arg r "$1" --arg at "$(epoch_to_iso $(( NOW - $2 )))" \
    '{recorded_at: $at, reason: $r,
      error_details: "Claude usage limit reached. resets 3:50pm"}' > "$BREADCRUMB"
}
make_breadcrumb rate_limit 60
OUT=$(run_classify '' "$BREADCRUMB")
check_eq "fresh rate_limit breadcrumb corroborates" "true"       "$(field "$OUT" LIMIT_SIGNAL)"
check_eq "  source is the breadcrumb"               "breadcrumb" "$(field "$OUT" LIMIT_SOURCE)"
# The 3:50pm in error_details is FREE TEXT. Parsing it would be the text-only
# match AC 3 forbids, so the park must take the 60-minute default instead.
PU=$(field "$OUT" PARKED_UNTIL); PU_EPOCH=$(iso_to_epoch "$PU")
DELTA=$(( PU_EPOCH - NOW ))
check_true "breadcrumb never supplies a reset time (60m default)" \
  "$( [ "$DELTA" -ge 3500 ] && [ "$DELTA" -le 3700 ] && echo true || echo false )"
check_eq "  and classifies as rolling_window" "rolling_window" "$(field "$OUT" LIMIT_KIND)"

make_breadcrumb rate_limit 7200
OUT=$(run_classify '' "$BREADCRUMB")
check_eq "a 2-hour-old breadcrumb is stale, not a limit" "false" "$(field "$OUT" LIMIT_SIGNAL)"
make_breadcrumb api_error 60
OUT=$(run_classify '' "$BREADCRUMB")
check_eq "a non-rate_limit breadcrumb is not a limit"    "false" "$(field "$OUT" LIMIT_SIGNAL)"
rm -f "$BREADCRUMB"

# ---------------------------------------------------------------------------
echo "== Detection: horizon classification (rolling window vs weekly) =="
# ---------------------------------------------------------------------------

RESET_IN=$(( NOW + 1800 ))
OUT=$(run_classify "$(jq -nc --argjson e "$RESET_IN" '{error:"rate_limit", reset_epoch:$e}')")
check_eq "30m reset -> rolling_window" "rolling_window" "$(field "$OUT" LIMIT_KIND)"
# The classified reset must reach the caller: §4 computes the wake deadline from
# it, so a value the block declares but never emits is a wake with no deadline.
check_eq "  and the reset epoch is emitted unchanged" "$RESET_IN" "$(field "$OUT" RESET_EPOCH)"
OUT=$(run_classify "$(jq -nc --argjson e $(( NOW + 3*86400 )) '{error:"rate_limit", reset_epoch:$e}')")
check_eq "3-day reset -> weekly"       "weekly"         "$(field "$OUT" LIMIT_KIND)"
# A past or non-numeric reset is no reset time at all — 2D.6's validation rule.
OUT=$(run_classify "$(jq -nc --argjson e $(( NOW - 600 )) '{error:"rate_limit", reset_epoch:$e}')")
PU_EPOCH=$(iso_to_epoch "$(field "$OUT" PARKED_UNTIL)"); DELTA=$(( PU_EPOCH - NOW ))
check_true "a PAST reset epoch falls back to the 60m default" \
  "$( [ "$DELTA" -ge 3500 ] && [ "$DELTA" -le 3700 ] && echo true || echo false )"
OUT=$(run_classify '{"error":"rate_limit","reset_epoch":"soon"}')
PU_EPOCH=$(iso_to_epoch "$(field "$OUT" PARKED_UNTIL)"); DELTA=$(( PU_EPOCH - NOW ))
check_true "a non-numeric reset falls back to the 60m default" \
  "$( [ "$DELTA" -ge 3500 ] && [ "$DELTA" -le 3700 ] && echo true || echo false )"

# ---------------------------------------------------------------------------
echo "== Park claim: writes the record, and adopts rather than duplicating (AC 4, AC 6) =="
# ---------------------------------------------------------------------------

PARK_UNTIL_FIX="$(epoch_to_iso $(( NOW + 1800 )))"
run_claim() {  # run_claim <parked_until> <limit_kind>
  PARKED_UNTIL="$1" LIMIT_KIND="$2" bash -c "$BLOCK_CLAIM" 2>/dev/null
}

seed_unparked
OUT=$(run_claim "$PARK_UNTIL_FIX" rolling_window)
check_eq "unparked board: claim won"        "PARK_CLAIM=won" "$(printf '%s' "$OUT" | tail -1)"
# Read the FILE back, not the printed word: a block that printed "won" while
# writing nothing would pass a printed-output-only assertion.
check_eq "  parked_until persisted"         "$PARK_UNTIL_FIX" "$(day_get parked_until)"
check_eq "  limit_kind persisted"           "rolling_window"  "$(day_get limit_kind)"
check_eq "  limit_cause claimed as reactive" "reactive"       "$(day_get limit_cause)"
check_eq "  thrash counter incremented"     "1"               "$(day_get consecutive_limit_hits)"
check_eq "  probe bound is null (no bound)" "null"            "$(day_get limit_probe_fires_remaining)"

# A day-mode park already standing: the CAS on limit_cause must lose, the
# existing record must survive byte-for-byte, and no second park may open.
seed_existing_park preemptive "2026-12-01T10:00:00Z" '"task-daymode"'
BEFORE=$(cat "$STATE_FILE")
OUT=$(run_claim "$PARK_UNTIL_FIX" rolling_window)
check_eq "day-mode park present: adopted, not duplicated" \
  "PARK_CLAIM=adopted" "$(printf '%s' "$OUT" | tail -1)"
check_eq "  existing parked_until untouched" "2026-12-01T10:00:00Z" "$(day_get parked_until)"
check_eq "  existing cause untouched"        "preemptive"           "$(day_get limit_cause)"
check_eq "  existing wake id untouched"      "task-daymode"         "$(day_get limit_resume_task_id)"
check_eq "  thrash counter NOT bumped by the loser" "1"             "$(day_get consecutive_limit_hits)"
# Field-by-field checks can only pin the fields someone thought to list. A lost
# claim must write NOTHING, so compare the whole file.
check_eq "  a lost claim writes nothing at all" "$BEFORE" "$(cat "$STATE_FILE")"

# A sibling REACTIVE park (another subagent thread on the same repo) is adopted
# on the same compare, not merely a day-mode one.
seed_existing_park reactive "2026-12-01T10:00:00Z" '"task-sibling"'
OUT=$(run_claim "$PARK_UNTIL_FIX" rolling_window)
check_eq "sibling thread's park is adopted too" \
  "PARK_CLAIM=adopted" "$(printf '%s' "$OUT" | tail -1)"

# Fail closed on an unreadable thrash counter: no claim, no park, no wake.
seed_unparked
jq --arg k "$REPO_KEY" '.repos[$k].day.consecutive_limit_hits = {"corrupt": true}' \
  "$STATE_FILE" > "$STATE_FILE.tmp" && mv "$STATE_FILE.tmp" "$STATE_FILE"
CORRUPT_STATE="$STUB_DIR/corrupt-session-state.sh"
cat > "$CORRUPT_STATE" <<'STUB'
#!/usr/bin/env bash
# Stands in for a state read that fails (lock timeout / parse failure): the one
# input that makes the thrash guard unenforceable if it is treated as zero.
case "$1" in --get) exit 6 ;; esac
exit 0
STUB
chmod +x "$CORRUPT_STATE"
OUT=$(SESSION_STATE_SH="$CORRUPT_STATE" PARKED_UNTIL="$PARK_UNTIL_FIX" LIMIT_KIND=rolling_window \
      bash -c "$BLOCK_CLAIM" 2>/dev/null | tail -1)
check_eq "unreadable thrash counter fails closed" "PARK_CLAIM=error rc=hits:6" "$OUT"

# A READABLE but malformed counter is corruption, not absence — coercing it to 0
# would reset the thrash guard on exactly the state that guard exists to survive.
# Driven through the real session-state.sh, not a stub.
seed_unparked
jq --arg k "$REPO_KEY" '.repos[$k].day.consecutive_limit_hits = "three"' "$STATE_FILE" \
  > "$STATE_FILE.tmp" && mv "$STATE_FILE.tmp" "$STATE_FILE"
check_eq "a malformed thrash counter fails closed too" \
  "PARK_CLAIM=error rc=hits:malformed" "$(run_claim "$PARK_UNTIL_FIX" rolling_window | tail -1)"
check_eq "  and no park was opened"  "null" "$(day_get limit_cause)"
# The EMPTY string is 2D.7's documented half-written value and must still
# normalise to a fresh counter — the negative control that keeps the fix above
# from becoming a break in the interop it has to preserve.
seed_unparked
jq --arg k "$REPO_KEY" '.repos[$k].day.consecutive_limit_hits = ""' "$STATE_FILE" \
  > "$STATE_FILE.tmp" && mv "$STATE_FILE.tmp" "$STATE_FILE"
check_eq "an empty counter still normalises to a first hit" \
  "PARK_CLAIM=won" "$(run_claim "$PARK_UNTIL_FIX" rolling_window | tail -1)"
check_eq "  counting it as hit 1"    "1" "$(day_get consecutive_limit_hits)"

# ---------------------------------------------------------------------------
echo "== Pipeline records: /go-on resumes the phase, not the pipeline (AC 7) =="
# ---------------------------------------------------------------------------

seed_unparked
run_claim "$PARK_UNTIL_FIX" rolling_window >/dev/null
OUT=$(PR_NUM=1616 PARK_PHASE=B PARK_HEAD_SHA=abc1234 PARK_NEEDS=relaunch_phase_b \
      PARK_REMAINING='["poll for CR review"]' PARKED_UNTIL="$PARK_UNTIL_FIX" \
      bash -c "$BLOCK_PIPELINE" 2>/dev/null | tail -1)
check_eq "pipeline record written"          "PR_PARK=1616:recorded"  "$OUT"
check_eq "  phase recorded"                 "B"                      "$(pr_get 1616 usage_limit_park.phase)"
check_eq "  head sha recorded"              "abc1234"                "$(pr_get 1616 usage_limit_park.head_sha)"
check_eq "  handoff_reason at the PR level" "usage_limit_park"        "$(pr_get 1616 handoff_reason)"
check_eq "  remaining work carried"         "poll for CR review"      "$(pr_get 1616 'usage_limit_park.remaining_work[0]')"

# ---------------------------------------------------------------------------
echo "== Wake: deadline, thrash cap, weekly branch (AC 5) =="
# ---------------------------------------------------------------------------

run_wake() {  # run_wake <new_hits> <limit_kind> <reset_epoch>
  NEW_HITS="$1" LIMIT_KIND="$2" RESET_EPOCH="$3" PARKED_UNTIL="$(epoch_to_iso "$3")" \
    bash -c "$BLOCK_WAKE" 2>/dev/null
}

# The baseline is re-read immediately before EACH call: the block computes its
# sleep from `date` at run time, so a reset epoch derived from a NOW captured
# minutes earlier shrinks the expected window and makes these assertions flaky
# on a slow machine rather than wrong on a broken one.
BASE=$(date -u +%s); RESET=$(( BASE + 1800 ))
OUT=$(run_wake 1 rolling_window "$RESET")
check_eq "rolling window: wake armed" "armed" "$(field "$OUT" WAKE)"
SLEEP=$(field "$OUT" WAKE_SLEEP)
# reset + 2 minutes, first hit -> no backoff multiplier.
# The block re-reads the clock itself, so elapsed startup time only SHRINKS the
# sleep: the upper bound is the exact one, and the lower bound absorbs scheduler
# delay rather than turning a slow machine into a red build.
check_true "  sleeps until reset + 2 min ($SLEEP)" \
  "$( [ "$SLEEP" -ge 1860 ] && [ "$SLEEP" -le 1921 ] && echo true || echo false )"
GEN=$(field "$OUT" WAKE_GENERATION)
check_true "  mints a limit- generation ($GEN)" \
  "$( case "$GEN" in limit-*) echo true ;; *) echo false ;; esac )"

BASE=$(date -u +%s); RESET=$(( BASE + 1800 ))
OUT=$(run_wake 2 rolling_window "$RESET")
SLEEP2=$(field "$OUT" WAKE_SLEEP)
check_true "second hit doubles the sleep (2^(n-1) backoff): $SLEEP2" \
  "$( [ "$SLEEP2" -ge 3720 ] && [ "$SLEEP2" -le 3842 ] && echo true || echo false )"

BASE=$(date -u +%s); RESET=$(( BASE + 1800 ))
OUT=$(run_wake 3 rolling_window "$RESET")
check_eq "third consecutive hit: capped, no wake" "capped" "$(field "$OUT" WAKE)"
check_eq "  and no generation is minted"          ""       "$(field "$OUT" WAKE_GENERATION)"

OUT=$(run_wake 1 weekly $(( $(date -u +%s) + 3*86400 )))
check_eq "weekly cap: parked with NO Monitor" "weekly" "$(field "$OUT" WAKE)"
check_eq "  and no generation is minted"      ""       "$(field "$OUT" WAKE_GENERATION)"
check_true "  one line naming the manual resume" \
  "$( printf '%s' "$OUT" | grep -q 'weekly cap reached' && echo true || echo false )"

# Publication: one CAS from null, so a wake armed inside the shutdown window
# supersedes ours instead of being overwritten.
seed_unparked
run_claim "$PARK_UNTIL_FIX" rolling_window >/dev/null
OUT=$(LIMIT_MONITOR_TASK_ID='"task-mine"' WAKE_GENERATION="limit-mine" \
      bash -c "$BLOCK_PUBLISH" 2>/dev/null | tail -1)
check_eq "wake identity published"        "WAKE_PUBLISH=ok" "$OUT"
check_eq "  task id recorded"             "task-mine"       "$(day_get limit_resume_task_id)"
check_eq "  generation recorded with it"  "limit-mine"      "$(day_get limit_resume_generation)"
OUT=$(LIMIT_MONITOR_TASK_ID='"task-second"' WAKE_GENERATION="limit-second" \
      bash -c "$BLOCK_PUBLISH" 2>/dev/null | tail -1)
check_eq "a second wake is superseded, never registered" "WAKE_PUBLISH=superseded" "$OUT"
check_eq "  the first wake still owns the slot"          "task-mine" "$(day_get limit_resume_task_id)"

# The documented failure release: clearing `parked_until` alone would leave
# `limit_cause` standing, and since that is the field every parker compares
# against null, no future park — this thread's, day mode's, or a sibling's —
# could ever win the compare again. Assert the documented shape releases the
# claim and that a park owned by someone else survives the same release.
seed_unparked
run_claim "$PARK_UNTIL_FIX" rolling_window >/dev/null
release_claim() {
  "$SESSION_STATE_SH" \
    --cas ".repos[\"$REPO_KEY\"].day.limit_cause=null" --expect '"reactive"' \
    --set ".repos[\"$REPO_KEY\"].day.parked_until=null" \
    --set ".repos[\"$REPO_KEY\"].day.limit_kind=null" \
    --set ".repos[\"$REPO_KEY\"].day.limit_probe_fires_remaining=null" >/dev/null 2>&1
}
release_claim
check_eq "publish failure releases the cause, not just parked_until" "null" "$(day_get limit_cause)"
check_eq "  and the park is fully retired"                           "null" "$(day_get parked_until)"
OUT=$(run_claim "$PARK_UNTIL_FIX" rolling_window | tail -1)
check_eq "  so a later park can still claim the slot" "PARK_CLAIM=won" "$OUT"
seed_existing_park preemptive "2026-12-01T10:00:00Z" '"task-daymode"'
release_claim
check_eq "the release never clears someone else's park" "preemptive" "$(day_get limit_cause)"

# ---------------------------------------------------------------------------
echo "== /go-on generation gate: a stale wake changes nothing (AC 7) =="
# ---------------------------------------------------------------------------

run_gen() { CALLER_GENERATION="$1" bash -c "$BLOCK_GEN" 2>/dev/null | tail -1; }

# Re-establish a published wake: this section asserts against the generation the
# park record holds, so it seeds its own rather than inheriting whatever the
# previous section happened to leave behind.
seed_unparked
run_claim "$PARK_UNTIL_FIX" rolling_window >/dev/null
LIMIT_MONITOR_TASK_ID='"task-mine"' WAKE_GENERATION="limit-mine" \
  bash -c "$BLOCK_PUBLISH" >/dev/null 2>&1

check_eq "matching generation is valid"   "GENERATION_VERDICT=valid" "$(run_gen limit-mine)"
check_eq "mismatched generation is stale" "GENERATION_VERDICT=stale" "$(run_gen limit-other)"
"$SESSION_STATE_SH" --set ".repos[\"$REPO_KEY\"].day.limit_resume_generation=null" >/dev/null 2>&1
check_eq "a retired park makes the wake stale" "GENERATION_VERDICT=stale" "$(run_gen limit-mine)"
check_eq "no --generation is a manual run"     "GENERATION_VERDICT=absent" "$(run_gen '')"
OUT=$(CALLER_GENERATION=limit-mine SESSION_STATE_SH="$CORRUPT_STATE" \
      bash -c "$BLOCK_GEN" 2>/dev/null | tail -1)
check_eq "unreadable generation blocks, never resumes" "GENERATION_VERDICT=blocked" "$OUT"
OUT=$(CALLER_GENERATION=limit-mine SESSION_STATE_SH="" bash -c "$BLOCK_GEN" 2>/dev/null | tail -1)
check_eq "unresolved helper blocks too"                "GENERATION_VERDICT=blocked" "$OUT"


# ---------------------------------------------------------------------------
echo "== per-PR park write retries a lock timeout (exit 6) =="
# ---------------------------------------------------------------------------
# Exit 6 leaves state unchanged, so a dropped write makes the PR invisible to
# BOTH resume scans. The block must retry once; a second failure is reported.
FLAKY="$STUB_DIR/flaky-session-state.sh"
cat > "$FLAKY" <<'STUB'
#!/usr/bin/env bash
# Fails the FIRST --set with a lock timeout, then succeeds.
if [[ "$1" == "--set" ]]; then
  if [[ -f "$FLAKY_MARKER" ]]; then exit 0; fi
  : > "$FLAKY_MARKER"
  exit 6
fi
exit 0
STUB
chmod +x "$FLAKY"
FLAKY_MARKER="$STUB_DIR/flaky.marker"; rm -f "$FLAKY_MARKER"
OUT=$(FLAKY_MARKER="$FLAKY_MARKER" SESSION_STATE_SH="$FLAKY" \
  PR_NUM=1616 PARK_PHASE=B PARK_HEAD_SHA=abc1234 PARK_NEEDS=relaunch_phase_b \
  PARK_REMAINING='[]' PARKED_UNTIL="$PARK_UNTIL_FIX" bash -c "$BLOCK_PIPELINE" 2>/dev/null | tail -1)
check_eq "a lock timeout is retried, not reported as a lost pipeline" \
  "PR_PARK=1616:recorded" "$OUT"

ALWAYS6="$STUB_DIR/always6-session-state.sh"
printf '#!/usr/bin/env bash\n[[ "$1" == "--set" ]] && exit 6\nexit 0\n' > "$ALWAYS6"
chmod +x "$ALWAYS6"
OUT=$(SESSION_STATE_SH="$ALWAYS6" \
  PR_NUM=1616 PARK_PHASE=B PARK_HEAD_SHA=abc1234 PARK_NEEDS=relaunch_phase_b \
  PARK_REMAINING='[]' PARKED_UNTIL="$PARK_UNTIL_FIX" bash -c "$BLOCK_PIPELINE" 2>/dev/null | tail -1)
check_eq "  but a persistent timeout still reports the lost pipeline" \
  "PR_PARK=1616:error rc=6" "$OUT"
require_text "and the reference doc requires the single retry" \
  "$DOC" 'Retry ONCE'

# ---------------------------------------------------------------------------
echo "== /go-on probe F: finds the parked pipelines and their phases (AC 7) =="
# ---------------------------------------------------------------------------

run_probe() { bash -c "$BLOCK_PROBE" 2>/dev/null; }

seed_unparked
run_claim "$PARK_UNTIL_FIX" rolling_window >/dev/null
PR_NUM=1616 PARK_PHASE=B PARK_HEAD_SHA=abc1234 PARK_NEEDS=relaunch_phase_b \
  PARK_REMAINING='[]' PARKED_UNTIL="$PARK_UNTIL_FIX" bash -c "$BLOCK_PIPELINE" >/dev/null 2>&1
OUT=$(run_probe)
check_eq "probe F sees the park"       "present" "$(field "$OUT" PARK_PROBE)"
PIPES=$(field "$OUT" PARK_PIPELINES)
check_eq "  names the parked PR"       "1616"    "$(jq -r '.[0].pr' <<<"$PIPES")"
check_eq "  at the phase it was in"    "B"       "$(jq -r '.[0].phase' <<<"$PIPES")"
check_eq "  carrying its head sha"     "abc1234" "$(jq -r '.[0].head_sha' <<<"$PIPES")"

# An unexpired park reports the wait; it never dispatches into a closed window.
check_eq "  park still closed -> active"  "true" "$(field "$OUT" PARK_ACTIVE)"
check_true "  and names the remaining wait" \
  "$( [ "$(field "$OUT" PARK_WAIT_S)" -gt 0 ] && echo true || echo false )"
seed_unparked
"$SESSION_STATE_SH" --cas ".repos[\"$REPO_KEY\"].day.limit_cause=\"reactive\"" --expect null \
  --set ".repos[\"$REPO_KEY\"].day.parked_until=\"$(epoch_to_iso $(( $(date -u +%s) - 60 )))\"" \
  >/dev/null 2>&1
PR_NUM=1616 PARK_PHASE=B PARK_HEAD_SHA=abc1234 PARK_NEEDS=relaunch_phase_b \
  PARK_REMAINING='[]' PARKED_UNTIL="x" bash -c "$BLOCK_PIPELINE" >/dev/null 2>&1
OUT=$(run_probe)
check_eq "an expired park is present and no longer active" "present" "$(field "$OUT" PARK_PROBE)"
check_eq "  so the lane may relaunch"                      "false"   "$(field "$OUT" PARK_ACTIVE)"

# A park with no per-PR records is day mode's, not this lane's.
seed_existing_park reactive "$PARK_UNTIL_FIX" 'null'
check_eq "park with no pipeline records is absent for probe F" \
  "absent" "$(field "$(run_probe)" PARK_PROBE)"
# An unparked board with a leftover PR entry is absent too.
seed_unparked
check_eq "unparked board: probe F absent" "absent" "$(field "$(run_probe)" PARK_PROBE)"

# A RETIRED park over surviving per-PR records is a resume-now park, not an
# absent one (#1618). /pause-resume Step 5 retires the six park fields in one
# write and only then relaunches, deliberately leaving handoff_reason set on any
# PR whose relaunch did not land "so the next pass can retry it". Gating the
# .prs scan on parked_until made that next pass blind — the orphaned record was
# unreachable by every later /go-on and the promised retry could never happen.
seed_unparked
run_claim "$PARK_UNTIL_FIX" rolling_window >/dev/null
PR_NUM=1616 PARK_PHASE=B PARK_HEAD_SHA=abc1234 PARK_NEEDS=relaunch_phase_b \
  PARK_REMAINING='[]' PARKED_UNTIL="$PARK_UNTIL_FIX" bash -c "$BLOCK_PIPELINE" >/dev/null 2>&1
# Step 5's retirement: the park fields go, the per-PR record stays.
"$SESSION_STATE_SH" --set ".repos[\"$REPO_KEY\"].day.parked_until=null" >/dev/null 2>&1
OUT=$(run_probe)
check_eq "a retired park over surviving records is still present" \
  "present" "$(field "$OUT" PARK_PROBE)"
check_eq "  and the window is open, so the lane may relaunch" \
  "false" "$(field "$OUT" PARK_ACTIVE)"
check_eq "  with no wait to report" "0" "$(field "$OUT" PARK_WAIT_S)"
check_eq "  and it still names the orphaned PR" \
  "1616" "$(jq -r '.[0].pr' <<<"$(field "$OUT" PARK_PIPELINES)")"
require_text "and go-on documents that records outlive a retired parked_until" \
  "$GO_ON" 'Records OUTLIVE a retired'
require_text "  and that a bare claim is not a confirmed resume" \
  "$GO_ON" 'claimed-not-confirmed'
require_text "  and that the park digest covers every parked PR" \
  "$GO_ON" 'carries every parked PR'
require_text "pause-resume reclaims a dead usage_limit_relaunching claim" \
  "$PAUSE_RESUME" 'Reclaim stale claims before you scan'
require_text "  and refuses to reclaim on an unreadable inventory" \
  "$PAUSE_RESUME" 'inventory is never an empty'
# "Could not look" is never "nothing there".
OUT=$(SESSION_STATE_SH="$CORRUPT_STATE" bash -c "$BLOCK_PROBE" 2>/dev/null)
check_eq "unreadable state: probe F unreadable, never absent" \
  "unreadable" "$(field "$OUT" PARK_PROBE)"
# A damaged timestamp is damaged evidence, not an absent park: falling through
# would let a lane launch into a window nothing can date.
seed_existing_park reactive "not-a-timestamp" 'null'
check_eq "probe F: a malformed parked_until is unreadable" \
  "unreadable" "$(field "$(run_probe)" PARK_PROBE)"

# ...and so is a value that only ONE of the two parsers accepts. GNU `date -d`
# takes relative words, so an unvalidated field would read as a plausible epoch
# on Linux and as damaged evidence on macOS — the same record, two verdicts.
for BAD in tomorrow now "+1 day" "2026-09-04 01:23:45" "2026-09-04T01:23:45+00:00"; do
  seed_existing_park reactive "$BAD" 'null'
  check_eq "probe F: non-canonical parked_until '$BAD' is unreadable" \
    "unreadable" "$(field "$(run_probe)" PARK_PROBE)"
done
# The canonical shape still parses, so the gate rejects only what it should.
seed_existing_park reactive "$PARK_UNTIL_FIX" 'null'
check_eq "probe F: a canonical Z timestamp is still accepted" \
  "absent" "$(field "$(run_probe)" PARK_PROBE)"

# A validated generation names WHICH park armed the wake; it says nothing about
# whether that park's record still parses. Rank 2 retires the park and relaunches
# pipelines, so both need a readable record: a valid token over an unreadable
# probe F must be unclassifiable, not a licence to relaunch.
seed_unparked
"$SESSION_STATE_SH" \
  --cas ".repos[\"$REPO_KEY\"].day.limit_cause=\"reactive\"" --expect null \
  --set ".repos[\"$REPO_KEY\"].day.parked_until=\"not-a-timestamp\"" \
  --set ".repos[\"$REPO_KEY\"].day.limit_resume_generation=\"limit-mine\"" >/dev/null 2>&1
check_eq "a valid generation over a malformed park: generation still valid" \
  "GENERATION_VERDICT=valid" "$(run_gen limit-mine)"
check_eq "  but probe F is unreadable, so rank 2 is ineligible" \
  "unreadable" "$(field "$(run_probe)" PARK_PROBE)"
require_text "and go-on documents that combination as unclassifiable" \
  "$GO_ON" 'PARK_PROBE=unreadable` with a validated'
require_text "  and ranks 2 only on a readable probe F" \
  "$GO_ON" 'only when probe F is readable'

# ---------------------------------------------------------------------------
echo "== Recovery: an interrupted session re-arms the wake (AC 8) =="
# ---------------------------------------------------------------------------

run_recovery() { bash -c "$BLOCK_RECOVERY" 2>/dev/null | tail -1; }

seed_existing_park reactive "$(epoch_to_iso $(( NOW + 1800 )))" '"task-dead"'
check_eq "unexpired rolling-window park re-arms" "PARK_RECOVERY=rearm" "$(run_recovery)"

seed_existing_park reactive "$(epoch_to_iso $(( NOW - 1800 )))" '"task-dead"'
check_eq "an expired park resumes instead"       "PARK_RECOVERY=expired" "$(run_recovery)"

# A PRE-EMPTIVE park with fires LEFT is 2D.7's, not this path's: recovery must
# re-arm its bounded probe WITH THE STORED COUNT. Reading a live bound as
# `manual` strands a board whose wake was still re-armable; re-arming a fresh
# bound turns the bounded probe unbounded (#1445).
seed_existing_park preemptive "$(epoch_to_iso $(( NOW + 1800 )))" 'null'
jq --arg k "$REPO_KEY" '.repos[$k].day.limit_probe_fires_remaining = 7' "$STATE_FILE" \
  > "$STATE_FILE.tmp" && mv "$STATE_FILE.tmp" "$STATE_FILE"
check_eq "a live probe bound re-arms the probe with its own count" \
  "PARK_RECOVERY=rearm_probe fires=7" "$(run_recovery)"

seed_existing_park reactive "$(epoch_to_iso $(( NOW + 3*86400 )))" 'null'
jq --arg k "$REPO_KEY" '.repos[$k].day.limit_kind = "weekly"' "$STATE_FILE" \
  > "$STATE_FILE.tmp" && mv "$STATE_FILE.tmp" "$STATE_FILE"
check_eq "a weekly park never auto-wakes"        "PARK_RECOVERY=manual" "$(run_recovery)"

# A spent probe bound (0 or -1) stays parked whatever parked_until says — the
# #1445 three-valued rule, which recovery must not re-arm through.
seed_existing_park preemptive "$(epoch_to_iso $(( NOW + 1800 )))" 'null'
jq --arg k "$REPO_KEY" '.repos[$k].day.limit_probe_fires_remaining = -1' "$STATE_FILE" \
  > "$STATE_FILE.tmp" && mv "$STATE_FILE.tmp" "$STATE_FILE"
check_eq "a -1 bound stays parked, re-arms nothing" "PARK_RECOVERY=manual" "$(run_recovery)"
jq --arg k "$REPO_KEY" '.repos[$k].day.limit_probe_fires_remaining = 0' "$STATE_FILE" \
  > "$STATE_FILE.tmp" && mv "$STATE_FILE.tmp" "$STATE_FILE"
check_eq "a spent 0 bound stays parked too"         "PARK_RECOVERY=manual" "$(run_recovery)"

seed_unparked
check_eq "no park: recovery is a no-op"          "PARK_RECOVERY=none" "$(run_recovery)"
OUT=$(SESSION_STATE_SH="$CORRUPT_STATE" bash -c "$BLOCK_RECOVERY" 2>/dev/null | tail -1)
check_eq "an unreadable park fails closed"       "PARK_RECOVERY=unreadable" "$OUT"
# A garbage timestamp is unreadable, never "expired" — reading it as expired
# would dispatch a fresh board into a window that is still closed.
seed_existing_park reactive "not-a-timestamp" 'null'
check_eq "a malformed parked_until fails closed" "PARK_RECOVERY=unreadable" "$(run_recovery)"

# ---------------------------------------------------------------------------
echo "== Wiring: the rules route limit deaths away from the crash path (AC 2, AC 9) =="
# ---------------------------------------------------------------------------

require_text "phase-protocols names the limit-parked bucket" \
  "$RULES/phase-protocols.md" 'Limit-parked is not a crash'
require_text "phase-protocols points at the reference doc" \
  "$RULES/phase-protocols.md" 'subagent-thread-limit-park\.md'
require_text "phase-protocols' Ask-first callout excludes the limit case" \
  "$RULES/phase-protocols.md" 'Ask first:.*limit-parked death never asks'
require_text "monitor-mode adds the third respawn bucket" \
  "$RULES/monitor-mode.md" 'crash asks, exhaustion auto, limit-parked'
require_text "monitor-mode recovery re-arms the wake" \
  "$RULES/monitor-mode.md" 'subagent-thread-limit-park\.md'
require_text "subagent-orchestration says a limit death does not ask" \
  "$RULES/subagent-orchestration.md" 'usage limit is neither'
require_text "subagent SKILL classifies before calling a death a crash" \
  "$SUBAGENT" 'subagent-thread-limit-park\.md'
require_text "subagent SKILL recovers a park at session start" \
  "$SUBAGENT" 'Recover an unexpired usage-limit park'
require_text "go-on documents the generation flag" \
  "$GO_ON" '\-\-generation <id>'
require_text "go-on ranks the park lane" \
  "$GO_ON" 'usage_limit_park'
require_text "the schema documents the park record" \
  "$SCHEMA" '_usage_limit_park_example'
require_text "the schema says the .day slot is shared" \
  "$SCHEMA" 'park slot is SHARED'
# The quota-authority rule must be untouched: only the runtime's classification
# triggers this, and nothing estimates tokens.
refute_text "safety.md's quota rule was NOT amended" \
  "$RULES/safety.md" 'subagent-thread-limit-park'
require_text "the reference doc restates the quota-authority constraint" \
  "$DOC" 'Nothing here estimates tokens'
# An adopted day-mode park is woken by /pause-resume, which re-arms live runtime
# IDs — so its Step 5 must ALSO relaunch the parked pipelines, or every record
# written on the adoption path resumes nothing.
require_text "pause-resume relaunches usage-limit-parked pipelines" \
  "$REPO_ROOT/.claude/skills/pause-resume/SKILL.md" 'handoff_reason == "usage_limit_park"'
require_text "  and follows the reference procedure directly, not via /go-on" \
  "$REPO_ROOT/.claude/skills/pause-resume/SKILL.md" 'never by invoking `/go-on`'
# A relaunch is a launch: a reopened window is not a licence to dispatch past
# the ceiling, the refill pause, or an armed deadline.
require_text "the relaunch reapplies every launch gate" \
  "$REPO_ROOT/.claude/skills/pause-resume/SKILL.md" 'Step 7 launch gate applies to each relaunch'
require_text "the reference doc says every launch gate binds" \
  "$DOC" 'Every launch gate still binds'
require_text "the reference doc names both wake entry points" \
  "$DOC" 'Either wake reaches the same relaunch'
require_text "subagent SKILL stops when the reference cannot be resolved" \
  "$SUBAGENT" 'checked all three paths'
# CodeAnt #1621: the monitor loop pointed at a bare `.claude/reference/` path
# while Step 0.1 resolves the same doc through three candidates — an installed
# skill in a repo without `.claude/` could not reach it.
require_text "the monitor loop resolves the reference through Step 0.1" \
  "$SUBAGENT" "Step 0.1's candidate order"
refute_text "  and hardcodes no bare .claude/reference path for it" \
  "$SUBAGENT" '\.claude/reference/subagent-thread-limit-park'
# CodeAnt #1621: a failed per-PR park write left the pipeline invisible to both
# the §5 scan and Probe F — the echoed error line had no consumer.
require_text "a failed per-PR park write is a lost pipeline, not a warning" \
  "$DOC" 'lost pipeline, not a logged warning'
require_text "  and is named in the park report as needing a manual relaunch" \
  "$DOC" 'unparked: PR'
# CodeAnt #1621: the per-PR records are repo-scoped, so two resuming threads
# would each relaunch the same parked pipeline without a claim.
require_text "the relaunch claims each PR before launching it" \
  "$REPO_ROOT/.claude/skills/pause-resume/SKILL.md" 'usage_limit_relaunching'
require_text "  and the reference doc names the same claim" \
  "$DOC" 'usage_limit_relaunching'

# CodeAnt #1621 (critical): /pause-resume Step 5 now relaunches the parked
# pipelines, so the /go-on park lane relaunching its own saved PARK_PIPELINES
# afterwards produced two Phase B/C pipelines on one branch.
require_text "the go-on park lane delegates the relaunch and launches nothing" \
  "$GO_ON" 'relaunch nothing here'
require_text "  and treats PARK_PIPELINES as an expectation, not a work list" \
  "$GO_ON" 'not a second work list'
refute_text "  so it no longer relaunches each PARK_PIPELINES entry itself" \
  "$GO_ON" 'for each entry in .PARK_PIPELINES., read its scoped handoff file and relaunch'
# CodeAnt #1621: probe F filled missing phase/head_sha/needs with empty strings,
# so a damaged record reported as resumable instead of unreadable.
require_text "probe F rejects a parked record missing required fields" \
  "$GO_ON" 'parked record missing phase/head_sha/needs'

# Negative control for the wiring assertions above: prove the matcher can fail.
refute_text "negative control — an unrelated pattern does not match" \
  "$RULES/monitor-mode.md" 'crash asks, exhaustion auto, limit-unparked'

# ---------------------------------------------------------------------------
echo
echo "== $PASS passed, $FAIL failed =="
[ "$FAIL" -eq 0 ] || exit 1
