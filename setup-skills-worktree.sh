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

# --- Step 3b: Remove orphaned skill symlinks (skill renamed or removed on main) ---
# Use "$SKILLS_DIR"/* (not */) so dangling symlinks are included — a broken link is
# not a directory, so */-style globs skip it.
for link in "$SKILLS_DIR"/*; do
  [[ -e "$link" || -L "$link" ]] || continue
  [[ -L "$link" ]] || continue
  skill_name="$(basename "$link")"
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
  $'PreToolUse\tWrite|Edit|MultiEdit|NotebookEdit|Bash\tconfig-protection.py\t5'
  $'Stop\t\tsilence-detector-ack.sh\t5'
  $'Stop\t\ttrust-flag-repair.sh\t10'
  $'Stop\t\tdirty-main-warn.sh\t10'
  $'Stop\t\tskill-usage-snapshot-hook.sh\t10'
  $'SessionStart\t\tsession-start-sync.sh\t30'
  $'StopFailure\trate_limit\tusage-limit-record.sh\t5'
  $'PostToolUse\tBash\tpost-merge-pull.sh\t15'
  $'PostToolUse\tBash\tpolling-backoff-warn.sh\t5'
  $'PostToolUse\tSkill\tskill-usage-tracker.sh\t5'
  $'PostToolUse\t\tsilence-detector.sh\t5'
  $'UserPromptSubmit\t\ttimestamp-injector.sh\t5'
  $'UserPromptSubmit\t\tstale-worktree-warn.sh\t30'
  $'UserPromptSubmit\t\tissue-prefix-nudge.sh\t5'
  $'UserPromptSubmit\t\tskill-command-tracker.sh\t5'
)

SETTINGS_FILE="$HOME/.claude/settings.json"
HOOKS_DIR="$SKILLS_WORKTREE/.claude/hooks"

echo ""
echo "Registering hooks in $SETTINGS_FILE..."

MANAGED_LEGACY_HOOKS_DIR="$REPO_ROOT/.claude/hooks" \
python3 - "$SETTINGS_FILE" "$HOOKS_DIR" "${HOOKS_MANIFEST[@]}" <<'PYTHON_SCRIPT'
import json
import os
import shlex
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

def command_parts(cmd):
    """Tokenize a hook command into argv, ignoring nothing. Returns [] for a
    non-string command (malformed settings.json) and falls back to a whitespace
    split when the command is not valid shell syntax."""
    if not isinstance(cmd, str):
        return []
    try:
        return shlex.split(cmd)
    except ValueError:
        return cmd.split()

def command_argv0(cmd):
    """Return the executable path from a hook command, ignoring any arguments
    (e.g. 'foo.sh --check' -> 'foo.sh')."""
    parts = command_parts(cmd)
    return parts[0] if parts else ""

def command_args_tail(cmd):
    """Return the argument portion of a hook command (everything after argv0),
    reconstructed as a shell-safe string, or '' when there are no arguments.
    Lets path migration fix the executable path without dropping the args."""
    parts = command_parts(cmd)
    return " ".join(shlex.quote(p) for p in parts[1:])

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
            # Compare by argv0 so an args-bearing registration (e.g.
            # "foo.sh --check") still matches its manifest entry — the raw
            # command string would basename to "--check" and never match,
            # duplicating the hook or stripping its args on migration.
            existing_argv0 = command_argv0(h.get("command", ""))
            if os.path.basename(existing_argv0) != basename:
                continue
            if is_placeholder_path(existing_argv0):
                return ("placeholder", h)
            if existing_argv0 == cmd_path:
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
    elif status in ("migrate", "placeholder"):
        # Fix the executable path in-place (root-repo -> skills-worktree, or
        # placeholder -> real path) while preserving any args the registration
        # carried, so migration never silently drops "foo.sh --check" -> "foo.sh".
        args_tail = command_args_tail(hook_ref.get("command", ""))
        hook_ref["command"] = f"{cmd} {args_tail}" if args_tail else cmd
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

# Prune stale registrations for decommissioned hooks.
# When a hook is removed from the repo (e.g. the /quota rollback dropped
# quota-stop-notify.sh and quota-usage-hook.sh), its entry can linger in an
# existing ~/.claude/settings.json pointing at a now-deleted script. setup.sh
# Step 7 then fails ("Hook not found") and Claude Code would try to invoke a
# missing Stop/PostToolUse command each session. Remove any registered command
# hook that is (1) NOT in the current manifest (decommissioned, not merely
# un-migrated), (2) inside a managed .claude/hooks directory, and (3) pointing
# at a file that no longer exists. Active hooks — and any hook whose target file
# is present — are never touched, so re-runs are no-ops (idempotent; see
# tests/test-setup.sh).
manifest_scripts = {item["script"] for item in manifest}
# Map script basename -> canonical event for migration pruning (see below).
script_to_canonical_event = {item["script"]: item["event"] for item in manifest}
pruned = []

# Managed hook roots — restrict pruning to directories THIS installer owns so we
# never touch a different tool's or repo's ~/.../.claude/hooks registrations:
#   * hooks_dir            — the current skills-worktree hooks directory
#   * MANAGED_LEGACY_HOOKS_DIR — the root-repo hooks directory (pre-worktree
#                            installs registered hooks here before migration)
managed_hook_roots = {
    os.path.normpath(root)
    for root in (hooks_dir, os.environ.get("MANAGED_LEGACY_HOOKS_DIR", ""))
    if root
}

def is_managed_hooks_path(path):
    return os.path.normpath(os.path.dirname(path)) in managed_hook_roots

for event in list(hooks.keys()):
    event_entries = hooks[event]
    if not isinstance(event_entries, list):
        continue
    surviving_groups = []
    for group in event_entries:
        if not isinstance(group, dict):
            surviving_groups.append(group)
            continue
        hook_list = group.get("hooks")
        if not isinstance(hook_list, list):
            surviving_groups.append(group)
            continue
        surviving_hooks = []
        for h in hook_list:
            if isinstance(h, dict) and h.get("type") == "command":
                exe = command_argv0(h.get("command", ""))
                script_name = os.path.basename(exe)
                if (exe
                        and script_name not in manifest_scripts
                        and is_managed_hooks_path(exe)
                        and not is_placeholder_path(exe)
                        and not os.path.isfile(exe)):
                    pruned.append(script_name)
                    continue  # drop this stale hook entry
                # Also prune hooks that have moved to a different event in the
                # manifest (e.g. PostToolUse -> SessionStart for issue #792).
                # Without this, the old event entry survives and the script fires
                # on both the old and new event — critical after the sentinel guard
                # was removed from session-start-sync.sh.
                canonical_event = script_to_canonical_event.get(script_name)
                if (exe
                        and canonical_event is not None
                        and canonical_event != event
                        and is_managed_hooks_path(exe)
                        and not is_placeholder_path(exe)):
                    pruned.append(f"{script_name} (moved to {canonical_event})")
                    continue  # drop stale event registration
            surviving_hooks.append(h)
        if surviving_hooks:
            group["hooks"] = surviving_hooks
            surviving_groups.append(group)
        # else: group held only stale hooks — drop the group entirely
    if surviving_groups:
        hooks[event] = surviving_groups
    else:
        del hooks[event]  # no hooks left for this event

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
for name in pruned:
    print(f"  {name} — pruned stale registration (script no longer exists)")
PYTHON_SCRIPT

echo ""
echo "Done. Skills worktree: $SKILLS_WORKTREE"
echo "Symlinks in:           $SKILLS_DIR"
echo ""
echo "Verify with: ls -la $SKILLS_DIR"
