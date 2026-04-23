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
setup_script="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." 2>/dev/null && pwd)/setup-skills-worktree.sh"
errors=""

# Bootstrap missing skills worktree if setup script is available
if [[ ! -d "$skills_wt/.claude/skills" || ! -f "$skills_wt/.git" ]]; then
  if [[ -x "$setup_script" || -f "$setup_script" ]]; then
    if ! err=$(bash "$setup_script" 2>&1); then
      errors="skills worktree setup failed: $err"
    fi
  fi
fi

if [[ -z "$errors" && -d "$skills_wt" && -f "$skills_wt/.git" ]]; then
  if ! err=$(git -C "$skills_wt" fetch origin main --quiet 2>&1); then
    errors="skills worktree fetch failed: $err"
  elif ! err=$(git -C "$skills_wt" reset --hard origin/main --quiet 2>&1); then
    errors="skills worktree reset failed: $err"
  fi
elif [[ -z "$errors" ]]; then
  errors="skills worktree not found at $skills_wt"
fi

# --- Sync root repo (derives path from skills worktree) ---
# Re-check skills worktree availability independently — fetch/reset errors above
# don't block this pull, and the root repo path is derived from the worktree.
if [[ -d "$skills_wt" && -f "$skills_wt/.git" ]]; then
  root_repo=$(git -C "$skills_wt" worktree list 2>/dev/null | head -1 | awk '{print $1}')
  if [[ -n "$root_repo" && -e "$root_repo/.git" ]]; then
    # Only pull if on main branch (don't disrupt feature branches).
    # Delegate the actual sync to main-sync.sh: exit 0 = updated/up-to-date,
    # exit 1 = benign skip (uncommitted tracked changes — leave the root repo
    # alone), exit 2 = hard failure. Only exit 2 is reported as an error.
    current_branch=$(git -C "$root_repo" branch --show-current 2>/dev/null)
    if [[ "$current_branch" == "main" ]]; then
      main_sync_script="$root_repo/.claude/scripts/main-sync.sh"
      # Match the `setup_script` guard on line 32: `-x` alone is too strict,
      # since `bash "$script"` only requires readability. Systems with
      # `core.filemode=false` or mounts that drop the exec bit would still
      # have a usable helper but the `-x` test would silently fall through
      # to the inline `git pull` fallback, losing main-sync.sh's status
      # reporting and error handling (see BugBot finding on PR #345).
      if [[ -x "$main_sync_script" || -f "$main_sync_script" ]]; then
        main_sync_out=$(bash "$main_sync_script" --repo "$root_repo" 2>&1)
        main_sync_rc=$?
        if [[ $main_sync_rc -eq 2 ]]; then
          errors="${errors:+$errors; }root repo sync failed: $main_sync_out"
        fi
      elif ! err=$(git -C "$root_repo" pull origin main --ff-only --quiet 2>&1); then
        errors="${errors:+$errors; }root repo pull failed: $err"
      fi
    fi
  else
    errors="${errors:+$errors; }root repo could not be resolved from skills worktree at $skills_wt"
  fi
fi

# --- Sync hooks from global-settings.json into ~/.claude/settings.json ---
# Ensures new hooks added to the template are auto-registered each session.
# Uses the same registration logic as setup-skills-worktree.sh Step 6.
# Matches by script basename to detect existing hooks; preserves user hooks
# and custom timeouts. No-op if root_repo is unavailable or template is missing.

if [[ -d "$skills_wt" && -f "$skills_wt/.git" ]]; then
  register_script="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)/register-hooks.py"
  if [[ -f "$register_script" ]]; then
    if ! err=$(python3 "$register_script" "$skills_wt" 2>&1); then
      errors="${errors:+$errors; }hook sync failed: $err"
    fi
  else
    errors="${errors:+$errors; }hook sync helper missing: $register_script"
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
