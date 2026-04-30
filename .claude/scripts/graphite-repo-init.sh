#!/usr/bin/env bash
# Optional: create .git/.graphite_repo_config so the Graphite Claude Code plugin
# can auto-detect Graphite-enabled repos (see issue #397).
#
# Requires Graphite CLI (`gt`). Install: brew install withgraphite/tap/graphite
# or npm install -g @withgraphite/graphite-cli@stable
#
# Usage:
#   bash .claude/scripts/graphite-repo-init.sh           # cwd or skills-worktree root
#   bash .claude/scripts/graphite-repo-init.sh /path/to/repo
#
# Non-destructive: exits 0 if gt is missing or the repo is already initialized.

set -euo pipefail

TARGET="${1:-}"
if [[ -z "$TARGET" ]]; then
  TARGET="$(pwd)"
elif [[ ! -d "$TARGET" ]]; then
  echo "graphite-repo-init: not a directory: $TARGET" >&2
  exit 1
fi

if ! command -v gt >/dev/null 2>&1; then
  echo "graphite-repo-init: 'gt' not in PATH — install Graphite CLI, then re-run."
  exit 0
fi

if ! git -C "$TARGET" rev-parse --git-dir >/dev/null 2>&1; then
  echo "graphite-repo-init: not a git repository: $TARGET" >&2
  exit 1
fi

# rev-parse --git-path returns a path relative to the repo root, not to $PWD.
REL="$(git -C "$TARGET" rev-parse --git-path .graphite_repo_config)"
TOP="$(git -C "$TARGET" rev-parse --show-toplevel)"
if [[ "$REL" == /* ]]; then
  CONFIG="$REL"
else
  CONFIG="$TOP/${REL#./}"
fi

if [[ -f "$CONFIG" ]]; then
  echo "graphite-repo-init: already present: $CONFIG"
  exit 0
fi

echo "graphite-repo-init: running gt repo init in $TARGET"
if ! (cd "$TARGET" && gt repo init); then
  echo "graphite-repo-init: gt repo init failed (auth/network?). Skip or run manually later." >&2
  exit 0
fi
echo "graphite-repo-init: done ($CONFIG)"
