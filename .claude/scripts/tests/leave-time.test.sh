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
# An ORDERING contract needs the positions, not the prose describing them: a sentence
# saying "X before Y" survives X and Y being swapped underneath it. `require_order`
# asserts that `$first` actually precedes `$second`, scoped to one `## ` section so a
# same-shaped line elsewhere in the file cannot satisfy it.
require_order() {
  local file=$1 section=$2 first=$3 second=$4 message=$5
  local slice="$TMP/order-slice.txt" a b
  awk -v s="$section" 'index($0,s)==1 && !seen {seen=1; print; next}
                       seen && /^## / {exit} seen {print}' "$ROOT/$file" >"$slice"
  if [ ! -s "$slice" ]; then
    fail "$message (section '$section' not found in $file)"; return
  fi
  # `|| true` on each pipeline, deliberately: a marker that has been RENAMED AWAY is the
  # loudest form of this failure, and under `set -e` an empty grep would abort the whole
  # suite before the ABSENT branch below could name which marker vanished — an exit code
  # with no diagnostic. The emptiness is handled explicitly instead.
  local ah bh na nb
  ah=$( { grep -nF -- "$first" "$slice" || true; } )
  bh=$( { grep -nF -- "$second" "$slice" || true; } )
  na=$(printf '%s' "$ah" | grep -c . || true)
  nb=$(printf '%s' "$bh" | grep -c . || true)
  # AMBIGUITY IS A FAILURE, NOT A TIE-BREAK. Taking the first hit silently compares
  # whichever occurrence happens to come first — so a prose sentence or a bash comment
  # mentioning the marker can satisfy the ordering while the live statements underneath
  # stay reversed. That is not hypothetical: an earlier draft of this suite matched a
  # `TaskStop the recorded ID` line belonging to a different teardown entry and reported
  # an inverted order for code that was correct. A duplicated marker now says so.
  if [ "$na" -gt 1 ] || [ "$nb" -gt 1 ]; then
    fail "$message (ambiguous marker in '$section': first matched $na line(s), second $nb — pick markers unique to the statements under test)"
    return
  fi
  a=$(printf '%s' "$ah" | head -1 | cut -d: -f1)
  b=$(printf '%s' "$bh" | head -1 | cut -d: -f1)
  if [ -z "$a" ] || [ -z "$b" ]; then
    fail "$message (missing marker in '$section': first=${a:-ABSENT} second=${b:-ABSENT})"
  elif [ "$a" -ge "$b" ]; then
    fail "$message (order inverted: first at line $a, second at line $b)"
  fi
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

# Stub pm-config-get.sh: prints whatever Budget body the case under test wants, and
# records every argv it was handed. A stub that answers ANY arguments proves only that
# the cascade called something — a dropped or renamed `--section Budget` would still be
# served the fixture and read as a configured value, so the interface is asserted below
# rather than assumed.
STUB_CONFIG="$TMP/pm-config-get.sh"
STUB_CONFIG_ARGS="$TMP/pm-config-args.txt"
cat >"$STUB_CONFIG" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${STUB_CONFIG_ARGS_FILE:-/dev/null}"
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
    # Start from a known-unset slate. Every case that passes no assignment for a
    # knob is asserting the knob is ABSENT; inheriting an ambient value there
    # does not just fail the run, it silently converts those cases into coverage
    # of a different branch. Unset before applying the caller's assignments.
    unset CLAUDE_LEAVE_LEAD_TIME_MIN STUB_CONFIG_RC
    export STUB_BUDGET_FILE="$TMP/budget.txt" STUB_CONFIG_ARGS_FILE="$STUB_CONFIG_ARGS"
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
    unset CLAUDE_LEAVE_LEAD_TIME_MIN STUB_CONFIG_RC   # same clean slate as run_lead
    export STUB_BUDGET_FILE="$TMP/budget.txt" STUB_CONFIG_ARGS_FILE="$STUB_CONFIG_ARGS"
    PM_CONFIG_GET="$STUB_CONFIG"
    # shellcheck disable=SC2163
    while [ "$#" -gt 0 ]; do export "$1"; shift; done
    # Discard the block's stdout at the source and let the subshell's stderr become the
    # captured stream. The equivalent `) 2>&1 >/dev/null` reads as the stdout+stderr
    # idiom written in the wrong order (ShellCheck SC2069) even though it is correct
    # here — expressing it this way needs no suppression comment to stay legible.
    eval "$LEAD_BLOCK" >/dev/null
  ) 2>&1
}

if [ -n "$LEAD_BLOCK" ]; then
  group_start
  OUT=$(run_lead '')
  [ "$OUT" = "30 default" ] || fail "no config and no env must yield the 30-min default (got: $OUT)"

  OUT=$(run_lead 'LEAVE_LEAD_TIME_MIN = 45')
  [ "$OUT" = "45 config" ] || fail "pm-config.md value must win over the code default (got: $OUT)"

  # Negative control for the harness itself: with the knob set in the AMBIENT
  # environment, every case that passes no assignment must still see it unset.
  # Before run_lead unset it, this ran green only on a machine that happened not
  # to export it — the suite reported coverage of the default/config branches
  # while exercising the env branch instead.
  export CLAUDE_LEAVE_LEAD_TIME_MIN=7
  OUT=$(run_lead '')
  [ "$OUT" = "30 default" ] || fail "ambient env must not leak into a no-assignment run (got: $OUT)"
  OUT=$(run_lead 'LEAVE_LEAD_TIME_MIN = 45')
  [ "$OUT" = "45 config" ] || fail "ambient env must not outrank pm-config.md in a no-assignment run (got: $OUT)"
  ERR=$(run_lead_stderr '')
  [ -z "$ERR" ] || fail "ambient env must not reach the stderr helper either (got: $ERR)"
  unset CLAUDE_LEAVE_LEAD_TIME_MIN

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

  # The getter's INTERFACE, not just its output. Every case above asserts what the
  # cascade did with the body it got back; none of them would notice the cascade asking
  # for the wrong thing. The non-empty check is the negative control: an unset recorder
  # path would send every argv to /dev/null and let the comparison below pass vacuously.
  if [ ! -s "$STUB_CONFIG_ARGS" ]; then
    fail 'the config path never invoked pm-config-get.sh — the cascade cannot be reading pm-config.md'
  else
    CFG_BAD=$(grep -vcxF -- '--section Budget' "$STUB_CONFIG_ARGS" || true)
    [ "$CFG_BAD" = "0" ] || fail \
      "pm-config-get.sh must be called as '--section Budget' ($CFG_BAD call(s) differed: $(sort -u "$STUB_CONFIG_ARGS" | paste -sd'|' -))"
  fi

  ok_group 'lead-time cascade: env > pm-config.md > 30, out-of-range rejected not clamped'
fi

# ---------------------------------------------------------------------------
# Part 1b — the per-launch deadline decline, executed
# ---------------------------------------------------------------------------
DECLINE_BLOCK="$(extract_skill_bash "$ROOT/$SUBAGENT_SKILL" subagent-step7-deadline-decline)" \
  || { fail 'could not extract the /subagent Step 7 deadline decline block'; DECLINE_BLOCK=""; }

# Stub session-state.sh: emits STUB_DEADLINE, exits STUB_STATE_RC, and records its argv.
# Answering any argv would serve the fixture deadline to a block reading the WRONG state
# path — a renamed field, an uninterpolated repo key, or a `--set` where a `--get` was
# meant — so the query itself is asserted after the cases below.
STUB_STATE="$TMP/session-state.sh"
STUB_STATE_ARGS="$TMP/session-state-args.txt"
cat >"$STUB_STATE" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${STUB_STATE_ARGS_FILE:-/dev/null}"
# `-` not `:-`: an empty STUB_DEADLINE is a deliberate test input (an empty read),
# and `:-` would silently rewrite it to `null` — turning the empty-read case into
# the absent case and passing the assertion vacuously.
printf '%s\n' "${STUB_DEADLINE-null}"
exit "${STUB_STATE_RC:-0}"
STUB
chmod +x "$STUB_STATE"

# Stub estimate-resolve.sh: emits STUB_EST verbatim, and records its argv for the same
# reason — the gate must ask about the issue it is actually launching.
STUB_EST_SH="$TMP/estimate-resolve.sh"
STUB_EST_ARGS="$TMP/estimate-resolve-args.txt"
cat >"$STUB_EST_SH" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${STUB_EST_ARGS_FILE:-/dev/null}"
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
    export STUB_STATE_ARGS_FILE="$STUB_STATE_ARGS" STUB_EST_ARGS_FILE="$STUB_EST_ARGS"
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

  # The QUERIES, not just the answers. Every case above feeds the block a deadline and
  # checks what it decided; none would notice the block reading a different state path
  # or asking about a different issue. The non-empty checks are the negative control —
  # an unset recorder path routes every argv to /dev/null and passes vacuously.
  if [ ! -s "$STUB_STATE_ARGS" ]; then
    fail 'the decline gate never invoked session-state.sh — it cannot be reading the armed deadline'
  else
    ST_BAD=$(grep -vcxF -- '--get .repos["org/repo"].window.deadline_epoch' "$STUB_STATE_ARGS" || true)
    [ "$ST_BAD" = "0" ] || fail \
      "the gate must read .repos[REPO_KEY].window.deadline_epoch ($ST_BAD call(s) differed: $(sort -u "$STUB_STATE_ARGS" | paste -sd'|' -))"
  fi
  if [ ! -s "$STUB_EST_ARGS" ]; then
    fail 'the decline gate never invoked estimate-resolve.sh — it cannot be bounding the work'
  else
    EST_BAD=$(grep -vcxF -- '61' "$STUB_EST_ARGS" || true)
    [ "$EST_BAD" = "0" ] || fail \
      "the gate must resolve the estimate for \$ISSUE_NUM ($EST_BAD call(s) differed: $(sort -u "$STUB_EST_ARGS" | paste -sd'|' -))"
  fi

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

# Disarm before delegating, then delegate to the real /pause. Asserted positionally rather than
# by sub-step heading: the contract is that the pair is nulled BEFORE the /pause call, and a
# heading string goes on matching after the two are reordered underneath it.
require_order "$LEAVE_SKILL" '## Step 8:' \
  '--expect "$WINDDOWN_GENERATION"' \
  '/pause --window ${REMAINING_MIN}m' \
  'leave-by must null the identity pair before invoking /pause'
# A spent deadline left armed declines every future launch in the repo. The clear is now
# CAS-pinned at every site (retirement, cancel, arm-failure rollback) because `.window` is
# shared with `/pm --window` — the intent is unchanged, the write is just no longer blind.
require_text "$LEAVE_SKILL" '--cas ".repos[\"$REPO_KEY\"].window=null"' \
  'a completed wind-down must clear the armed window, not just leave.active'
require_text .claude/skills/pause-resume/SKILL.md '.repos["$REPO_KEY"].window=null' \
  '/pause-resume must clear the armed window when it retires a leave time'
# The window is SHARED with /pm --window: clearing it on a null task ID alone would
# wipe a PM planning deadline no leave time ever touched.
require_text .claude/skills/pause-resume/SKILL.md 'skip this entire block' \
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

# The identity must be committed before the Monitor can emit anything against it: the
# wake sleeps a 1-second minimum and a state write can outlast that under lock
# contention, so a generation published after arming can still be null when Step 8.1
# validates — rejecting the very wake that was just created, with no second chance.
require_order "$LEAVE_SKILL" '## Step 6:' \
  'leave.winddown_generation=\"$WINDDOWN_GENERATION\"' \
  'while sleep "$WINDDOWN_SLEEP"' \
  'the generation must be published BEFORE the wind-down Monitor is armed'
# Both Step 6 anchors must still EXTRACT. Prose inserted between an anchor and its
# fence makes extract_skill_bash exit 5, and an anchor nobody extracts today is exactly
# the one a later edit breaks unnoticed.
for anchor in leave-by-publish-generation leave-by-arm-monitor leave-by-arm-state; do
  extract_skill_bash "$ROOT/$LEAVE_SKILL" "$anchor" >/dev/null \
    || fail "anchor '$anchor' no longer extracts a bash block (extract_skill_bash rc=$?)"
done

# A LOST slot is not a failed publish. Both shapes producing PUBLISH_RC 7 — the CAS losing
# to an ID already there, and the holder re-read returning a different generation — mean a
# countermand or re-declaration already owns `.leave`. Rolling back there nulls the
# SUCCESSOR's generation and clears its .window: a live wind-down dies silently and
# dispatch reopens past the deadline the user just set.
require_text "$LEAVE_SKILL" '`PUBLISH_RC == 7` — the slot is no longer yours' \
  'Step 6 must branch a lost slot away from the ordinary publish-failure rollback'
require_text "$LEAVE_SKILL" '--expect "$WINDDOWN_TASK_ID"' \
  'a lost slot must release winddown_task_id under CAS, so a dead ID cannot squat the successor'
reject_text "$LEAVE_SKILL" 'is handled below like any other publish failure' \
  'the superseded "exit 7 is just another publish failure" wording must not return'

# A still-future checkin_epoch is jitter, not proof of replacement — Step 8.1's
# generation check is what detects a re-declaration. Exiting on jitter loses the
# one-shot wind-down entirely.
require_text "$LEAVE_SKILL" 'not by itself a replacement' \
  'an early Monitor wake must not be read as a replaced declaration'
require_text "$LEAVE_SKILL" 'exit without winding down' \
  'an unreadable or non-numeric deadline must stop the check-in before the runway math'

# /pause reports INCOMPLETE SHUTDOWN when a stop, the persistence write, or a gate
# could not be confirmed; retiring the declaration there reopens dispatch on a board
# that never parked and destroys the record recovery needs.
require_text "$LEAVE_SKILL" 'Retire only on a complete shutdown' \
  'an incomplete /pause must not retire the leave declaration'

# Same ordering property as Step 9, at /pause's own teardown site.
require_order .claude/skills/pause/SKILL.md '## Step 2' \
  'leave.winddown_generation=null' \
  'only then `TaskStop` the leave-time wind-down ID' \
  "/pause Step 2 must null the wind-down generation before TaskStop, not after"
# And the third copy of that rule, at /pause-resume's disarm site — where it was wrong
# while both siblings above were right. Stopping first leaves a queued `--checkin` that
# still passes Step 8.1 and starts a `/pause` inside a restore that is still running.
require_order .claude/skills/pause-resume/SKILL.md '## Step 5' \
  'leave.winddown_generation=null' \
  'Only then `TaskStop` a non-null ID' \
  "/pause-resume Step 5 must null the wind-down generation before TaskStop, not after"

# The gate that admits the whole block must precede every branch it governs, and the
# deadline must be validated before anything is stopped.
require_order .claude/skills/pause-resume/SKILL.md '## Step 5' \
  'Gate first: `leave.active` must be `true`' \
  'Deadline still in the future' \
  '/pause-resume must gate on leave.active BEFORE the deadline branches, not after'
require_order .claude/skills/pause-resume/SKILL.md '## Step 5' \
  'still before stopping anything' \
  'TaskStop` a' \
  '/pause-resume must validate the deadline before stopping the wind-down Monitor'
require_text .claude/skills/pause-resume/SKILL.md 'and it is delivered the same way every other check-in is' \
  'a resume past a fired check-in must deliver the overdue check-in, not silently skip it'

# A re-declaration must pass through Step 9 BEFORE Step 5 rewrites .leave: Step 5 replaces
# the whole object with a null identity pair, and that ID exists nowhere else — entering
# declare mode first orphans a live Monitor that nothing can name or stop.
require_text "$LEAVE_SKILL" '**Step 9 first when one is already armed**' \
  'the mode table must route a re-declaration through Step 9 before Steps 1-7'
require_text "$LEAVE_SKILL" 'discards the only record of that task ID' \
  'the skill must say why declaring over an armed leave time orphans its Monitor'

# Routing through Step 9 is only half the gate — WHICH field decides "already armed" is the
# other half. Step 8.5 nulls winddown_task_id before delegating to /pause, so a task-ID-only
# sentinel reads "nothing armed" for the whole runway: precisely the window the countermand
# clause covers. The pair is the contract; pinning the routing alone let that through.
require_text "$LEAVE_SKILL" 'a non-null task ID **or**' \
  'the declare-mode gate must accept EITHER sentinel, not the task ID alone'
require_text "$LEAVE_SKILL" '`active` stays true across that whole window' \
  'the skill must say why active is the sentinel that covers the runway'

# The retirement is the other side of the same defect: a re-declaration during the runway
# arms a successor, and an unguarded 8.6 then clears ITS window. Retire only what you own.
require_text "$LEAVE_SKILL" 'Capture `.leave.declared_at` before invoking' \
  'Step 8.6 must capture the declaration identity before /pause so retirement can verify it'
require_text "$LEAVE_SKILL" 'is a mismatch, not a match' \
  'two unreadable identity reads must not compare equal and retire an unidentifiable declaration'

# A failed TaskStop leaves a dead ID squatting the slot the re-arm must win with --expect null.
# Step 6 exit-7 then stops the Monitor this step just created; releasing the slot prevents it.
require_text .claude/skills/pause-resume/SKILL.md 'release the slot anyway' \
  'a failed stop must still release the ID slot, or the re-arm CAS loses to a dead ID'
require_text .claude/skills/pause-resume/SKILL.md 'holding `.window` open here re-creates the precise failure' \
  'a spent deadline must be retired on an unconfirmed stop, not left arming every decline'

# Releasing the slot and retaining the un-stopped ID are both required, and they cannot both
# live in leave.winddown_task_id — the release empties it. Name the surviving record, or a
# later branch reports an un-stopped Monitor as stopped.
require_text .claude/skills/pause-resume/SKILL.md 'Where the un-stopped ID lives after this' \
  'the skill must name where an un-stopped ID survives once the slot is released'

# A FAILED holder re-read proves nothing about ownership, so it must not take the exit-7
# lost-slot path — that path stops the new Monitor and stays silent, leaving the leave time
# looking armed with no wake behind it.
require_text "$LEAVE_SKILL" 'unreadable re-read is not a lost slot' \
  'an unreadable holder re-read must not be treated as a lost slot'

# Step 11 recovery carries no new time, so the live-user source gate must exempt it or the
# rule silently deletes every leave time across a restart or compaction.
require_text "$LEAVE_SKILL" 'recovery may **re-arm what is already persisted**' \
  'the source gate must exempt Step 11 recovery, and bound that exemption to re-arming'

# Every destructive leave-state write must prove it still owns what it is clearing. Three sites,
# one contract: arm-failure rollback, Step 8.6 retirement, and the /pause-resume retirement.
# A half-applied ownership rule is worse than none — the guarded sites imply the others are safe.
require_text "$LEAVE_SKILL" 'roll back only what is still yours' \
  'arm-failure rollback must be identity-guarded, not blind'
require_text "$LEAVE_SKILL" '`.window` is shared; `.leave` is not' \
  'the retirement must treat the shared window as a separate claim from the leave record'
require_text .claude/skills/pause-resume/SKILL.md 'exit 7 = another writer owns .window' \
  'the pause-resume retirement must CAS the window clear, not write it blind'
# The window CAS is only meaningful if it pins the value the verdict was reached on.
require_text .claude/skills/pause-resume/SKILL.md 'RESUMED_DEADLINE_EPOCH' \
  'the resumed deadline must be bound so the retirement CAS can pin its write to it'

# An ordering rule is only a safety property if the earlier write actually landed. Both
# invalidations that other steps depend on must read their exit code, and the Step 9 one is
# fail-closed: a queued --checkin stays valid until the token is really gone.
require_text "$LEAVE_SKILL" 'the disarm is the whole point of this sub-step' \
  'Step 8.5 must check the disarm exit code rather than assuming the write landed'
require_text "$LEAVE_SKILL" 'A failed invalidation is a STOP' \
  'Step 9 must not TaskStop or re-declare when the generation invalidation failed'

# --expect is matched at the --cas PATH. Both window clears CAS on `.window`, so the expected
# value must be the whole object; expecting deadline_epoch there can never compare equal, so the
# CAS loses every time and the spent deadline stays armed while LOOKING guarded — the same
# "declines every pipeline in this repo" failure, reintroduced by the guard meant to prevent it.
require_text "$LEAVE_SKILL" 'the expected value must be the **whole window object**' \
  'the retirement CAS must expect the whole window object, not a scalar under it'
require_text .claude/skills/pause-resume/SKILL.md 'the WHOLE window object' \
  'the pause-resume retirement CAS must expect the whole window object, not a scalar under it'
# And the captures must actually bind the object, not the scalar the prose warns against.
require_text "$LEAVE_SKILL" 'RETIRE_WINDOW=' \
  'leave-by must bind the whole window object for its retirement CAS'
require_text .claude/skills/pause-resume/SKILL.md 'RESUMED_WINDOW=' \
  'pause-resume must bind the whole window object for its retirement CAS'

# EVERY .window clear is CAS-pinned, not just the two retirements. Cancel and the arm-failure
# rollback write the same shared slot, and /pm --window also owns it.
require_text "$LEAVE_SKILL" 'CANCEL_WINDOW=' \
  'the cancel path must pin its window clear to the window it armed'
require_text "$LEAVE_SKILL" 'ARM_WINDOW=' \
  'the arm-failure rollback must pin its window clear to the window it armed'

# The 8.5 disarm is the FIRST write the check-in makes, so the identity 8.6 retires against must
# be captured BEFORE it. Capturing afterwards reads whatever a countermand left in the gap — the
# successor declared_at — and the 8.6 HOLDER_AT re-read then compares equal, so the completing
# wind-down retires the successor and CAS-clears the window the user just re-armed, with every
# guard passing. Prose cannot hold this contract; only the positions can.
require_order "$LEAVE_SKILL" '## Step 8:' \
  'RETIRE_DECLARED_AT=$("$SESSION_STATE_SH"' \
  '--expect "$WINDDOWN_GENERATION"' \
  'Step 8.5 must capture the retirement identity BEFORE its disarm, not after it in 8.6'
# And the disarm itself is CAS-pinned. A blind null lands on whatever occupies the slot, so a
# re-declaration that has already re-armed loses its winddown_task_id and its live Monitor
# becomes one nobody can name or stop.
reject_text "$LEAVE_SKILL" '--set ".repos[\"$REPO_KEY\"].leave.winddown_task_id=null"' \
  'the 8.5 disarm must CAS the identity pair, never blind-set it over a successor'
require_text "$LEAVE_SKILL" '--expect "$WINDDOWN_GENERATION"' \
  'the 8.5 disarm must prove ownership through the generation CAS before nulling the pair'
require_text "$LEAVE_SKILL" '`DISARM_RC` non-zero and not `7`' \
  'Step 8.5 must separate an I/O disarm failure from a CAS loss'
require_text "$LEAVE_SKILL" 'a successor owns `.leave`.** Do **not** wind down' \
  'a lost disarm CAS must stop the wind-down, not park the board against a replaced deadline'

# All THREE copies of the invalidate-then-stop ordering must read the exit code and fail closed.
# Fixing only /leave-by Step 9 leaves the two siblings stopping tasks on an open queue window.
require_text .claude/skills/pause/SKILL.md 'INVALIDATE_RC' \
  '/pause Step 2 must check the generation invalidation before stopping the task'
require_text .claude/skills/pause-resume/SKILL.md 'fail closed — the same contract as `/leave-by` Step 9' \
  '/pause-resume Step 5 must fail closed on a failed generation invalidation'

# Reading the deadline early is not enough — the disarm must not run when validation fails,
# or the inconsistent-record branch preserves leave.active with nothing left to recover.
require_order .claude/skills/pause-resume/SKILL.md '## Step 5' \
  'stops here — before the disarm, not after it' \
  'TaskStop` a' \
  '/pause-resume must skip the disarm entirely on an unreadable deadline, not merely read first'
require_text .claude/skills/pause-resume/SKILL.md 'stop nothing, and skip the rest of' \
  'an inconsistent deadline must leave the wind-down identity intact and nameable'

# Step 11's table must be TOTAL over the four epoch orderings. A missing row is not a
# no-op: `future`/`past` (the deadline moved in under the check-in, which /pm --window
# can do to shared .window) fell through to undefined behavior.
require_text "$LEAVE_SKILL" 'The deadline moved in under the check-in' \
  'Step 11 must define the future-checkin / past-deadline row, not fall through it'

# Step 11 retires the same SHARED slot every other retirement pins, so it takes the same guards.
# Recovery is not a licence to clear blind: /pm --window can arm a live planning deadline in the
# gap between the read and the clear, and wiping that is the failure the blind form produces. The
# CAS cannot strand the spent deadline it was meant to clear, because a loss means the spent value
# is already gone.
require_text "$LEAVE_SKILL" 'RECOVERY_WINDOW=' \
  'Step 11 must bind the whole window object for its retirement CAS'
require_order "$LEAVE_SKILL" '## Step 11:' \
  'RECOVERY_WINDOW=$("$SESSION_STATE_SH"' \
  '--expect "$RECOVERY_WINDOW"' \
  'Step 11 must capture the window it judged before CAS-clearing it'
require_text "$LEAVE_SKILL" 'A CAS loss here strands nothing' \
  'Step 11 must say why a guarded clear cannot leave a spent deadline armed forever'
reject_text "$LEAVE_SKILL" 'Clear `.leave.active` and the armed `.window`; say so in one line' \
  'the expired row must route through the guarded retirement, not clear the shared slot blind'
# The .leave half needs the identity re-read too: recovery re-entered after a compaction can have
# live user turns behind it, and a re-declaration landing there gets retired by a blind write.
require_order "$LEAVE_SKILL" '## Step 11:' \
  'RECOVERY_DECLARED_AT=$("$SESSION_STATE_SH"' \
  '"$HOLDER_AT" = "$RECOVERY_DECLARED_AT"' \
  'Step 11 must capture the declaration identity before re-reading it to authorize the clear'

# The monitor loop that actually launches successors must not carry its own count of the
# launch controls — a fixed count in a second place is exactly how the deadline got left
# out of it while phase-protocols.md named three.
reject_text "$SUBAGENT_SKILL" 'Re-check both launch gates' \
  'the monitor loop must not restate a two-gate launch check that omits the deadline'
require_text "$SUBAGENT_SKILL" 'Re-check **every** launch control before every successor' \
  'the monitor loop must defer to the canonical launch-gate list rather than counting gates'

# Successor launches are launches: the auto-loaded gate must name the deadline too.
require_text .claude/rules/phase-protocols.md 'subagent-step7-deadline-decline' \
  'the successor launch gate must run the armed-deadline check, not only refill + execution-pause'
require_text .claude/rules/phase-protocols.md 'frees no' \
  'a deadline-declined successor must not free its overlap-chain successors'
require_text .claude/skills/subagent-dispatch/SKILL.md 'still holds its overlap chain' \
  '/subagent-dispatch must state the chain exception, not just "every other agent"'

# The deadline verdict must read the same projected finish the row displays — in BOTH
# places it was stated. Fixing one copy and leaving the other is how the two come to
# disagree, and the bound-only form is the one that reads an overrun row as landing.
require_text .claude/reference/time-estimates.md 'effective projected finish' \
  'the By-deadline verdict must use the displayed projected finish, not the original bound'
require_text "$LEAVE_SKILL" 'effective projected finish' \
  'the check-in must use the displayed projected finish too, not a second bound-only formula'
reject_text "$LEAVE_SKILL" 'started_at_epoch + BOUND_MIN' \
  'the check-in must not restate the bound-only verdict formula it just replaced'

# The retired shape (active:false + window:null) is normal, not an inconsistent record —
# otherwise every session start after a leave time ends reports a false recovery failure.
require_text "$LEAVE_SKILL" 'normal retired shape' \
  'a completed or cancelled leave must not read as an inconsistent record forever'
require_order "$LEAVE_SKILL" '## Step 11:' \
  'Check `leave.active` before judging the pair' \
  'is an **inconsistent** record' \
  'Step 11 must test leave.active BEFORE calling a missing deadline inconsistent'

# An overdue check-in is delivered as an armed event, never by calling Step 8 inline with
# a nulled pair: 8.1 would validate against the generation just cleared and exit silently,
# and from /pause-resume it would also nest a /pause inside the running restore.
require_text .claude/skills/pause-resume/SKILL.md 'Never invoke Step 8 inline from here' \
  '/pause-resume must deliver an overdue check-in as an armed event, not a nested Step 8'
require_text "$LEAVE_SKILL" 'Do **not** call Step 8 with the pair still null' \
  'Step 11 must not run Step 8 against a nulled generation'

# .window is shared with /pm --window, which can move the deadline without minting a new
# generation — so 8.1 passes and the event would wind down against a deadline the leave
# time never targeted.
require_text "$LEAVE_SKILL" 'two records have desynced' \
  'the check-in must detect a deadline moved by /pm --window rather than winding down against it'

# Recovery has to be reachable from something that actually runs at session start.
require_text .claude/rules/scheduling-reliability.md 'Step 11' \
  'an always-loaded rule must route session-start recovery to /leave-by Step 11'

# Ordering: invalidate the generation BEFORE stopping, so an already-queued event
# cannot match live state and wind down against a deadline the user just moved.
require_text "$LEAVE_SKILL" 'Invalidate the generation in state first, then stop the task' \
  'a countermand must null the generation before TaskStop, not after'
# …and the snippet must actually be in that order. The sentence above is documentation;
# swapping the two lines it describes would leave it true-looking and the race live.
# Scoped to Step 9 because Step 8's teardown nulls the same field on its own path.
require_order "$LEAVE_SKILL" '## Step 9:' \
  '.leave.winddown_generation=null' \
  'only now TaskStop the recorded winddown_task_id' \
  "the countermand snippet must null winddown_generation BEFORE the TaskStop it describes"

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
