#!/usr/bin/env bash
# repo-root.sh — Resolve the absolute path of the main (root) worktree.
#
# PURPOSE
#   Centralizes the "first-entry-in-`git worktree list`" pattern used across
#   rules, skills, agents, hooks, and scripts. The main worktree root is the
#   path returned as the first `worktree ` stanza by `git worktree list
#   --porcelain` — it is stable regardless of which worktree the caller is in.
#
#   Hardens the historic one-liner (`git worktree list | head -1 | awk '{print
#   $1}'`) against two silent-failure modes:
#     1. Not inside a git repo — old one-liner prints an empty string and
#        returns exit 0; callers would assign "" to ROOT_REPO and proceed.
#     2. Path contains whitespace — the space-splitting awk breaks; porcelain
#        format preserves the full path on its own line.
#
# USAGE
#   repo-root.sh [path]
#   repo-root.sh --help | -h
#
#   path   Optional directory to resolve from (equivalent to `git -C <path>`).
#          Defaults to the current working directory.
#
# OUTPUT
#   stdout: absolute path of the main-worktree root (no trailing newline beyond
#           the usual `echo`).
#   stderr: one-line error message on failure.
#
# EXIT STATUS
#   0  Success — path printed on stdout.
#   1  Not inside a git repo / no worktrees found / resolved path missing.
#   2  Usage error (unknown flag or extra argument).
#
# EXAMPLES
#   ROOT_REPO=$(.claude/scripts/repo-root.sh)            # from anywhere in repo
#   ROOT_REPO=$(.claude/scripts/repo-root.sh "$SOME_WT") # from another worktree

set -euo pipefail

# Self-extract the header block between BEGIN/END markers for --help.
print_help() {
  sed -n '/^# PURPOSE$/,/^# EXAMPLES$/p' "$0" | sed 's/^# \{0,1\}//'
}

TARGET=""
for arg in "$@"; do
  case "$arg" in
    -h|--help)
      print_help
      exit 0
      ;;
    --)
      ;;
    -*)
      echo "repo-root.sh: unknown flag: $arg" >&2
      echo "Run with --help for usage." >&2
      exit 2
      ;;
    *)
      if [[ -n "$TARGET" ]]; then
        echo "repo-root.sh: only one path argument is allowed" >&2
        exit 2
      fi
      TARGET="$arg"
      ;;
  esac
done

# Porcelain parsing: first `worktree <path>` line is the main worktree root.
# Suppress stderr — we emit our own one-line error on failure below.
# Use two code paths instead of an empty array + expansion because Bash 3.2
# (macOS default) errors on `"${arr[@]}"` when arr is empty under `set -u`.
if [[ -n "$TARGET" ]]; then
  root="$(git -C "$TARGET" worktree list --porcelain 2>/dev/null \
    | awk '/^worktree /{sub(/^worktree /, ""); print; exit}')" || true
else
  root="$(git worktree list --porcelain 2>/dev/null \
    | awk '/^worktree /{sub(/^worktree /, ""); print; exit}')" || true
fi

if [[ -z "$root" ]]; then
  if [[ -n "$TARGET" ]]; then
    echo "repo-root.sh: could not resolve main worktree root (not a git repo: $TARGET)" >&2
  else
    echo "repo-root.sh: could not resolve main worktree root (not inside a git repo)" >&2
  fi
  exit 1
fi

if [[ ! -d "$root" ]]; then
  echo "repo-root.sh: resolved path does not exist: $root" >&2
  exit 1
fi

echo "$root"
