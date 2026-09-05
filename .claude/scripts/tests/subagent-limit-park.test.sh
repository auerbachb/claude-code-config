#!/usr/bin/env bash
# Tests for the reactive subagent-thread usage-limit park — issue #1618.
# catalog: tests — Tests the reactive subagent-thread usage-limit park (#1618) against the real fenced bash in `.claude/reference/subagent-thread-limit-park.md` and `/go-on` — structured-signal detection with its text-only negative controls, the compare-and-set park claim and its adoption of an existing day-mode or sibling park, per-pipeline phase records, the reset-plus-2-minute wake with its thrash cap and weekly branch, stale-generation rejection, and fail-closed recovery
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
PM_SKILL="$REPO_ROOT/.claude/skills/pm/SKILL.md"
PAUSE_RESUME="$REPO_ROOT/.claude/skills/pause-resume/SKILL.md"
SCHEMA="$REPO_ROOT/.claude/reference/session-state-schema.json"
DAY_MODE_DOC="$REPO_ROOT/.claude/reference/pm-day-mode.md"
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

# Ordering assertions. `require_text` proves a string is SOMEWHERE in a file;
# these prove one string precedes another, which is what a checklist position
# actually means. Both readers put the horizon read at item 0 deliberately: a
# document that kept every matched string but demoted the read below the refill
# step would satisfy every presence assertion and still start work it should
# not have.
line_of() {   # line_of <file> <extended-regex> -> first matching line no, or 0
  local n
  n="$(grep -nE -m1 -- "$2" "$1" 2>/dev/null | cut -d: -f1)"
  printf '%s' "${n:-0}"
}
check_before() {   # check_before <desc> <file> <earlier-regex> <later-regex>
  local desc="$1" file="$2" a b
  a="$(line_of "$file" "$3")"
  b="$(line_of "$file" "$4")"
  check_true "$desc" \
    "$( [ "$a" -gt 0 ] && [ "$b" -gt 0 ] && [ "$a" -lt "$b" ] && echo true || echo false )"
}

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
      park_claim_token: null,
      limit_probe_fires_remaining: null, limit_resume_task_id: null,
      limit_resume_generation: null, consecutive_limit_hits: 0}}}}' > "$STATE_FILE"
}
# A `/pm` 2D.7 Step 1 claim caught mid-assembly: `parked_until` and the kind are
# durable, the token is held, and `limit_cause` is still null because Step 3
# never ran (#1596).
seed_inflight_claim() {  # seed_inflight_claim <token> <parked_until>
  jq -n --arg k "$REPO_KEY" --arg tok "$1" --arg until "$2" \
    '{repos: {($k): {day: {
      active: true, parked_until: $until, limit_kind: "rolling_window",
      limit_cause: null, park_claim_token: $tok,
      limit_probe_fires_remaining: -1, limit_resume_task_id: null,
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

# An in-flight 2D.7 claim is the one park state this claim may take rather than
# adopt: `limit_cause` is still null, so the compare wins — and the win must
# RETIRE that claim's token in the same write (#1596), or the claim goes on to
# finalise (or release) over the record this thread just created.
seed_inflight_claim "park-20261201T090000Z-4242-7" "2026-12-01T15:00:00Z"
OUT=$(run_claim "$PARK_UNTIL_FIX" rolling_window)
check_eq "in-flight 2D.7 claim: this leg wins the cause compare" \
  "PARK_CLAIM=won" "$(printf '%s' "$OUT" | tail -1)"
check_eq "  the in-flight claim token is retired" "null"       "$(day_get park_claim_token)"
check_eq "  and this leg's record is the survivor" "reactive"  "$(day_get limit_cause)"
check_eq "  with this leg's parked_until"  "$PARK_UNTIL_FIX"   "$(day_get parked_until)"
# Non-vacuity: without the `--set park_claim_token=null` the same win leaves the
# token standing, and 2D.7's stale finalisation then still matches this slot.
seed_inflight_claim "park-20261201T090000Z-4242-7" "2026-12-01T15:00:00Z"
CONTROL_CLAIM_RC=0
"$SESSION_STATE_SH" --cas ".repos[\"$REPO_KEY\"].day.limit_cause=\"reactive\"" --expect null \
  --set ".repos[\"$REPO_KEY\"].day.parked_until=\"$PARK_UNTIL_FIX\"" \
  --set ".repos[\"$REPO_KEY\"].day.limit_kind=\"rolling_window\"" \
  >/dev/null 2>&1 || CONTROL_CLAIM_RC=$?
check_eq "control: the untokenized claim also wins" "0" "$CONTROL_CLAIM_RC"
check_eq "control: ...but leaves the stale claim token live" \
  "park-20261201T090000Z-4242-7" "$(day_get park_claim_token)"

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
echo "== #1622: /pm 2D.6 landing between this park's claim and its wake publish =="
# ---------------------------------------------------------------------------
# The residual window the ticket names. §2's CAS has won — `limit_cause` is
# claimed — but §4 has not published yet, so `limit_resume_task_id` is still
# null. Before #1622 /pm's reactive path read that null, concluded there was no
# wake to stop, and wrote its whole record with a plain --set batch; the §2
# winner then reached §4, also read null, and published. Two wakes over one
# park. 2D.6 now claims `limit_cause` by the same compare-and-set, so the
# interleaving costs it the slot instead of the park.
BLOCK_PM_2D6="$(extract_skill_bash "$PM_SKILL" pm-day-2d6-park-claim)" || exit 1

run_pm_2d6() {  # run_pm_2d6 <parked_until> <limit_kind> [new_hits]
  PARKED_UNTIL="$1" LIMIT_KIND="$2" NEW_HITS="${3-1}" bash -c "$BLOCK_PM_2D6" 2>/dev/null | tail -1
}
PM_2D6_UNTIL="2026-12-01T10:00:00Z"   # deliberately NOT $PARK_UNTIL_FIX

seed_unparked
check_eq "the thread's §2 claim wins first" "PARK_CLAIM=won" \
  "$(run_claim "$PARK_UNTIL_FIX" rolling_window | tail -1)"
check_eq "  and §4 has not published a wake yet" "null" "$(day_get limit_resume_task_id)"
BEFORE_2D6=$(cat "$STATE_FILE")
check_eq "2D.6 landing inside that window adopts" "PARK_CLAIM=adopted" \
  "$(run_pm_2d6 "$PM_2D6_UNTIL" rolling_window 5)"
# The two paths write DIFFERENT values into every shared field, so each check
# below distinguishes the winner's record from 2D.6's rather than matching both.
check_eq "  the §2 winner's parked_until survives" "$PARK_UNTIL_FIX" "$(day_get parked_until)"
check_eq "  2D.6's own timestamp was not written"  "1"               "$(day_get consecutive_limit_hits)"
check_eq "  a lost 2D.6 claim writes nothing at all" "$BEFORE_2D6" "$(cat "$STATE_FILE")"

# Now the §2 winner reaches §4. Exactly one wake may exist over this one park,
# and it must be the owner's — the outcome #1428 / #1445 / #1622 exist for.
OUT=$(LIMIT_MONITOR_TASK_ID='"task-owner"' WAKE_GENERATION="limit-owner" \
      bash -c "$BLOCK_PUBLISH" 2>/dev/null | tail -1)
check_eq "the §2 winner publishes its wake"      "WAKE_PUBLISH=ok" "$OUT"
check_eq "  exactly one wake over one park"      "task-owner"      "$(day_get limit_resume_task_id)"
check_eq "  and the generation is the owner's"   "limit-owner"     "$(day_get limit_resume_generation)"

# Negative control for the adoption above: with the slot free, the SAME 2D.6
# invocation wins and writes its own record. Without this, "adopted" would also
# be the reading of a block that could never claim anything.
seed_unparked
check_eq "control: with the slot free, 2D.6 wins" "PARK_CLAIM=won" \
  "$(run_pm_2d6 "$PM_2D6_UNTIL" rolling_window 5)"
check_eq "  and 2D.6's own record landed"      "$PM_2D6_UNTIL" "$(day_get parked_until)"
check_eq "  with its own thrash counter"       "5"             "$(day_get consecutive_limit_hits)"
check_eq "  and its own cause"                 "reactive"      "$(day_get limit_cause)"
# The mirror direction, closing the loop: a park 2D.6 opened is adopted by this
# document's §2 claim, exactly as a day-mode 2D.7 park already is.
check_eq "  a park 2D.6 opened is adopted here" "PARK_CLAIM=adopted" \
  "$(run_claim "$PARK_UNTIL_FIX" rolling_window | tail -1)"
check_eq "  2D.6's park survives that adoption" "$PM_2D6_UNTIL" "$(day_get parked_until)"

# The mechanism is documented where the mechanism lives, not in the auto-loaded
# corpus: pin the day-mode narrative and the schema comment.
require_text "day-mode doc records the reactive CAS claim" "$DAY_MODE_DOC" \
  'since #1622'
require_text "day-mode doc states the loss semantics" "$DAY_MODE_DOC" \
  'What a lost claim means'
require_text "schema attributes the cause CAS to both paths" "$SCHEMA" \
  'since #1622, 2D.6'

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
echo "== Pre-emptive (#1619): the horizon gate, and its parity with /pm 2D.7 =="
# ---------------------------------------------------------------------------
# The subagent monitor loop and day mode's D2 tick read the SAME script and must
# reach the SAME verdict — two readers of one predicate is exactly the shape
# that drifts silently, so both blocks are run over one fixture matrix and
# compared field by field rather than eyeballed.

BLOCK_HORIZON="$(extract_skill_bash "$DOC" subagent-limit-horizon-gate)"       || exit 1
BLOCK_WINDOW="$(extract_skill_bash  "$DOC" subagent-limit-preemptive-window)"  || exit 1
BLOCK_PM_D2="$(extract_skill_bash   "$PM_SKILL" pm-day-d2-horizon-branch)"     || exit 1

# A stand-in for usage-horizon.sh: --check prints the STATUS/REASON pair and
# exits on the documented code; --observe exits 0 whatever the verdict.
make_horizon_stub() {   # make_horizon_stub <status> [observe_rc]
  local status="$1" observe_rc="${2:-0}" path="$STUB_DIR/usage-horizon.sh" rc
  case "$status" in
    clear) rc=0 ;; approaching) rc=1 ;; critical) rc=2 ;; *) rc=3 ;;
  esac
  cat > "$path" <<STUB
#!/usr/bin/env bash
case "\$1" in
  --observe) exit $observe_rc ;;
  --check)   printf 'STATUS=%s\nREASON=%s\n' "$status" "stub"; exit $rc ;;
esac
exit 4
STUB
  chmod +x "$path"
  echo "$path"
}
run_horizon() {  # run_horizon <block> <script-path> [remaining] [limit]
  USAGE_HORIZON_SH="$2" HORIZON_REMAINING="${3:-}" HORIZON_LIMIT="${4:-}" \
    bash -c "$1" 2>/dev/null
}

# The four verdicts, each asserted on the two decisions it drives.
OUT=$(run_horizon "$BLOCK_HORIZON" "$(make_horizon_stub clear)" 900000 1000000)
check_eq "clear: refill allowed" "true"  "$(field "$OUT" HORIZON_REFILL_OK)"
check_eq "clear: no park"        "false" "$(field "$OUT" HORIZON_PARK)"

OUT=$(run_horizon "$BLOCK_HORIZON" "$(make_horizon_stub approaching)" 200000 1000000)
check_eq "approaching: launches nothing new" "false" "$(field "$OUT" HORIZON_REFILL_OK)"
check_eq "approaching: NEVER parks"          "false" "$(field "$OUT" HORIZON_PARK)"
check_eq "approaching: idle reason"          "paused (horizon approaching)" \
  "$(field "$OUT" HORIZON_IDLE_REASON)"

OUT=$(run_horizon "$BLOCK_HORIZON" "$(make_horizon_stub critical)" 50000 1000000)
check_eq "critical: parks"          "true"  "$(field "$OUT" HORIZON_PARK)"
check_eq "critical: no new work"    "false" "$(field "$OUT" HORIZON_REFILL_OK)"

OUT=$(run_horizon "$BLOCK_HORIZON" "$(make_horizon_stub unknown)" 50000 1000000)
check_eq "unknown: verdict"      "unknown" "$(field "$OUT" HORIZON_STATUS)"
check_eq "unknown: NEVER parks"  "false"   "$(field "$OUT" HORIZON_PARK)"
check_eq "unknown: no refill"    "false"   "$(field "$OUT" HORIZON_REFILL_OK)"

# Every degraded input lands on `unknown`, and `unknown` is never `clear`. Each
# of these would be a fail-open under a `!= critical` test.
OUT=$(run_horizon "$BLOCK_HORIZON" "$STUB_DIR/does-not-exist.sh" 50000 1000000)
check_eq "missing script: unknown, no park" "unknown" "$(field "$OUT" HORIZON_STATUS)"
check_eq "  and no launches"                "false"   "$(field "$OUT" HORIZON_REFILL_OK)"
OUT=$(run_horizon "$BLOCK_HORIZON" "" 50000 1000000)
check_eq "unresolved helper: unknown"       "unknown" "$(field "$OUT" HORIZON_STATUS)"
check_eq "  and never parks"                "false"   "$(field "$OUT" HORIZON_PARK)"
# No counter in context is an ABSENT reading, not a remembered one.
OUT=$(run_horizon "$BLOCK_HORIZON" "$(make_horizon_stub critical)" "" "")
check_eq "no counter: observe skipped, check still consulted" "critical" \
  "$(field "$OUT" HORIZON_STATUS)"
# A failed --observe is a write failure, never a verdict: hold unknown.
OUT=$(run_horizon "$BLOCK_HORIZON" "$(make_horizon_stub clear 5)" 900000 1000000)
check_eq "failed observe clamps to unknown"  "unknown" "$(field "$OUT" HORIZON_STATUS)"
check_eq "  and never reads as clear"        "false"   "$(field "$OUT" HORIZON_REFILL_OK)"
GARBAGE="$STUB_DIR/garbage.sh"
printf '#!/usr/bin/env bash\necho "Review limit reached"\nexit 0\n' > "$GARBAGE"; chmod +x "$GARBAGE"
OUT=$(run_horizon "$BLOCK_HORIZON" "$GARBAGE" 50000 1000000)
check_eq "garbage output: unknown, not clear" "unknown" "$(field "$OUT" HORIZON_STATUS)"

# PARITY. Same inputs into both readers; identical verdict/refill/park/idle.
for CASE in clear approaching critical unknown; do
  STUB_PATH="$(make_horizon_stub "$CASE")"
  MINE=$(run_horizon "$BLOCK_HORIZON" "$STUB_PATH" 500000 1000000 \
    | grep -E '^HORIZON_(STATUS|REFILL_OK|PARK|IDLE_REASON)=')
  THEIRS=$(run_horizon "$BLOCK_PM_D2" "$STUB_PATH" 500000 1000000 \
    | grep -E '^HORIZON_(STATUS|REFILL_OK|PARK|IDLE_REASON)=')
  check_eq "parity with /pm 2D.7's D2 gate on '$CASE'" "$THEIRS" "$MINE"
done
# Parity on the degraded paths too — that is where a divergence would be a
# fail-open rather than a cosmetic difference.
for SCRIPT in "$STUB_DIR/does-not-exist.sh" "$GARBAGE" ""; do
  MINE=$(run_horizon "$BLOCK_HORIZON" "$SCRIPT" 500000 1000000 \
    | grep -E '^HORIZON_(STATUS|REFILL_OK|PARK)=')
  THEIRS=$(run_horizon "$BLOCK_PM_D2" "$SCRIPT" 500000 1000000 \
    | grep -E '^HORIZON_(STATUS|REFILL_OK|PARK)=')
  check_eq "parity on degraded input '${SCRIPT:-<unresolved>}'" "$THEIRS" "$MINE"
done
# Negative control for the parity comparison itself: two DIFFERENT verdicts must
# not compare equal, or every check above would pass vacuously.
MINE=$(run_horizon "$BLOCK_HORIZON" "$(make_horizon_stub clear)" 900000 1000000 \
  | grep -E '^HORIZON_PARK=')
THEIRS=$(run_horizon "$BLOCK_PM_D2" "$(make_horizon_stub critical)" 50000 1000000 \
  | grep -E '^HORIZON_PARK=')
check_true "negative control — the parity comparison can fail" \
  "$( [ "$MINE" != "$THEIRS" ] && echo true || echo false )"

# ---------------------------------------------------------------------------
echo "== Pre-emptive: knobs, deadline, and the reset-known / reset-unknown split =="
# ---------------------------------------------------------------------------

run_window() { env "$@" bash -c "$BLOCK_WINDOW" 2>/dev/null; }

OUT=$(run_window HORIZON_RESET_EPOCH=)
check_eq "cause is preemptive"          "preemptive"     "$(field "$OUT" PARK_CAUSE)"
check_eq "kind is always rolling_window" "rolling_window" "$(field "$OUT" LIMIT_KIND)"
check_eq "default landing window"        "2"             "$(field "$OUT" PARK_WINDOW_MIN)"
check_eq "default probe cadence"         "30"            "$(field "$OUT" PROBE_CADENCE_MIN)"
check_eq "default probe bound"           "12"            "$(field "$OUT" PROBE_MAX_FIRES)"
check_eq "no reset time known"           "false"         "$(field "$OUT" PARK_RESET_KNOWN)"
check_eq "  so the real bound is claimed, not the -1 sentinel" "12" \
  "$(field "$OUT" CLAIM_FIRES)"
# The deadline must be in the FUTURE: every reader treats a non-future
# parked_until as "no park", so a knob that fell through to 0 would stop the
# board while its own record said it had not been parked.
PU=$(field "$OUT" PARKED_UNTIL)
check_true "deadline is the cadence x fires outer edge, in the future" \
  "$( [ "$(iso_to_epoch "$PU")" -gt "$(date -u +%s)" ] && echo true || echo false )"

# A known reset wins, and switches the wake to the sleep-until-reset shape.
FUTURE=$(( $(date -u +%s) + 5400 ))
OUT=$(run_window HORIZON_RESET_EPOCH="$FUTURE")
check_eq "a known reset is used"            "true" "$(field "$OUT" PARK_RESET_KNOWN)"
check_eq "  and carries no probe bound"     "null" "$(field "$OUT" CLAIM_FIRES)"
check_eq "  and parks until that instant"   "$(epoch_to_iso "$FUTURE")" \
  "$(field "$OUT" PARKED_UNTIL)"
# A PAST reset is no reset at all — same validation §1 applies.
OUT=$(run_window HORIZON_RESET_EPOCH=$(( $(date -u +%s) - 60 )))
check_eq "a past reset is ignored" "false" "$(field "$OUT" PARK_RESET_KNOWN)"

# Knob validation is EXECUTED, not merely documented.
OUT=$(run_window CLAUDE_HORIZON_PARK_WINDOW_MINUTES=0 HORIZON_RESET_EPOCH=)
check_eq "window 0 is legal — reactive parity" "0" "$(field "$OUT" PARK_WINDOW_MIN)"
OUT=$(run_window CLAUDE_HORIZON_PARK_WINDOW_MINUTES=abc HORIZON_RESET_EPOCH=)
check_eq "a malformed window falls back to 2"  "2" "$(field "$OUT" PARK_WINDOW_MIN)"
OUT=$(run_window CLAUDE_HORIZON_PROBE_CADENCE_MINUTES=0 HORIZON_RESET_EPOCH=)
check_eq "cadence 0 is rejected — a hot loop"  "30" "$(field "$OUT" PROBE_CADENCE_MIN)"
OUT=$(run_window CLAUDE_HORIZON_PROBE_MAX_FIRES=0 HORIZON_RESET_EPOCH=)
check_eq "bound 0 is rejected — a self-stopping wake" "12" "$(field "$OUT" PROBE_MAX_FIRES)"
OUT=$(run_window CLAUDE_HORIZON_PROBE_CADENCE_MINUTES=5 CLAUDE_HORIZON_PROBE_MAX_FIRES=3 HORIZON_RESET_EPOCH=)
check_eq "valid cadence override honoured" "5" "$(field "$OUT" PROBE_CADENCE_MIN)"
check_eq "valid bound override honoured"   "3" "$(field "$OUT" PROBE_MAX_FIRES)"
check_eq "  and the bound is what gets claimed" "3" "$(field "$OUT" CLAIM_FIRES)"

# A leading zero passes `^[0-9]+$` AND `[ 08 -gt 0 ]`, then dies in the OCTAL
# arithmetic that computes the deadline — leaving RESET_EPOCH empty and
# PARKED_UNTIL garbage, and writing `08` into state where jq rejects it as a
# number. Normalising through `10#` at validation time is what closes it.
OUT=$(run_window CLAUDE_HORIZON_PROBE_CADENCE_MINUTES=08 CLAUDE_HORIZON_PROBE_MAX_FIRES=09 \
                 CLAUDE_HORIZON_PARK_WINDOW_MINUTES=05 HORIZON_RESET_EPOCH=)
check_eq "leading-zero cadence is decimal, not octal" "8" "$(field "$OUT" PROBE_CADENCE_MIN)"
check_eq "leading-zero bound is decimal too"          "9" "$(field "$OUT" PROBE_MAX_FIRES)"
check_eq "leading-zero window is decimal too"         "5" "$(field "$OUT" PARK_WINDOW_MIN)"
check_eq "  and the claimed bound is a valid JSON number" "9" "$(field "$OUT" CLAIM_FIRES)"
ZERO_EPOCH=$(iso_to_epoch "$(field "$OUT" PARKED_UNTIL)" 2>/dev/null || echo 0)
check_true "  and the deadline is still a real future instant" \
  "$( [ "$ZERO_EPOCH" -gt "$(date -u +%s)" ] && echo true || echo false )"
ZERO_FIRES=$(field "$OUT" CLAIM_FIRES)
check_true "  and jq accepts that bound as a number" \
  "$( jq -e -n --argjson f "$ZERO_FIRES" '$f > 0' >/dev/null 2>&1 && echo true || echo false )"

# The same hole by magnitude (#1619 review). A bare `^[0-9]+$` accepts a 20-digit
# knob, and `10#` then WRAPS IT SILENTLY — rc 0, no error, no stderr:
# `$(( 10#99999999999999999999 ))` is 7766279631452241919, and one more `* 60`
# lands on 0. The park deadline that computes is not in the future, so every
# reader treats the record as "no park" — the leading-zero failure by another
# road. The `{1,6}` digit bound is what closes it, so a huge knob must REJECT
# to the documented default rather than be normalised into garbage.
# Negative control (bound reverted to `^[0-9]+$`): the WINDOW knob is the one
# that actually wraps — 2 becomes 7766279631452241919 — because it is the only
# one with no `-gt 0` test. `[ <20 digits> -gt 0 ]` errors out ("integer
# expression expected") and accidentally saves the other two, which is luck,
# not a guard: `$(( ))` wraps where `[ ]` refuses. Assert all three anyway.
HUGE=99999999999999999999
OUT=$(run_window CLAUDE_HORIZON_PARK_WINDOW_MINUTES=$HUGE \
                 CLAUDE_HORIZON_PROBE_CADENCE_MINUTES=$HUGE \
                 CLAUDE_HORIZON_PROBE_MAX_FIRES=$HUGE HORIZON_RESET_EPOCH=)
check_eq "a 20-digit window is rejected, not wrapped"  "2"  "$(field "$OUT" PARK_WINDOW_MIN)"
check_eq "a 20-digit cadence is rejected, not wrapped" "30" "$(field "$OUT" PROBE_CADENCE_MIN)"
check_eq "a 20-digit bound is rejected, not wrapped"   "12" "$(field "$OUT" PROBE_MAX_FIRES)"
HUGE_EPOCH=$(iso_to_epoch "$(field "$OUT" PARKED_UNTIL)" 2>/dev/null || echo 0)
check_true "  and the deadline is still a real future instant" \
  "$( [ "$HUGE_EPOCH" -gt "$(date -u +%s)" ] && echo true || echo false )"
# Negative control: the bound must not be so tight it rejects a legitimate knob.
OUT=$(run_window CLAUDE_HORIZON_PROBE_CADENCE_MINUTES=999999 HORIZON_RESET_EPOCH=)
check_eq "  six digits is still accepted" "999999" "$(field "$OUT" PROBE_CADENCE_MIN)"

# ---------------------------------------------------------------------------
echo "== Pre-emptive: a critical fixture parks with the preemptive cause =="
# ---------------------------------------------------------------------------
# Test Plan 1: fixture counter below the critical threshold -> park with the
# preemptive cause, the landing window honoured, and the probe wake armed when
# no reset time is known. State is read BACK from the file: a claim block that
# printed "won" while writing nothing would pass a stdout-only assertion.

seed_unparked
W=$(run_window CLAUDE_HORIZON_PROBE_CADENCE_MINUTES=30 CLAUDE_HORIZON_PROBE_MAX_FIRES=12 HORIZON_RESET_EPOCH=)
PRE_UNTIL=$(field "$W" PARKED_UNTIL)
OUT=$(PARK_CAUSE=preemptive CLAIM_FIRES="$(field "$W" CLAIM_FIRES)" \
      PARKED_UNTIL="$PRE_UNTIL" LIMIT_KIND=rolling_window \
      bash -c "$BLOCK_CLAIM" 2>/dev/null | tail -1)
check_eq "the pre-emptive claim wins the empty slot" "PARK_CLAIM=won" "$OUT"
check_eq "  cause recorded as preemptive"  "preemptive"     "$(day_get limit_cause)"
check_eq "  kind recorded as rolling"      "rolling_window" "$(day_get limit_kind)"
check_eq "  deadline recorded"             "$PRE_UNTIL"     "$(day_get parked_until)"
check_eq "  the probe bound rides the SAME write" "12"      "$(day_get limit_probe_fires_remaining)"
check_eq "  thrash counter incremented"    "1"              "$(day_get consecutive_limit_hits)"
# ...and that record is exactly what §6 recovery re-arms the PROBE from, with
# the stored count rather than a fresh bound.
check_eq "recovery re-arms the probe with the claimed count" \
  "PARK_RECOVERY=rearm_probe fires=12" "$(run_recovery)"

# The wake: no reset time -> the bounded probe, at the cadence, not a one-shot.
OUT=$(NEW_HITS=1 LIMIT_KIND=rolling_window PARK_RESET_KNOWN=false \
      PROBE_CADENCE_MIN=30 PROBE_MAX_FIRES=12 RESET_EPOCH="$(iso_to_epoch "$PRE_UNTIL")" \
      PARKED_UNTIL="$PRE_UNTIL" bash -c "$BLOCK_WAKE" 2>/dev/null)
check_eq "an unknown reset arms the bounded probe" "probe" "$(field "$OUT" WAKE)"
check_eq "  at the cadence, in seconds"            "1800"  "$(field "$OUT" WAKE_SLEEP)"
check_true "  with a probe- generation, not a limit- one" \
  "$( case "$(field "$OUT" WAKE_GENERATION)" in probe-*) echo true ;; *) echo false ;; esac )"
# A known reset still takes the reactive one-shot — the probe is the exception,
# not the new default.
RESET_KNOWN=$(( $(date -u +%s) + 3600 ))
OUT=$(NEW_HITS=1 LIMIT_KIND=rolling_window PARK_RESET_KNOWN=true \
      RESET_EPOCH="$RESET_KNOWN" PARKED_UNTIL="$(epoch_to_iso "$RESET_KNOWN")" \
      bash -c "$BLOCK_WAKE" 2>/dev/null)
check_eq "a known reset still arms the one-shot" "armed" "$(field "$OUT" WAKE)"
# The reactive leg passes no PARK_RESET_KNOWN at all and must be unchanged.
OUT=$(run_wake 1 rolling_window "$RESET_KNOWN")
check_eq "the reactive leg is unchanged by the new branch" "armed" "$(field "$OUT" WAKE)"
# The thrash cap and the weekly branch still outrank the probe branch: a bounded
# probe against a wall that keeps refusing is the hot loop the cap exists to stop.
OUT=$(NEW_HITS=3 LIMIT_KIND=rolling_window PARK_RESET_KNOWN=false \
      PROBE_CADENCE_MIN=30 PROBE_MAX_FIRES=12 RESET_EPOCH="$RESET_KNOWN" \
      PARKED_UNTIL="$(epoch_to_iso "$RESET_KNOWN")" bash -c "$BLOCK_WAKE" 2>/dev/null)
check_eq "the thrash cap outranks the probe branch" "capped" "$(field "$OUT" WAKE)"
OUT=$(NEW_HITS=1 LIMIT_KIND=weekly PARK_RESET_KNOWN=false \
      PROBE_CADENCE_MIN=30 PROBE_MAX_FIRES=12 RESET_EPOCH="$RESET_KNOWN" \
      PARKED_UNTIL="$(epoch_to_iso "$RESET_KNOWN")" bash -c "$BLOCK_WAKE" 2>/dev/null)
check_eq "a weekly cap outranks it too"             "weekly" "$(field "$OUT" WAKE)"

# ---------------------------------------------------------------------------
echo "== Pre-emptive: approaching and unknown change nothing durable =="
# ---------------------------------------------------------------------------
# Test Plan 2 and 3. Neither verdict may write state, so the whole file is
# compared byte for byte around the gate — a park field written and reverted
# would still show up as a differing snapshot.

seed_unparked
BEFORE=$(cat "$STATE_FILE")
run_horizon "$BLOCK_HORIZON" "$(make_horizon_stub approaching)" 200000 1000000 >/dev/null
check_eq "approaching writes no state"  "$BEFORE" "$(cat "$STATE_FILE")"
check_eq "  and leaves the slot unclaimed" "null" "$(day_get limit_cause)"
run_horizon "$BLOCK_HORIZON" "$(make_horizon_stub unknown)" 200000 1000000 >/dev/null
check_eq "unknown writes no state"      "$BEFORE" "$(cat "$STATE_FILE")"
check_eq "  and arms no wake"           "null"    "$(day_get limit_resume_task_id)"
# The queue head is what `approaching` must hold back, and the running
# pipelines are what it must NOT touch — both are stated where the loop reads.
require_text "approaching holds the queue head as well as the backlog" \
  "$DOC" 'no queued chain head, no backlog'
require_text "  while running pipelines keep going" \
  "$DOC" 'Running pipelines are untouched'
require_text "  and in-flight successors still launch" \
  "$DOC" 'A→B and B→C transitions still run'
require_text "the subagent monitor loop gates refill on the verdict" \
  "$SUBAGENT" "Step 0's horizon verdict gates this step"
require_text "  and gates the first dispatch on it too" \
  "$SUBAGENT" 'Check the usage horizon before every one of those launches'

# ---------------------------------------------------------------------------
echo "== Pre-emptive: a park day mode already opened is ADOPTED, never doubled =="
# ---------------------------------------------------------------------------
# Test Plan 4. The claim is the only mutual-exclusion point, so the assertion
# that matters is that the existing record SURVIVES ours untouched.

seed_existing_park preemptive "$(epoch_to_iso $(( NOW + 3600 )))" '"task-daymode"'
OUT=$(PARK_CAUSE=preemptive CLAIM_FIRES=12 PARKED_UNTIL="$PARK_UNTIL_FIX" \
      LIMIT_KIND=rolling_window bash -c "$BLOCK_CLAIM" 2>/dev/null | tail -1)
check_eq "a day-mode pre-emptive park is adopted"  "PARK_CLAIM=adopted" "$OUT"
check_eq "  its deadline is untouched"   "$(epoch_to_iso $(( NOW + 3600 )))" "$(day_get parked_until)"
check_eq "  its wake still owns the slot" "task-daymode" "$(day_get limit_resume_task_id)"
check_eq "  and no second bound was written" "null" "$(day_get limit_probe_fires_remaining)"
# A second Monitor is refused at the identity publish as well — the last
# mutual-exclusion point, so an adopted park cannot register a wake even if the
# thread wrongly reached §4.
OUT=$(LIMIT_MONITOR_TASK_ID='"task-second"' WAKE_GENERATION="probe-second" \
      bash -c "$BLOCK_PUBLISH" 2>/dev/null | tail -1)
check_eq "  a second wake is superseded at publish" "WAKE_PUBLISH=superseded" "$OUT"
check_eq "  the day-mode wake still owns the slot"  "task-daymode" "$(day_get limit_resume_task_id)"
# Day mode claims `parked_until` first (2D.7 Step 1) and only takes
# `limit_cause` when it finishes the record (Step 3); §2 takes both in one write.
# BOTH interleavings must leave exactly one record and one wake. This is AC 4's
# "never double-park" property, driven through the real blocks rather than read.
seed_unparked
# Order A — the subagent claims first; day mode's parked_until compare must lose.
PARK_CAUSE=preemptive CLAIM_FIRES=12 PARKED_UNTIL="$PARK_UNTIL_FIX" \
  LIMIT_KIND=rolling_window bash -c "$BLOCK_CLAIM" >/dev/null 2>&1
DAY_RC=0
"$SESSION_STATE_SH" --cas ".repos[\"$REPO_KEY\"].day.parked_until=\"$(epoch_to_iso $(( NOW + 60 )))\"" \
  --expect null >/dev/null 2>&1 || DAY_RC=$?
check_eq "subagent-first: day mode's parked_until claim loses" "7" "$DAY_RC"
check_eq "  and the subagent's record stands" "preemptive" "$(day_get limit_cause)"
# Order B — day mode claims parked_until first; the subagent's limit_cause
# compare still wins, and day mode's own Step 3 compare is then superseded.
seed_unparked
"$SESSION_STATE_SH" --cas ".repos[\"$REPO_KEY\"].day.parked_until=\"$(epoch_to_iso $(( NOW + 60 )))\"" \
  --expect null --set ".repos[\"$REPO_KEY\"].day.limit_probe_fires_remaining=-1" >/dev/null 2>&1
OUT=$(PARK_CAUSE=preemptive CLAIM_FIRES=12 PARKED_UNTIL="$PARK_UNTIL_FIX" \
      LIMIT_KIND=rolling_window bash -c "$BLOCK_CLAIM" 2>/dev/null | tail -1)
check_eq "daymode-first: the subagent still claims the cause" "PARK_CLAIM=won" "$OUT"
DAY_RC=0
"$SESSION_STATE_SH" --cas ".repos[\"$REPO_KEY\"].day.limit_cause=\"preemptive\"" \
  --expect null >/dev/null 2>&1 || DAY_RC=$?
check_eq "  and day mode's Step 3 compare is superseded" "7" "$DAY_RC"
check_eq "  leaving exactly one cause"      "preemptive" "$(day_get limit_cause)"
check_eq "  and one deadline — the winner's" "$PARK_UNTIL_FIX" "$(day_get parked_until)"
require_text "the decision record documents both interleavings" \
  "$DOC" 'The two claim orders interleave to one record and one wake'

require_text "and the doc says the adoption path arms nothing" \
  "$DOC" 'Skip this step entirely on `adopted`'
# Each wake branch has exactly ONE command, and they must not be confusable:
# wiring the bounded probe to /go-on would resume on its first fire, unbounded.
require_text "the armed branch's command is /go-on --generation" \
  "$DOC" 'Its command is `/go-on --generation`'
require_text "  and the probe branch's is /pm day --probe-wake" \
  "$DOC" 'The probe branch does not print `/go-on`'
require_text "  ending at the same relaunch, not a third route" \
  "$DOC" 'Those are §5.s two entry points'
# A reactive kill that landed first also wins, and the pre-emptive path adopts it
# rather than overwriting the better (vendor-supplied) reset time.
seed_existing_park reactive "$(epoch_to_iso $(( NOW + 900 )))" '"task-reactive"'
OUT=$(PARK_CAUSE=preemptive CLAIM_FIRES=12 PARKED_UNTIL="$PARK_UNTIL_FIX" \
      LIMIT_KIND=rolling_window bash -c "$BLOCK_CLAIM" 2>/dev/null | tail -1)
check_eq "a reactive park is adopted too" "PARK_CLAIM=adopted" "$OUT"
check_eq "  and keeps its vendor reset"   "$(epoch_to_iso $(( NOW + 900 )))" "$(day_get parked_until)"

# ---------------------------------------------------------------------------
echo "== Pre-emptive: wiring, and the #1444 ownership decision (AC 2, 4, 5, 6) =="
# ---------------------------------------------------------------------------

require_text "monitor-mode's per-cycle checklist reads the horizon" \
  "$RULES/monitor-mode.md" 'usage-horizon\.sh --observe'
require_text "  from the harness-printed counter only" \
  "$RULES/monitor-mode.md" 'harness-printed `<total_tokens>`'
require_text "  and routes critical to the park procedure" \
  "$RULES/monitor-mode.md" 'subagent-thread-limit-park\.md` §7'
require_text "the subagent monitor loop reads it every cycle" \
  "$SUBAGENT" 'Read the usage horizon'
require_text "  observing then checking" \
  "$SUBAGENT" 'usage-horizon\.sh --observe'
require_text "  and resolving the script through Step 0" \
  "$SUBAGENT" 'USAGE_HORIZON_SH=\$\(resolve_script usage-horizon\.sh'
require_text "  with a named degraded mode when it does not resolve" \
  "$SUBAGENT" 'usage-horizon\.sh not found \(checked all three paths\)'

# CodeAnt (#1628): the wiring assertions above are presence-only, so a loop that
# kept the strings but moved the gate — or ran --check without --observe — would
# still pass. Pin the POSITION as well: item 0 of each per-cycle checklist,
# ahead of every other item, observing before checking.
check_before "monitor-mode: the horizon read opens the per-cycle checklist" \
  "$RULES/monitor-mode.md" '^Every ~60s, in order:' '^0\. \*\*Usage horizon'
check_before "  and precedes every other item in it" \
  "$RULES/monitor-mode.md" '^0\. \*\*Usage horizon' '^1\. Process completed subagents'
require_text "  observing before checking, on that same line" \
  "$RULES/monitor-mode.md" '^0\. \*\*Usage horizon.*--observe.*--check'
check_before "the subagent monitor loop reads it as item 0 too" \
  "$SUBAGENT" '^### Monitor loop' '^0\. \*\*Read the usage horizon'
check_before "  ahead of processing completed subagents" \
  "$SUBAGENT" '^0\. \*\*Read the usage horizon' '^1\. \*\*Check for completed subagents'
require_text "  observing before branching on --check" \
  "$SUBAGENT" '^0\. \*\*Read the usage horizon.*--observe.*--check'
# Negative control for the ordering matcher: the reversed claim must FAIL, or
# every check_before above would be passing on a comparison that cannot fail.
check_true "negative control — check_before can distinguish order" \
  "$( A="$(line_of "$RULES/monitor-mode.md" '^0\. \*\*Usage horizon')"
      B="$(line_of "$RULES/monitor-mode.md" '^1\. Process completed subagents')"
      [ "$B" -lt "$A" ] && echo false || echo true )"
require_text "the doc pins the counter to the harness value" \
  "$DOC" 'the one the \*\*harness printed\*\*'
require_text "  and forbids substituting a remembered figure" \
  "$DOC" 'Never substitute a remembered figure'
require_text "  and states the cause the pre-emptive leg claims" \
  "$DOC" 'PARK_CAUSE=preemptive'
require_text "  and reuses 2D.7's landing-window and probe knobs" \
  "$DOC" 'CLAUDE_HORIZON_PARK_WINDOW_MINUTES'
require_text "  and says a pre-emptive park is always rolling_window" \
  "$DOC" 'ALWAYS rolling_window'

# AC 4 / #1444: one decision record, naming who may claim and who may only adopt.
require_text "the decision record exists" \
  "$DOC" 'Which loop may park which work'
require_text "  keyed on the limit_cause compare-and-set" \
  "$DOC" 'compare-and-set on `limit_cause`'
require_text "  saying double-parking is unrepresentable, not merely banned" \
  "$DOC" 'it is unrepresentable'
require_text "  and naming #1444's loops as honour-and-adopt only" \
  "$DOC" 'honour and adopt only'
require_text "  and stating the principle it rests on" \
  "$DOC" 'launch ownership, not loop seniority'
require_text "pm-monitoring-decision separates polling from parking" \
  "$REPO_ROOT/.claude/reference/pm-monitoring-decision.md" 'Polling ownership is not park ownership'

# AC 5: both out-of-scope notes now name what is in scope.
require_text "/pm 2D.7 names the newly in-scope loops" \
  "$PM_SKILL" 'Now in scope elsewhere'
# #1444 moved PMM and babysit from "out of scope" to "readers only". Assert the
# NEW sentence and refute the old one — a presence-only check on the section
# would still pass if the out-of-scope claim came back beside the new text.
require_text "  and names #1444's two loops as readers only" \
  "$PM_SKILL" 'Also in scope, as readers only \(#1444\)'
refute_text "  and no longer calls them out of scope" \
  "$PM_SKILL" 'Still out of scope'
refute_text "  and no longer calls the monitor-mode reflex an unfiled follow-up" \
  "$PM_SKILL" 'is a named follow-up, not part of this change'
require_text "pm-day-mode.md's scope boundary is updated" \
  "$REPO_ROOT/.claude/reference/pm-day-mode.md" 'Scope boundary \(updated by #1619, then #1444\)'
refute_text "  and no longer says the follow-up is unfiled" \
  "$REPO_ROOT/.claude/reference/pm-day-mode.md" 'a named follow-up to be filed once this lands'

# AC 6: safety.md's horizon carve-out covers this reader WITHOUT amendment.
refute_text "safety.md was not amended for this reader" \
  "$RULES/safety.md" 'subagent-thread-limit-park'
require_text "  and its horizon carve-out still stands as written" \
  "$RULES/safety.md" 'Horizon carve-out \(#1427\)'
require_text "the doc claims that carve-out rather than widening it" \
  "$DOC" "carve-out \(#1427\) covers this reader"
# No local estimation anywhere in the new procedure.
refute_text "the pre-emptive leg estimates nothing locally" \
  "$DOC" 'estimate the remaining|derive the counter|count the tokens'

# The schema records that a subagent thread can now write a preemptive cause.
require_text "the schema records the pre-emptive subagent-thread writer" \
  "$SCHEMA" 'pre-emptively on its own .critical. usage-horizon verdict' 

# Negative control for this section's matchers: the same files, a pattern that
# was never written. Without it every require_text above could be passing on a
# grep that matches anything.
refute_text "negative control — an unwritten pattern does not match" \
  "$DOC" 'Which loop may park which unicorn'

# ---------------------------------------------------------------------------
echo
echo "== $PASS passed, $FAIL failed =="
[ "$FAIL" -eq 0 ] || exit 1
