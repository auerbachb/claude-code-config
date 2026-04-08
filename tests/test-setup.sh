#!/bin/bash
# test-setup.sh — Automated test suite for setup.sh and setup-skills-worktree.sh
# Runs 7 test scenarios validating fresh install, idempotency, settings merge,
# hook migration, symlink recovery, hook resolution, and from-scratch creation.
#
# Usage: bash tests/test-setup.sh  (or via Docker entrypoint)
# Exit code: 0 = all pass, 1 = any fail

set -uo pipefail

# ── Globals ──────────────────────────────────────────────────────────────────
PASS=0
FAIL=0
TOTAL=0
REPO_ROOT="/workspace"
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[0;33m'
BOLD='\033[1m'
NC='\033[0m' # No Color

# ── Helpers ──────────────────────────────────────────────────────────────────

assert() {
  # NOTE: $condition is always a script-authored string (never user input).
  # eval is intentional here — it lets test cases pass shell expressions as strings.
  local description="$1"
  local condition="$2"
  TOTAL=$((TOTAL + 1))
  if eval "$condition" >/dev/null 2>&1; then
    echo -e "  ${GREEN}✓${NC} $description"
    PASS=$((PASS + 1))
  else
    echo -e "  ${RED}✗${NC} $description"
    FAIL=$((FAIL + 1))
  fi
}

section() {
  echo ""
  echo -e "${BOLD}━━━ $1 ━━━${NC}"
}

clean_slate() {
  # Remove all setup artifacts to start fresh
  rm -rf "$HOME/.claude"
  rm -f "$HOME/.claude.json"
}

run_setup() {
  # Run setup.sh from repo root, capture output
  cd "$REPO_ROOT"
  bash setup.sh 2>&1
  return $?
}

# ── Test 1: Fresh install ────────────────────────────────────────────────────

test_1_fresh_install() {
  section "Test 1: Fresh install (empty ~/.claude/)"

  clean_slate
  local output
  output=$(run_setup)
  local exit_code=$?

  echo "$output" | head -30

  assert "setup.sh exits 0" "[ $exit_code -eq 0 ]"
  assert "~/.claude/ directory exists" "[ -d '$HOME/.claude' ]"
  assert "~/.claude/skills/ directory exists" "[ -d '$HOME/.claude/skills' ]"
  assert "~/.claude/settings.json exists" "[ -f '$HOME/.claude/settings.json' ]"
  assert "~/.claude/skills-worktree/ exists" "[ -d '$HOME/.claude/skills-worktree' ]"
  assert "~/.claude/CLAUDE.md is a symlink" "[ -L '$HOME/.claude/CLAUDE.md' ]"
  assert "~/.claude/rules is a symlink" "[ -L '$HOME/.claude/rules' ]"
  assert "CLAUDE.md symlink target exists" "[ -e '$HOME/.claude/CLAUDE.md' ]"
  assert "rules symlink target exists" "[ -e '$HOME/.claude/rules' ]"
  assert "CLAUDE.md points to skills-worktree" "readlink '$HOME/.claude/CLAUDE.md' | grep -q 'skills-worktree'"
  assert "rules points to skills-worktree" "readlink '$HOME/.claude/rules' | grep -q 'skills-worktree'"

  # Check that at least some skills are symlinked
  local skill_count
  skill_count=$(find "$HOME/.claude/skills" -maxdepth 1 -type l 2>/dev/null | wc -l)
  assert "At least 1 skill symlinked" "[ $skill_count -gt 0 ]"

  # Check settings.json has hooks
  assert "settings.json contains hooks" "python3 -c \"import json; d=json.load(open('$HOME/.claude/settings.json')); assert 'hooks' in d\""

  # Check settings.json hooks have real paths (not placeholders)
  assert "No placeholder paths in settings.json" "! grep -q '/path/to/' '$HOME/.claude/settings.json'"
}

# ── Test 2: Idempotent re-run ────────────────────────────────────────────────

test_2_idempotent() {
  section "Test 2: Idempotent re-run"

  # Capture state before
  local settings_before hooks_before
  settings_before=$(cat "$HOME/.claude/settings.json")
  hooks_before=$(python3 -c "
import json
d = json.load(open('$HOME/.claude/settings.json'))
hooks = d.get('hooks', {})
count = sum(len(group.get('hooks', [])) for groups in hooks.values() for group in groups)
print(count)
" 2>/dev/null || echo "0")

  local output
  output=$(run_setup)
  local exit_code=$?

  assert "setup.sh exits 0 on re-run" "[ $exit_code -eq 0 ]"

  # Capture state after
  local settings_after hooks_after
  settings_after=$(cat "$HOME/.claude/settings.json")
  hooks_after=$(python3 -c "
import json
d = json.load(open('$HOME/.claude/settings.json'))
hooks = d.get('hooks', {})
count = sum(len(group.get('hooks', [])) for groups in hooks.values() for group in groups)
print(count)
" 2>/dev/null || echo "0")

  assert "Hook count unchanged after re-run" "[ '$hooks_before' = '$hooks_after' ]"
  assert "Symlinks still valid" "[ -e '$HOME/.claude/CLAUDE.md' ] && [ -e '$HOME/.claude/rules' ]"
}

# ── Test 3: Existing settings preserved ──────────────────────────────────────

test_3_settings_preserved() {
  section "Test 3: Existing settings preserved"

  # Inject custom keys
  python3 -c "
import json
path = '$HOME/.claude/settings.json'
with open(path) as f:
    data = json.load(f)

data['model'] = 'sonnet'
data['permissions'] = {'allow': ['Read']}
data['env'] = {'CUSTOM_VAR': 'keep_me', 'ANOTHER': 'also_keep'}
data['extraKnownMarketplaces'] = {'test': True}

with open(path, 'w') as f:
    json.dump(data, f, indent=2)
"

  local output
  output=$(run_setup)
  local exit_code=$?

  assert "setup.sh exits 0" "[ $exit_code -eq 0 ]"

  # Check preserved keys
  assert "model key preserved" "python3 -c \"import json; d=json.load(open('$HOME/.claude/settings.json')); assert d['model'] == 'sonnet', f'got {d[\\\"model\\\"]}'\""
  assert "permissions key preserved" "python3 -c \"import json; d=json.load(open('$HOME/.claude/settings.json')); assert d['permissions'] == {'allow': ['Read']}\""
  assert "env.CUSTOM_VAR preserved" "python3 -c \"import json; d=json.load(open('$HOME/.claude/settings.json')); assert d['env']['CUSTOM_VAR'] == 'keep_me'\""
  assert "env.ANOTHER preserved" "python3 -c \"import json; d=json.load(open('$HOME/.claude/settings.json')); assert d['env']['ANOTHER'] == 'also_keep'\""
  assert "extraKnownMarketplaces preserved" "python3 -c \"import json; d=json.load(open('$HOME/.claude/settings.json')); assert 'extraKnownMarketplaces' in d\""
  assert "hooks still registered" "python3 -c \"import json; d=json.load(open('$HOME/.claude/settings.json')); assert 'hooks' in d\""
}

# ── Test 4: Hook path migration ──────────────────────────────────────────────

test_4_hook_path_migration() {
  section "Test 4: Hook path migration"

  # Replace a hook path with a stale root-repo path
  python3 -c "
import json
path = '$HOME/.claude/settings.json'
with open(path) as f:
    data = json.load(f)

# Find the first hook and replace its path with a stale root-repo path
for event_key, event_groups in data.get('hooks', {}).items():
    for group in event_groups:
        for hook in group.get('hooks', []):
            if 'command' in hook and 'skills-worktree' in hook['command']:
                # Replace with a stale root-repo path
                hook['command'] = hook['command'].replace('/.claude/skills-worktree/', '/')
                break
        break
    break

with open(path, 'w') as f:
    json.dump(data, f, indent=2)
"

  # Run setup-skills-worktree.sh which handles migration
  cd "$REPO_ROOT"
  bash setup-skills-worktree.sh 2>&1 | tail -10

  # Check that paths now point to skills-worktree
  assert "No stale root-repo hook paths" "python3 -c \"
import json
d = json.load(open('$HOME/.claude/settings.json'))
for event_key, groups in d.get('hooks', {}).items():
    for group in groups:
        for hook in group.get('hooks', []):
            cmd = hook.get('command', '')
            if '.claude/hooks/' in cmd and 'skills-worktree' not in cmd:
                raise AssertionError(f'Stale path found: {cmd}')
\""
}

# ── Test 5: Broken symlink recovery ──────────────────────────────────────────

test_5_broken_symlink_recovery() {
  section "Test 5: Broken symlink recovery"

  # Break the CLAUDE.md symlink
  rm -f "$HOME/.claude/CLAUDE.md"
  assert "CLAUDE.md symlink is gone" "[ ! -e '$HOME/.claude/CLAUDE.md' ]"

  # Break one skill symlink
  local first_skill
  first_skill=$(find "$HOME/.claude/skills" -maxdepth 1 -type l | head -1)
  if [ -n "$first_skill" ]; then
    local skill_name
    skill_name=$(basename "$first_skill")
    rm -f "$first_skill"
    assert "Skill symlink removed ($skill_name)" "[ ! -e '$first_skill' ]"
  fi

  # Run setup
  local output
  output=$(run_setup)
  local exit_code=$?

  assert "setup.sh exits 0 after recovery" "[ $exit_code -eq 0 ]"
  assert "CLAUDE.md symlink restored" "[ -L '$HOME/.claude/CLAUDE.md' ] && [ -e '$HOME/.claude/CLAUDE.md' ]"

  if [ -n "${skill_name:-}" ]; then
    assert "Skill symlink restored ($skill_name)" "[ -L '$HOME/.claude/skills/$skill_name' ]"
  fi
}

# ── Test 6: All hooks resolve to executables ─────────────────────────────────

test_6_hooks_resolve() {
  section "Test 6: All hooks resolve to executables"

  local result
  result=$(python3 -c "
import json

d = json.load(open('$HOME/.claude/settings.json'))
hooks = d.get('hooks', {})
errors = []
checked = 0

for event_key, groups in hooks.items():
    for group in groups:
        for hook in group.get('hooks', []):
            cmd = hook.get('command', '')
            if cmd:
                checked += 1
                import os
                if not os.path.isfile(cmd):
                    errors.append(f'NOT FOUND: {cmd}')
                elif not os.access(cmd, os.X_OK):
                    errors.append(f'NOT EXECUTABLE: {cmd}')

if errors:
    for e in errors:
        print(e)
    raise SystemExit(1)
else:
    print(f'All {checked} hook paths resolve to existing executables')
" 2>&1)

  echo "  $result"
  assert "All hook paths resolve" "echo '$result' | grep -q 'All .* hook paths resolve'"
}

# ── Test 7: No settings.json yet ─────────────────────────────────────────────

test_7_no_settings_json() {
  section "Test 7: No settings.json (created from scratch)"

  # Remove settings.json but keep the rest
  rm -f "$HOME/.claude/settings.json"
  assert "settings.json removed" "[ ! -f '$HOME/.claude/settings.json' ]"

  local output
  output=$(run_setup)
  local exit_code=$?

  assert "setup.sh exits 0" "[ $exit_code -eq 0 ]"
  assert "settings.json recreated" "[ -f '$HOME/.claude/settings.json' ]"
  assert "Hooks registered in new settings.json" "python3 -c \"import json; d=json.load(open('$HOME/.claude/settings.json')); assert 'hooks' in d\""
  assert "Valid JSON" "python3 -c \"import json; json.load(open('$HOME/.claude/settings.json'))\""
  assert "No placeholder paths" "! grep -q '/path/to/' '$HOME/.claude/settings.json'"
}

# ── Main ─────────────────────────────────────────────────────────────────────

echo ""
echo -e "${BOLD}╔══════════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}║  claude-code-config setup.sh test suite              ║${NC}"
echo -e "${BOLD}╚══════════════════════════════════════════════════════╝${NC}"

test_1_fresh_install
test_2_idempotent
test_3_settings_preserved
test_4_hook_path_migration
test_5_broken_symlink_recovery
test_6_hooks_resolve
test_7_no_settings_json

# ── Summary ──────────────────────────────────────────────────────────────────

echo ""
echo -e "${BOLD}━━━ Summary ━━━${NC}"
if [ $FAIL -eq 0 ]; then
  echo -e "${GREEN}${BOLD}ALL PASSED${NC}: $PASS/$TOTAL tests"
  exit 0
else
  echo -e "${RED}${BOLD}FAILURES${NC}: $FAIL/$TOTAL tests failed ($PASS passed)"
  exit 1
fi
