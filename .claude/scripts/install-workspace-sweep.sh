#!/bin/bash
# catalog: scheduling-monitoring — Install the daily finished-worktree LaunchAgent, with a side-effect-free dry run
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec python3 "$SCRIPT_DIR/lib/workspace_sweep_install.py" "$@"
