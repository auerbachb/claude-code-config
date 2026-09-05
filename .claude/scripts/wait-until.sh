#!/usr/bin/env bash
# wait-until.sh — Poll a check command until it succeeds, with a hard cap.
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
#   5  Environment — a required helper or lib/bounded-run.sh is missing, so
#      nothing was polled.
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
  if [[ ! -x "${CMD[0]}" ]]; then
    echo "wait-until.sh: the check command is not an executable file: ${CMD[0]}" >&2
    exit 3
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
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)" || SCRIPT_DIR=""
BOUNDED_RUN_LIB="${SCRIPT_DIR:-.}/lib/bounded-run.sh"
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

CAPTURE="$(mktemp "${TMPDIR:-/tmp}/wait-until.XXXXXX")"
CAPTURE_ERR="$(mktemp "${TMPDIR:-/tmp}/wait-until-err.XXXXXX")"

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
if [[ -z "$START" ]]; then
  # An unreadable clock cannot be allowed to mean "no cap" — inside (( )) an
  # empty variable is 0, so elapsed would never grow and the loop would run
  # forever. Fail closed and say so.
  echo "wait-until.sh: could not read the clock (date -u +%s), so the ${TIMEOUT}s cap could not be enforced — refusing to poll unbounded" >&2
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
  if [[ -z "$now" ]]; then
    echo "wait-until.sh: could not read the clock (date -u +%s) mid-wait, so the ${TIMEOUT}s cap could not be enforced — stopping rather than polling unbounded" >&2
    exit 2
  fi
  ELAPSED=$((now - START))
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
  # Only reachable after a tick has run, because TIMEOUT is a positive integer
  # and ELAPSED is 0 on entry.
  (( REMAINING > 0 )) || cap_hit "condition never met: $STATE"

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
      STATE="met: output == '$EXPECT'"
    elif [[ "$LAST_RC" -ne 0 ]]; then
      STATE="check exited $LAST_RC (want 0 and output '$EXPECT')"
    else
      STATE="output '$ACTUAL' != '$EXPECT'"
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
