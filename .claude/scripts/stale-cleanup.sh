#!/usr/bin/env bash
# stale-cleanup.sh — Detect and optionally remove stale worktrees and branches.
#
# PURPOSE
#   Replaces the self-cleanup that /wrap used to do (worktree removal + branch
#   deletion in the running session). Runs out-of-band so the active session
#   never deletes itself. Two skills consume this script as the single source of
#   truth for stale worktree/branch detection and safety — /pm-update (Step 8)
#   and /pm-clean (workspace sweep) — so their results can never diverge (issue
#   #618). Detects four classes of stale state on the target repo's root:
#     1. Local worktrees whose HEAD commit is older than STALE_DAYS.
#     2. Local branches whose tip commit is older than STALE_DAYS.
#     3. Remote branches (refs/remotes/origin/*) whose tip commit is older
#        than STALE_DAYS.
#     4. Orphaned worktree *registrations* — `<git-common-dir>/worktrees/<id>`
#        entries with no live worktree behind them (issue #1402).
#
#   TARGET REPO RESOLUTION (invoking-repo scope — issues #687/#697): the swept
#   repo is resolved from the CALLER's current directory (or an explicit
#   --root <path>), never from this script's own location. The script is
#   routinely invoked from other projects via the ~/.claude/skills-worktree
#   checkout; resolving from its own path would sweep claude-code-config's
#   workspace no matter where the caller was standing. The open-PR safety
#   check runs inside the resolved root for the same reason — the PR set must
#   describe the repo actually being swept.
#
#   Default mode is --check (dry-run). --apply performs the deletions only
#   for items that pass every safety check below. Nothing is ever deleted in
#   --check mode.
#
# SAFETY CHECKS (always applied; cannot be bypassed)
#   Worktrees:
#     - Skip the main worktree (root repo).
#     - Skip the worktree the caller is currently inside (resolved from $PWD).
#     - Skip if the worktree has uncommitted tracked changes (git diff).
#     - Skip if the worktree's branch has an open PR.
#   Local branches:
#     - Skip protected names: main, master, develop.
#     - Skip the current branch in any worktree (git refuses anyway).
#     - Skip branches checked out in any worktree.
#     - Skip branches with an open PR.
#   Remote branches:
#     - Skip protected names: main, master, develop, HEAD.
#     - Skip branches with an open PR.
#   Worktree registrations:
#     - Skip any registration whose worktree directory still exists AND whose
#       metadata reads cleanly — a live entry is never touched.
#     - Skip the registration belonging to the caller's own worktree.
#     - Skip `locked` registrations unless --include-locked is passed, and even
#       then only when the worktree directory is gone or its metadata is
#       unreadable (a lock on a live worktree is always honoured).
#
# ORPHANED WORKTREE REGISTRATIONS (issue #1402)
#   Every linked worktree has a registration directory at
#   `<git-common-dir>/worktrees/<id>` holding `gitdir`, `HEAD`, `index`, and
#   optionally `locked`. Removing a worktree directory without going through
#   `git worktree remove` leaves that registration behind, and every later
#   `git worktree list` pays to read it. Enough of them and git stalls — the
#   2026-08-26 incident that motivated issue #1363 / PR #1386, where 62 stale
#   registrations pointed at iCloud-evicted (`dataless`) files whose reads
#   never returned. PR #1386 bounded `repo-root.sh` so the stall could not
#   freeze the merge path; this script removes the debris that caused it.
#
#   Classification (staleness-independent — STALE_DAYS does NOT apply here;
#   a missing worktree directory is a definitive signal, not an age heuristic,
#   and this matches `git worktree prune`'s own semantics):
#     live       — `gitdir` read cleanly and the worktree directory exists.
#                  Never reported, never touched.
#     orphaned   — `gitdir` read cleanly and the worktree directory is gone.
#     unreadable — `gitdir` (or the existence probe on its target) did not
#                  finish inside the read bound. Reported as
#                  "unreadable — prunable with warning": we cannot prove the
#                  worktree is gone, only that git cannot read the entry
#                  either. Recovery if such a worktree does still exist is
#                  `git worktree repair <path>`.
#
#   Removal paths under --apply (which path handles which case):
#     `git worktree prune`  — the plain orphaned, unlocked case. Preferred:
#           git applies its own safety rules and the call is cheap and bounded
#           once the unreadable entries are out of the way.
#     targeted removal      — unreadable entries, and locked entries cleared
#           via --include-locked. `git worktree prune` reads the same `gitdir`
#           we could not read, so it would hang on exactly these; and it
#           refuses locked entries by design. The registration directory is
#           removed directly, under path guards that allow only a single-
#           segment id directly beneath `<git-common-dir>/worktrees`, never a
#           symlink, always under the bound. Targeted removals run FIRST so
#           the subsequent `git worktree prune` cannot stall.
#
#   Locks: this repo's agent harness writes a `locked` marker into every
#   worktree it creates, so abandoned agent worktrees leave *locked* orphans
#   that `git worktree prune` will not touch. They are reported as skipped and
#   cleared only with the explicit --include-locked opt-in.
#
# BOUNDED READS (NON-NEGOTIABLE)
#   Every git call, and every *content* read, that can touch a worktree
#   registration runs under a wall-clock bound and is killed on expiry — the
#   sweep must never hang on evicted files, which is the failure it exists to
#   clean up. macOS ships no `timeout(1)`, hence the background-and-poll
#   wrapper (the same shape `repo-root.sh` uses). `git worktree list
#   --porcelain` is bounded too: on expiry the worktree and local-branch
#   passes degrade to "not classified" rather than the whole script blocking,
#   and the registration sweep — the pass that fixes the cause — still runs.
#
#   Where the bound stops, stated exactly because "every filesystem call"
#   would overclaim: the enumeration glob over <common>/worktrees and the
#   `-d`/`-f` probes on entries inside it are readdir/stat against the local
#   repo's own .git — which this script has already read, under a bound, to
#   resolve that path at all. Metadata is never `dataless`; only file
#   *content* is evicted, so those probes cannot block on the incident these
#   bounds exist for, and forking twice per probe per entry to wrap them
#   would still leave the parent's own glob unbounded. What does get bounded
#   is everything that comes *out* of a registration and is therefore
#   arbitrary: the `gitdir` and `locked` contents (read_bounded_line) and the
#   worktree path they name, which may sit on the evicted volume
#   (path_exists_bounded). Resolving the common dir is bounded for the same
#   reason — it is a git call — and degrades to registration_scan
#   "unavailable" rather than proceeding on an unverified path.
#
# CONFIGURATION
#   STALE_DAYS — env var, default 7. Tip commits older than this are stale.
#   STALE_CLEANUP_TIMEOUT_SECS — env var, default 10. Wall-clock bound on each
#       git call (worktree enumeration, prune, git-dir resolution).
#   STALE_CLEANUP_READ_TIMEOUT_SECS — env var, default 2. Wall-clock bound on
#       each per-registration metadata read, existence probe, and targeted
#       removal. Whole-second resolution, so a bound of N trips between N-1
#       and N seconds. Worst case is this bound times the registration count,
#       which is why it is much tighter than the git bound. A non-numeric or
#       zero value falls back to the default rather than disabling the bound.
#
# USAGE
#   stale-cleanup.sh --check                    # dry-run (default)
#   stale-cleanup.sh --apply                    # delete stale items
#   stale-cleanup.sh --check --json             # machine-readable output
#   stale-cleanup.sh --check --root <path>      # sweep a specific repo
#   stale-cleanup.sh --apply --include-locked   # also clear locked orphans
#   stale-cleanup.sh --help | -h
#
#   --check    Report stale items without deleting. Exit 0 if none, 1 if any.
#   --apply    Delete stale items that pass safety checks. Exit 0 when every
#              category was swept with no failures, 1 when the sweep was
#              incomplete (a bound expired, so a category was skipped — what
#              it did reach was still applied), 2 on partial failure.
#   --json     Emit a JSON object instead of human-readable text. Includes a
#              top-level "root" (the resolved main-worktree root being swept)
#              plus the stale_*/skipped_* arrays (issue #707), the
#              orphaned_registrations/skipped_registrations arrays,
#              "worktree_enumeration" ("ok", "timed_out", or "failed"), and
#              "registration_scan" ("ok", "none" when the repo has never had a
#              linked worktree, or "unavailable" when the git common dir did
#              not resolve inside the bound). Anything other than
#              worktree_enumeration "ok", and a registration_scan of
#              "unavailable", each make --check exit 1 on their own: the sweep
#              could not classify, which is a finding, not a clean bill of
#              health. "none" is a clean state and does not.
#   --include-locked
#              Also clear orphaned registrations carrying a `locked` marker.
#              Only ever applies when the worktree directory is gone or its
#              metadata is unreadable — a lock on a live worktree is always
#              honoured. Without this flag such entries are reported and left
#              alone.
#   --root     Path to (or inside) the repo to sweep. Defaults to the caller's
#              current directory, so the sweep targets the invoking repo even
#              when the script runs from another checkout (issues #687/#697).
#              Also accepts --root=<path>. An empty or flag-like value (e.g.
#              `--root --json`) is a usage error (exit 3).
#
# OUTPUT (human-readable, default)
#   Stale worktrees (older than 7 days):
#     <path> (branch <branch>, last commit <YYYY-MM-DD>)
#     ...
#   Stale local branches (older than 7 days):
#     <branch> (last commit <YYYY-MM-DD>)
#   Stale remote branches (older than 7 days):
#     origin/<branch> (last commit <YYYY-MM-DD>)
#   Orphaned worktree registrations:
#     <id> — <reason>
#   Skipped (with reason):
#     <name> — <reason>
#
#   On --apply, each successful deletion is logged as "removed: <thing>" and
#   each failure as "failed: <thing> — <reason>".
#
# EXIT STATUS
#   0  No stale items, or --apply swept every category with no failures.
#   1  Incomplete sweep — the same meaning in both modes. --check found one or
#      more stale items, including orphaned worktree registrations; or, in
#      either mode, a worktree enumeration or registration scan that did not
#      finish inside its bound. An --apply that skipped a whole category is
#      reported here rather than as success: a caller that reads 0 as "done"
#      would otherwise never re-run it.
#   2  --apply hit one or more deletion failures (other items may have
#      succeeded — see output). Takes precedence over 1. A registration the
#      re-check declined to remove because its worktree reappeared is NOT a
#      failure and does not reach this code.
#   3  Usage error.
#   4  Environment error (cannot resolve repo, gh missing, etc.).

set -euo pipefail
# Best-effort usage telemetry — must never change this script's exit contract
# (issue #1430); stderr muted BEFORE the append per issue #1406's ordering.
if [[ -n "${HOME:-}" ]]; then
  printf '%s\t%s\t%s\n' "$(date -u +%FT%TZ)" "$(basename "$0")" "${*//$'\n'/ }" 2>/dev/null >> "$HOME/.claude/script-usage.log" || true
fi

print_help() {
  awk 'NR == 1 { next } /^$/ { exit } { sub(/^# ?/, ""); print }' "$0"
}

usage_error() {
  echo "stale-cleanup.sh: $1" >&2
  echo "Run with --help for usage." >&2
  exit 3
}

MODE="check"
JSON=0
MODE_SET=0
ROOT_OVERRIDE=""
INCLUDE_LOCKED=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help)
      print_help
      exit 0
      ;;
    --check|--apply)
      if (( MODE_SET == 1 )); then
        usage_error "--check and --apply are mutually exclusive"
      fi
      MODE="${1#--}"
      MODE_SET=1
      shift
      ;;
    --json)
      JSON=1
      shift
      ;;
    --include-locked)
      INCLUDE_LOCKED=1
      shift
      ;;
    --root)
      # Flag-like values (e.g. `--root --json`) are a usage error too —
      # letting them through would fail later at repo resolution with exit 4,
      # misreporting an argument mistake as an environment error (issue #707).
      if [[ $# -lt 2 || -z "$2" || "$2" == -* ]]; then
        usage_error "--root requires a non-empty path argument"
      fi
      ROOT_OVERRIDE="$2"
      shift 2
      ;;
    --root=*)
      ROOT_OVERRIDE="${1#--root=}"
      # Same rejection as the two-arg form. A path that genuinely starts with
      # '-' can be written as --root=./-name.
      if [[ -z "$ROOT_OVERRIDE" || "$ROOT_OVERRIDE" == -* ]]; then
        usage_error "--root requires a non-empty path argument"
      fi
      shift
      ;;
    --)
      shift
      break
      ;;
    -*)
      usage_error "unknown flag: $1"
      ;;
    *)
      usage_error "unexpected positional argument: $1"
      ;;
  esac
done

STALE_DAYS="${STALE_DAYS:-7}"
if ! [[ "$STALE_DAYS" =~ ^[0-9]+$ ]] || (( STALE_DAYS < 1 )); then
  echo "error: STALE_DAYS must be a positive integer (got: $STALE_DAYS)" >&2
  exit 3
fi

NOW="$(date +%s)"
THRESHOLD=$(( NOW - STALE_DAYS * 86400 ))

# --- Bounded execution -------------------------------------------------------
# macOS ships no `timeout(1)`, so every call that can touch a worktree
# registration goes through run_bounded: start the child in its own process
# group, poll the wall clock, kill the group on expiry. Same shape as
# repo-root.sh (issue #1363) — kept local rather than sourced because
# repo-root.sh is an executable, not a library.

# A bad override must not silently disable a bound — that is the exact failure
# these bounds exist to prevent, so anything non-numeric or zero falls back to
# the default. The `10#` is load-bearing: `08`/`09` are all-digits and pass a
# `-gt 0` test, but `(( ))` reads a leading zero as octal, where they are not
# valid literals; the arithmetic then errors, the comparison is false on every
# pass, and the bound vanishes without a word.
normalize_bound() { # value, default
  local v="$1" d="$2"
  case "$v" in ''|*[!0-9]*) v="$d" ;; esac
  v="$(( 10#$v ))"
  [ "$v" -gt 0 ] 2>/dev/null || v="$d"
  printf '%s' "$v"
}
GIT_BOUND_SECS="$(normalize_bound "${STALE_CLEANUP_TIMEOUT_SECS:-10}" 10)"
READ_BOUND_SECS="$(normalize_bound "${STALE_CLEANUP_READ_TIMEOUT_SECS:-2}" 2)"

# Created after arg parsing so --help and usage errors leave nothing behind.
# All four are unconditional — no empty-variable arguments to guard against,
# and no early exit path that could leave one behind. CAPTURE/CAPTURE_ERR can
# be replaced mid-run (see run_bounded's orphan handover), so cleanup is a
# function over the current values plus any handed-over ones rather than a
# fixed command list.
CAPTURE="$(mktemp "${TMPDIR:-/tmp}/stale-cleanup.XXXXXX")"
CAPTURE_ERR="$(mktemp "${TMPDIR:-/tmp}/stale-cleanup-err.XXXXXX")"
WT_LIST_FILE="$(mktemp "${TMPDIR:-/tmp}/stale-cleanup-wt.XXXXXX")"
GH_TMPERR="$(mktemp "${TMPDIR:-/tmp}/stale-cleanup-gh-stderr.XXXXXX")"
ORPHANED_CAPTURES=()
# The trap stays a single command rather than a function so it reads as the
# fixed cleanup list it is. It expands at EXIT, so it removes whatever
# CAPTURE/CAPTURE_ERR point at by then plus any handed-over pair. The
# `[@]+` guard is the portable empty-array expansion — a bare "${arr[@]}" is
# an unbound-variable error under `set -u` on macOS's bash 3.2.
trap 'rm -f "$CAPTURE" "$CAPTURE_ERR" "$WT_LIST_FILE" "$GH_TMPERR" ${ORPHANED_CAPTURES[@]+"${ORPHANED_CAPTURES[@]}"}' EXIT

BOUNDED_TIMED_OUT=0
BOUNDED_CLOCK_UNREADABLE=0
# read_bounded_line's out-parameter. See that function for why the answer comes
# back through a global instead of stdout.
BOUNDED_LINE=""

# Seconds since the epoch, or a non-zero return when the answer is unusable.
# A blank result must never be accepted: inside `(( ))` an empty variable is 0,
# so `now - start` would go negative and the bound would never trip.
now_epoch() {
  local t
  t="$(date -u +%s 2>/dev/null || true)"
  case "$t" in ''|*[!0-9]*) return 1 ;; esac
  printf '%s' "$t"
}

# Signal the child, preferring its whole process group. The negative form is
# used ONLY after confirming the child really leads its own group: a group
# outlives its leader, so a recycled pid can name a live, unrelated group, and
# signalling that would "succeed" while our actual child kept running.
kill_child() { # signal, pid
  local sig="$1" pid="$2" pgid=""
  pgid="$(ps -o pgid= -p "$pid" 2>/dev/null | tr -d '[:space:]')"
  if [[ -n "$pgid" && "$pgid" == "$pid" ]]; then
    kill -"$sig" -"$pid" 2>/dev/null || true
  fi
  kill -"$sig" "$pid" 2>/dev/null || true
}

run_bounded() { # bound_secs, command...
  # stdout lands in $CAPTURE, stderr in $CAPTURE_ERR. Returns the child's real
  # exit status, or 124 with BOUNDED_TIMED_OUT=1 when the bound cut it short.
  local bound="$1"; shift
  BOUNDED_TIMED_OUT=0
  BOUNDED_CLOCK_UNREADABLE=0
  : > "$CAPTURE"
  : > "$CAPTURE_ERR"

  # Job control puts the child in its OWN process group so the kill reaches
  # anything it spawned. stdin is /dev/null because a job-controlled background
  # job that reads the terminal takes SIGTTIN and stops, which looks exactly
  # like the hang we are trying to detect.
  set -m 2>/dev/null || true
  "$@" >"$CAPTURE" 2>"$CAPTURE_ERR" </dev/null &
  local pid=$!
  set +m 2>/dev/null || true

  local start now rc=0 killed=0 waited=0 reaped=0
  start="$(now_epoch)" || start=""
  # The bound reads the clock every pass, never a tick count: a tick is a sleep
  # plus a fork, so counting iterations drifts past the requested bound.
  while kill -0 "$pid" 2>/dev/null; do
    now="$(now_epoch)" || now=""
    # An unreadable clock cannot be allowed to mean "no bound". Fail closed.
    if [[ -z "$start" || -z "$now" ]]; then
      BOUNDED_CLOCK_UNREADABLE=1
    fi
    if [[ "$BOUNDED_CLOCK_UNREADABLE" -eq 1 ]] || (( now - start >= bound )); then
      killed=1
      kill_child TERM "$pid"
      for _ in 1 2; do
        kill -0 "$pid" 2>/dev/null || break
        sleep 1
      done
      kill_child KILL "$pid"
      break
    fi
    sleep 0.05 2>/dev/null || sleep 1
  done

  if [[ "$killed" -eq 1 ]]; then
    # Bounded reap. SIGKILL is QUEUED, not effective, against a child wedged in
    # uninterruptible I/O — exactly the evicted-file case these bounds exist
    # for — so a plain `wait` would inherit the hang we just prevented.
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
    # result over the sampling.
    if [[ "$reaped" -eq 1 && "$rc" -eq 0 ]]; then
      return 0
    fi
    # Still alive after SIGKILL means wedged in uninterruptible I/O, which no
    # signal can end — that is the kernel's call, not ours. What we can stop is
    # the contamination: the orphan still holds this call's stdout/stderr open,
    # so if its read ever completes it writes into files a LATER call will have
    # truncated and be reading. Hand the descriptors over to the orphan and
    # continue on fresh ones; the handed-over paths are unlinked by the EXIT
    # trap like any other temp. (Deleting a registration out from under such a
    # child is separately safe — POSIX unlink on an open file is well defined,
    # and the inode survives until the last descriptor closes.)
    if kill -0 "$pid" 2>/dev/null; then
      ORPHANED_CAPTURES+=("$CAPTURE" "$CAPTURE_ERR")
      CAPTURE="$(mktemp "${TMPDIR:-/tmp}/stale-cleanup.XXXXXX")"
      CAPTURE_ERR="$(mktemp "${TMPDIR:-/tmp}/stale-cleanup-err.XXXXXX")"
    fi
    BOUNDED_TIMED_OUT=1
    return 124
  fi

  wait "$pid" 2>/dev/null || rc=$?
  return "$rc"
}

# Read the first line of a small metadata file under the read bound. On success
# the line lands in BOUNDED_LINE and the return is 0; a non-zero return means
# the read failed or tripped the bound, and BOUNDED_LINE is left empty.
# `cat` is forked deliberately — a builtin `$(<file)` read cannot be killed.
#
# The answer comes back through a global rather than stdout ON PURPOSE, and the
# callers must never wrap this in `$(...)`. Command substitution runs the whole
# function — run_bounded included — in a subshell, and run_bounded's orphan
# handover is a mutation of the PARENT's state: it appends the wedged call's
# capture paths to ORPHANED_CAPTURES and points CAPTURE/CAPTURE_ERR at fresh
# ones. Lose that to a subshell and the parent keeps reading and truncating
# files an unkillable orphan still holds open — precisely the contamination the
# handover exists to prevent. `read_bounded_line` is the only run_bounded
# wrapper that ever returned data, so it was the only one exposed to this.
read_bounded_line() { # path
  local rc=0
  BOUNDED_LINE=""
  run_bounded "$READ_BOUND_SECS" cat "$1" || rc=$?
  if (( rc != 0 )); then return 1; fi
  # This substitution is safe where the one around run_bounded was not: the
  # handover has already happened in the parent, and $CAPTURE is our own temp
  # file, never the possibly-wedged path being probed.
  BOUNDED_LINE="$(head -n 1 "$CAPTURE")" || { BOUNDED_LINE=""; return 1; }
  return 0
}

# Is the path's absence actually established, or merely not observed? `test -e`
# reports no errno: it is false for a path that does not exist AND for one
# whose parent cannot be searched (EACCES on an unreadable directory, a stale
# or half-mounted mountpoint). Absence only counts as proven when the nearest
# ancestor that does exist is a directory we can search — walk up to it, since
# the whole parent tree being gone is an ordinary orphan, not an anomaly. The
# walk runs inside one bounded child so it stays under the same bound.
path_absence_provable() { # path
  local parent rc=0
  parent="$(dirname -- "$1")"
  run_bounded "$READ_BOUND_SECS" test -x "$parent" || rc=$?
  if [[ "$BOUNDED_TIMED_OUT" -eq 1 ]]; then return 1; fi
  # A searchable parent means the lookup really happened and really missed.
  if (( rc == 0 )); then return 0; fi
  # Otherwise the parent is either absent — in which case the child cannot
  # exist either, so absence still holds — or present but refusing search,
  # which is the case we must not mistake for "missing".
  rc=0
  run_bounded "$READ_BOUND_SECS" test -e "$parent" || rc=$?
  if [[ "$BOUNDED_TIMED_OUT" -eq 1 ]]; then return 1; fi
  if (( rc != 0 )); then return 0; fi
  return 1
}

# Bounded existence probe.
#   0 = exists
#   1 = absent, and provably so
#   2 = could not be determined inside the bound (a stalled stat is itself the
#       symptom we are cleaning up, so this stays a removal candidate)
#   3 = indeterminate — not observed, but absence could not be established.
#       Distinct from 1 on purpose: collapsing it into "missing" would classify
#       a live worktree behind an unsearchable parent as an orphan and delete
#       its registration. This probe gates deletion, so it fails closed.
path_exists_bounded() { # path
  local rc=0
  run_bounded "$READ_BOUND_SECS" test -e "$1" || rc=$?
  if [[ "$BOUNDED_TIMED_OUT" -eq 1 ]]; then return 2; fi
  if (( rc == 0 )); then return 0; fi
  rc=0
  path_absence_provable "$1" || rc=$?
  if [[ "$BOUNDED_TIMED_OUT" -eq 1 ]] || (( rc != 0 )); then return 3; fi
  return 1
}

# SCRIPT_DIR is used ONLY to locate the repo-root.sh helper next to this
# script — never to pick the repo to sweep (see TARGET REPO RESOLUTION above).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT_SH="$SCRIPT_DIR/repo-root.sh"
if [[ ! -x "$REPO_ROOT_SH" ]]; then
  echo "error: repo-root.sh not found or not executable at $REPO_ROOT_SH" >&2
  exit 4
fi

# Resolve the repo to sweep from the caller's context — cwd by default, or an
# explicit --root override. Passing "$SCRIPT_DIR" here was the issue-#697 bug:
# invoked via ~/.claude/skills-worktree from another project, it swept
# claude-code-config's workspace instead of the invoking repo's.
#
# repo-root.sh's own diagnostic rides along on failure: since issue #1363 it can
# also exit 3 because a git call was killed at its wall-clock bound, and the
# "run from inside the repo" advice below would be wrong for that case.
ROOT=""
ROOT_RC=0
ROOT_ERR_FILE="$(mktemp)"
if [[ -n "$ROOT_OVERRIDE" ]]; then
  ROOT="$("$REPO_ROOT_SH" "$ROOT_OVERRIDE" 2>"$ROOT_ERR_FILE")" || ROOT_RC=$?
else
  ROOT="$("$REPO_ROOT_SH" 2>"$ROOT_ERR_FILE")" || ROOT_RC=$?
fi
ROOT_ERR="$(head -n 1 "$ROOT_ERR_FILE" 2>/dev/null || true)"
rm -f "$ROOT_ERR_FILE"
if [[ "$ROOT_RC" -ne 0 ]]; then
  if [[ -n "$ROOT_OVERRIDE" ]]; then
    echo "error: could not resolve a git repo from --root: $ROOT_OVERRIDE (repo-root.sh exit $ROOT_RC)${ROOT_ERR:+ — $ROOT_ERR}" >&2
  else
    echo "error: could not resolve a git repo from the current directory — run from inside the repo to sweep, or pass --root <path> (repo-root.sh exit $ROOT_RC)${ROOT_ERR:+ — $ROOT_ERR}" >&2
  fi
  exit 4
fi
if [[ -z "$ROOT" || ! -d "$ROOT" ]]; then
  echo "error: resolved root repo is empty or missing" >&2
  exit 4
fi

GIT=(git -C "$ROOT")

if ! command -v gh >/dev/null 2>&1; then
  echo "error: gh CLI not found — open-PR safety check requires it" >&2
  exit 4
fi
if ! command -v jq >/dev/null 2>&1; then
  echo "error: jq not found — required for parsing gh JSON output and emit_json" >&2
  exit 4
fi

# skill-telemetry is the data-only usage-snapshot branch (issue #572). It is
# updated at most weekly and must survive long gaps — a laptop that dies after
# weeks offline is exactly the window the snapshot exists for — so it must
# never age into the remote-stale prune set. The default name stays protected
# even when SKILL_TELEMETRY_BRANCH points snapshots at an override branch;
# the override (when set) is protected additionally.
PROTECTED_BRANCHES=("main" "master" "develop" "skill-telemetry")
if [[ -n "${SKILL_TELEMETRY_BRANCH:-}" ]]; then
  PROTECTED_BRANCHES+=("$SKILL_TELEMETRY_BRANCH")
fi
is_protected() {
  local b="$1"
  for p in "${PROTECTED_BRANCHES[@]}"; do
    [[ "$b" == "$p" ]] && return 0
  done
  return 1
}

# Cache open-PR head refs once. `gh pr list --json headRefName` caps at 1000
# per call (gh's hard limit), so we paginate via `--search "is:open"` with
# created-time pagination by walking pages until we get a short page back.
# For typical repos (dozens to low-hundreds of open PRs) this is one round
# trip; for a repo with thousands of open PRs it stays correct without
# silently dropping entries.
OPEN_PR_BRANCHES=""
# GH_TMPERR is created with the other capture files above and removed by the
# shared EXIT trap installed there.

gh_pr_page() {
  # gh pr list with --json forces non-interactive mode; --limit 1000 is the
  # max gh accepts per call. We use the search API via --search to enable
  # cursor-style pagination through `created:<timestamp` filters.
  # Stderr is captured (not silenced) so fetch_open_prs can distinguish
  # "no PRs" from "gh failed" — silently swallowing errors here would
  # let the open-PR safety check return false for every branch and
  # delete branches that actually have open PRs.
  local cursor="$1"
  local query="state:open"
  if [[ -n "$cursor" ]]; then
    query="$query created:<$cursor"
  fi
  # Run gh from the resolved root: gh derives the repo from its cwd, and the
  # PR set must describe the repo being swept — not the caller's cwd repo,
  # which differs under --root (and differed under the pre-#697 scope bug,
  # silently voiding the open-PR safety check).
  ( cd "$ROOT" && gh pr list --search "$query" --limit 1000 --json headRefName,createdAt ) 2>"$GH_TMPERR"
}
fetch_open_prs() {
  local cursor=""
  local prev_cursor=""
  local accumulated=""
  while :; do
    local page
    if ! page="$(gh_pr_page "$cursor")"; then
      echo "error: gh pr list failed — refusing to run with an unverified open-PR set" >&2
      sed 's/^/  gh: /' "$GH_TMPERR" >&2 || true
      exit 4
    fi
    [[ -z "$page" ]] && break
    local count
    if ! count="$(printf '%s' "$page" | jq 'length')"; then
      echo "error: gh pr list returned non-JSON output — refusing to proceed" >&2
      exit 4
    fi
    (( count == 0 )) && break
    local refs
    refs="$(printf '%s' "$page" | jq -r '.[].headRefName')"
    if [[ -n "$refs" ]]; then
      if [[ -z "$accumulated" ]]; then
        accumulated="$refs"
      else
        accumulated="$accumulated"$'\n'"$refs"
      fi
    fi
    # Page < 1000 entries means no more results.
    (( count < 1000 )) && break
    # Advance cursor to the oldest createdAt we just saw.
    prev_cursor="$cursor"
    cursor="$(printf '%s' "$page" | jq -r '[.[].createdAt] | min')"
    [[ -z "$cursor" || "$cursor" == "null" ]] && break
    # Guard against pathological case where 1000+ PRs share the same
    # createdAt timestamp — without this check we'd refetch the same page
    # forever. In practice 1000 collisions is impossible (timestamps have
    # second resolution and PR creation is rate-limited), but the bound
    # makes the loop demonstrably terminating.
    if [[ "$cursor" == "$prev_cursor" ]]; then
      break
    fi
  done
  printf '%s' "$accumulated"
}
OPEN_PR_BRANCHES="$(fetch_open_prs)"
has_open_pr() {
  local b="$1"
  [[ -z "$OPEN_PR_BRANCHES" ]] && return 1
  printf '%s\n' "$OPEN_PR_BRANCHES" | grep -Fxq "$b"
}

# Resolve "where am I right now?" so we never delete the caller's own worktree
# even if its HEAD commit happens to be older than STALE_DAYS (e.g., long-lived
# branch the user is actively working on).
CALLER_PWD="$(pwd -P 2>/dev/null || pwd)"
caller_in_worktree() {
  local wt="$1"
  # Resolve symlinks in both paths so we compare canonicalized forms.
  local wt_real
  wt_real="$(cd "$wt" 2>/dev/null && pwd -P || echo "$wt")"
  [[ "$CALLER_PWD" == "$wt_real" || "$CALLER_PWD" == "$wt_real"/* ]]
}

# Compatibility note: macOS ships bash 3.2, which has no associative arrays.
# Worktree records are stored as one delimited line per worktree in WORKTREES,
# and CHECKED_OUT_BRANCHES is a newline-joined string of branch names. We look
# up by linear scan / grep — fine for the dozens-of-worktrees scale we expect.
#
# Records use the ASCII unit separator (US, 0x1f) as the field delimiter
# instead of `|` — git refnames and filesystem paths can both contain `|`
# but never US, so parsing stays unambiguous regardless of input shape.
US=$'\x1f'
WORKTREES=()           # each entry: "is_main<US>path<US>branch<US>head_ts"
CHECKED_OUT_BRANCHES="" # newline-separated list of branches checked out anywhere

# `git worktree list --porcelain` emits records separated by blank lines:
#   worktree <path>
#   HEAD <sha>
#   branch refs/heads/<name>      (or `detached`)
parse_worktrees() {
  local cur_path="" cur_branch="" cur_head=""
  # `first` is intentionally accessible to the nested flush() below via bash's
  # dynamic scoping — flush() flips it to 0 after recording the first record
  # so subsequent records are tagged as non-main worktrees. Don't promote
  # `first` to global without also updating flush().
  local first=1
  flush() {
    if [[ -n "$cur_path" ]]; then
      local is_main=0
      if (( first == 1 )); then is_main=1; first=0; fi
      WORKTREES+=("${is_main}${US}${cur_path}${US}${cur_branch}${US}${cur_head}")
      if [[ -n "$cur_branch" ]]; then
        if [[ -z "$CHECKED_OUT_BRANCHES" ]]; then
          CHECKED_OUT_BRANCHES="$cur_branch"
        else
          CHECKED_OUT_BRANCHES="$CHECKED_OUT_BRANCHES"$'\n'"$cur_branch"
        fi
      fi
    fi
    cur_path=""; cur_branch=""; cur_head=""
  }
  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ -z "$line" ]]; then
      flush
      continue
    fi
    case "$line" in
      "worktree "*) cur_path="${line#worktree }" ;;
      "HEAD "*)
        local sha="${line#HEAD }"
        # Empty fallback (NOT 0) — 0 would compare as "ancient" against
        # THRESHOLD and force the worktree to be classified stale even
        # though we couldn't read its HEAD. Classification skips entries
        # with empty/non-numeric ts and logs the worktree.
        cur_head="$("${GIT[@]}" log -1 --format=%ct "$sha" 2>/dev/null || echo "")"
        ;;
      "branch refs/heads/"*) cur_branch="${line#branch refs/heads/}" ;;
      "detached") cur_branch="" ;;
    esac
  done < "$WT_LIST_FILE"
  flush
}

# Enumeration is bounded: this is the exact call that froze on the 2026-08-26
# incident's evicted registrations. On expiry we degrade instead of blocking —
# the registration sweep below is the pass that actually clears the cause, and
# it must still run.
WORKTREE_ENUM_STATE="ok"
enumerate_worktrees() {
  local rc=0
  run_bounded "$GIT_BOUND_SECS" "${GIT[@]}" worktree list --porcelain || rc=$?
  if [[ "$BOUNDED_TIMED_OUT" -eq 1 ]]; then
    if [[ "$BOUNDED_CLOCK_UNREADABLE" -eq 1 ]]; then
      echo "warning: could not read the clock, so the ${GIT_BOUND_SECS}s bound on 'git worktree list --porcelain' could not be enforced — killed the call rather than running it unbounded" >&2
    else
      echo "warning: 'git worktree list --porcelain' exceeded ${GIT_BOUND_SECS}s and was killed — worktrees and local branches are NOT classified in this run (raise STALE_CLEANUP_TIMEOUT_SECS if the repo is genuinely this slow)" >&2
    fi
    WORKTREE_ENUM_STATE="timed_out"
    return 1
  fi
  if (( rc != 0 )); then
    echo "warning: 'git worktree list --porcelain' failed (exit $rc) — worktrees and local branches are NOT classified in this run" >&2
    sed 's/^/  git: /' "$CAPTURE_ERR" >&2 || true
    WORKTREE_ENUM_STATE="failed"
    return 1
  fi
  cat "$CAPTURE" > "$WT_LIST_FILE"
  return 0
}

if enumerate_worktrees; then
  parse_worktrees
fi

is_branch_checked_out() {
  local b="$1"
  [[ -z "$CHECKED_OUT_BRANCHES" ]] && return 1
  printf '%s\n' "$CHECKED_OUT_BRANCHES" | grep -Fxq "$b"
}

# Classify each worktree. Stale ⇔ not main, not the caller's, no uncommitted
# tracked changes, branch has no open PR, HEAD older than threshold.
STALE_WORKTREES=()
SKIPPED_WORKTREES=()
# Empty-array guard, same pattern as the --apply loops and emit_json: under
# `set -u`, expanding "${ARR[@]}" on an empty array is an `unbound variable`
# error on bash 3.2 (macOS system bash). WORKTREES is empty exactly when
# enumerate_worktrees failed — the degraded run whose whole point is to reach
# the registration sweep that clears the cause — so an abort here would defeat
# the fallback rather than merely skipping a loop with nothing in it.
if (( ${#WORKTREES[@]} > 0 )); then
for record in "${WORKTREES[@]}"; do
  IFS="$US" read -r is_main wt branch ts <<<"$record"
  if (( is_main == 1 )); then
    SKIPPED_WORKTREES+=("${wt}${US}main worktree")
    continue
  fi
  if caller_in_worktree "$wt"; then
    SKIPPED_WORKTREES+=("${wt}${US}caller's current worktree")
    continue
  fi
  if [[ ! -d "$wt" ]]; then
    SKIPPED_WORKTREES+=("${wt}${US}directory missing — its registration is listed under orphaned registrations; clear it with --apply")
    continue
  fi
  # Tracked-only dirty detection inside the worktree.
  if ! git -C "$wt" diff --quiet 2>/dev/null \
     || ! git -C "$wt" diff --cached --quiet 2>/dev/null; then
    SKIPPED_WORKTREES+=("${wt}${US}uncommitted tracked changes")
    continue
  fi
  if [[ -n "$branch" ]] && has_open_pr "$branch"; then
    SKIPPED_WORKTREES+=("${wt}${US}open PR on branch $branch")
    continue
  fi
  # Unreadable HEAD (`git log -1 --format=%ct` failed): conservatively
  # skip rather than treating as ancient and deleting.
  if [[ -z "$ts" ]] || ! [[ "$ts" =~ ^[0-9]+$ ]]; then
    SKIPPED_WORKTREES+=("${wt}${US}HEAD unreadable — cannot determine staleness")
    continue
  fi
  if (( ts > THRESHOLD )); then
    continue  # fresh — not stale, not skipped (just normal)
  fi
  STALE_WORKTREES+=("${wt}${US}${branch}${US}${ts}")
done
fi

# Local branches: any refs/heads entry whose tip is older than threshold.
#
# Skipped wholesale when the worktree enumeration did not complete:
# CHECKED_OUT_BRANCHES would be empty, so every branch held by a worktree would
# read as unheld. `git branch -D` refuses a checked-out branch on its own, but
# that refusal costs git another worktree-registry read — the very call that
# just timed out. Classifying nothing is the honest answer; the caller sees
# `worktree_enumeration` and re-runs after the registration sweep.
STALE_LOCAL_BRANCHES=()
SKIPPED_LOCAL_BRANCHES=()
if [[ "$WORKTREE_ENUM_STATE" == "ok" ]]; then
while IFS="$US" read -r branch ts; do
  [[ -z "$branch" ]] && continue
  if is_protected "$branch"; then
    SKIPPED_LOCAL_BRANCHES+=("${branch}${US}protected")
    continue
  fi
  if is_branch_checked_out "$branch"; then
    SKIPPED_LOCAL_BRANCHES+=("${branch}${US}checked out in a worktree")
    continue
  fi
  if has_open_pr "$branch"; then
    SKIPPED_LOCAL_BRANCHES+=("${branch}${US}open PR")
    continue
  fi
  if (( ts > THRESHOLD )); then
    continue
  fi
  STALE_LOCAL_BRANCHES+=("${branch}${US}${ts}")
done < <("${GIT[@]}" for-each-ref --format="%(refname:short)${US}%(committerdate:unix)" refs/heads/)
fi

# Remote branches under origin/. Skip the symbolic origin/HEAD and protected
# names. We do NOT auto-fetch — that's a network operation the caller can run
# explicitly before invoking this script. Stale state on a stale fetch is
# still real signal.
STALE_REMOTE_BRANCHES=()
SKIPPED_REMOTE_BRANCHES=()
while IFS="$US" read -r ref ts; do
  [[ -z "$ref" ]] && continue
  # ref is e.g. "origin/feature-x"; strip leading origin/.
  case "$ref" in
    origin/HEAD) continue ;;
    origin/*) branch="${ref#origin/}" ;;
    *) continue ;;
  esac
  if is_protected "$branch"; then
    SKIPPED_REMOTE_BRANCHES+=("${ref}${US}protected")
    continue
  fi
  if has_open_pr "$branch"; then
    SKIPPED_REMOTE_BRANCHES+=("${ref}${US}open PR")
    continue
  fi
  if (( ts > THRESHOLD )); then
    continue
  fi
  STALE_REMOTE_BRANCHES+=("${ref}${US}${ts}")
done < <("${GIT[@]}" for-each-ref --format="%(refname:short)${US}%(committerdate:unix)" refs/remotes/origin/)

# --- Orphaned worktree registrations (issue #1402) ---------------------------
# Enumerated by listing <git-common-dir>/worktrees/, which is a directory read
# and never blocks. Only the per-entry metadata reads can stall, and those are
# individually bounded, so a wedged entry costs one bound instead of the run.

# The git common dir is resolved separately from ROOT: --separate-git-dir and
# bare layouts put it somewhere other than "$ROOT/.git". This is the cheapest
# call git offers and it touches no worktree entries.
GIT_COMMON_DIR=""
WORKTREE_REG_DIR=""
REG_SCAN_STATE="ok"   # ok | unavailable | none
resolve_common_dir() {
  local rc=0 out=""
  run_bounded "$GIT_BOUND_SECS" "${GIT[@]}" rev-parse --path-format=absolute --git-common-dir || rc=$?
  if [[ "$BOUNDED_TIMED_OUT" -eq 1 ]]; then return 1; fi
  if (( rc != 0 )); then
    # git < 2.31 has no --path-format; its plain form may answer relative to
    # the directory the call ran in, which is "$ROOT" here.
    rc=0
    run_bounded "$GIT_BOUND_SECS" "${GIT[@]}" rev-parse --git-common-dir || rc=$?
    if [[ "$BOUNDED_TIMED_OUT" -eq 1 || "$rc" -ne 0 ]]; then return 1; fi
  fi
  out="$(head -n 1 "$CAPTURE")"
  [[ -n "$out" ]] || return 1
  case "$out" in
    /*) ;;
    *) out="$ROOT/$out" ;;
  esac
  GIT_COMMON_DIR="$out"
  return 0
}

# The caller's own registration is never a removal candidate, mirroring the
# "caller's current worktree" skip the worktree pass already applies. In a
# linked worktree `rev-parse --git-dir` answers <common>/worktrees/<id>; in the
# main worktree it answers the common dir itself and matches no id.
CALLER_REG_ID=""
resolve_caller_reg_id() {
  local rc=0 out=""
  run_bounded "$GIT_BOUND_SECS" git -C "$CALLER_PWD" rev-parse --path-format=absolute --git-dir || rc=$?
  if [[ "$BOUNDED_TIMED_OUT" -eq 1 || "$rc" -ne 0 ]]; then return 1; fi
  out="$(head -n 1 "$CAPTURE")"
  # Match against THIS repo's registration directory, not any path containing
  # "/worktrees/". Under --root the caller can be standing in an unrelated
  # repo, and two repos can hold same-named entries (ids are worktree
  # basenames) — matching on the bare id would then skip a genuinely orphaned
  # entry here because of a live worktree somewhere else.
  case "$out" in
    "$WORKTREE_REG_DIR"/*) CALLER_REG_ID="${out#"$WORKTREE_REG_DIR"/}" ;;
    *) CALLER_REG_ID="" ;;
  esac
  # Only a single-segment id is meaningful; anything else is not an entry name.
  case "$CALLER_REG_ID" in */*) CALLER_REG_ID="" ;; esac
  return 0
}

# Each entry: id US reg_path US worktree_path US reason US method
#   method: prune    — `git worktree prune` can and should remove it
#           targeted — git would hang or refuse; remove the directory directly
ORPHANED_REGISTRATIONS=()
SKIPPED_REGISTRATIONS=()   # id US reason

scan_registrations() {
  if ! resolve_common_dir; then
    REG_SCAN_STATE="unavailable"
    echo "warning: could not resolve the git common dir within ${GIT_BOUND_SECS}s — worktree registrations were not scanned" >&2
    return
  fi
  WORKTREE_REG_DIR="$GIT_COMMON_DIR/worktrees"
  if [[ ! -d "$WORKTREE_REG_DIR" ]]; then
    REG_SCAN_STATE="none"   # no linked worktree has ever been created here
    return
  fi
  resolve_caller_reg_id || true

  local reg id locked_marker=0 lock_reason="" gitdir_line="" wt="" reason="" method=""
  for reg in "$WORKTREE_REG_DIR"/*; do
    [[ -d "$reg" ]] || continue
    id="${reg##*/}"
    if [[ -n "$CALLER_REG_ID" && "$id" == "$CALLER_REG_ID" ]]; then
      SKIPPED_REGISTRATIONS+=("${id}${US}caller's own worktree registration")
      continue
    fi

    # Presence of `locked` is pure metadata — no content read, so it cannot
    # stall. The reason text is a bounded read and may legitimately be empty.
    locked_marker=0
    lock_reason=""
    if [[ -f "$reg/locked" ]]; then
      locked_marker=1
      # Called as a statement, never inside `$(...)` — see read_bounded_line.
      read_bounded_line "$reg/locked" 2>/dev/null || true
      lock_reason="$BOUNDED_LINE"
    fi

    reason=""
    method=""
    gitdir_line=""
    if read_bounded_line "$reg/gitdir"; then gitdir_line="$BOUNDED_LINE"; fi
    if [[ -z "$gitdir_line" ]]; then
      # We cannot prove the worktree is gone — only that git cannot read this
      # entry either, which is precisely what stalls `git worktree list`.
      reason="unreadable — prunable with warning (metadata did not read within ${READ_BOUND_SECS}s)"
      method="targeted"
      wt=""
    else
      # `gitdir` holds the path of the worktree's own .git file.
      wt="${gitdir_line%/.git}"
      local probe_rc=0
      path_exists_bounded "$wt" || probe_rc=$?
      if (( probe_rc == 0 )); then
        continue   # live entry — never reported, never touched
      elif (( probe_rc == 2 )); then
        reason="unreadable — prunable with warning (existence probe on $wt did not finish within ${READ_BOUND_SECS}s)"
        method="targeted"
      elif (( probe_rc == 3 )); then
        # Not observed, but absence was not established — the parent could not
        # be searched. A live worktree behind an unreadable directory looks
        # exactly like a missing one here, so this is the one probe outcome
        # that must not become a removal candidate.
        SKIPPED_REGISTRATIONS+=("${id}${US}worktree path $wt could not be inspected (its nearest existing parent is not searchable) — absence not established, leaving the registration alone")
        continue
      else
        reason="worktree directory missing ($wt)"
        method="prune"
      fi
    fi

    if (( locked_marker == 1 )); then
      # A lock on an entry whose worktree is gone protects nothing real, but
      # clearing it is still an explicit opt-in: `locked` is the operator's own
      # "do not prune" marker, and `git worktree prune` refuses it by design.
      if (( INCLUDE_LOCKED == 0 )); then
        SKIPPED_REGISTRATIONS+=("${id}${US}locked${lock_reason:+ ($lock_reason)} — pass --include-locked to clear it")
        continue
      fi
      reason="$reason; locked${lock_reason:+ ($lock_reason)}, cleared via --include-locked"
      method="targeted"   # git worktree prune refuses locked entries
    fi

    ORPHANED_REGISTRATIONS+=("${id}${US}${reg}${US}${wt}${US}${reason}${US}${method}")
  done
}

scan_registrations

ts_to_date() {
  # Portable across BSD/GNU date: read a unix ts on stdin, emit YYYY-MM-DD.
  local ts="$1"
  if date -r "$ts" +%Y-%m-%d 2>/dev/null; then return; fi
  date -d "@$ts" +%Y-%m-%d 2>/dev/null || echo "?"
}

emit_text() {
  echo "Stale threshold: ${STALE_DAYS} days (commits before $(ts_to_date "$THRESHOLD"))"
  echo
  if (( ${#STALE_WORKTREES[@]} == 0 )); then
    echo "Stale worktrees: none"
  else
    echo "Stale worktrees:"
    for entry in "${STALE_WORKTREES[@]}"; do
      IFS="$US" read -r p b t <<<"$entry"
      printf '  %s (branch %s, last commit %s)\n' "$p" "${b:-detached}" "$(ts_to_date "$t")"
    done
  fi
  if (( ${#STALE_LOCAL_BRANCHES[@]} == 0 )); then
    echo "Stale local branches: none"
  else
    echo "Stale local branches:"
    for entry in "${STALE_LOCAL_BRANCHES[@]}"; do
      IFS="$US" read -r b t <<<"$entry"
      printf '  %s (last commit %s)\n' "$b" "$(ts_to_date "$t")"
    done
  fi
  if (( ${#STALE_REMOTE_BRANCHES[@]} == 0 )); then
    echo "Stale remote branches: none"
  else
    echo "Stale remote branches:"
    for entry in "${STALE_REMOTE_BRANCHES[@]}"; do
      IFS="$US" read -r r t <<<"$entry"
      printf '  %s (last commit %s)\n' "$r" "$(ts_to_date "$t")"
    done
  fi
  if (( ${#ORPHANED_REGISTRATIONS[@]} == 0 )); then
    echo "Orphaned worktree registrations: none"
  else
    echo "Orphaned worktree registrations:"
    for entry in "${ORPHANED_REGISTRATIONS[@]}"; do
      IFS="$US" read -r rid _ _ rreason rmethod <<<"$entry"
      printf '  %s — %s [%s]\n' "$rid" "$rreason" "$rmethod"
    done
  fi
  if [[ "$WORKTREE_ENUM_STATE" != "ok" ]]; then
    echo
    echo "WARNING: worktree enumeration $WORKTREE_ENUM_STATE — worktrees and local branches were NOT classified in this run."
    echo "         Clear the registrations above with --apply, then re-run."
  fi
  if [[ "$REG_SCAN_STATE" == "unavailable" ]]; then
    echo
    echo "WARNING: worktree registrations were not scanned (git common dir unresolved within ${GIT_BOUND_SECS}s)."
  fi
  local skipped_total=$(( ${#SKIPPED_WORKTREES[@]} + ${#SKIPPED_LOCAL_BRANCHES[@]} + ${#SKIPPED_REMOTE_BRANCHES[@]} + ${#SKIPPED_REGISTRATIONS[@]} ))
  if (( skipped_total > 0 )); then
    echo
    echo "Skipped (safety):"
    # Per-array guards: under bash 3.2 + set -u, expanding "${ARR[@]}" on
    # an empty array crashes — even when at least one of the three has
    # items. Same pattern used by --apply and emit_json.
    if (( ${#SKIPPED_WORKTREES[@]} > 0 )); then
      for entry in "${SKIPPED_WORKTREES[@]}"; do
        IFS="$US" read -r p reason <<<"$entry"
        printf '  worktree %s — %s\n' "$p" "$reason"
      done
    fi
    if (( ${#SKIPPED_LOCAL_BRANCHES[@]} > 0 )); then
      for entry in "${SKIPPED_LOCAL_BRANCHES[@]}"; do
        IFS="$US" read -r b reason <<<"$entry"
        printf '  branch %s — %s\n' "$b" "$reason"
      done
    fi
    if (( ${#SKIPPED_REMOTE_BRANCHES[@]} > 0 )); then
      for entry in "${SKIPPED_REMOTE_BRANCHES[@]}"; do
        IFS="$US" read -r r reason <<<"$entry"
        printf '  remote %s — %s\n' "$r" "$reason"
      done
    fi
    if (( ${#SKIPPED_REGISTRATIONS[@]} > 0 )); then
      for entry in "${SKIPPED_REGISTRATIONS[@]}"; do
        IFS="$US" read -r rid reason <<<"$entry"
        printf '  registration %s — %s\n' "$rid" "$reason"
      done
    fi
  fi
}

emit_json() {
  local wt_json="[]" lb_json="[]" rb_json="[]"
  local sw_json="[]" sl_json="[]" sr_json="[]"
  if (( ${#STALE_WORKTREES[@]} > 0 )); then
    wt_json="$(printf '%s\n' "${STALE_WORKTREES[@]}" \
      | jq -Rn --arg D "$US" '[inputs | split($D) | {path:.[0], branch:.[1], last_commit_ts:(.[2]|tonumber)}]')"
  fi
  if (( ${#STALE_LOCAL_BRANCHES[@]} > 0 )); then
    lb_json="$(printf '%s\n' "${STALE_LOCAL_BRANCHES[@]}" \
      | jq -Rn --arg D "$US" '[inputs | split($D) | {branch:.[0], last_commit_ts:(.[1]|tonumber)}]')"
  fi
  if (( ${#STALE_REMOTE_BRANCHES[@]} > 0 )); then
    rb_json="$(printf '%s\n' "${STALE_REMOTE_BRANCHES[@]}" \
      | jq -Rn --arg D "$US" '[inputs | split($D) | {ref:.[0], last_commit_ts:(.[1]|tonumber)}]')"
  fi
  if (( ${#SKIPPED_WORKTREES[@]} > 0 )); then
    sw_json="$(printf '%s\n' "${SKIPPED_WORKTREES[@]}" \
      | jq -Rn --arg D "$US" '[inputs | split($D) | {path:.[0], reason:.[1]}]')"
  fi
  if (( ${#SKIPPED_LOCAL_BRANCHES[@]} > 0 )); then
    sl_json="$(printf '%s\n' "${SKIPPED_LOCAL_BRANCHES[@]}" \
      | jq -Rn --arg D "$US" '[inputs | split($D) | {branch:.[0], reason:.[1]}]')"
  fi
  if (( ${#SKIPPED_REMOTE_BRANCHES[@]} > 0 )); then
    sr_json="$(printf '%s\n' "${SKIPPED_REMOTE_BRANCHES[@]}" \
      | jq -Rn --arg D "$US" '[inputs | split($D) | {ref:.[0], reason:.[1]}]')"
  fi
  local or_json="[]" sg_json="[]"
  if (( ${#ORPHANED_REGISTRATIONS[@]} > 0 )); then
    or_json="$(printf '%s\n' "${ORPHANED_REGISTRATIONS[@]}" \
      | jq -Rn --arg D "$US" '[inputs | split($D)
          | {id:.[0], registration_path:.[1], worktree_path:.[2], reason:.[3], method:.[4]}]')"
  fi
  if (( ${#SKIPPED_REGISTRATIONS[@]} > 0 )); then
    sg_json="$(printf '%s\n' "${SKIPPED_REGISTRATIONS[@]}" \
      | jq -Rn --arg D "$US" '[inputs | split($D) | {id:.[0], reason:.[1]}]')"
  fi
  jq -n --argjson wt "$wt_json" --argjson lb "$lb_json" --argjson rb "$rb_json" \
        --argjson sw "$sw_json" --argjson sl "$sl_json" --argjson sr "$sr_json" \
        --argjson or "$or_json" --argjson sg "$sg_json" \
        --arg threshold_days "$STALE_DAYS" \
        --arg threshold_ts "$THRESHOLD" \
        --arg root "$ROOT" \
        --arg enum_state "$WORKTREE_ENUM_STATE" \
        --arg reg_scan "$REG_SCAN_STATE" \
        '{root:$root,
          stale_days:($threshold_days|tonumber),
          threshold_ts:($threshold_ts|tonumber),
          stale_worktrees:$wt,
          stale_local_branches:$lb,
          stale_remote_branches:$rb,
          skipped_worktrees:$sw,
          skipped_local_branches:$sl,
          skipped_remote_branches:$sr,
          orphaned_registrations:$or,
          skipped_registrations:$sg,
          worktree_enumeration:$enum_state,
          registration_scan:$reg_scan}'
}

if [[ "$MODE" == "check" ]]; then
  if (( JSON == 1 )); then emit_json; else emit_text; fi
  total=$(( ${#STALE_WORKTREES[@]} + ${#STALE_LOCAL_BRANCHES[@]} + ${#STALE_REMOTE_BRANCHES[@]} \
            + ${#ORPHANED_REGISTRATIONS[@]} ))
  if (( total > 0 )); then exit 1; fi
  # A sweep that could not classify is a finding, not a clean bill of health:
  # exiting 0 here would tell the caller "nothing stale" about a repo we never
  # managed to read.
  if [[ "$WORKTREE_ENUM_STATE" != "ok" || "$REG_SCAN_STATE" == "unavailable" ]]; then exit 1; fi
  exit 0
fi

# --apply: delete each stale item, recording outcomes.
FAILURES=0
emit_text
echo

# Registrations go first. Targeted removals clear the entries `git worktree
# prune` would stall on, so the prune that follows — and every `git worktree
# remove` in the worktree loop below — reads a registry it can actually parse.
# Does a live worktree stand behind this registration *right now*? Answers the
# question scan_registrations asked, but at removal time. Only the affirmative
# is trusted: a gitdir that reads AND names a path that exists. An unreadable
# gitdir and a still-missing worktree both answer "not live", because those are
# exactly the states that made the entry an orphan in the first place.
registration_is_live() { # registration path
  local gitdir_line="" wt="" probe_rc=0
  # Statement form, not `$(...)` — see read_bounded_line.
  read_bounded_line "$1/gitdir" || return 1
  gitdir_line="$BOUNDED_LINE"
  [[ -n "$gitdir_line" ]] || return 1
  wt="${gitdir_line%/.git}"
  path_exists_bounded "$wt" || probe_rc=$?
  # Fail closed, unlike the classification pass: this gate stands immediately
  # before an rm, so "exists" (0) and "cannot establish absence" (3) both stop
  # it. Only proven absence (1) and the stalled probe (2) — the very symptom
  # being cleaned — let the removal through.
  case "$probe_rc" in
    0|3) return 0 ;;
    *)   return 1 ;;
  esac
}

# Returns 0 removed, 1 failed, 2 skipped by the re-check (not a failure).
remove_registration() { # id, registration path
  local id="$1" target="$2" rc=0
  # Path guards: only a single-segment id directly beneath the resolved
  # <git-common-dir>/worktrees, a real directory, never a symlink. Anything
  # else is refused rather than removed.
  case "$id" in
    ''|.|..|*/*)
      echo "failed: worktree registration '$id' — refusing to remove: not a single-segment entry name"
      return 1
      ;;
  esac
  if [[ -z "$WORKTREE_REG_DIR" || "$target" != "$WORKTREE_REG_DIR/$id" ]]; then
    echo "failed: worktree registration $id — refusing to remove: $target is not directly beneath $WORKTREE_REG_DIR"
    return 1
  fi
  if [[ -L "$target" || ! -d "$target" ]]; then
    echo "failed: worktree registration $id — refusing to remove: not a plain directory"
    return 1
  fi
  # TOCTOU re-check, the same shape the remote-branch deletion below uses. The
  # scan that classified this entry ran before --apply, and callers dry-run
  # --check first and only then decide, so the gap is human-scale, not
  # instantaneous: an operator can re-materialize a quarantined checkout in
  # between — the documented recovery path in
  # .claude/reference/worktree-registration-quarantine-20260826.md. `git
  # worktree prune` re-reads the registry itself and so needs no equivalent;
  # this is the path that bypasses git, so it re-validates for itself.
  if registration_is_live "$target"; then
    echo "skipped: worktree registration $id — its worktree reappeared after the scan; not removing"
    return 2
  fi
  run_bounded "$READ_BOUND_SECS" rm -rf -- "$target" || rc=$?
  if [[ "$BOUNDED_TIMED_OUT" -eq 1 ]]; then
    echo "failed: worktree registration $id — removal exceeded ${READ_BOUND_SECS}s and was killed"
    return 1
  fi
  if (( rc != 0 )) || [[ -e "$target" ]]; then
    echo "failed: worktree registration $id — $(head -n 1 "$CAPTURE_ERR" 2>/dev/null || echo "rm exited $rc")"
    return 1
  fi
  return 0
}

if (( ${#ORPHANED_REGISTRATIONS[@]} > 0 )); then
  PRUNE_WANTED=0
  for entry in "${ORPHANED_REGISTRATIONS[@]}"; do
    IFS="$US" read -r rid rpath _ _ rmethod <<<"$entry"
    if [[ "$rmethod" == "targeted" ]]; then
      RM_RC=0
      remove_registration "$rid" "$rpath" || RM_RC=$?
      if (( RM_RC == 0 )); then
        echo "removed: worktree registration $rid (targeted — git could not read or would refuse it)"
      elif (( RM_RC != 2 )); then
        # 2 is the re-check declining to remove a resurrected entry, which is
        # the guard working — it already said so, and it is not a failure.
        FAILURES=$(( FAILURES + 1 ))
      fi
    else
      PRUNE_WANTED=1
    fi
  done

  if (( PRUNE_WANTED == 1 )); then
    PRUNE_RC=0
    run_bounded "$GIT_BOUND_SECS" "${GIT[@]}" worktree prune || PRUNE_RC=$?
    if [[ "$BOUNDED_TIMED_OUT" -eq 1 ]]; then
      echo "failed: git worktree prune — exceeded ${GIT_BOUND_SECS}s and was killed"
    elif (( PRUNE_RC != 0 )); then
      echo "failed: git worktree prune — $(head -n 1 "$CAPTURE_ERR" 2>/dev/null || echo "exit $PRUNE_RC")"
    fi
    # Report per entry from the filesystem rather than from prune's exit code:
    # prune is all-or-nothing across the registry, so its status cannot say
    # which entries it actually cleared.
    for entry in "${ORPHANED_REGISTRATIONS[@]}"; do
      IFS="$US" read -r rid rpath _ _ rmethod <<<"$entry"
      [[ "$rmethod" == "prune" ]] || continue
      if [[ -e "$rpath" ]]; then
        if registration_is_live "$rpath"; then
          # prune did its job: the worktree came back between the scan and
          # here, so git correctly refused. Same non-failure as the targeted
          # re-check above — reporting it as a deletion failure would be wrong.
          echo "skipped: worktree registration $rid — its worktree reappeared after the scan; git worktree prune left it in place"
          continue
        fi
        echo "failed: worktree registration $rid — still present after git worktree prune"
        FAILURES=$(( FAILURES + 1 ))
      else
        echo "removed: worktree registration $rid (git worktree prune)"
      fi
    done
  fi
fi

# Empty-array guard: under `set -u`, expanding "${ARR[@]}" on an empty
# array errors with `unbound variable` on bash 3.2 (macOS system bash).
# Skip the loop entirely when the category has no stale items.
if (( ${#STALE_WORKTREES[@]} > 0 )); then
for entry in "${STALE_WORKTREES[@]}"; do
  IFS="$US" read -r p b _ <<<"$entry"
  # TOCTOU re-check: between classification (Phase --check) and apply, the
  # user may have started editing the worktree or opened a PR on its
  # branch. Re-run the same safety checks used during classification and
  # skip if anything has changed — losing user work to a stale dry-run is
  # a much bigger problem than skipping a deletion.
  if [[ -d "$p" ]] && { ! git -C "$p" diff --quiet 2>/dev/null \
       || ! git -C "$p" diff --cached --quiet 2>/dev/null; }; then
    echo "skipped: worktree $p (became dirty after dry-run)"
    continue
  fi
  if [[ -n "$b" ]] && has_open_pr "$b"; then
    echo "skipped: worktree $p (open PR on branch $b appeared after dry-run)"
    continue
  fi
  if out="$("${GIT[@]}" worktree remove "$p" 2>&1)"; then
    echo "removed: worktree $p"
    # The branch this worktree was holding was NOT classified as a stale
    # local branch (parse_worktrees adds every worktree's branch to
    # CHECKED_OUT_BRANCHES, so during classification stale-worktree
    # branches were skipped as "checked out"). Now that the worktree is
    # gone, attempt to delete the branch too — gated by the same safety
    # checks the local-branch loop uses (protected names, open PR).
    # `git branch -D` is non-fatal on unknown branches, so failures here
    # don't abort the script; we surface them via the FAILURES counter
    # only when the branch actually exists and refuses deletion.
    if [[ -n "$b" ]] && ! is_protected "$b" && ! has_open_pr "$b"; then
      if "${GIT[@]}" show-ref --verify --quiet "refs/heads/$b"; then
        if branch_out="$("${GIT[@]}" branch -D "$b" 2>&1)"; then
          echo "removed: local branch $b (was on stale worktree $p)"
        else
          echo "failed: local branch $b (after worktree $p removed) — $branch_out"
          FAILURES=$(( FAILURES + 1 ))
        fi
      fi
    fi
  else
    echo "failed: worktree $p — $out"
    FAILURES=$(( FAILURES + 1 ))
  fi
done
fi

if (( ${#STALE_LOCAL_BRANCHES[@]} > 0 )); then
for entry in "${STALE_LOCAL_BRANCHES[@]}"; do
  IFS="$US" read -r b _ <<<"$entry"
  # TOCTOU re-check: same defense as worktrees — a PR opened between
  # dry-run and apply must not lose its branch.
  if has_open_pr "$b"; then
    echo "skipped: local branch $b (open PR appeared after dry-run)"
    continue
  fi
  if out="$("${GIT[@]}" branch -D "$b" 2>&1)"; then
    echo "removed: local branch $b"
  else
    echo "failed: local branch $b — $out"
    FAILURES=$(( FAILURES + 1 ))
  fi
done
fi

if (( ${#STALE_REMOTE_BRANCHES[@]} > 0 )); then
for entry in "${STALE_REMOTE_BRANCHES[@]}"; do
  IFS="$US" read -r ref _ <<<"$entry"
  branch="${ref#origin/}"
  # TOCTOU re-check for remote-branch deletion.
  if has_open_pr "$branch"; then
    echo "skipped: remote branch $branch (open PR appeared after dry-run)"
    continue
  fi
  if out="$("${GIT[@]}" push origin --delete "$branch" 2>&1)"; then
    echo "removed: remote branch $branch"
  else
    echo "failed: remote branch $branch — $out"
    FAILURES=$(( FAILURES + 1 ))
  fi
done
fi

INCOMPLETE_SWEEP=0
if [[ "$WORKTREE_ENUM_STATE" != "ok" ]]; then
  INCOMPLETE_SWEEP=1
  echo
  echo "note: worktree enumeration $WORKTREE_ENUM_STATE, so worktrees and local branches were not swept."
  echo "      Re-run --apply now that the registrations above are cleared."
fi
if [[ "$REG_SCAN_STATE" == "unavailable" ]]; then
  INCOMPLETE_SWEEP=1
  echo
  echo "note: registration scan unavailable (git common dir unresolved), so orphaned registrations were not swept."
  echo "      Re-run --apply once the repo responds inside the bound."
fi

if (( FAILURES > 0 )); then exit 2; fi
# An apply that skipped whole categories is not a clean sweep. Saying so with
# exit 1 matches --check, which already reports both of these states that way;
# exiting 0 here let a caller record a partial sweep as done and never re-run.
if (( INCOMPLETE_SWEEP == 1 )); then exit 1; fi
exit 0
