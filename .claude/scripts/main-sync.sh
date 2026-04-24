#!/usr/bin/env bash
# main-sync.sh — Sync a repo's local `main` with `origin/main`.
#
# PURPOSE
#   Centralizes the "sync local main" sequence used in `/merge` Step 5b,
#   `/wrap` Step 2.5 (née 2.6), and the `session-start-sync.sh` hook:
#     1. Checkout `main` if the repo is on another branch — but only after
#        guarding against uncommitted tracked changes (staged + unstaged),
#        since `git checkout` would either refuse or silently carry them.
#     2. `git pull origin main --ff-only` and report BEFORE/AFTER SHAs.
#
#   When already on `main`, the dirty-check is skipped: `git pull --ff-only`
#   handles non-conflicting dirty trees natively, matching the prior bare-
#   pull behavior of `session-start-sync.sh` (see PR #345).
#
#   All output lines follow the status-string contract documented below, so
#   callers can simply capture stdout and pass it through to user-visible
#   reports without re-parsing.
#
# USAGE
#   main-sync.sh [--repo <path>] [--reset]
#   main-sync.sh --help | -h
#
#   --repo <path>   Operate on the git repo rooted at <path> (uses `git -C`).
#                   Defaults to the current working directory.
#   --reset         Aggressive post-merge sync: fetch origin/main, abort if
#                   local main has unpushed commits, else `git reset --hard
#                   origin/main`. Used by /wrap to guarantee local main
#                   matches origin after merge. Without --reset, the script
#                   falls back to the cautious `git pull --ff-only` path.
#
# OUTPUT (single stdout line, always — multi-line git stderr is collapsed)
#   updated <before7> → <after7>       Fast-forward pulled new commits.
#   reset <before7> → <after7>         --reset advanced main to origin/main.
#   up to date (<sha7>)                Already at origin/main.
#   skipped: tracked files have uncommitted changes — run manually: <cmd>
#                                       Off-main with dirty tree; no-op.
#                                       (On-main dirty trees are NOT skipped
#                                       in the default path — pull --ff-only
#                                       handles them natively. --reset DOES
#                                       check tracked changes on main because
#                                       `reset --hard` is destructive.)
#   aborted: local main has <N> unpushed commit(s) — inspect: git log origin/main..main, resolve manually before re-running
#                                       --reset refused to clobber unpushed
#                                       commits. Belt-and-suspenders for any
#                                       bypass of the root/main pre-commit
#                                       hook (#323). Run the suggested
#                                       `git log` to see what's local.
#   failed: not inside a git working tree — <rev-parse output>
#                                       --repo (or cwd) is not a git repo.
#   failed: could not inspect working tree state (git diff rc=<N>, ...)
#                                       `git diff` itself errored (rc>1).
#   failed: could not checkout main — <git output>
#                                       Not on main and checkout refused.
#   failed: git fetch origin main — <git output>
#                                       --reset fetch step failed.
#   failed: could not compare HEAD to origin/main — <git output>
#                                       --reset rev-list step failed.
#   failed: could not reset main to origin/main — <git output>
#                                       --reset reset step failed.
#   failed: <git pull output>           Pull refused (non-ff, network, etc.).
#
#   The arrow is rendered as U+2192 RIGHTWARDS ARROW to match the existing
#   prose in merge/wrap skills.
#
# EXIT STATUS
#   0  Success — pull or reset succeeded (updated, reset, or up to date).
#   1  Skipped — uncommitted changes blocked the sync.
#   2  Failed — checkout main, fetch, rev-list, pull, or reset failed.
#   3  Usage error (unknown flag, missing --repo value, bad path).
#   4  Aborted — --reset refused because local main has unpushed commits.
#
# EXAMPLES
#   # Default: operate on the current working directory's repo.
#   STATUS=$(bash .claude/scripts/main-sync.sh)
#
#   # Explicit: operate on the root worktree from inside a feature worktree.
#   ROOT_REPO=$(.claude/scripts/repo-root.sh)
#   STATUS=$(bash .claude/scripts/main-sync.sh --repo "$ROOT_REPO")

set -euo pipefail

# Collapse a captured git stderr blob into a single whitespace-normalized line
# so the "failed: ..." status string honors the single-line stdout contract
# documented in the OUTPUT section above. Callers capture this stdout and
# pipe it straight into user-visible reports; a multi-line value would split
# into multiple "columns" and break table rendering / grep-based checks.
to_one_line() {
  printf '%s' "$1" | tr '\n' ' ' | sed -e 's/[[:space:]]\{1,\}/ /g' -e 's/^ //' -e 's/ $//'
}

print_help() {
  # Print the header block (lines 2..first blank line), stripping leading "# ".
  # Matches the pattern used by repo-root.sh / off-peak-minute.sh / workday.sh.
  awk 'NR == 1 { next } /^$/ { exit } { sub(/^# ?/, ""); print }' "$0"
}

usage_error() {
  echo "main-sync.sh: $1" >&2
  echo "Run with --help for usage." >&2
  exit 3
}

REPO=""
RESET_MODE=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help)
      print_help
      exit 0
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
    --reset)
      RESET_MODE=1
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

if [[ $# -gt 0 ]]; then
  usage_error "unexpected positional argument: $1"
fi

# Build the git command prefix and the manual-recovery command used in the
# "skipped" status. Bare `git` when no --repo so the recovery command stays
# readable; `git -C "<path>"` otherwise so it's copy-paste-runnable from
# anywhere the caller invoked us.
if [[ -n "$REPO" ]]; then
  if [[ ! -d "$REPO" ]]; then
    usage_error "--repo path does not exist: $REPO"
  fi
  GIT=(git -C "$REPO")
  MANUAL_CMD="git -C \"$REPO\" checkout main && git -C \"$REPO\" pull origin main --ff-only"
else
  GIT=(git)
  MANUAL_CMD="git checkout main && git pull origin main --ff-only"
fi

# Refuse to run outside a git working tree — every downstream call (checkout,
# diff, pull, rev-parse) would otherwise fail with a cryptic "fatal: not a git
# repository" and exit 128/129, which the dirty-check below would misread as
# a "dirty tree" skip (exit 1) instead of a hard configuration failure (exit 2).
if ! INSIDE_WT=$("${GIT[@]}" rev-parse --is-inside-work-tree 2>&1); then
  echo "failed: not inside a git working tree — $(to_one_line "$INSIDE_WT")"
  exit 2
fi
if [[ "$INSIDE_WT" != "true" ]]; then
  echo "failed: not inside a git working tree (rev-parse returned: $INSIDE_WT)"
  exit 2
fi

# Ensure we're on main before pulling. The uncommitted-changes guard only
# fires when we need to checkout — `git checkout main` refuses to run if
# uncommitted tracked changes would be clobbered, and silently carries them
# across branches otherwise, both of which we want to avoid. If we're
# ALREADY on main, `git pull --ff-only` handles non-conflicting dirty trees
# natively (the pull succeeds and leaves the working tree intact), so
# skipping there would regress the hook's prior bare-pull behavior
# (see BugBot finding on PR #345).
#
# `diff --quiet` / `diff --cached --quiet` cover tracked files only —
# untracked files do NOT block a fast-forward pull, so using
# `status --porcelain` here would produce false positives (see memory
# note `feedback_porcelain_untracked.md`).
CURRENT_BRANCH=$("${GIT[@]}" branch --show-current 2>/dev/null || true)
if [[ "$CURRENT_BRANCH" != "main" ]]; then
  # Distinguish "dirty tree" (exit 1 — benign skip) from "git error" (exit >1 —
  # hard failure). The `|| rc=$?` idiom both captures the exit status AND
  # suppresses `set -e` on the expected non-zero rc=1 from `diff --quiet`.
  unstaged_rc=0
  "${GIT[@]}" diff --quiet 2>/dev/null || unstaged_rc=$?
  staged_rc=0
  "${GIT[@]}" diff --cached --quiet 2>/dev/null || staged_rc=$?
  if (( unstaged_rc > 1 || staged_rc > 1 )); then
    echo "failed: could not inspect working tree state (git diff rc=$unstaged_rc, git diff --cached rc=$staged_rc)"
    exit 2
  fi
  if (( unstaged_rc == 1 || staged_rc == 1 )); then
    echo "skipped: tracked files have uncommitted changes — run manually: $MANUAL_CMD"
    exit 1
  fi
  if ! CHECKOUT_OUTPUT=$("${GIT[@]}" checkout main 2>&1); then
    echo "failed: could not checkout main — $(to_one_line "$CHECKOUT_OUTPUT")"
    exit 2
  fi
fi

BEFORE_SHA=$("${GIT[@]}" rev-parse HEAD 2>/dev/null || true)

if (( RESET_MODE == 1 )); then
  # --reset mode: fetch, verify safety, then hard-reset to origin/main.
  # `git reset --hard` is a sanctioned exception to safety.md's destructive-
  # command prohibitions, guarded by:
  #   (a) the dirty-tree check below (pull --ff-only's tolerance of dirty
  #       on-main trees does NOT apply — reset --hard clobbers them),
  #   (b) the ahead-of-origin check below (belt-and-suspenders for any
  #       bypass of the root/main pre-commit hook from #323).
  # Expected composition: /wrap runs dirty-main-guard --quarantine on the
  # root repo before calling this, so the dirty check here should be a
  # formality on the happy path.
  unstaged_rc=0
  "${GIT[@]}" diff --quiet 2>/dev/null || unstaged_rc=$?
  staged_rc=0
  "${GIT[@]}" diff --cached --quiet 2>/dev/null || staged_rc=$?
  if (( unstaged_rc > 1 || staged_rc > 1 )); then
    echo "failed: could not inspect working tree state (git diff rc=$unstaged_rc, git diff --cached rc=$staged_rc)"
    exit 2
  fi
  if (( unstaged_rc == 1 || staged_rc == 1 )); then
    echo "skipped: tracked files have uncommitted changes — run manually: $MANUAL_CMD"
    exit 1
  fi

  if ! FETCH_OUTPUT=$("${GIT[@]}" fetch origin main 2>&1); then
    echo "failed: git fetch origin main — $(to_one_line "$FETCH_OUTPUT")"
    exit 2
  fi

  if ! AHEAD_RAW=$("${GIT[@]}" rev-list --count origin/main..HEAD 2>&1); then
    echo "failed: could not compare HEAD to origin/main — $(to_one_line "$AHEAD_RAW")"
    exit 2
  fi
  # Fail loud if the count can't be parsed — silently treating "?" as 0
  # would proceed to reset --hard with unknown state, which is exactly what
  # the ahead check exists to prevent.
  AHEAD_TRIMMED="$(printf '%s' "$AHEAD_RAW" | tr -d '[:space:]')"
  if ! [[ "$AHEAD_TRIMMED" =~ ^[0-9]+$ ]]; then
    echo "failed: could not parse ahead count from rev-list — $(to_one_line "$AHEAD_RAW")"
    exit 2
  fi
  AHEAD="$AHEAD_TRIMMED"
  if (( AHEAD > 0 )); then
    echo "aborted: local main has $AHEAD unpushed commit(s) — inspect: git log origin/main..main, resolve manually before re-running"
    exit 4
  fi

  if ! RESET_OUTPUT=$("${GIT[@]}" reset --hard origin/main 2>&1); then
    echo "failed: could not reset main to origin/main — $(to_one_line "$RESET_OUTPUT")"
    exit 2
  fi
  AFTER_SHA=$("${GIT[@]}" rev-parse HEAD 2>/dev/null || true)
  if [[ "$BEFORE_SHA" == "$AFTER_SHA" ]]; then
    echo "up to date (${AFTER_SHA:0:7})"
  else
    echo "reset ${BEFORE_SHA:0:7} → ${AFTER_SHA:0:7}"
  fi
  exit 0
fi

if PULL_OUTPUT=$("${GIT[@]}" pull origin main --ff-only 2>&1); then
  AFTER_SHA=$("${GIT[@]}" rev-parse HEAD 2>/dev/null || true)
  if [[ "$BEFORE_SHA" == "$AFTER_SHA" ]]; then
    echo "up to date (${AFTER_SHA:0:7})"
  else
    echo "updated ${BEFORE_SHA:0:7} → ${AFTER_SHA:0:7}"
  fi
  exit 0
else
  echo "failed: $(to_one_line "$PULL_OUTPUT")"
  exit 2
fi
