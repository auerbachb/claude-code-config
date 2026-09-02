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

# Find the repo root. Both spellings resolve from SCRIPT_DIR, never from the
# caller's cwd: this script is invoked by absolute path from contexts that have
# no meaningful working directory — the claude-config-sync LaunchAgent runs with
# cwd `/`, where an unanchored `git worktree list` finds no repository and the
# script would abort with "Could not find the root repo" on precisely the
# fresh-machine bootstrap it exists to perform.
# Prefer the shared helper; fall back to the inline one-liner when the helper
# file isn't on disk yet (e.g., this script was copied into a bare clone).
if [[ -x "$REPO_ROOT_HELPER" ]]; then
  REPO_ROOT="$("$REPO_ROOT_HELPER" "$SCRIPT_DIR" 2>/dev/null)" || true
else
  # No `exit` in the awk: under `set -o pipefail` an early-exiting consumer
  # SIGPIPEs `git worktree list` mid-write, so the pipeline reports failure with
  # the right answer already on stdout. Consuming the whole stream avoids it.
  REPO_ROOT="$(git -C "$SCRIPT_DIR" worktree list --porcelain 2>/dev/null | awk '/^worktree /{if (!seen++) {sub(/^worktree /, ""); print}}')" || true
fi

if [[ -z "$REPO_ROOT" || ! -d "$REPO_ROOT/.git" ]]; then
  echo "ERROR: Could not find the root repo. Run this from inside the claude-code-config repo." >&2
  exit 1
fi

echo "Root repo: $REPO_ROOT"

# --- Step 0: Preflight — the symlink publisher must exist BEFORE we mutate ---
#
# Publishing the skill / CLAUDE.md / rules symlinks is this script's core job
# (Steps 2-5 below), and since issue #1524 that work lives in a separate
# publisher. A missing publisher is therefore fatal, not skippable: completing
# "setup" with a worktree and no symlinks would report success while leaving
# ~/.claude/ unconfigured.
#
# The check runs HERE, before Step 1, rather than at the call site: failing
# after the worktree is created leaves a half-finished install behind. Resolved
# from SCRIPT_DIR, not REPO_ROOT — the publisher that ships beside THIS script
# is the one the user invoked; the main checkout may sit on a branch that
# predates it. REPO_ROOT is still passed as the legacy-migration argument,
# which is all it is for.
SKILLS_PUBLISH_SCRIPT="$SCRIPT_DIR/.claude/scripts/publish-skill-symlinks.sh"
if [[ ! -f "$SKILLS_PUBLISH_SCRIPT" ]]; then
  echo "ERROR: publish-skill-symlinks.sh not found at $SKILLS_PUBLISH_SCRIPT" >&2
  echo "       Nothing has been changed. Re-run from a complete checkout." >&2
  exit 1
fi

# --- Step 1: Create the skills worktree ---

if [[ -d "$SKILLS_WORKTREE" ]]; then
  # Verify it's a valid worktree pointing to this repo
  if [[ -x "$REPO_ROOT_HELPER" ]]; then
    wt_root="$("$REPO_ROOT_HELPER" "$SKILLS_WORKTREE" 2>/dev/null)" || wt_root=""
  else
    # Same SIGPIPE reasoning as the lookup above, and here the `|| wt_root=""`
    # made it worse: a wiped value fails the comparison below and the script
    # aborts claiming the worktree "belongs to a different repo".
    wt_root="$(git -C "$SKILLS_WORKTREE" worktree list --porcelain 2>/dev/null | awk '/^worktree /{if (!seen++) {sub(/^worktree /, ""); print}}')"
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

# --- Steps 2-5: Publish skill, CLAUDE.md and rules symlinks ---
#
# The symlink state machine (publish, prune, legacy-migrate) and the
# CLAUDE.md / rules legs live in .claude/scripts/publish-skill-symlinks.sh
# (issue #1524) so that the scheduled claude-config-sync.sh tick and the
# session-start hook can run the same idempotent publish without re-running
# this whole bootstrap. This mirrors the Step 5b delegation to
# publish-agent-symlinks.sh below.

# SKILLS_PUBLISH_SCRIPT is resolved and existence-checked in the Step 0
# preflight above, so this call site only has to invoke it.
echo "Symlinking skills, CLAUDE.md and rules from worktree..."
bash "$SKILLS_PUBLISH_SCRIPT" "$SKILLS_WORKTREE" "$REPO_ROOT"

# --- Step 5b: Publish phase-agent definitions to user scope (issue #1189) ---
#
# Claude Code discovers custom subagent definitions at BOTH ~/.claude/agents/
# (user scope) and <repo>/.claude/agents/ (project scope), project winning on a
# name: collision. Without this leg the phase agents exist only in this repo, so
# `subagent_type: "phase-a-fixer"` fails everywhere else and the PM skills lose
# their inline pipelines with no visible error.
#
# Topology note: this mirrors the SKILLS leg — a REAL directory holding one
# symlink per file — and deliberately NOT the RULES leg, which points a single
# directory symlink at the worktree. The Claude Code docs state that
# .claude/rules/ resolves symlinks; they are silent on symlink-following for
# agents/. A real directory needs no such guarantee, and per-file symlinks keep
# the worktree as the single source either way.
#
# Logic extracted to .claude/scripts/publish-agent-symlinks.sh (issue #1197) so
# session-start-sync.sh can run the same idempotent publish every session,
# keeping existing installs in sync without a manual re-run of this script.

WORKTREE_AGENTS="$SKILLS_WORKTREE/.claude/agents"
AGENTS_PUBLISH_SCRIPT="$SCRIPT_DIR/.claude/scripts/publish-agent-symlinks.sh"

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
