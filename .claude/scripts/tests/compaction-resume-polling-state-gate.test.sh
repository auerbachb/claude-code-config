#!/usr/bin/env bash
# Simulated compaction test for polling-state-gate.sh (issue #315).
# Uses a temporary HOME — does not touch ~/.claude/. Requires jq + git.
set -euo pipefail

TMP_HOME="$(mktemp -d)"
cleanup() { rm -rf "$TMP_HOME"; }
trap cleanup EXIT

export HOME="$TMP_HOME"
mkdir -p "$HOME/.claude/handoffs"

REPO_ROOT="$(git rev-parse --show-toplevel)"
SCRIPT="$REPO_ROOT/.claude/scripts/polling-state-gate.sh"

PR_NUM="99001"
# Minimal session + handoff as if parent had run --ensure-session
cat > "$HOME/.claude/session-state.json" <<EOF
{
  "root_repo": "$REPO_ROOT",
  "prs": {
    "$PR_NUM": {
      "root_repo": "$REPO_ROOT",
      "head_sha": "deadbeef",
      "reviewer": "cr"
    }
  }
}
EOF
cp "$REPO_ROOT/.claude/reference/handoff-file-schema.json" "$HOME/.claude/handoffs/pr-${PR_NUM}-handoff.json"
# Align pr_number and head_sha with session-state (verify-state checks consistency).
tmp="$(mktemp)"
jq --argjson p "$PR_NUM" --arg sha "deadbeef" '.pr_number = $p | .head_sha = $sha' \
  "$HOME/.claude/handoffs/pr-${PR_NUM}-handoff.json" > "$tmp"
mv "$tmp" "$HOME/.claude/handoffs/pr-${PR_NUM}-handoff.json"

# Simulate compaction (lost in-memory context): verify offline gate passes
"$SCRIPT" "$PR_NUM" --verify-state --root-repo "$REPO_ROOT"

# Second verify — idempotent "resume"
"$SCRIPT" "$PR_NUM" --verify-state --root-repo "$REPO_ROOT"

echo "OK: compaction-resume simulation passed (handoff + session-state + root_repo consistency)"
