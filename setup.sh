#!/bin/bash
# setup.sh — Idempotent installer for claude-code-config
#
# Derives all paths from the script's own location (SCRIPT_DIR).
# Safe to run multiple times — backs up settings.json before overwrite,
# exits fast on failure with a clear error message.
#
# Usage: bash ./setup.sh

set -euo pipefail

# ---------------------------------------------------------------------------
# Path derivation — everything is relative to this script's location
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

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

# ---------------------------------------------------------------------------
# Prerequisites
# ---------------------------------------------------------------------------
if ! command -v git >/dev/null 2>&1; then
  echo "FAIL: git is not installed or not in PATH." >&2
  exit 1
fi


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
# Step 2: Install settings.json (copy + path replacement)
# ---------------------------------------------------------------------------
echo "Step 2: Installing settings.json..."

SETTINGS_SRC="$SCRIPT_DIR/global-settings.json"
SETTINGS_DST="$CLAUDE_DIR/settings.json"

if [[ ! -f "$SETTINGS_SRC" ]]; then
  step_fail "Install settings.json" "Source file not found: $SETTINGS_SRC"
  exit 1
fi

# Back up existing settings.json if present
if [[ -f "$SETTINGS_DST" ]]; then
  backup="$SETTINGS_DST.bak.$(date +%Y%m%d%H%M%S)"
  cp "$SETTINGS_DST" "$backup"
  echo "  Backed up existing settings.json to $backup"
fi

cp "$SETTINGS_SRC" "$SETTINGS_DST"

# Replace placeholder paths with this clone's absolute path (works on both macOS and Linux)
# Escape & and \ in SCRIPT_DIR so sed doesn't misinterpret them in replacement text
ESCAPED_DIR="$(printf '%s\n' "$SCRIPT_DIR" | sed 's/[&\\/]/\\&/g')"
if sed --version >/dev/null 2>&1; then
  # GNU sed (Linux)
  sed -i "s|/path/to/claude-code-config|$ESCAPED_DIR|g" "$SETTINGS_DST"
else
  # BSD sed (macOS)
  sed -i '' "s|/path/to/claude-code-config|$ESCAPED_DIR|g" "$SETTINGS_DST"
fi

# Verify: no placeholders remain
if grep -q '/path/to/claude-code-config' "$SETTINGS_DST"; then
  step_fail "Install settings.json" "Placeholder paths still present in $SETTINGS_DST"
  exit 1
fi

# Verify: settings.json contains this clone's SCRIPT_DIR
if ! grep -Fq -- "$SCRIPT_DIR" "$SETTINGS_DST"; then
  step_fail "Install settings.json" "settings.json does not contain paths to $SCRIPT_DIR"
  exit 1
fi

# Ensure hooks are executable before verifying (handles missing execute bits
# from tarballs, WSL, or CI environments where git didn't preserve modes)
chmod +x "$SCRIPT_DIR/.claude/hooks"/*.sh 2>/dev/null || true

# Verify: ALL hook paths referenced in settings.json exist and are executable
hook_errors=0
while IFS= read -r hook_path; do
  if [[ ! -f "$hook_path" ]]; then
    echo "  ERROR: Hook not found: $hook_path" >&2
    hook_errors=$((hook_errors + 1))
  elif [[ ! -x "$hook_path" ]]; then
    echo "  ERROR: Hook not executable: $hook_path" >&2
    hook_errors=$((hook_errors + 1))
  fi
done < <(grep -o '"command": "[^"]*"' "$SETTINGS_DST" | sed 's/"command": "//;s/"$//')

if [[ $hook_errors -gt 0 ]]; then
  step_fail "Install settings.json" "$hook_errors hook(s) missing or not executable"
  exit 1
fi

step_pass "Install settings.json"

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
