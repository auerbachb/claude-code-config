#!/bin/bash
# Worktree guard — PreToolUse hook
# Blocks Write/Edit/NotebookEdit when the TARGET FILE resolves into a
# claude-code-config checkout whose current branch is `main`. Enforces the
# "ALWAYS USE A WORKTREE" rule mechanically without blocking writes that land
# outside the repo (session scratchpad, ~/.claude memory, other repos) when
# the session cwd happens to be on main — see issue #549.
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

# Parse tool_name, cwd, and the tool's target path from the hook input JSON.
# Output protocol: four newline-separated fields — tool, cwd, anchor, target.
#   anchor — nearest EXISTING ancestor directory of the resolved target; git
#            queries run there (Write targets and their parent dirs may not
#            exist yet). Empty when no target path could be parsed — bash then
#            falls back to the legacy cwd-based check so malformed tool_input
#            cannot bypass the guard.
#   target — resolved absolute target path, used in the deny message only.
PARSED=$(printf '%s' "$INPUT" | python3 -c '
import json, os, sys

def clean(s):
    return (s or "").replace("\n", " ").replace("\r", " ")

def emit(tool="", cwd="", anchor="", target=""):
    print(clean(tool))
    print(clean(cwd))
    # A newline inside a real directory name would corrupt the line protocol;
    # treat such a path as unparseable (legacy fallback) instead of mis-parsing.
    print(anchor if anchor == clean(anchor) else "")
    print(clean(target))

def as_str(v):
    # Coerce non-string metadata to "" instead of crashing the helper —
    # a crash here would empty PARSED and fail the guard open.
    return v if isinstance(v, str) else ""

try:
    d = json.loads(sys.stdin.read() or "{}")
except Exception:
    d = None
if not isinstance(d, dict):
    d = {}

cwd = as_str(d.get("cwd"))
tool = as_str(d.get("tool_name"))
ti = d.get("tool_input") or d.get("toolInput") or {}
if not isinstance(ti, dict):
    ti = {}
target = as_str(ti.get("file_path")) or as_str(ti.get("notebook_path"))

anchor = ""
resolved = ""
if target:
    if os.path.isabs(target):
        p = target
    else:
        p = os.path.join(cwd, target) if cwd else ""
    if p:
        # realpath: normalize + resolve symlinks; safe for non-existent paths
        resolved = os.path.realpath(p)
        probe = resolved
        while probe and not os.path.isdir(probe):
            parent = os.path.dirname(probe)
            if parent == probe:
                break
            probe = parent
        if os.path.isdir(probe):
            anchor = probe

emit(tool, cwd, anchor, resolved)
' 2>/dev/null)

TOOL_NAME=$(printf '%s\n' "$PARSED" | sed -n '1p')
CWD=$(printf '%s\n' "$PARSED" | sed -n '2p')
ANCHOR=$(printf '%s\n' "$PARSED" | sed -n '3p')
TARGET=$(printf '%s\n' "$PARSED" | sed -n '4p')

# Defense-in-depth: also filter here in case the matcher in global-settings.json
# is ever widened or the script is invoked directly during testing.
case "$TOOL_NAME" in
  Write|Edit|NotebookEdit) ;;
  *) exit 0 ;;
esac

# No parseable target path: fall back to the legacy cwd-based check.
if [ -z "$ANCHOR" ]; then
  ANCHOR="$CWD"
fi
[ -z "$ANCHOR" ] && exit 0

TOPLEVEL=$(git -C "$ANCHOR" rev-parse --show-toplevel 2>/dev/null || true)
[ -z "$TOPLEVEL" ] && exit 0

# Scope enforcement to the claude-code-config repo only. The hook is registered
# globally in ~/.claude/settings.json, but we only want to block writes into
# main for this specific repo. Match the repo's canonical directory name as a
# full path component:
#   - Excludes forks like /foo/claude-code-config-fork/bar (requires literal
#     /claude-code-config trailing segment or /claude-code-config/ prefix segment)
#   - Excludes clones under alternate names (e.g., ~/my-config) — intentional
#     trade-off: the guard only protects the canonical directory name
#   - Linked worktrees under .claude/worktrees/ still match the pattern, but
#     their own checked-out branch (not main's) is what gets evaluated below.
case "$TOPLEVEL" in
  */claude-code-config|*/claude-code-config/*) ;;
  *) exit 0 ;;
esac

BRANCH=$(git -C "$ANCHOR" branch --show-current 2>/dev/null || true)

if [ "$BRANCH" = "main" ]; then
  # If this python3 invocation fails for any reason (transient crash, etc.),
  # the hook exits 0 with empty stdout — the framework treats that as "allow"
  # (fail-open). The inline script is trivially simple so this is unlikely.
  TARGET_DISPLAY="$TARGET" python3 -c '
import json, os
target = os.environ.get("TARGET_DISPLAY") or ""
suffix = " (target: %s)" % target if target else ""
print(json.dumps({
    "hookSpecificOutput": {
        "hookEventName": "PreToolUse",
        "permissionDecision": "deny",
        "permissionDecisionReason": (
            "BLOCKED: Cannot write files on main branch in claude-code-config"
            + suffix + ". "
            "Use EnterWorktree to create a worktree first. "
            "See CLAUDE.md \"ALWAYS USE A WORKTREE\" section."
        ),
    }
}))
'
  exit 0
fi

exit 0
