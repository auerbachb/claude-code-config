#!/bin/bash
# setup-skills-worktree.sh — Create a dedicated worktree for serving skill symlinks
#
# Problem: Skills are symlinked from ~/.claude/skills/<name> to the root repo's
# .claude/skills/<name>. When the root repo isn't on main (e.g., left on a feature
# branch), symlinks break for skills added after that branch was created.
#
# Solution: A dedicated worktree at ~/.claude/skills-worktree/ that always tracks
# main. Symlinks point here instead of the root repo, so skills are available
# regardless of what branch the root repo is on.
#
# This script is idempotent — safe to run multiple times.

set -euo pipefail

SKILLS_WORKTREE="$HOME/.claude/skills-worktree"
SKILLS_DIR="$HOME/.claude/skills"

# Locate the script dir so we can invoke the repo-root helper by absolute path,
# independent of the caller's cwd.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT_HELPER="$SCRIPT_DIR/.claude/scripts/repo-root.sh"

# Find the repo root (works from anywhere inside the repo or a worktree).
# Prefer the shared helper; fall back to the inline one-liner when the helper
# file isn't on disk yet (e.g., this script was copied into a bare clone).
if [[ -x "$REPO_ROOT_HELPER" ]]; then
  REPO_ROOT="$("$REPO_ROOT_HELPER" 2>/dev/null)" || true
else
  REPO_ROOT="$(git worktree list --porcelain 2>/dev/null | awk '/^worktree /{sub(/^worktree /, ""); print; exit}')" || true
fi

if [[ -z "$REPO_ROOT" || ! -d "$REPO_ROOT/.git" ]]; then
  echo "ERROR: Could not find the root repo. Run this from inside the claude-code-config repo." >&2
  exit 1
fi

echo "Root repo: $REPO_ROOT"

# --- Shared helper: migrate_symlink ---
# Manages one symlink, handling all five states in one place so Steps 4 and 5
# do not each carry a hand-rolled copy of the same state machine.
#
# Usage: migrate_symlink LINK NEW_TARGET LEGACY_TARGET LABEL EXISTENCE_TEST
#   LINK            Path of the symlink to manage (e.g. ~/.claude/CLAUDE.md)
#   NEW_TARGET      Where the symlink should point after this call
#   LEGACY_TARGET   Old root-repo target that triggers a "migrating" message
#   LABEL           Human-readable name used in echo output
#   EXISTENCE_TEST  test(1) flag for the target: -f for files, -d for dirs
#
# States handled:
#   already-correct target   → no-op
#   legacy LEGACY_TARGET     → migrate if NEW_TARGET exists; warn if not
#   any other symlink target → repoint to NEW_TARGET
#   non-symlink regular file → warn, never overwrite
#   missing                  → create if NEW_TARGET passes EXISTENCE_TEST
migrate_symlink() {
  local link="$1" new_target="$2" legacy_target="$3" label="$4" existence_test="$5"

  if [[ -L "$link" ]]; then
    local current_target
    current_target="$(readlink "$link")"
    if [[ "$current_target" == "$new_target" ]]; then
      echo "  $label — already correct"
    elif [[ "$current_target" == "$legacy_target" ]]; then
      if test "$existence_test" "$new_target"; then
        echo "  $label — migrating from root repo to worktree"
        rm "$link"
        ln -s "$new_target" "$link"
      else
        echo "  $label — WARNING: exists in root repo but not in worktree (skill may not be on main yet)"
      fi
    else
      echo "  $label — symlink points elsewhere ($current_target), updating to worktree"
      rm "$link"
      ln -s "$new_target" "$link"
    fi
  elif [[ -e "$link" ]]; then
    echo "  WARNING: $link is not a symlink — skipping (will not overwrite)"
  else
    if test "$existence_test" "$new_target"; then
      echo "  $label — creating symlink to worktree"
      ln -s "$new_target" "$link"
    fi
  fi
}

# --- Step 1: Create the skills worktree ---

if [[ -d "$SKILLS_WORKTREE" ]]; then
  # Verify it's a valid worktree pointing to this repo
  if [[ -x "$REPO_ROOT_HELPER" ]]; then
    wt_root="$("$REPO_ROOT_HELPER" "$SKILLS_WORKTREE" 2>/dev/null)" || wt_root=""
  else
    wt_root="$(git -C "$SKILLS_WORKTREE" worktree list --porcelain 2>/dev/null | awk '/^worktree /{sub(/^worktree /, ""); print; exit}')" || wt_root=""
  fi
  if [[ "$wt_root" == "$REPO_ROOT" ]]; then
    echo "Skills worktree already exists at $SKILLS_WORKTREE — updating to latest main."
    git -C "$SKILLS_WORKTREE" fetch origin main --quiet
    git -C "$SKILLS_WORKTREE" reset --hard origin/main --quiet
  else
    echo "ERROR: $SKILLS_WORKTREE exists but belongs to a different repo ($wt_root)." >&2
    echo "Remove it manually and re-run: rm -rf $SKILLS_WORKTREE" >&2
    exit 1
  fi
else
  echo "Creating skills worktree at $SKILLS_WORKTREE..."
  # If a previous run removed only the worktree directory, git can still list the
  # path as registered — worktree add then fails. Prune with immediate expiry so
  # recently-removed worktrees are dropped (default prune window is too long).
  git -C "$REPO_ROOT" worktree prune --expire now 2>/dev/null || true
  # Fetch latest main first
  git -C "$REPO_ROOT" fetch origin main --quiet
  # Create worktree on main — use a detached HEAD tracking origin/main
  # to avoid conflicts with the root repo's main branch
  git -C "$REPO_ROOT" worktree add "$SKILLS_WORKTREE" origin/main --detach --quiet
  echo "Skills worktree created."
fi

# --- Step 2: Ensure ~/.claude/skills/ exists ---

mkdir -p "$SKILLS_DIR"

# --- Step 3: Symlink all skills from the worktree ---

WORKTREE_SKILLS="$SKILLS_WORKTREE/.claude/skills"

# --- Helper: skill_owned_by_setup ---
# Returns true (exit 0) when the symlink target is one this script manages —
# i.e., it points into the skills worktree or into the legacy root-repo skills
# directory that is being migrated away from. Used by both the publish and prune
# loops to leave user-owned personal skills untouched (mirrors the identical
# predicate in publish-agent-symlinks.sh for the agents leg).
#
# The target is normalized before the prefix check so that traversal sequences
# (e.g. ~/.claude/skills-worktree/../../../etc) cannot cause a path outside the
# managed directories to be misidentified as setup-owned.
skill_owned_by_setup() {
  local raw_target="$1"
  local target
  # Normalize the path — resolve any ../ sequences — without requiring it to exist.
  if [[ "$raw_target" == /* ]]; then
    target="$(python3 -c "import os,sys; print(os.path.normpath(sys.argv[1]))" \
              "$raw_target" 2>/dev/null)" || return 1
  else
    # Relative symlinks are rare (all setup-created links are absolute) but resolve
    # them against SKILLS_DIR — the parent directory of every skill symlink.
    target="$(python3 -c "import os,sys; print(os.path.normpath(os.path.join(sys.argv[1],sys.argv[2])))" \
              "$SKILLS_DIR" "$raw_target" 2>/dev/null)" || return 1
  fi
  [[ "$target" == "$WORKTREE_SKILLS/"* ]] && return 0
  [[ "$target" == "$REPO_ROOT/.claude/skills/"* ]] && return 0
  return 1
}

if [[ ! -d "$WORKTREE_SKILLS" ]]; then
  echo "WARNING: No .claude/skills/ directory in the worktree. Skipping skill symlinks."
else

echo "Symlinking skills from worktree..."

for skill_dir in "$WORKTREE_SKILLS"/*/; do
  # Skip if glob didn't match anything
  [[ -d "$skill_dir" ]] || continue

  skill_name="$(basename "$skill_dir")"
  target="$WORKTREE_SKILLS/$skill_name"
  link="$SKILLS_DIR/$skill_name"

  if [[ -L "$link" ]]; then
    current_target="$(readlink "$link")"
    if [[ "$current_target" == "$target" ]]; then
      echo "  $skill_name — already correct"
      continue
    fi
    # If the link points somewhere we do not manage, it is a user-owned personal
    # skill. Leave it alone rather than silently repointing it.
    if ! skill_owned_by_setup "$current_target"; then
      echo "  $skill_name — leaving user-owned symlink alone (-> $current_target)"
      continue
    fi
    echo "  $skill_name — updating symlink (was: $current_target)"
    rm "$link"
  elif [[ -d "$link" ]]; then
    echo "  $skill_name — replacing directory copy with symlink"
    rm -rf "$link"
  fi

  ln -s "$target" "$link"
  echo "  $skill_name — symlinked"
done

# --- Step 3b: Remove orphaned skill symlinks (skill renamed or removed on main) ---
# Use "$SKILLS_DIR"/* (not */) so dangling symlinks are included — a broken link is
# not a directory, so */-style globs skip it.
# Only prune setup-managed links; user-owned personal skills are left in place.
for link in "$SKILLS_DIR"/*; do
  [[ -e "$link" || -L "$link" ]] || continue
  [[ -L "$link" ]] || continue
  skill_name="$(basename "$link")"
  current_target="$(readlink "$link")"
  # Skip user-owned symlinks — they point outside what setup manages.
  if ! skill_owned_by_setup "$current_target"; then
    echo "  $skill_name — leaving user-owned symlink alone (-> $current_target)"
    continue
  fi
  # Skip legacy root-repo links: Step 4 handles them via migrate_symlink, which
  # preserves the link and warns when the worktree target does not yet exist
  # (skill not on main). Pruning here would remove the link before Step 4 runs.
  if [[ "$current_target" == "$REPO_ROOT/.claude/skills/$skill_name" ]]; then
    continue
  fi
  if [[ ! -d "$WORKTREE_SKILLS/$skill_name" ]]; then
    echo "  $skill_name — removing stale symlink (no matching skill in worktree)"
    rm "$link"
  fi
done

# --- Step 4: Remove stale symlinks pointing to the old root repo location ---

for link in "$SKILLS_DIR"/*; do
  [[ -e "$link" || -L "$link" ]] || continue
  [[ -L "$link" ]] || continue
  skill_name="$(basename "$link")"
  current_target="$(readlink "$link")"

  # If it points to the root repo's .claude/skills/ (old approach), migrate it.
  # migrate_symlink handles the migrate-if-target-exists / warn-if-not branches.
  if [[ "$current_target" == "$REPO_ROOT/.claude/skills/$skill_name" ]]; then
    migrate_symlink "$link" "$WORKTREE_SKILLS/$skill_name" \
      "$REPO_ROOT/.claude/skills/$skill_name" "$skill_name" -d
  fi
done

fi  # end of skills directory check

# --- Step 5: Migrate CLAUDE.md and rules symlinks to skills worktree ---

CLAUDE_MD_LINK="$HOME/.claude/CLAUDE.md"
CLAUDE_MD_TARGET="$SKILLS_WORKTREE/CLAUDE.md"
RULES_LINK="$HOME/.claude/rules"
RULES_TARGET="$SKILLS_WORKTREE/.claude/rules"

migrate_symlink "$CLAUDE_MD_LINK" "$CLAUDE_MD_TARGET" "$REPO_ROOT/CLAUDE.md" "CLAUDE.md" -f
migrate_symlink "$RULES_LINK" "$RULES_TARGET" "$REPO_ROOT/.claude/rules" "rules" -d

# --- Step 5b: Publish phase-agent definitions to user scope (issue #1189) ---
#
# Claude Code discovers custom subagent definitions at BOTH ~/.claude/agents/
# (user scope) and <repo>/.claude/agents/ (project scope), project winning on a
# name: collision. Without this leg the phase agents exist only in this repo, so
# `subagent_type: "phase-a-fixer"` fails everywhere else and the PM skills lose
# their inline pipelines with no visible error.
#
# Topology note: this mirrors Step 3 (skills) — a REAL directory holding one
# symlink per file — and deliberately NOT Step 5 (rules), which points a single
# directory symlink at the worktree. The Claude Code docs state that
# .claude/rules/ resolves symlinks; they are silent on symlink-following for
# agents/. A real directory needs no such guarantee, and per-file symlinks keep
# the worktree as the single source either way.
#
# Logic extracted to .claude/scripts/publish-agent-symlinks.sh (issue #1197) so
# session-start-sync.sh can run the same idempotent publish every session,
# keeping existing installs in sync without a manual re-run of this script.

WORKTREE_AGENTS="$SKILLS_WORKTREE/.claude/agents"
AGENTS_PUBLISH_SCRIPT="$REPO_ROOT/.claude/scripts/publish-agent-symlinks.sh"

echo ""
if [[ ! -d "$WORKTREE_AGENTS" ]]; then
  echo "WARNING: No .claude/agents/ directory in the worktree. Skipping agent symlinks." >&2
elif [[ ! -f "$AGENTS_PUBLISH_SCRIPT" ]]; then
  echo "WARNING: publish-agent-symlinks.sh not found at $AGENTS_PUBLISH_SCRIPT — skipping agent symlinks" >&2
else
  echo "Symlinking agent definitions from worktree..."
  bash "$AGENTS_PUBLISH_SCRIPT" "$SKILLS_WORKTREE" "$REPO_ROOT"
fi

# --- Step 6: Register hooks and statusLine in ~/.claude/settings.json ---
#
# Delegates entirely to register-hooks.py which reads global-settings.json as
# the single source of truth — no separate manifest to maintain. Full-mode
# (no --statusline-only) registers hooks, prunes stale/decommissioned
# registrations, and syncs statusLine in one atomic write.
#
# To add a new hook:
#   1. Add the hook script to .claude/hooks/
#   2. Add the entry to global-settings.json (one place, no manifest to sync)
#   3. Run this script — register-hooks.py picks it up automatically
#
SETTINGS_FILE="$HOME/.claude/settings.json"
REGISTER_HOOKS_PY="$SKILLS_WORKTREE/.claude/hooks/register-hooks.py"

echo ""
echo "Registering hooks in $SETTINGS_FILE..."

if [[ ! -f "$REGISTER_HOOKS_PY" ]]; then
  echo "  WARNING: register-hooks.py not found at $REGISTER_HOOKS_PY; skipping hook registration" >&2
elif ! command -v python3 >/dev/null 2>&1; then
  echo "  WARNING: python3 not found; skipping hook and statusLine registration" >&2
else
  # Full-mode invocation: registers all hooks from global-settings.json, prunes
  # stale/decommissioned registrations, and syncs statusLine — one atomic write.
  # MANAGED_LEGACY_HOOKS_DIR tells the pruner to also clean up root-repo hook
  # paths left behind by pre-worktree installs.
  if MANAGED_LEGACY_HOOKS_DIR="$REPO_ROOT/.claude/hooks" \
     python3 "$REGISTER_HOOKS_PY" "$SKILLS_WORKTREE"; then
    echo "  Hooks and statusLine registered (read from global-settings.json)"
  else
    echo "  WARNING: register-hooks.py reported errors (some hooks may not be registered)" >&2
  fi
fi

echo ""
echo "Done. Skills worktree: $SKILLS_WORKTREE"
echo "Symlinks in:           $SKILLS_DIR"
echo ""
echo "Verify with: ls -la $SKILLS_DIR"
