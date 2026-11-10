#!/bin/bash
# catalog: scheduling-monitoring — Uninstall the finished-worktree LaunchAgent while retaining logs and registry
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec python3 "$SCRIPT_DIR/lib/workspace_sweep_install.py" --uninstall "$@"
