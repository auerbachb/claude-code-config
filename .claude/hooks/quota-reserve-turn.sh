#!/usr/bin/env bash
# Quota-reserve turn classifier — UserPromptSubmit hook (issue #1863).
# Records whether the turn about to run was started by the owner or by an
# automated event (a CI monitor, a task notification, a session note), so the
# PreToolUse guard can leave the owner's own turns alone while an account is in
# reserve. Never blocks anything: it only writes a small per-session record.

set -uo pipefail
HERE="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)" || exit 0
SCRIPT="${HERE%/hooks}/scripts/quota-reserve.sh"
[[ -x "$SCRIPT" ]] || exit 0
"$SCRIPT" --classify-prompt >/dev/null 2>&1 || true
exit 0
