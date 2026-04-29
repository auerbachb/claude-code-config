#!/bin/bash
# Stale worktree warning — UserPromptSubmit hook.
# Warns before the agent acts when the submitted prompt names an issue that
# does not match the currently checked-out worktree branch.

INPUT=$(cat 2>/dev/null || true)

# Fail open: missing python/git or malformed hook input should not block work.
if ! command -v python3 >/dev/null 2>&1 || ! command -v git >/dev/null 2>&1; then
  echo '{}'
  exit 0
fi

INPUT="$INPUT" python3 <<'PY'
import json
import os
import re
import subprocess
import sys


def empty():
    print("{}")
    sys.exit(0)


try:
    payload = json.loads(os.environ.get("INPUT", "") or "{}")
except Exception:
    empty()

cwd = payload.get("cwd") or ""
if not cwd:
    empty()

prompt = payload.get("prompt") or payload.get("message") or ""


def git(args):
    try:
        return subprocess.check_output(
            ["git", "-C", cwd, *args],
            stderr=subprocess.DEVNULL,
            text=True,
        ).strip()
    except Exception:
        return ""


toplevel = git(["rev-parse", "--show-toplevel"])
branch = git(["branch", "--show-current"])
worktrees = git(["worktree", "list", "--porcelain"])
if not toplevel or not branch or not worktrees:
    empty()

main_worktree = ""
for line in worktrees.splitlines():
    if line.startswith("worktree "):
        main_worktree = line.split(" ", 1)[1]
        break

# Root repo sessions still have their own main/worktree gate in CLAUDE.md. This
# hook focuses on the failure mode where the harness starts inside a stale linked
# worktree and the prompt names a different issue.
if not main_worktree or os.path.realpath(toplevel) == os.path.realpath(main_worktree):
    empty()

issue_matches = re.findall(r"(?:issues?/|issue\s*#?|#)(\d+)\b", prompt, re.IGNORECASE)
if not issue_matches:
    empty()

branch_match = re.search(r"(?:^|[/-])issue-(\d+)(?:\b|-)", branch)
branch_issue = branch_match.group(1) if branch_match else ""

# If the branch issue matches any issue mentioned in the prompt, no warning needed.
if branch_issue and branch_issue in issue_matches:
    empty()

prompt_issue = issue_matches[0]

if branch_issue:
    mismatch = f"current branch '{branch}' is for issue #{branch_issue}, but the prompt names issue #{prompt_issue}"
else:
    mismatch = f"current branch '{branch}' does not include issue #{prompt_issue}"

message = (
    "STALE WORKTREE CHECK: STOP before making edits: "
    f"{mismatch}. Return to the root repo, sync main, and create a fresh "
    "issue-matching worktree. See CLAUDE.md 'ALWAYS USE A WORKTREE'."
)

print(json.dumps({
    "hookSpecificOutput": {
        "hookEventName": "UserPromptSubmit",
        "additionalContext": message,
    }
}))
PY

exit 0
