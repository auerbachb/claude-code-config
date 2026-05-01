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

# Defense-in-depth: also filter here in case the matcher in global-settings.json
# is ever widened or the script is invoked directly during testing.
case "$TOOL_NAME" in
  Write|Edit|NotebookEdit) ;;
  *) exit 0 ;;
esac

TOPLEVEL=$(git -C "$CWD" rev-parse --show-toplevel 2>/dev/null || true)
[ -z "$TOPLEVEL" ] && exit 0

# Scope enforcement to the claude-code-config repo only. The hook is registered
# globally in ~/.claude/settings.json, but we only want to block writes on main
# for this specific repo. Match the repo's canonical directory name as a full
# path component:
#   - Excludes forks like /foo/claude-code-config-fork/bar (requires literal
#     /claude-code-config trailing segment or /claude-code-config/ prefix segment)
#   - Excludes clones under alternate names (e.g., ~/my-config) — intentional
#     trade-off: the guard only protects the canonical directory name
case "$TOPLEVEL" in
  */claude-code-config|*/claude-code-config/*) ;;
  *) exit 0 ;;
esac

BRANCH=$(git -C "$CWD" branch --show-current 2>/dev/null || true)

if [ "$BRANCH" = "main" ]; then
  # If this python3 invocation fails for any reason (transient crash, etc.),
  # the hook exits 0 with empty stdout — the framework treats that as "allow"
  # (fail-open). The inline script is trivially simple so this is unlikely.
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
