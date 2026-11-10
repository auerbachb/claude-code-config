#!/usr/bin/env bash
# catalog: review-escalation — Read-only bounded current-HEAD BugBot invitation/grant verdict with private recovery evidence; never triggers or consumes
# See lib/bugbot_invitation.py --help. No GitHub write or paid authorization.
set -euo pipefail
exec python3 "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/bugbot_invitation.py" "$@"
