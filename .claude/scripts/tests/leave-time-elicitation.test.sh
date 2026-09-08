#!/usr/bin/env bash
# Regression coverage for issue #1679: the launch gate ASKS for the laptop-close
# time when none is armed, plans against the pause point, and turns an attended
# overrun into a menu whose answer is remembered.
# catalog: tests — Runs the real skill-embedded bash for `/subagent` Step 7's leave-time elicitation gate and overrun decision, and `/leave-by`'s "no deadline today" marker and launch-anyway `parks` override (issue #1679), plus the cross-file contracts those four blocks depend on
#
# Same two-halves shape as `leave-time.test.sh`, and for the same reason:
#   1. EXECUTES the four anchored blocks that make decisions. Every case below is
#      DISCRIMINATING — it distinguishes the intended behaviour from the plausible
#      wrong one (ask vs stay silent, remembered vs re-asked, parks vs lands).
#   2. Pins the cross-file contracts that have no executable form: one parser, one
#      deadline home, and the surfaces that must never elicit.

set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
# shellcheck source=lib/skill-bash.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/skill-bash.sh"

FAILURES=0
fail() { printf 'FAIL: %s\n' "$*" >&2; FAILURES=$((FAILURES + 1)); }
ok() { printf 'ok   — %s\n' "$*"; }

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

TMP=$(mktemp -d)
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

LEAVE_SKILL=".claude/skills/leave-by/SKILL.md"
SUBAGENT_SKILL=".claude/skills/subagent/SKILL.md"
PM_SKILL=".claude/skills/pm/SKILL.md"
SCHEMA=".claude/reference/session-state-schema.json"

NOW=$(date -u +%s)

# ---------------------------------------------------------------------------
# Part 1 — the elicitation gate, executed
# ---------------------------------------------------------------------------
ELICIT_BLOCK="$(extract_skill_bash "$ROOT/$SUBAGENT_SKILL" subagent-step7-leave-elicitation-gate)" \
  || { fail 'could not extract the /subagent Step 7 leave-time elicitation gate'; ELICIT_BLOCK=""; }

# Path-dispatching stub. A catch-all branch would serve the deadline fixture to the
# no-deadline-marker read, so a gate that never looked at `no_deadline_until` would
# still pass every "does not re-ask" case below.
STUB_ELICIT="$TMP/session-state-elicit.sh"
STUB_ELICIT_ARGS="$TMP/elicit-args.txt"
cat >"$STUB_ELICIT" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${STUB_ARGS_FILE:-/dev/null}"
case "$*" in
  *window.deadline_epoch)    printf '%s\n' "${STUB_DEADLINE-null}";  exit "${STUB_DEADLINE_RC:-0}" ;;
  *leave.no_deadline_until)  printf '%s\n' "${STUB_NO_DEADLINE-null}"; exit "${STUB_ND_RC:-0}" ;;
esac
printf 'session-state stub: unexpected argv: %s\n' "$*" >&2
exit 99
STUB
chmod +x "$STUB_ELICIT"

run_elicit() {
  # $1 = deadline, $2 = deadline rc, $3 = no_deadline_until, $4 = no_deadline rc,
  # $5 = ATTENDED ("true"/"false")
  (
    set -euo pipefail
    export STUB_DEADLINE="$1" STUB_DEADLINE_RC="$2" STUB_NO_DEADLINE="$3" STUB_ND_RC="$4"
    export STUB_ARGS_FILE="$STUB_ELICIT_ARGS"
    SESSION_STATE_SH="$STUB_ELICIT"
    REPO_KEY="org/repo"
    ATTENDED="$5"
    eval "$ELICIT_BLOCK"
    printf '%s|%s\n' "$ELICIT_LEAVE_TIME" "$ELICIT_SKIP_REASON"
  ) 2>/dev/null
}

if [ -n "$ELICIT_BLOCK" ]; then
  group_start
  ARMED=$(( NOW + 4 * 3600 ))
  SPENT=$(( NOW - 600 ))
  TODAY_END=$(( NOW + 3600 ))     # an unexpired "no deadline today" marker
  YESTERDAY_END=$(( NOW - 3600 )) # the same marker, one ET day later

  OUT=$(run_elicit "null" 0 "null" 0 true)
  [ "$OUT" = "true|" ] || fail "nothing armed in an attended session must ask (got: $OUT)"

  # rc 3 is "no state file has ever been written" — the very first launch on a repo,
  # which is exactly when the question is most useful.
  OUT=$(run_elicit "null" 3 "null" 3 true)
  [ "$OUT" = "true|" ] || fail "a repo with no state file yet must ask (got: $OUT)"

  OUT=$(run_elicit "$ARMED" 0 "null" 0 true)
  [ "$OUT" = "false|deadline already armed" ] \
    || fail "an armed unexpired deadline must NOT re-ask (got: $OUT)"

  # A deadline in the past is spent, not armed. Reading it as armed would silence the
  # question for the rest of a session that outlived the time it was planning around.
  OUT=$(run_elicit "$SPENT" 0 "null" 0 true)
  [ "$OUT" = "true|" ] || fail "an EXPIRED deadline must ask again (got: $OUT)"

  OUT=$(run_elicit "null" 0 "$TODAY_END" 0 true)
  [ "$OUT" = "false|no deadline today" ] \
    || fail "an unexpired no_deadline_until must suppress the question (got: $OUT)"

  # The marker is a TIME, not a flag, precisely so it self-clears on the next ET day.
  OUT=$(run_elicit "null" 0 "$YESTERDAY_END" 0 true)
  [ "$OUT" = "true|" ] \
    || fail "a stale no_deadline_until (a new ET day) must ask again (got: $OUT)"

  OUT=$(run_elicit "null" 0 "null" 0 false)
  [ "$OUT" = "false|unattended" ] \
    || fail "an unattended session must skip the question, not stall on it (got: $OUT)"

  # Unreadable is not absent, at either path: asking for a deadline the repo may
  # already have would overwrite a live plan with a guess.
  OUT=$(run_elicit "null" 6 "null" 0 true)
  [ "$OUT" = "false|deadline state unreadable (rc=6)" ] \
    || fail "an unreadable deadline read must skip the question (got: $OUT)"
  OUT=$(run_elicit "null" 0 "null" 6 true)
  [ "$OUT" = "false|no-deadline marker unreadable (rc=6)" ] \
    || fail "an unreadable no-deadline marker must skip the question (got: $OUT)"

  # A malformed deadline is not an armed one — the decline gate reports it separately,
  # and an attended thread is the right place to replace it with a real answer.
  OUT=$(run_elicit "not-an-epoch" 0 "null" 0 true)
  [ "$OUT" = "true|" ] || fail "a malformed deadline must not read as armed (got: $OUT)"

  # THE QUERIES, not just the answers.
  if [ ! -s "$STUB_ELICIT_ARGS" ]; then
    fail 'the elicitation gate never invoked session-state.sh'
  else
    EL_BAD=$(grep -vcxE -- '^--get \.repos\["org/repo"\]\.(window\.deadline_epoch|leave\.no_deadline_until)$' \
      "$STUB_ELICIT_ARGS" || true)
    [ "$EL_BAD" = "0" ] || fail \
      "the gate must read only the armed deadline and the no-deadline marker ($EL_BAD differed: $(sort -u "$STUB_ELICIT_ARGS" | paste -sd'|' -))"
    # Both affirmative checks: the allowed-path filter above is satisfied by a gate that
    # reads only ONE of the two, so each must be shown to actually happen.
    grep -qxF -- '--get .repos["org/repo"].window.deadline_epoch' "$STUB_ELICIT_ARGS" \
      || fail 'the gate never read .window.deadline_epoch — it cannot tell an armed deadline from none'
    grep -qxF -- '--get .repos["org/repo"].leave.no_deadline_until' "$STUB_ELICIT_ARGS" \
      || fail 'the gate never read .leave.no_deadline_until — "no deadline today" cannot suppress anything'
  fi

  ok_group 'elicitation gate: asks when nothing is armed, stays silent when something is, unreadable never asks'
fi

# ---------------------------------------------------------------------------
# Part 2 — the attended overrun decision, executed
# ---------------------------------------------------------------------------
OVERRUN_BLOCK="$(extract_skill_bash "$ROOT/$SUBAGENT_SKILL" subagent-step7-overrun-decision)" \
  || { fail 'could not extract the /subagent Step 7 overrun decision block'; OVERRUN_BLOCK=""; }

STUB_DEC="$TMP/session-state-decision.sh"
STUB_DEC_ARGS="$TMP/decision-args.txt"
cat >"$STUB_DEC" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${STUB_ARGS_FILE:-/dev/null}"
case "$*" in
  *launch_decisions*) printf '%s\n' "${STUB_DECISION-null}"; exit "${STUB_DECISION_RC:-0}" ;;
esac
printf 'session-state stub: unexpected argv: %s\n' "$*" >&2
exit 99
STUB
chmod +x "$STUB_DEC"

run_overrun() {
  # $1 = LAUNCH_DECLINED in, $2 = DECLINE_REASON in, $3 = ATTENDED,
  # $4 = deadline epoch, $5 = recorded decision JSON, $6 = decision read rc
  (
    set -euo pipefail
    export STUB_DECISION="$5" STUB_DECISION_RC="$6" STUB_ARGS_FILE="$STUB_DEC_ARGS"
    SESSION_STATE_SH="$STUB_DEC"
    REPO_KEY="org/repo"
    ISSUE_NUM=1679
    LAUNCH_DECLINED="$1"
    DECLINE_REASON="$2"
    ATTENDED="$3"
    DEADLINE_EPOCH="$4"
    eval "$OVERRUN_BLOCK"
    printf '%s|%s|%s\n' "$OVERRUN_ASK" "$OVERRUN_DECISION" "$LAUNCH_DECLINED"
  ) 2>/dev/null
}

if [ -n "$OVERRUN_BLOCK" ]; then
  group_start
  DL=$(( NOW + 3600 ))
  OTHER_DL=$(( NOW + 7200 ))
  REC_SKIP="{\"decision\":\"skip\",\"deadline_epoch\":${DL},\"at\":\"2026-09-08T17:00:00Z\"}"
  REC_GO="{\"decision\":\"launch_anyway\",\"deadline_epoch\":${DL},\"at\":\"2026-09-08T17:00:00Z\"}"
  REC_GO_STALE="{\"decision\":\"launch_anyway\",\"deadline_epoch\":${OTHER_DL},\"at\":\"2026-09-08T12:00:00Z\"}"

  OUT=$(run_overrun true "plan on 180 min" true "$DL" "null" 0)
  [ "$OUT" = "true||true" ] \
    || fail "a first attended overrun must ask, leaving the decline standing (got: $OUT)"

  OUT=$(run_overrun true "plan on 180 min" true "$DL" "$REC_SKIP" 0)
  [ "$OUT" = "false|skip|true" ] \
    || fail "a recorded 'skip' must apply silently and keep the issue queued (got: $OUT)"

  OUT=$(run_overrun true "plan on 180 min" true "$DL" "$REC_GO" 0)
  [ "$OUT" = "false|launch_anyway|false" ] \
    || fail "a recorded 'launch_anyway' must reopen the gate without re-asking (got: $OUT)"

  # The record is keyed to the deadline it was given against: an answer about a
  # 2-hour horizon is not an answer about the 1-hour one now armed.
  OUT=$(run_overrun true "plan on 180 min" true "$DL" "$REC_GO_STALE" 0)
  [ "$OUT" = "true||true" ] \
    || fail "a decision recorded against a DIFFERENT deadline must re-arm the ask (got: $OUT)"

  # Headless keeps today's silent decline for every reason.
  OUT=$(run_overrun true "plan on 180 min" false "$DL" "null" 0)
  [ "$OUT" = "false||true" ] \
    || fail "an unattended overrun must stay a silent decline (got: $OUT)"

  # ...but attendance gates the QUESTION, not the RECORD. Most monitor cycles that re-apply
  # this gate are unattended; ignoring a stored answer there is how "Launch anyway" is
  # honoured once and then forgotten, leaving the issue declined forever.
  OUT=$(run_overrun true "plan on 180 min" false "$DL" "$REC_GO" 0)
  [ "$OUT" = "false|launch_anyway|false" ] \
    || fail "a stored 'launch_anyway' must be honoured on an unattended cycle too (got: $OUT)"
  OUT=$(run_overrun true "plan on 180 min" false "$DL" "$REC_SKIP" 0)
  [ "$OUT" = "false|skip|true" ] \
    || fail "a stored 'skip' must still apply on an unattended cycle (got: $OUT)"

  # Only the overrun reason is a choice. The rest are broken or missing inputs.
  for R in "unestimated" "deadline malformed" "deadline unreadable (rc=6)" "estimate lookup failed (rc=4)"; do
    OUT=$(run_overrun true "$R" true "$DL" "null" 0)
    [ "$OUT" = "false||true" ] \
      || fail "'$R' is not a choice and must not open a menu (got: $OUT)"
  done

  # A launch that was never declined must not consult the record at all.
  OUT=$(run_overrun false "" true "$DL" "$REC_SKIP" 0)
  [ "$OUT" = "false||false" ] \
    || fail "an undeclined launch must not read or apply a decision (got: $OUT)"

  # Unreadable is not "never asked": re-asking on it is the per-cycle nag the record exists to end.
  # It also is not "skip" — a failed read must not be reported as a decision the user made,
  # and the value it takes must never be one the write allow-list would persist.
  OUT=$(run_overrun true "plan on 180 min" true "$DL" "null" 6)
  [ "$OUT" = "false|unreadable|true" ] \
    || fail "an unreadable decision record must fall back to the standing decline under its own value (got: $OUT)"

  # A corrupt record is not a decision — it must ask, never launch.
  OUT=$(run_overrun true "plan on 180 min" true "$DL" '"launch_anyway"' 0)
  [ "$OUT" = "true||true" ] \
    || fail "a record that is not an object must re-arm the ask, not reopen the gate (got: $OUT)"

  if [ ! -s "$STUB_DEC_ARGS" ]; then
    fail 'the overrun path never invoked session-state.sh — it cannot be reading the record'
  else
    DEC_BAD=$(grep -vcxF -- '--get-json .repos["org/repo"].window.launch_decisions["1679"]' \
      "$STUB_DEC_ARGS" || true)
    [ "$DEC_BAD" = "0" ] || fail \
      "the record must be read with --get-json at .window.launch_decisions[ISSUE] ($DEC_BAD differed: $(sort -u "$STUB_DEC_ARGS" | paste -sd'|' -))"
  fi

  ok_group 'overrun decision: asks once, remembers the answer, re-arms on a new deadline'
fi

# ---------------------------------------------------------------------------
# Part 2b — recording a FRESH answer, and acting on it in the same turn
# ---------------------------------------------------------------------------
# The block in Part 2 runs BEFORE the menu exists, so its reopen only ever sees a STORED
# decision. These two blocks are the other half: they must persist the new answer and
# reopen the gate in the same turn, or "Launch anyway" launches nothing until some later
# monitor cycle happens to read the record back.
RECORD_BLOCK="$(extract_skill_bash "$ROOT/$SUBAGENT_SKILL" subagent-step7-overrun-record)" \
  || { fail 'could not extract the /subagent Step 7 overrun record write'; RECORD_BLOCK=""; }
REOPEN_BLOCK="$(extract_skill_bash "$ROOT/$SUBAGENT_SKILL" subagent-step7-overrun-reopen)" \
  || { fail 'could not extract the /subagent Step 7 post-menu reopen'; REOPEN_BLOCK=""; }

STUB_WRITE="$TMP/session-state-write.sh"
STUB_WRITE_ARGS="$TMP/write-args.txt"
cat >"$STUB_WRITE" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${STUB_ARGS_FILE:-/dev/null}"
if [ -n "${STUB_FLAKE_ONCE_FILE:-}" ] && [ ! -f "$STUB_FLAKE_ONCE_FILE" ]; then
  : >"$STUB_FLAKE_ONCE_FILE"
  exit 6
fi
exit "${STUB_SET_RC:-0}"
STUB
chmod +x "$STUB_WRITE"

if [ -n "$RECORD_BLOCK" ] && [ -n "$REOPEN_BLOCK" ]; then
  group_start
  DL=$(( NOW + 3600 ))

  run_record_then_reopen() {
    # $1 = the answer just given, $2 = --set exit code, $3 = flake-once marker path
    (
      set -euo pipefail
      export STUB_ARGS_FILE="$STUB_WRITE_ARGS" STUB_SET_RC="$2"
      export STUB_FLAKE_ONCE_FILE="${3:-}"
      SESSION_STATE_SH="$STUB_WRITE"
      REPO_KEY="org/repo"
      ISSUE_NUM=1679
      DEADLINE_EPOCH="$DL"
      OVERRUN_DECISION="$1"
      # The state the gate left behind for a freshly-asked issue.
      LAUNCH_DECLINED=true
      DECLINE_REASON="plan on 180 min"
      eval "$RECORD_BLOCK"
      eval "$REOPEN_BLOCK"
      printf '%s|%s|%s\n' "$DECISION_WRITE_RC" "$LAUNCH_DECLINED" "$DECLINE_REASON"
    ) 2>/dev/null
  }

  : >"$STUB_WRITE_ARGS"
  OUT=$(run_record_then_reopen launch_anyway 0 "")
  [ "$OUT" = "0|false|" ] \
    || fail "a fresh 'launch_anyway' must reopen the gate in the same turn (got: $OUT)"

  OUT=$(run_record_then_reopen skip 0 "")
  [ "$OUT" = "0|true|plan on 180 min" ] \
    || fail "a fresh 'skip' must leave the decline standing (got: $OUT)"

  # A failed write must NOT abort the launch path — the answer still applies to this turn.
  OUT=$(run_record_then_reopen launch_anyway 5 "")
  [ "$OUT" = "5|false|" ] \
    || fail "a failed write must surface its status and still honour the answer (got: $OUT)"

  # "Change my leave time" is an answer about the DEADLINE, not about this issue: it must
  # persist nothing, or the record silences this issue's ask while meaning nothing to any
  # reader. Asserted against its own recorder so a stray write is visible.
  # Only `skip` and `launch_anyway` may be persisted. "Change my leave time" is an answer
  # about the DEADLINE, and `unreadable` is not an answer at all — persisting either would
  # silence this issue's ask under a record no reader recognises.
  run_no_write_case() {
    # $1 = the OVERRUN_DECISION value, $2 = a recorder path of its own
    (
      set -euo pipefail
      export STUB_ARGS_FILE="$2" STUB_SET_RC=0 STUB_FLAKE_ONCE_FILE=""
      SESSION_STATE_SH="$STUB_WRITE"
      REPO_KEY="org/repo"; ISSUE_NUM=1679; DEADLINE_EPOCH="$DL"
      OVERRUN_DECISION="$1"
      LAUNCH_DECLINED=true; DECLINE_REASON="plan on 180 min"
      eval "$RECORD_BLOCK"
      eval "$REOPEN_BLOCK"
      printf '%s|%s|%s\n' "$DECISION_WRITE_RC" "$LAUNCH_DECLINED" "$DECLINE_REASON"
    ) 2>/dev/null
  }

  for NOWRITE in change_leave_time unreadable; do
    NOWRITE_ARGS="$TMP/nowrite-$NOWRITE-args.txt"
    : >"$NOWRITE_ARGS"
    OUT=$(run_no_write_case "$NOWRITE" "$NOWRITE_ARGS")
    [ "$OUT" = "0|true|plan on 180 min" ] \
      || fail "'$NOWRITE' must record nothing and leave the decline standing (got: $OUT)"
    [ ! -s "$NOWRITE_ARGS" ] \
      || fail "'$NOWRITE' must write no launch_decisions record (wrote: $(cat "$NOWRITE_ARGS"))"
  done

  WRITE_FLAKE="$TMP/write-flake-once"
  rm -f "$WRITE_FLAKE"
  OUT=$(run_record_then_reopen launch_anyway 0 "$WRITE_FLAKE")
  [ "$OUT" = "0|false|" ] \
    || fail "a lock timeout on the record write must be retried once (got: $OUT)"
  rm -f "$WRITE_FLAKE"

  if [ ! -s "$STUB_WRITE_ARGS" ]; then
    fail 'the answer was never written to state'
  else
    WR="$(cat "$STUB_WRITE_ARGS")"
    case "$WR" in
      *'--set .repos["org/repo"].window.launch_decisions["1679"]='*) : ;;
      *) fail "the answer must be written one key at a time under launch_decisions (got: $WR)" ;;
    esac
    case "$WR" in
      *"\"deadline_epoch\":${DL}"*) : ;;
      *) fail 'the record must name the deadline it was given against' ;;
    esac
  fi

  ok_group 'fresh answer: recorded per key, retried on a lock timeout, applied in the same turn'
fi

# ---------------------------------------------------------------------------
# Part 3 — "No deadline today" writes an ET end-of-day marker
# ---------------------------------------------------------------------------
ND_BLOCK="$(extract_skill_bash "$ROOT/$LEAVE_SKILL" leave-by-no-deadline-until)" \
  || { fail 'could not extract the /leave-by no-deadline-until block'; ND_BLOCK=""; }

STUB_ND="$TMP/session-state-nd.sh"
STUB_ND_ARGS="$TMP/nd-args.txt"
cat >"$STUB_ND" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${STUB_ARGS_FILE:-/dev/null}"
if [ -n "${STUB_FLAKE_ONCE_FILE:-}" ] && [ ! -f "$STUB_FLAKE_ONCE_FILE" ]; then
  : >"$STUB_FLAKE_ONCE_FILE"
  exit 6
fi
exit "${STUB_SET_RC:-0}"
STUB
chmod +x "$STUB_ND"

# Independent check that an epoch really is an ET midnight — recomputing the block's
# own idiom here would only prove the test can copy/paste.
# GNU form first, then BSD: `-r` on GNU coreutils means "reference FILE", so leading with
# it makes the common CI interpreter take the fallback on every call.
et_clock() {
  TZ='America/New_York' date -d "@$1" +'%H:%M' 2>/dev/null \
    || TZ='America/New_York' date -r "$1" +'%H:%M' 2>/dev/null
}

if [ -n "$ND_BLOCK" ]; then
  group_start
  : >"$STUB_ND_ARGS"
  ND_OUT=$(
    set -euo pipefail
    export STUB_ARGS_FILE="$STUB_ND_ARGS" STUB_SET_RC=0
    SESSION_STATE_SH="$STUB_ND"
    REPO_KEY="org/repo"
    eval "$ND_BLOCK"
    printf '%s|%s\n' "$NO_DEADLINE_RC" "$NO_DEADLINE_UNTIL"
  )
  ND_RC="${ND_OUT%%|*}"
  ND_EPOCH="${ND_OUT##*|}"
  [ "$ND_RC" = "0" ] || fail "a successful marker write must report rc 0 (got: $ND_RC)"
  case "$ND_EPOCH" in
    [1-9]*) : ;;
    *) fail "the marker must be a positive epoch (got: '$ND_EPOCH')" ;;
  esac
  if [ -n "$ND_EPOCH" ] && [ "$ND_EPOCH" -gt 0 ] 2>/dev/null; then
    [ "$ND_EPOCH" -gt "$NOW" ] || fail 'the marker must be in the future, or it suppresses nothing'
    [ "$ND_EPOCH" -le $(( NOW + 86400 + 7200 )) ] \
      || fail 'the marker must be TOMORROW ET midnight, not a day-and-a-bit of blanket silence'
    CLOCK=$(et_clock "$ND_EPOCH")
    [ "$CLOCK" = "00:00" ] \
      || fail "the marker must land on an ET midnight boundary, not now+86400 (ET clock: '$CLOCK')"
  fi
  if [ ! -s "$STUB_ND_ARGS" ]; then
    fail 'the no-deadline path never wrote state'
  else
    WRITE="$(cat "$STUB_ND_ARGS")"
    case "$WRITE" in
      *'--set .repos["org/repo"].leave='*) : ;;
      *) fail "the marker must be written to .repos[KEY].leave (got: $WRITE)" ;;
    esac
    case "$WRITE" in
      *'"active":false'*) : ;;
      *) fail 'declining a deadline must write active:false — a true here reads as a live wind-down' ;;
    esac
    case "$WRITE" in
      *'.window'*) fail 'declining a deadline must arm NO window' ;;
      *) : ;;
    esac
    case "$WRITE" in
      *"\"no_deadline_until\":${ND_EPOCH}"*) : ;;
      *) fail "the written marker must be the computed epoch (got: $WRITE)" ;;
    esac
  fi

  # A failed write is reported, never silently treated as "don't ask again".
  ND_FAIL=$(
    set -euo pipefail
    export STUB_ARGS_FILE=/dev/null STUB_SET_RC=6
    SESSION_STATE_SH="$STUB_ND"
    REPO_KEY="org/repo"
    eval "$ND_BLOCK"
    printf '%s\n' "$NO_DEADLINE_RC"
  )
  [ "$ND_FAIL" = "6" ] \
    || fail "a failed marker write must surface its exit code, not report success (got: $ND_FAIL)"

  # A DISMISSED menu must still write a marker — writing nothing is the nag loop, since
  # repo state is the only thing that suppresses the question. It is bounded at an hour,
  # not the rest of the day: a dismissal is "not now", not "no deadline today".
  DISMISS_ARGS="$TMP/nd-dismiss-args.txt"
  : >"$DISMISS_ARGS"
  # Read the clock HERE, not from the suite-level NOW: Parts 1-3 run real subprocesses,
  # and a minute of elapsed time would push the marker past a bound measured from a
  # timestamp taken before them, failing on machine speed rather than on behaviour.
  DISMISS_NOW=$(date -u +%s)
  DISMISS_OUT=$(
    set -euo pipefail
    export STUB_ARGS_FILE="$DISMISS_ARGS" STUB_SET_RC=0 STUB_FLAKE_ONCE_FILE=""
    SESSION_STATE_SH="$STUB_ND"
    REPO_KEY="org/repo"
    ND_SCOPE=dismissed
    eval "$ND_BLOCK"
    printf '%s|%s\n' "$NO_DEADLINE_RC" "$NO_DEADLINE_UNTIL"
  )
  DISMISS_RC="${DISMISS_OUT%%|*}"
  DISMISS_EPOCH="${DISMISS_OUT##*|}"
  [ "$DISMISS_RC" = "0" ] \
    || fail "a dismissed menu must still write its suppression marker (rc: $DISMISS_RC)"
  [ -s "$DISMISS_ARGS" ] \
    || fail 'a dismissed menu wrote nothing — the gate would re-ask on the very next launch'
  if [ -n "$DISMISS_EPOCH" ] && [ "$DISMISS_EPOCH" -gt 0 ] 2>/dev/null; then
    [ "$DISMISS_EPOCH" -gt "$DISMISS_NOW" ] || fail 'a dismissal marker must be in the future'
    # Strictly shorter than the day marker: this is the assertion that would fail if the
    # dismissal path were quietly reusing the end-of-day boundary.
    [ "$DISMISS_EPOCH" -le $(( DISMISS_NOW + 3660 )) ] \
      || fail "a dismissal must suppress for about an hour, not the rest of the day (got: $DISMISS_EPOCH)"
  else
    fail "a dismissed menu must produce a positive epoch (got: '$DISMISS_EPOCH')"
  fi

  # ...but a lock timeout that clears on the retry must NOT be reported as a failure, or
  # the question fires again on the very next launch despite the marker being written.
  ND_FLAKE_MARK="$TMP/nd-flake-once"
  rm -f "$ND_FLAKE_MARK"
  ND_RETRY=$(
    set -euo pipefail
    export STUB_ARGS_FILE=/dev/null STUB_SET_RC=0 STUB_FLAKE_ONCE_FILE="$ND_FLAKE_MARK"
    SESSION_STATE_SH="$STUB_ND"
    REPO_KEY="org/repo"
    eval "$ND_BLOCK"
    printf '%s\n' "$NO_DEADLINE_RC"
  )
  [ "$ND_RETRY" = "0" ] \
    || fail "a lock timeout on the marker write must be retried once (got: $ND_RETRY)"
  rm -f "$ND_FLAKE_MARK"

  ok_group 'no-deadline-today: a DST-safe ET end-of-day marker, active:false, no window armed'
fi

# ---------------------------------------------------------------------------
# Part 4 — the check-in forces `parks` for a launch-anyway row
# ---------------------------------------------------------------------------
PARKS_READ_BLOCK="$(extract_skill_bash "$ROOT/$LEAVE_SKILL" leave-by-checkin-launch-decisions-read)" \
  || { fail 'could not extract the /leave-by check-in launch-decisions read'; PARKS_READ_BLOCK=""; }
PARKS_BLOCK="$(extract_skill_bash "$ROOT/$LEAVE_SKILL" leave-by-checkin-launch-anyway-parks)" \
  || { fail 'could not extract the /leave-by check-in launch-anyway block'; PARKS_BLOCK=""; }

# The per-row block must do NO state I/O — it is evaluated once per table row, and a read
# in there is N calls behind one render plus rows that can disagree with each other.
case "$PARKS_BLOCK" in
  *SESSION_STATE_SH*) fail 'the per-row verdict block must not read state — hoist the read above the loop' ;;
  *) : ;;
esac

STUB_PARKS="$TMP/session-state-parks.sh"
cat >"$STUB_PARKS" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${STUB_ARGS_FILE:-/dev/null}"
case "$*" in
  *launch_decisions)
    # STUB_FLAKE_ONCE_FILE lets a case fail the FIRST read with a lock timeout and
    # succeed on the second, so the retry can be shown to happen rather than assumed.
    if [ -n "${STUB_FLAKE_ONCE_FILE:-}" ] && [ ! -f "$STUB_FLAKE_ONCE_FILE" ]; then
      : >"$STUB_FLAKE_ONCE_FILE"
      exit 6
    fi
    printf '%s\n' "${STUB_MAP-null}"; exit "${STUB_MAP_RC:-0}"
    ;;
esac
printf 'session-state stub: unexpected argv: %s\n' "$*" >&2
exit 99
STUB
chmod +x "$STUB_PARKS"
STUB_PARKS_ARGS="$TMP/parks-args.txt"

run_parks() {
  # $1 = map JSON, $2 = read rc, $3 = row issue, $4 = validated deadline epoch
  (
    set -euo pipefail
    export STUB_MAP="$1" STUB_MAP_RC="$2" STUB_ARGS_FILE="$STUB_PARKS_ARGS"
    # Exported explicitly: a `VAR=x run_parks …` prefix sets a SHELL variable for a
    # function call, which the stub (a separate process) would never see.
    export STUB_FLAKE_ONCE_FILE="${STUB_FLAKE_ONCE_FILE:-}"
    SESSION_STATE_SH="$STUB_PARKS"
    REPO_KEY="org/repo"
    ROW_ISSUE="$3"
    DEADLINE_EPOCH="$4"
    eval "$PARKS_READ_BLOCK"
    eval "$PARKS_BLOCK"
    printf '%s\n' "${ROW_VERDICT_FORCED:-NONE}"
  ) 2>/dev/null
}

if [ -n "$PARKS_BLOCK" ] && [ -n "$PARKS_READ_BLOCK" ]; then
  group_start
  DL=$(( NOW + 3600 ))
  OTHER_DL=$(( NOW + 7200 ))
  MAP="{\"1679\":{\"decision\":\"launch_anyway\",\"deadline_epoch\":${DL}},\"1512\":{\"decision\":\"skip\",\"deadline_epoch\":${DL}}}"
  MAP_STALE="{\"1679\":{\"decision\":\"launch_anyway\",\"deadline_epoch\":${OTHER_DL}}}"

  [ "$(run_parks "$MAP" 0 1679 "$DL")" = "parks" ] \
    || fail 'a launch-anyway row on the armed deadline must be forced to parks'
  [ "$(run_parks "$MAP" 0 1512 "$DL")" = "NONE" ] \
    || fail 'a "skip" record must not force a verdict — that row was never launched'
  [ "$(run_parks "$MAP" 0 1504 "$DL")" = "NONE" ] \
    || fail 'a row with no record must be judged normally'
  [ "$(run_parks "$MAP_STALE" 0 1679 "$DL")" = "NONE" ] \
    || fail 'a record naming a previous deadline must not keep forcing parks after a re-declaration'
  [ "$(run_parks "null" 3 1679 "$DL")" = "NONE" ] \
    || fail 'an absent map must leave every row to the normal comparison'
  # Fail closed: an unreadable map keeps rows at parks rather than promoting them.
  [ "$(run_parks "null" 6 1679 "$DL")" = "parks" ] \
    || fail 'an unreadable decision map must fail closed to parks, not to "finishes by deadline"'

  # A CORRUPT map is not an absent one. `--get-json` exists to tell them apart, so reading
  # a damaged record as "nothing forced" would promote every launch-anyway row to
  # "finishes by deadline" — the one direction this must never fail.
  [ "$(run_parks '"not-an-object"' 0 1679 "$DL")" = "parks" ] \
    || fail 'a corrupt (non-object) decision map must fail closed to parks, not read as absent'
  [ "$(run_parks '[1,2,3]' 0 1679 "$DL")" = "parks" ] \
    || fail 'an array where the decision map should be must fail closed to parks'

  # A lock timeout is retryable, and the retry has to be IN the block: a first read that
  # times out and a second that succeeds must yield the normal verdict, not a forced park.
  FLAKE_MARK="$TMP/parks-flake-once"
  rm -f "$FLAKE_MARK"
  FLAKE_OUT=$(STUB_FLAKE_ONCE_FILE="$FLAKE_MARK" run_parks "$MAP" 0 1504 "$DL")
  [ "$FLAKE_OUT" = "NONE" ] \
    || fail "a lock timeout must be retried once, not taken as final (got: $FLAKE_OUT)"
  rm -f "$FLAKE_MARK"

  # The QUERY, not just the verdict: the recorder exists, so assert against it rather than
  # letting a read of some other path satisfy every case above.
  if [ ! -s "$STUB_PARKS_ARGS" ]; then
    fail 'the check-in never invoked session-state.sh — it cannot be reading the decisions'
  else
    PARKS_BAD=$(grep -vcxF -- '--get-json .repos["org/repo"].window.launch_decisions' \
      "$STUB_PARKS_ARGS" || true)
    [ "$PARKS_BAD" = "0" ] || fail \
      "the check-in must read the whole map with --get-json at .window.launch_decisions ($PARKS_BAD differed: $(sort -u "$STUB_PARKS_ARGS" | paste -sd'|' -))"
  fi

  ok_group 'check-in verdict: launch-anyway forces parks, keyed to the armed deadline'
fi

# ---------------------------------------------------------------------------
# Part 4b — the planning-only marker, and the `false`-is-not-absent trap
# ---------------------------------------------------------------------------
MARKER_BLOCK="$(extract_skill_bash "$ROOT/$LEAVE_SKILL" leave-by-elicit-planning-only-marker)" \
  || { fail 'could not extract the /leave-by planning-only marker write'; MARKER_BLOCK=""; }

if [ -n "$MARKER_BLOCK" ]; then
  group_start
  MARKER_ARGS="$TMP/marker-args.txt"
  : >"$MARKER_ARGS"
  MARKER_OUT=$(
    set -euo pipefail
    export STUB_ARGS_FILE="$MARKER_ARGS" STUB_SET_RC=0 STUB_FLAKE_ONCE_FILE=""
    SESSION_STATE_SH="$STUB_ND"
    REPO_KEY="org/repo"
    eval "$MARKER_BLOCK"
    printf '%s\n' "$PLANNING_ONLY_RC"
  )
  [ "$MARKER_OUT" = "0" ] || fail "the planning-only marker write must report rc 0 (got: $MARKER_OUT)"
  grep -qxF -- '--set .repos["org/repo"].leave.winddown_scheduled=false' "$MARKER_ARGS" \
    || fail "the elicitation path must mark the record planning-only (wrote: $(cat "$MARKER_ARGS"))"

  MARKER_FLAKE="$TMP/marker-flake-once"
  rm -f "$MARKER_FLAKE"
  MARKER_RETRY=$(
    set -euo pipefail
    export STUB_ARGS_FILE=/dev/null STUB_SET_RC=0 STUB_FLAKE_ONCE_FILE="$MARKER_FLAKE"
    SESSION_STATE_SH="$STUB_ND"
    REPO_KEY="org/repo"
    eval "$MARKER_BLOCK"
    printf '%s\n' "$PLANNING_ONLY_RC"
  )
  [ "$MARKER_RETRY" = "0" ] \
    || fail "a lock timeout on the marker write must be retried once (got: $MARKER_RETRY)"
  rm -f "$MARKER_FLAKE"

  # The trap this marker is most likely to die of: jq's `// empty` reads a literal `false`
  # as absent, so the one value that must suppress re-arming would read as "no marker".
  # Assert the reader's own expression against all three shapes.
  READ_EXPR='.winddown_scheduled | if . == null then "" else tostring end'
  grep -Fq -- "$READ_EXPR" "$ROOT/$LEAVE_SKILL" \
    || fail 'Step 11 must read winddown_scheduled with an expression that keeps `false` distinct from absent'
  [ "$(printf '%s' '{"winddown_scheduled":false}' | jq -r "$READ_EXPR")" = "false" ] \
    || fail 'the reader expression must surface a literal false'
  [ "$(printf '%s' '{"winddown_scheduled":true}' | jq -r "$READ_EXPR")" = "true" ] \
    || fail 'the reader expression must surface a literal true'
  [ "$(printf '%s' '{}' | jq -r "$READ_EXPR")" = "" ] \
    || fail 'the reader expression must report an absent field as empty, so pre-#1679 records still re-arm'
  # The negative control: the tempting form fails the first case, which is why it is banned.
  [ "$(printf '%s' '{"winddown_scheduled":false}' | jq -r '.winddown_scheduled // empty')" = "" ] \
    || fail 'control failed: `// empty` was expected to swallow a literal false'

  ok_group 'planning-only marker: written and retried, and read without folding false into absent'
fi

# ---------------------------------------------------------------------------
# Part 5 — cross-file contracts with no executable form
# ---------------------------------------------------------------------------
group_start

# One parser, one deadline home. The gate must DELEGATE, never normalize a time itself.
require_text "$SUBAGENT_SKILL" '/leave-by --elicit' \
  'the launch gate must delegate the elicited time to /leave-by, never parse it itself'
# The MODE-TABLE row, not the bare flag: `--elicit` also appears in the argument-hint, so a
# bare needle passes over a skill that advertises the mode and dispatches nothing.
require_text "$LEAVE_SKILL" '**elicit** (Step 0e)' \
  'leave-by must dispatch the internal --elicit invocation, not merely advertise it'
# Single-line needles, deliberately: `grep -F` reads an embedded newline as a SECOND
# pattern, so a two-line needle passes when either half is present anywhere in the file.
require_text "$LEAVE_SKILL" 'Step 6 is the only step that does not run: no Monitor, no wind-down' \
  'the elicitation path must arm Steps 1-5 only — a question answered in passing must not schedule an interruption'

# The source gate is SATISFIED by a live answer, never bypassed by text.
require_text "$LEAVE_SKILL" 'pre-fill the menu from such text' \
  'a leave time arriving as text must not be laundered into the elicitation menu'

# Never elicit where no live user can answer.
require_text "$PM_SKILL" 'Neither question ever fires from `/pm day` or `/pm --window`' \
  '/pm must state that day-mode ticks and --window runs never elicit'
require_text "$SUBAGENT_SKILL" 'ELICIT_SKIP_REASON="unattended"' \
  'an unattended launch must SKIP the question, not fail on it'
require_text "$SUBAGENT_SKILL" '`ELICIT_LEAVE_TIME` is a new-pipeline concern' \
  'phase transitions must be excluded from elicitation in the monitor loop'

# An elicited time never had a Monitor, so no recovery path may invent one for it.
require_text "$LEAVE_SKILL" 'RECOVERY_WINDDOWN_SCHEDULED' \
  'Step 11 recovery must consult the planning-only marker before re-arming a wind-down'
require_text .claude/skills/pause-resume/SKILL.md 'leave.winddown_scheduled' \
  '/pause-resume must not re-arm a wind-down for a planning-only leave time'
require_text "$SCHEMA" 'winddown_scheduled' \
  'the schema must document the planning-only marker'

# .window is a MUTABLE object now, so a retirement CAS must identify it by its deadline.
require_text "$LEAVE_SKILL" 'IDENTITY IS THE DEADLINE, NOT THE OBJECT' \
  'the retirement CAS must not lose to a launch_decisions write and strand a spent deadline'

# The pause point, and the one place its input lives.
require_text "$SUBAGENT_SKILL" 'PAUSE_POINT_EPOCH=$(( DEADLINE_EPOCH - LEAD_MIN * 60 ))' \
  'the gate must derive the pause point by subtracting the lead from the raw deadline'
require_text .claude/rules/scheduling-reliability.md 'deadline_epoch − lead_minutes×60' \
  'the auto-loaded rule must name the pause point the launch gate plans against'
require_text .claude/rules/scheduling-reliability.md '/leave-by --elicit' \
  'the auto-loaded rule must route the unarmed case to the elicitation path'

# The verdict contract, in BOTH files that state it — fixing one and leaving the other
# is how the check-in and its own definition come to disagree.
require_text .claude/reference/time-estimates.md 'launch_anyway' \
  'the verdict definition must name the launch-anyway override'
require_text "$LEAVE_SKILL" 'launch_decisions' \
  'the check-in must read the launch decisions before judging rows'

# The two new fields are documented where their writers and readers look.
require_text "$SCHEMA" 'no_deadline_until' \
  'the schema must document the no-deadline-today marker'
require_text "$SCHEMA" 'launch_decisions' \
  'the schema must document the launch-decision map'
require_text "$SCHEMA" 'ONE KEY AT A TIME' \
  'the schema must require per-key writes so a concurrent sibling entry is never dropped'

ok_group 'cross-file contracts: one parser, one deadline home, no elicitation without a live user'

if [ "$FAILURES" -ne 0 ]; then
  printf 'FAIL: %d leave-time elicitation assertion(s) failed\n' "$FAILURES" >&2
  exit 1
fi
ok 'leave-time elicitation, pause-point planning, and the remembered overrun answer hold'
