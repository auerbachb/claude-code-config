#!/usr/bin/env bash
# Regression coverage for issue #1525: declared leave time -> deadline-aware
# dispatch -> proactive check-in -> /pause wind-down.
#
# Two halves, deliberately:
#   1. EXECUTES the real skill-embedded bash (via lib/skill-bash.sh) for the two
#      blocks that make decisions — the lead-time cascade and the per-launch
#      deadline decline. A grep-only suite would pass while the logic inverted.
#   2. Pins the cross-file contracts that have no executable form: one deadline
#      source, Monitor-not-CronCreate, disarm-before-delegate, the /pause and
#      /pause-resume teardown entries, and the human-in-chat countermand rule.

set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
# shellcheck source=lib/skill-bash.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/skill-bash.sh"

FAILURES=0
fail() { printf 'FAIL: %s\n' "$*" >&2; FAILURES=$((FAILURES + 1)); }
ok() { printf 'ok   — %s\n' "$*"; }

# A group summary that prints `ok` while its own assertions were failing is a
# false-clean in the report, even when the exit status is right. `ok_group`
# only reports success when the failure counter did not move.
GROUP_MARK=0
group_start() { GROUP_MARK="$FAILURES"; }
ok_group() {
  if [ "$FAILURES" -eq "$GROUP_MARK" ]; then ok "$@"; else
    printf 'FAIL: %s (group had %d failure(s) above)\n' "$1" "$((FAILURES - GROUP_MARK))" >&2
  fi
}

require_text() {
  local file=$1 text=$2 message=$3
  grep -Fq -- "$text" "$ROOT/$file" || fail "$message"
}
reject_text() {
  local file=$1 text=$2 message=$3
  if grep -Fq -- "$text" "$ROOT/$file"; then fail "$message"; fi
}

TMP=$(mktemp -d)
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

LEAVE_SKILL=".claude/skills/leave-by/SKILL.md"
SUBAGENT_SKILL=".claude/skills/subagent/SKILL.md"

# ---------------------------------------------------------------------------
# Part 1a — the lead-time cascade, executed
# ---------------------------------------------------------------------------
LEAD_BLOCK="$(extract_skill_bash "$ROOT/$LEAVE_SKILL" leave-by-lead-cascade)" \
  || { fail 'could not extract the leave-by lead cascade block'; LEAD_BLOCK=""; }

# Stub pm-config-get.sh: prints whatever Budget body the case under test wants.
STUB_CONFIG="$TMP/pm-config-get.sh"
cat >"$STUB_CONFIG" <<'STUB'
#!/usr/bin/env bash
cat "${STUB_BUDGET_FILE:-/dev/null}"
exit "${STUB_CONFIG_RC:-0}"
STUB
chmod +x "$STUB_CONFIG"

run_lead() {
  # $1 = Budget section body ('' for none), $2.. = env assignments
  local budget="$1"; shift
  printf '%s\n' "$budget" >"$TMP/budget.txt"
  (
    set -euo pipefail
    export STUB_BUDGET_FILE="$TMP/budget.txt"
    PM_CONFIG_GET="$STUB_CONFIG"
    # shellcheck disable=SC2163
    while [ "$#" -gt 0 ]; do export "$1"; shift; done
    eval "$LEAD_BLOCK"
    printf '%s %s\n' "$LEAD_MIN" "$LEAD_SOURCE"
  ) 2>/dev/null
}

# Same run, stderr captured: a rejection the user never sees is not a rejection.
run_lead_stderr() {
  local budget="$1"; shift
  printf '%s\n' "$budget" >"$TMP/budget.txt"
  (
    set -euo pipefail
    export STUB_BUDGET_FILE="$TMP/budget.txt"
    PM_CONFIG_GET="$STUB_CONFIG"
    # shellcheck disable=SC2163
    while [ "$#" -gt 0 ]; do export "$1"; shift; done
    eval "$LEAD_BLOCK"
  ) 2>&1 >/dev/null
}

if [ -n "$LEAD_BLOCK" ]; then
  group_start
  OUT=$(run_lead '')
  [ "$OUT" = "30 default" ] || fail "no config and no env must yield the 30-min default (got: $OUT)"

  OUT=$(run_lead 'LEAVE_LEAD_TIME_MIN = 45')
  [ "$OUT" = "45 config" ] || fail "pm-config.md value must win over the code default (got: $OUT)"

  OUT=$(run_lead 'LEAVE_LEAD_TIME_MIN = 45' 'CLAUDE_LEAVE_LEAD_TIME_MIN=60')
  [ "$OUT" = "60 env" ] || fail "env override must win over pm-config.md (got: $OUT)"

  # A commented-out placeholder is documentation, not configuration.
  OUT=$(run_lead '# LEAVE_LEAD_TIME_MIN = 45')
  [ "$OUT" = "30 default" ] || fail "a commented-out knob must not be read as active (got: $OUT)"

  # Out of range is REJECTED (falls back), never clamped: a 2-minute lead is a
  # wind-down that cannot finish, a 600-minute one fires before the work does.
  # Every rejection must fall back AND say so — a silent fallback is indistinguishable
  # from the knob never having been set, which is the failure the warning exists to stop.
  for bad in 2 600 abc; do
    OUT=$(run_lead '' "CLAUDE_LEAVE_LEAD_TIME_MIN=$bad")
    [ "$OUT" = "30 env_rejected" ] \
      || fail "an invalid env lead ('$bad') must fall back to 30, not clamp (got: $OUT)"
    ERR=$(run_lead_stderr '' "CLAUDE_LEAVE_LEAD_TIME_MIN=$bad")
    case "$ERR" in
      *"rejected CLAUDE_LEAVE_LEAD_TIME_MIN='$bad'"*) : ;;
      *) fail "an invalid env lead ('$bad') must warn on stderr (got: $ERR)" ;;
    esac
    # An explicit-but-invalid override must NOT be quietly replaced by a config value:
    # the documented fallback is the default, not "whatever the repo happens to set".
    OUT=$(run_lead 'LEAVE_LEAD_TIME_MIN = 45' "CLAUDE_LEAVE_LEAD_TIME_MIN=$bad")
    [ "$OUT" = "30 env_rejected" ] \
      || fail "a rejected env lead ('$bad') must not fall through to the config value (got: $OUT)"
  done
  OUT=$(run_lead 'LEAVE_LEAD_TIME_MIN = 900')
  [ "$OUT" = "30 default" ] || fail "an out-of-range config lead must fall back to 30 (got: $OUT)"

  # A typo in the config file must be REPORTED, not silently defaulted — otherwise a
  # misconfiguration is indistinguishable from an absent knob.
  OUT=$(run_lead 'LEAVE_LEAD_TIME_MIN = abc')
  [ "$OUT" = "30 default" ] || fail "a non-numeric config lead must fall back to 30 (got: $OUT)"
  ERR=$(run_lead_stderr 'LEAVE_LEAD_TIME_MIN = abc')
  case "$ERR" in
    *"rejected LEAVE_LEAD_TIME_MIN='abc'"*) : ;;
    *) fail "a non-numeric config lead must warn on stderr (got: $ERR)" ;;
  esac
  ERR=$(run_lead_stderr 'LEAVE_LEAD_TIME_MIN = 900')
  case "$ERR" in
    *"rejected LEAVE_LEAD_TIME_MIN='900'"*) : ;;
    *) fail "an out-of-range config lead must warn on stderr (got: $ERR)" ;;
  esac

  # A knob SET to empty is a misconfiguration to report, not an absent knob to skip —
  # on both the env and the config path.
  OUT=$(run_lead '' 'CLAUDE_LEAVE_LEAD_TIME_MIN=')
  [ "$OUT" = "30 env_rejected" ] || fail "an empty env lead must fall back to 30 (got: $OUT)"
  ERR=$(run_lead_stderr '' 'CLAUDE_LEAVE_LEAD_TIME_MIN=')
  case "$ERR" in
    *"rejected CLAUDE_LEAVE_LEAD_TIME_MIN=''"*) : ;;
    *) fail "an empty env lead must warn on stderr, not be skipped as unset (got: $ERR)" ;;
  esac
  OUT=$(run_lead 'LEAVE_LEAD_TIME_MIN =')
  [ "$OUT" = "30 default" ] || fail "an empty config lead must fall back to 30 (got: $OUT)"
  ERR=$(run_lead_stderr 'LEAVE_LEAD_TIME_MIN =')
  case "$ERR" in
    *"rejected LEAVE_LEAD_TIME_MIN=''"*) : ;;
    *) fail "an empty config lead must warn on stderr (got: $ERR)" ;;
  esac
  # An unset knob is silent — the normal case, and the control that proves the two
  # empty cases above are not just matching everything.
  ERR=$(run_lead_stderr '')
  [ -z "$ERR" ] || fail "an unset lead knob must warn about nothing (got: $ERR)"

  # Boundaries are inclusive.
  OUT=$(run_lead '' 'CLAUDE_LEAVE_LEAD_TIME_MIN=5')
  [ "$OUT" = "5 env" ] || fail "5 minutes is in range (got: $OUT)"
  OUT=$(run_lead '' 'CLAUDE_LEAVE_LEAD_TIME_MIN=240')
  [ "$OUT" = "240 env" ] || fail "240 minutes is in range (got: $OUT)"

  # A failing READER is not "no value configured": rc 1/2 are ordinary (knob absent),
  # anything above is the getter breaking and must be reported before the fallback.
  # rc=1 is "section missing or body empty", so a faithful stub prints nothing with it.
  OUT=$(run_lead '' 'STUB_CONFIG_RC=1')
  [ "$OUT" = "30 default" ] || fail "rc=1 from the getter means no knob set (got: $OUT)"
  ERR=$(run_lead_stderr '' 'STUB_CONFIG_RC=1')
  [ -z "$ERR" ] || fail "an ordinary rc=1 from the getter must not warn (got: $ERR)"
  OUT=$(run_lead '' 'STUB_CONFIG_RC=2')
  [ "$OUT" = "30 default" ] || fail "rc=2 (no config file) means no knob set (got: $OUT)"
  OUT=$(run_lead 'LEAVE_LEAD_TIME_MIN = 45' 'STUB_CONFIG_RC=5')
  [ "$OUT" = "30 default" ] || fail "a failing getter must fall back to 30 (got: $OUT)"
  ERR=$(run_lead_stderr 'LEAVE_LEAD_TIME_MIN = 45' 'STUB_CONFIG_RC=5')
  case "$ERR" in
    *"DEGRADED: pm-config-get.sh failed (rc=5)"*) : ;;
    *) fail "a failing getter must report DEGRADED before falling back (got: $ERR)" ;;
  esac

  ok_group 'lead-time cascade: env > pm-config.md > 30, out-of-range rejected not clamped'
fi

# ---------------------------------------------------------------------------
# Part 1b — the per-launch deadline decline, executed
# ---------------------------------------------------------------------------
DECLINE_BLOCK="$(extract_skill_bash "$ROOT/$SUBAGENT_SKILL" subagent-step7-deadline-decline)" \
  || { fail 'could not extract the /subagent Step 7 deadline decline block'; DECLINE_BLOCK=""; }

# Stub session-state.sh: emits STUB_DEADLINE and exits STUB_STATE_RC.
STUB_STATE="$TMP/session-state.sh"
cat >"$STUB_STATE" <<'STUB'
#!/usr/bin/env bash
# `-` not `:-`: an empty STUB_DEADLINE is a deliberate test input (an empty read),
# and `:-` would silently rewrite it to `null` — turning the empty-read case into
# the absent case and passing the assertion vacuously.
printf '%s\n' "${STUB_DEADLINE-null}"
exit "${STUB_STATE_RC:-0}"
STUB
chmod +x "$STUB_STATE"

# Stub estimate-resolve.sh: emits STUB_EST verbatim.
STUB_EST_SH="$TMP/estimate-resolve.sh"
cat >"$STUB_EST_SH" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "${STUB_EST:-unestimated}"
exit "${STUB_EST_RC:-0}"
STUB
chmod +x "$STUB_EST_SH"

run_decline() {
  # $1 = deadline value, $2 = state rc, $3 = estimate string, $4 = estimate helper path,
  # $5 = optional estimate-resolver exit code, $6 = optional fixed `now` epoch
  (
    set -euo pipefail
    export STUB_DEADLINE="$1" STUB_STATE_RC="$2" STUB_EST="$3" STUB_EST_RC="${5:-0}"
    # Freeze the clock when asked, so a boundary case tests the boundary rather than
    # however many milliseconds elapsed between the fixture and the block.
    if [ -n "${6:-}" ]; then
      _NOW_FIXED="$6"
      date() {
        if [ "${1:-}" = "-u" ] && [ "${2:-}" = "+%s" ]; then printf '%s\n' "$_NOW_FIXED"
        else command date "$@"; fi
      }
    fi
    SESSION_STATE_SH="$STUB_STATE"
    ESTIMATE_RESOLVE_SH="$4"
    REPO_KEY="org/repo"
    ISSUE_NUM=61
    eval "$DECLINE_BLOCK"
    printf '%s|%s\n' "$LAUNCH_DECLINED" "$DECLINE_REASON"
  ) 2>/dev/null
}

if [ -n "$DECLINE_BLOCK" ]; then
  group_start
  FAR=$(( $(date -u +%s) + 6 * 3600 ))   # 6 h of runway
  NEAR=$(( $(date -u +%s) + 30 * 60 ))   # 30 min of runway
  PAST=$(( $(date -u +%s) - 600 ))

  OUT=$(run_decline "null" 0 "Est: 90–180 min · plan on 180" "$STUB_EST_SH")
  [ "$OUT" = "false|" ] || fail "no armed deadline must not decline (got: $OUT)"

  OUT=$(run_decline "null" 3 "Est: 90–180 min · plan on 180" "$STUB_EST_SH")
  [ "$OUT" = "false|" ] || fail "exit 3 (no state file) must not decline (got: $OUT)"

  OUT=$(run_decline "$FAR" 0 "Est: 90–180 min · plan on 180" "$STUB_EST_SH")
  [ "$OUT" = "false|" ] || fail "a bound that fits inside the deadline must launch (got: $OUT)"

  OUT=$(run_decline "$NEAR" 0 "Est: 90–180 min · plan on 180" "$STUB_EST_SH")
  [ "$OUT" = "true|plan on 180 min" ] || fail "a bound that overruns the deadline must decline (got: $OUT)"

  OUT=$(run_decline "$NEAR" 0 "Est: 15–20 min · plan on 20" "$STUB_EST_SH")
  [ "$OUT" = "false|" ] || fail "a shorter pipeline must still launch under the same deadline (got: $OUT)"

  OUT=$(run_decline "$PAST" 0 "Est: 15–20 min · plan on 20" "$STUB_EST_SH")
  [ "$OUT" = "true|plan on 20 min" ] || fail "a deadline already passed must decline everything (got: $OUT)"

  # The strict boundary, on a frozen clock: a bound landing exactly ON the deadline
  # leaves zero runway for the wind-down and must decline, while one second of slack
  # must still launch. Both sides are asserted — a one-sided boundary test passes
  # equally well against a gate that declines everything.
  FIXED_NOW=1787439600
  EXACT=$(( FIXED_NOW + 20 * 60 ))
  OUT=$(run_decline "$EXACT" 0 "Est: 15–20 min · plan on 20" "$STUB_EST_SH" 0 "$FIXED_NOW")
  [ "$OUT" = "true|plan on 20 min" ] \
    || fail "a bound exactly equal to the remaining time must decline (got: $OUT)"
  OUT=$(run_decline "$(( EXACT + 1 ))" 0 "Est: 15–20 min · plan on 20" "$STUB_EST_SH" 0 "$FIXED_NOW")
  [ "$OUT" = "false|" ] \
    || fail "one second of slack past the bound must still launch (got: $OUT)"

  # Fail-closed cases: unknown duration and unknown deadline both decline.
  OUT=$(run_decline "$FAR" 0 "unestimated" "$STUB_EST_SH")
  [ "$OUT" = "true|unestimated" ] || fail "an unestimated issue must decline near a deadline (got: $OUT)"

  OUT=$(run_decline "$FAR" 0 "Est: 15–20 min · plan on 20" "")
  [ "$OUT" = "true|unestimated" ] || fail "a missing estimate helper must decline, not pass (got: $OUT)"

  OUT=$(run_decline "$FAR" 6 "Est: 15–20 min · plan on 20" "$STUB_EST_SH")
  [ "$OUT" = "true|deadline unreadable (rc=6)" ] \
    || fail "an unreadable deadline read (lock timeout) must decline, not pass (got: $OUT)"

  # Exit 0 carrying a value that is neither the absent sentinel nor an epoch is
  # corruption. Only `null` (and an empty read) may bypass the gate.
  OUT=$(run_decline "invalid" 0 "Est: 15–20 min · plan on 20" "$STUB_EST_SH")
  [ "$OUT" = "true|deadline malformed" ] \
    || fail "a malformed exit-0 deadline value must decline, not pass (got: $OUT)"
  OUT=$(run_decline "-1" 0 "Est: 15–20 min · plan on 20" "$STUB_EST_SH")
  [ "$OUT" = "true|deadline malformed" ] \
    || fail "a negative epoch must decline, not pass (got: $OUT)"
  OUT=$(run_decline '(.repos | map(.window))' 0 "Est: 15–20 min · plan on 20" "$STUB_EST_SH")
  [ "$OUT" = "true|deadline malformed" ] \
    || fail "an unevaluated jq filter stored as the deadline must decline (got: $OUT)"

  # Range validation before arithmetic: an arbitrarily long digit string overflows
  # bash arithmetic, and an overflow under `set -e` aborts the launch path rather
  # than declining it.
  OUT=$(run_decline "999999999999999999999999" 0 "Est: 15–20 min · plan on 20" "$STUB_EST_SH")
  [ "$OUT" = "true|deadline malformed" ] \
    || fail "an out-of-range epoch must decline as malformed, not overflow (got: $OUT)"

  # Leading zeros: bash reads `0…` as OCTAL, so an accepted leading-zero value would
  # mean a different instant — and `09…` is not valid octal at all, so the arithmetic
  # would fail outright under `set -e` instead of declining.
  OUT=$(run_decline "0123456789" 0 "Est: 15–20 min · plan on 20" "$STUB_EST_SH")
  [ "$OUT" = "true|deadline malformed" ] \
    || fail "a leading-zero epoch must decline rather than be read as octal (got: $OUT)"
  OUT=$(run_decline "09999999999" 0 "Est: 15–20 min · plan on 20" "$STUB_EST_SH")
  [ "$OUT" = "true|deadline malformed" ] \
    || fail "an invalid-octal epoch must decline, not abort the launch path (got: $OUT)"
  # Absent has exactly one exit-0 shape: the literal `null`. An empty read means the
  # field holds an empty string — no more a valid epoch than `-1`.
  OUT=$(run_decline "" 0 "Est: 15–20 min · plan on 20" "$STUB_EST_SH")
  [ "$OUT" = "true|deadline malformed" ] \
    || fail "an empty exit-0 read is corrupt, not absent, and must decline (got: $OUT)"

  # An estimate string carrying no `plan on N` yields no bound at all, which is the
  # unestimated path — distinct from a bound that resolves and overruns.
  OUT=$(run_decline "$FAR" 0 "Est: 15–20 min" "$STUB_EST_SH")
  [ "$OUT" = "true|unestimated" ] \
    || fail "a malformed estimate with no 'plan on N' must decline as unestimated (got: $OUT)"

  # A tier fallback (rc=1) is a real estimate and must be honoured, not declined.
  OUT=$(run_decline "$FAR" 0 "Est: 15–30 min · plan on 30" "$STUB_EST_SH" 1)
  [ "$OUT" = "false|" ] \
    || fail "a tier-fallback estimate (rc=1) is a real bound and must launch (got: $OUT)"

  # rc 3/4 are the estimate TOOL failing — a different problem from an unestimated
  # issue, and reported as such rather than laundered into the unestimated branch.
  OUT=$(run_decline "$FAR" 0 "Est: 15–20 min · plan on 20" "$STUB_EST_SH" 4)
  [ "$OUT" = "true|estimate lookup failed (rc=4)" ] \
    || fail "an estimate-resolver failure must decline with its own reason (got: $OUT)"

  ok_group 'deadline decline: fits launches, overruns declines, unknown duration/deadline fail closed'
fi

# ---------------------------------------------------------------------------
# Part 2 — cross-file contracts with no executable form
# ---------------------------------------------------------------------------
group_start

# One deadline source. A second copy is how the two come to disagree.
require_text "$LEAVE_SKILL" '\"deadline_epoch\":null' \
  'leave-by must write .leave.deadline_epoch as null — the deadline lives only in .window'
require_text "$LEAVE_SKILL" '.window.deadline_epoch' \
  'leave-by must name .window.deadline_epoch as the single deadline source'
require_text .claude/reference/session-state-schema.json \
  '`deadline_epoch` HERE IS ALWAYS null' \
  'the schema must state that .leave never carries the deadline'

# Monitor, never CronCreate or a wake-up chain (scheduling-reliability.md).
require_text "$LEAVE_SKILL" 'persistent: true' \
  'leave-by must arm its wind-down with a persistent Monitor'
require_text "$LEAVE_SKILL" 'Never `CronCreate`' \
  'leave-by must forbid CronCreate for the wind-down wake'
require_text "$LEAVE_SKILL" 'never a chain' \
  'leave-by must forbid a chain of one-shot wake-ups'
reject_text "$LEAVE_SKILL" 'CronCreate(' \
  'leave-by must never call CronCreate'
require_text .claude/rules/scheduling-reliability.md '## Declared Leave Times' \
  'the scheduling rule must route declared leave times to /leave-by'

# Runtime identity pair + stale-generation rejection.
require_text "$LEAVE_SKILL" 'winddown_generation' \
  'leave-by must record a generation alongside the wind-down task ID'
require_text "$LEAVE_SKILL" '--cas ".repos[\"$REPO_KEY\"].leave.winddown_task_id=\"$WINDDOWN_TASK_ID\""' \
  'the task ID must be published by compare-and-set so a late write cannot resurrect a torn-down wake'
require_text "$LEAVE_SKILL" 'exit silently, writing nothing' \
  'a stale --checkin generation must be a silent no-op'

# Disarm before delegating, then delegate to the real /pause.
require_text "$LEAVE_SKILL" '8.5 — Disarm before delegating' \
  'leave-by must null the identity pair before invoking /pause'
# A spent deadline left armed declines every future launch in the repo.
require_text "$LEAVE_SKILL" '--set ".repos[\"$REPO_KEY\"].window=null"' \
  'a completed wind-down must clear the armed window, not just leave.active'
require_text .claude/skills/pause-resume/SKILL.md '.repos["$REPO_KEY"].window=null' \
  '/pause-resume must clear the armed window when it retires a leave time'
# The window is SHARED with /pm --window: clearing it on a null task ID alone would
# wipe a PM planning deadline no leave time ever touched.
require_text .claude/skills/pause-resume/SKILL.md 'do nothing here unless it is `true`' \
  '/pause-resume must gate the window clear on leave.active, not on a null task ID'
require_text "$LEAVE_SKILL" '/pause --window ${REMAINING_MIN}m' \
  'the wind-down must delegate to /pause with the remaining minutes as its window'
require_text "$LEAVE_SKILL" 'hard flow-wide ceiling, not a target' \
  'the declared time must be documented as a hard ceiling (issue #1482), never best-effort'

# Teardown on both sides of a manual pause.
require_text .claude/skills/pause/SKILL.md 'leave.winddown_task_id' \
  '/pause Step 2 must stop the leave-time wind-down Monitor by its recorded ID'
require_text .claude/skills/pause/SKILL.md 'owner: "leave_winddown"' \
  '/pause must record the wind-down stop under its own owner in monitors_stopped'
require_text .claude/skills/pause-resume/SKILL.md 'leave.winddown_task_id=null' \
  '/pause-resume must clear the wind-down identity pair'
require_text .claude/skills/pause-resume/SKILL.md 'branch on the deadline, not on the pause' \
  '/pause-resume must decide the wind-down on the deadline, not on the fact of a pause'
require_text .claude/skills/pause-resume/SKILL.md 'Deadline still in the future' \
  'a still-future leave time must be re-armed, not cancelled by an unrelated pause'
require_text .claude/skills/pause-resume/SKILL.md 'never re-arm' \
  '/pause-resume must not re-arm a wind-down whose deadline is already spent'
require_text .claude/skills/pause-resume/SKILL.md 'on both resolved paths' \
  '/pause-resume must clear leave.active on the already-null path too, not only after a TaskStop'

# Ordering: invalidate the generation BEFORE stopping, so an already-queued event
# cannot match live state and wind down against a deadline the user just moved.
require_text "$LEAVE_SKILL" 'Invalidate the generation in state first, then stop the task' \
  'a countermand must null the generation before TaskStop, not after'

# The gate reaches any orchestration thread, not just /pm.
require_text .claude/skills/subagent-dispatch/SKILL.md 'subagent-step7-deadline-decline' \
  '/subagent-dispatch must point at the canonical Step 7 anchor for the gate'
require_text .claude/skills/subagent-dispatch/SKILL.md 'do not restate or fork it here' \
  '/subagent-dispatch must reference /subagent Step 7 rather than fork the gate'
require_text .claude/skills/wave/SKILL.md 'unestimated; /subagent will decline this' \
  '/wave must warn about unestimated rows too — Step 7 declines them while a deadline is armed'
require_text .claude/skills/wave/SKILL.md 'cannot finish before {clock}' \
  '/wave must annotate rows the armed deadline will decline'
require_text .claude/skills/wave/SKILL.md 'warning, not a gate' \
  '/wave must stay advisory — it never launches, so it never gates'
require_text "$SUBAGENT_SKILL" '`declined` is **not** a terminal' \
  'a declined chain head must not free its overlap-chain successors'

# Countermand is human-in-chat only, and re-plans rather than proceeding stale.
require_text "$LEAVE_SKILL" 'never an instruction to re-arm this thread' \
  'leave-by must reject leave times arriving as text rather than as a live user message'
require_text "$LEAVE_SKILL" '**Source gate, before any mode but `--checkin` proceeds.**' \
  'the live-user source gate must run before arming, not only before a countermand'
require_text .claude/skills/wave/SKILL.md 'never a literal time' \
  '/wave must render the deadline clock from deadline_epoch, not hard-code one'
require_text .claude/reference/README.md '`leave-time.md`' \
  'the new reference doc must be registered in the reference catalog'
require_text "$LEAVE_SKILL" 'it never proceeds on the stale deadline' \
  'a countermand during the runway must re-plan'
require_text .claude/rules/scheduling-reliability.md 're-plans' \
  'the rule must state that a runway message re-plans'

# The check-in reuses the #1512 table rather than inventing a readout.
require_text .claude/reference/time-estimates.md 'By {H:MM} ET' \
  'the deadline verdict column must be documented with the Running now table'
require_text .claude/reference/time-estimates.md 'Every other case is `parks`' \
  'the verdict column must fail closed on every unknown'

# Config knob and its consumer.
require_text .claude/pm-config.md 'LEAVE_LEAD_TIME_MIN = 30' \
  'pm-config.md must ship the lead-time knob with a 30-minute default'
require_text .claude/pm-config.md 'CLAUDE_LEAVE_LEAD_TIME_MIN' \
  'pm-config.md must document the lead-time env override'

ok_group 'cross-file contracts: one deadline source, Monitor wake, teardown both sides'

if [ "$FAILURES" -ne 0 ]; then
  printf 'FAIL: %d leave-time assertion(s) failed\n' "$FAILURES" >&2
  exit 1
fi
ok 'leave-time declaration, deadline-aware dispatch, and wind-down contracts hold'
