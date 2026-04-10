#!/bin/bash
# Worktree guard — PreToolUse hook
# Blocks Write/Edit/NotebookEdit when the current branch of the claude-code-config
# repo is `main`. Enforces the "ALWAYS USE A WORKTREE" rule mechanically.
#
# Hook contract (PreToolUse):
#   stdin  — JSON with {tool_name, tool_input, cwd, ...}
#   stdout — JSON with hookSpecificOutput.permissionDecision ("deny" to block)
#   exit 0 — always (decision is carried in the JSON, not the exit code)

set -u

INPUT=$(cat 2>/dev/null || true)

# Fail open if python3 is unavailable — never block work on tooling gaps
if ! command -v python3 >/dev/null 2>&1; then
  exit 0
fi

# Parse cwd and tool_name from the hook input JSON via stdin (safe for any content)
PARSED=$(printf '%s' "$INPUT" | python3 -c '
import json, sys
try:
    d = json.loads(sys.stdin.read() or "{}")
except Exception:
    print("|")
    sys.exit(0)
cwd = (d.get("cwd") or "").replace("\n", " ").replace("\r", " ")
tool = (d.get("tool_name") or "").replace("\n", " ").replace("\r", " ")
print(f"{cwd}|{tool}")
' 2>/dev/null)

CWD="${PARSED%|*}"
TOOL_NAME="${PARSED##*|}"

[ -z "$CWD" ] && exit 0

case "$TOOL_NAME" in
  Write|Edit|NotebookEdit) ;;
  *) exit 0 ;;
esac

TOPLEVEL=$(git -C "$CWD" rev-parse --show-toplevel 2>/dev/null || true)
[ -z "$TOPLEVEL" ] && exit 0

# Scope enforcement to the claude-code-config repo only. The hook is registered
# globally in ~/.claude/settings.json, but we only want to block writes on main
# for this specific repo. Match the repo name as a full path component so paths
# like /foo/claude-code-config-fork/bar do NOT trigger the guard.
case "$TOPLEVEL" in
  */claude-code-config|*/claude-code-config/*) ;;
  *) exit 0 ;;
esac

BRANCH=$(git -C "$CWD" branch --show-current 2>/dev/null || true)

if [ "$BRANCH" = "main" ]; then
  python3 -c '
import json
print(json.dumps({
    "hookSpecificOutput": {
        "hookEventName": "PreToolUse",
        "permissionDecision": "deny",
        "permissionDecisionReason": (
            "BLOCKED: Cannot write files on main branch in claude-code-config. "
            "Use EnterWorktree to create a worktree first. "
            "See CLAUDE.md \"ALWAYS USE A WORKTREE\" section."
        ),
    }
}))
'
  exit 0
fi

exit 0
