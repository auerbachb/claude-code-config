#!/usr/bin/env bash
# Thin wrapper — delegates to the shared .claude/scripts/pr-state.sh.
#
# The canonical PR-state script lives at .claude/scripts/pr-state.sh and is shared
# across /fixpr, /merge, /wrap, /go-on, /status, phase-b-reviewer, phase-c-merger.
# This file remains as a compatibility shim for anyone invoking the old path.
#
# All arguments, stdout (the JSON path), stderr, and exit codes are passed through
# unchanged via exec.
#
# Prefer calling .claude/scripts/pr-state.sh directly in new code.

set -euo pipefail

for candidate in \
  "$HOME/.claude/skills-worktree/.claude/scripts/pr-state.sh" \
  "$HOME/.claude/scripts/pr-state.sh" \
  "$(git rev-parse --show-toplevel 2>/dev/null)/.claude/scripts/pr-state.sh" \
  ".claude/scripts/pr-state.sh"; do
  if [[ -x "$candidate" ]]; then
    exec "$candidate" "$@"
  fi
done

echo "ERROR: pr-state.sh not found (checked ~/.claude/skills-worktree/.claude/scripts/, ~/.claude/scripts/, repo root .claude/scripts/)" >&2
exit 1
