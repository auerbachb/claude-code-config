#!/usr/bin/env bash
# wait-until.sh — Poll a check command until it succeeds, with a hard cap.
# catalog: scheduling-monitoring — In-turn poll loop with a hard cap — the non-refused equivalent of `until <check>; do sleep <n>; done` for a worktree-isolated agent (`.claude/reference/worktree-isolation-command-shapes.md`); blocks the calling turn only, never a substitute for a persistent `Monitor`
#
# PURPOSE
#   The non-refused equivalent of the shape the sleep blocker itself recommends:
#
#     until <check>; do sleep <n>; done
#
#   A worktree-isolated agent is refused that loop by the harness's
#   worktree-isolation guard — "this command is too complex to verify that it
#   stays inside the worktree" — even when the loop contains no git at all. One
#   guard recommends the shape; the other refuses it, and the agent is left with
#   no way to follow the advice (issue #1470, case 2). This script runs the loop
#   INSIDE a single plain script call, which is an allowed shape. Full catalog of
#   refused vs allowed shapes:
#   .claude/reference/worktree-isolation-command-shapes.md
#
#   For waiting on a GitHub Actions run specifically, `gh run watch
#   --exit-status <id>` is already one command and is the preferred shortcut.
#   Reach for this script for conditions `gh run watch` cannot express.
#
#   THIS IS NOT A SCHEDULER. It blocks the calling turn for at most --timeout
#   seconds. Between-turn or recurring polling belongs to a persistent `Monitor`
#   (`.claude/rules/scheduling-reliability.md`), never to a longer cap here.
#
# USAGE
#   wait-until.sh [options] [--] <command> [args…]
#   wait-until.sh --help | -h
#
#   --interval <secs>  Seconds between checks (default 10; positive integer).
#   --timeout <secs>   Wall-clock cap on the whole wait (default 600; positive
#                      integer). The first check always runs, so a cap smaller
#                      than one interval still performs exactly one check. On
#                      the kill path the call can return up to ~5s LATE — see
#                      THE CHECK IS BOUNDED TOO.
#   --expect <string>  Condition is met when the check's stdout, trimmed of
#                      leading and trailing whitespace, EQUALS <string> and the
#                      check exited 0. Without this flag the condition is simply
#                      "the check exited 0".
#   --quiet            Suppress the per-tick heartbeat (stderr). The final
#                      outcome line is still emitted.
#   --                 Everything after this is the command, even if it starts
#                      with a dash. Optional: the first non-flag argument also
#                      begins the command.
#
# OUTPUT
#   stdout — on success, the check's last stdout, verbatim. Nothing otherwise,
#            so a caller can safely do:
#              STATUS=$(wait-until.sh --expect completed -- gh run view … )
#   stderr — one heartbeat per tick (unless --quiet) and one outcome line. The
#            check's own stderr is NOT relayed per tick (a polling loop would
#            repeat it N times); the last capture is printed once on failure.
#
# EXIT STATUS
#   0  Condition met.
#   2  Usage error (unknown flag, missing/invalid value, no command given, or
#      an unreadable clock — which would silently mean "no cap").
#   3  The check command does not resolve — no such command on PATH, or a path
#      that is not executable. Decided ONCE, by a preflight BEFORE the first
#      tick, deliberately: a typo'd command name would otherwise "poll" all the
#      way to the cap and report a timeout, hiding the real fault behind a wait.
#      The check's OWN exit statuses are never reinterpreted as a launch
#      failure — a check that exits 126 or 127 on purpose keeps polling like any
#      other non-zero result.
#   4  Cap reached — the condition was never met within --timeout. Includes the
#      case where the CHECK ITSELF was still running when the cap expired: each
#      check is bounded by the time remaining, so a check that hangs is killed
#      at the cap instead of blocking the caller past it (see THE CHECK IS
#      BOUNDED TOO below).
#   5  Environment — a required helper or lib/bounded-run.sh is missing, or the
#      capture files could not be created, so nothing was polled.
#   70 --help header extraction produced no output (internal defect).
#
# THE CHECK IS BOUNDED TOO
#   --timeout would be a fiction if a single check could block indefinitely: one
#   wedged `gh` call, or a `git` on a stalled mount, would hold the caller far
#   past the cap with no output and no diagnostic — the exact shape of the
#   20-minute freeze issue #1363 was raised for. So every check runs under
#   lib/bounded-run.sh with the time REMAINING as its bound, in its own process
#   group, and is killed when that runs out. The result is exit 4 with a message
#   saying the check was still running, never a silent overrun.
#
#   The cap is therefore an upper bound on POLLING, not to the second on the
#   process. Killing a wedged check is not instantaneous: run_bounded sends
#   TERM, waits up to 2s for the child to go, sends KILL, then reaps for up to
#   3s before giving up on the status. So a run that ends by killing its check
#   returns up to ~5s after --timeout. That overshoot is bounded and only ever
#   on the kill path — a check that returns on its own is never held past the
#   cap. The alternative, reserving those 5s out of REMAINING, would silently
#   shorten every legitimate check's budget to flatter the number, so the
#   grace is documented rather than subtracted.
#
# REQUIREMENTS
#   mktemp, date, sleep, awk, cat, rm, plus lib/bounded-run.sh beside this
#   script. All are checked up front so a missing one exits 5 with a named
#   diagnostic rather than letting the shell's own 127 escape as an undocumented
#   status, or leaving the check unbounded.
#
# EXAMPLES
#   # Issue #1470 case 2, rewritten as one allowed call:
#   .claude/scripts/wait-until.sh --interval 10 --timeout 900 \
#     --expect completed -- gh run view 123 --json status --jq .status
#
#   # Plain exit-status condition:
#   .claude/scripts/wait-until.sh --interval 5 --timeout 60 -- test -f /tmp/ready
#
#   # Preferred shortcut for a CI run — no wrapper needed:
#   gh run watch 123 --exit-status

set -uo pipefail

CAPTURE=""
CAPTURE_ERR=""
cleanup() {
  if [[ -n "$CAPTURE" ]]; then rm -f "$CAPTURE" 2>/dev/null || true; fi
  if [[ -n "$CAPTURE_ERR" ]]; then rm -f "$CAPTURE_ERR" 2>/dev/null || true; fi
}
trap cleanup EXIT

# Terminates on the first BLANK line, not on a named heading: a range ends AT
# its terminator, which is how six scripts silently swallowed their own EXAMPLES
# section (issue #1475).
print_help() {
  awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; n = 1; next } { exit } END { exit(n ? 0 : 1) }' "$0" ||
    { printf '%s: --help header extraction produced no output\n' "$0" >&2; exit 70; }
}

usage_error() {
  echo "wait-until.sh: $1" >&2
  echo "Run with --help for usage." >&2
  exit 2
}

# Validates and normalizes one integer flag; sets NORMALIZED_INT to the base-10
# value. A bound that silently vanishes is the failure this whole family of
# scripts exists to prevent, so a bad value is REJECTED rather than defaulted.
#
# Normalizing at PARSE time, rather
# than validating and storing the raw string, is load-bearing: `08` and `09` are
# all-digits and pass the regex, but every later `$(( ))` reads a leading zero as
# octal, where they are not valid literals. The arithmetic then errors, the
# comparison is false on every pass, and the cap silently vanishes — the exact
# failure this script exists to prevent. Pinned by the leading-zero case in the
# test suite.
NORMALIZED_INT=0
require_positive_int() { # flag, value
  [[ "$2" =~ ^[0-9]+$ ]] || usage_error "$1 requires a positive integer (got '$2')"
  # All-digits is not the same as representable. Past 2^63 bash arithmetic wraps
  # silently, so a long digit string can pass a `> 0` test as a completely
  # different — even negative — number and set a bound nobody asked for. Ten
  # digits is far beyond any sane interval or timeout and stays clear of the
  # wrap, matching how the other entry points in this repo bound their counts.
  (( ${#2} <= 10 )) || usage_error "$1 is too large to be a sane bound (got '$2'; at most 10 digits)"
  (( 10#$2 > 0 )) || usage_error "$1 must be greater than zero (got '$2')"
  NORMALIZED_INT=$((10#$2))
}

INTERVAL=10
TIMEOUT=600
EXPECT=""
HAVE_EXPECT=0
QUIET=0
CMD=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help)
      print_help
      exit 0
      ;;
    --interval)
      [[ $# -ge 2 ]] || usage_error "--interval requires a value"
      require_positive_int --interval "$2"
      INTERVAL="$NORMALIZED_INT"; shift 2 ;;
    --interval=*)
      require_positive_int --interval "${1#--interval=}"
      INTERVAL="$NORMALIZED_INT"; shift ;;
    --timeout)
      [[ $# -ge 2 ]] || usage_error "--timeout requires a value"
      require_positive_int --timeout "$2"
      TIMEOUT="$NORMALIZED_INT"; shift 2 ;;
    --timeout=*)
      require_positive_int --timeout "${1#--timeout=}"
      TIMEOUT="$NORMALIZED_INT"; shift ;;
    --expect)
      # An EMPTY --expect is legitimate (a command whose stdout is empty when
      # ready), so only a MISSING value is an error. HAVE_EXPECT, not a
      # non-empty EXPECT, is what selects the comparison mode.
      [[ $# -ge 2 ]] || usage_error "--expect requires a value"
      EXPECT="$2"; HAVE_EXPECT=1; shift 2 ;;
    --expect=*)
      EXPECT="${1#--expect=}"; HAVE_EXPECT=1; shift ;;
    --quiet)
      QUIET=1; shift ;;
    --)
      shift
      CMD=("$@")
      break ;;
    -*)
      usage_error "unknown flag: $1" ;;
    *)
      # First non-flag argument begins the command; everything after it belongs
      # to the command, dashes included.
      CMD=("$@")
      break ;;
  esac
done

[[ ${#CMD[@]} -gt 0 ]] || usage_error "no check command given"

# Resolve the check command ONCE, up front. Two things depend on this being a
# preflight rather than an in-loop inspection of the child's status:
#   1. A typo must fail immediately, not after a full --timeout of "polling" a
#      command that was never going to run — that hides the real fault behind a
#      wait and reports it as a cap timeout.
#   2. Exit statuses 126 and 127 must stay the CHECK's own. A check that exits
#      127 by design is an ordinary not-yet-met result and keeps polling; only
#      this preflight decides "cannot be launched", so the two can never be
#      confused. `command -v` also covers builtins and functions, which is why
#      it is used rather than a bare file test.
if [[ "${CMD[0]}" == */* ]]; then
  # REGULAR file, not merely executable. A directory carries the execute bit
  # (that is traverse permission) and would sail through a bare -x, then exec as
  # 126 and be polled to a cap timeout. A FIFO is worse still: the shebang read
  # below would block on it forever, before the timeout loop that is supposed to
  # bound this run has even started.
  if [[ ! -f "${CMD[0]}" || ! -x "${CMD[0]}" ]]; then
    echo "wait-until.sh: the check command is not an executable regular file: ${CMD[0]}" >&2
    exit 3
  fi
  # Executable is not the same as launchable. A script whose interpreter is
  # missing passes -x and then fails at exec time, which reaching the loop would
  # report as a cap timeout for a check that never ran — the fault (2) above
  # exists to prevent. Resolving it HERE rather than reading 126/127 in the loop
  # is what keeps that rule intact: launchability stays a preflight verdict, so
  # a check that exits 127 by design is still just not-yet-met.
  WU_SHEBANG=""
  read -r WU_SHEBANG < "${CMD[0]}" 2>/dev/null || WU_SHEBANG=""
  if [[ "$WU_SHEBANG" == '#!'* ]]; then
    WU_SHEBANG="${WU_SHEBANG#\#!}"
    WU_SHEBANG="${WU_SHEBANG#"${WU_SHEBANG%%[![:space:]]*}"}"
    WU_INTERP="${WU_SHEBANG%%[[:space:]]*}"
    # -f as well as -x, matching the check on the command itself above: a
    # DIRECTORY carries the execute bit (that is traverse permission), so a bare
    # -x would pass one through to exec, which fails 126 and polls to a cap
    # timeout — the launch failure this preflight exists to name, arriving as
    # the timeout it exists to prevent.
    if [[ -n "$WU_INTERP" && "$WU_INTERP" == /* ]] \
       && { [[ ! -f "$WU_INTERP" ]] || [[ ! -x "$WU_INTERP" ]]; }; then
      echo "wait-until.sh: the check command could not be launched — ${CMD[0]} names interpreter '$WU_INTERP', which is not an executable file" >&2
      exit 3
    fi
    # `/usr/bin/env foo` defers to env, but env can only fail the same way one
    # step later: a missing foo is still an exec failure that the loop would
    # report as a cap timeout. env resolves it on PATH, so resolve it here the
    # same way.
    #
    # env's OWN options sit between it and that name, and merely SKIPPING a
    # `-*` token takes the verdict with it: `#!/usr/bin/env -S python3 -u` hides
    # the interpreter behind -S, so a missing python3 would exec-fail on every
    # tick and arrive as a cap timeout (4) — the exact fault (3) this preflight
    # exists to name. So walk PAST the options to the first real word. Flags
    # that take a SEPARATE value consume it too, so `-u NAME` never offers NAME
    # as the command. -S is not one of them: its argument IS the command line,
    # so the word after it is the interpreter we are looking for.
    #
    # Only a bare name is checked — an absolute argument was already covered
    # above, and anything with a slash is env's own business. Anything the walk
    # cannot resolve leaves the name empty and the check is skipped: MISSING a
    # launch failure costs a cap timeout, while GUESSING one would refuse a
    # check that runs perfectly well, so this fails open on purpose.
    if [[ "$WU_INTERP" == */env ]]; then
      WU_ENV_REST="${WU_SHEBANG#"$WU_INTERP"}"
      WU_ENV_TOKENS=()
      read -r -a WU_ENV_TOKENS <<< "$WU_ENV_REST" || true
      WU_ENV_ARG=""
      WU_I=0
      while (( WU_I < ${#WU_ENV_TOKENS[@]} )); do
        case "${WU_ENV_TOKENS[WU_I]}" in
          --) WU_I=$(( WU_I + 1 )); break ;;
          # -S's argument IS the command line, so the word after it is the
          # interpreter — step over the flag only, never over its value.
          -S|--split-string) WU_I=$(( WU_I + 1 )) ;;
          # Rewrite rather than advance: the joined form carries the command
          # line in its own token. The value is strictly shorter each pass, so
          # this cannot spin.
          --split-string=*) WU_ENV_TOKENS[WU_I]="${WU_ENV_TOKENS[WU_I]#*=}" ;;
          # Options taking a SEPARATE value: the value goes with the flag, or it
          # gets offered as the interpreter and refuses a launchable check.
          -u|--unset|-C|--chdir|--argv0|-P) WU_I=$(( WU_I + 2 )) ;;
          # Value-LESS options, listed by name rather than matched by shape —
          # shape cannot tell `-i` from `--argv0`, and that is the whole bug.
          -i|-0|-v|--ignore-environment|--null|--debug|--default-signal|--list-signals)
            WU_I=$(( WU_I + 1 )) ;;
          # A joined long option carries its own value in the same token.
          --?*=*) WU_I=$(( WU_I + 1 )) ;;
          # ANY OTHER option is one this walk does not know, and there is no way
          # to tell from the token whether a value follows it. Advancing by one
          # would offer that value as the interpreter — the false exit 3 that
          # refuses a check which runs perfectly well, which is the costly
          # direction here. Enumerating every option env may ever grow is not a
          # contract this script can hold, so an unknown one ends the walk and
          # the check is skipped, in the same fail-open direction as the rest.
          -*) WU_I=${#WU_ENV_TOKENS[@]}; break ;;
          # VAR=value, an environment assignment env applies before the command.
          *=*) WU_I=$(( WU_I + 1 )) ;;
          *) break ;;
        esac
      done
      if (( WU_I < ${#WU_ENV_TOKENS[@]} )); then
        WU_ENV_ARG="${WU_ENV_TOKENS[WU_I]}"
      fi
      # `env -S` honours quoting, escapes and ${VAR} expansion; the split above
      # is plain whitespace. So a token carrying any of that syntax is one this
      # walk has NOT resolved — `-S 'my interp' arg` really names an interpreter
      # with a space in it, and reading the leading `'my` as the name would refuse
      # a check that launches perfectly well. Drop it and skip, in the same
      # fail-open direction as the rest of the walk: a missed launch failure
      # costs a cap timeout, an invented one costs a working check.
      case "$WU_ENV_ARG" in
        *[\'\"\\\$]*) WU_ENV_ARG="" ;;
      esac
      # `type -P`, not `command -v`: env execs an EXTERNAL program and nothing
      # else, while command -v also answers for shell builtins and functions.
      # `#!/usr/bin/env cd` would satisfy command -v and then fail at exec,
      # arriving as the cap timeout this preflight exists to replace. The bare
      # command below keeps command -v on purpose — that one is run by this
      # shell, where a builtin genuinely does execute.
      if [[ -n "$WU_ENV_ARG" && "$WU_ENV_ARG" != -* && "$WU_ENV_ARG" != */* ]] \
         && ! type -P "$WU_ENV_ARG" >/dev/null 2>&1; then
        echo "wait-until.sh: the check command could not be launched — ${CMD[0]} asks env for interpreter '$WU_ENV_ARG', which is not on PATH" >&2
        exit 3
      fi
    fi
  fi
elif ! command -v "${CMD[0]}" >/dev/null 2>&1; then
  echo "wait-until.sh: the check command could not be launched — not found on PATH: ${CMD[0]}" >&2
  exit 3
fi

MISSING_HELPERS=""
for helper in mktemp date sleep awk cat rm; do
  command -v "$helper" >/dev/null 2>&1 \
    || MISSING_HELPERS="${MISSING_HELPERS:+$MISSING_HELPERS }$helper"
done
if [[ -n "$MISSING_HELPERS" ]]; then
  echo "wait-until.sh: required helper(s) not found on PATH ($MISSING_HELPERS) — nothing was polled" >&2
  exit 5
fi

# Refusing here is deliberate: without the bound, a single hanging check turns
# this script's whole contract — a hard cap — into a lie. Falling through to an
# unbounded check would be worse than not running at all.
# Resolved WITHOUT dirname, and never silently relative. dirname is not in the
# required-helper list above, so a missing one left SCRIPT_DIR empty and the
# `${SCRIPT_DIR:-.}` fallback then named `./lib/bounded-run.sh` — whatever
# happens to sit under the CALLER's cwd, which is either the wrong library or a
# missing-library message blaming a path this script never meant. Parameter
# expansion needs no fork at all, and a directory that still will not resolve is
# an environment failure (5), the same answer the missing library gets below.
WU_SELF="${BASH_SOURCE[0]:-$0}"
case "$WU_SELF" in
  */*) WU_SELF_DIR="${WU_SELF%/*}" ;;
  # No slash means we were named as a bare word, so the script IS in the current
  # directory — `.` is the answer here, not a fallback for a failed lookup.
  *)   WU_SELF_DIR="." ;;
esac
SCRIPT_DIR="$(cd "$WU_SELF_DIR" 2>/dev/null && pwd)" || SCRIPT_DIR=""
if [[ -z "$SCRIPT_DIR" ]]; then
  echo "wait-until.sh: could not resolve this script's own directory (from '$WU_SELF'), so lib/bounded-run.sh could not be located and the ${TIMEOUT}s cap could not be honoured — nothing was polled" >&2
  exit 5
fi
BOUNDED_RUN_LIB="$SCRIPT_DIR/lib/bounded-run.sh"
if [[ ! -r "$BOUNDED_RUN_LIB" ]]; then
  echo "wait-until.sh: required library not found at $BOUNDED_RUN_LIB, so each check could not be bounded and the ${TIMEOUT}s cap could not be honoured — reinstall .claude/scripts/lib/ and retry" >&2
  exit 5
fi
# shellcheck source=lib/bounded-run.sh
source "$BOUNDED_RUN_LIB"

# A check may legitimately print nothing when the condition is not yet met, so
# an empty capture must never be read as "the child never really finished".
BOUNDED_REQUIRE_OUTPUT=0

# Usage telemetry — deliberately NOT the argument vector. Unlike every other
# script here, this one's arguments are an ARBITRARY command line: a caller
# waiting on `gh api -H "Authorization: token …"` would otherwise write that
# token to the log verbatim. Only this script's own flags and the check
# command's basename are recorded; --expect's VALUE is omitted for the same
# reason. Best-effort and fully guarded, matching repo-root.sh: an unset HOME, a
# missing ~/.claude, or a read-only log must never change this script's
# contract, and an unset HOME is skipped outright rather than expanded so a
# stray file is never dropped at the filesystem root.
if [[ -n "${HOME:-}" ]]; then
  printf '%s\t%s\t%s\n' \
    "$(date -u +%FT%TZ 2>/dev/null || true)" "${0##*/}" \
    "--interval $INTERVAL --timeout $TIMEOUT expect=$HAVE_EXPECT quiet=$QUIET cmd=${CMD[0]##*/}" \
    2>/dev/null >> "$HOME/.claude/script-usage.log" || true
fi

# Both capture files are REQUIRED, so a failed mktemp stops the run here. Left
# unchecked it fails OPEN in the worst possible way: CAPTURE is empty, every
# redirection in run_bounded fails, the check never actually executes, and the
# loop polls that non-event all the way to the cap and reports exit 4 — "the
# condition was never met" — for a run in which nothing was ever tested. A
# script whose whole job is to fail closed must not report a timeout it never
# measured. Exit 5 (environment) with the reason instead.
CAPTURE="$(mktemp "${TMPDIR:-/tmp}/wait-until.XXXXXX" 2>/dev/null || true)"
CAPTURE_ERR="$(mktemp "${TMPDIR:-/tmp}/wait-until-err.XXXXXX" 2>/dev/null || true)"
if [[ -z "$CAPTURE" || -z "$CAPTURE_ERR" || ! -w "$CAPTURE" || ! -w "$CAPTURE_ERR" ]]; then
  echo "wait-until.sh: could not create the capture files under ${TMPDIR:-/tmp} (mktemp failed or the result is not writable), so the check's output could not be read and nothing was polled — free space or fix TMPDIR and retry" >&2
  exit 5
fi

heartbeat() { # tick, elapsed, state
  [[ "$QUIET" -eq 1 ]] && return 0
  local ts
  ts="$(TZ='America/New_York' date +'%a %b %-d %I:%M %p ET' 2>/dev/null || true)"
  echo "${ts:+[$ts] }[WAIT] tick $1 — ${2}s/${TIMEOUT}s — $3" >&2
}

# Trimmed of surrounding whitespace so a trailing newline (every `--jq` result
# has one) never turns an equal value into a mismatch.
trim() { # value
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

START="$(date -u +%s 2>/dev/null || true)"
# Non-empty is not enough: a clock that answers with anything but digits is as
# unusable as one that answers with nothing. `$(( ))` reads a bare word as an
# unset name worth 0, so a garbage reading would quietly place START at the
# epoch and make ELAPSED enormous (instant cap) or, on an arithmetic error,
# leave it stale forever (no cap). Both are the bound silently vanishing, which
# is the failure this family of scripts exists to prevent, so require digits.
if [[ ! "$START" =~ ^[0-9]+$ ]]; then
  echo "wait-until.sh: could not read the clock (date -u +%s gave '${START}'), so the ${TIMEOUT}s cap could not be enforced — refusing to poll unbounded" >&2
  exit 2
fi

TICK=0
ELAPSED=0
LAST_RC=0
STATE="no check has completed yet"

# Reads the clock, or stops the run. An unreadable clock mid-wait cannot be
# allowed to mean "no cap": inside (( )) an empty variable is 0, so elapsed
# would never grow and the loop would run forever.
refresh_elapsed() {
  local now
  now="$(date -u +%s 2>/dev/null || true)"
  # Digits, not merely non-empty — same reasoning as the START read above.
  if [[ ! "$now" =~ ^[0-9]+$ ]]; then
    echo "wait-until.sh: could not read the clock (date -u +%s gave '${now}') mid-wait, so the ${TIMEOUT}s cap could not be enforced — stopping rather than polling unbounded" >&2
    exit 2
  fi
  local measured=$((now - START))
  # The cap is enforced against a WALL clock, which can step backwards (NTP
  # correction, a manual set, a DST-naive host). Left alone, a backward step
  # makes elapsed shrink and silently hands the loop extra time — the cap
  # quietly EXTENDING is the same class of failure as the cap quietly vanishing.
  #
  # Clamping elapsed to its high-water mark is not enough on its own: a step
  # back that never corrects would freeze elapsed there and stall the cap
  # forever. So re-anchor START by the size of the jump. Elapsed is then
  # non-decreasing AND still advancing, which is the monotonic clock this loop
  # actually wants — the time lost to the jump is forgiven once, and the wait
  # continues to completion instead of extending without limit. Measured with a
  # clock stepped back 6s mid-wait against a 12s cap: unguarded it ran 18s, this
  # version 13s (the extra second is tick granularity).
  #
  # A clock that stops or rewinds PERMANENTLY is still unbounded, here and in
  # lib/bounded-run.sh alike: elapsed time cannot be measured from a clock that
  # does not advance. That is the floor of a wall-clock design, not something
  # this guard claims to fix; what it fixes is the correction-shaped jump (NTP,
  # a manual set) that actually happens on healthy hosts.
  #
  # The guard is on THIS loop's clock only. run_bounded anchors its own start
  # and does not re-anchor, so a backward step landing while a HANGING check is
  # being bounded lets that one check run long by the size of the jump. The
  # overrun is bounded and self-correcting rather than open-ended: it happens
  # once, it cannot exceed the step, and the re-anchor below runs the moment
  # run_bounded returns, so the loop itself still ends on time. Closing it
  # properly means re-anchoring inside lib/bounded-run.sh, which is shared by
  # five callers and outside this script — tracked separately (issue #1651).
  if (( measured < ELAPSED )); then
    START=$((now - ELAPSED))
  else
    ELAPSED="$measured"
  fi
  return 0
}

cap_hit() { # reason
  echo "[WAIT] CAP HIT after ${ELAPSED}s of ${TIMEOUT}s ($TICK tick(s)) — $1" >&2
  if [[ -s "$CAPTURE_ERR" ]]; then
    echo "[WAIT] last stderr from the check:" >&2
    cat "$CAPTURE_ERR" >&2 2>/dev/null || true
  fi
  exit 4
}

while :; do
  refresh_elapsed
  REMAINING=$((TIMEOUT - ELAPSED))
  # The first check is GUARANTEED, never merely likely. `date +%s` is
  # whole-second, so START and the first reading can straddle a tick boundary
  # and put ELAPSED at 1 before anything has run: with --timeout 1 that makes
  # REMAINING 0 and caps the run at zero checks, contradicting the documented
  # "the first check always runs". Anchoring on TICK instead of on the arithmetic
  # makes the guarantee unconditional rather than a property of how fast the
  # setup happened to be. The check still gets a positive bound (see below), so
  # this cannot hand run_bounded a non-positive one.
  (( REMAINING > 0 || TICK == 0 )) || cap_hit "condition never met: $STATE"
  # run_bounded must never be handed a non-positive bound — 0 means "already
  # expired", which would kill the guaranteed first check before it produced
  # anything and turn the guarantee back into the zero-tick cap it just fixed.
  (( REMAINING > 0 )) || REMAINING=1

  TICK=$((TICK + 1))
  LAST_RC=0
  # Bounded by the time LEFT, not by the interval: a check that hangs is killed
  # at the cap rather than outliving it, so --timeout bounds the whole call and
  # not just the polling. "At the cap" means the TRIP is at the cap — TERM/KILL
  # and the reap add up to ~5s after it (see THE CHECK IS BOUNDED TOO in the
  # header). NEVER call run_bounded inside `$( )` — a subshell
  # discards BOUNDED_TIMED_OUT and turns a bounded failure back into a silent
  # one. run_bounded truncates both capture files itself.
  run_bounded "$REMAINING" "${CMD[@]}" || LAST_RC=$?

  # run_bounded kills the check and raises this when IT cannot read the clock.
  # Left unread, that arrives as an ordinary failed tick and the loop polls on to
  # exit 4 — a cap timeout reported by a run whose bound was never enforceable.
  # This script already exits 2 at both of its own clock reads; the bound's clock
  # failing is the same condition seen one level down, so it gets the same answer
  # rather than being laundered into a timeout.
  if [[ "$BOUNDED_CLOCK_UNREADABLE" -eq 1 ]]; then
    echo "wait-until.sh: lib/bounded-run.sh could not read the clock while bounding the check, so the ${TIMEOUT}s cap could not be enforced — stopping rather than polling unbounded" >&2
    exit 2
  fi

  if [[ "$BOUNDED_TIMED_OUT" -eq 1 ]]; then
    refresh_elapsed
    heartbeat "$TICK" "$ELAPSED" "check still running when the cap expired — killed"
    cap_hit "the check itself was still running at the ${TIMEOUT}s cap and was killed (it was given the remaining ${REMAINING}s)"
  fi

  MET=0
  if [[ "$HAVE_EXPECT" -eq 1 ]]; then
    ACTUAL="$(trim "$(cat "$CAPTURE" 2>/dev/null || true)")"
    if [[ "$LAST_RC" -eq 0 && "$ACTUAL" == "$EXPECT" ]]; then
      MET=1
      STATE="met: output matched --expect"
    elif [[ "$LAST_RC" -ne 0 ]]; then
      STATE="check exited $LAST_RC (want 0 and output matching --expect)"
    else
      STATE="output did not match --expect (${#ACTUAL} chars vs ${#EXPECT})"
    fi
  else
    if [[ "$LAST_RC" -eq 0 ]]; then
      MET=1
      STATE="met: check exited 0"
    else
      STATE="check exited $LAST_RC (want 0)"
    fi
  fi

  refresh_elapsed
  heartbeat "$TICK" "$ELAPSED" "$STATE"

  if [[ "$MET" -eq 1 ]]; then
    echo "[WAIT] condition met after ${ELAPSED}s ($TICK tick(s))" >&2
    cat "$CAPTURE" 2>/dev/null || true
    exit 0
  fi

  # Checked BEFORE sleeping so the wait never overruns its own cap by up to one
  # interval, and so a cap smaller than one interval still costs one check, not
  # one sleep.
  if (( ELAPSED + INTERVAL > TIMEOUT )); then
    cap_hit "condition never met: $STATE"
  fi

  sleep "$INTERVAL"
done
