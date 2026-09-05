#!/usr/bin/env bash
# catalog: tests — Tests the watch-only usage-horizon contract shared by /pr-monitor-and-manage and /babysit-pr (#1444)
#
# Tests the honour-and-adopt usage-horizon contract for the two watch-only
# loops — issue #1444.
#
# WHAT IS UNDER TEST
#   The REAL fenced bash in `.claude/reference/subagent-thread-limit-park.md`
#   §8.1 (`watchonly-horizon-posture`), pulled out at run time by
#   `lib/skill-bash.sh` and driven with the verdicts §7.1's gate block produces,
#   plus the wiring in `/pr-monitor-and-manage`, `/pr-monitor-and-manage-wake`
#   and `/babysit-pr` that consumes it. Nothing below is a transcription of the
#   posture block: edit §8.1 and this suite runs the edit. Same principle as
#   `pm-day-horizon.test.sh` and `subagent-limit-park.test.sh`.
#
# WHY (issue #1444)
#   #1619 gave a subagent-running thread the pre-emptive park. These two loops
#   watch PRs they did not launch, so §8 entitles them to honour a park and
#   never to claim one. Three things have to hold and none is visible from prose
#   review: `unknown` must never park and must never read as `clear`; a
#   `critical` verdict must stand the loop down in its OWN namespace with no
#   write anywhere under `.repos["<key>"].day.*`; and suppressing a launch must
#   not suppress the work already in flight, or a PR one merge from done is
#   stranded for the length of the window.
#
# NON-VACUITY
#   The posture block is driven through the same stubbed `usage-horizon.sh` the
#   sibling suites use (including a stub that does not exist and one that prints
#   garbage), the adopt probe is driven against a REAL `session-state.sh` over a
#   throwaway $HOME so an absent park and an unreadable one are distinguished by
#   reading state back, and every prose assertion is paired with a negative
#   control proving the matcher can fail.
#
# Requires: bash 3.2+ (macOS system bash), jq. Offline: no gh, no git, no network.
set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TEST_DIR/../../.." && pwd)"
DOC="$REPO_ROOT/.claude/reference/subagent-thread-limit-park.md"
PMM="$REPO_ROOT/.claude/skills/pr-monitor-and-manage/SKILL.md"
PMM_LIFECYCLE="$REPO_ROOT/.claude/skills/pr-monitor-and-manage/references/pmm-lifecycle.md"
PMM_WAKE="$REPO_ROOT/.claude/skills/pr-monitor-and-manage-wake/SKILL.md"
BABYSIT="$REPO_ROOT/.claude/skills/babysit-pr/SKILL.md"
DAY_MODE_DOC="$REPO_ROOT/.claude/reference/pm-day-mode.md"
SCHEMA="$REPO_ROOT/.claude/reference/session-state-schema.json"
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
refute_text() {
  local desc="$1" file="$2" pattern="$3"
  if grep -Eq -- "$pattern" "$file"; then
    FAIL=$((FAIL + 1)); echo "FAIL — $desc (unexpected match for /$pattern/ in $(basename "$file"))"
  else
    PASS=$((PASS + 1)); echo "ok   — $desc"
  fi
}

# A failed extraction is fatal, never skipped: a suite that silently runs zero
# lines of the real block passes green forever.
BLOCK_POSTURE="$(extract_skill_bash "$DOC" watchonly-horizon-posture)" || exit 1
BLOCK_GATE="$(extract_skill_bash "$DOC" subagent-limit-horizon-gate)"  || exit 1

field() { printf '%s\n' "$1" | sed -n "s/^$2=//p" | head -1; }

# Stand-in for usage-horizon.sh: --check prints the STATUS/REASON pair on the
# documented exit code; --observe exits 0 whatever the verdict.
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

run_posture() {  # run_posture <HORIZON_STATUS> [SESSION_STATE_SH] [REPO_KEY]
  HORIZON_STATUS="$1" SESSION_STATE_SH="${2:-}" REPO_KEY="${3:-}" \
    bash -c "$BLOCK_POSTURE" 2>/dev/null
}
run_gate() {     # run_gate <script-path> [remaining] [limit]
  USAGE_HORIZON_SH="$1" HORIZON_REMAINING="${2:-}" HORIZON_LIMIT="${3:-}" \
    bash -c "$BLOCK_GATE" 2>/dev/null
}

seed_state() {   # seed_state <limit_cause-json> [parked_until-json]
  rm -f "$STATE_FILE"
  printf '{"repos":{"%s":{"day":{"active":true,"limit_cause":%s,"parked_until":%s}}}}\n' \
    "$REPO_KEY" "$1" "${2:-null}" > "$STATE_FILE"
}

# ---------------------------------------------------------------------------
echo "== §8.1 posture: the four verdicts, and what each one stops =="
# ---------------------------------------------------------------------------
# The start/finish split IS the contract: `approaching` and `unknown` bar a new
# launch and leave a merge-ready PR landable, `critical` bars both. A test that
# only checked LAUNCH_OK would pass on a block that also froze every merge.

OUT=$(run_posture clear)
check_eq "clear: may launch"            "true"  "$(field "$OUT" WATCH_LAUNCH_OK)"
check_eq "clear: may finish"            "true"  "$(field "$OUT" WATCH_FINISH_OK)"
check_eq "clear: does not stand down"   "false" "$(field "$OUT" WATCH_STAND_DOWN)"
check_eq "clear: no idle reason"        ""      "$(field "$OUT" WATCH_IDLE_REASON)"

OUT=$(run_posture approaching)
check_eq "approaching: launches nothing new" "false" "$(field "$OUT" WATCH_LAUNCH_OK)"
check_eq "approaching: STILL finishes in-flight work" "true" "$(field "$OUT" WATCH_FINISH_OK)"
check_eq "approaching: does not stand down"  "false" "$(field "$OUT" WATCH_STAND_DOWN)"
check_eq "approaching: names the posture"    "paused (horizon approaching)" \
  "$(field "$OUT" WATCH_IDLE_REASON)"

OUT=$(run_posture critical)
check_eq "critical: launches nothing"   "false" "$(field "$OUT" WATCH_LAUNCH_OK)"
check_eq "critical: finishes nothing"   "false" "$(field "$OUT" WATCH_FINISH_OK)"
check_eq "critical: stands down"        "true"  "$(field "$OUT" WATCH_STAND_DOWN)"
check_eq "critical: names the posture"  "paused (horizon critical)" \
  "$(field "$OUT" WATCH_IDLE_REASON)"

# AC 3: `unknown` never parks and never refills — matching 2D.7 exactly.
OUT=$(run_posture unknown)
check_eq "unknown: launches nothing new" "false" "$(field "$OUT" WATCH_LAUNCH_OK)"
check_eq "unknown: NEVER stands down"    "false" "$(field "$OUT" WATCH_STAND_DOWN)"
check_eq "unknown: still finishes in-flight work" "true" "$(field "$OUT" WATCH_FINISH_OK)"
check_eq "unknown: names the posture"    "paused (horizon unknown)" \
  "$(field "$OUT" WATCH_IDLE_REASON)"

# Every unrecognised value is `unknown`, never `clear`. A `!= critical` test
# would read each of these as permission to dispatch.
for BOGUS in "" "CLEAR" "clear " "ok" "STATUS=clear" "criticalish"; do
  OUT=$(run_posture "$BOGUS")
  check_eq "bogus verdict '$BOGUS' does not read as clear" "false" \
    "$(field "$OUT" WATCH_LAUNCH_OK)"
  check_eq "  and never stands down"                       "false" \
    "$(field "$OUT" WATCH_STAND_DOWN)"
done
# An unset HORIZON_STATUS is the same absent reading, not a crash.
OUT=$(HORIZON_STATUS= bash -c "$BLOCK_POSTURE" 2>/dev/null)
check_eq "unset verdict falls back to unknown" "paused (horizon unknown)" \
  "$(field "$OUT" WATCH_IDLE_REASON)"

# ---------------------------------------------------------------------------
echo "== §7.1 gate -> §8.1 posture: the two blocks agree on every verdict =="
# ---------------------------------------------------------------------------
# The gate names the verdict; the posture decides what a watch-only loop does
# with it. Feeding one into the other is the only way to prove the pair cannot
# disagree — including on the degraded inputs, where a divergence would be a
# fail-open rather than a cosmetic difference.
for CASE in clear approaching critical unknown; do
  GATE_OUT=$(run_gate "$(make_horizon_stub "$CASE")" 500000 1000000)
  VERDICT=$(field "$GATE_OUT" HORIZON_STATUS)
  POST_OUT=$(run_posture "$VERDICT")
  # The gate's own park flag and the posture's stand-down must agree: they are
  # the same decision seen by a claimer and by an adopter.
  check_eq "gate+posture agree on '$CASE'" \
    "$(field "$GATE_OUT" HORIZON_PARK)" "$(field "$POST_OUT" WATCH_STAND_DOWN)"
done
GARBAGE="$STUB_DIR/garbage.sh"
printf '#!/usr/bin/env bash\necho "Review limit reached"\nexit 0\n' > "$GARBAGE"
chmod +x "$GARBAGE"
for SCRIPT in "$STUB_DIR/does-not-exist.sh" "$GARBAGE" ""; do
  GATE_OUT=$(run_gate "$SCRIPT" 500000 1000000)
  POST_OUT=$(run_posture "$(field "$GATE_OUT" HORIZON_STATUS)")
  check_eq "degraded '${SCRIPT:-<unresolved>}' reaches unknown, not clear" \
    "unknown" "$(field "$GATE_OUT" HORIZON_STATUS)"
  check_eq "  and the posture launches nothing" "false" \
    "$(field "$POST_OUT" WATCH_LAUNCH_OK)"
  check_eq "  and parks nothing"                "false" \
    "$(field "$POST_OUT" WATCH_STAND_DOWN)"
done
# Negative control for the agreement comparison itself: two DIFFERENT verdicts
# must not compare equal, or every check above would pass vacuously.
A=$(run_posture clear    | grep -E '^WATCH_STAND_DOWN=')
B=$(run_posture critical | grep -E '^WATCH_STAND_DOWN=')
if [[ "$A" != "$B" ]]; then
  PASS=$((PASS + 1)); echo "ok   — negative control: the agreement check can fail"
else
  FAIL=$((FAIL + 1)); echo "FAIL — negative control: clear and critical compared equal"
fi

# ---------------------------------------------------------------------------
echo "== The adopt probe is READ-ONLY, and its failure is never a verdict =="
# ---------------------------------------------------------------------------
# AC 2: honour an existing park without double-parking against day mode's
# record. The probe reads `.repos[<key>].day.limit_cause` and NEVER writes it —
# asserted by reading the file back, since a block that printed `true` while
# claiming the slot would pass a printed-output-only test.

seed_state '"preemptive"'
BEFORE=$(cat "$STATE_FILE")
OUT=$(run_posture critical "$SESSION_STATE_SH" "$REPO_KEY")
check_eq "existing park is seen"        "true" "$(field "$OUT" WATCH_PARK_SEEN)"
check_eq "  and the loop still stands down" "true" "$(field "$OUT" WATCH_STAND_DOWN)"
check_eq "  and the park record is BYTE-IDENTICAL afterwards" "$BEFORE" "$(cat "$STATE_FILE")"
check_eq "  and limit_cause was not re-claimed" "preemptive" \
  "$("$SESSION_STATE_SH" --get ".repos[\"$REPO_KEY\"].day.limit_cause" 2>/dev/null)"

seed_state 'null'
BEFORE=$(cat "$STATE_FILE")
OUT=$(run_posture critical "$SESSION_STATE_SH" "$REPO_KEY")
check_eq "no park open: reported as absent" "false" "$(field "$OUT" WATCH_PARK_SEEN)"
check_eq "  and the loop stands down anyway" "true" "$(field "$OUT" WATCH_STAND_DOWN)"
# The whole point of the #1444 decision: an ABSENT park is not an invitation to
# open one. Nothing under .day.* may change on the verdict that would tempt it.
check_eq "  and it opens no park of its own" "$BEFORE" "$(cat "$STATE_FILE")"

# A HALF-ASSEMBLED park: 2D.7 Step 1 claims parked_until and takes limit_cause
# only when it finishes the record, so a probe reading limit_cause alone would
# report "no park open" inside that window — and then this loop would say it
# opened nothing while a park was in fact being assembled underneath it.
seed_state 'null' '"2026-12-01T10:00:00Z"'
BEFORE=$(cat "$STATE_FILE")
OUT=$(run_posture critical "$SESSION_STATE_SH" "$REPO_KEY")
check_eq "park claimed but not yet finished is still SEEN" "true" \
  "$(field "$OUT" WATCH_PARK_SEEN)"
check_eq "  and nothing was written over the half-assembled record" "$BEFORE" \
  "$(cat "$STATE_FILE")"
# Control for that case: with BOTH fields null the same seed reads as absent, so
# the assertion above is pinning parked_until and not just the seed's shape.
seed_state 'null' 'null'
OUT=$(run_posture critical "$SESSION_STATE_SH" "$REPO_KEY")
check_eq "control: both fields null reads as absent" "false" \
  "$(field "$OUT" WATCH_PARK_SEEN)"

# rc 3 (no state file has ever been written) is a readable absence, not a fault.
rm -f "$STATE_FILE"
OUT=$(run_posture critical "$SESSION_STATE_SH" "$REPO_KEY")
check_eq "no state file: readable absence, not unreadable" "false" \
  "$(field "$OUT" WATCH_PARK_SEEN)"
check_eq "  and the probe wrote no state file" "absent" \
  "$( [ -f "$STATE_FILE" ] && echo present || echo absent )"

# An unreadable slot must stay unreadable. Reporting `false` there would say
# "no park is open" about a park nobody could look at.
BROKEN="$STUB_DIR/broken-session-state.sh"
printf '#!/usr/bin/env bash\nexit 6\n' > "$BROKEN"; chmod +x "$BROKEN"
OUT=$(run_posture critical "$BROKEN" "$REPO_KEY")
check_eq "lock timeout (rc 6): unreadable, not absent" "unreadable" \
  "$(field "$OUT" WATCH_PARK_SEEN)"
check_eq "  and the loop still stands down" "true" "$(field "$OUT" WATCH_STAND_DOWN)"
OUT=$(run_posture critical "" "$REPO_KEY")
check_eq "unresolved session-state.sh: unreadable" "unreadable" \
  "$(field "$OUT" WATCH_PARK_SEEN)"
OUT=$(run_posture critical "$SESSION_STATE_SH" "")
check_eq "unresolvable repo key: unreadable" "unreadable" \
  "$(field "$OUT" WATCH_PARK_SEEN)"

# The probe runs ONLY on a stand-down — a non-critical verdict must not spend a
# state read, and must not report a park it never looked for.
seed_state '"preemptive"'
for CASE in clear approaching unknown; do
  OUT=$(run_posture "$CASE" "$SESSION_STATE_SH" "$REPO_KEY")
  check_eq "$CASE: probe not run, park reported false" "false" \
    "$(field "$OUT" WATCH_PARK_SEEN)"
done

# ---------------------------------------------------------------------------
echo "== Wiring: the decision, and the three call sites that consume it =="
# ---------------------------------------------------------------------------

# AC 1: the decision is recorded, in one place, as a contract rather than prose.
require_text "§8.1 records the watch-only contract" \
  "$DOC" 'Honour-and-adopt — the watch-only loop contract'
require_text "  keyed on launch ownership" "$DOC" 'launch ownership, not loop seniority'
require_text "  and forbids the day-slot write outright" \
  "$DOC" 'never .--set. on .\.repos\["<key>"\]\.day\.\*'
require_text "  citing the shared-signal precedent" "$DOC" 'bgwork-ceiling\.sh. and .credit-budget\.sh'
require_text "monitor-mode.md's per-cycle checklist already consults the horizon" \
  "$REPO_ROOT/.claude/rules/monitor-mode.md" 'Usage horizon.*usage-horizon\.sh --observe'

# AC 4: the out-of-scope notes are gone from both places that carried them.
refute_text "pm-day-mode.md no longer excludes the two loops" \
  "$DAY_MODE_DOC" 'remain out of scope \(#1444\)'
require_text "  and names them as readers instead" \
  "$DAY_MODE_DOC" 'run the consult too since #1444, but strictly as readers'
refute_text "/pm 2D.7 no longer says they do not consult the horizon" \
  "$REPO_ROOT/.claude/skills/pm/SKILL.md" 'They do not consult the horizon'

# PMM: consult before action, gate the dispatch, stand down on critical.
require_text "PMM resolves usage-horizon.sh" "$PMM" 'USAGE_HORIZON_SH=\$\(resolve_script usage-horizon\.sh'
require_text "  degrading to unknown rather than clear when it is missing" \
  "$PMM" 'DEGRADED: usage-horizon\.sh not found'
require_text "PMM consults before it acts (Step 3.7)" "$PMM" '## Step 3\.7: Usage-horizon consult'
require_text "  running §7.1 and §8.1 rather than a third copy" \
  "$PMM" '§7\.1.s gate block, then §8\.1.s posture block'
require_text "  suppressing new fixer dispatch on WATCH_LAUNCH_OK=false" \
  "$PMM" 'WATCH_LAUNCH_OK=false. skips Step 5c'
require_text "  and leaving in-flight subagents alone" \
  "$PMM" 'In-flight work is never touched'
require_text "  standing down on critical through its OWN pause" \
  "$PMM" 'Usage-horizon stand-down'
require_text "  tagged with a cause in its own namespace" "$PMM" 'pmm\.pause_cause="usage_horizon"'
require_text "  and arming no re-scan on that route" "$PMM" 'Arm \*\*no\*\* auto-wake re-scan on this route'
refute_text "PMM never claims the park slot" "$PMM" 'session-state\.sh --cas .*limit_cause'
require_text "  and says so explicitly" "$PMM" 'PMM never claims a park'
require_text "the pause marker carries the cause" "$PMM" '\.pmm\.pause_cause=\\"\$PAUSE_CAUSE\\"'
require_text "  mirrored in the lifecycle reference" "$PMM_LIFECYCLE" '\.pmm\.pause_cause=\\"\$PAUSE_CAUSE\\"'
require_text "  and documented in the marker schema" "$PMM_LIFECYCLE" '\| .\.pmm\.pause_cause. \|'
require_text "resume clears the cause with the rest of the marker" \
  "$PMM" '\.pmm\.pause_cause=null'
require_text "  on the -wake path too" "$PMM_WAKE" "set '\.pmm\.pause_cause=null'"

# The wake must re-consult BEFORE teardown, or a refusal is not a no-op.
require_text "the wake re-consults the horizon" "$PMM_WAKE" '## Step 3\.5: Re-consult the usage horizon'
require_text "  before Step 3 stops anything" "$PMM_WAKE" 'before\*\* Step 3 tears anything down'
require_text "  refusing to resume while critical" "$PMM_WAKE" 'Stop nothing, arm nothing, write nothing'
require_text "  and refusing to park further on unknown" \
  "$PMM_WAKE" 'Do not resume dispatch, and park nothing further'

# babysit: same contract, its own namespace, its own cadence hold.
require_text "babysit resolves usage-horizon.sh" \
  "$BABYSIT" 'USAGE_HORIZON_SH=\$\(resolve_script usage-horizon\.sh'
require_text "babysit consults between T2 and T3" "$BABYSIT" '### T2\.5\. Usage-horizon consult'
require_text "  running §7.1 and §8.1 rather than a third copy" \
  "$BABYSIT" '§7\.1.s gate block, then §8\.1.s posture block'
require_text "  keeping /wrap landable on approaching" \
  "$BABYSIT" 'Why ./wrap. survives .approaching. and .unknown'
require_text "  and never orphaning an in-flight dispatch" \
  "$BABYSIT" 'In-flight dispatch is never orphaned'
require_text "babysit widens its own cadence on critical" "$BABYSIT" 'HORIZON_HOLD_MIN'
require_text "  only ever widening" "$BABYSIT" 'EFFECTIVE_MIN < HORIZON_HOLD_MIN'
require_text "  and persisting the verdict in its own namespace" \
  "$BABYSIT" 'babysit\.horizon_status'
refute_text "babysit never claims the park slot" "$BABYSIT" 'session-state\.sh --cas .*limit_cause'
require_text "  and says so explicitly" "$BABYSIT" 'This watcher claims no park'

# Neither loop may write the shared day slot. This is the assertion the whole
# #1444 decision reduces to, so it is checked as a refutation on every file —
# with a POSITIVE control on /pm's own SKILL.md, which does write that slot.
# Without the control this refutation would pass on a typo'd pattern that
# matches nothing anywhere, which is the failure mode a refute-only check has.
DAY_WRITE_RE='\-\-(set|cas) [^|]*\.repos\[[^]]*\]\.day'
for F in "$PMM" "$PMM_LIFECYCLE" "$PMM_WAKE" "$BABYSIT"; do
  refute_text "$(basename "$F") writes nothing under .repos[<key>].day" \
    "$F" "$DAY_WRITE_RE"
done
require_text "positive control — the matcher DOES catch day mode's own day-slot writes" \
  "$REPO_ROOT/.claude/skills/pm/SKILL.md" "$DAY_WRITE_RE"
# And the read the two loops ARE allowed is still there: PMM reads the day block
# to refuse arming beside a live day loop, so a blanket ban on the path would be
# the wrong fix and this pins the distinction between --get and --set/--cas.
require_text "PMM still READS the day block (mutual exclusion, #1194)" \
  "$PMM" '\-\-get "\.repos\[[^]]*\]\.day\.active'

# Schema: both self-park markers are documented as self-park, not as parks.
require_text "schema documents .pmm.pause_cause" "$SCHEMA" '_pause_cause_comment'
require_text "  as PMM's own namespace, not a park" "$SCHEMA" "SELF-PARK bookkeeping in PMM's OWN namespace"
require_text "schema documents the babysit horizon fields" "$SCHEMA" '_horizon_comment'
require_text "  as not a park record" "$SCHEMA" 'They are NOT a park record'
require_text "the day block still names its complete writer set" \
  "$SCHEMA" 'the set of writers named above is complete'

# Negative controls for the matcher itself: an unrelated pattern must not match,
# and a pattern that IS present must not be refutable. Without both, a typo in
# any require_text above would pass silently as an absent-but-unasserted claim.
refute_text "negative control — an unrelated pattern does not match" \
  "$DOC" 'Honour-and-adopt — the claim-anything-you-like contract'
require_text "negative control — a known-present pattern does match" \
  "$DOC" 'Which loop may park which work'

# ---------------------------------------------------------------------------
echo ""
echo "== $PASS passed, $FAIL failed =="
[[ "$FAIL" -eq 0 ]]
