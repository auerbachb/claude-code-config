#!/usr/bin/env bash
# Tests the identity-guarded park retirement — issue #1663.
# catalog: tests — Tests the identity-guarded usage-limit park retirement (#1663) against the real fenced bash in `/pause-resume` Step 5 and `/pm` D5 — the reactive claim interleaved between the reads and the retire surviving with its bound and wake intact, each anchor tier actually comparing its own field, the no-identity record still clearing so the #1595 escape hatch cannot deadlock, fail-closed on an unreadable identity, and a negative control proving the pre-fix unconditional clear destroyed the newer park
#
# WHAT IS UNDER TEST
#   The REAL fenced bash in `.claude/skills/pause-resume/SKILL.md` (Step 5) and
#   `.claude/skills/pm/SKILL.md` (2D.6's D5 successful-resume clear), pulled out
#   at run time by `lib/skill-bash.sh` through the `<!-- test-anchor: … -->`
#   markers and run against a real `session-state.sh` driven by a throwaway
#   $HOME. Nothing here is a transcription: edit the document and this suite
#   runs the edit. Same principle as `subagent-limit-park.test.sh`.
#
#     pause-resume-retire-limit-park  the bound identity read + retire_limit_park
#     pause-resume-limit-wake-disarm  both call sites and their three-way case
#     pm-day-d5-resume-clear          D5's successful-resume clear
#
# WHY (issue #1663)
#   Both cleanup writes used to clear the whole park record with an unconditional
#   `--set` batch decided on reads taken earlier in the step. A 2D.6 reactive park
#   claims the slot by compare-and-set on `limit_cause --expect null` and does NOT
#   require `parked_until` to be null, so it can land inside that window — and the
#   clear then erased a park that had just been created, together with its vendor
#   reset time and the wake identity that was the only way to name its Monitor to
#   `TaskStop`. None of that is visible from prose review: the pre-fix code reads
#   as an ordinary cleanup.
#
# NON-VACUITY
#   Every assertion reads the state file back rather than trusting a printed
#   verdict — a block that printed "superseded" while still clearing the record
#   would pass a printed-output-only test. The race case carries an explicit
#   negative control (the pre-fix unconditional `--set` batch, run against the
#   identical interleaved state) proving the newer park IS destroyed without the
#   guard, and each anchor tier is pinned by mutating only the field it claims to
#   compare.
#
# Requires: bash 3.2+ (macOS system bash), jq. Offline: no gh, no git, no network.
set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TEST_DIR/../../.." && pwd)"
PAUSE_RESUME="$REPO_ROOT/.claude/skills/pause-resume/SKILL.md"
PM_SKILL="$REPO_ROOT/.claude/skills/pm/SKILL.md"
DAY_MODE_DOC="$REPO_ROOT/.claude/reference/pm-day-mode.md"
LIMIT_PARK_DOC="$REPO_ROOT/.claude/reference/subagent-thread-limit-park.md"
SESSION_STATE_SH="$REPO_ROOT/.claude/scripts/session-state.sh"

# shellcheck source=lib/skill-bash.sh
source "$TEST_DIR/lib/skill-bash.sh"

TMP_HOME="$(mktemp -d)"
cleanup() { rm -rf "$TMP_HOME"; }
trap cleanup EXIT
export HOME="$TMP_HOME"
mkdir -p "$HOME/.claude"
STATE_FILE="$HOME/.claude/session-state.json"
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
check_ne() {
  local desc="$1" unexpected="$2" actual="$3"
  if [[ "$actual" != "$unexpected" ]]; then
    PASS=$((PASS + 1)); echo "ok   — $desc"
  else
    FAIL=$((FAIL + 1)); echo "FAIL — $desc (value should have changed from '$unexpected')"
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

# Extraction is FATAL on failure: a suite that silently runs zero lines of the
# document passes green forever.
BLOCK_RETIRE="$(extract_skill_bash "$PAUSE_RESUME" pause-resume-retire-limit-park)" || exit 1
BLOCK_DISARM="$(extract_skill_bash "$PAUSE_RESUME" pause-resume-limit-wake-disarm)" || exit 1
BLOCK_D5="$(extract_skill_bash     "$PM_SKILL"     pm-day-d5-resume-clear)"         || exit 1

day_get() { jq -r --arg k "$REPO_KEY" ".repos[\$k].day.$1" "$STATE_FILE"; }

# `/pm` 2D.7 Step 1 caught mid-assembly: bound and kind durable, token held,
# `limit_cause` still null because Step 3 never ran (#1596).
seed_inflight_claim() {  # seed_inflight_claim <token> <parked_until>
  jq -n --arg k "$REPO_KEY" --arg tok "$1" --arg until "$2" \
    '{repos: {($k): {day: {
      active: true, parked_until: $until, limit_kind: "rolling_window",
      limit_cause: null, park_claim_token: $tok,
      limit_probe_fires_remaining: -1, limit_resume_task_id: null,
      limit_resume_generation: null, consecutive_limit_hits: 0}}}}' > "$STATE_FILE"
}
# A completed park with an armed wake — 2D.6's record, or 2D.7 after Step 3.
seed_complete_park() {  # seed_complete_park <cause> <parked_until> <task_id>
  jq -n --arg k "$REPO_KEY" --arg cause "$1" --arg until "$2" --arg task "$3" \
    '{repos: {($k): {day: {
      active: true, parked_until: $until, limit_kind: "rolling_window",
      limit_cause: $cause, park_claim_token: null,
      limit_probe_fires_remaining: null, limit_resume_task_id: $task,
      limit_resume_generation: "limit-gen-1", consecutive_limit_hits: 1}}}}' > "$STATE_FILE"
}
# The legacy / partially-written record the #1595 escape hatch exists for: a bound
# stands, but neither identity field is present at all.
seed_no_identity_park() {  # seed_no_identity_park <parked_until>
  jq -n --arg k "$REPO_KEY" --arg until "$1" \
    '{repos: {($k): {day: {
      active: true, parked_until: $until, limit_kind: null,
      limit_probe_fires_remaining: -1, consecutive_limit_hits: 0}}}}' > "$STATE_FILE"
}
# The pre-#1428 shape `pm-day-mode.md` names explicitly: a live-looking wake
# identity with no cause and no token at all, because `limit_resume_task_id`
# predates `limit_cause` in the schema. It is the one record that reaches the
# armed-wake call site with a null cause, so it is what a reactive claim — which
# needs `limit_cause == null` to win — can actually race there.
seed_legacy_armed_wake() {  # seed_legacy_armed_wake <parked_until> <task_id>
  jq -n --arg k "$REPO_KEY" --arg until "$1" --arg task "$2" \
    '{repos: {($k): {day: {
      active: true, parked_until: $until, limit_kind: "rolling_window",
      limit_resume_task_id: $task, limit_resume_generation: "limit-gen-legacy",
      consecutive_limit_hits: 1}}}}' > "$STATE_FILE"
}
# D5's normal starting point: the park just ended, the slot is empty.
seed_empty_slot() {
  jq -n --arg k "$REPO_KEY" '{repos: {($k): {day: {
      active: true, parked_until: null, limit_kind: null, limit_cause: null,
      park_claim_token: null, limit_probe_fires_remaining: null,
      limit_resume_task_id: null, limit_resume_generation: null,
      consecutive_limit_hits: 3}}}}' > "$STATE_FILE"
}

# The interleaving writers, run BETWEEN the block's bound read and its retire.
# Each is the real claim shape, taken through the real `session-state.sh --cas`,
# so the race is won the way production wins it — not by a hand-written state file.
REACTIVE_CLAIM_CMD='"$SESSION_STATE_SH" \
  --cas ".repos[\"$REPO_KEY\"].day.limit_cause=\"reactive\"" --expect null \
  --set ".repos[\"$REPO_KEY\"].day.parked_until=\"2026-09-11T23:30:00Z\"" \
  --set ".repos[\"$REPO_KEY\"].day.limit_kind=\"rolling_window\"" \
  --set ".repos[\"$REPO_KEY\"].day.limit_probe_fires_remaining=null" \
  --set ".repos[\"$REPO_KEY\"].day.consecutive_limit_hits=1" \
  --set ".repos[\"$REPO_KEY\"].day.park_claim_token=null" \
  --set ".repos[\"$REPO_KEY\"].day.limit_resume_task_id=\"task-reactive-new\"" \
  --set ".repos[\"$REPO_KEY\"].day.limit_resume_generation=\"limit-gen-new\"" >/dev/null 2>&1
echo "INTERLEAVE_RC=$?"'

PREEMPTIVE_CLAIM_CMD='"$SESSION_STATE_SH" \
  --cas ".repos[\"$REPO_KEY\"].day.parked_until=\"2026-09-11T23:45:00Z\"" --expect null \
  --set ".repos[\"$REPO_KEY\"].day.limit_kind=\"rolling_window\"" \
  --set ".repos[\"$REPO_KEY\"].day.limit_probe_fires_remaining=-1" \
  --set ".repos[\"$REPO_KEY\"].day.park_claim_token=\"tok-preemptive-new\"" >/dev/null 2>&1
echo "INTERLEAVE_RC=$?"'

# run_retire <interleave-snippet> — the bound read happens inside the block, the
# interleave lands after it, and only then does the retire write.
run_retire() {
  bash -c "$BLOCK_RETIRE"$'\n'"${1:-:}"$'\n''retire_limit_park; echo "RETIRE_RC=$?"' 2>&1
}

# ---------------------------------------------------------------------------
echo "== The race: a reactive claim between the reads and the retire (AC 5) =="
# ---------------------------------------------------------------------------
seed_inflight_claim "tok-inflight-A" "2026-09-11T22:00:00Z"
OUT="$(run_retire "$REACTIVE_CLAIM_CMD")"
check_eq "the interleaved reactive claim wins its own CAS" "0" "$(field "$OUT" INTERLEAVE_RC)"
check_eq "the retire reports superseded (exit 7)"          "7" "$(field "$OUT" RETIRE_RC)"
check_eq "  the newer park's bound survives"      "2026-09-11T23:30:00Z" "$(day_get parked_until)"
check_eq "  its cause survives"                   "reactive"             "$(day_get limit_cause)"
check_eq "  its kind survives"                    "rolling_window"       "$(day_get limit_kind)"
check_eq "  its wake task id survives"            "task-reactive-new"    "$(day_get limit_resume_task_id)"
check_eq "  its wake generation survives"         "limit-gen-new"        "$(day_get limit_resume_generation)"

# NEGATIVE CONTROL — the pre-#1663 shape, run on the identical interleaved state.
# If this passed too, the guard above would be proving nothing.
seed_inflight_claim "tok-inflight-A" "2026-09-11T22:00:00Z"
OUT="$(bash -c "$REACTIVE_CLAIM_CMD"$'\n''"$SESSION_STATE_SH" \
  --set ".repos[\"$REPO_KEY\"].day.limit_resume_task_id=null" \
  --set ".repos[\"$REPO_KEY\"].day.limit_resume_generation=null" \
  --set ".repos[\"$REPO_KEY\"].day.limit_probe_fires_remaining=null" \
  --set ".repos[\"$REPO_KEY\"].day.limit_cause=null" \
  --set ".repos[\"$REPO_KEY\"].day.limit_kind=null" \
  --set ".repos[\"$REPO_KEY\"].day.park_claim_token=null" \
  --set ".repos[\"$REPO_KEY\"].day.parked_until=null" >/dev/null 2>&1; echo "OLD_RC=$?"' 2>&1)"
check_eq "control: the pre-fix unconditional batch reports success" "0" "$(field "$OUT" OLD_RC)"
check_eq "control: and it DID erase the newer park's bound"    "null" "$(day_get parked_until)"
check_eq "control: and its wake identity with it"              "null" "$(day_get limit_resume_task_id)"

# ---------------------------------------------------------------------------
echo "== Anchor selection: each tier compares its own field (AC 1) =="
# ---------------------------------------------------------------------------
# Mid-claim -> the TOKEN is the anchor. Change only the token and nothing else:
# a cause- or bound-anchored clear would still win here.
seed_inflight_claim "tok-inflight-B" "2026-09-11T22:00:00Z"
OUT="$(run_retire '"$SESSION_STATE_SH" --set ".repos[\"$REPO_KEY\"].day.park_claim_token=\"tok-other\"" >/dev/null 2>&1')"
check_eq "a changed token alone supersedes the clear" "7" "$(field "$OUT" RETIRE_RC)"
check_eq "  the other claim's token is left alone"    "tok-other" "$(day_get park_claim_token)"

seed_inflight_claim "tok-inflight-C" "2026-09-11T22:00:00Z"
OUT="$(run_retire)"
check_eq "an untouched mid-claim record clears (exit 0)" "0" "$(field "$OUT" RETIRE_RC)"
check_eq "  token cleared"        "null" "$(day_get park_claim_token)"
check_eq "  bound cleared"        "null" "$(day_get parked_until)"
check_eq "  probe bound cleared"  "null" "$(day_get limit_probe_fires_remaining)"
check_eq "  kind cleared"         "null" "$(day_get limit_kind)"

# Completed record -> `limit_cause` is the anchor. Change only the cause.
seed_complete_park "reactive" "2026-09-11T22:00:00Z" "task-old"
OUT="$(run_retire '"$SESSION_STATE_SH" --set ".repos[\"$REPO_KEY\"].day.limit_cause=\"preemptive\"" >/dev/null 2>&1')"
check_eq "a changed cause alone supersedes the clear" "7" "$(field "$OUT" RETIRE_RC)"
check_eq "  the surviving cause is untouched" "preemptive" "$(day_get limit_cause)"

seed_complete_park "reactive" "2026-09-11T22:00:00Z" "task-old"
OUT="$(run_retire)"
check_eq "an untouched complete record clears (exit 0)" "0" "$(field "$OUT" RETIRE_RC)"
check_eq "  cause cleared"          "null" "$(day_get limit_cause)"
check_eq "  wake task id cleared"   "null" "$(day_get limit_resume_task_id)"
check_eq "  wake generation cleared" "null" "$(day_get limit_resume_generation)"

# ---------------------------------------------------------------------------
echo "== The #1595 escape hatch: a no-identity record still clears (AC 2) =="
# ---------------------------------------------------------------------------
seed_no_identity_park "2026-09-11T22:00:00Z"
OUT="$(run_retire)"
check_eq "neither identity present, bound set -> cleared" "0" "$(field "$OUT" RETIRE_RC)"
check_eq "  the deadlocked bound is gone"       "null" "$(day_get parked_until)"
check_eq "  and so is the -1 sentinel"          "null" "$(day_get limit_probe_fires_remaining)"

# …and it is still refused when the slot changed hands, which is the whole point
# of anchoring the no-identity tier on `parked_until` rather than writing blind.
seed_no_identity_park "2026-09-11T22:00:00Z"
OUT="$(run_retire '"$SESSION_STATE_SH" --set ".repos[\"$REPO_KEY\"].day.parked_until=\"2026-09-11T23:59:00Z\"" >/dev/null 2>&1')"
check_eq "a no-identity record whose bound moved is superseded" "7" "$(field "$OUT" RETIRE_RC)"
check_eq "  the newer bound survives" "2026-09-11T23:59:00Z" "$(day_get parked_until)"

# ---------------------------------------------------------------------------
echo "== Fail closed: an unreadable identity clears nothing =="
# ---------------------------------------------------------------------------
printf '%s' 'not json at all' > "$STATE_FILE"
OUT="$(run_retire)"
check_eq "an unreadable record returns 8, not a clear" "8" "$(field "$OUT" RETIRE_RC)"
check_eq "  and the file is left exactly as found" "not json at all" "$(cat "$STATE_FILE")"

# ---------------------------------------------------------------------------
echo "== Both call sites route through the guarded path (AC 4) =="
# ---------------------------------------------------------------------------
# Static: neither site may test the helper's exit status inline again, which is
# what discards the distinct superseded verdict.
check_eq "the disarm block captures the retire rc twice (both sites)" "2" \
  "$(printf '%s\n' "$BLOCK_DISARM" | grep -c 'retire_limit_park || RETIRE_RC=\$?')"
check_eq "  and no site tests it as a bare condition" "0" \
  "$(printf '%s\n' "$BLOCK_DISARM" | grep -Ec '(if|elif) +retire_limit_park')"
check_eq "  both sites carry a superseded arm" "2" \
  "$(printf '%s\n' "$BLOCK_DISARM" | grep -cE '^ *7\)')"

# Functional, armed-wake site: a reactive claim lands after the identity read, so
# the stop still runs on the OLD id and the retire must leave the new park alone.
seed_legacy_armed_wake "2026-09-11T22:00:00Z" "task-old-wake"
OUT="$(bash -c 'TaskStop() { echo "STOPPED=$1"; return 0; }'$'\n'"$BLOCK_RETIRE"$'\n'"$REACTIVE_CLAIM_CMD"$'\n'"$BLOCK_DISARM"$'\n''echo "RESOLVED=$LIMIT_WAKE_RESOLVED"' 2>&1)"
check_eq "armed-wake site stops the wake it read"   "task-old-wake" "$(field "$OUT" STOPPED)"
check_eq "  and treats the supersession as resolved" "true"         "$(field "$OUT" RESOLVED)"
case "$OUT" in
  *"newer usage-limit park now owns the slot"*)
    PASS=$((PASS + 1)); echo "ok   — armed-wake site reports the supersession in one line" ;;
  *) FAIL=$((FAIL + 1)); echo "FAIL — armed-wake site did not report the supersession: $OUT" ;;
esac
check_eq "  the newer park's bound is intact" "2026-09-11T23:30:00Z" "$(day_get parked_until)"
check_eq "  the newer park's wake is intact"  "task-reactive-new"    "$(day_get limit_resume_task_id)"

# Functional, no-wake standing-park site: no armed wake, a rolling-window park
# stands, and a claim lands in the window.
seed_inflight_claim "tok-inflight-D" "2026-09-11T22:00:00Z"
OUT="$(bash -c 'TaskStop() { return 0; }'$'\n'"$BLOCK_RETIRE"$'\n'"$REACTIVE_CLAIM_CMD"$'\n'"$BLOCK_DISARM"$'\n''echo "RESOLVED=$LIMIT_WAKE_RESOLVED"' 2>&1)"
case "$OUT" in
  *"newer usage-limit park now owns the slot"*)
    PASS=$((PASS + 1)); echo "ok   — no-wake site reports the supersession in one line" ;;
  *) FAIL=$((FAIL + 1)); echo "FAIL — no-wake site did not report the supersession: $OUT" ;;
esac
check_eq "  no-wake site leaves the newer park standing" "2026-09-11T23:30:00Z" "$(day_get parked_until)"

# And the ordinary path still clears and still says so.
seed_inflight_claim "tok-inflight-E" "2026-09-11T22:00:00Z"
OUT="$(bash -c 'TaskStop() { return 0; }'$'\n'"$BLOCK_RETIRE"$'\n'"$BLOCK_DISARM" 2>&1)"
case "$OUT" in
  *"cleared standing usage-limit park"*)
    PASS=$((PASS + 1)); echo "ok   — an uncontested standing park still clears and reports it" ;;
  *) FAIL=$((FAIL + 1)); echo "FAIL — uncontested standing park did not report a clear: $OUT" ;;
esac
check_eq "  and the record is actually empty" "null" "$(day_get parked_until)"

# ---------------------------------------------------------------------------
echo "== The branches the one-snapshot restructure absorbed still fire (#1595) =="
# ---------------------------------------------------------------------------
# The per-field `--get`s for the wake id, the bound and the kind are gone; every
# branch they gated now reads the single snapshot. A restructure that quietly
# stopped firing one of them would pass every test above, so each is pinned here.
run_disarm() { bash -c 'TaskStop() { return 0; }'$'\n'"$BLOCK_RETIRE"$'\n'"$BLOCK_DISARM"$'\n''echo "RESOLVED=$LIMIT_WAKE_RESOLVED"' 2>&1; }

rm -f "$STATE_FILE"
OUT="$(run_disarm)"
check_eq "no state file at all -> resolved, nothing said" "true" "$(field "$OUT" RESOLVED)"
refute_text "  and no DEGRADED line" <(printf '%s\n' "$OUT") 'DEGRADED'

printf '%s' 'not json at all' > "$STATE_FILE"
OUT="$(run_disarm)"
check_eq "an unreadable record -> NOT resolved" "false" "$(field "$OUT" RESOLVED)"
require_text "  and it says so once, fail closed" <(printf '%s\n' "$OUT") \
  'DEGRADED: could not read the day park record'
check_eq "  the file is untouched" "not json at all" "$(cat "$STATE_FILE")"

jq -n --arg k "$REPO_KEY" '{repos: {($k): {day: {
    active: true, parked_until: "2026-09-18T00:00:00Z", limit_kind: "weekly",
    limit_cause: "reactive", park_claim_token: null,
    limit_probe_fires_remaining: null, limit_resume_task_id: null,
    limit_resume_generation: null, consecutive_limit_hits: 2}}}}' > "$STATE_FILE"
OUT="$(run_disarm)"
require_text "a weekly park is still left standing" <(printf '%s\n' "$OUT") \
  'limit_kind=weekly is not rolling_window'
check_eq "  its bound is untouched" "2026-09-18T00:00:00Z" "$(day_get parked_until)"
check_eq "  and the resume is NOT marked resolved" "false" "$(field "$OUT" RESOLVED)"

# ---------------------------------------------------------------------------
echo "== /pm D5's successful-resume clear (AC 6, AC 8) =="
# ---------------------------------------------------------------------------
run_d5() {  # run_d5 <interleave-snippet>
  bash -c "$BLOCK_D5_PREFIX"$'\n'"${1:-:}"$'\n'"$BLOCK_D5_SUFFIX" 2>&1
}
# D5's block is one unit: the read, the interleave, and the write must be spliced
# at the read/write seam, so the snippet lands exactly where a sibling thread's
# claim would. The seam is the `if [[ "$D5_CLEAR_RC" -eq 0 ]]` line that opens the
# write half — splitting on it keeps BOTH halves real skill bash.
D5_SEAM='if [[ "$D5_CLEAR_RC" -eq 0 ]]; then'
BLOCK_D5_PREFIX="$(printf '%s\n' "$BLOCK_D5" | awk -v seam="$D5_SEAM" 'index($0, seam) { exit } { print }')"
BLOCK_D5_SUFFIX="$(printf '%s\n' "$BLOCK_D5" | awk -v seam="$D5_SEAM" 'found { print } index($0, seam) { found = 1; print }')"
if [[ -n "$BLOCK_D5_PREFIX" && -n "$BLOCK_D5_SUFFIX" ]]; then
  PASS=$((PASS + 1)); echo "ok   — D5's block splits at its read/write seam"
else
  FAIL=$((FAIL + 1)); echo "FAIL — D5's block no longer carries the read/write seam ($D5_SEAM)"
fi

# AC 8 — a 2D.7 Step 1 claim takes the empty slot between D5's read and its clear.
seed_empty_slot
OUT="$(run_d5 "$PREEMPTIVE_CLAIM_CMD")"
check_eq "the interleaved 2D.7 claim wins its own CAS" "0" "$(field "$OUT" INTERLEAVE_RC)"
check_eq "D5 reports superseded"  "superseded" "$(field "$OUT" RESUME_CLEAR)"
check_eq "  the new claim's bound survives"  "2026-09-11T23:45:00Z" "$(day_get parked_until)"
check_eq "  its token survives"              "tok-preemptive-new"   "$(day_get park_claim_token)"
check_eq "  its -1 sentinel survives"        "-1"                   "$(day_get limit_probe_fires_remaining)"
check_ne "  and the thrash counter was NOT reset with it" "0" "$(day_get consecutive_limit_hits)"

# The uncontested path: the slot really is empty, so the clear lands.
seed_empty_slot
OUT="$(run_d5)"
check_eq "an uncontested D5 clear reports cleared" "cleared" "$(field "$OUT" RESUME_CLEAR)"
check_eq "  and resets the thrash counter"         "0" "$(day_get consecutive_limit_hits)"

# A record still holding a completed park clears on the cause anchor.
seed_complete_park "reactive" "2026-09-11T22:00:00Z" "task-old"
OUT="$(run_d5)"
check_eq "D5 clears a completed record too" "cleared" "$(field "$OUT" RESUME_CLEAR)"
check_eq "  bound cleared"        "null" "$(day_get parked_until)"
check_eq "  wake identity cleared" "null" "$(day_get limit_resume_task_id)"

# Fail closed.
printf '%s' 'not json at all' > "$STATE_FILE"
OUT="$(run_d5)"
check_eq "an unreadable record makes D5 fail closed" "error rc=8" "$(field "$OUT" RESUME_CLEAR)"
check_eq "  leaving the file as found" "not json at all" "$(cat "$STATE_FILE")"

# ---------------------------------------------------------------------------
echo "== One documented contract, pointed at from both sites (AC 7) =="
# ---------------------------------------------------------------------------
require_text "pm-day-mode.md defines the shared contract" "$DAY_MODE_DOC" \
  '### The park-retirement contract'
require_text "  it names the exit-7 superseded obligation" "$DAY_MODE_DOC" \
  'superseded'
require_text "  and the #1595 no-identity carve-out"       "$DAY_MODE_DOC" \
  '#1595'
require_text "/pause-resume points at it"  "$PAUSE_RESUME" 'park-retirement contract'
require_text "/pm D5 points at it"         "$PM_SKILL"     'park-retirement contract'
require_text "the limit-park reference records the guard" "$LIMIT_PARK_DOC" \
  'compare-and-set on the identity'
refute_text  "pm-day-mode.md no longer describes #1663 as unlanded" "$DAY_MODE_DOC" \
  'Guarding them is issue #1663'

# ---------------------------------------------------------------------------
echo
echo "Passed: $PASS   Failed: $FAIL"
[[ "$FAIL" -eq 0 ]] || exit 1
