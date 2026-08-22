#!/bin/bash
# Session-start sync — SessionStart hook (fires at session start and on resume)
# Syncs the skills worktree and root repo to ensure skills, rules, and
# CLAUDE.md are up to date with origin/main. Runs on every session start
# (fresh session, resume, clear, compact, fork).

# Consume stdin (required by hook protocol) and keep it: SessionStart carries
# a `source` telling us WHY it fired — startup | resume | clear | compact.
# Only `startup` is a genuinely new session; the rest fire inside a live one.
hook_stdin=$(cat)
session_source=$(jq -r '.source // empty' <<<"$hook_stdin" 2>/dev/null)

# --- Sync skills worktree ---
skills_wt="$HOME/.claude/skills-worktree"
setup_script="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." 2>/dev/null && pwd)/setup-skills-worktree.sh"
errors=""
_agents_notices=""

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

# --- Publish agent symlinks on the steady-state path (issue #1197) ---
# git reset --hard above updates worktree contents (including .claude/agents/)
# but never creates ~/.claude/agents/ or its per-file symlinks. Run the publish
# every session so new, renamed, and removed agent definitions propagate without
# requiring a manual setup-skills-worktree.sh run on existing installs.
if [[ -z "$errors" && -d "$skills_wt" && -f "$skills_wt/.git" ]]; then
  _agents_publish_script="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)/../scripts/publish-agent-symlinks.sh"
  if [[ -f "$_agents_publish_script" ]]; then
    _root_repo=$(git -C "$skills_wt" worktree list 2>/dev/null | head -1 | awk '{print $1}') || _root_repo=""
    if ! _agents_out=$(bash "$_agents_publish_script" "$skills_wt" "${_root_repo}" 2>&1); then
      errors="${errors:+$errors; }agent symlink publish failed: $_agents_out"
    elif [[ -n "$_agents_out" ]]; then
      _agents_notices="$_agents_out"
    fi
  fi
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

# --- Reconcile durable scheduling state (issue #827) ---
# CronCreate jobs are in-memory and die with the session that armed them, so
# every job this file recorded before now is already gone. Purge that dead
# bookkeeping and surface the durable on-disk records that DID survive (an
# overdue harness-audit, a paused PR fleet). Fail-soft by contract — the
# script always exits 0, and any failure here must not block the session.

# Resolved from this hook's own location, not from the skills worktree: the
# reconciler reads session-state, so a broken or missing worktree — exactly
# when stale bookkeeping is most likely — must not also suppress the cleanup.
#
# Purge ONLY on `startup`. compact/resume/clear fire inside a live session,
# where a job or watcher recorded in state may still be running: clearing its
# bookkeeping there orphans a live job, and deciding a watcher is dead races
# the tick that is about to refresh it. On a true startup neither is possible —
# nothing from the previous session survived — so the purge is unambiguous.
# An absent `source` (older harness) is treated as NOT startup: a stale record
# lingering one more session is strictly cheaper than clearing a live one.
notices=""
reconcile_script="$(cd "$(dirname "${BASH_SOURCE[0]}")/../scripts" 2>/dev/null && pwd)/session-scheduling-reconcile.sh"
if [[ -f "$reconcile_script" ]]; then
  if [[ "$session_source" == "startup" ]]; then
    notices=$(bash "$reconcile_script" 2>/dev/null)
  else
    notices=$(bash "$reconcile_script" --check 2>/dev/null)
  fi
fi

# Fold agent-publish notices into the notices variable before sanitization so
# they reach the user when no other notices are present.
if [[ -n "$_agents_notices" ]]; then
  if [[ -n "$notices" ]]; then
    notices="${notices}
${_agents_notices}"
  else
    notices="$_agents_notices"
  fi
fi

# Strip control characters before they reach jq. `$errors` carries raw git
# stderr, and a clone/fetch progress meter emits carriage returns and escape
# sequences — noise that lands verbatim in the context block, on exactly the
# first run in a fresh HOME when the sync warning matters most.
# CR (\015) is inside the deleted set: it is the character progress meters
# actually emit, so leaving it out would have made this scrub miss its target.
# Tab (\011) and newline (\012) are preserved — they carry real formatting.
errors=$(printf '%s' "$errors" | LC_ALL=C tr -d '\000-\010\013-\015\016-\037')
notices=$(printf '%s' "$notices" | LC_ALL=C tr -d '\000-\010\013-\015\016-\037')

# Report result
if [[ -n "$errors" ]]; then
  jq -n --arg errors "$errors" --arg notices "$notices" '{
    hookSpecificOutput: {
      hookEventName: "SessionStart",
      additionalContext: ("SESSION SYNC WARNING: Config sync encountered errors: " + $errors + ". Skills, rules, or CLAUDE.md may be stale. Run manually: git -C ~/.claude/skills-worktree fetch origin main && git -C ~/.claude/skills-worktree reset --hard origin/main" + (if $notices == "" then "" else "\n\n" + $notices end))
    }
  }'
elif [[ -n "$notices" ]]; then
  jq -n --arg notices "$notices" '{
    hookSpecificOutput: {
      hookEventName: "SessionStart",
      additionalContext: $notices
    }
  }'
else
  echo '{}'
fi

exit 0
