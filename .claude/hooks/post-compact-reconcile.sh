#!/usr/bin/env bash
# post-compact-reconcile.sh — deterministic post-compaction reconciliation
#                             trigger (issue #813)
#
# PURPOSE
#   `monitor-mode.md` §"Post-Compaction Recovery" requires the agent to run a
#   reconciliation sequence after context compaction — re-reading session-state
#   and handoff files, reconciling open PRs against GitHub, and verifying stale
#   agents and stalled transitions. Today that trigger depends on model judgment:
#   the agent must notice an unfamiliar summary block and decide to run recovery.
#
#   This hook closes the gap. `PostCompact` fires deterministically after every
#   compaction; by emitting `hookSpecificOutput.additionalContext`, the hook
#   guarantees the reconciliation prompt reaches the agent regardless of how
#   clearly the compact summary signals the prior state.
#
# WHAT THIS IS NOT
#   It does not replace the backstops that already exist: on-disk
#   `session-state.json`, per-PR handoff files in `~/.claude/handoffs/`, and
#   `checkpoint-handoff.sh` on `SubagentStop`. Those remain intact. This hook
#   makes the model-judgment trigger *redundant* rather than necessary — the
#   recovery is now guaranteed to be prompted whether or not the agent would
#   have noticed the need.
#
# PAYLOAD
#   `PostCompact` extends the shared hook payload base with `compact_summary`
#   (the text the runtime produced as the compaction summary). This script reads
#   it for informational context but emits the same context regardless of its
#   content — compaction always warrants a reconciliation pass.
#
# REGISTRATION
#   Registered under `PostCompact` in `global-settings.json` with a 10 s timeout.
#   `register-hooks.py` auto-registers it from that template on every session start.
#
# EXIT STATUS
#   Always 0. A hook that becomes a new failure mode is worse than no hook.
#   Diagnostics go to stderr.

set -uo pipefail

# Consume stdin. The hook protocol requires draining stdin; PostCompact carries
# compact_summary and the shared base fields. Reading into a variable lets us
# optionally surface the summary in the context message.
INPUT=$(cat 2>/dev/null || true)

# Extract compact_summary from the payload if jq is available. This is used only
# for the context message — the reconciliation prompt is emitted regardless.
COMPACT_SUMMARY=""
if command -v jq >/dev/null 2>&1 && [[ -n "$INPUT" ]]; then
  COMPACT_SUMMARY=$(jq -r '.compact_summary // empty' <<<"$INPUT" 2>/dev/null || true)
fi

# Build the additionalContext message. The core instruction is the Post-Compaction
# Recovery sequence from monitor-mode.md. Including the compact_summary (when
# available) gives the agent immediate context about what the compaction covered,
# so it can calibrate how much state to re-verify.
if [[ -n "$COMPACT_SUMMARY" ]]; then
  CONTEXT="POST-COMPACTION RECOVERY REQUIRED

Context compaction just completed. Run the Post-Compaction Recovery sequence from
.claude/rules/monitor-mode.md §\"Post-Compaction Recovery\" now:

1. Timestamp and rerun session-start checks.
2. Read session-state.json + handoffs; reconcile each open PR on GitHub (all 3
   endpoints per cr-github-review.md).
3. Per polled PR: polling-state-gate.sh <N> --verify-state (optional --root-repo <path>),
   then polling-state-gate.sh <N> (shells merge-gate.sh).
4. Reconcile state (PR, HEAD, reviewer, pending); verify stale agents and stalled
   transitions; launch as needed.
5. Resume monitoring — one heartbeat line, no report.

Compact summary from the runtime:
${COMPACT_SUMMARY}"
else
  CONTEXT="POST-COMPACTION RECOVERY REQUIRED

Context compaction just completed. Run the Post-Compaction Recovery sequence from
.claude/rules/monitor-mode.md §\"Post-Compaction Recovery\" now:

1. Timestamp and rerun session-start checks.
2. Read session-state.json + handoffs; reconcile each open PR on GitHub (all 3
   endpoints per cr-github-review.md).
3. Per polled PR: polling-state-gate.sh <N> --verify-state (optional --root-repo <path>),
   then polling-state-gate.sh <N> (shells merge-gate.sh).
4. Reconcile state (PR, HEAD, reviewer, pending); verify stale agents and stalled
   transitions; launch as needed.
5. Resume monitoring — one heartbeat line, no report."
fi

# Emit the additionalContext. jq is preferred for correct JSON encoding; plain
# printf is a reliable fallback for environments where jq is not installed.
if command -v jq >/dev/null 2>&1; then
  jq -n --arg ctx "$CONTEXT" '{
    hookSpecificOutput: {
      hookEventName: "PostCompact",
      additionalContext: $ctx
    }
  }'
else
  # Minimal safe fallback: the context message contains no characters that would
  # break this simple substitution (no backslashes, no control characters), but
  # we escape double-quotes to be safe.
  CONTEXT_ESCAPED="${CONTEXT//\\/\\\\}"
  CONTEXT_ESCAPED="${CONTEXT_ESCAPED//\"/\\\"}"
  printf '{"hookSpecificOutput":{"hookEventName":"PostCompact","additionalContext":"%s"}}\n' \
    "${CONTEXT_ESCAPED//$'\n'/\\n}"
fi

exit 0
