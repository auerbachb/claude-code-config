#!/bin/bash
# Post-merge hook: pulls main in the root repo after a successful gh pr merge
# This keeps hardlinked rule files in ~/.claude/rules/ up to date
#
# Setup: Add this to ~/.claude/settings.json under "hooks":
#   {
#     "hooks": {
#       "PostToolUse": [{
#         "matcher": "Bash",
#         "hooks": [{
#           "type": "command",
#           "command": "<repo-root>/.claude/hooks/post-merge-pull.sh",
#           "timeout": 15
#         }]
#       }]
#     }
#   }

input=$(cat)

command=$(echo "$input" | jq -r '.tool_input.command')
exit_code=$(echo "$input" | jq -r '.tool_response.exitCode // 1' 2>/dev/null)

# Only act on successful gh pr merge commands
if [[ "$command" == *"gh pr merge"* ]] && [[ "$exit_code" == "0" ]]; then
  # Find the root repo (first entry from git worktree list)
  cwd=$(echo "$input" | jq -r '.cwd')
  if [[ -z "$cwd" || ! -d "$cwd" ]]; then
    exit 0
  fi
  root_repo=$(git -C "$cwd" worktree list --porcelain 2>/dev/null \
    | sed -n 's/^worktree //p' \
    | head -n 1)

  if [[ -n "$root_repo" && -d "$root_repo/.git" ]]; then
    # Pull main in the root repo (not the worktree)
    if ! git -C "$root_repo" pull origin main --ff-only >/dev/null 2>&1; then
      printf 'post-merge-pull: fast-forward pull failed in %s\n' "$root_repo" >&2
    fi
  fi
fi

exit 0
