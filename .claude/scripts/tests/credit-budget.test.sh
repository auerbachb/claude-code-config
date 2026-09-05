#!/usr/bin/env bash
# credit-budget.test.sh — coverage for .claude/scripts/credit-budget.sh and the
# lib/usage-limit-classify.sh library it shares with the recorder hook
# (issue #1633).
#
# The defect under test: every `rate_limit` event counted as a credit overage,
# so four plan-window hits before 07:15Z froze autonomous dispatch for the whole
# ET day while the account was on plan and had spent nothing.
#
# Covers:
#   - the classifier matrix: each plan-wall shape, each credit-exhausted shape,
#     the precedence rules, and `unclassified` for unrelated prose
#   - reset-clause parsing: same-day, next-day rollover, a named zone, and the
#     shapes it must REFUSE to guess at rather than invent an instant for
#   - the gate: plan-window fixtures -> ok, an overage fixture -> reached, an
#     overage whose window has reopened -> never reached
#   - legacy records (no `limit_kind` field) classified identically to fresh ones
#   - a NEGATIVE CONTROL: the pre-fix predicate, copied verbatim from the code
#     this change replaced, still matches the plan-window fixture — proving the
#     fixture would have frozen dispatch, so the new `ok` is a real fix and not
#     a vacuous pass against a fixture that never tripped anything
#   - PAIRED positive controls, so an `ok` can never come from a gate that
#     simply stopped firing
#   - fail-closed paths: unreadable log -> unknown, missing library -> exit 5
#
# ALL FIXTURES ARE SYNTHETIC. The real ~/.claude/usage-limit-events.jsonl is
# never read, copied, or referenced: HOME and CLAUDE_USAGE_LIMIT_DIR are
# redirected into a temp tree for every invocation.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
SCRIPT="$ROOT/.claude/scripts/credit-budget.sh"
LIB="$ROOT/.claude/scripts/lib/usage-limit-classify.sh"

command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not installed"; exit 0; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

PASS=0
FAILED=0
ok()  { PASS=$((PASS + 1)); echo "ok   — $*"; }
bad() { FAILED=$((FAILED + 1)); echo "FAIL — $*" >&2; }

check_eq() { # <actual> <expected> <label>
  if [[ "$1" == "$2" ]]; then ok "$3"; else bad "$3 (got '$1', want '$2')"; fi
}

# --- portable date helpers, mirroring the ones under test --------------------
# GNU `-d "@epoch"` arm first, per issue #1587 — see date-r-ordering.test.sh.
epoch_to_iso() { # <epoch>
  date -u -d "@$1" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null \
    || date -u -r "$1" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null
}
et_day_bound() { # <YYYY-MM-DD>
  TZ='America/New_York' date -j -f '%Y-%m-%d %H:%M:%S' "$1 00:00:00" '+%s' 2>/dev/null \
    || TZ='America/New_York' date -d "$1 00:00:00" '+%s' 2>/dev/null
}
et_next_day() { # <YYYY-MM-DD>
  TZ='America/New_York' date -j -v+1d -f '%Y-%m-%d' "$1" '+%Y-%m-%d' 2>/dev/null \
    || TZ='America/New_York' date -d "$1 + 1 day" '+%Y-%m-%d' 2>/dev/null
}

NOW_EPOCH="$(date -u '+%s')"
TODAY_ET="$(TZ='America/New_York' date '+%Y-%m-%d')"
TOMORROW_ET="$(et_next_day "$TODAY_ET")"
ET_START="$(et_day_bound "$TODAY_ET")"
ET_END="$(et_day_bound "$TOMORROW_ET")"

# An instant guaranteed to sit inside today's ET calendar day whatever time the
# suite runs. `now - 1 hour` would NOT do: run at 00:30 ET it lands on
# yesterday, every fixture falls outside the day window, and the whole suite
# passes for the wrong reason.
IN_DAY_ISO="$(epoch_to_iso "$(TZ='America/New_York' date -j -f '%Y-%m-%d %H:%M:%S' "$TODAY_ET 12:00:00" '+%s' 2>/dev/null \
  || TZ='America/New_York' date -d "$TODAY_ET 12:00:00" '+%s' 2>/dev/null)")"
# Absolute instants for the reset tests — judged against `now`, not the day
# window, so they are safe to place anywhere on the clock.
PAST_ISO="$(epoch_to_iso "$((NOW_EPOCH - 3600))")"
FUTURE_ISO="$(epoch_to_iso "$((NOW_EPOCH + 7200))")"
YESTERDAY_ISO="$(epoch_to_iso "$((ET_START - 3600))")"

for v in IN_DAY_ISO PAST_ISO FUTURE_ISO YESTERDAY_ISO ET_START ET_END; do
  [[ -n "${!v:-}" ]] || { echo "FAIL — could not compute $v (date(1) unusable)" >&2; exit 1; }
done

# =============================================================================
# 1. Classifier matrix
# =============================================================================
# shellcheck source=../lib/usage-limit-classify.sh
source "$LIB"

kind_is() { # <message> <expected> <label>
  check_eq "$(usage_limit_kind "$1")" "$2" "$3"
}

# The exact message four sessions died on, 2026-09-04.
OBSERVED="You've hit your weekly limit · resets 1pm (America/New_York)"

kind_is "$OBSERVED"                                    plan_window  "observed weekly-limit message is plan_window"
kind_is "You've hit your usage limit"                  plan_window  "usage limit, no reset stated"
kind_is "You've hit your rate limit"                   plan_window  "rate limit"
kind_is "Weekly limit reached"                         plan_window  "weekly limit reached"
kind_is "You've reached your usage limit for now"      plan_window  "reached your usage limit"
kind_is "You are near the 5-hour limit"                plan_window  "5-hour window"
kind_is "Your credit balance is too low to continue."  overage      "credit balance too low is overage"
kind_is "You are out of credits."                      overage      "out of credits is overage"
kind_is "Insufficient credits for this request"        overage      "insufficient credits is overage"
kind_is "Your monthly spending limit was reached"      overage      "spending limit is overage"
kind_is "The build failed with exit code 2"            unclassified "unrelated prose is unclassified"
kind_is ""                                             unclassified "empty message is unclassified, never overage"

# Precedence, which is the whole point of the file.
kind_is "You've hit your usage limit — purchase credits to continue" \
  plan_window "an upsell inside a plan wall stays plan_window (it is not proof of spend)"
kind_is "Rate limit hit. Resets at 3:00 PM (America/New_York). Buy credits to keep going." \
  plan_window "a stated reset outranks upsell wording"
kind_is "Out of credits. Resets 9am (America/New_York)" \
  plan_window "a stated reset outranks even explicit credit wording — balances do not reset on a clock"

# Case-insensitivity: the vendor capitalizes inconsistently across surfaces.
kind_is "YOU'VE HIT YOUR WEEKLY LIMIT"                 plan_window  "classification is case-insensitive"

# =============================================================================
# 2. Reset-clause parsing
# =============================================================================
# Recorded 06:23Z; "resets 1pm America/New_York" is 17:00Z the same day.
check_eq "$(usage_limit_reset_at "$OBSERVED" "2026-09-04T06:23:11Z")" \
  "2026-09-04T17:00:00Z" "resets 1pm (ET) anchored to the record's own day"

# Recorded 18:00Z, i.e. after that day's 1pm ET — the clause names TOMORROW's.
check_eq "$(usage_limit_reset_at "$OBSERVED" "2026-09-04T18:00:00Z")" \
  "2026-09-05T17:00:00Z" "a wall-clock time already past rolls to the next occurrence"

check_eq "$(usage_limit_reset_at "Resets at 3:00 PM (America/New_York)" "2026-09-04T06:23:11Z")" \
  "2026-09-04T19:00:00Z" "'resets at H:MM PM' with a named zone"

check_eq "$(usage_limit_reset_at "You've hit your weekly limit · resets tomorrow at 9am (America/New_York)" "2026-09-04T06:23:11Z")" \
  "2026-09-05T13:00:00Z" "'resets tomorrow at 9am' advances a day"

# Refusals: an unparseable clause must yield NOTHING, never an invented instant.
check_eq "$(usage_limit_reset_at "You've hit your usage limit" "2026-09-04T06:23:11Z")" \
  "" "no reset clause yields no instant"
check_eq "$(usage_limit_reset_at "Rate limit · resets in 3 hours" "2026-09-04T06:23:11Z")" \
  "" "a DURATION is refused rather than read as a wall-clock hour"
check_eq "$(usage_limit_reset_at "Please reset your password, see step 2" "2026-09-04T06:23:11Z")" \
  "" "an unrelated 'reset' near a digit is not a reset clause"

# The classifier and the parser must agree about whether a reset was stated.
if usage_limit_has_reset_clause "$OBSERVED"; then
  ok "has_reset_clause true for the observed message"
else
  bad "has_reset_clause false for the observed message"
fi
if usage_limit_has_reset_clause "Please reset your password, see step 2"; then
  bad "has_reset_clause matched an unrelated 'reset'"
else
  ok "has_reset_clause rejects an unrelated 'reset'"
fi

# The DAY-WORD arm of the same predicate, which used to search the whole 40-char
# window instead of anchoring to the word "reset" (CodeAnt, PR #1638). Because a
# stated reset outranks the overage phrase list in usage_limit_kind, a false
# positive here downgrades a real overage to plan_window and un-gates spend —
# so the negative cases matter more than the positive ones.
if usage_limit_has_reset_clause "Please reset your password tomorrow"; then
  bad "has_reset_clause matched an unrelated 'reset' followed by a day word"
else
  ok "has_reset_clause rejects an unrelated 'reset' followed by a day word"
fi
if usage_limit_has_reset_clause "To reset your billing contact on Monday, see step 2"; then
  bad "has_reset_clause matched an unrelated 'reset' followed by a weekday"
else
  ok "has_reset_clause rejects an unrelated 'reset' followed by a weekday"
fi
# The end that matters: that false positive must not swallow a real overage.
check_eq "$(usage_limit_kind "You have run out of credits. Please reset your password tomorrow.")" \
  "overage" "an unrelated 'reset ... tomorrow' does not mask a credit overage"

# PAIRED positive controls — the anchoring must not have simply stopped the
# day-word arm from ever firing.
if usage_limit_has_reset_clause "Usage limit reached · resets tomorrow"; then
  ok "has_reset_clause still accepts 'resets tomorrow' with no clock time"
else
  bad "has_reset_clause rejected 'resets tomorrow'"
fi
if usage_limit_has_reset_clause "Weekly limit reached · resets on Monday"; then
  ok "has_reset_clause still accepts 'resets on Monday'"
else
  bad "has_reset_clause rejected 'resets on Monday'"
fi
check_eq "$(usage_limit_kind "Weekly limit reached · resets on Monday")" \
  "plan_window" "a day-only reset clause still classifies as a plan window"

# NEGATIVE CONTROL: the pre-fix day-word arm, verbatim, still matches the
# password fixture — proving these cases would have misclassified before the
# change rather than passing vacuously against the new code.
_prefix_day_arm() { # <message> -> exit 0 when the OLD code saw a reset clause
  local lower rest
  lower="$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]')"
  case "$lower" in *reset*) ;; *) return 1 ;; esac
  rest="${lower#*reset}"; rest="${rest:0:40}"
  case "$rest" in
    *tomorrow*|*monday*|*tuesday*|*wednesday*|*thursday*|*friday*|*saturday*|*sunday*)
      return 0 ;;
  esac
  return 1
}
if _prefix_day_arm "Please reset your password tomorrow"; then
  ok "negative control: the pre-fix day-word arm did match the password fixture"
else
  bad "negative control failed — fixture never tripped the old code, so the new pass is vacuous"
fi

# usage_limit_reset_passed: only a positively established reopening returns 0.
if usage_limit_reset_passed "$PAST_ISO" "$NOW_EPOCH"; then
  ok "reset_passed true for an instant already gone"
else
  bad "reset_passed false for an instant already gone"
fi
if usage_limit_reset_passed "$FUTURE_ISO" "$NOW_EPOCH"; then
  bad "reset_passed true for a future instant"
else
  ok "reset_passed false for a future instant"
fi
if usage_limit_reset_passed "" "$NOW_EPOCH"; then
  bad "reset_passed treated 'no instant stated' as a reopening"
else
  ok "reset_passed: absence of information is never a reopening"
fi
if usage_limit_reset_passed "not-a-timestamp" "$NOW_EPOCH"; then
  bad "reset_passed treated an unparseable instant as a reopening"
else
  ok "reset_passed: an unparseable instant is never a reopening"
fi

# The library must be source-only: executing it would report success silently.
LIB_RC=0
bash "$LIB" >/dev/null 2>&1 || LIB_RC=$?
check_eq "$LIB_RC" "2" "the library refuses direct execution"

# =============================================================================
# 3. The gate — end-to-end against synthetic event logs
# =============================================================================
EVENT_DIR="$TMP/events"
FAKE_HOME="$TMP/home"
mkdir -p "$EVENT_DIR" "$FAKE_HOME/.claude"

# One synthetic event line. Empty kind/reset produce JSON nulls — the legacy
# record shape, written before the recorder classified anything.
event() { # <recorded_at> <limit_kind> <reset_at> <message>
  jq -cn --arg ra "$1" --arg k "$2" --arg r "$3" --arg m "$4" \
    '{recorded_at: $ra, reason: "rate_limit",
      limit_kind: (if $k == "" then null else $k end),
      reset_at:   (if $r == "" then null else $r end),
      last_assistant_message: $m}'
}

# Each run starts from clean state: `--check` short-circuits on a persisted
# same-day `reached`, so a leftover from the previous case would decide the
# next one before its fixture was ever read.
run_check() { # stdout = JSON, sets RUN_RC
  rm -f "$FAKE_HOME/.claude/session-state.json"
  RUN_RC=0
  HOME="$FAKE_HOME" \
  CLAUDE_USAGE_LIMIT_DIR="$EVENT_DIR" \
  CLAUDE_DAILY_CREDIT_BUDGET_USD=25 \
    bash "$SCRIPT" --check 2>/dev/null || RUN_RC=$?
}

status_of() { printf '%s' "$1" | jq -r '.status // "?"'; }

expect_gate() { # <expected status> <expected rc> <label>
  run_check > "$TMP/out.json"
  check_eq "$(status_of "$(cat "$TMP/out.json")")/$RUN_RC" "$1/$2" "$3"
}

LOG="$EVENT_DIR/usage-limit-events.jsonl"

# --- 3a. THE REGRESSION: four plan-window events, exactly as recorded --------
: > "$LOG"
for _ in 1 2 3 4; do
  event "$IN_DAY_ISO" "plan_window" "$PAST_ISO" "$OBSERVED" >> "$LOG"
done
expect_gate ok 0 "four plan-window events today -> ok (issue #1633 regression)"

# --- 3b. NEGATIVE CONTROL ----------------------------------------------------
# The predicate this change replaced, copied verbatim from the removed code:
# reason == "rate_limit" plus the ET-day window, and nothing else. It must
# still MATCH the fixture above — that is what proves the fixture would have
# returned `reached` before this fix, so 3a's `ok` is a behavior change and not
# a fixture that never tripped the old gate either.
PREFIX_MATCH="$(jq -rn \
  --argjson et_start "$ET_START" \
  --argjson et_end "$ET_END" \
  'first(inputs |
    select(.reason == "rate_limit") |
    select(
      (.recorded_at // "") |
      if . == "" then false
      else (fromdateiso8601 as $ep | $ep >= $et_start and $ep < $et_end)
      end
    ) | .reason)' \
  "$LOG" 2>/dev/null)"
check_eq "$PREFIX_MATCH" "rate_limit" \
  "negative control: the PRE-FIX predicate does match this fixture (it would have frozen dispatch)"

# --- 3c. Legacy records: no limit_kind, no reset_at --------------------------
: > "$LOG"
for _ in 1 2 3 4; do
  event "$IN_DAY_ISO" "" "" "$OBSERVED" >> "$LOG"
done
expect_gate ok 0 "legacy plan-window records (no limit_kind) classify from prose -> ok"

# --- 3d. POSITIVE CONTROL: a genuine overage still gates ---------------------
: > "$LOG"
event "$IN_DAY_ISO" "overage" "" "Your credit balance is too low to continue." >> "$LOG"
expect_gate reached 1 "positive control: a genuine overage event still yields reached"

: > "$LOG"
event "$IN_DAY_ISO" "" "" "Your credit balance is too low to continue." >> "$LOG"
expect_gate reached 1 "positive control: a legacy overage record still yields reached"

# --- 3e. A reopened window never gates ---------------------------------------
: > "$LOG"
event "$IN_DAY_ISO" "overage" "$PAST_ISO" "Your credit balance is too low." >> "$LOG"
expect_gate ok 0 "an event whose reset time has passed never produces reached"

: > "$LOG"
event "$IN_DAY_ISO" "overage" "$FUTURE_ISO" "Your credit balance is too low." >> "$LOG"
expect_gate reached 1 "paired control: the same event with a FUTURE reset does gate"

# --- 3f. A plan-window event must not shadow a later overage -----------------
: > "$LOG"
event "$IN_DAY_ISO" "plan_window" "" "$OBSERVED" >> "$LOG"
event "$IN_DAY_ISO" "overage" "" "You are out of credits." >> "$LOG"
expect_gate reached 1 "a leading plan-window event does not shadow a later overage"

# --- 3g. Day window still respected ------------------------------------------
: > "$LOG"
event "$YESTERDAY_ISO" "overage" "" "Your credit balance is too low." >> "$LOG"
expect_gate ok 0 "an overage recorded before today's ET day does not gate"

# --- 3h. Fail-closed paths ----------------------------------------------------
: > "$LOG"
expect_gate ok 0 "an empty event log is ok"

rm -f "$LOG"
expect_gate ok 0 "a log that was never created is ok (fresh install)"

mkdir -p "$LOG"
expect_gate unknown 2 "an unreadable log is unknown, never ok — unreadable state is not permission"
rmdir "$LOG"

# Missing library -> exit 5, loudly. The gate cannot tell the two kinds apart
# without it, and both silent alternatives are wrong.
STAGE="$TMP/stage"
mkdir -p "$STAGE/lib"
cp "$ROOT/.claude/scripts/credit-budget.sh" "$STAGE/"
cp "$ROOT/.claude/scripts/state-lock.sh" "$STAGE/"
MISSING_RC=0
HOME="$FAKE_HOME" CLAUDE_USAGE_LIMIT_DIR="$EVENT_DIR" \
  bash "$STAGE/credit-budget.sh" --check >/dev/null 2>&1 || MISSING_RC=$?
check_eq "$MISSING_RC" "5" "a missing classifier library fails loudly (exit 5), never silently"

# =============================================================================
# 4. Unchanged surface
# =============================================================================
HELP_OUT="$(bash "$SCRIPT" --help 2>/dev/null)"
case "$HELP_OUT" in
  *"credit-budget.sh --check"*) ok "--help still prints the usage header" ;;
  *) bad "--help output lost its usage header" ;;
esac
case "$HELP_OUT" in
  *"overage"*) ok "--help documents what counts as an overage" ;;
  *) bad "--help does not say what counts as an overage" ;;
esac

USAGE_RC=0
bash "$SCRIPT" --nope >/dev/null 2>&1 || USAGE_RC=$?
check_eq "$USAGE_RC" "3" "an unknown flag is still a usage error"

USAGE_RC=0
bash "$SCRIPT" >/dev/null 2>&1 || USAGE_RC=$?
check_eq "$USAGE_RC" "3" "a missing mode is still a usage error"

# --reset still clears to ok and persists the override.
: > "$LOG"
event "$IN_DAY_ISO" "overage" "" "Your credit balance is too low." >> "$LOG"
rm -f "$FAKE_HOME/.claude/session-state.json"
RESET_RC=0
RESET_OUT="$(HOME="$FAKE_HOME" CLAUDE_USAGE_LIMIT_DIR="$EVENT_DIR" \
  CLAUDE_DAILY_CREDIT_BUDGET_USD=25 bash "$SCRIPT" --reset 2>/dev/null)" || RESET_RC=$?
check_eq "$(status_of "$RESET_OUT")/$RESET_RC" "ok/0" "--reset still clears to ok"

# =============================================================================
# 5. GNU/BSD `date -r` ordering (issue #1587 convention)
# =============================================================================
# `-r` exists on both platforms with different meanings: BSD reads epoch
# seconds, GNU reads a FILENAME and prints that file's mtime. A BSD-first chain
# works on GNU only by accident — until a file happens to be named for the
# epoch, at which point GNU's `-r` succeeds and prints an unrelated time at exit
# 0. The library's epoch->text helpers put the unambiguous GNU `-d "@epoch"`
# arm first; this proves it with a hostile filesystem, which is the only way the
# defect is visible at all (never on BSD, and on GNU only with the decoy present).
SHIM_DIR="$TMP/gnubin"
mkdir -p "$SHIM_DIR"
REAL_DATE="$(command -v date)"
# Which flavour is the REAL binary? The shim has to delegate its `-d @epoch`
# work to it, and the two flavours need different flags for that. Discriminate
# on the RESULT, not on exit status: BSD `date -d` is the daylight-saving flag,
# so it accepts `-d @0` happily and prints the current year.
if [[ "$("$REAL_DATE" -u -d '@0' '+%Y' 2>/dev/null)" == "1970" ]]; then
  REAL_DATE_KIND=gnu
else
  REAL_DATE_KIND=bsd
fi
cat > "$SHIM_DIR/date" <<'SHIM'
#!/usr/bin/env bash
# GNU-coreutils-semantics `date` shim.
#   -d @EPOCH -> format that epoch (delegated to the real binary)
#   -r ARG    -> ARG is a FILENAME: emit a fixed sentinel when it exists, and
#                exit 1 when it does not — exactly what GNU date does.
set -uo pipefail
real="${SHIM_REAL_DATE:?SHIM_REAL_DATE must be set}"
kind="${SHIM_REAL_KIND:?SHIM_REAL_KIND must be set}"
mode=""; val=""; fmt=""; utc=0
while [ $# -gt 0 ]; do
  case "$1" in
    -u) utc=1; shift ;;
    -d) mode=d; val="${2:-}"; shift 2 ;;
    -r) mode=r; val="${2:-}"; shift 2 ;;
    +*) fmt="$1"; shift ;;
    *)  shift ;;
  esac
done
case "$mode" in
  d)
    # Delegate with the flag the REAL binary understands. Never a `||` chain
    # here: BSD's `-d` is the daylight-saving flag, so it would "succeed" and
    # print the current time instead of the requested epoch.
    ep="${val#@}"
    if [ "$kind" = gnu ]; then
      if [ "$utc" -eq 1 ]; then "$real" -u -d "@$ep" "$fmt"; else "$real" -d "@$ep" "$fmt"; fi
    else
      if [ "$utc" -eq 1 ]; then "$real" -u -r "$ep" "$fmt"; else "$real" -r "$ep" "$fmt"; fi
    fi
    ;;
  r) [ -e "$val" ] || exit 1; printf 'DECOY-MTIME\n' ;;
  *) exit 1 ;;
esac
SHIM
chmod +x "$SHIM_DIR/date"

DECOY_EPOCH=1788404400            # arbitrary but fixed
# Derived from the real binary, never hardcoded: a literal here would be one
# more thing to keep in sync, and getting it wrong would make the assertion
# fail for a reason that has nothing to do with argument ordering.
DECOY_EXPECT_ISO="$(epoch_to_iso "$DECOY_EPOCH")"
DECOY_EXPECT_ET_DAY="$(TZ='America/New_York' date -d "@$DECOY_EPOCH" '+%Y-%m-%d' 2>/dev/null \
  || TZ='America/New_York' date -r "$DECOY_EPOCH" '+%Y-%m-%d' 2>/dev/null)"
DECOY_DIR="$TMP/decoy"
mkdir -p "$DECOY_DIR"
: > "$DECOY_DIR/$DECOY_EPOCH"     # the hostile filesystem: a file NAMED for it

shimmed() { # <shell snippet> — run it with the GNU-semantics date shim in front
  ( cd "$DECOY_DIR" \
    && PATH="$SHIM_DIR:$PATH" SHIM_REAL_DATE="$REAL_DATE" \
       SHIM_REAL_KIND="$REAL_DATE_KIND" \
       bash -c "source '$LIB'; $1" 2>/dev/null )
}

check_eq "$(shimmed "_ulc_utc_iso_from_epoch $DECOY_EPOCH")" "$DECOY_EXPECT_ISO" \
  "_ulc_utc_iso_from_epoch converts the epoch, not the decoy file's mtime"
check_eq "$(shimmed "_ulc_day_in_zone America/New_York $DECOY_EPOCH")" "$DECOY_EXPECT_ET_DAY" \
  "_ulc_day_in_zone converts the epoch, not the decoy file's mtime"

# Negative control: the BSD-first chain this ordering replaced DOES render the
# decoy under the same shim. Without it, the two assertions above would pass on
# a BSD host whatever order the shipped code used.
OLD_CHAIN='date -u -r "$1" "+%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || date -u -d "@$1" "+%Y-%m-%dT%H:%M:%SZ" 2>/dev/null'
OLD_RENDER="$( cd "$DECOY_DIR" \
  && PATH="$SHIM_DIR:$PATH" SHIM_REAL_DATE="$REAL_DATE" \
     SHIM_REAL_KIND="$REAL_DATE_KIND" \
     bash -c "old() { $OLD_CHAIN; }; old $DECOY_EPOCH" 2>/dev/null )"
check_eq "$OLD_RENDER" "DECOY-MTIME" \
  "negative control: the OLD BSD-first chain does render the decoy (so the shim really is hostile)"

# =============================================================================
# 6. The estimation ban is satisfied architecturally
# =============================================================================
# Neither file may acquire a token/dollar arithmetic path. Comments naming the
# ban are expected and are stripped before the check, so prose about the rule
# never masks code that breaks it.
for f in "$SCRIPT" "$LIB"; do
  CODE_ONLY="$(sed 's/#.*$//' "$f")"
  if printf '%s' "$CODE_ONLY" | grep -Eq 'ccusage|tokens_used|cost_usd|price_per|estimate_(tokens|cost)'; then
    bad "$(basename "$f") gained a local token/cost estimation path"
  else
    ok "$(basename "$f") performs no local token/cost estimation"
  fi
done

echo
echo "passed: $PASS   failed: $FAILED"
[[ $FAILED -eq 0 ]]
