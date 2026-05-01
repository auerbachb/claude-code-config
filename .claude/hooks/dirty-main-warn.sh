#!/bin/bash
# Stop hook: warn loudly if the root repo's main branch is dirty.
# Complements the session-start guard in CLAUDE.md. If this fires mid-session,
# something pushed dirty state onto main after the session started.
#
# Emits additionalContext (non-blocking) with the recommended quarantine
# command so the model sees it and can act. Never calls --quarantine
# itself — quarantine is an intentional operation gated on session start.

cat > /dev/null

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
guard="${script_dir%/.claude/hooks}/.claude/scripts/dirty-main-guard.sh"

if [[ ! -x "$guard" ]]; then
  exit 0
fi

# --no-fetch skips the network round-trip (BugBot PR #350 finding:
# Stop fires after every response, and a fetch per turn is wasteful).
# Local-only drift detection is what this hook needs — session-start
# is where the canonical fetch happens.
status=$("$guard" --check --no-fetch 2>/dev/null) || rc=$?
rc=${rc:-0}

if [[ "$rc" -eq 1 ]]; then
  # Shell-escape the guard path so copy/paste survives paths with spaces.
  # printf '%q' produces a shell-safe representation that the user can paste
  # directly into a terminal without mis-tokenizing on whitespace.
  quarantine_cmd="$(printf '%q' "$guard") --quarantine"
  jq -n --arg s "$status" --arg cmd "$quarantine_cmd" '{
    hookSpecificOutput: {
      hookEventName: "Stop",
      additionalContext: ("DIRTY MAIN WARNING: " + $s + ". Run: " + $cmd + "  (creates a recovery/dirty-main-* branch, then resets main to origin/main).")
    }
  }'
fi

exit 0
