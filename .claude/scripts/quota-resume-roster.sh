#!/usr/bin/env bash
# catalog: token-measurement — Record checkpointed Claude sessions and list manual resume options across verified shared profiles
set -euo pipefail
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec python3 "$SCRIPT_DIR/lib/quota_resume_roster.py" "$@"
