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

# Find the repo root (works from anywhere inside the repo or a worktree)
REPO_ROOT="$(git worktree list 2>/dev/null | head -1 | awk '{print $1}')" || true

if [[ -z "$REPO_ROOT" || ! -d "$REPO_ROOT/.git" ]]; then
  echo "ERROR: Could not find the root repo. Run this from inside the claude-code-config repo." >&2
  exit 1
fi

echo "Root repo: $REPO_ROOT"

# --- Step 1: Create the skills worktree ---

if [[ -d "$SKILLS_WORKTREE" ]]; then
  # Verify it's a valid worktree pointing to this repo
  wt_root="$(git -C "$SKILLS_WORKTREE" worktree list 2>/dev/null | head -1 | awk '{print $1}')"
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

if [[ ! -d "$WORKTREE_SKILLS" ]]; then
  echo "WARNING: No .claude/skills/ directory in the worktree. Nothing to symlink."
  exit 0
fi

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
    echo "  $skill_name — updating symlink (was: $current_target)"
    rm "$link"
  elif [[ -d "$link" ]]; then
    echo "  $skill_name — replacing directory copy with symlink"
    rm -rf "$link"
  fi

  ln -s "$target" "$link"
  echo "  $skill_name — symlinked"
done

# --- Step 4: Remove stale symlinks pointing to the old root repo location ---

for link in "$SKILLS_DIR"/*/; do
  [[ -L "${link%/}" ]] || continue
  link="${link%/}"
  skill_name="$(basename "$link")"
  current_target="$(readlink "$link")"

  # If it points to the root repo's .claude/skills/ (old approach), migrate it
  if [[ "$current_target" == "$REPO_ROOT/.claude/skills/$skill_name" ]]; then
    new_target="$WORKTREE_SKILLS/$skill_name"
    if [[ -d "$new_target" ]]; then
      echo "  $skill_name — migrating from root repo to worktree"
      rm "$link"
      ln -s "$new_target" "$link"
    else
      echo "  $skill_name — WARNING: exists in root repo but not in worktree (skill may not be on main yet)"
    fi
  fi
done

# --- Step 5: Migrate CLAUDE.md and rules symlinks to skills worktree ---

CLAUDE_MD_LINK="$HOME/.claude/CLAUDE.md"
CLAUDE_MD_TARGET="$SKILLS_WORKTREE/CLAUDE.md"
RULES_LINK="$HOME/.claude/rules"
RULES_TARGET="$SKILLS_WORKTREE/.claude/rules"

# Migrate CLAUDE.md
if [[ -L "$CLAUDE_MD_LINK" ]]; then
  current_target="$(readlink "$CLAUDE_MD_LINK")"
  if [[ "$current_target" == "$CLAUDE_MD_TARGET" ]]; then
    echo "  CLAUDE.md — already correct"
  elif [[ "$current_target" == "$REPO_ROOT/CLAUDE.md" ]]; then
    echo "  CLAUDE.md — migrating from root repo to worktree"
    rm "$CLAUDE_MD_LINK"
    ln -s "$CLAUDE_MD_TARGET" "$CLAUDE_MD_LINK"
  else
    echo "  CLAUDE.md — symlink points elsewhere ($current_target), updating to worktree"
    rm "$CLAUDE_MD_LINK"
    ln -s "$CLAUDE_MD_TARGET" "$CLAUDE_MD_LINK"
  fi
elif [[ -e "$CLAUDE_MD_LINK" ]]; then
  echo "  WARNING: $CLAUDE_MD_LINK is not a symlink — skipping (will not overwrite)"
else
  if [[ -f "$CLAUDE_MD_TARGET" ]]; then
    echo "  CLAUDE.md — creating symlink to worktree"
    ln -s "$CLAUDE_MD_TARGET" "$CLAUDE_MD_LINK"
  fi
fi

# Migrate rules
if [[ -L "$RULES_LINK" ]]; then
  current_target="$(readlink "$RULES_LINK")"
  if [[ "$current_target" == "$RULES_TARGET" ]]; then
    echo "  rules — already correct"
  elif [[ "$current_target" == "$REPO_ROOT/.claude/rules" ]]; then
    echo "  rules — migrating from root repo to worktree"
    rm "$RULES_LINK"
    ln -s "$RULES_TARGET" "$RULES_LINK"
  else
    echo "  rules — symlink points elsewhere ($current_target), updating to worktree"
    rm "$RULES_LINK"
    ln -s "$RULES_TARGET" "$RULES_LINK"
  fi
elif [[ -e "$RULES_LINK" ]]; then
  echo "  WARNING: $RULES_LINK is not a symlink — skipping (will not overwrite)"
else
  if [[ -d "$RULES_TARGET" ]]; then
    echo "  rules — creating symlink to worktree"
    ln -s "$RULES_TARGET" "$RULES_LINK"
  fi
fi

# --- Step 6: Register hooks in ~/.claude/settings.json ---
#
# Hooks manifest — declarative list of hooks this repo expects to be registered.
# Each entry: "event|matcher|script_name|timeout"
# matcher is empty string for hooks with no matcher.
#
# To add a new hook:
#   1. Add the hook script to .claude/hooks/
#   2. Add a manifest entry below with the event, matcher, script name, and timeout
#   3. Run this script — it will register the hook in settings.json
#
HOOKS_MANIFEST=(
  "Stop||silence-detector-ack.sh|5"
  "Stop||trust-flag-repair.sh|10"
  "PostToolUse|Bash|post-merge-pull.sh|15"
  "PostToolUse||session-start-sync.sh|30"
  "PostToolUse||silence-detector.sh|5"
)

SETTINGS_FILE="$HOME/.claude/settings.json"
HOOKS_DIR="$REPO_ROOT/.claude/hooks"

echo ""
echo "Registering hooks in $SETTINGS_FILE..."

python3 - "$SETTINGS_FILE" "$HOOKS_DIR" "${HOOKS_MANIFEST[@]}" <<'PYTHON_SCRIPT'
import json
import os
import sys

settings_file = sys.argv[1]
hooks_dir = sys.argv[2]
manifest_entries = sys.argv[3:]

# Parse manifest: "event|matcher|script_name|timeout"
manifest = []
for entry in manifest_entries:
    parts = entry.split("|")
    manifest.append({
        "event": parts[0],
        "matcher": parts[1] if parts[1] else None,
        "script": parts[2],
        "timeout": int(parts[3]),
    })

# Read existing settings.json or start fresh
if os.path.isfile(settings_file):
    with open(settings_file) as f:
        settings = json.load(f)
else:
    settings = {}

if "hooks" not in settings:
    settings["hooks"] = {}

hooks = settings["hooks"]

def command_path(script_name):
    return os.path.join(hooks_dir, script_name)

def hook_already_registered(event_entries, cmd_path, matcher):
    """Check if a hook with this command path is already registered under the event."""
    for group in event_entries:
        group_matcher = group.get("matcher")
        # Match by command path within groups that have the same matcher
        if group_matcher != matcher:
            continue
        for h in group.get("hooks", []):
            if os.path.basename(h.get("command", "")) == os.path.basename(cmd_path):
                return True
    return False

added = []
already_present = []

for item in manifest:
    event = item["event"]
    matcher = item["matcher"]
    script = item["script"]
    timeout = item["timeout"]
    cmd = command_path(script)

    if event not in hooks:
        hooks[event] = []

    if hook_already_registered(hooks[event], cmd, matcher):
        already_present.append(script)
        continue

    # Build the hook group entry
    hook_obj = {"type": "command", "command": cmd, "timeout": timeout}
    group = {"hooks": [hook_obj]}
    if matcher:
        group["matcher"] = matcher

    hooks[event].append(group)
    added.append(script)

# Write back
with open(settings_file, "w") as f:
    json.dump(settings, f, indent=2)
    f.write("\n")

# Report
for name in added:
    print(f"  {name} — added")
for name in already_present:
    print(f"  {name} — already registered")
PYTHON_SCRIPT

echo ""
echo "Done. Skills worktree: $SKILLS_WORKTREE"
echo "Symlinks in:           $SKILLS_DIR"
echo ""
echo "Verify with: ls -la $SKILLS_DIR"
