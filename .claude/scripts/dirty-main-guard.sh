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
# USAGE
#   dirty-main-guard.sh --check
#   dirty-main-guard.sh --quarantine
#   dirty-main-guard.sh --help | -h
#
#   --check        Report whether main is dirty. Exit 0 clean, 1 dirty,
#                  0 also when not on main (not applicable).
#   --quarantine   Move dirty state to a recovery branch and reset main
#                  to origin/main. Exit 0 on success (or no-op when clean),
#                  2 on failure.
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
#   2  Failure (git error, could not create recovery branch, etc.).
#   3  Usage error (unknown flag, conflicting modes).
#
# EXAMPLES
#   # Session-start gate: check then quarantine if dirty.
#   ROOT=$(.claude/scripts/repo-root.sh)
#   if ! .claude/scripts/dirty-main-guard.sh --check >/dev/null; then
#     .claude/scripts/dirty-main-guard.sh --quarantine
#   fi
#   git -C "$ROOT" pull origin main --ff-only

set -euo pipefail

print_help() {
  awk 'NR == 1 { next } /^$/ { exit } { sub(/^# ?/, ""); print }' "$0"
}

usage_error() {
  echo "dirty-main-guard.sh: $1" >&2
  echo "Run with --help for usage." >&2
  exit 3
}

MODE=""
NO_FETCH=0
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

# Resolve root repo via the canonical helper. Script lives in .claude/scripts/
# inside the root repo, so BASH_SOURCE walks up two levels.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT_SH="$SCRIPT_DIR/repo-root.sh"
if [[ ! -x "$REPO_ROOT_SH" ]]; then
  echo "error: repo-root.sh not found or not executable at $REPO_ROOT_SH"
  exit 2
fi

ROOT=""
if ! ROOT="$("$REPO_ROOT_SH" "$SCRIPT_DIR" 2>/dev/null)"; then
  echo "error: could not resolve root repo"
  exit 2
fi
if [[ -z "$ROOT" || ! -d "$ROOT" ]]; then
  echo "error: resolved root repo is empty or missing"
  exit 2
fi

GIT=(git -C "$ROOT")

# Short-circuit: if root repo is not on main, the guard has nothing to enforce.
# Feature branches are expected to carry dirty state; this guard only cares
# about the root-repo main branch.
CURRENT_BRANCH="$("${GIT[@]}" symbolic-ref --short HEAD 2>/dev/null || true)"
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
"${GIT[@]}" diff --quiet 2>/dev/null || unstaged_rc=$?
staged_rc=0
"${GIT[@]}" diff --cached --quiet 2>/dev/null || staged_rc=$?
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
  "${GIT[@]}" fetch origin main --quiet 2>/dev/null || true
fi
AHEAD=0
if ahead_raw="$("${GIT[@]}" rev-list --count origin/main..HEAD 2>/dev/null)"; then
  AHEAD="$ahead_raw"
fi
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
if "${GIT[@]}" show-ref --verify --quiet "refs/heads/$RECOVERY"; then
  RECOVERY="$RECOVERY-$$"
fi

# Step 1: create the recovery branch at the current main HEAD. This preserves
# any unpushed commits even if there are no uncommitted changes to move.
if ! branch_out="$("${GIT[@]}" branch "$RECOVERY" 2>&1)"; then
  echo "error: could not create recovery branch — $branch_out"
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
  if ! checkout_out="$("${GIT[@]}" checkout --quiet "$RECOVERY" 2>&1)"; then
    echo "error: could not checkout recovery branch — $checkout_out"
    exit 2
  fi
  if ! commit_out="$("${GIT[@]}" -c core.hooksPath=/dev/null commit -a -m "dirty-main quarantine $STAMP" 2>&1)"; then
    # Return to main before bailing so we don't leave the user on recovery.
    "${GIT[@]}" checkout --quiet main 2>/dev/null || true
    echo "error: could not commit quarantined changes — $commit_out"
    exit 2
  fi
  if ! back_out="$("${GIT[@]}" checkout --quiet main 2>&1)"; then
    echo "error: could not return to main after commit — $back_out"
    exit 2
  fi
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
if ! reset_out="$("${GIT[@]}" reset --hard origin/main 2>&1)"; then
  echo "error: could not reset main to origin/main — $reset_out"
  exit 2
fi

echo "quarantined: $RECOVERY ($moved_what)"
exit 0
