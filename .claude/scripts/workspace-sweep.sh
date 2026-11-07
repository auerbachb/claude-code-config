#!/bin/bash
# catalog: trust-worktree-repo — Run finished-worktree cleanup after merges, on PM ticks, and daily across configured repositories
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec python3 "$SCRIPT_DIR/lib/workspace_sweep.py" "$@"
