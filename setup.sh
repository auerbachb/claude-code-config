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
CLAUDE_DIR="$HOME/.claude"

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
# Step 2: Symlink CLAUDE.md (global instructions)
# ---------------------------------------------------------------------------
echo "Step 2: Symlinking CLAUDE.md..."

CLAUDE_MD_TARGET="$SCRIPT_DIR/CLAUDE.md"
CLAUDE_MD_LINK="$CLAUDE_DIR/CLAUDE.md"

if [[ ! -f "$CLAUDE_MD_TARGET" ]]; then
  step_fail "Symlink CLAUDE.md" "Source file not found: $CLAUDE_MD_TARGET"
  exit 1
fi

ln -sfn "$CLAUDE_MD_TARGET" "$CLAUDE_MD_LINK"

# Verify symlink resolves to THIS clone
actual_target="$(readlink "$CLAUDE_MD_LINK")"
if [[ "$actual_target" == "$CLAUDE_MD_TARGET" ]]; then
  step_pass "Symlink CLAUDE.md"
else
  step_fail "Symlink CLAUDE.md" "Symlink points to $actual_target, expected $CLAUDE_MD_TARGET"
  exit 1
fi

# ---------------------------------------------------------------------------
# Step 3: Symlink rule files
# ---------------------------------------------------------------------------
echo "Step 3: Symlinking rules..."

RULES_TARGET="$SCRIPT_DIR/.claude/rules"
RULES_LINK="$CLAUDE_DIR/rules"

if [[ ! -d "$RULES_TARGET" ]]; then
  step_fail "Symlink rules" "Source directory not found: $RULES_TARGET"
  exit 1
fi

ln -sfn "$RULES_TARGET" "$RULES_LINK"

actual_target="$(readlink "$RULES_LINK")"
if [[ "$actual_target" == "$RULES_TARGET" ]]; then
  step_pass "Symlink rules"
else
  step_fail "Symlink rules" "Symlink points to $actual_target, expected $RULES_TARGET"
  exit 1
fi

# ---------------------------------------------------------------------------
# Step 4: Install settings.json (copy + path replacement)
# ---------------------------------------------------------------------------
echo "Step 4: Installing settings.json..."

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
if sed --version >/dev/null 2>&1; then
  # GNU sed (Linux)
  sed -i "s|/path/to/claude-code-config|$SCRIPT_DIR|g" "$SETTINGS_DST"
else
  # BSD sed (macOS)
  sed -i '' "s|/path/to/claude-code-config|$SCRIPT_DIR|g" "$SETTINGS_DST"
fi

# Verify: no placeholders remain
if grep -q '/path/to/claude-code-config' "$SETTINGS_DST"; then
  step_fail "Install settings.json" "Placeholder paths still present in $SETTINGS_DST"
  exit 1
fi

# Verify: settings.json contains this clone's SCRIPT_DIR
if ! grep -q "$SCRIPT_DIR" "$SETTINGS_DST"; then
  step_fail "Install settings.json" "settings.json does not contain paths to $SCRIPT_DIR"
  exit 1
fi

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
# Step 5: Ensure hook scripts are executable
# ---------------------------------------------------------------------------
echo "Step 5: Verifying hook permissions..."

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
# Step 6: Set up skills worktree
# ---------------------------------------------------------------------------
echo "Step 6: Setting up skills worktree..."

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
if [[ ! -d "$CLAUDE_DIR/skills-worktree/.claude/skills" ]]; then
  step_fail "Skills worktree" "Skills worktree directory not created at $CLAUDE_DIR/skills-worktree"
  exit 1
fi

# Verify: at least one skill is symlinked
skill_count=0
for link in "$CLAUDE_DIR/skills"/*/; do
  [[ -L "${link%/}" ]] && skill_count=$((skill_count + 1))
done

if [[ $skill_count -eq 0 ]]; then
  step_fail "Skills worktree" "No skill symlinks found in $CLAUDE_DIR/skills/"
  exit 1
fi

step_pass "Skills worktree"

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
