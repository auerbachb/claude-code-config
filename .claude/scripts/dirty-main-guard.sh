#!/usr/bin/env bash
# dirty-main-guard.sh — Detect and quarantine dirty state on the root repo's main.
#
# PURPOSE
#   Enforces the "never leave anything on main" rule (CLAUDE.md). All work
#   happens in worktrees on feature branches; the root repo should sit clean
#   on main between sessions. This guard detects two forms of drift on the
#   root repo's main branch:
#     1. Uncommitted tracked changes (staged or unstaged).
#     2. Local commits on main that have not been pushed to origin/main.
#
#   On --quarantine, dirty state is preserved to a timestamped recovery
#   branch (recovery/dirty-main-YYYYMMDD-HHMMSS) BEFORE main is reset to
#   origin/main. Nothing is ever deleted — recovery branches are the user's
#   audit trail for what the guard rescued.
#
#   Untracked files are never touched (they're preserved by `git reset
#   --hard`). The guard also short-circuits to exit 0 whenever the root
#   repo is on any branch other than main — feature branches are expected
#   to have dirty state.
#
#   The guarded repo is resolved from the CALLER's current directory (the
#   invoking repo's root) unless --repo names one, never from this script's
#   own location — the script is invoked from any project repo, including via
#   the ~/.claude/skills-worktree checkout (issues #687/#697).
#
#   --repo exists because the cwd default is unreachable for a worktree-
#   isolated agent: it may run neither `(cd <root> && guard)` nor `git -C
#   <root>`, so before the flag the /wrap root-main sync step could not run
#   at all from a Phase C subagent (issue #1411). A script call is an allowed
#   shape, so the flag restores the step; the guard's own internals still use
#   `git -C` freely, since isolation gates the AGENT's command shapes, not a
#   child process's. This mirrors main-sync.sh, the other half of that sync
#   step, which has taken --repo all along.
#
#   --repo is orthogonal to both modes, exactly as main-sync.sh keeps --repo
#   orthogonal to --reset. It changes only WHICH repo is resolved, never what
#   is done to it: --quarantine still writes (recovery branch + reset) to the
#   resolved ROOT repo, so a caller whose sandbox forbids that write sees the
#   attempt refused and takes its own degraded path.
#
# USAGE
#   dirty-main-guard.sh --check [--repo <path>] [--no-fetch]
#   dirty-main-guard.sh --quarantine [--repo <path>] [--no-fetch]
#   dirty-main-guard.sh --help | -h
#
#   --check        Report whether main is dirty. Exit 0 clean, 1 dirty,
#                  0 also when not on main (not applicable).
#   --quarantine   Move dirty state to a recovery branch and reset main
#                  to origin/main. Exit 0 on success (or no-op when clean),
#                  2 on failure.
#   --repo <path>  Resolve the guarded repo from <path> instead of the
#                  caller's current directory. Also accepts --repo=<path>.
#                  <path> may be anywhere inside the target repo, including
#                  a linked worktree: resolution goes through repo-root.sh,
#                  which always answers with the MAIN worktree root. So
#                  --repo <a-worktree> guards that worktree's ROOT repo, not
#                  the worktree's own checkout — identical to what cd-ing
#                  into the worktree would have guarded.
#   --no-fetch     Skip the `git fetch origin main` that normally precedes
#                  the unpushed-commit comparison. The comparison then runs
#                  against whatever remote-tracking ref is already present.
#                  Intended for recurring callers (e.g. Stop hooks) that
#                  only care about local drift; a stale origin/main cannot
#                  mask new local commits. Session-start callers should
#                  still fetch.
#
# OUTPUT (single stdout line per invocation)
#   --check:
#     clean                                           Main is clean or not on main.
#     dirty: uncommitted tracked changes              Staged or unstaged tracked files.
#     dirty: N unpushed commit(s) on main             Local main ahead of origin/main.
#     dirty: uncommitted tracked changes + N unpushed Both conditions hold.
#     error: <reason>                                 Environment / git error.
#   --quarantine:
#     no-op: main is clean                            Nothing to quarantine.
#     quarantined: <recovery-branch> (<what>)         Success; <what> names
#                                                      the preserved state.
#     error: <reason>                                 Environment / git error.
#
# EXIT STATUS
#   0  Clean, or quarantine succeeded, or no-op (not on main).
#   1  Dirty (--check only — --quarantine uses 0 for "no-op when clean").
#   2  Failure (git error, could not create recovery branch, etc.), INCLUDING a
#      post-resolution git call killed at its wall-clock bound (issue #1404) —
#      see BOUNDED GIT CALLS below.
#   3  Usage error (unknown flag, conflicting modes, missing/empty --repo
#      value, --repo path does not exist).
#   70  --help header extraction produced no output (internal defect).
#
# BOUNDED GIT CALLS (issue #1404)
#   repo-root.sh bounds the calls that RESOLVE the root; every call this script
#   then makes against that root is bounded too, by the same knob
#   (REPO_ROOT_TIMEOUT_SECS, default 10s) through lib/bounded-run.sh. On expiry
#   the child's process group is killed and the guard exits 2 with a one-line
#   diagnostic naming the command and the bound — it never falls through to an
#   unbounded retry, and it never reports "clean" for a tree it could not read.
#   The `git fetch` is the one exception: its failure is already non-fatal by
#   design, so a timeout there warns on stderr and the comparison continues
#   against the origin/main already on disk.
#
#   The Stop hook (dirty-main-warn.sh) needs no change and stays quiet: it acts
#   only on exit 1, so a wedged git makes no per-turn noise there — exactly as
#   every other exit-2 git error already behaves — while session-start and
#   /wrap callers, the ones that act on the answer, see the diagnostic.
#
# EXAMPLES
#   # Session-start gate: check then quarantine if dirty.
#   ROOT=$(.claude/scripts/repo-root.sh)
#   if ! .claude/scripts/dirty-main-guard.sh --check >/dev/null; then
#     .claude/scripts/dirty-main-guard.sh --quarantine
#   fi
#   git -C "$ROOT" pull origin main --ff-only
#
#   # From an isolated worktree, where no `cd` to the root is permitted.
#   ROOT=$(.claude/scripts/repo-root.sh)
#   .claude/scripts/dirty-main-guard.sh --check --repo "$ROOT"

set -euo pipefail
printf '%s\t%s\t%s\n' "$(date -u +%FT%TZ)" "$(basename "$0")" "${*//$'\n'/ }" 2>/dev/null >> "$HOME/.claude/script-usage.log" || true

print_help() {
  awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; n = 1; next } { exit } END { exit(n ? 0 : 1) }' "$0" ||
    { printf '%s: --help header extraction produced no output\n' "$0" >&2; exit 70; }
}

usage_error() {
  echo "dirty-main-guard.sh: $1" >&2
  echo "Run with --help for usage." >&2
  exit 3
}

MODE=""
NO_FETCH=0
REPO=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help)
      print_help
      exit 0
      ;;
    --check|--quarantine)
      [[ -z "$MODE" ]] || usage_error "--check and --quarantine are mutually exclusive"
      MODE="${1#--}"
      shift
      ;;
    --repo)
      [[ $# -ge 2 ]] || usage_error "--repo requires a value"
      [[ -n "$2" ]] || usage_error "--repo value cannot be empty"
      REPO="$2"
      shift 2
      ;;
    --repo=*)
      REPO="${1#--repo=}"
      [[ -n "$REPO" ]] || usage_error "--repo value cannot be empty"
      shift
      ;;
    --no-fetch)
      NO_FETCH=1
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

[[ -n "$MODE" ]] || usage_error "one of --check or --quarantine is required"

# Reject a bad --repo path here, as a usage error, rather than letting it reach
# repo-root.sh — a typo'd path is the caller's mistake (exit 3), not a resolution
# failure of an existing tree (exit 2). Same split, same message shape, as
# main-sync.sh. "Not a git repo" stays repo-root.sh's call and keeps exit 2.
if [[ -n "$REPO" && ! -d "$REPO" ]]; then
  usage_error "--repo path does not exist: $REPO"
fi

# Resolve the root repo from --repo when given, otherwise from the caller's cwd,
# via the canonical helper. SCRIPT_DIR is used only to locate repo-root.sh next
# to this script — the guard must target the INVOKING repo (or the named one),
# not the repo this script happens to live in: passing "$SCRIPT_DIR" to
# repo-root.sh made cross-repo sessions (invoking via ~/.claude/skills-worktree)
# check — and on dirty state quarantine — claude-code-config's main instead
# (issue #697).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT_SH="$SCRIPT_DIR/repo-root.sh"
if [[ ! -x "$REPO_ROOT_SH" ]]; then
  echo "error: repo-root.sh not found or not executable at $REPO_ROOT_SH"
  exit 2
fi

# Carry repo-root.sh's own diagnostic instead of dropping it. Since issue #1363
# it can also exit 3 because a git call was killed at its wall-clock bound, and
# "from the current directory" is the wrong thing to tell an operator whose git
# is wedged — that misdiagnosis is what made the original stall so hard to read.
#
# The command is built as an array whose first element is the script itself, so
# it is never empty — Bash 3.2 (macOS default) errors on expanding an empty
# array under `set -u`. Naming the resolution SOURCE in the failure keeps the
# diagnostic honest under --repo: "from the current directory" would send an
# operator to inspect a cwd that had nothing to do with the failure.
RESOLVE_CMD=("$REPO_ROOT_SH")
ROOT_SOURCE="the current directory"
if [[ -n "$REPO" ]]; then
  RESOLVE_CMD+=("$REPO")
  ROOT_SOURCE="--repo $REPO"
fi

ROOT=""
ROOT_RC=0
ROOT_ERR_FILE="$(mktemp)"
ROOT="$("${RESOLVE_CMD[@]}" 2>"$ROOT_ERR_FILE")" || ROOT_RC=$?
ROOT_ERR="$(head -n 1 "$ROOT_ERR_FILE" 2>/dev/null || true)"
rm -f "$ROOT_ERR_FILE"
if [[ "$ROOT_RC" -ne 0 ]]; then
  echo "error: could not resolve root repo from $ROOT_SOURCE (repo-root.sh exit $ROOT_RC)${ROOT_ERR:+ — $ROOT_ERR}"
  exit 2
fi
if [[ -z "$ROOT" || ! -d "$ROOT" ]]; then
  echo "error: resolved root repo is empty or missing"
  exit 2
fi

GIT=(git -C "$ROOT")

# --- Bounded git calls (issue #1404) -----------------------------------------
# repo-root.sh bounds the calls it makes to RESOLVE the root; everything below
# runs against that root and was unbounded until now. Cheapness is no defence:
# the #1363 incident was an iCloud-evicted (`dataless`) tree that stalls PER
# FILE, so a single-file `symbolic-ref` read is cheap in I/O terms and still
# unbounded in wall-clock terms — a stall here reproduces the same no-output,
# no-diagnostic freeze one call further down the chain.
#
# Every call goes through git_bounded, and a timeout is a hard exit 2 (this
# script's existing "git error" code) with a one-line diagnostic — never a fall
# through to an unbounded retry. The Stop hook stays advisory without any change
# to it: dirty-main-warn.sh acts only on exit 1, so a wedged git makes no noise
# per turn there, exactly as every other exit-2 git error already behaves, while
# session-start and /wrap callers — the ones that act on the answer — see the
# diagnostic and a non-zero status.
BOUNDED_RUN_LIB="$SCRIPT_DIR/lib/bounded-run.sh"
if [[ ! -r "$BOUNDED_RUN_LIB" ]]; then
  echo "error: bounded-run library not found at $BOUNDED_RUN_LIB — refusing to run git calls unbounded"
  exit 2
fi
# shellcheck source=lib/bounded-run.sh
source "$BOUNDED_RUN_LIB"

# One knob for the whole chain: the same variable repo-root.sh already reads,
# so an operator raising the bound for a genuinely slow repo raises it once.
GIT_BOUND_SECS="$(normalize_bound "${REPO_ROOT_TIMEOUT_SECS:-10}" 10)"
CAPTURE="$(mktemp "${TMPDIR:-/tmp}/dirty-main-guard.XXXXXX")"
CAPTURE_ERR="$(mktemp "${TMPDIR:-/tmp}/dirty-main-guard-err.XXXXXX")"
# Opt into the library's orphan handover. Every fatal timeout exits, but the
# SOFT one (the fetch) does not: the guard runs on past it, so a child left
# unkillable in uninterruptible I/O would still hold these descriptors open
# while the calls after it truncate and re-read the same files. Handing the pair
# over costs two temp files and removes that contamination entirely.
ORPHANED_CAPTURES=()
BOUNDED_CAPTURE_TEMPLATE="${TMPDIR:-/tmp}/dirty-main-guard.XXXXXX"
BOUNDED_CAPTURE_ERR_TEMPLATE="${TMPDIR:-/tmp}/dirty-main-guard-err.XXXXXX"
# `[@]+` is the portable empty-array expansion — a bare "${arr[@]}" is an
# unbound-variable error under `set -u` on macOS's bash 3.2.
trap 'rm -f "$CAPTURE" "$CAPTURE_ERR" ${ORPHANED_CAPTURES[@]+"${ORPHANED_CAPTURES[@]}"} 2>/dev/null || true' EXIT

timeout_message() { # what
  if [[ "$BOUNDED_CLOCK_UNREADABLE" -eq 1 ]]; then
    # Naming which of the two it was matters: reporting a clock failure as an
    # elapsed-time timeout is its own misdiagnosis.
    echo "error: could not read the clock (date -u +%s), so the ${GIT_BOUND_SECS}s bound on '$1' could not be enforced — killed the call rather than running it unbounded"
  else
    echo "error: '$1' exceeded ${GIT_BOUND_SECS}s and was killed — the repo is not answering (raise REPO_ROOT_TIMEOUT_SECS if it is genuinely this slow)"
  fi
}

timeout_die() { # what
  timeout_message "$1"
  exit 2
}

# Run one git call against $ROOT under the bound. Returns git's real exit
# status; its stdout lands in GIT_OUT and its stderr in GIT_ERR (both with
# trailing newlines stripped, exactly as the `$( )` captures they replace).
#
# NEVER call this inside `$( )`: timeout_die's `exit` would only leave the
# command substitution's subshell, and the guard would sail on past a bound it
# had already tripped.
GIT_OUT=""
GIT_ERR=""
git_bounded_soft() { # git args…
  local rc=0
  run_bounded "$GIT_BOUND_SECS" "${GIT[@]}" "$@" || rc=$?
  GIT_OUT="$(cat "$CAPTURE")" || GIT_OUT=""
  GIT_ERR="$(cat "$CAPTURE_ERR")" || GIT_ERR=""
  return "$rc"
}

# The fatal form: everything whose answer the guard actually reports. A stall
# here means the guard cannot tell clean from dirty, and "clean" would be a
# lie — so it dies with the diagnostic instead. The one caller that wants the
# soft form (the fetch) says so at its own site.
git_bounded() { # git args…
  local rc=0
  git_bounded_soft "$@" || rc=$?
  if [[ "$BOUNDED_TIMED_OUT" -eq 1 ]]; then
    timeout_die "git $*"
  fi
  return "$rc"
}

# Between the checkout onto the recovery branch and the checkout back, the root
# repo is NOT on main, and a bare `exit 2` would leave it there. That is not
# just an untidy exit: the branch short-circuit below reads any non-main branch
# as "nothing to guard", so the next `--check` prints `clean` for a repo whose
# main is still dirty and `--quarantine` no-ops. The guard would stop guarding,
# silently, and the Stop hook — which surfaces only exit 1 — would never say so.
#
# So every bounded call made while off main dies through this instead: it always
# attempts the return trip first, and always names the branch the repo was left
# on when that trip does not land. QUARANTINE_BRANCH is set at the moment the
# window opens; empty means the window was never entered.
QUARANTINE_BRANCH=""
quarantine_die() { # first_line
  local back_rc=0
  git_bounded_soft checkout --quiet main || back_rc=$?
  echo "$1"
  if [[ "$BOUNDED_TIMED_OUT" -eq 1 || "$back_rc" -ne 0 ]]; then
    echo "error: the root repo was left on ${QUARANTINE_BRANCH:-the recovery branch} — return it to main by hand, or the guard will report a dirty main as clean"
  else
    echo "note: the root repo was returned to main; the quarantined work is on ${QUARANTINE_BRANCH:-the recovery branch}"
  fi
  exit 2
}

# The fatal form for that window. The message is composed BEFORE the return trip
# because `git_bounded_soft` resets BOUNDED_TIMED_OUT / BOUNDED_CLOCK_UNREADABLE
# — read afterwards, every timeout would describe the checkout instead of the
# call that actually tripped.
git_bounded_offmain() { # git args…
  local rc=0
  git_bounded_soft "$@" || rc=$?
  if [[ "$BOUNDED_TIMED_OUT" -eq 1 ]]; then
    quarantine_die "$(timeout_message "git $*")"
  fi
  return "$rc"
}

# git's own last words for a failure message, in the order they are useful:
# stderr, then stdout, then a bare status so the message is never a dangling
# dash.
git_failure_text() { # rc
  local msg="$GIT_ERR"
  [[ -n "$msg" ]] || msg="$GIT_OUT"
  [[ -n "$msg" ]] || msg="git exited $1"
  printf '%s' "$msg"
}

# Short-circuit: if root repo is not on main, the guard has nothing to enforce.
# Feature branches are expected to carry dirty state; this guard only cares
# about the root-repo main branch.
CURRENT_BRANCH=""
git_bounded symbolic-ref --short HEAD || true
CURRENT_BRANCH="$GIT_OUT"
if [[ "$CURRENT_BRANCH" != "main" ]]; then
  if [[ "$MODE" == "check" ]]; then
    echo "clean"
  else
    echo "no-op: root repo is on '$CURRENT_BRANCH', not main"
  fi
  exit 0
fi

# Tracked-only dirty detection. `diff --quiet` covers unstaged; `diff --cached
# --quiet` covers staged. Using --porcelain would include untracked files,
# which should NOT block (see memory `feedback_porcelain_untracked.md`).
unstaged_rc=0
git_bounded diff --quiet || unstaged_rc=$?
staged_rc=0
git_bounded diff --cached --quiet || staged_rc=$?
if (( unstaged_rc > 1 || staged_rc > 1 )); then
  echo "error: could not inspect working tree (diff rc=$unstaged_rc, diff --cached rc=$staged_rc)"
  exit 2
fi
HAS_UNCOMMITTED=0
if (( unstaged_rc == 1 || staged_rc == 1 )); then
  HAS_UNCOMMITTED=1
fi

# Unpushed-commits detection. Fetch first so we compare against an up-to-date
# origin/main ref — otherwise a stale remote-tracking branch produces false
# positives. Fetch errors are non-fatal (offline / no network): fall back to
# whatever origin/main we already have.
#
# --no-fetch skips the round-trip for recurring callers (Stop hooks) where
# only *local* drift matters — a stale origin/main cannot mask new local
# commits or uncommitted changes, it can only make `rev-list ahead` stale,
# which is still correct for "did I commit something here?" detection.
if (( NO_FETCH == 0 )); then
  # Bounded like the rest, and for a second reason on top of the evicted-file
  # one: this is the only network call the guard makes, so a black-holed remote
  # would otherwise hang it with no diagnostic at all.
  #
  # The SOFT bound, uniquely, because a fetch failure is already non-fatal by
  # design (the paragraph above): a slow remote must not turn a guard that can
  # still answer from the origin/main on disk into a hard error. The timeout is
  # said out loud on stderr rather than swallowed.
  git_bounded_soft fetch origin main --quiet || true
  if [[ "$BOUNDED_TIMED_OUT" -eq 1 ]]; then
    echo "warning: 'git fetch origin main' exceeded ${GIT_BOUND_SECS}s and was killed — comparing against the origin/main already on disk" >&2
  fi
fi
# Fail fast if we can't compare HEAD to origin/main. Silently defaulting
# AHEAD=0 would mask the case where origin/main is missing (unusual remote
# config, first-ever clone with no successful fetch) and cause --check to
# report "clean" on a tree we never actually compared. Per the script's
# contract, git errors exit 2 rather than normalize to zero.
rev_list_rc=0
git_bounded rev-list --count origin/main..HEAD || rev_list_rc=$?
if (( rev_list_rc != 0 )); then
  echo "error: could not compare HEAD to origin/main — $(git_failure_text "$rev_list_rc" | tr '\n' ' ' | sed 's/[[:space:]]\{1,\}/ /g')"
  exit 2
fi
AHEAD="$GIT_OUT"
# Normalize to integer; rev-list yields a plain count, but guard against
# leading whitespace or empty string from unusual git output.
AHEAD="${AHEAD//[^0-9]/}"
[[ -n "$AHEAD" ]] || AHEAD=0

# --check mode: report and exit.
if [[ "$MODE" == "check" ]]; then
  if (( HAS_UNCOMMITTED == 0 && AHEAD == 0 )); then
    echo "clean"
    exit 0
  fi
  parts=()
  (( HAS_UNCOMMITTED == 1 )) && parts+=("uncommitted tracked changes")
  (( AHEAD > 0 )) && parts+=("$AHEAD unpushed commit(s) on main")
  # Join with " + " — Bash 3.2 compatible (no ${arr[*]/#/sep} tricks).
  joined=""
  for p in "${parts[@]}"; do
    if [[ -z "$joined" ]]; then
      joined="$p"
    else
      joined="$joined + $p"
    fi
  done
  echo "dirty: $joined"
  exit 1
fi

# --quarantine mode: preserve state, then reset main.
if (( HAS_UNCOMMITTED == 0 && AHEAD == 0 )); then
  echo "no-op: main is clean"
  exit 0
fi

STAMP="$(date +%Y%m%d-%H%M%S)"
RECOVERY="recovery/dirty-main-$STAMP"

# Defensive: if the branch name is already taken (clock skew, rapid re-runs),
# append a disambiguating suffix rather than clobbering.
if git_bounded show-ref --verify --quiet "refs/heads/$RECOVERY"; then
  RECOVERY="$RECOVERY-$$"
fi

# Step 1: create the recovery branch at the current main HEAD. This preserves
# any unpushed commits even if there are no uncommitted changes to move.
branch_rc=0
git_bounded branch "$RECOVERY" || branch_rc=$?
if (( branch_rc != 0 )); then
  echo "error: could not create recovery branch — $(git_failure_text "$branch_rc")"
  exit 2
fi

# Step 2: if there are uncommitted tracked changes, move them onto the recovery
# branch as a single commit. Switch to recovery, commit with -a (stages tracked
# modifications only; `-a` does NOT add untracked files), then switch back.
#
# `git commit -a` equivalent: `git add -u && git commit`. Already-staged
# entries in the index (including new-but-staged files) are committed too.
# Plain untracked-and-unstaged files remain untracked throughout.
moved_what=""
if (( HAS_UNCOMMITTED == 1 )); then
  # The window opens here. A timeout on this very checkout is ambiguous — git
  # may or may not have switched before it was killed — so the branch is named
  # from this point on and the off-main form is used, which checks rather than
  # assumes.
  QUARANTINE_BRANCH="$RECOVERY"
  checkout_rc=0
  git_bounded_offmain checkout --quiet "$RECOVERY" || checkout_rc=$?
  if (( checkout_rc != 0 )); then
    echo "error: could not checkout recovery branch — $(git_failure_text "$checkout_rc")"
    exit 2
  fi
  commit_rc=0
  git_bounded_offmain -c core.hooksPath=/dev/null commit -a -m "dirty-main quarantine $STAMP" || commit_rc=$?
  if (( commit_rc != 0 )); then
    # Return to main before bailing so we don't leave the user on recovery.
    # Captured first: the return trip overwrites GIT_ERR with its own result.
    commit_err="$(git_failure_text "$commit_rc")"
    # Soft: this is best-effort cleanup on a path that is already failing, and
    # the commit error is the actionable one. But a return trip that does not
    # land still has to be said out loud, whichever way it failed — a stranded
    # repo makes the next `--check` answer `clean` for a dirty main.
    back_rc=0
    git_bounded_soft checkout --quiet main || back_rc=$?
    if [[ "$BOUNDED_TIMED_OUT" -eq 1 ]]; then
      echo "warning: 'git checkout main' exceeded ${GIT_BOUND_SECS}s and was killed — the root repo may be left on $RECOVERY" >&2
    elif (( back_rc != 0 )); then
      echo "warning: could not return the root repo to main — it may be left on $RECOVERY" >&2
    fi
    echo "error: could not commit quarantined changes — $commit_err"
    exit 2
  fi
  # The return trip. Soft, because both ways it can fail leave the repo on the
  # recovery branch, and the caller has to be told that — a bare "could not
  # return to main" reads as an untidy exit rather than a guard that will now
  # answer `clean` for a dirty main.
  back_rc=0
  git_bounded_soft checkout --quiet main || back_rc=$?
  if [[ "$BOUNDED_TIMED_OUT" -eq 1 ]]; then
    timeout_message "git checkout --quiet main"
    echo "error: the root repo was left on $RECOVERY — return it to main by hand, or the guard will report a dirty main as clean"
    exit 2
  fi
  if (( back_rc != 0 )); then
    echo "error: could not return to main after commit — $(git_failure_text "$back_rc")"
    echo "error: the root repo was left on $RECOVERY — return it to main by hand, or the guard will report a dirty main as clean"
    exit 2
  fi
  QUARANTINE_BRANCH=""
  moved_what="uncommitted"
fi

if (( AHEAD > 0 )); then
  if [[ -n "$moved_what" ]]; then
    moved_what="$moved_what + $AHEAD unpushed commit(s)"
  else
    moved_what="$AHEAD unpushed commit(s)"
  fi
fi

# Step 3: reset main to origin/main. Safe now — all tracked state is on the
# recovery branch, and --hard leaves untracked files untouched.
reset_rc=0
git_bounded reset --hard origin/main || reset_rc=$?
if (( reset_rc != 0 )); then
  echo "error: could not reset main to origin/main — $(git_failure_text "$reset_rc")"
  exit 2
fi

echo "quarantined: $RECOVERY ($moved_what)"
exit 0
