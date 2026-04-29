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
  # path as registered — worktree add then fails. Prune drops stale metadata.
  git -C "$REPO_ROOT" worktree prune 2>/dev/null || true
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

fi  # end of skills directory check

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
# Fields are TAB-separated so matchers can use "|" alternation (e.g. Write|Edit).
# Layout: event<TAB>matcher<TAB>script_name<TAB>timeout
# matcher is an empty field for hooks with no matcher.
#
# Must stay in sync with global-settings.json; setup.sh verifies this and fails
# if any template hook is missing from ~/.claude/settings.json after this runs.
#
# To add a new hook:
#   1. Add the hook script to .claude/hooks/
#   2. Add the same entry to global-settings.json AND to this manifest
#   3. Run this script — it will register the hook in settings.json
#
HOOKS_MANIFEST=(
  $'PreToolUse\tBash\tscript-bypass-detector.sh\t5'
  $'PreToolUse\tWrite|Edit|NotebookEdit\tworktree-guard.sh\t5'
  $'PreToolUse\tWrite|Edit|MultiEdit|NotebookEdit|Bash\tenv-guard.py\t5'
  $'Stop\t\tsilence-detector-ack.sh\t5'
  $'Stop\t\ttrust-flag-repair.sh\t10'
  $'Stop\t\tdirty-main-warn.sh\t10'
  $'PostToolUse\t\tsession-start-sync.sh\t30'
  $'PostToolUse\tBash\tpost-merge-pull.sh\t15'
  $'PostToolUse\tBash\tpolling-backoff-warn.sh\t5'
  $'PostToolUse\tSkill\tskill-usage-tracker.sh\t5'
  $'PostToolUse\t\tsilence-detector.sh\t5'
  $'UserPromptSubmit\t\ttimestamp-injector.sh\t5'
  $'UserPromptSubmit\t\tstale-worktree-warn.sh\t30'
)

SETTINGS_FILE="$HOME/.claude/settings.json"
HOOKS_DIR="$SKILLS_WORKTREE/.claude/hooks"

echo ""
echo "Registering hooks in $SETTINGS_FILE..."

python3 - "$SETTINGS_FILE" "$HOOKS_DIR" "${HOOKS_MANIFEST[@]}" <<'PYTHON_SCRIPT'
import json
import os
import sys

settings_file = sys.argv[1]
hooks_dir = sys.argv[2]
manifest_entries = sys.argv[3:]

# Parse manifest: TAB-separated "event\tmatcher\tscript_name\ttimeout".
# Tab is used (not "|") so matchers can contain "|" alternation (e.g. Write|Edit).
manifest = []
for entry in manifest_entries:
    parts = entry.split("\t")
    if len(parts) != 4:
        print(f"  WARNING: skipping malformed manifest entry: {entry!r}")
        continue
    try:
        timeout_val = int(parts[3])
    except ValueError:
        print(f"  WARNING: skipping entry with non-integer timeout: {entry!r}")
        continue
    manifest.append({
        "event": parts[0],
        "matcher": parts[1] if parts[1] else None,
        "script": parts[2],
        "timeout": timeout_val,
    })

# Read existing settings.json or start fresh
if os.path.isfile(settings_file):
    try:
        with open(settings_file) as f:
            settings = json.load(f)
    except json.JSONDecodeError as e:
        import shutil
        backup = settings_file + ".bak"
        shutil.copy2(settings_file, backup)
        print(f"  WARNING: {settings_file} contains invalid JSON: {e}")
        print(f"  Backed up to {backup}, starting fresh (all settings will be re-created)")
        settings = {}
else:
    settings = {}

if not isinstance(settings, dict):
    print(f"  WARNING: {settings_file} top-level value is not an object; resetting")
    settings = {}

if "hooks" not in settings or not isinstance(settings["hooks"], dict):
    if "hooks" in settings:
        print(f"  WARNING: {settings_file} has non-object 'hooks'; resetting hooks section")
    settings["hooks"] = {}

hooks = settings["hooks"]

def command_path(script_name):
    return os.path.join(hooks_dir, script_name)

def is_placeholder_path(path):
    """Detect placeholder paths from global-settings.json templates."""
    return "/path/to/" in path or not os.path.isabs(path)

def find_existing_hook(event_entries, cmd_path, matcher):
    """Find an existing hook entry by basename match within groups that share the same matcher.

    Returns:
      ("exact", None)    — already registered with correct path
      ("migrate", hook)  — registered but path needs updating (e.g., root-repo -> worktree)
      ("placeholder", hook) — registered with a placeholder path
      (None, None)       — not registered
    """
    basename = os.path.basename(cmd_path)
    for group in event_entries:
        if not isinstance(group, dict):
            continue
        group_matcher = group.get("matcher")
        if group_matcher != matcher:
            continue
        hook_list = group.get("hooks", [])
        if not isinstance(hook_list, list):
            continue
        for h in hook_list:
            if not isinstance(h, dict):
                continue
            existing_cmd = h.get("command", "")
            if os.path.basename(existing_cmd) != basename:
                continue
            if is_placeholder_path(existing_cmd):
                return ("placeholder", h)
            if existing_cmd == cmd_path:
                return ("exact", None)
            # Same script name, different valid path — needs migration
            return ("migrate", h)
    return (None, None)

added = []
migrated = []
already_present = []

for item in manifest:
    event = item["event"]
    matcher = item["matcher"]
    script = item["script"]
    timeout = item["timeout"]
    cmd = command_path(script)

    if not os.path.isfile(cmd):
        print(f"  {script} — WARNING: not found at {cmd}; skipping")
        continue

    if event not in hooks or not isinstance(hooks[event], list):
        hooks[event] = []

    status, hook_ref = find_existing_hook(hooks[event], cmd, matcher)

    if status == "exact":
        already_present.append(script)
        continue
    elif status == "migrate":
        # Update path in-place (e.g., root-repo -> skills-worktree)
        old_path = hook_ref["command"]
        hook_ref["command"] = cmd
        hook_ref["timeout"] = timeout
        migrated.append(script)
        continue
    elif status == "placeholder":
        # Replace placeholder with real path in-place
        hook_ref["command"] = cmd
        hook_ref["timeout"] = timeout
        migrated.append(script)
        continue

    # Not registered at all — add new entry
    hook_obj = {"type": "command", "command": cmd, "timeout": timeout}
    group = {"hooks": [hook_obj]}
    if matcher:
        group["matcher"] = matcher

    hooks[event].append(group)
    added.append(script)

# Write back atomically to prevent corruption on interrupt
import tempfile

settings_dir = os.path.dirname(settings_file) or "."
fd, tmp_path = tempfile.mkstemp(dir=settings_dir, suffix=".tmp")
try:
    with os.fdopen(fd, "w") as f:
        json.dump(settings, f, indent=2)
        f.write("\n")
    os.replace(tmp_path, settings_file)
except BaseException:
    os.unlink(tmp_path)
    raise

# Report
for name in added:
    print(f"  {name} — added")
for name in migrated:
    print(f"  {name} — migrated path to skills worktree")
for name in already_present:
    print(f"  {name} — already registered")
PYTHON_SCRIPT

echo ""
echo "Done. Skills worktree: $SKILLS_WORKTREE"
echo "Symlinks in:           $SKILLS_DIR"
echo ""
echo "Verify with: ls -la $SKILLS_DIR"
