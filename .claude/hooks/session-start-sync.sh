#!/bin/bash
# Session-start sync — PostToolUse hook (fires after every tool call)
# Syncs the skills worktree and root repo ONCE per session to ensure
# skills, rules, and CLAUDE.md are up to date with origin/main.
#
# Uses a sentinel file to run only once per session.

# Consume stdin (required by hook protocol)
cat > /dev/null

# Session-scoped sentinel file
session_id="${CLAUDE_SESSION_ID:-${PPID:-$$}}"
session_id="${session_id//[^[:alnum:]_.-]/_}"
sentinel="/tmp/claude-config-synced-${session_id}"

# Already synced this session — exit fast
if [[ -f "$sentinel" ]]; then
  echo '{}'
  exit 0
fi

# Mark as synced (even if sync fails — don't retry every tool call)
touch "$sentinel"

# --- Sync skills worktree ---
skills_wt="$HOME/.claude/skills-worktree"
errors=""

if [[ -d "$skills_wt" && -f "$skills_wt/.git" ]]; then
  if ! err=$(git -C "$skills_wt" fetch origin main --quiet 2>&1); then
    errors="skills worktree fetch failed: $err"
  elif ! err=$(git -C "$skills_wt" reset --hard origin/main --quiet 2>&1); then
    errors="skills worktree reset failed: $err"
  fi
else
  errors="skills worktree not found at $skills_wt"
fi

# --- Sync root repo (derives path from skills worktree) ---
if [[ -d "$skills_wt" && -f "$skills_wt/.git" ]]; then
  root_repo=$(git -C "$skills_wt" worktree list 2>/dev/null | head -1 | awk '{print $1}')
  if [[ -n "$root_repo" && -e "$root_repo/.git" ]]; then
    # Only pull if on main branch (don't disrupt feature branches)
    current_branch=$(git -C "$root_repo" branch --show-current 2>/dev/null)
    if [[ "$current_branch" == "main" ]]; then
      if ! err=$(git -C "$root_repo" pull origin main --ff-only --quiet 2>&1); then
        errors="${errors:+$errors; }root repo pull failed: $err"
      fi
    fi
  else
    errors="${errors:+$errors; }root repo could not be resolved from skills worktree at $skills_wt"
  fi
fi

# Report result
if [[ -n "$errors" ]]; then
  jq -n --arg errors "$errors" '{
    hookSpecificOutput: {
      hookEventName: "PostToolUse",
      additionalContext: ("SESSION SYNC WARNING: Config sync encountered errors: " + $errors + ". Skills, rules, or CLAUDE.md may be stale. Run manually: git -C ~/.claude/skills-worktree fetch origin main && git -C ~/.claude/skills-worktree reset --hard origin/main")
    }
  }'
else
  echo '{}'
fi

exit 0
