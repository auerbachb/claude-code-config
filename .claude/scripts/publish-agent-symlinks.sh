#!/bin/bash
# publish-agent-symlinks.sh — Publish ~/.claude/agents/ symlinks from the skills worktree
#
# Extracted from setup-skills-worktree.sh Step 5b (issue #1197) so that
# session-start-sync.sh can run the same idempotent publish on every session
# start, not only during the initial bootstrap path.
#
# Usage: publish-agent-symlinks.sh <skills-worktree> [<repo-root>]
#
# Arguments:
#   skills-worktree  Absolute path to ~/.claude/skills-worktree
#   repo-root        (optional) Root repo path; used only to recognise legacy
#                    root-repo symlinks that pre-date the worktree topology and
#                    should be migrated. Pass "" or omit when unknown — the
#                    script still publishes all worktree-backed symlinks.
#
# Stdout:  Human-readable progress lines (suitable for folding into hook
#          additionalContext or setup script output)
# Stderr:  Warnings for non-fatal conditions
# Exit 0:  Success, including when the worktree has no .claude/agents/ directory
# Exit 1:  Unexpected failure (a symlink could not be created or removed)
#
# Idempotent — safe to run every session. Preserves user-owned symlinks
# (targets outside the skills worktree) per the ownership rule from PR #1196.

set -euo pipefail

SKILLS_WORKTREE="${1:?publish-agent-symlinks.sh: SKILLS_WORKTREE argument not provided}"
REPO_ROOT="${2:-}"
AGENTS_DIR="$HOME/.claude/agents"
WORKTREE_AGENTS="$SKILLS_WORKTREE/.claude/agents"

# --- Helper: migrate_symlink ---
# Manages one symlink, handling all five states:
#   already-correct target   → no-op (silent)
#   legacy LEGACY_TARGET     → migrate if NEW_TARGET exists; warn if not
#   any other symlink target → repoint to NEW_TARGET
#   non-symlink regular file → warn, never overwrite
#   missing                  → create if NEW_TARGET passes EXISTENCE_TEST
#
# Usage: migrate_symlink LINK NEW_TARGET LEGACY_TARGET LABEL EXISTENCE_TEST
#   LEGACY_TARGET may be empty to skip the legacy-migration branch.
migrate_symlink() {
  local link="$1" new_target="$2" legacy_target="$3" label="$4" existence_test="$5"

  if [[ -L "$link" ]]; then
    local current_target
    current_target="$(readlink "$link")"
    if [[ "$current_target" == "$new_target" ]]; then
      : # already correct — silent no-op
    elif [[ -n "$legacy_target" && "$current_target" == "$legacy_target" ]]; then
      if test "$existence_test" "$new_target"; then
        echo "  $label — migrating from root repo to worktree"
        rm "$link"
        ln -s "$new_target" "$link"
      else
        echo "  $label — WARNING: legacy root-repo symlink exists but target not in worktree (agent may not be on main yet)" >&2
      fi
    else
      echo "  $label — updating symlink (was: $current_target)"
      rm "$link"
      ln -s "$new_target" "$link"
    fi
  elif [[ -e "$link" ]]; then
    echo "  WARNING: $link is not a symlink — skipping (will not overwrite)" >&2
  else
    if test "$existence_test" "$new_target"; then
      echo "  $label — creating"
      ln -s "$new_target" "$link"
    fi
  fi
}

# --- Helper: owned_by_setup ---
# Returns true (exit 0) when the symlink target is one this script manages —
# i.e., it points into the skills worktree or into the legacy root-repo agents
# directory that is being migrated away from. Used by both the publish and prune
# loops to leave user-owned symlinks untouched.
owned_by_setup() {
  local target="$1"
  [[ "$target" == "$WORKTREE_AGENTS/"* ]] && return 0
  [[ -n "$REPO_ROOT" && "$target" == "$REPO_ROOT/.claude/agents/"* ]] && return 0
  return 1
}

# Detect brand-new agents/ directory creation. Claude Code cannot pick up a
# directory that did not exist at session start without a restart.
agents_dir_created=false
[[ -d "$AGENTS_DIR" ]] || agents_dir_created=true
mkdir -p "$AGENTS_DIR"

if [[ -d "$WORKTREE_AGENTS" ]]; then
  # --- Publish loop: create / update symlinks for each agent definition ---
  for agent_file in "$WORKTREE_AGENTS"/*.md; do
    [[ -f "$agent_file" ]] || continue

    agent_name="$(basename "$agent_file")"
    link="$AGENTS_DIR/$agent_name"

    # README.md documents the directory; it is not an agent definition.
    [[ "$agent_name" == "README.md" ]] && continue

    # A symlink pointing somewhere we do not manage is the user's — leave it and
    # say so rather than silently clobbering custom user definitions.
    if [[ -L "$link" ]] && ! owned_by_setup "$(readlink "$link")"; then
      echo "  $agent_name — leaving user-owned symlink alone (-> $(readlink "$link"))"
      continue
    fi

    legacy_target=""
    [[ -n "$REPO_ROOT" ]] && legacy_target="$REPO_ROOT/.claude/agents/$agent_name"
    migrate_symlink "$link" "$agent_file" "$legacy_target" "$agent_name" -f
  done
# else: worktree has no agent definitions (or directory was removed) — skip
# publish but fall through to the prune loop so stale setup-owned symlinks
# for deleted agents are removed rather than remaining exposed in user scope.
fi

# --- Prune loop: remove stale symlinks for agents renamed or removed on main ---
# Runs even when WORKTREE_AGENTS is absent so that a complete removal of the
# agents directory propagates to user scope.
# Glob without trailing slash so dangling symlinks (broken links are not
# directories) are included.
for link in "$AGENTS_DIR"/*; do
  [[ -e "$link" || -L "$link" ]] || continue
  [[ -L "$link" ]] || continue
  agent_name="$(basename "$link")"
  owned_by_setup "$(readlink "$link")" || continue
  if [[ ! -f "$WORKTREE_AGENTS/$agent_name" ]]; then
    echo "  $agent_name — removing stale symlink (no matching agent in worktree)"
    rm "$link" || echo "  WARNING: could not remove $link — remove it manually" >&2
  fi
done

# Surface the restart caveat when the directory is newly created. The file
# watcher does not cover a directory that did not exist at session start, so
# the agent types won't register until the next session.
if [[ "$agents_dir_created" == true ]]; then
  echo "NOTE: ~/.claude/agents/ was just created. Restart your Claude Code session"
  echo "      for the agent types to register (see .claude/agents/README.md)."
fi
