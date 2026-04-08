#!/bin/bash
# setup.sh — Idempotent installer for claude-code-config
#
# Derives all paths from the script's own location (SCRIPT_DIR).
# Safe to run multiple times — merges settings without overwriting user
# customizations, exits fast on failure with a clear error message.
#
# Usage: bash ./setup.sh

set -euo pipefail

# ---------------------------------------------------------------------------
# Path derivation — everything is relative to this script's location
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# ---------------------------------------------------------------------------
# Prerequisites
# ---------------------------------------------------------------------------
if ! command -v git >/dev/null 2>&1; then
  echo "FAIL: git is not installed or not in PATH." >&2
  exit 1
fi

# Validate SCRIPT_DIR is a git repo root (catches copied/symlinked setup.sh)
if ! REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel 2>/dev/null)"; then
  echo "FAIL: setup.sh must be run from a cloned git repository." >&2
  exit 1
fi
if [[ "$REPO_ROOT" != "$SCRIPT_DIR" ]]; then
  echo "FAIL: setup.sh must live at the repo root. Found repo root: $REPO_ROOT" >&2
  exit 1
fi

CLAUDE_DIR="$HOME/.claude"
SKILLS_WORKTREE="$CLAUDE_DIR/skills-worktree"


# Track pass/fail per step for final summary
declare -a STEP_NAMES=()
declare -a STEP_RESULTS=()

step_pass() { STEP_NAMES+=("$1"); STEP_RESULTS+=("PASS"); }
step_fail() { STEP_NAMES+=("$1"); STEP_RESULTS+=("FAIL"); echo "FAIL: $1 — $2" >&2; }

# ---------------------------------------------------------------------------
# Step 1: Create ~/.claude directory structure
# ---------------------------------------------------------------------------
echo "Step 1: Creating ~/.claude directory structure..."

mkdir -p "$CLAUDE_DIR/skills"

if [[ -d "$CLAUDE_DIR/skills" ]]; then
  step_pass "Directory structure"
else
  step_fail "Directory structure" "Could not create $CLAUDE_DIR/skills"
  exit 1
fi

# ---------------------------------------------------------------------------
# Step 2: Merge non-hook settings into settings.json (preserves existing keys)
# ---------------------------------------------------------------------------
echo "Step 2: Merging settings from global-settings.json..."

SETTINGS_SRC="$SCRIPT_DIR/global-settings.json"
SETTINGS_DST="$CLAUDE_DIR/settings.json"

if [[ ! -f "$SETTINGS_SRC" ]]; then
  step_fail "Merge settings" "Source file not found: $SETTINGS_SRC"
  exit 1
fi

# Ensure hooks are executable before anything else (handles missing execute bits
# from tarballs, WSL, or CI environments where git didn't preserve modes)
chmod +x "$SCRIPT_DIR/.claude/hooks"/*.sh 2>/dev/null || true

# Merge non-hook keys from template into existing settings.json.
# Existing keys are NEVER overwritten — only missing keys are seeded.
# Hooks are NOT touched here — setup-skills-worktree.sh Step 6 handles them.
if ! python3 - "$SETTINGS_SRC" "$SETTINGS_DST" <<'PYTHON_MERGE'
import json
import os
import sys
import tempfile

template_path = sys.argv[1]
settings_path = sys.argv[2]

# Read template
with open(template_path) as f:
    template = json.load(f)

# Read existing settings (or start empty)
if os.path.isfile(settings_path):
    try:
        with open(settings_path) as f:
            settings = json.load(f)
    except json.JSONDecodeError as e:
        import shutil
        backup = settings_path + ".bak"
        shutil.copy2(settings_path, backup)
        print(f"  WARNING: {settings_path} has invalid JSON: {e}")
        print(f"  Backed up to {backup}, starting fresh")
        settings = {}
else:
    settings = {}

if not isinstance(settings, dict):
    import shutil
    backup = settings_path + ".bak"
    shutil.copy2(settings_path, backup)
    print(f"  WARNING: {settings_path} top-level is not an object; backed up to {backup}, starting fresh")
    settings = {}

# Seed missing non-hook keys from template
# Never overwrite existing keys — user customizations take precedence
SKIP_KEYS = {"hooks"}  # hooks are managed by setup-skills-worktree.sh
added = []
for key, value in template.items():
    if key in SKIP_KEYS:
        continue
    if key not in settings:
        settings[key] = value
        added.append(key)
    else:
        # For dict values, seed missing sub-keys (one level deep)
        if isinstance(value, dict) and isinstance(settings[key], dict):
            for sub_key, sub_value in value.items():
                if sub_key not in settings[key]:
                    settings[key][sub_key] = sub_value
                    added.append(f"{key}.{sub_key}")

# Ensure hooks key exists (setup-skills-worktree.sh expects it)
if "hooks" not in settings:
    settings["hooks"] = {}

# Write atomically
settings_dir = os.path.dirname(settings_path) or "."
fd, tmp_path = tempfile.mkstemp(dir=settings_dir, suffix=".tmp")
try:
    with os.fdopen(fd, "w") as f:
        json.dump(settings, f, indent=2)
        f.write("\n")
    os.replace(tmp_path, settings_path)
except BaseException:
    os.unlink(tmp_path)
    raise

if added:
    print(f"  Seeded {len(added)} missing key(s): {', '.join(added)}")
else:
    print("  All settings already present — no changes needed")
PYTHON_MERGE
then
  step_fail "Merge settings" "Python merge script failed"
  exit 1
fi

step_pass "Merge settings"

# ---------------------------------------------------------------------------
# Step 3: Ensure hook scripts are executable
# ---------------------------------------------------------------------------
echo "Step 3: Verifying hook permissions..."

hooks_dir="$SCRIPT_DIR/.claude/hooks"
if [[ -d "$hooks_dir" ]]; then
  chmod +x "$hooks_dir"/*.sh 2>/dev/null || true

  hook_check_errors=0
  for f in "$hooks_dir"/*.sh; do
    [[ -f "$f" ]] || continue
    if [[ ! -x "$f" ]]; then
      echo "  ERROR: Could not make executable: $f" >&2
      hook_check_errors=$((hook_check_errors + 1))
    fi
  done

  if [[ $hook_check_errors -gt 0 ]]; then
    step_fail "Hook permissions" "$hook_check_errors hook(s) still not executable after chmod"
    exit 1
  fi
  step_pass "Hook permissions"
else
  step_fail "Hook permissions" "Hooks directory not found: $hooks_dir"
  exit 1
fi

# ---------------------------------------------------------------------------
# Step 4: Set up skills worktree (also creates CLAUDE.md + rules symlinks)
# ---------------------------------------------------------------------------
echo "Step 4: Setting up skills worktree..."

SETUP_WORKTREE="$SCRIPT_DIR/setup-skills-worktree.sh"

if [[ ! -f "$SETUP_WORKTREE" ]]; then
  step_fail "Skills worktree" "Script not found: $SETUP_WORKTREE"
  exit 1
fi

if ! bash "$SETUP_WORKTREE"; then
  step_fail "Skills worktree" "setup-skills-worktree.sh exited with non-zero status"
  exit 1
fi

# Verify: skills worktree directory exists
if [[ ! -d "$SKILLS_WORKTREE/.claude/skills" ]]; then
  step_fail "Skills worktree" "Skills worktree directory not created at $SKILLS_WORKTREE"
  exit 1
fi

# Verify: all skill entries are symlinks pointing into the skills worktree
skill_count=0
skill_errors=0
for entry in "$CLAUDE_DIR/skills"/*/; do
  [[ -e "$entry" || -L "${entry%/}" ]] || continue
  entry="${entry%/}"
  skill_count=$((skill_count + 1))
  if [[ ! -L "$entry" ]]; then
    echo "  ERROR: Not a symlink (copy?): $entry" >&2
    skill_errors=$((skill_errors + 1))
  else
    resolved="$(readlink "$entry")"
    if [[ "$resolved" != "$SKILLS_WORKTREE/.claude/skills/"* ]]; then
      echo "  ERROR: Symlink target outside worktree: $entry -> $resolved" >&2
      skill_errors=$((skill_errors + 1))
    fi
  fi
done

if [[ $skill_count -eq 0 ]]; then
  step_fail "Skills worktree" "No skills found in $CLAUDE_DIR/skills/"
  exit 1
fi

if [[ $skill_errors -gt 0 ]]; then
  step_fail "Skills worktree" "$skill_errors skill(s) not correctly symlinked to worktree"
  exit 1
fi

step_pass "Skills worktree"

# ---------------------------------------------------------------------------
# Step 5: Verify CLAUDE.md symlink (through skills worktree)
# ---------------------------------------------------------------------------
echo "Step 5: Verifying CLAUDE.md symlink..."

# The skills worktree setup (step 4) creates this symlink.
# Verify it points to the worktree, not directly to the root repo.
CLAUDE_MD_LINK="$CLAUDE_DIR/CLAUDE.md"
CLAUDE_MD_EXPECTED="$SKILLS_WORKTREE/CLAUDE.md"

if [[ ! -L "$CLAUDE_MD_LINK" ]]; then
  # Worktree script didn't create it — create it now
  if [[ -f "$CLAUDE_MD_EXPECTED" ]]; then
    ln -sfn "$CLAUDE_MD_EXPECTED" "$CLAUDE_MD_LINK"
  else
    step_fail "Symlink CLAUDE.md" "Expected source not found: $CLAUDE_MD_EXPECTED"
    exit 1
  fi
fi

actual_target="$(readlink "$CLAUDE_MD_LINK")"
if [[ "$actual_target" == "$CLAUDE_MD_EXPECTED" ]]; then
  step_pass "Symlink CLAUDE.md"
elif [[ "$actual_target" == "$SCRIPT_DIR/CLAUDE.md" ]]; then
  # Points to root repo instead of worktree — fix it
  ln -sfn "$CLAUDE_MD_EXPECTED" "$CLAUDE_MD_LINK"
  step_pass "Symlink CLAUDE.md (migrated to worktree)"
else
  step_fail "Symlink CLAUDE.md" "Points to $actual_target, expected $CLAUDE_MD_EXPECTED"
  exit 1
fi

# ---------------------------------------------------------------------------
# Step 6: Verify rules symlink (through skills worktree)
# ---------------------------------------------------------------------------
echo "Step 6: Verifying rules symlink..."

RULES_LINK="$CLAUDE_DIR/rules"
RULES_EXPECTED="$SKILLS_WORKTREE/.claude/rules"

if [[ ! -L "$RULES_LINK" ]]; then
  if [[ -d "$RULES_EXPECTED" ]]; then
    ln -sfn "$RULES_EXPECTED" "$RULES_LINK"
  else
    step_fail "Symlink rules" "Expected source not found: $RULES_EXPECTED"
    exit 1
  fi
fi

actual_target="$(readlink "$RULES_LINK")"
if [[ "$actual_target" == "$RULES_EXPECTED" ]]; then
  step_pass "Symlink rules"
elif [[ "$actual_target" == "$SCRIPT_DIR/.claude/rules" ]]; then
  ln -sfn "$RULES_EXPECTED" "$RULES_LINK"
  step_pass "Symlink rules (migrated to worktree)"
else
  step_fail "Symlink rules" "Points to $actual_target, expected $RULES_EXPECTED"
  exit 1
fi

# ---------------------------------------------------------------------------
# Step 7: Verify hooks registered in settings.json
# ---------------------------------------------------------------------------
echo "Step 7: Verifying hook registration..."

# setup-skills-worktree.sh Step 6 should have registered all hooks.
# Verify that hook paths exist, are executable, and point to the skills worktree.
hook_verify_errors=0
while IFS= read -r hook_path; do
  [[ -z "$hook_path" ]] && continue
  if [[ ! -f "$hook_path" ]]; then
    echo "  ERROR: Hook not found: $hook_path" >&2
    hook_verify_errors=$((hook_verify_errors + 1))
  elif [[ ! -x "$hook_path" ]]; then
    echo "  ERROR: Hook not executable: $hook_path" >&2
    hook_verify_errors=$((hook_verify_errors + 1))
  fi
done < <(python3 - "$SETTINGS_DST" <<'PYTHON_HOOK_PATHS'
import json, sys
with open(sys.argv[1]) as f:
    data = json.load(f)
hooks = data.get("hooks", {})
if not isinstance(hooks, dict):
    sys.exit(0)
for event_entries in hooks.values():
    if not isinstance(event_entries, list):
        continue
    for group in event_entries:
        if not isinstance(group, dict):
            continue
        for hook in group.get("hooks", []):
            if isinstance(hook, dict) and hook.get("type") == "command":
                cmd = hook.get("command", "")
                if cmd:
                    print(cmd)
PYTHON_HOOK_PATHS
)

if [[ $hook_verify_errors -gt 0 ]]; then
  step_fail "Hook registration" "$hook_verify_errors hook(s) missing or not executable in settings.json"
else
  step_pass "Hook registration"
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo "=============================="
echo "  setup.sh — Results"
echo "=============================="

all_passed=true
for i in "${!STEP_NAMES[@]}"; do
  result="${STEP_RESULTS[$i]}"
  name="${STEP_NAMES[$i]}"
  if [[ "$result" == "PASS" ]]; then
    echo "  [PASS] $name"
  else
    echo "  [FAIL] $name"
    all_passed=false
  fi
done

echo "=============================="

if $all_passed; then
  echo "All steps passed. Claude Code config is installed."
  echo ""
  echo "Verify with:"
  echo "  ls -la ~/.claude/CLAUDE.md"
  echo "  ls -la ~/.claude/rules"
  echo "  ls -la ~/.claude/skills/"
  echo "  grep 'path/to' ~/.claude/settings.json && echo 'ERROR: placeholders remain' || echo 'OK'"
  exit 0
else
  echo "Some steps failed. Review the errors above."
  exit 1
fi
