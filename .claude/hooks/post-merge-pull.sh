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
#           "command": "/absolute/path/to/repo/.claude/hooks/post-merge-pull.sh",
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
  if [[ -z "$root_repo" || ! -e "$root_repo/.git" ]]; then
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    # Walk up from .claude/hooks/ to find the repo root
    candidate="${script_dir%/.claude/hooks}"
    if [[ "$candidate" != "$script_dir" && -e "$candidate/.git" ]]; then
      root_repo=$(git -C "$candidate" worktree list --porcelain 2>/dev/null \
        | sed -n 's/^worktree //p' \
        | head -n 1)
    fi
  fi

  # Strategy 3: Extract repo name from the gh command and search common locations
  if [[ -z "$root_repo" || ! -e "$root_repo/.git" ]]; then
    # gh pr merge often runs in a repo context — try to extract from git remote
    # in the cwd (even if the dir exists but worktree list failed)
    if [[ -n "$cwd" && -d "$cwd" ]]; then
      repo_name=$(git -C "$cwd" remote get-url origin 2>/dev/null \
        | sed 's|.*/||; s|\.git$||')
      if [[ -n "$repo_name" ]]; then
        for base in "$HOME/Documents/Develop" "$HOME/repos" "$HOME/projects" "$HOME/src"; do
          if [[ -e "$base/$repo_name/.git" ]]; then
            root_repo="$base/$repo_name"
            break
          fi
        done
      fi
    fi
  fi

  pull_errors=""

  # Pull if we found the root repo
  if [[ -n "$root_repo" && -e "$root_repo/.git" ]]; then
    if ! err=$(git -C "$root_repo" pull origin main --ff-only 2>&1); then
      pull_errors="root repo pull failed in $root_repo: $err"
    fi

    # --- Sync skills worktree (if it exists) ---
    skills_wt="$HOME/.claude/skills-worktree"
    sync_errors=""

    if [[ ! -d "$skills_wt" ]]; then
      sync_errors="skills worktree not found at $skills_wt"
    elif [[ ! -f "$skills_wt/.git" ]]; then
      sync_errors="skills worktree at $skills_wt is not a valid git directory"
    else
      # Verify it belongs to the same repo
      wt_root="$(git -C "$skills_wt" worktree list 2>/dev/null | head -1 | awk '{print $1}')"
      if [[ "$wt_root" == "$root_repo" ]]; then
        if ! err=$(git -C "$skills_wt" fetch origin main --quiet 2>&1); then
          sync_errors="skills worktree fetch failed: $err"
        elif ! err=$(git -C "$skills_wt" reset --hard origin/main --quiet 2>&1); then
          sync_errors="skills worktree reset failed: $err"
        fi

        # Re-symlink any new or stale skills
        skills_src="$skills_wt/.claude/skills"
        skills_dir="$HOME/.claude/skills"
        if [[ -d "$skills_src" && -d "$skills_dir" ]]; then
          for skill_dir in "$skills_src"/*/; do
            [[ -d "$skill_dir" ]] || continue
            name="$(basename "$skill_dir")"
            link="$skills_dir/$name"
            target="$skills_src/$name"
            if [[ -L "$link" ]]; then
              # Replace stale symlinks pointing elsewhere
              [[ "$(readlink "$link")" == "$target" ]] && continue
              rm "$link" 2>/dev/null || true
            elif [[ -e "$link" ]]; then
              # Skip non-symlink entries (directories/copies) — setup script handles these
              continue
            fi
            ln -s "$target" "$link" 2>/dev/null || true
          done
        fi

        # Verify/refresh CLAUDE.md and rules symlinks
        claude_md_link="$HOME/.claude/CLAUDE.md"
        claude_md_target="$skills_wt/CLAUDE.md"
        if [[ -L "$claude_md_link" ]]; then
          if [[ "$(readlink "$claude_md_link")" != "$claude_md_target" && -f "$claude_md_target" ]]; then
            rm "$claude_md_link" 2>/dev/null || true
            ln -s "$claude_md_target" "$claude_md_link" 2>/dev/null || true
          fi
        elif [[ ! -e "$claude_md_link" && -f "$claude_md_target" ]]; then
          ln -s "$claude_md_target" "$claude_md_link" 2>/dev/null || true
        elif [[ -e "$claude_md_link" ]]; then
          sync_errors="${sync_errors:+$sync_errors; }$claude_md_link exists and is not a symlink (left unchanged)"
        fi

        rules_link="$HOME/.claude/rules"
        rules_target="$skills_wt/.claude/rules"
        if [[ -L "$rules_link" ]]; then
          if [[ "$(readlink "$rules_link")" != "$rules_target" && -d "$rules_target" ]]; then
            rm "$rules_link" 2>/dev/null || true
            ln -s "$rules_target" "$rules_link" 2>/dev/null || true
          fi
        elif [[ ! -e "$rules_link" && -d "$rules_target" ]]; then
          ln -s "$rules_target" "$rules_link" 2>/dev/null || true
        elif [[ -e "$rules_link" ]]; then
          sync_errors="${sync_errors:+$sync_errors; }$rules_link exists and is not a symlink (left unchanged)"
        fi
      else
        sync_errors="skills worktree belongs to different repo ($wt_root)"
      fi
    fi

    # Output JSON warning if sync had errors
    if [[ -n "$sync_errors" ]]; then
      jq -n --arg err "$sync_errors" '{
        hookSpecificOutput: {
          hookEventName: "PostToolUse",
          additionalContext: ("POST-MERGE SYNC WARNING: " + $err + ". Skills, rules, or CLAUDE.md may be stale after merge.")
        }
      }'
      exit 0
    fi
  else
    pull_errors="could not find root repo (cwd=$cwd). Local main may be stale."
  fi

  # Report pull-level errors via JSON additionalContext
  if [[ -n "$pull_errors" ]]; then
    jq -n --arg err "$pull_errors" '{
      hookSpecificOutput: {
        hookEventName: "PostToolUse",
        additionalContext: ("POST-MERGE PULL WARNING: " + $err)
      }
    }'
    exit 0
  fi
fi

exit 0
