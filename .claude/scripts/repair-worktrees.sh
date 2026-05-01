#!/usr/bin/env bash
# repair-worktrees.sh — Detect and optionally clean up stale git worktrees.
#
# A worktree is "stale" when BOTH:
#   1. Its branch is merged into main OR its branch no longer exists on origin, AND
#   2. The worktree has no uncommitted changes (tracked or staged).
#
# The main worktree (first entry from `git worktree list`) is NEVER touched.
# Worktrees with uncommitted changes are NEVER removed — they are reported and skipped.
#
# Usage:
#   repair-worktrees.sh            # dry-run: report stale worktrees, print the
#                                  # exact `git worktree remove` commands that
#                                  # WOULD run, but do nothing.
#   repair-worktrees.sh --apply    # actually remove safe stale worktrees, then
#                                  # run `git worktree prune`.
#   repair-worktrees.sh -h|--help  # print this usage and exit.
#
# Exit codes:
#   0 — success (dry-run completed, or --apply finished without errors)
#   1 — usage error or unrecoverable failure
#
# Safety:
#   - Defaults to dry-run; --apply is required for destructive action.
#   - Uncommitted changes (working tree OR index) always skip removal.
#   - Main worktree is identified by `git worktree list --porcelain` order
#     (first entry) and explicitly excluded.

set -euo pipefail
printf '%s\t%s\t%s\n' "$(date -u +%FT%TZ)" "$(basename "$0")" "${*//$'\n'/ }" >> "$HOME/.claude/script-usage.log" 2>/dev/null || true

APPLY=0
for arg in "$@"; do
  case "$arg" in
    --apply)
      APPLY=1
      ;;
    -h|--help)
      sed -n '2,27p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *)
      echo "Unknown argument: $arg" >&2
      echo "Run with -h for usage." >&2
      exit 1
      ;;
  esac
done

# Resolve the main repo root (first worktree entry).
# Prefer the shared helper; fall back to inline porcelain parse when not available.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT_HELPER="$SCRIPT_DIR/repo-root.sh"
if [[ -x "$REPO_ROOT_HELPER" ]]; then
  MAIN_ROOT="$("$REPO_ROOT_HELPER")" || true
else
  MAIN_ROOT="$(git worktree list --porcelain 2>/dev/null \
    | awk '/^worktree /{sub(/^worktree /, ""); print; exit}')" || true
fi
if [[ -z "${MAIN_ROOT}" ]]; then
  echo "error: could not determine main worktree root" >&2
  exit 1
fi

# Ensure we have up-to-date refs for the remote-branch check.
if ! git -C "$MAIN_ROOT" fetch --prune --quiet origin 2>/dev/null; then
  echo "warning: 'git fetch origin' failed — remote-branch check may be stale" >&2
fi

# Parse worktree list into parallel arrays: paths and branches.
# Porcelain format: stanzas separated by blank lines; each has `worktree <path>`
# and (usually) `branch refs/heads/<name>`. Detached HEADs have no branch line.
paths=()
branches=()
cur_path=""
cur_branch=""
while IFS= read -r line; do
  if [[ "$line" == worktree\ * ]]; then
    cur_path="${line#worktree }"
    cur_branch=""
  elif [[ "$line" == branch\ refs/heads/* ]]; then
    cur_branch="${line#branch refs/heads/}"
  elif [[ -z "$line" ]]; then
    if [[ -n "$cur_path" ]]; then
      paths+=("$cur_path")
      branches+=("$cur_branch")
    fi
    cur_path=""
    cur_branch=""
  fi
done < <(git -C "$MAIN_ROOT" worktree list --porcelain; printf '\n')
# Flush final stanza if no trailing blank line.
if [[ -n "$cur_path" ]]; then
  paths+=("$cur_path")
  branches+=("$cur_branch")
fi

stale_paths=()
dirty_paths=()
skipped_detached=()

total="${#paths[@]}"
for ((i = 0; i < total; i++)); do
  wt="${paths[$i]}"
  br="${branches[$i]}"

  # Never touch the main worktree.
  if [[ "$wt" == "$MAIN_ROOT" ]]; then
    continue
  fi

  # Detached HEAD: no branch to reason about — skip for safety.
  if [[ -z "$br" ]]; then
    skipped_detached+=("$wt")
    continue
  fi

  # Dirty check: uncommitted working-tree OR index changes OR untracked files.
  # Untracked files (e.g., a stray .env, scratch notes, partially-written scripts)
  # are invisible to `diff --quiet` but `git worktree remove` will silently delete
  # them. The ls-files check below protects those files.
  if ! (git -C "$wt" diff --quiet 2>/dev/null && git -C "$wt" diff --cached --quiet 2>/dev/null); then
    dirty_paths+=("$wt")
    continue
  fi
  if [[ -n "$(git -C "$wt" ls-files --others --exclude-standard 2>/dev/null)" ]]; then
    dirty_paths+=("$wt")
    continue
  fi

  # Staleness: merged into main OR branch no longer on origin.
  # NOTE: `merge-base --is-ancestor` does NOT catch squash-merged branches —
  # the original tip is not an ancestor of the squash commit. In practice
  # squash-merge always deletes the remote branch, so the remote_gone check
  # below catches squash-merged PRs. The is-ancestor check covers non-squash
  # (true merge or ff) merges. We compare against `origin/main` to avoid lag
  # in the local `main` ref.
  merged=0
  if git -C "$MAIN_ROOT" merge-base --is-ancestor "$br" origin/main 2>/dev/null; then
    merged=1
  fi

  # Remote-gone: the branch is absent from origin. A never-pushed local branch
  # also has no origin ref — distinguish by checking whether the branch has
  # any commits ahead of main. Never-pushed branches with local commits are
  # not stale (they represent in-progress unpushed work).
  remote_gone=0
  if [[ -z "$(git -C "$MAIN_ROOT" ls-remote --heads origin "$br" 2>/dev/null)" ]]; then
    local_commits="$(git -C "$MAIN_ROOT" rev-list --count "origin/main..$br" 2>/dev/null || echo 0)"
    if [[ "$local_commits" -eq 0 ]]; then
      remote_gone=1
    fi
  fi

  if [[ "$merged" -eq 1 || "$remote_gone" -eq 1 ]]; then
    stale_paths+=("$wt")
  fi
done

echo "Worktree cleanup report"
echo "======================="
echo "Main worktree (never removed): $MAIN_ROOT"
echo
echo "Stale worktrees detected:       ${#stale_paths[@]}"
echo "Dirty worktrees (skipped):      ${#dirty_paths[@]}"
echo "Detached HEADs (skipped):       ${#skipped_detached[@]}"
echo

if (( ${#dirty_paths[@]} > 0 )); then
  echo "Dirty worktrees — uncommitted changes, NOT eligible for removal:"
  for p in "${dirty_paths[@]}"; do
    echo "  - $p"
  done
  echo
fi

if (( ${#skipped_detached[@]} > 0 )); then
  echo "Detached HEAD worktrees — skipped (no branch to evaluate):"
  for p in "${skipped_detached[@]}"; do
    echo "  - $p"
  done
  echo
fi

if (( ${#stale_paths[@]} == 0 )); then
  echo "Nothing to clean up."
  exit 0
fi

echo "Stale worktrees safe to remove:"
for p in "${stale_paths[@]}"; do
  echo "  - $p"
done
echo

if (( APPLY == 0 )); then
  echo "Dry-run mode (default). The following commands WOULD run with --apply:"
  for p in "${stale_paths[@]}"; do
    echo "  git -C \"$MAIN_ROOT\" worktree remove \"$p\""
  done
  echo "  git -C \"$MAIN_ROOT\" worktree prune"
  echo
  echo "Re-run with --apply to actually remove them."
  exit 0
fi

echo "Applying removals..."
failures=0
for p in "${stale_paths[@]}"; do
  if git -C "$MAIN_ROOT" worktree remove "$p"; then
    echo "  removed: $p"
  else
    echo "  FAILED:  $p" >&2
    failures=$((failures + 1))
  fi
done

git -C "$MAIN_ROOT" worktree prune
echo "Prune complete."

if (( failures > 0 )); then
  echo "$failures removal(s) failed." >&2
  exit 1
fi

echo "Done."
