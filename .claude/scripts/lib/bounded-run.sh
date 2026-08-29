#!/usr/bin/env bash
# lib/bounded-run.sh — wall-clock bound around one child process, killed at
# expiry (issue #1363).
#
# Source this file (do NOT execute it directly) from any script that must not
# block indefinitely on a git (or filesystem) call.
#
# PROBLEM SOLVED
#   On 2026-08-26 a repo with 62 stale worktree registrations pointing at
#   iCloud-evicted (`dataless`) files froze `git worktree list --porcelain` for
#   20+ minutes: no output, no diagnostic, no failure — and the whole merge path
#   (admin-merge.sh, /wrap, /merge, Phase C) hung with it. That filesystem
#   stalls PER FILE, so cheapness is no defence: a single-file read is cheap in
#   I/O terms and still unbounded in wall-clock terms. Stock macOS ships no
#   `timeout(1)`, so the bound has to be built here — background the child in
#   its own process group, poll the wall clock, kill the group on expiry.
#
#   PR #1386 bounded repo-root.sh with an inline copy of this code and
#   stale-cleanup.sh grew a second copy for its registration sweep. Issue #1404
#   bounds what the CALLERS do after resolution, which would have made four
#   copies of the job-control + process-group-kill dance; this file is the one
#   definition all of them share.
#
# CONTRACT
#   run_bounded <secs> <command> [args…]
#     Runs the command with stdout in $CAPTURE and stderr in $CAPTURE_ERR (both
#     caller-owned temp files, truncated on entry). Returns the child's REAL
#     exit status, or 124 with BOUNDED_TIMED_OUT=1 when the bound cut the call
#     short. A child that had already finished when the sampling loop tripped is
#     NOT reported as a timeout — its result is trusted over the sampling.
#     <secs> must be a positive integer; normalize_bound() produces one.
#
#     Never call this inside `$( )`. Command substitution runs the whole
#     function in a subshell, which discards BOUNDED_TIMED_OUT, the capture
#     handover below, and any `exit` a caller's timeout handler would make —
#     turning a bounded failure back into a silent one.
#
#   normalize_bound <value> <default>
#     Prints a positive integer bound. Empty, non-numeric, or zero values fall
#     back to <default> rather than disabling the bound — a bad override must
#     never silently mean "no bound", which is the exact failure these bounds
#     exist to remove. The `10#` is load-bearing: `08`/`09` are all-digits and
#     pass a `-gt 0` test, but `(( ))` reads a leading zero as octal, where they
#     are not valid literals; the arithmetic then errors, the comparison is
#     false on every pass, and the bound vanishes without a word.
#
#   kill_child <signal> <pid>
#     Signals the child, preferring its whole process group. `ps` and `tr` each
#     carry their own `2>/dev/null`: without them the group kill is skipped and
#     the builtin single-pid `kill` still stops the child, so absence degrades
#     QUIETLY rather than narrating `command not found` over a caller's one-line
#     stderr contract (issue #1435).
#
#   now_epoch
#     Seconds since the epoch, or a non-zero return when the answer is unusable.
#     Callers must not accept a blank result: inside `(( ))` an empty variable is
#     0, so `now - start` would go negative and the bound would never trip.
#
# USAGE
#   Caller-owned inputs, set before the first call:
#     CAPTURE, CAPTURE_ERR   temp files for the child's stdout/stderr (required)
#   Caller-owned outputs, read after each call:
#     BOUNDED_TIMED_OUT      1 when the bound killed the call
#     BOUNDED_CLOCK_UNREADABLE  1 when `date` failed and the call was killed
#                            rather than run unbounded — a distinct diagnosis
#                            from an elapsed-time timeout, so say which it was
#   Optional knobs:
#     BOUNDED_REQUIRE_OUTPUT=1  Only trust a completed-but-late child when it
#                            left output behind. For a caller whose ANSWER is
#                            the capture (repo-root.sh reads a path out of it),
#                            an empty capture means the answer was lost, so
#                            "it finished" must not be read as success.
#     BOUNDED_CAPTURE_TEMPLATE / BOUNDED_CAPTURE_ERR_TEMPLATE
#                            mktemp templates enabling the orphan handover: a
#                            child still alive after SIGKILL is wedged in
#                            uninterruptible I/O, and it still holds this call's
#                            stdout/stderr open. Rather than let a later call
#                            truncate files that orphan may still write to, the
#                            descriptors are handed over to it — the paths are
#                            appended to ORPHANED_CAPTURES (the caller declares
#                            the array and unlinks them at exit) and
#                            CAPTURE/CAPTURE_ERR are pointed at fresh files.
#                            Unset means no handover: a caller that exits moments
#                            later (repo-root.sh) has nothing to protect.
#
#   source "$SCRIPT_DIR/lib/bounded-run.sh"
#   BOUND="$(normalize_bound "${REPO_ROOT_TIMEOUT_SECS:-10}" 10)"
#   rc=0
#   run_bounded "$BOUND" git -C "$ROOT" symbolic-ref --short HEAD || rc=$?
#   if [[ "$BOUNDED_TIMED_OUT" -eq 1 ]]; then …caller's own die/degrade… ; fi
#
#   Deliberately NOT provided: a die-on-timeout helper. Each caller maps a
#   timeout onto its own documented exit code (repo-root.sh 3, dirty-main-guard
#   2, stale-cleanup per-item `failed:`, admin-merge refuse-to-guess), and a
#   shared `exit` would flatten four different contracts into one.

# Guard against direct execution. Running a definition-only library would
# otherwise report success while doing nothing.
if [[ "${BASH_SOURCE[0]:-}" == "${0:-}" ]]; then
  echo "bounded-run.sh: source this file, do not execute it directly" >&2
  exit 2
fi

BOUNDED_TIMED_OUT=0
BOUNDED_CLOCK_UNREADABLE=0

normalize_bound() { # value, default
  local v="$1" d="$2"
  case "$v" in ''|*[!0-9]*) v="$d" ;; esac
  v="$(( 10#$v ))"
  [ "$v" -gt 0 ] 2>/dev/null || v="$d"
  printf '%s' "$v"
}

now_epoch() {
  local t
  t="$(date -u +%s 2>/dev/null || true)"
  case "$t" in ''|*[!0-9]*) return 1 ;; esac
  printf '%s' "$t"
}

# The negative (process-group) form is used ONLY after confirming the child
# really leads its own group: a process group outlives its leader, so a recycled
# pid can name a live, unrelated group. Signalling that group would also
# "succeed", skipping the single-pid fallback and leaving our child running.
kill_child() { # signal, pid
  local sig="$1" pid="$2" pgid=""
  pgid="$(ps -o pgid= -p "$pid" 2>/dev/null | tr -d '[:space:]' 2>/dev/null)"
  if [[ -n "$pgid" && "$pgid" == "$pid" ]]; then
    kill -"$sig" -"$pid" 2>/dev/null || true
  fi
  kill -"$sig" "$pid" 2>/dev/null || true
}

run_bounded() { # bound_secs, command...
  local bound="$1"; shift
  BOUNDED_TIMED_OUT=0
  BOUNDED_CLOCK_UNREADABLE=0
  : > "$CAPTURE"
  : > "$CAPTURE_ERR"

  # Job control puts the child in its OWN process group, so the kill below
  # reaches anything it spawned (pager, credential helper, alias) instead of
  # only the direct pid — a survivor would keep the stalled fd open while we
  # reported the call as stopped. stdin is /dev/null because a job-controlled
  # background job that reads the terminal takes SIGTTIN and stops, which looks
  # exactly like the hang we are trying to detect.
  set -m 2>/dev/null || true
  "$@" >"$CAPTURE" 2>"$CAPTURE_ERR" </dev/null &
  local pid=$!
  set +m 2>/dev/null || true

  local start now rc=0 killed=0 waited=0 reaped=0
  start="$(now_epoch)" || start=""
  # The bound reads the clock every pass, never a tick count: a tick is a sleep
  # plus a fork, so counting iterations drifts past the requested bound under
  # load — unbounded drift on the one path that is supposed to be bounded.
  while kill -0 "$pid" 2>/dev/null; do
    now="$(now_epoch)" || now=""
    # An unreadable clock cannot be allowed to mean "no bound". Fail closed:
    # stop the call and say why, rather than running it unbounded.
    if [[ -z "$start" || -z "$now" ]]; then
      BOUNDED_CLOCK_UNREADABLE=1
    fi
    if [[ "$BOUNDED_CLOCK_UNREADABLE" -eq 1 ]] || (( now - start >= bound )); then
      killed=1
      kill_child TERM "$pid"
      # Polled grace so a child that dies at once does not hold the wrapper
      # past the bound it was just held to.
      for _ in 1 2; do
        kill -0 "$pid" 2>/dev/null || break
        sleep 1
      done
      kill_child KILL "$pid"
      break
    fi
    # Sub-second polling keeps the healthy path (a few milliseconds) fast; these
    # callers run on every hook. A `sleep` without fractional support fails
    # instantly and the whole-second form takes over.
    sleep 0.05 2>/dev/null || sleep 1
  done

  if [[ "$killed" -eq 1 ]]; then
    # Bounded reap. SIGKILL is QUEUED, not effective, against a child wedged in
    # uninterruptible I/O — exactly the stalled-mount case this bound exists
    # for. A plain `wait` here would block until that I/O returns, inheriting
    # the very hang the bound just prevented. So give up on the status instead;
    # init reaps the orphan.
    while (( waited < 3 )); do
      if ! kill -0 "$pid" 2>/dev/null; then
        reaped=1
        rc=0
        wait "$pid" 2>/dev/null || rc=$?
        break
      fi
      sleep 1
      waited=$(( waited + 1 ))
    done
    # A child that had already finished when the sampling loop tripped left a
    # complete answer behind: `kill -0` succeeds on a zombie and the clock is
    # whole-second, so the trip can land after the work was done. Trust the
    # result over the sampling — reporting a timeout here would throw away a
    # correct answer that is already sitting in $CAPTURE.
    if [[ "$reaped" -eq 1 && "$rc" -eq 0 ]] \
       && { [[ "${BOUNDED_REQUIRE_OUTPUT:-0}" -ne 1 ]] || [[ -s "$CAPTURE" ]]; }; then
      return 0
    fi
    # Still alive after SIGKILL means wedged in uninterruptible I/O, which no
    # signal can end — that is the kernel's call, not ours. What we can stop is
    # the contamination (see BOUNDED_CAPTURE_TEMPLATE above).
    if [[ -n "${BOUNDED_CAPTURE_TEMPLATE:-}" ]] && kill -0 "$pid" 2>/dev/null; then
      ORPHANED_CAPTURES+=("$CAPTURE" "$CAPTURE_ERR")
      CAPTURE="$(mktemp "$BOUNDED_CAPTURE_TEMPLATE")"
      CAPTURE_ERR="$(mktemp "${BOUNDED_CAPTURE_ERR_TEMPLATE:-$BOUNDED_CAPTURE_TEMPLATE}")"
    fi
    BOUNDED_TIMED_OUT=1
    return 124
  fi

  # The child finished on its own, so `wait` returns its real exit status
  # rather than a zombie plus a guess.
  wait "$pid" 2>/dev/null || rc=$?
  return "$rc"
}
