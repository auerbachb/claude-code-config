#!/usr/bin/env bash
# Tests for `/pm` day mode's usage-horizon reflex — issue #1428.
#
# WHAT IS UNDER TEST
#   The REAL fenced bash in `.claude/skills/pm/SKILL.md`, pulled out at run time
#   by `lib/skill-bash.sh` through the `<!-- test-anchor: … -->` markers and
#   executed against a stubbed `usage-horizon.sh` and a real `session-state.sh`
#   driven by a throwaway $HOME. Nothing below is a transcription: edit the
#   skill and this suite runs the edit. Same principle as
#   `pmm-wake-step-4a.test.sh` and `pr-state-classify.test.sh`.
#
#   Five anchors, five jobs:
#     pm-day-d2-horizon-branch  D2's tick gate — verdict -> {refill, park, idle}
#     pm-day-2d7-park-claim     the compare-and-set single-park claim
#     pm-day-2d7-park-record    the park record, including the cause field
#     pm-day-2d7-wake-publish   the wake identity pair (armed / lost / failed / stranded)
#     pm-day-2d7-probe-fire     one bounded probe fire (resume / decrement / stop)
#
# WHY (issue #1428)
#   Day mode could only park AFTER a usage-limit kill. The pre-emptive leg fires
#   on the horizon verdict instead, which means three things have to be true and
#   none of them is visible from prose review: `unknown` must never park and must
#   never read as `clear`; exactly one park record may exist when a real kill
#   races the pre-emptive park; and the probe wake must be bounded by state, not
#   by the loop, so a restart cannot re-arm a fresh bound forever.
#
# NON-VACUITY
#   Every assertion here can fail. The verdict cases are driven through a stub
#   whose STATUS line and exit code are set per case (including a stub that does
#   not exist and one that prints garbage), and the state assertions read the
#   file back rather than trusting what a block printed — a park block that
#   printed "won" while writing nothing would pass a printed-output-only test.
#
# Requires: bash 3.2+ (macOS system bash), jq. Offline: no gh, no git, no network.
set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TEST_DIR/../../.." && pwd)"
SKILL="$REPO_ROOT/.claude/skills/pm/SKILL.md"
PAUSE="$REPO_ROOT/.claude/skills/pause/SKILL.md"
PAUSE_RESUME="$REPO_ROOT/.claude/skills/pause-resume/SKILL.md"
SCHEMA="$REPO_ROOT/.claude/reference/session-state-schema.json"
DAY_MODE_DOC="$REPO_ROOT/.claude/reference/pm-day-mode.md"
SESSION_STATE_SH="$REPO_ROOT/.claude/scripts/session-state.sh"

# shellcheck source=lib/skill-bash.sh
source "$TEST_DIR/lib/skill-bash.sh"

TMP_HOME="$(mktemp -d)"
STUB_DIR="$(mktemp -d)"
# Set by the negative control at the end of the file; removed here so an early
# exit never leaves a registered worktree behind.
CTRL_ROOT=""
CTRL_DIR=""
cleanup() {
  if [[ -n "$CTRL_DIR" ]]; then
    git -C "$REPO_ROOT" worktree remove --force "$CTRL_DIR" >/dev/null 2>&1
    # `git worktree prune` takes no path — it is repository-wide, and this repo
    # routinely runs a dozen concurrent agent worktrees whose branch locks a
    # stray prune would release. `remove` above already drops our admin entry on
    # the normal path, so only reach for prune when it did not: that keeps the
    # safety net for a control directory that vanished under us without firing a
    # repo-wide sweep on every green run.
    if git -C "$REPO_ROOT" worktree list --porcelain 2>/dev/null \
         | grep -qxF "worktree $CTRL_DIR"; then
      git -C "$REPO_ROOT" worktree prune >/dev/null 2>&1
    fi
  fi
  rm -rf "$TMP_HOME" "$STUB_DIR" ${CTRL_ROOT:+"$CTRL_ROOT"}
}
trap cleanup EXIT
export HOME="$TMP_HOME"
mkdir -p "$HOME/.claude"
STATE_FILE="$HOME/.claude/session-state.json"
REPO_KEY="auerbachb/claude-code-config"

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
require_text() {
  local desc="$1" file="$2" pattern="$3"
  if grep -Eq -- "$pattern" "$file"; then
    PASS=$((PASS + 1)); echo "ok   — $desc"
  else
    FAIL=$((FAIL + 1)); echo "FAIL — $desc (no match for /$pattern/ in $(basename "$file"))"
  fi
}
# Presence-only assertions cannot pin a value that must STOP being written; the
# #1595 deadlock is exactly that shape (the resume path restamping `-1`).
refute_text() {
  local desc="$1" file="$2" pattern="$3"
  if grep -Eq -- "$pattern" "$file"; then
    FAIL=$((FAIL + 1)); echo "FAIL — $desc (unexpected match for /$pattern/ in $(basename "$file"))"
  else
    PASS=$((PASS + 1)); echo "ok   — $desc"
  fi
}

# Extract every anchored block once; a failed extraction is fatal, never skipped
# (a suite that silently runs zero lines of skill bash passes green forever).
BLOCK_D2="$(extract_skill_bash "$SKILL" pm-day-d2-horizon-branch)" || exit 1
BLOCK_CLAIM="$(extract_skill_bash "$SKILL" pm-day-2d7-park-claim)" || exit 1
BLOCK_RECORD="$(extract_skill_bash "$SKILL" pm-day-2d7-park-record)" || exit 1
BLOCK_WAKE="$(extract_skill_bash "$SKILL" pm-day-2d7-wake-publish)" || exit 1
BLOCK_PROBE="$(extract_skill_bash "$SKILL" pm-day-2d7-probe-fire)" || exit 1

# `TaskStop` is a harness tool, not a binary, so the wake-publish block cannot
# run without a stand-in. Two shapes are needed: one that stops the Monitor
# (`lost` / `failed`) and one that cannot (`stranded`) — the block's own branch.
make_taskstop_stub() {   # make_taskstop_stub <exit-code>
  local rc="$1" stub_path="$STUB_DIR/TaskStop"
  printf '#!/usr/bin/env bash\nexit %s\n' "$rc" > "$stub_path"
  chmod +x "$stub_path"
}
make_taskstop_stub 0
export PATH="$STUB_DIR:$PATH"

# A stub standing in for usage-horizon.sh: --check prints the STATUS/REASON pair
# and exits on the documented code; --observe exits 0 whatever the verdict.
make_horizon_stub() {
  local status="$1" observe_rc="${2:-0}" path="$STUB_DIR/usage-horizon.sh"
  local rc
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

# Run the D2 gate with a given stub path and reading, return its printed fields.
run_d2() {
  local horizon_sh="$1" remaining="${2:-}" limit="${3:-}"
  USAGE_HORIZON_SH="$horizon_sh" HORIZON_REMAINING="$remaining" HORIZON_LIMIT="$limit" \
    bash -c "$BLOCK_D2" 2>/dev/null
}
field() { printf '%s\n' "$1" | sed -n "s/^$2=//p" | head -1; }

# Parse a `…Z` timestamp to epoch on both date flavours. The `-u` on the BSD
# fallback is load-bearing and was found by this suite: without it macOS reads
# the Z timestamp as LOCAL time, so on an ET machine every park measures four
# hours long — the failure mode is a wrong number, not an error, which is
# exactly the try-both trap `date`/`stat` chains keep setting.
iso_to_epoch() {
  date -u -d "$1" +%s 2>/dev/null || date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "$1" '+%s'
}

seed_day_state() {
  # A day block shaped like 2D.2's init write, with no park recorded.
  jq -n --arg k "$REPO_KEY" '{repos: {($k): {day: {
      active: true, parked_until: null, limit_kind: null, limit_cause: null,
      limit_probe_fires_remaining: null, limit_resume_task_id: null,
      limit_resume_generation: null, consecutive_limit_hits: 0}}}}' > "$STATE_FILE"
}
day_get() { jq -r --arg k "$REPO_KEY" ".repos[\$k].day.$1" "$STATE_FILE"; }

# ---------------------------------------------------------------------------
echo "== D2 tick-branch matrix (AC 1) =="
# ---------------------------------------------------------------------------

OUT=$(run_d2 "$(make_horizon_stub clear)" 900000 1000000)
check_eq "clear: verdict"        "clear" "$(field "$OUT" HORIZON_STATUS)"
check_eq "clear: refill allowed" "true"  "$(field "$OUT" HORIZON_REFILL_OK)"
check_eq "clear: no park"        "false" "$(field "$OUT" HORIZON_PARK)"
check_eq "clear: no idle reason" ""      "$(field "$OUT" HORIZON_IDLE_REASON)"

OUT=$(run_d2 "$(make_horizon_stub approaching)" 200000 1000000)
check_eq "approaching: verdict"      "approaching" "$(field "$OUT" HORIZON_STATUS)"
check_eq "approaching: refill stops" "false"       "$(field "$OUT" HORIZON_REFILL_OK)"
check_eq "approaching: never parks"  "false"       "$(field "$OUT" HORIZON_PARK)"
check_eq "approaching: idle reason"  "paused (horizon approaching)" "$(field "$OUT" HORIZON_IDLE_REASON)"

OUT=$(run_d2 "$(make_horizon_stub critical)" 50000 1000000)
check_eq "critical: verdict"      "critical" "$(field "$OUT" HORIZON_STATUS)"
check_eq "critical: refill stops" "false"    "$(field "$OUT" HORIZON_REFILL_OK)"
check_eq "critical: parks"        "true"     "$(field "$OUT" HORIZON_PARK)"

OUT=$(run_d2 "$(make_horizon_stub unknown)" 50000 1000000)
check_eq "unknown: verdict"      "unknown" "$(field "$OUT" HORIZON_STATUS)"
check_eq "unknown: refill stops" "false"   "$(field "$OUT" HORIZON_REFILL_OK)"
check_eq "unknown: NEVER parks"  "false"   "$(field "$OUT" HORIZON_PARK)"

# Degraded inputs all land on unknown, and unknown is never clear. Each of these
# would be a fail-open if the branch tested `!= critical` instead of matching
# the three known verdicts explicitly.
OUT=$(run_d2 "$STUB_DIR/does-not-exist.sh" 50000 1000000)
check_eq "missing script: unknown"    "unknown" "$(field "$OUT" HORIZON_STATUS)"
check_eq "missing script: no refill"  "false"   "$(field "$OUT" HORIZON_REFILL_OK)"
check_eq "missing script: no park"    "false"   "$(field "$OUT" HORIZON_PARK)"

OUT=$(run_d2 "" 50000 1000000)
check_eq "unresolved helper: unknown" "unknown" "$(field "$OUT" HORIZON_STATUS)"
check_eq "unresolved helper: no park" "false"   "$(field "$OUT" HORIZON_PARK)"

GARBAGE="$STUB_DIR/garbage.sh"
printf '#!/usr/bin/env bash\necho "Review limit reached"\nexit 0\n' > "$GARBAGE"; chmod +x "$GARBAGE"
OUT=$(run_d2 "$GARBAGE" 50000 1000000)
check_eq "garbage output: unknown"      "unknown" "$(field "$OUT" HORIZON_STATUS)"
check_eq "garbage output: not clear"    "false"   "$(field "$OUT" HORIZON_REFILL_OK)"

# A --check that prints STATUS=clear but exits 3 must still be read as clear:
# the verdict comes from the STATUS line, which is what the script documents.
# (--observe still succeeds here — the clamp above is about observe, not check.)
MIXED="$STUB_DIR/mixed.sh"
printf '#!/usr/bin/env bash\ncase "$1" in --observe) exit 0 ;; esac\nprintf "STATUS=clear\\nREASON=x\\n"\nexit 3\n' > "$MIXED"; chmod +x "$MIXED"
OUT=$(run_d2 "$MIXED" 900000 1000000)
check_eq "STATUS line drives the verdict" "clear" "$(field "$OUT" HORIZON_STATUS)"

# A failed observe (write/lock error) must clamp to unknown rather than trust a
# stored verdict this turn's reading never reached. The stub deliberately says
# `clear` on --check: the counter only falls during a session, so a stale reading
# is optimistic, and this is the one direction that can green-light a dying board.
OUT=$(run_d2 "$(make_horizon_stub clear 5)" 50000 1000000)
check_eq "failed observe clamps to unknown"   "unknown" "$(field "$OUT" HORIZON_STATUS)"
check_eq "failed observe does not refill"     "false"   "$(field "$OUT" HORIZON_REFILL_OK)"
check_eq "failed observe does not park"       "false"   "$(field "$OUT" HORIZON_PARK)"
# A lock timeout is the same story with a different code.
OUT=$(run_d2 "$(make_horizon_stub clear 6)" 50000 1000000)
check_eq "observe lock timeout clamps too"    "unknown" "$(field "$OUT" HORIZON_STATUS)"
# ...but a SUCCESSFUL observe still reads the verdict through.
OUT=$(run_d2 "$(make_horizon_stub clear 0)" 900000 1000000)
check_eq "successful observe reads through"   "clear"   "$(field "$OUT" HORIZON_STATUS)"

# No reading in context at all (empty HORIZON_REMAINING) must not invent one.
OUT=$(run_d2 "$(make_horizon_stub unknown)" "" "")
check_eq "no reading: unknown"  "unknown" "$(field "$OUT" HORIZON_STATUS)"
check_eq "no reading: no park"  "false"   "$(field "$OUT" HORIZON_PARK)"

# ---------------------------------------------------------------------------
echo "== 2D.7 park claim + park record (AC 2, AC 4) =="
# ---------------------------------------------------------------------------

run_claim() {
  local reset_epoch="${1:-}"
  SESSION_STATE_SH="$SESSION_STATE_SH" REPO_KEY="$REPO_KEY" \
    HORIZON_RESET_EPOCH="$reset_epoch" PROBE_CADENCE_MIN=30 PROBE_MAX_FIRES=12 \
    bash -c "$BLOCK_CLAIM" 2>/dev/null
}

seed_day_state
OUT=$(run_claim)
check_eq "claim on a clean board wins" "PARK_CLAIM=won" "$(printf '%s\n' "$OUT" | tail -1)"
PARKED_UNTIL="$(day_get parked_until)"
if [[ "$PARKED_UNTIL" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]]; then
  PASS=$((PASS + 1)); echo "ok   — claim persisted an ISO parked_until ($PARKED_UNTIL)"
else
  FAIL=$((FAIL + 1)); echo "FAIL — claim did not persist an ISO parked_until (got '$PARKED_UNTIL')"
fi
# The unknown-reset bound is cadence x fires ahead — 6h at the defaults.
NOW_E=$(date -u +%s)
PARK_E=$(iso_to_epoch "$PARKED_UNTIL")
DELTA=$(( PARK_E - NOW_E ))
if (( DELTA > 21000 && DELTA <= 21600 )); then
  PASS=$((PASS + 1)); echo "ok   — unknown reset parks to the probe bound (~6h; ${DELTA}s)"
else
  FAIL=$((FAIL + 1)); echo "FAIL — probe bound out of range (${DELTA}s, expected ~21600)"
fi

# A reactive park already on the board: the pre-emptive claim must LOSE and
# must not overwrite the reactive timestamp. This is the double-park guard.
seed_day_state
jq --arg k "$REPO_KEY" '.repos[$k].day.parked_until="2026-08-28T04:00:00Z"
  | .repos[$k].day.limit_cause="reactive"' "$STATE_FILE" > "$STATE_FILE.tmp" && mv "$STATE_FILE.tmp" "$STATE_FILE"
OUT=$(run_claim)
check_eq "claim loses to an existing park" "PARK_CLAIM=lost" "$(printf '%s\n' "$OUT" | tail -1)"
check_eq "reactive park survives the loss"  "2026-08-28T04:00:00Z" "$(day_get parked_until)"
check_eq "reactive cause survives the loss" "reactive" "$(day_get limit_cause)"

# A known reset time is used verbatim rather than the probe bound.
seed_day_state
KNOWN=$(( $(date -u +%s) + 3600 ))
OUT=$(run_claim "$KNOWN")
check_eq "known reset: claim wins" "PARK_CLAIM=won" "$(printf '%s\n' "$OUT" | tail -1)"
PARK_E=$(iso_to_epoch "$(day_get parked_until)")
check_eq "known reset used verbatim" "$KNOWN" "$PARK_E"

# A past/garbage reset epoch falls back to the probe bound rather than parking
# into the past (which would read as "not parked" everywhere downstream).
seed_day_state
OUT=$(run_claim "$(( $(date -u +%s) - 500 ))")
PARK_E=$(iso_to_epoch "$(day_get parked_until)")
if (( PARK_E > $(date -u +%s) + 21000 )); then
  PASS=$((PASS + 1)); echo "ok   — past reset epoch falls back to the probe bound"
else
  FAIL=$((FAIL + 1)); echo "FAIL — past reset epoch was used as the park time"
fi

run_record() {
  local reset_known="$1"
  SESSION_STATE_SH="$SESSION_STATE_SH" REPO_KEY="$REPO_KEY" \
    PARK_RESET_KNOWN="$reset_known" PROBE_MAX_FIRES=12 NEW_HITS=1 \
    bash -c "$BLOCK_RECORD" 2>/dev/null
}

seed_day_state
check_eq "record: writes on a park it still owns" "PARK_RECORD=written" "$(run_record false | tail -1)"
check_eq "record: rolling_window kind"   "rolling_window" "$(day_get limit_kind)"
check_eq "record: cause is preemptive"   "preemptive"     "$(day_get limit_cause)"
check_eq "record: probe bound persisted" "12"             "$(day_get limit_probe_fires_remaining)"
check_eq "record: thrash counter"        "1"              "$(day_get consecutive_limit_hits)"
check_eq "record: refill.paused untouched" "null" "$(jq -r --arg k "$REPO_KEY" '.repos[$k].refill // "null"' "$STATE_FILE")"

seed_day_state
run_record true >/dev/null
check_eq "known reset: no probe bound" "null" "$(day_get limit_probe_fires_remaining)"
check_eq "known reset: still preemptive" "preemptive" "$(day_get limit_cause)"

# Winning the Step 1 claim is not a licence to finish: a real kill can take the
# park during the shutdown that sits between the two. The completion path must
# then write NOTHING — otherwise it overwrites the reactive winner's cause and
# probe bound, and goes on to arm a second wake over its identity.
jq -n --arg k "$REPO_KEY" '{repos: {($k): {day: {parked_until: "2026-08-28T04:00:00Z",
  limit_kind: "rolling_window", limit_cause: "reactive", limit_probe_fires_remaining: null,
  limit_resume_task_id: "reactive-task", limit_resume_generation: "limit-gen-1",
  consecutive_limit_hits: 2}}}}' > "$STATE_FILE"
check_eq "record: stands down when superseded mid-shutdown" "PARK_RECORD=superseded" \
  "$(run_record false | tail -1)"
check_eq "superseded: reactive cause survives"      "reactive"       "$(day_get limit_cause)"
check_eq "superseded: reactive wake survives"       "reactive-task"  "$(day_get limit_resume_task_id)"
check_eq "superseded: no probe bound written"       "null"           "$(day_get limit_probe_fires_remaining)"
check_eq "superseded: thrash counter not rewritten" "2"              "$(day_get consecutive_limit_hits)"

# Publication is itself a compare-and-set, so two paths arming at once cannot
# both own the wake slot — the loser stops its own Monitor instead of orphaning
# the winner's. (Read-before-arm would leave a window for exactly that.)
seed_day_state
"$SESSION_STATE_SH" --set ".repos[\"$REPO_KEY\"].day.limit_resume_task_id=\"reactive-task\"" >/dev/null
PUB_RC=0
"$SESSION_STATE_SH" --cas ".repos[\"$REPO_KEY\"].day.limit_resume_task_id=\"probe-task\"" \
  --expect null >/dev/null 2>&1 || PUB_RC=$?
check_eq "wake publish loses to an armed wake" "7" "$PUB_RC"
check_eq "armed wake identity survives" "reactive-task" "$(day_get limit_resume_task_id)"

# ---------------------------------------------------------------------------
echo "== Concurrent park race (AC 4) =="
# ---------------------------------------------------------------------------

# Two writers claim the same slot at once. Exactly one may win; the loser must
# get the distinct CAS-loss code rather than an I/O error, because the two
# demand opposite handling (stand down vs. fail closed and say so).
seed_day_state
RC_A_FILE="$STUB_DIR/rc_a"; RC_B_FILE="$STUB_DIR/rc_b"
( "$SESSION_STATE_SH" --cas ".repos[\"$REPO_KEY\"].day.parked_until=\"2026-08-28T04:00:00Z\"" \
    --expect null >/dev/null 2>&1; echo $? > "$RC_A_FILE" ) &
( "$SESSION_STATE_SH" --cas ".repos[\"$REPO_KEY\"].day.parked_until=\"2026-08-28T09:00:00Z\"" \
    --expect null >/dev/null 2>&1; echo $? > "$RC_B_FILE" ) &
wait
RC_A=$(cat "$RC_A_FILE"); RC_B=$(cat "$RC_B_FILE")
WINS=0; LOSSES=0
[[ "$RC_A" == "0" ]] && WINS=$((WINS+1)); [[ "$RC_A" == "7" ]] && LOSSES=$((LOSSES+1))
[[ "$RC_B" == "0" ]] && WINS=$((WINS+1)); [[ "$RC_B" == "7" ]] && LOSSES=$((LOSSES+1))
check_eq "concurrent claims: exactly one wins" "1" "$WINS"
check_eq "concurrent claims: loser gets CAS-loss 7" "1" "$LOSSES"
PARKED_NOW="$(day_get parked_until)"
if [[ "$PARKED_NOW" == "2026-08-28T04:00:00Z" || "$PARKED_NOW" == "2026-08-28T09:00:00Z" ]]; then
  PASS=$((PASS + 1)); echo "ok   — exactly one park record landed ($PARKED_NOW)"
else
  FAIL=$((FAIL + 1)); echo "FAIL — park slot holds neither claim ('$PARKED_NOW')"
fi

# ---------------------------------------------------------------------------
echo "== Probe fire: bound, resume, stale generation (AC 3, AC 4) =="
# ---------------------------------------------------------------------------

seed_probe_state() {
  local fires="$1" generation="${2:-probe-20260828T041500Z-1234-99}"
  jq -n --arg k "$REPO_KEY" --arg g "$generation" --argjson f "$fires" \
    '{repos: {($k): {day: {active: true, parked_until: "2026-08-28T09:00:00Z",
      limit_kind: "rolling_window", limit_cause: "preemptive",
      limit_probe_fires_remaining: $f, limit_resume_task_id: "task-abc",
      limit_resume_generation: $g, consecutive_limit_hits: 1}}}}' > "$STATE_FILE"
}
run_probe() {
  local generation="$1" status="$2"
  SESSION_STATE_SH="$SESSION_STATE_SH" REPO_KEY="$REPO_KEY" \
    TICK_GENERATION="$generation" HORIZON_STATUS="$status" \
    bash -c "$BLOCK_PROBE" 2>/dev/null
}
GEN="probe-20260828T041500Z-1234-99"

seed_probe_state 12
check_eq "probe: still-critical fire continues" "PROBE=continue" "$(run_probe "$GEN" critical | tail -1)"
check_eq "probe: bound decremented"             "11"             "$(day_get limit_probe_fires_remaining)"

seed_probe_state 12
check_eq "probe: replenished window resumes" "PROBE=resume" "$(run_probe "$GEN" clear | tail -1)"
check_eq "probe: resume spends no fire"      "12"           "$(day_get limit_probe_fires_remaining)"

# `approaching` is a partial refill, not a recovery — resuming there walks back
# into the wall the thrash guard exists to prevent.
seed_probe_state 12
check_eq "probe: approaching does NOT resume" "PROBE=continue" "$(run_probe "$GEN" approaching | tail -1)"

# `unknown` must not resume any more than it may park.
seed_probe_state 12
check_eq "probe: unknown does NOT resume" "PROBE=continue" "$(run_probe "$GEN" unknown | tail -1)"

seed_probe_state 1
check_eq "probe: last fire exhausts the bound" "PROBE=exhausted" "$(run_probe "$GEN" critical | tail -1)"
check_eq "probe: bound floors at zero"         "0"               "$(day_get limit_probe_fires_remaining)"

seed_probe_state 0
check_eq "probe: spent bound stays exhausted" "PROBE=exhausted" "$(run_probe "$GEN" critical | tail -1)"

# A stale generation (superseded Monitor) must change nothing and resume nothing.
seed_probe_state 12
check_eq "probe: stale generation rejected" "PROBE=stale" "$(run_probe "probe-OLD-0000-1" clear | tail -1)"
check_eq "probe: stale fire spends no bound" "12" "$(day_get limit_probe_fires_remaining)"
check_eq "probe: stale fire leaves the park" "2026-08-28T09:00:00Z" "$(day_get parked_until)"

# A stale fire must be rejected even when the verdict says clear — the whole
# point of the token is that a superseded wake cannot resume the board.
seed_probe_state 12 "probe-CURRENT-1"
check_eq "probe: clear verdict cannot rescue a stale token" "PROBE=stale" \
  "$(run_probe "probe-OTHER-2" clear | tail -1)"

# A probe fire arriving on a REACTIVE park must never resume it. This is the
# other half of the race: 2D.6 adopts by stopping the armed wake and nulling the
# identity pair, so if that TaskStop failed and the Monitor kept ticking, the
# surviving fire meets a null generation and is rejected — no double-wake.
jq -n --arg k "$REPO_KEY" '{repos: {($k): {day: {parked_until: "2026-08-28T04:00:00Z",
  limit_kind: "rolling_window", limit_cause: "reactive",
  limit_probe_fires_remaining: null, limit_resume_task_id: null,
  limit_resume_generation: null, consecutive_limit_hits: 1}}}}' > "$STATE_FILE"
check_eq "probe fire cannot resume a reactive park" "PROBE=stale" \
  "$(run_probe "$GEN" clear | tail -1)"
check_eq "reactive park survives a surviving probe" "2026-08-28T04:00:00Z" "$(day_get parked_until)"

# An unreadable bound must stop probing rather than guess a count.
jq -n --arg k "$REPO_KEY" '{repos: {($k): {day: {limit_probe_fires_remaining: "twelve",
  limit_resume_generation: "g1", limit_resume_task_id: "t1"}}}}' > "$STATE_FILE"
check_eq "probe: non-integer bound fails closed" "PROBE=fail-closed" "$(run_probe g1 clear | tail -1)"

# ---------------------------------------------------------------------------
echo "== Contract: teardown, recovery, schema, scope (AC 2, 5, 6, 7) =="
# ---------------------------------------------------------------------------

require_text "2D.7 exists as its own sub-step" "$SKILL" '^### 2D\.7: Usage-horizon pre-emptive park'
require_text "2D.6 is still its own sub-step"  "$SKILL" '^### 2D\.6: Usage-limit park and wake'
require_text "critical is the only park trigger" "$SKILL" 'Trigger:.*HORIZON_PARK=true.*critical'
require_text "park reuses the execution gate"  "$SKILL" 'execution-pause\.sh --activate --command pause --window-minutes'
require_text "park skips the refill.paused write" "$SKILL" 'skipping only Step 1.s `\.refill\.paused` write'
require_text "wake never passes --resume-refill"  "$SKILL" 'Never pass `--resume-refill`'
require_text "probe monitor is persistent"        "$SKILL" '/pm day --probe-wake --day-generation'
require_text "probe defaults are 30m / 12 fires"  "$SKILL" 'CLAUDE_HORIZON_PROBE_CADENCE_MINUTES'
require_text "probe fire bound knob documented"   "$SKILL" 'CLAUDE_HORIZON_PROBE_MAX_FIRES'
# A zero cadence would make the Monitor's `sleep 0` a hot loop, and a zero bound
# arms a wake that can only ever stop itself; a zero WINDOW is legal and is how
# reactive parity is requested. The knobs therefore validate differently.
# These three assert the DOCUMENTATION only — the behaviour they describe is
# proven in the "Knob validation" and "rc propagation" sections below. A grep for
# a sentence is not coverage of the rule that sentence describes.
require_text "probe knobs documented as > 0" "$SKILL" 'and `> 0`'
require_text "window knob documented as 0-legal" "$SKILL" '`0` is legal.*reactive parity'
require_text "hot-loop rationale is stated"  "$SKILL" 'sleep 0.* hot loop'
# A wake whose TaskStop failed — or whose registry could not be read — must keep
# its identity: nulling it strands a ticking Monitor that nothing can name.
require_text "failed TaskStop aborts the replacement" "$SKILL" 'aborts the replacement'
require_text "abort is carried by a flag, not a top-level return" "$SKILL" 'ADOPT_ABORT'
require_text "known reset arms the one-shot instead" "$SKILL" "arm 2D\.6's sleep-until-reset one-shot verbatim"
require_text "reactive path tags its cause"       "$SKILL" 'day\.limit_cause=..reactive'
require_text "reactive path adopts a live wake"   "$SKILL" 'Stop it BEFORE the write nulls its ID'
require_text "recovery re-arms with remaining fires" "$SKILL" 'not a fresh bound'
# Restart recovery compares parked_until against `date -u +%s`, so its BSD
# fallback must parse the Z timestamp as UTC. A bare `date -j -f` there reads
# every park four hours long on an ET machine — silently, with no error.
require_text "restart recovery parses parked_until as UTC" "$SKILL" \
  "date -u -j -f '%Y-%m-%dT%H:%M:%SZ'"
require_text "weekly caps stay manual-resume"     "$SKILL" 'weekly caps remain the reactive path.s business and stay manual-resume'
require_text "credit budget still gates refill"   "$SKILL" 'credit-budget\.sh --check` exits 0'
require_text "non-day threads are out of scope"   "$SKILL" 'Out of scope:.*non-day orchestration threads'
require_text "park surfaces at most two lines"    "$SKILL" 'Two lines on park, one on resume'

require_text "pause teardown covers the probe wake" "$PAUSE" 'both wake shapes'
# -1, not null: the field is three-valued since #1445, and `null` means "reset
# time known — re-arm the sleep-until-reset one-shot". Writing null after
# deliberately stopping the wake would order a later recovery to re-arm it.
require_text "pause teardown retires the probe bound to the sentinel" "$PAUSE" \
  'day\.limit_probe_fires_remaining=-1'
require_text "pause teardown does NOT null the probe bound" "$PAUSE" \
  '\*\*`-1`, not `null`\*\*'
require_text "pause-resume disarm covers the probe" "$PAUSE_RESUME" 'One registry covers both wake shapes'
# #1595: /pause writes `-1` because there the park is meant to stand, but
# /pause-resume is the RESUME path and must retire the park outright. 2D.1(b+)
# and 2D.5 stay parked on a `preemptive` cause with a `0`/`-1` bound *regardless
# of parked_until* and stop recovery before 2D.2's init write — the only other
# place the park is cleared — so a sentinel restamped here deadlocks the very
# manual-resume escape hatch those branches name in their own message.
refute_text  "pause-resume never restamps the -1 sentinel" "$PAUSE_RESUME" \
  'day\.limit_probe_fires_remaining=-1'
require_text "pause-resume clears the probe bound"  "$PAUSE_RESUME" \
  'day\.limit_probe_fires_remaining=null'
require_text "pause-resume clears limit_cause"      "$PAUSE_RESUME" 'day\.limit_cause=null'
require_text "pause-resume clears parked_until"     "$PAUSE_RESUME" 'day\.parked_until=null'
require_text "pause-resume states why it retires"   "$PAUSE_RESUME" 'never restamp the .-1. sentinel'
# The no-armed-wake branch matters on its own: /pause already nulled the task id,
# so only this path can lift the park it left standing.
require_text "pause-resume retires a park with no armed wake" "$PAUSE_RESUME" \
  'cleared standing usage-limit park'
require_text "pause-resume fails closed on an unreadable park" "$PAUSE_RESUME" \
  'could not read day\.parked_until'
require_text "generation check is unchanged"        "$PAUSE_RESUME" 'day\.limit_resume_generation'

require_text "schema documents limit_cause"    "$SCHEMA" 'limit_cause'
require_text "schema documents the probe bound" "$SCHEMA" 'limit_probe_fires_remaining'
require_text "doc records the scope boundary"  "$DAY_MODE_DOC" 'pr-monitor-and-manage.*babysit-pr.*out of scope'
require_text "doc names the follow-up"         "$DAY_MODE_DOC" 'named follow-up'
require_text "doc explains the window deviation" "$DAY_MODE_DOC" 'Why the park window is 2 minutes'

# The schema example day block must carry both new fields, or a reader
# reconstructing state from the schema would drop them.
SCHEMA_FIELDS=$(jq -r '[paths|join(".")] | map(select(test("day\\.limit_(cause|probe_fires_remaining)$"))) | length' "$SCHEMA")
check_eq "schema example carries both new fields" "2" "$SCHEMA_FIELDS"

# ---------------------------------------------------------------------------
echo "== Knob validation: the range is enforced, not just documented (AC 3) =="
# ---------------------------------------------------------------------------
# The knobs resolve inside the claim block. Injecting PROBE_CADENCE_MIN /
# PROBE_MAX_FIRES (as the sections above do) is exactly what hides this: bash
# arithmetic turns an unset or zero knob into 0, so PARK_EPOCH == NOW_EPOCH and
# every reader treats a non-future parked_until as "not parked" — the board winds
# down while its own durable record says it did not. So run the block with the
# ENV knobs only, and never pre-seed the shell variables.
run_claim_env() {   # run_claim_env <cadence-env> <fires-env>
  SESSION_STATE_SH="$SESSION_STATE_SH" REPO_KEY="$REPO_KEY" HORIZON_RESET_EPOCH="" \
    CLAUDE_HORIZON_PROBE_CADENCE_MINUTES="$1" CLAUDE_HORIZON_PROBE_MAX_FIRES="$2" \
    bash -c "$BLOCK_CLAIM" 2>/dev/null
}
park_delta() { local p; p="$(day_get parked_until)"; [ "$p" = null ] && { echo -1; return; }; echo $(( $(iso_to_epoch "$p") - $(date -u +%s) )); }

# Unset knobs must fall back to the shipped 30 x 12 = 6h, not collapse to now.
seed_day_state
check_eq "knobs unset: claim still wins" "PARK_CLAIM=won" "$(run_claim_env "" "" | tail -1)"
D=$(park_delta)
if (( D > 21000 && D <= 21600 )); then
  PASS=$((PASS + 1)); echo "ok   — knobs unset: defaults give a ~6h park (${D}s)"
else
  FAIL=$((FAIL + 1)); echo "FAIL — knobs unset: expected ~6h park, got ${D}s"
fi

# Zero and garbage are rejected in favour of the defaults — never accepted, and
# never allowed to produce a parked_until that is not in the future.
for BAD in 0 abc -5; do
  seed_day_state
  OUT="$(run_claim_env "$BAD" 12 | tail -1)"
  D=$(park_delta)
  if [[ "$OUT" == "PARK_CLAIM=won" ]] && (( D > 21000 && D <= 21600 )); then
    PASS=$((PASS + 1)); echo "ok   — cadence '$BAD' rejected, default 30 used (${D}s)"
  else
    FAIL=$((FAIL + 1)); echo "FAIL — cadence '$BAD' not rejected (out='$OUT' delta=${D}s)"
  fi
  seed_day_state
  OUT="$(run_claim_env 30 "$BAD" | tail -1)"
  D=$(park_delta)
  if [[ "$OUT" == "PARK_CLAIM=won" ]] && (( D > 21000 && D <= 21600 )); then
    PASS=$((PASS + 1)); echo "ok   — fires '$BAD' rejected, default 12 used (${D}s)"
  else
    FAIL=$((FAIL + 1)); echo "FAIL — fires '$BAD' not rejected (out='$OUT' delta=${D}s)"
  fi
done

# A valid override is still honoured, or the validation would be a no-op guard.
seed_day_state
run_claim_env 1 1 >/dev/null
D=$(park_delta)
if (( D > 0 && D <= 60 )); then
  PASS=$((PASS + 1)); echo "ok   — valid override honoured (1x1 = ${D}s)"
else
  FAIL=$((FAIL + 1)); echo "FAIL — valid override not honoured (got ${D}s)"
fi

# The window knob is the opposite case: 0 is legal and must survive validation.
WINDOW_OUT=$(SESSION_STATE_SH="$SESSION_STATE_SH" REPO_KEY="$REPO_KEY" HORIZON_RESET_EPOCH="" \
  CLAUDE_HORIZON_PARK_WINDOW_MINUTES=0 bash -c "$BLOCK_CLAIM"'; echo "WINDOW=$PARK_WINDOW_MIN"' 2>/dev/null | sed -n 's/^WINDOW=//p')
check_eq "window knob 0 is accepted (reactive parity)" "0" "$WINDOW_OUT"
WINDOW_OUT=$(SESSION_STATE_SH="$SESSION_STATE_SH" REPO_KEY="$REPO_KEY" HORIZON_RESET_EPOCH="" \
  CLAUDE_HORIZON_PARK_WINDOW_MINUTES=zzz bash -c "$BLOCK_CLAIM"'; echo "WINDOW=$PARK_WINDOW_MIN"' 2>/dev/null | sed -n 's/^WINDOW=//p')
check_eq "window knob garbage falls back to 2" "2" "$WINDOW_OUT"

# ---------------------------------------------------------------------------
echo "== rc propagation: a failed write is never reported as success (AC 4) =="
# ---------------------------------------------------------------------------
# Every guard below arms something — a bound, an identity pair, a thrash counter.
# A swallowed rc on any of them reports a guard that was never armed, which is
# strictly worse than reporting the failure: the probe would run unbounded, or
# the board would park with a wake that can never resume it.
# A self-contained stand-in for session-state.sh: --get / --set / --cas against
# $STATE_FILE with jq, and a fault injected on whichever op $FAULT_ON names.
# Deliberately NOT a wrapper around the real script — what is under test here is
# whether the BLOCK propagates a non-zero rc, and delegating would drag the real
# script's locking and repo-scope resolution into a question that is neither.
# session-state.sh's own semantics are covered by its own suite.
#
# It understands the composed form (issue #1445): a --cas may arrive with --set
# writes riding along, and the compare gates all of them. A stub that took only
# the LAST flag it saw would silently reduce a composed park record to a blind
# --set of one field and never compare at all — a fault-injection harness that
# tests a shape the skill no longer emits.
FAULT_SH="$STUB_DIR/session-state-fault.sh"
cat > "$FAULT_SH" <<'FAULT'
#!/usr/bin/env bash
op=""; cas_arg=""; expect=""; get_arg=""
SET_ARGS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --get) op=get; get_arg="$2"; shift 2 ;;
    --set) SET_ARGS+=("$2"); [ "$op" = cas ] || op=set; shift 2 ;;
    --cas) op=cas; cas_arg="$2"; shift 2 ;;
    --expect) expect="$2"; shift 2 ;;
    *) shift ;;
  esac
done
[ "$op" = "${FAULT_ON:-}" ] && exit "${FAULT_RC:-6}"
[ -f "$STATE_FILE" ] || exit 3
apply_sets() {   # every --set in one pass, like the real single pipeline
  local a p v
  for a in ${SET_ARGS[@]+"${SET_ARGS[@]}"}; do
    p="${a%%=*}"; v="${a#*=}"
    jq "$p = $v" "$STATE_FILE" > "$STATE_FILE.t" && mv "$STATE_FILE.t" "$STATE_FILE"
  done
}
case "$op" in
  get) jq -r "$get_arg" "$STATE_FILE" ;;
  set) apply_sets ;;
  cas)
    cas_path="${cas_arg%%=*}"; cas_value="${cas_arg#*=}"
    cur=$(jq -c "$cas_path" "$STATE_FILE")
    # A lost compare writes NOTHING — the composed --set values included.
    [ "$cur" = "$expect" ] || exit 7
    jq "$cas_path = $cas_value" "$STATE_FILE" > "$STATE_FILE.t" && mv "$STATE_FILE.t" "$STATE_FILE"
    apply_sets ;;
esac
FAULT
chmod +x "$FAULT_SH"

seed_probe_state 12
PROBE_OUT=$(SESSION_STATE_SH="$FAULT_SH" STATE_FILE="$STATE_FILE" REPO_KEY="$REPO_KEY" \
  TICK_GENERATION="$GEN" HORIZON_STATUS=critical FAULT_ON=set FAULT_RC=6 \
  bash -c "$BLOCK_PROBE" 2>/dev/null | tail -1)
check_eq "probe: failed decrement fails closed, not 'continue'" "PROBE=fail-closed" "$PROBE_OUT"
check_eq "probe: failed decrement left the bound untouched" "12" "$(day_get limit_probe_fires_remaining)"

# A lock timeout on the generation read is contention, not supersession. Reading
# it as `stale` exits silently AND spends no fire, so the bound never advances.
seed_probe_state 12
PROBE_OUT=$(SESSION_STATE_SH="$FAULT_SH" STATE_FILE="$STATE_FILE" REPO_KEY="$REPO_KEY" \
  TICK_GENERATION="$GEN" HORIZON_STATUS=critical FAULT_ON=get FAULT_RC=6 \
  bash -c "$BLOCK_PROBE" 2>/dev/null | tail -1)
check_eq "probe: lock timeout on generation read fails closed, not 'stale'" "PROBE=fail-closed" "$PROBE_OUT"

# rc 3 (no state file has ever been written) IS legitimately "no generation".
seed_probe_state 12
PROBE_OUT=$(SESSION_STATE_SH="$FAULT_SH" STATE_FILE="$STATE_FILE" REPO_KEY="$REPO_KEY" \
  TICK_GENERATION="$GEN" HORIZON_STATUS=critical FAULT_ON=get FAULT_RC=3 \
  bash -c "$BLOCK_PROBE" 2>/dev/null | tail -1)
check_eq "probe: rc 3 on generation read is stale, not fail-closed" "PROBE=stale" "$PROBE_OUT"

# The thrash guard is only a guard if the counter is a number: an empty write is
# coerced back to 0 by 2D.6's own validation, so MAX_LIMIT_HITS could never bite.
seed_day_state
RECORD_OUT=$(SESSION_STATE_SH="$SESSION_STATE_SH" REPO_KEY="$REPO_KEY" \
  PARK_RESET_KNOWN=false PROBE_MAX_FIRES=12 bash -c "$BLOCK_RECORD" 2>/dev/null | tail -1)
check_eq "record: unset NEW_HITS is refused" "PARK_RECORD=error rc=hits" "$RECORD_OUT"
check_eq "record: refused write claimed no cause" "null" "$(day_get limit_cause)"
check_eq "record: refused write left the counter alone" "0" "$(day_get consecutive_limit_hits)"

# A failed record write must report the failure, not a written record. The park
# record is now ONE composed call, so the fault is injected on that call (`cas`)
# rather than on a follow-up --set that no longer exists.
seed_day_state
RECORD_OUT=$(SESSION_STATE_SH="$FAULT_SH" STATE_FILE="$STATE_FILE" REPO_KEY="$REPO_KEY" \
  PARK_RESET_KNOWN=false PROBE_MAX_FIRES=12 NEW_HITS=1 FAULT_ON=cas FAULT_RC=6 \
  bash -c "$BLOCK_RECORD" 2>/dev/null | tail -1)
check_eq "record: failed record write reports error" "PARK_RECORD=error rc=6" "$RECORD_OUT"
check_eq "record: failed record write claimed no cause" "null" "$(day_get limit_cause)"
check_eq "record: failed record write wrote no probe bound" "null" \
  "$(day_get limit_probe_fires_remaining)"

# ---------------------------------------------------------------------------
echo "== Greptile round: expired-but-unresolved park, and CAS interleaving =="
# ---------------------------------------------------------------------------
# P1: an unknown-reset park sets parked_until to exactly cadence x fires ahead,
# which is the same instant the last probe fires — so a spent bound always sits
# fractionally in the PAST. Both recovery sites must consult the bound before the
# expiry shortcut, or they call a standing park "resolved", erase the
# manual-resume state, and arm a loop the still-closed execution gate then blocks.
require_text "2D.1(b+) checks the spent bound before expiry" "$SKILL" \
  'spent bound outlives its own deadline'
require_text "2D.5 checks the spent bound before expiry" "$SKILL" \
  'Read that pair before applying the expiry test'
require_text "spent bound stays parked whatever parked_until says" "$SKILL" \
  'stays parked whatever `parked_until` says'
require_text "spent-bound recovery names the manual resume" "$SKILL" \
  'probe bound spent.*resume manually with /pause-resume'
# Non-vacuity for the ordering claim. The finding is ORDER, not presence: each
# recovery paragraph is one long line, so take the line carrying the expiry
# phrase and assert the bound check sits at a smaller offset WITHIN THAT LINE.
# A test that merely greps both strings would pass with the guard written after
# the shortcut it is supposed to qualify — i.e. with the bug still in place.
assert_bound_precedes_expiry() {
  local desc="$1" marker="$2" line off_bound off_expiry
  line=$(grep -F -- "$marker" "$SKILL" | head -1)
  if [ -z "$line" ]; then
    FAIL=$((FAIL + 1)); echo "FAIL — $desc (no line carrying '$marker')"; return
  fi
  local before="${line%%probe bound spent*}"
  if [ "$before" = "$line" ]; then
    FAIL=$((FAIL + 1)); echo "FAIL — $desc (that paragraph never checks the spent bound)"; return
  fi
  off_bound=${#before}
  local before_e="${line%%$marker*}"
  off_expiry=${#before_e}
  if [ "$off_bound" -lt "$off_expiry" ]; then
    PASS=$((PASS + 1)); echo "ok   — $desc (bound at $off_bound, expiry at $off_expiry)"
  else
    FAIL=$((FAIL + 1)); echo "FAIL — $desc (bound at $off_bound is NOT before expiry at $off_expiry)"
  fi
}
assert_bound_precedes_expiry "2D.1(b+) qualifies its expiry shortcut" 'the park resolved or never existed'
assert_bound_precedes_expiry "2D.5 qualifies its expiry shortcut"     'may recovery continue normally'

# P1: the cause CAS and the metadata write used to be two lock holds, so a
# reactive kill landing between them could leave a record mixing both paths'
# fields. Since #1445 they are ONE composed write, so the window is gone — but
# the outcome it guarded still has to hold.
seed_day_state
RECORD_OUT=$(SESSION_STATE_SH="$SESSION_STATE_SH" REPO_KEY="$REPO_KEY" \
  PARK_RESET_KNOWN=false PROBE_MAX_FIRES=12 NEW_HITS=1 bash -c "$BLOCK_RECORD" 2>/dev/null | tail -1)
check_eq "record: uncontended write still reports written" "PARK_RECORD=written" "$RECORD_OUT"

# ---------------------------------------------------------------------------
echo "== Atomic park record + wake identity (issue #1445) =="
# ---------------------------------------------------------------------------
# The mid-write steal this section used to simulate is no longer expressible:
# there is no gap between the cause CAS and the metadata write to land inside.
# What replaces it is the property that gap made impossible — under genuine
# contention exactly one path writes, and the surviving record is entirely that
# path's, never a blend. The two writers below carry DIFFERENT metadata, so a
# mixed record is detectable rather than merely improbable.
seed_day_state
RC_P_FILE="$STUB_DIR/rc_preemptive"; RC_R_FILE="$STUB_DIR/rc_reactive"
( SESSION_STATE_SH="$SESSION_STATE_SH" REPO_KEY="$REPO_KEY" \
    PARK_RESET_KNOWN=false PROBE_MAX_FIRES=12 NEW_HITS=1 \
    bash -c "$BLOCK_RECORD" >"$STUB_DIR/out_preemptive" 2>/dev/null
  tail -1 "$STUB_DIR/out_preemptive" > "$RC_P_FILE" ) &
( "$SESSION_STATE_SH" --cas ".repos[\"$REPO_KEY\"].day.limit_cause=\"reactive\"" \
    --expect null \
    --set ".repos[\"$REPO_KEY\"].day.limit_kind=\"rolling_window\"" \
    --set ".repos[\"$REPO_KEY\"].day.limit_probe_fires_remaining=null" \
    --set ".repos[\"$REPO_KEY\"].day.consecutive_limit_hits=99" >/dev/null 2>&1
  printf 'rc=%s' "$?" > "$RC_R_FILE" ) &
wait
RACE_RECORD_OUT="$(cat "$RC_P_FILE")"
RACE_REACTIVE_RC="$(sed -n 's/^rc=//p' "$RC_R_FILE")"
# Exactly one of the two may have written; the pre-emptive block reports which
# side it ended on, and the reactive claim reports 0 (won) or 7 (lost).
case "$RACE_RECORD_OUT:$RACE_REACTIVE_RC" in
  "PARK_RECORD=written:7"|"PARK_RECORD=superseded:0")
    PASS=$((PASS + 1)); echo "ok   — concurrent records: exactly one path won ($RACE_RECORD_OUT / reactive rc=$RACE_REACTIVE_RC)" ;;
  *)
    FAIL=$((FAIL + 1)); echo "FAIL — concurrent records: both or neither won ($RACE_RECORD_OUT / reactive rc=$RACE_REACTIVE_RC)" ;;
esac
# The surviving record must be entirely one writer's. A cause from one path
# beside the other path's bound or thrash counter is exactly the transiently
# mixed record #1445 exists to make unreachable.
RACE_TRIPLE="$(day_get limit_cause)|$(day_get limit_probe_fires_remaining)|$(day_get consecutive_limit_hits)"
case "$RACE_TRIPLE" in
  "preemptive|12|1"|"reactive|null|99")
    PASS=$((PASS + 1)); echo "ok   — concurrent records: the survivor is entirely one path's ($RACE_TRIPLE)" ;;
  *)
    FAIL=$((FAIL + 1)); echo "FAIL — concurrent records: mixed or partial record ($RACE_TRIPLE)" ;;
esac

# The wake identity pair is the same story: id and generation land together or
# not at all. `WAKE_PUBLISH=lost` is now exercised through the REAL skill block
# (extracted from the anchor), not only through a proxy CAS on the primitive.
run_wake() {   # run_wake <task-id> <generation>
  SESSION_STATE_SH="$SESSION_STATE_SH" STATE_FILE="$STATE_FILE" REPO_KEY="$REPO_KEY" \
    WAKE_TASK_ID="$1" WAKE_GENERATION="$2" \
    bash -c "$BLOCK_WAKE" 2>/dev/null | tail -1
}

make_taskstop_stub 0
seed_day_state
check_eq "wake: publishes on a free slot" "WAKE_PUBLISH=armed" "$(run_wake probe-task probe-gen-1)"
check_eq "wake: task id written"   "probe-task"  "$(day_get limit_resume_task_id)"
check_eq "wake: generation written with it" "probe-gen-1" "$(day_get limit_resume_generation)"

# A wake already armed by the reactive path: our publish loses, our Monitor is
# stopped, and — the atomicity half — our generation never lands beside their id.
seed_day_state
"$SESSION_STATE_SH" --set ".repos[\"$REPO_KEY\"].day.limit_resume_task_id=\"reactive-task\"" \
  --set ".repos[\"$REPO_KEY\"].day.limit_resume_generation=\"limit-gen-1\"" >/dev/null
check_eq "wake: loses to an armed wake" "WAKE_PUBLISH=lost" "$(run_wake probe-task probe-gen-2)"
check_eq "wake: the armed identity survives" "reactive-task" "$(day_get limit_resume_task_id)"
check_eq "wake: the loser's generation was NOT written" "limit-gen-1" \
  "$(day_get limit_resume_generation)"

# A write failure is not a lost race: the board is parked with no wake at all,
# which the block must surface rather than report as armed.
seed_day_state
check_eq "wake: a failed publish reports failed, not lost" "WAKE_PUBLISH=failed" \
  "$(SESSION_STATE_SH="$FAULT_SH" STATE_FILE="$STATE_FILE" REPO_KEY="$REPO_KEY" \
     WAKE_TASK_ID=probe-task WAKE_GENERATION=probe-gen-3 FAULT_ON=cas FAULT_RC=6 \
     bash -c "$BLOCK_WAKE" 2>/dev/null | tail -1)"
check_eq "wake: a failed publish wrote no generation" "null" "$(day_get limit_resume_generation)"

# ...and when the orphaned Monitor cannot be stopped, the ID has to be surfaced.
make_taskstop_stub 1
seed_day_state
"$SESSION_STATE_SH" --set ".repos[\"$REPO_KEY\"].day.limit_resume_task_id=\"reactive-task\"" >/dev/null
check_eq "wake: an unstoppable orphan reports stranded" "WAKE_PUBLISH=stranded" \
  "$(run_wake probe-task probe-gen-4)"
make_taskstop_stub 0

# The abort release must be keyed on `limit_cause`, never on the claim's own
# timestamp. With a KNOWN reset, 2D.7's PARK_EPOCH *is* the vendor reset epoch,
# and a reactive kill parking off the same signal computes the same instant — so
# `--expect "<our timestamp>"` matches a park that is not ours and clears a real
# one while its wake stays armed. The collision is constructed exactly here: both
# paths carry the identical parked_until.
COLLIDING_TS="2026-08-28T09:00:00Z"
jq -n --arg k "$REPO_KEY" --arg ts "$COLLIDING_TS" '{repos: {($k): {day: {
    parked_until: $ts, limit_kind: "rolling_window", limit_cause: "reactive",
    limit_probe_fires_remaining: null, limit_resume_task_id: "reactive-task",
    limit_resume_generation: "limit-gen-1", consecutive_limit_hits: 2}}}}' > "$STATE_FILE"
RELEASE_RC=0
"$SESSION_STATE_SH" --cas ".repos[\"$REPO_KEY\"].day.limit_cause=null" --expect null \
  --set ".repos[\"$REPO_KEY\"].day.parked_until=null" \
  --set ".repos[\"$REPO_KEY\"].day.limit_probe_fires_remaining=null" >/dev/null 2>&1 || RELEASE_RC=$?
check_eq "release: loses to a reactive park sharing the same timestamp" "7" "$RELEASE_RC"
check_eq "release: the reactive park survives" "$COLLIDING_TS" "$(day_get parked_until)"
check_eq "release: the reactive wake survives"  "reactive-task" "$(day_get limit_resume_task_id)"
# Non-vacuity: the old timestamp-keyed shape would have cleared that same park,
# which is the bug the gate change fixes — so it must NOT be what we ship.
STALE_RC=0
"$SESSION_STATE_SH" --cas ".repos[\"$REPO_KEY\"].day.parked_until=null" \
  --expect "\"$COLLIDING_TS\"" >/dev/null 2>&1 || STALE_RC=$?
check_eq "control: the timestamp-keyed release WOULD have cleared it" "0" "$STALE_RC"
check_eq "control: ...leaving a wake armed over no park" "null" "$(day_get parked_until)"
# Positive control: an abort with no competing park still clears its own claim.
seed_day_state
run_claim >/dev/null
OWN_RELEASE_RC=0
"$SESSION_STATE_SH" --cas ".repos[\"$REPO_KEY\"].day.limit_cause=null" --expect null \
  --set ".repos[\"$REPO_KEY\"].day.parked_until=null" \
  --set ".repos[\"$REPO_KEY\"].day.limit_probe_fires_remaining=null" >/dev/null 2>&1 || OWN_RELEASE_RC=$?
check_eq "release: an uncontended abort clears its own claim" "0" "$OWN_RELEASE_RC"
check_eq "release: parked_until cleared" "null" "$(day_get parked_until)"
check_eq "release: the -1 sentinel retired with it" "null" "$(day_get limit_probe_fires_remaining)"
require_text "the release is keyed on limit_cause, not the timestamp" "$SKILL" \
  'Gate the release on `limit_cause`, not on your own timestamp'

# ---------------------------------------------------------------------------
echo "== Three-valued limit_probe_fires_remaining (issue #1445) =="
# ---------------------------------------------------------------------------
# `null` used to mean two incompatible things: "reset time known — re-arm the
# sleep-until-reset one-shot" and "reset unknown, bound not written yet". The
# claim now stamps `-1` for the second, so the minutes-long window between the
# claim and the record reads honestly instead of ordering the wrong wake.
seed_day_state
run_claim >/dev/null
check_eq "claim: unknown reset stamps the -1 sentinel" "-1" \
  "$(day_get limit_probe_fires_remaining)"

seed_day_state
run_claim "$(( $(date -u +%s) + 3600 ))" >/dev/null
check_eq "claim: known reset keeps null (legacy meaning preserved)" "null" \
  "$(day_get limit_probe_fires_remaining)"

# The record replaces the sentinel with the real bound, in its own single write.
seed_day_state
run_claim >/dev/null
run_record false >/dev/null
check_eq "record: the real bound replaces the sentinel" "12" \
  "$(day_get limit_probe_fires_remaining)"

# A probe fire arriving against the sentinel has no bound to spend: the
# non-negative-integer guard must reject it rather than treat -1 as a count.
seed_probe_state -1
check_eq "probe: the -1 sentinel fails closed, never decrements" "PROBE=fail-closed" \
  "$(run_probe "$GEN" critical | tail -1)"
check_eq "probe: the sentinel is left untouched" "-1" "$(day_get limit_probe_fires_remaining)"

# Recovery and teardown must know the third value, or -1 silently falls into the
# null branch and re-arms the very wake the teardown stopped.
require_text "2D.1(b+) handles the -1 sentinel"  "$SKILL" 'is the third value'
require_text "2D.5 handles the -1 sentinel"      "$SKILL" 'zero, .-1., or unreadable'
require_text "the bound is documented three-valued" "$SKILL" 'bound field is three-valued'
require_text "schema documents the three-valued bound" "$SCHEMA" 'THREE-VALUED'
require_text "day-mode doc records the sentinel"  "$DAY_MODE_DOC" 'probe bound is three-valued'

# ---------------------------------------------------------------------------
echo "== Negative control: the 2D.7 blocks require the composed primitive =="
# ---------------------------------------------------------------------------
# Non-vacuity for the whole atomicity section above. Those blocks are only
# meaningful if they genuinely depend on #1445's composed --cas, so run them
# against a session-state.sh WITHOUT the composition: they must FAIL there, not
# quietly succeed by some other route.
#
# The control is materialised inside a real detached git worktree rather than a
# flat copy in a temp dir. session-state.sh resolves state-lock.sh,
# lib/repo-normalizer.sh and ../reference/session-state-schema.json relative to
# its OWN location, so a lone copy aborts on a missing sibling and "fails" for
# the wrong reason — a control that proves nothing about the composition.
#
# The composition is removed by re-narrowing the two parser guards, literally
# (awk index/substr, no regex — the guard text is full of regex metacharacters).
# The substitution is idempotent: against a tree that never had the composition
# it is a no-op and the checkout is already the control, so this cannot go
# vacuous once origin/main carries the fix.
CTRL_ROOT="$(mktemp -d)"
CTRL_DIR="$CTRL_ROOT/base"        # must not exist — `git worktree add` creates it
if git -C "$REPO_ROOT" worktree add --detach --quiet "$CTRL_DIR" HEAD >/dev/null 2>&1; then
  PASS=$((PASS + 1)); echo "ok   — control worktree created (detached, siblings intact)"
else
  # Fail closed: a control that could not be built is not a control that passed.
  CTRL_DIR=""
  FAIL=$((FAIL + 1)); echo "FAIL — could not create the control worktree; the atomicity section is unverified"
fi

if [[ -n "$CTRL_DIR" ]]; then
  CTRL_SS="$CTRL_DIR/.claude/scripts/session-state.sh"
  awk '
  BEGIN {
    set_new = "if [[ -n \"$MODE\" && \"$MODE\" != \"set\" && \"$MODE\" != \"cas\" ]]; then"
    set_old = "if [[ -n \"$MODE\" && \"$MODE\" != \"set\" ]]; then"
    cas_new = "if [[ -n \"$MODE\" && \"$MODE\" != \"cas\" && \"$MODE\" != \"set\" ]]; then"
    cas_old = "if [[ -n \"$MODE\" && \"$MODE\" != \"cas\" ]]; then"
  }
  {
    i = index($0, set_new)
    if (i > 0) { print substr($0, 1, i - 1) set_old; next }
    i = index($0, cas_new)
    if (i > 0) { print substr($0, 1, i - 1) cas_old; next }
    print
  }' "$CTRL_SS" > "$CTRL_SS.stripped" && mv "$CTRL_SS.stripped" "$CTRL_SS"
  chmod +x "$CTRL_SS"

  if bash -n "$CTRL_SS" 2>/dev/null; then
    PASS=$((PASS + 1)); echo "ok   — control script still parses after the strip"
  else
    FAIL=$((FAIL + 1)); echo "FAIL — the strip broke the control script (it would fail for the wrong reason)"
  fi

  # Read the control RUN, not just its verdict: prove the control is a WORKING
  # script that refuses only the composition, never a broken one that refuses
  # everything. Both single-flag modes must still behave.
  CTRL_HOME="$(mktemp -d)"
  CTRL_SET_RC=0
  HOME="$CTRL_HOME" bash "$CTRL_SS" --raw-path --set '.probe=ok' >/dev/null 2>&1 || CTRL_SET_RC=$?
  check_eq "control: a plain --set still works" "0" "$CTRL_SET_RC"
  CTRL_CAS_RC=0
  HOME="$CTRL_HOME" bash "$CTRL_SS" --raw-path --cas '.slot="claimed"' --expect null >/dev/null 2>&1 || CTRL_CAS_RC=$?
  check_eq "control: a plain --cas still works" "0" "$CTRL_CAS_RC"
  CTRL_COMPOSED_RC=0
  HOME="$CTRL_HOME" bash "$CTRL_SS" --raw-path --cas '.other="x"' --expect null \
    --set '.extra=1' >/dev/null 2>&1 || CTRL_COMPOSED_RC=$?
  check_eq "control: the composition is refused as a usage error (exit 2)" "2" "$CTRL_COMPOSED_RC"
  rm -rf "$CTRL_HOME"

  # The blocks themselves, against that control. `written` / `armed` here would
  # mean the sections above pass without the primitive — i.e. prove nothing.
  seed_day_state
  CTRL_RECORD_OUT=$(SESSION_STATE_SH="$CTRL_SS" REPO_KEY="$REPO_KEY" \
    PARK_RESET_KNOWN=false PROBE_MAX_FIRES=12 NEW_HITS=1 \
    bash -c "$BLOCK_RECORD" 2>/dev/null | tail -1)
  check_eq "control: the park record cannot be written without composition" \
    "PARK_RECORD=error rc=2" "$CTRL_RECORD_OUT"
  check_eq "control: and it claimed no cause" "null" "$(day_get limit_cause)"

  seed_day_state
  CTRL_WAKE_OUT=$(SESSION_STATE_SH="$CTRL_SS" STATE_FILE="$STATE_FILE" REPO_KEY="$REPO_KEY" \
    WAKE_TASK_ID=probe-task WAKE_GENERATION=probe-gen-ctl \
    bash -c "$BLOCK_WAKE" 2>/dev/null | tail -1)
  check_eq "control: the wake identity cannot be published without composition" \
    "WAKE_PUBLISH=failed" "$CTRL_WAKE_OUT"
  check_eq "control: and no task id was published" "null" "$(day_get limit_resume_task_id)"
fi

echo
echo "passed: $PASS   failed: $FAIL"
[[ "$FAIL" -eq 0 ]]
