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
#   main-sync.sh [--repo <path>]
#   main-sync.sh --help | -h
#
#   --repo <path>   Operate on the git repo rooted at <path> (uses `git -C`).
#                   Defaults to the current working directory.
#
# OUTPUT (single stdout line, always)
#   updated <before7> → <after7>       Fast-forward pulled new commits.
#   up to date (<sha7>)                Already at origin/main.
#   skipped: tracked files have uncommitted changes — run manually: <cmd>
#                                       Off-main with dirty tree; no-op.
#                                       (On-main dirty trees are NOT skipped —
#                                       pull --ff-only handles them natively.)
#   failed: could not checkout main — <git output>
#                                       Not on main and checkout refused.
#   failed: <git pull output>           Pull refused (non-ff, network, etc.).
#
#   The "updated" arrow is rendered as U+2192 RIGHTWARDS ARROW to match the
#   existing prose in merge/wrap skills.
#
# EXIT STATUS
#   0  Success — pull succeeded (updated or already up to date).
#   1  Skipped — uncommitted changes blocked the sync.
#   2  Failed — checkout main failed or pull --ff-only failed.
#   3  Usage error (unknown flag, missing --repo value, bad path).
#
# EXAMPLES
#   # Default: operate on the current working directory's repo.
#   STATUS=$(bash .claude/scripts/main-sync.sh)
#
#   # Explicit: operate on the root worktree from inside a feature worktree.
#   ROOT_REPO=$(.claude/scripts/repo-root.sh)
#   STATUS=$(bash .claude/scripts/main-sync.sh --repo "$ROOT_REPO")

set -euo pipefail

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
  if ! "${GIT[@]}" diff --quiet 2>/dev/null || ! "${GIT[@]}" diff --cached --quiet 2>/dev/null; then
    echo "skipped: tracked files have uncommitted changes — run manually: $MANUAL_CMD"
    exit 1
  fi
  if ! CHECKOUT_OUTPUT=$("${GIT[@]}" checkout main 2>&1); then
    echo "failed: could not checkout main — $CHECKOUT_OUTPUT"
    exit 2
  fi
fi

BEFORE_SHA=$("${GIT[@]}" rev-parse HEAD 2>/dev/null || true)
if PULL_OUTPUT=$("${GIT[@]}" pull origin main --ff-only 2>&1); then
  AFTER_SHA=$("${GIT[@]}" rev-parse HEAD 2>/dev/null || true)
  if [[ "$BEFORE_SHA" == "$AFTER_SHA" ]]; then
    echo "up to date (${AFTER_SHA:0:7})"
  else
    echo "updated ${BEFORE_SHA:0:7} → ${AFTER_SHA:0:7}"
  fi
  exit 0
else
  echo "failed: $PULL_OUTPUT"
  exit 2
fi
