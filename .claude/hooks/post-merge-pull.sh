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
#           "command": "~/.claude/hooks/post-merge-pull.sh",
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

  root_repo=""

  # Strategy 1: Use $cwd to find root repo via git worktree list
  cwd=$(echo "$input" | jq -r '.cwd')
  if [[ -n "$cwd" && -d "$cwd" ]]; then
    root_repo=$(git -C "$cwd" worktree list --porcelain 2>/dev/null \
      | sed -n 's/^worktree //p' \
      | head -n 1)
  fi

  # Strategy 2: Resolve this script's location to find the repo it lives in
  if [[ -z "$root_repo" || ! -d "$root_repo/.git" ]]; then
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    # Walk up from .claude/hooks/ to find the repo root
    candidate="${script_dir%/.claude/hooks}"
    if [[ "$candidate" != "$script_dir" && -d "$candidate/.git" ]]; then
      root_repo=$(git -C "$candidate" worktree list --porcelain 2>/dev/null \
        | sed -n 's/^worktree //p' \
        | head -n 1)
    fi
  fi

  # Strategy 3: Extract repo name from the gh command and search common locations
  if [[ -z "$root_repo" || ! -d "$root_repo/.git" ]]; then
    # gh pr merge often runs in a repo context — try to extract from git remote
    # in the cwd (even if the dir exists but worktree list failed)
    if [[ -n "$cwd" && -d "$cwd" ]]; then
      repo_name=$(git -C "$cwd" remote get-url origin 2>/dev/null \
        | sed 's|.*/||; s|\.git$||')
      if [[ -n "$repo_name" ]]; then
        for base in "$HOME/Documents/Develop" "$HOME/repos" "$HOME/projects" "$HOME/src"; do
          if [[ -d "$base/$repo_name/.git" ]]; then
            root_repo="$base/$repo_name"
            break
          fi
        done
      fi
    fi
  fi

  # Pull if we found the root repo
  if [[ -n "$root_repo" && -d "$root_repo/.git" ]]; then
    if ! git -C "$root_repo" pull origin main --ff-only >/dev/null 2>&1; then
      printf 'post-merge-pull: fast-forward pull failed in %s\n' "$root_repo" >&2
    fi
  else
    # Visible warning instead of silent exit
    printf 'post-merge-pull: could not find root repo (cwd=%s). Local main may be stale.\n' "$cwd" >&2
  fi
fi

exit 0
