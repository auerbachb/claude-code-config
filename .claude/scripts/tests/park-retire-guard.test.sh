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
mkdir -p "$HOME/.claude/scripts"
# Fixtures install the same trusted helper locations as production.
ln -s "$REPO_ROOT/.claude/scripts/park-generation.sh" "$HOME/.claude/scripts/park-generation.sh"
ln -s "$REPO_ROOT/.claude/scripts/park-retire.sh" "$HOME/.claude/scripts/park-retire.sh"
STATE_FILE="$HOME/.claude/session-state.json"
REPO_KEY="auerbachb/claude-code-config"
PARK_RETIRE_SH="$REPO_ROOT/.claude/scripts/park-retire.sh"
export SESSION_STATE_SH REPO_KEY PARK_RETIRE_SH

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
echo "== The no-wake fast path turns on record PRESENCE, not the bound =="
# ---------------------------------------------------------------------------
# `/pm` 2D.1(b+) and 2D.5 keep the day parked on a `preemptive` cause with a
# `0`/`-1` bound REGARDLESS of `parked_until` — the invariant Step 5 opens with.
# So a present record whose bound is null is a live park, not an empty slot, and
# skipping it here marks the resume resolved while the park it is the escape
# hatch for (#1595) stays standing: a deadlock wearing a success message.
seed_present_null_bound_park() {  # seed_present_null_bound_park <cause> <probe-bound>
  jq -n --arg k "$REPO_KEY" --arg cause "$1" --argjson probe "$2" \
    '{repos: {($k): {day: {
      active: true, parked_until: null, limit_kind: null,
      limit_cause: $cause, park_claim_token: null,
      limit_probe_fires_remaining: $probe, limit_resume_task_id: null,
      limit_resume_generation: null, consecutive_limit_hits: 2}}}}' > "$STATE_FILE"
}

for PROBE in -1 0; do
  seed_present_null_bound_park "preemptive" "$PROBE"
  OUT="$(run_disarm)"
  check_eq "a present preemptive park (bound null, probe $PROBE) is retired, not skipped" \
    "null" "$(day_get limit_cause)"
  check_eq "  its probe bound is cleared too (probe $PROBE)" "null" "$(day_get limit_probe_fires_remaining)"
  check_eq "  and the resume IS marked resolved (probe $PROBE)" "true" "$(field "$OUT" RESOLVED)"
  require_text "  and it says the park was cleared (probe $PROBE)" <(printf '%s\n' "$OUT") \
    'cleared standing usage-limit park'
done

# NEGATIVE CONTROL — the pre-fix condition, run on the identical state. If this
# passed too, the presence check above would be proving nothing.
seed_present_null_bound_park "preemptive" -1
OUT="$(bash -c 'TaskStop() { return 0; }'$'\n'"$BLOCK_RETIRE"$'\n''PARKED_UNTIL_OLD="$PARKED_UNTIL"
if [[ -z "$PARKED_UNTIL_OLD" || "$PARKED_UNTIL_OLD" == "null" ]]; then
  echo "OLD_RESOLVED=true"
else
  echo "OLD_RESOLVED=false"
fi' 2>&1)"
check_eq "control: the pre-fix bound test calls this present park absent" "true" \
  "$(field "$OUT" OLD_RESOLVED)"
check_eq "control: and it would have left the cause standing" "preemptive" "$(day_get limit_cause)"

# …and a genuinely empty slot still short-circuits without a spurious clear line.
seed_empty_slot
OUT="$(run_disarm)"
check_eq "an empty slot is still resolved with no retire" "true" "$(field "$OUT" RESOLVED)"
refute_text "  and says nothing about clearing a park" <(printf '%s\n' "$OUT") \
  'cleared standing usage-limit park'

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
echo "== #1715 durable generation: ABA and legacy-to-generated replacement =="
# ---------------------------------------------------------------------------
OLD_RETIRE=$(extract_skill_bash "$TEST_DIR/fixtures/park-retire-pre1715.md" old-retire) || exit 1
OLD_D5=$(extract_skill_bash "$TEST_DIR/fixtures/park-retire-pre1715.md" old-d5) || exit 1
OLD_D5_PREFIX=$(printf '%s\n' "$OLD_D5" | awk -v seam="$D5_SEAM" 'index($0, seam) { exit } { print }')
OLD_D5_SUFFIX=$(printf '%s\n' "$OLD_D5" | awk -v seam="$D5_SEAM" 'found { print } index($0, seam) { found = 1; print }')
run_old_retire() { local BLOCK_RETIRE="$OLD_RETIRE"; run_retire "$1"; }
run_old_d5() { local BLOCK_D5_PREFIX="$OLD_D5_PREFIX" BLOCK_D5_SUFFIX="$OLD_D5_SUFFIX"; run_d5 "$1"; }
aba_interleave() {
  case "$1" in
    *cause) cat <<'ABA_CAUSE'
"$SESSION_STATE_SH" --set ".repos[\"$REPO_KEY\"].day.limit_cause=null" >/dev/null
"$SESSION_STATE_SH" --cas ".repos[\"$REPO_KEY\"].day.limit_cause=\"reactive\"" --expect null --set ".repos[\"$REPO_KEY\"].day.park_generation=\"generation-replacement\"" >/dev/null
ABA_CAUSE
      ;;
    *bound) cat <<'ABA_BOUND'
"$SESSION_STATE_SH" --set ".repos[\"$REPO_KEY\"].day.parked_until=null" >/dev/null
"$SESSION_STATE_SH" --cas ".repos[\"$REPO_KEY\"].day.parked_until=\"2026-09-11T22:00:00Z\"" --expect null --set ".repos[\"$REPO_KEY\"].day.park_generation=\"generation-replacement\"" >/dev/null
ABA_BOUND
      ;;
  esac
}
for SITE in retire d5; do
  for SHAPE in generated-cause generated-bound legacy-cause legacy-bound; do
    case "$SHAPE" in
      *cause) seed_complete_park reactive 2026-09-11T22:00:00Z task-original ;;
      *bound) seed_no_identity_park 2026-09-11T22:00:00Z ;;
    esac
    if [[ "$SHAPE" == generated-* ]]; then
      "$SESSION_STATE_SH" --set ".repos[\"$REPO_KEY\"].day.park_generation=\"generation-original\"" >/dev/null
    fi
    HITS_BEFORE=$(day_get consecutive_limit_hits)
    TASK_BEFORE=$(day_get limit_resume_task_id); WAKE_BEFORE=$(day_get limit_resume_generation)
    KIND_BEFORE=$(day_get limit_kind)
    ABA_CMD=$(aba_interleave "$SHAPE")
    if [[ "$SITE" == retire ]]; then
      OUT=$(run_retire "$ABA_CMD")
      check_eq "$SITE $SHAPE: loses original snapshot" 7 "$(field "$OUT" RETIRE_RC)"
    else
      OUT=$(run_d5 "$ABA_CMD")
      check_eq "$SITE $SHAPE: loses original snapshot" superseded "$(field "$OUT" RESUME_CLEAR)"
    fi
    check_eq "$SITE $SHAPE: new generation preserved" generation-replacement "$(day_get park_generation)"
    check_eq "$SITE $SHAPE: same timestamp preserved" 2026-09-11T22:00:00Z "$(day_get parked_until)"
    check_eq "$SITE $SHAPE: hits unchanged" "$HITS_BEFORE" "$(day_get consecutive_limit_hits)"
    check_eq "$SITE $SHAPE: wake task unchanged" "$TASK_BEFORE" "$(day_get limit_resume_task_id)"
    check_eq "$SITE $SHAPE: wake generation unchanged" "$WAKE_BEFORE" "$(day_get limit_resume_generation)"
    check_eq "$SITE $SHAPE: kind unchanged" "$KIND_BEFORE" "$(day_get limit_kind)"
  done
  for SHAPE in cause bound; do
    case "$SHAPE" in
      cause) seed_complete_park reactive 2026-09-11T22:00:00Z task-original ;;
      bound) seed_no_identity_park 2026-09-11T22:00:00Z ;;
    esac
    "$SESSION_STATE_SH" --set ".repos[\"$REPO_KEY\"].day.park_generation=\"generation-original\"" >/dev/null
    ABA_CMD=$(aba_interleave "$SHAPE")
    if [[ "$SITE" == retire ]]; then
      OUT=$(run_old_retire "$ABA_CMD")
      check_eq "negative $SITE $SHAPE: old anchor wrongly clears" 0 "$(field "$OUT" RETIRE_RC)"
    else
      OUT=$(run_old_d5 "$ABA_CMD")
      check_eq "negative $SITE $SHAPE: old anchor wrongly clears" cleared "$(field "$OUT" RESUME_CLEAR)"
    fi
    check_eq "negative $SITE $SHAPE: replacement bound destroyed" null "$(day_get parked_until)"
  done
  seed_complete_park reactive 2026-09-11T22:00:00Z task-original
  "$SESSION_STATE_SH" --set ".repos[\"$REPO_KEY\"].day.park_generation=\"generation-original\"" \
    --set ".repos[\"$REPO_KEY\"].day.unrelated={\"flag\":false,\"counter\":0}" >/dev/null
  if [[ "$SITE" == retire ]]; then OUT=$(run_retire); else OUT=$(run_d5); fi
  check_eq "$SITE: owned durable generation retired" null "$(day_get park_generation)"
  check_eq "$SITE: unrelated metadata retained" '{"flag":false,"counter":0}' \
    "$(jq -c --arg k "$REPO_KEY" '.repos[$k].day.unrelated' "$STATE_FILE")"
  for INVALID in false 0 '""' '"null"' '{}' '[]'; do
    seed_complete_park reactive 2026-09-11T22:00:00Z task-original
    "$SESSION_STATE_SH" --set ".repos[\"$REPO_KEY\"].day.park_generation=$INVALID" >/dev/null
    BEFORE=$(cat "$STATE_FILE")
    if [[ "$SITE" == retire ]]; then
      OUT=$(run_retire)
      check_eq "$SITE: malformed generation $INVALID refuses" 8 "$(field "$OUT" RETIRE_RC)"
    else
      OUT=$(run_d5)
      check_eq "$SITE: malformed generation $INVALID refuses" 'error rc=8' "$(field "$OUT" RESUME_CLEAR)"
    fi
    check_eq "$SITE: malformed generation leaves state untouched" "$BEFORE" "$(cat "$STATE_FILE")"
  done
 done

# Metadata-only losses must not masquerade as a new owner after TaskStop.
# The shim interleaves through the REAL state writer before the actual CAS,
# including a second race after the helper's bounded metadata refresh.
REAL_SESSION_STATE_SH="$SESSION_STATE_SH"
export REAL_SESSION_STATE_SH
RACE_SH="$TMP_HOME/retire-race.sh"
RACE_COUNT="$TMP_HOME/retire-cas-count"
export RACE_COUNT RACE_MODE
cat > "$RACE_SH" <<'RACE_HELPER'
#!/usr/bin/env bash
set -uo pipefail
path=".repos[\"$REPO_KEY\"].day"
case " $* " in
  *' --cas '*)
    count=0; [[ ! -f "$RACE_COUNT" ]] || read -r count < "$RACE_COUNT"
    count=$((count + 1)); printf '%s\n' "$count" > "$RACE_COUNT"
    case "$RACE_MODE:$count" in
      single:1|churn:*|replacement:1|tuple:1|hits:1|legacy:1|read-error:1|read-lock:1|malformed:1)
        "$REAL_SESSION_STATE_SH" --set "$path.unrelated_counter=$count" >/dev/null || exit 9 ;;
    esac
    case "$RACE_MODE:$count" in
      replacement:2)
        "$REAL_SESSION_STATE_SH" --set "$path.park_generation=\"replacement\"" \
          --set "$path.limit_kind=\"weekly\"" --set "$path.parked_until=\"new-bound\"" \
          --set "$path.limit_resume_generation=\"new-wake\"" \
          --set "$path.consecutive_limit_hits=9" >/dev/null || exit 9 ;;
      tuple:1)
        "$REAL_SESSION_STATE_SH" --set "$path.limit_resume_generation=\"changed-same-owner\"" >/dev/null || exit 9 ;;
      hits:1)
        "$REAL_SESSION_STATE_SH" --set "$path.consecutive_limit_hits=8" >/dev/null || exit 9 ;;
      lock:1) exit 6 ;;
    esac ;;
  *' --get-json '*)
    if [[ -f "$RACE_COUNT" ]]; then
      case "$RACE_MODE" in
        read-error) exit 4 ;;
        malformed) printf '%s\n' '{"park_generation":false}'; exit 0 ;;
        read-lock)
          if [[ ! -f "$RACE_COUNT.read" ]]; then touch "$RACE_COUNT.read"; exit 6; fi ;;
      esac
    fi ;;
esac
exec "$REAL_SESSION_STATE_SH" "$@"
RACE_HELPER
chmod +x "$RACE_SH"
INITIAL_FIXTURE="$TEST_DIR/fixtures/park-retire-initial1715.md"
INITIAL_RETIRE=$(extract_skill_bash "$INITIAL_FIXTURE" pause-resume-retire-limit-park) || exit 1
INITIAL_D5=$(extract_skill_bash "$INITIAL_FIXTURE" pm-day-d5-resume-clear) || exit 1
INITIAL_D5_PREFIX=$(printf '%s\n' "$INITIAL_D5" | awk -v seam="$D5_SEAM" 'index($0, seam) { exit } { print }')
INITIAL_D5_SUFFIX=$(printf '%s\n' "$INITIAL_D5" | awk -v seam="$D5_SEAM" 'found { print } index($0, seam) { found = 1; print }')
for SITE in disarm d5; do
  for RACE_MODE in single churn replacement tuple hits legacy read-error read-lock malformed lock; do
    seed_complete_park reactive 2026-09-11T22:00:00Z task-original
    if [[ "$RACE_MODE" != legacy ]]; then
      "$REAL_SESSION_STATE_SH" --set ".repos[\"$REPO_KEY\"].day.park_generation=\"original\"" >/dev/null
    fi
    rm -f "$RACE_COUNT" "$RACE_COUNT.read"
    SESSION_STATE_SH="$RACE_SH"
    if [[ "$SITE" == disarm ]]; then OUT=$(run_disarm); else OUT=$(run_d5); fi
    SESSION_STATE_SH="$REAL_SESSION_STATE_SH"
    case "$RACE_MODE" in
      single|read-lock|lock)
        check_eq "$SITE $RACE_MODE: original park cleared" null "$(day_get parked_until)"
        check_eq "$SITE $RACE_MODE: generation retired" null "$(day_get park_generation)"
        if [[ "$SITE" == disarm ]]; then
          check_eq "$SITE $RACE_MODE: resolved only after clear" true "$(field "$OUT" RESOLVED)"
        else
          check_eq "$SITE $RACE_MODE: reports clear" cleared "$(field "$OUT" RESUME_CLEAR)"
          check_eq "$SITE $RACE_MODE: hit reset committed" 0 "$(day_get consecutive_limit_hits)"
        fi
        if [[ "$RACE_MODE" != lock ]]; then
          check_eq "$SITE $RACE_MODE: updated metadata preserved" 1 "$(day_get unrelated_counter)"
        fi ;;
      replacement)
        for pair in 'park_generation replacement' 'parked_until new-bound' 'limit_kind weekly' 'limit_resume_generation new-wake' 'consecutive_limit_hits 9'; do
          check_eq "$SITE replacement: ${pair%% *} preserved" "${pair#* }" "$(day_get "${pair%% *}")"
        done
        if [[ "$SITE" == d5 ]]; then check_eq 'D5 replacement: honest supersession' superseded "$(field "$OUT" RESUME_CLEAR)"; fi ;;
      *)
        check_eq "$SITE $RACE_MODE: original bound retained" 2026-09-11T22:00:00Z "$(day_get parked_until)"
        check_eq "$SITE $RACE_MODE: hit count retained" "$(if [[ "$RACE_MODE" == hits ]]; then echo 8; else echo 1; fi)" "$(day_get consecutive_limit_hits)"
        if [[ "$SITE" == disarm ]]; then
          check_eq "$SITE $RACE_MODE: unresolved after stopped wake" false "$(field "$OUT" RESOLVED)"
          require_text "$SITE $RACE_MODE: reports uncertainty" <(printf '%s\n' "$OUT") 'DEGRADED'
        else
          EXPECT_RC=5
          case "$RACE_MODE" in read-error|malformed) EXPECT_RC=8 ;; esac
          check_eq "$SITE $RACE_MODE: honest failure status" "error rc=$EXPECT_RC" "$(field "$OUT" RESUME_CLEAR)"
        fi
        if [[ "$RACE_MODE" == tuple ]]; then
          check_eq "$SITE: same-generation new wake untouched" changed-same-owner "$(day_get limit_resume_generation)"
        fi ;;
    esac
    EXPECT_CAS_COUNT=1
    case "$RACE_MODE" in single|churn|replacement|read-lock|lock) EXPECT_CAS_COUNT=2 ;; esac
    if [[ "$SITE" == disarm ]]; then
      case "$RACE_MODE" in churn) EXPECT_CAS_COUNT=3 ;; *) EXPECT_CAS_COUNT=2 ;; esac
    fi
    check_eq "$SITE $RACE_MODE: bounded CAS count" "$EXPECT_CAS_COUNT" "$(cat "$RACE_COUNT")"
  done
  # Published initial fences actually return a misleading superseded outcome.
  seed_complete_park reactive 2026-09-11T22:00:00Z task-original
  "$REAL_SESSION_STATE_SH" --set ".repos[\"$REPO_KEY\"].day.park_generation=\"original\"" >/dev/null
  RACE_MODE=single; rm -f "$RACE_COUNT"
  SESSION_STATE_SH="$RACE_SH"
  if [[ "$SITE" == disarm ]]; then
    OUT=$(BLOCK_RETIRE="$INITIAL_RETIRE" run_disarm)
    check_eq 'negative published initial resume: falsely resolved' true "$(field "$OUT" RESOLVED)"
  else
    OUT=$(BLOCK_D5_PREFIX="$INITIAL_D5_PREFIX" BLOCK_D5_SUFFIX="$INITIAL_D5_SUFFIX" run_d5)
    check_eq 'negative published initial D5: false supersession' superseded "$(field "$OUT" RESUME_CLEAR)"
  fi
  SESSION_STATE_SH="$REAL_SESSION_STATE_SH"
  check_eq "$SITE negative: initial fence stranded original park" 2026-09-11T22:00:00Z "$(day_get parked_until)"
done

# Minting is real OS entropy, not clock/PID/RANDOM fallback. An entropy failure
# must be visible before any of the three actual producer fences can claim.
GENERATOR="$REPO_ROOT/.claude/scripts/park-generation.sh"
G1=$(bash "$GENERATOR"); G2=$(bash "$GENERATOR")
check_ne 'successive OS-entropy generations differ' "$G1" "$G2"
if [[ "$G1" =~ ^parkgen-[0-9a-f]{32}$ && "$G2" =~ ^parkgen-[0-9a-f]{32}$ ]]; then
  PASS=$((PASS + 1)); echo 'ok   — durable generation has 128 entropy bits'
else FAIL=$((FAIL + 1)); echo 'FAIL — durable generation shape'; fi
mkdir -p "$TMP_HOME/entropy-fail"
printf '%s\n' '#!/bin/sh' 'exit 1' > "$TMP_HOME/entropy-fail/od"
chmod +x "$TMP_HOME/entropy-fail/od"
BLOCK_REACTIVE=$(extract_skill_bash "$PM_SKILL" pm-day-2d6-park-claim) || exit 1
BLOCK_PREEMPTIVE=$(extract_skill_bash "$PM_SKILL" pm-day-2d7-park-claim) || exit 1
BLOCK_SUBAGENT=$(extract_skill_bash "$LIMIT_PARK_DOC" subagent-limit-park-claim) || exit 1
for PRODUCER in reactive preemptive subagent; do
  seed_empty_slot
  BEFORE=$(cat "$STATE_FILE")
  case "$PRODUCER" in reactive) CLAIM_BLOCK="$BLOCK_REACTIVE" ;; preemptive) CLAIM_BLOCK="$BLOCK_PREEMPTIVE" ;; subagent) CLAIM_BLOCK="$BLOCK_SUBAGENT" ;; esac
  OUT=$(PATH="$TMP_HOME/entropy-fail:$PATH" NEW_HITS=1 PARKED_UNTIL=2026-12-01T23:00:00Z \
    LIMIT_KIND=rolling_window HORIZON_RESET_EPOCH="$(( $(date -u +%s) + 3600 ))" \
    PROBE_CADENCE_MIN=30 PROBE_MAX_FIRES=12 bash -c "$CLAIM_BLOCK" 2>&1)
  check_eq "$PRODUCER: entropy failure claims nothing" 'PARK_CLAIM=error rc=generation' "$(printf '%s\n' "$OUT" | sed -n '/^PARK_CLAIM=/{p;q;}')"
  check_eq "$PRODUCER: entropy failure writes nothing" "$BEFORE" "$(cat "$STATE_FILE")"
done

# Even successful entropy utilities must provide the full expected shape.
printf '%s\n' '#!/bin/sh' 'echo abcd' > "$TMP_HOME/entropy-fail/od"
MINT_RC=0
MINT_OUT=$(PATH="$TMP_HOME/entropy-fail:$PATH" bash "$GENERATOR" 2>/dev/null) || MINT_RC=$?
check_eq 'short entropy is refused' 5 "$MINT_RC"
check_eq 'failed mint prints no identity' '' "$MINT_OUT"

# Installed-only resolution is exercised from a deliberately untrusted cwd.
# Its benign sentinel would falsely report retirement success if executed.
rm -f "$HOME/.claude/scripts/park-generation.sh" "$HOME/.claude/scripts/park-retire.sh"
STOP_CALLS="$TMP_HOME/native-stop-calls"
SENTINEL="$TMP_HOME/untrusted-executed"
export STOP_CALLS SENTINEL STOP_RESULT
STOP_RESULT=0
STOP_FUNC=$(cat <<'STOP_FUNCTION'
TaskStop() {
  printf '%s\n' "$1" >> "$STOP_CALLS"
  if [[ -n "${STOP_REMOVE_PATH:-}" ]]; then
    [[ "$STOP_REMOVE_PATH" == "$HOME/"* ]] || return 99
    rm -f "$STOP_REMOVE_PATH"
  fi
  return "$STOP_RESULT"
}
STOP_FUNCTION
)
run_stop_case() {
  bash -c "$STOP_FUNC"$'\n'"$BLOCK_RETIRE"$'\n'"$BLOCK_DISARM"$'\n''echo "RESOLVED=$LIMIT_WAKE_RESOLVED"' 2>&1
}
TOP_RESOLVE=$(extract_skill_bash "$PAUSE_RESUME" pause-resume-installed-helpers) || exit 1
REVIEW1_FIXTURE="$TEST_DIR/fixtures/park-retire-review1-1715.md"
REVIEW1_RETIRE=$(extract_skill_bash "$REVIEW1_FIXTURE" pause-resume-retire-limit-park) || exit 1
REVIEW1_DISARM=$(extract_skill_bash "$REVIEW1_FIXTURE" pause-resume-limit-wake-disarm) || exit 1
UNTRUSTED="$TMP_HOME/untrusted"
mkdir -p "$UNTRUSTED/.claude/scripts"
cat > "$UNTRUSTED/.claude/scripts/park-retire.sh" <<'UNTRUSTED_HELPER'
#!/bin/sh
: > "$SENTINEL"
exit 0
UNTRUSTED_HELPER
chmod +x "$UNTRUSTED/.claude/scripts/park-retire.sh"
cat > "$UNTRUSTED/.claude/scripts/park-generation.sh" <<'UNTRUSTED_GENERATOR'
#!/bin/sh
: > "$SENTINEL"
printf 'park-benign-untrusted\n'
UNTRUSTED_GENERATOR
chmod +x "$UNTRUSTED/.claude/scripts/park-generation.sh"
seed_complete_park reactive 2026-09-11T22:00:00Z task-original
BEFORE=$(cat "$STATE_FILE")
OUT=$(cd "$UNTRUSTED" && bash -c "$BLOCK_D5" 2>&1)
check_eq 'D5 missing installed helper reports error 4' 'RESUME_CLEAR=error rc=4' "$OUT"
check_eq 'D5 missing installed helper preserves state bytes' "$BEFORE" "$(cat "$STATE_FILE")"
check_eq 'D5 never executes an untrusted retirement helper' false "$(if [[ -e "$SENTINEL" ]]; then echo true; else echo false; fi)"
for CLAIM_ANCHOR in pm-day-2d6-park-claim pm-day-2d7-park-claim subagent-limit-park-claim; do
  CLAIM_DOC="$PM_SKILL"
  [[ "$CLAIM_ANCHOR" != subagent-limit-park-claim ]] || CLAIM_DOC="$LIMIT_PARK_DOC"
  CLAIM_BLOCK=$(extract_skill_bash "$CLAIM_DOC" "$CLAIM_ANCHOR") || exit 1
  RESOLVE_BLOCK=$(printf '%s\n' "$CLAIM_BLOCK" | awk '/^PARK_GENERATION_SH=""$/ {on=1} on {print} on && /^done$/ {exit}')
  [[ -n "$RESOLVE_BLOCK" ]] || exit 1
  OUT=$(cd "$UNTRUSTED" && bash -c "$RESOLVE_BLOCK"$'\n''echo "SELECTED=$PARK_GENERATION_SH"; if [[ -n "$PARK_GENERATION_SH" ]]; then "$PARK_GENERATION_SH"; fi')
  check_eq "$CLAIM_ANCHOR: no cwd generation authority" 'SELECTED=' "$OUT"
  check_eq "$CLAIM_ANCHOR: no untrusted execution" false "$(if [[ -e "$SENTINEL" ]]; then echo true; else echo false; fi)"
  for LOCATION in "$HOME/.claude/skills-worktree/.claude/scripts" "$HOME/.claude/scripts"; do
    mkdir -p "$LOCATION"
    ln -s "$REPO_ROOT/.claude/scripts/park-generation.sh" "$LOCATION/park-generation.sh"
    OUT=$(cd "$UNTRUSTED" && bash -c "$RESOLVE_BLOCK"$'\n''echo "$PARK_GENERATION_SH"')
    check_eq "$CLAIM_ANCHOR: trusted location is selected" "$LOCATION/park-generation.sh" "$OUT"
    rm -f "$LOCATION/park-generation.sh"
  done
done
ln -s "$REPO_ROOT/.claude/scripts/park-generation.sh" "$HOME/.claude/scripts/park-generation.sh"
seed_complete_park reactive 2026-09-11T22:00:00Z task-original
BEFORE=$(cat "$STATE_FILE"); : > "$STOP_CALLS"
OUT=$(cd "$UNTRUSTED" && bash -c "$TOP_RESOLVE"$'\n''SESSION_STATE_SH="$REAL_SESSION_STATE_SH"'$'\n'"$STOP_FUNC"$'\n'"$BLOCK_RETIRE"$'\n'"$BLOCK_DISARM"$'\n''echo "RESOLVED=$LIMIT_WAKE_RESOLVED"' 2>&1)
check_eq 'missing installed helper does not mark resolved' false "$(field "$OUT" RESOLVED)"
check_eq 'missing installed helper does not stop the Monitor' '' "$(cat "$STOP_CALLS")"
check_eq 'missing installed helper preserves the park byte-for-byte' "$BEFORE" "$(cat "$STATE_FILE")"
check_eq 'untrusted checkout helper never executes' false "$(if [[ -e "$SENTINEL" ]]; then echo true; else echo false; fi)"
OUT=$(cd "$UNTRUSTED" && BLOCK_RETIRE="$REVIEW1_RETIRE" BLOCK_DISARM="$REVIEW1_DISARM" run_stop_case)
check_eq 'negative R1: current-checkout helper was executed' true "$(if [[ -e "$SENTINEL" ]]; then echo true; else echo false; fi)"
check_eq 'negative R1: benign fake could falsely report resolved' true "$(field "$OUT" RESOLVED)"
rm -f "$SENTINEL"
INSTALLED_FIRST="$HOME/.claude/skills-worktree/.claude/scripts/park-retire.sh"
INSTALLED_SECOND="$HOME/.claude/scripts/park-retire.sh"
mkdir -p "$(dirname "$INSTALLED_FIRST")" "$(dirname "$INSTALLED_SECOND")"
ln -s "$REPO_ROOT/.claude/scripts/park-retire.sh" "$INSTALLED_FIRST"
ln -s "$REPO_ROOT/.claude/scripts/park-retire.sh" "$INSTALLED_SECOND"
OUT=$(cd "$UNTRUSTED" && bash -c "$TOP_RESOLVE"$'\n''echo "$PARK_RETIRE_SH"')
check_eq 'installed worktree helper has priority' "$INSTALLED_FIRST" "$OUT"
rm -f "$INSTALLED_FIRST"
OUT=$(cd "$UNTRUSTED" && bash -c "$TOP_RESOLVE"$'\n''echo "$PARK_RETIRE_SH"')
check_eq 'second installed location is supported' "$INSTALLED_SECOND" "$OUT"
rm -f "$INSTALLED_SECOND"

FAIL_RETIRE="$TMP_HOME/retire-fails.sh"
printf '%s\n' '#!/bin/sh' 'exit 5' > "$FAIL_RETIRE"
chmod +x "$FAIL_RETIRE"
for SHAPE in generated legacy; do
  seed_complete_park reactive 2026-09-11T22:00:00Z task-original
  if [[ "$SHAPE" == generated ]]; then
    "$SESSION_STATE_SH" --set ".repos[\"$REPO_KEY\"].day.park_generation=\"original\"" >/dev/null
  fi
  : > "$STOP_CALLS"
  OUT=$(PARK_RETIRE_SH="$FAIL_RETIRE" run_stop_case)
  check_eq "$SHAPE: failed retirement remains unresolved" false "$(field "$OUT" RESOLVED)"
  check_eq "$SHAPE: one confirmed native stop" task-original "$(cat "$STOP_CALLS")"
  check_eq "$SHAPE: stopped receipt is retained" true "$(jq -r --arg k "$REPO_KEY" '.repos[$k].day.limit_resume_stop_proofs | to_entries[0].value.stopped' "$STATE_FILE")"
  check_eq "$SHAPE: failed retirement retains bound" 2026-09-11T22:00:00Z "$(day_get parked_until)"
  OUT=$(STOP_RESULT=1 run_stop_case)
  check_eq "$SHAPE: retry retires the same stopped wake" true "$(field "$OUT" RESOLVED)"
  check_eq "$SHAPE: retry never calls a failed second stop" task-original "$(cat "$STOP_CALLS")"
  check_eq "$SHAPE: retry clears original park" null "$(day_get parked_until)"
  check_eq "$SHAPE: retirement clears receipt map" null "$(day_get limit_resume_stop_proofs)"
  # The published R1 caller cannot recover once TaskStop reports already dead.
  seed_complete_park reactive 2026-09-11T22:00:00Z task-original
  if [[ "$SHAPE" == generated ]]; then
    "$SESSION_STATE_SH" --set ".repos[\"$REPO_KEY\"].day.park_generation=\"original\"" >/dev/null
  fi
  ln -s "$FAIL_RETIRE" "$INSTALLED_SECOND"
  : > "$STOP_CALLS"
  OUT=$(BLOCK_RETIRE="$REVIEW1_RETIRE" BLOCK_DISARM="$REVIEW1_DISARM" run_stop_case)
  rm -f "$INSTALLED_SECOND"
  ln -s "$REPO_ROOT/.claude/scripts/park-retire.sh" "$INSTALLED_SECOND"
  OUT=$(STOP_RESULT=1 BLOCK_RETIRE="$REVIEW1_RETIRE" BLOCK_DISARM="$REVIEW1_DISARM" run_stop_case)
  check_eq "$SHAPE negative R1: second stop failure leaves park unresolved" false "$(field "$OUT" RESOLVED)"
  check_eq "$SHAPE negative R1: restored helper cannot lift standing park" 2026-09-11T22:00:00Z "$(day_get parked_until)"
  check_eq "$SHAPE negative R1: unnecessarily retried stopped task" 2 "$(wc -l < "$STOP_CALLS" | tr -d ' ')"
  rm -f "$INSTALLED_SECOND"
done

# Numeric receipts use the same installed reader, retirement helper and
# synthetic native stop as the string controls above.
seed_typed_stop() { # park shape, raw JSON task
  seed_complete_park reactive 2026-09-11T22:00:00Z placeholder
  "$SESSION_STATE_SH" --set ".repos[\"$REPO_KEY\"].day.limit_resume_task_id=$2" >/dev/null
  if [[ "$1" == generated ]]; then
    "$SESSION_STATE_SH" --set ".repos[\"$REPO_KEY\"].day.park_generation=\"typed-park\"" >/dev/null
  fi
}
for SHAPE in generated legacy; do
  for TASK_JSON in 0 7 7.0 '"7"' '"null"'; do
    seed_typed_stop "$SHAPE" "$TASK_JSON"
    NATIVE_ID=$(printf '%s\n' "$TASK_JSON" | jq -r 'if type == "number" then floor else . end')
    : > "$STOP_CALLS"
    OUT=$(PARK_RETIRE_SH="$FAIL_RETIRE" run_stop_case)
    check_eq "$SHAPE $TASK_JSON: failed retirement remains unresolved" false "$(field "$OUT" RESOLVED)"
    check_eq "$SHAPE $TASK_JSON: native stop receives exact rendered ID" "$NATIVE_ID" "$(cat "$STOP_CALLS")"
    RECORDED=$(jq -c --arg k "$REPO_KEY" '.repos[$k].day.limit_resume_stop_proofs | to_entries[0].value.task_id' "$STATE_FILE")
    EXPECTED=$(printf '%s\n' "$TASK_JSON" | jq -c 'if type == "number" then floor else . end')
    check_eq "$SHAPE $TASK_JSON: receipt retains the task JSON type" "$EXPECTED" "$RECORDED"
    if [[ "$TASK_JSON" == 7.0 ]]; then
      "$SESSION_STATE_SH" --set ".repos[\"$REPO_KEY\"].day.limit_resume_task_id=7" >/dev/null
    fi
    OUT=$(STOP_RESULT=1 run_stop_case)
    check_eq "$SHAPE $TASK_JSON: exact receipt permits retry" true "$(field "$OUT" RESOLVED)"
    check_eq "$SHAPE $TASK_JSON: retry never attempts a second stop" "$NATIVE_ID" "$(cat "$STOP_CALLS")"
  done
done

for CHANGE in task-type wake-generation park-generation; do
  seed_typed_stop generated 7
  : > "$STOP_CALLS"
  OUT=$(PARK_RETIRE_SH="$FAIL_RETIRE" run_stop_case)
  case "$CHANGE" in
    task-type) FIELD=limit_resume_task_id; REPLACEMENT='"7"' ;;
    wake-generation) FIELD=limit_resume_generation; REPLACEMENT='"replacement-wake"' ;;
    park-generation) FIELD=park_generation; REPLACEMENT='"replacement-park"' ;;
  esac
  "$SESSION_STATE_SH" --set ".repos[\"$REPO_KEY\"].day.$FIELD=$REPLACEMENT" >/dev/null
  BEFORE=$(cat "$STATE_FILE")
  OUT=$(STOP_RESULT=1 run_stop_case)
  check_eq "$CHANGE: receipt cannot resolve a replacement identity" false "$(field "$OUT" RESOLVED)"
  check_eq "$CHANGE: replacement and the foreign receipt stay untouched" "$BEFORE" "$(cat "$STATE_FILE")"
  check_eq "$CHANGE: the receipt did not skip the separate native stop" 2 "$(wc -l < "$STOP_CALLS" | tr -d ' ')"
done

for TASK_JSON in -1 7.5 9007199254740992 false '""' '{}'; do
  seed_typed_stop generated "$TASK_JSON"
  BEFORE=$(cat "$STATE_FILE"); : > "$STOP_CALLS"
  OUT=$(run_stop_case)
  check_eq "$TASK_JSON: invalid stored task ID leaves recovery unresolved" false "$(field "$OUT" RESOLVED)"
  check_eq "$TASK_JSON: invalid task is neither stopped nor erased" "|$BEFORE" "$(cat "$STOP_CALLS")|$(cat "$STATE_FILE")"
done
seed_typed_stop generated null
BEFORE=$(cat "$STATE_FILE")
OUT=$(bash -c "$BLOCK_RETIRE"$'\n''record_limit_stop_proof; echo "PROOF_RC=$?"' 2>&1)
check_eq 'null task cannot make a stop receipt' 8 "$(field "$OUT" PROOF_RC)"
check_eq 'null receipt attempt does not mutate the park' "$BEFORE" "$(cat "$STATE_FILE")"
seed_typed_stop generated 0
BEFORE=$(cat "$STATE_FILE"); : > "$STOP_CALLS"
OUT=$(STOP_RESULT=1 run_stop_case)
check_eq 'failed numeric native stop does not leave a receipt' "$BEFORE" "$(cat "$STATE_FILE")"
check_eq 'failed numeric native stop leaves recovery unresolved' false "$(field "$OUT" RESOLVED)"


# A helper disappearing after the successful stop still cannot erase its proof:
# proof persistence uses the separate installed state helper, not park-retire.sh.
seed_complete_park reactive 2026-09-11T22:00:00Z task-original
"$SESSION_STATE_SH" --set ".repos[\"$REPO_KEY\"].day.park_generation=\"original\"" >/dev/null
ln -s "$REPO_ROOT/.claude/scripts/park-retire.sh" "$INSTALLED_SECOND"
: > "$STOP_CALLS"
OUT=$(PARK_RETIRE_SH="$INSTALLED_SECOND" STOP_REMOVE_PATH="$INSTALLED_SECOND" run_stop_case)
check_eq 'disappearing helper keeps resume unresolved' false "$(field "$OUT" RESOLVED)"
check_eq 'disappearing helper retains native stop receipt' 1 "$(jq -r --arg k "$REPO_KEY" '.repos[$k].day.limit_resume_stop_proofs | length' "$STATE_FILE")"
ln -s "$REPO_ROOT/.claude/scripts/park-retire.sh" "$INSTALLED_SECOND"
OUT=$(STOP_RESULT=1 PARK_RETIRE_SH="$INSTALLED_SECOND" run_stop_case)
check_eq 'restored installed helper recovers with exact stop proof' true "$(field "$OUT" RESOLVED)"
check_eq 'restored helper does not stop twice' task-original "$(cat "$STOP_CALLS")"
rm -f "$INSTALLED_SECOND"

# Produce a receipt through the actual confirmed-stop/error path, then mutate
# exactly one of its authority fields. None permits a generic failed stop.
seed_complete_park reactive 2026-09-11T22:00:00Z task-original
"$SESSION_STATE_SH" --set ".repos[\"$REPO_KEY\"].day.park_generation=\"original\"" >/dev/null
: > "$STOP_CALLS"
OUT=$(PARK_RETIRE_SH="$FAIL_RETIRE" run_stop_case)
RECEIPT_DAY=$("$SESSION_STATE_SH" --get-json ".repos[\"$REPO_KEY\"].day")
for MUTATION in stopped generation task wake map_type proof_type; do
  "$SESSION_STATE_SH" --set ".repos[\"$REPO_KEY\"].day=$RECEIPT_DAY" >/dev/null
  case "$MUTATION" in
    stopped) FILTER='(.limit_resume_stop_proofs[] | .stopped) = false' ;;
    generation) FILTER='(.limit_resume_stop_proofs[] | .park_generation) = "wrong"' ;;
    task) FILTER='(.limit_resume_stop_proofs[] | .task_id) = "wrong"' ;;
    wake) FILTER='(.limit_resume_stop_proofs[] | .wake_generation) = "wrong"' ;;
    map_type) FILTER='.limit_resume_stop_proofs = false' ;;
    proof_type) FILTER='(.limit_resume_stop_proofs[]) = "stopped"' ;;
  esac
  BAD_DAY=$(printf '%s' "$RECEIPT_DAY" | jq -c "$FILTER")
  "$SESSION_STATE_SH" --set ".repos[\"$REPO_KEY\"].day=$BAD_DAY" >/dev/null
  BEFORE=$(cat "$STATE_FILE"); : > "$STOP_CALLS"
  OUT=$(STOP_RESULT=1 run_stop_case)
  check_eq "$MUTATION: invalid proof cannot resolve a failed stop" false "$(field "$OUT" RESOLVED)"
  check_eq "$MUTATION: invalid proof cannot skip native stop" task-original "$(cat "$STOP_CALLS")"
  check_eq "$MUTATION: invalid proof leaves state byte-identical" "$BEFORE" "$(cat "$STATE_FILE")"
done
"$SESSION_STATE_SH" --set ".repos[\"$REPO_KEY\"].day=$RECEIPT_DAY" \
  --set ".repos[\"$REPO_KEY\"].day.park_generation=\"replacement\"" >/dev/null
BEFORE=$(cat "$STATE_FILE"); : > "$STOP_CALLS"
OUT=$(STOP_RESULT=1 run_stop_case)
check_eq 'replacement generation cannot reuse old stopped evidence' false "$(field "$OUT" RESOLVED)"
check_eq 'replacement keeps all state unchanged' "$BEFORE" "$(cat "$STATE_FILE")"

# Per-key proof writes preserve another current wake's stop receipt. The old
# writer uses its original bound snapshot after the new writer records its own.
# Legacy keys also distinguish two policies naming the same legacy wake.
for SHAPE in generated legacy; do
  seed_complete_park reactive 2026-09-11T22:00:00Z task-original
  if [[ "$SHAPE" == generated ]]; then
    "$SESSION_STATE_SH" --set ".repos[\"$REPO_KEY\"].day.park_generation=\"original\"" >/dev/null
    NEW_STOP_FIELDS=$(cat <<'NEW_GENERATED_STOP'
"$SESSION_STATE_SH" --set ".repos[\"$REPO_KEY\"].day.limit_resume_task_id=\"task-new\"" \
  --set ".repos[\"$REPO_KEY\"].day.limit_resume_generation=\"wake-new\"" >/dev/null
NEW_GENERATED_STOP
)
  else
    NEW_STOP_FIELDS=$(cat <<'NEW_LEGACY_STOP'
"$SESSION_STATE_SH" --set ".repos[\"$REPO_KEY\"].day.parked_until=\"2026-09-12T22:00:00Z\"" >/dev/null
NEW_LEGACY_STOP
)
  fi
  INTERLEAVED_RECORD=$(cat <<'RECORD_RACE'
bash -c "$BLOCK_RETIRE"$'\n''record_limit_stop_proof' || exit 91
record_limit_stop_proof || exit 92
RECORD_RACE
)
  export BLOCK_RETIRE
  OUT=$(bash -c "$BLOCK_RETIRE"$'\n'"$NEW_STOP_FIELDS"$'\n'"$INTERLEAVED_RECORD" 2>&1)
  check_eq "$SHAPE: interleaved stop receipts both survive" 2 "$(jq -r --arg k "$REPO_KEY" '.repos[$k].day.limit_resume_stop_proofs | length' "$STATE_FILE")"
  : > "$STOP_CALLS"
  OUT=$(STOP_RESULT=1 run_stop_case)
  check_eq "$SHAPE: current wake recovers after old proof writer" true "$(field "$OUT" RESOLVED)"
  check_eq "$SHAPE: recovery never repeats a confirmed stop" '' "$(cat "$STOP_CALLS")"
  check_eq "$SHAPE: retirement clears all stopped receipts" null "$(day_get limit_resume_stop_proofs)"
done

# If storage itself cannot retain proof, preserve the native stop receipt and
# original bound snapshot. A later exact replay of that receipt is still pinned
# to its old generation; it cannot adopt a replacement from a fresh read.
PROOF_LOCK_SH="$TMP_HOME/proof-lock.sh"
PROOF_LOCK_CALLS="$TMP_HOME/proof-lock-calls"
export PROOF_LOCK_CALLS
cat > "$PROOF_LOCK_SH" <<'PROOF_LOCK'
#!/usr/bin/env bash
case " $* " in *' --cas '*) echo lock >> "$PROOF_LOCK_CALLS"; exit 6 ;; esac
exec "$REAL_SESSION_STATE_SH" "$@"
PROOF_LOCK
chmod +x "$PROOF_LOCK_SH"
seed_complete_park reactive 2026-09-11T22:00:00Z task-original
"$SESSION_STATE_SH" --set ".repos[\"$REPO_KEY\"].day.park_generation=\"original\"" >/dev/null
BEFORE=$(cat "$STATE_FILE"); : > "$STOP_CALLS"; : > "$PROOF_LOCK_CALLS"
REPORT_RECEIPT=$(cat <<'RECEIPT_REPORT'
echo "RESOLVED=$LIMIT_WAKE_RESOLVED"
echo "RECEIPT_DAY=$PARK_DAY_EXPECT"
RECEIPT_REPORT
)
OUT=$(SESSION_STATE_SH="$PROOF_LOCK_SH" PARK_RETIRE_SH="$FAIL_RETIRE" bash -c "$STOP_FUNC"$'\n'"$BLOCK_RETIRE"$'\n'"$BLOCK_DISARM"$'\n'"$REPORT_RECEIPT" 2>&1)
check_eq 'proof storage failure stays unresolved' false "$(field "$OUT" RESOLVED)"
check_eq 'proof lock retry is bounded' 2 "$(wc -l < "$PROOF_LOCK_CALLS" | tr -d ' ')"
check_eq 'proof storage failure leaves original state unchanged' "$BEFORE" "$(cat "$STATE_FILE")"
require_text 'proof storage failure retains a typed pending receipt' <(printf '%s\n' "$OUT") 'STOP_PROOF_PENDING=\{"stopped":true.*rc=6'
RETAINED_DAY=$(field "$OUT" RECEIPT_DAY)
export RETAINED_DAY
REPLAY_RECEIPT=$(cat <<'REPLAY_NATIVE_RECEIPT'
# The enclosing control just verified a successful native stop and retained this
# exact bound snapshot. The production instruction forbids invented receipts.
PARK_DAY_EXPECT="$RETAINED_DAY"
record_limit_stop_proof
echo "PROOF_REPLAY_RC=$?"
REPLAY_NATIVE_RECEIPT
)
OUT=$(bash -c "$BLOCK_RETIRE"$'\n'"$REPLAY_RECEIPT" 2>&1)
check_eq 'retained native receipt can persist after storage recovers' 0 "$(field "$OUT" PROOF_REPLAY_RC)"
OUT=$(STOP_RESULT=1 run_stop_case)
check_eq 'retained native receipt completes retirement without stopping twice' true "$(field "$OUT" RESOLVED)"
check_eq 'receipt recovery keeps one actual stop' task-original "$(cat "$STOP_CALLS")"
seed_complete_park reactive 2026-09-12T22:00:00Z task-replacement
"$SESSION_STATE_SH" --set ".repos[\"$REPO_KEY\"].day.park_generation=\"replacement\"" >/dev/null
BEFORE=$(cat "$STATE_FILE")
OUT=$(bash -c "$BLOCK_RETIRE"$'\n'"$REPLAY_RECEIPT" 2>&1)
check_eq 'old native receipt cannot adopt a fresh replacement generation' 7 "$(field "$OUT" PROOF_REPLAY_RC)"
check_eq 'rejected old receipt leaves replacement byte-identical' "$BEFORE" "$(cat "$STATE_FILE")"

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
