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
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd)"
GREEN='\033[0;32m'
RED='\033[0;31m'
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

ensure_safe_environment() {
  if [[ "${ALLOW_LOCAL_DESTRUCTIVE_TESTS:-0}" != "1" && ! -f "/.dockerenv" ]]; then
    echo -e "${RED}Refusing to run destructive setup tests outside Docker.${NC}" >&2
    echo "Set ALLOW_LOCAL_DESTRUCTIVE_TESTS=1 to override intentionally." >&2
    exit 1
  fi
}

clean_slate() {
  # Remove all setup artifacts to start fresh
  rm -rf "$HOME/.claude"
  rm -f "$HOME/.claude.json"
}

run_setup() {
  # Run setup.sh from repo root, capture output
  cd "$REPO_ROOT" || return 1
  bash setup.sh 2>&1
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
  assert "CLAUDE.md points to skills-worktree" "python3 -c \"import os; h=os.path.expanduser('~'); assert os.readlink(os.path.join(h,'.claude','CLAUDE.md')) == os.path.join(h,'.claude','skills-worktree','CLAUDE.md')\""
  assert "rules points to skills-worktree" "python3 -c \"import os; h=os.path.expanduser('~'); assert os.readlink(os.path.join(h,'.claude','rules')) == os.path.join(h,'.claude','skills-worktree','.claude','rules')\""

  # Check that at least some skills are symlinked
  local skill_count
  skill_count=$(find "$HOME/.claude/skills" -maxdepth 1 -type l 2>/dev/null | wc -l)
  assert "At least 1 skill symlinked" "[ $skill_count -gt 0 ]"

  # Check settings.json has hooks
  assert "settings.json contains hooks" "python3 -c \"import json; d=json.load(open('$HOME/.claude/settings.json')); assert 'hooks' in d\""

  # Check settings.json hooks have real paths (not placeholders)
  assert "No placeholder paths in settings.json" "! grep -q '/path/to/' '$HOME/.claude/settings.json'"
  assert "Graphite plugin marketplace seeded" "python3 -c \"import json; d=json.load(open('$HOME/.claude/settings.json')); assert 'extraKnownMarketplaces' in d and 'claude-code-graphite' in d['extraKnownMarketplaces']\""
  assert "Graphite plugins enabled in settings" "python3 -c \"import json; d=json.load(open('$HOME/.claude/settings.json')); ep=d.get('enabledPlugins',{}); assert ep.get('graphite@claude-code-graphite') is True and ep.get('graphite-mcp@claude-code-graphite') is True\""
}

# ── Test 2: Idempotent re-run ────────────────────────────────────────────────

test_2_idempotent() {
  section "Test 2: Idempotent re-run"

  # Capture state before
  local settings_hash_before hooks_before
  settings_hash_before=$(sha256sum "$HOME/.claude/settings.json" | awk '{print $1}')
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
  local settings_hash_after hooks_after
  settings_hash_after=$(sha256sum "$HOME/.claude/settings.json" | awk '{print $1}')
  hooks_after=$(python3 -c "
import json
d = json.load(open('$HOME/.claude/settings.json'))
hooks = d.get('hooks', {})
count = sum(len(group.get('hooks', [])) for groups in hooks.values() for group in groups)
print(count)
" 2>/dev/null || echo "0")

  assert "settings.json unchanged after re-run" "[ '$settings_hash_before' = '$settings_hash_after' ]"
  assert "Hook count unchanged after re-run" "[ '$hooks_before' = '$hooks_after' ]"
  assert "Symlinks still valid" "[ -e '$HOME/.claude/CLAUDE.md' ] && [ -e '$HOME/.claude/rules' ]"
}

# ── Test 3: Existing settings preserved ──────────────────────────────────────

test_3_settings_preserved() {
  section "Test 3: Existing settings preserved"

  # Inject custom keys AND remove a template key to test re-seeding
  python3 -c "
import json
path = '$HOME/.claude/settings.json'
with open(path) as f:
    data = json.load(f)

data['model'] = 'sonnet'
data['permissions'] = {'allow': ['Read']}
data['env'] = {'CUSTOM_VAR': 'keep_me', 'ANOTHER': 'also_keep'}
data['extraKnownMarketplaces'] = {'test': True}
# Remove a template-provided key to test that setup.sh re-seeds it
data.pop('permissions', None)

with open(path, 'w') as f:
    json.dump(data, f, indent=2)
"

  local output
  output=$(run_setup)
  local exit_code=$?

  assert "setup.sh exits 0" "[ $exit_code -eq 0 ]"

  # Check preserved keys
  assert "model key preserved" "python3 -c \"import json; d=json.load(open('$HOME/.claude/settings.json')); assert d['model'] == 'sonnet', f'got {d[\\\"model\\\"]}'\""
  assert "permissions key re-seeded" "python3 -c \"import json; d=json.load(open('$HOME/.claude/settings.json')); assert 'permissions' in d, 'permissions not re-seeded'\""
  assert "env.CUSTOM_VAR preserved" "python3 -c \"import json; d=json.load(open('$HOME/.claude/settings.json')); assert d['env']['CUSTOM_VAR'] == 'keep_me'\""
  assert "env.ANOTHER preserved" "python3 -c \"import json; d=json.load(open('$HOME/.claude/settings.json')); assert d['env']['ANOTHER'] == 'also_keep'\""
  assert "extraKnownMarketplaces preserved" "python3 -c \"import json; d=json.load(open('$HOME/.claude/settings.json')); assert 'extraKnownMarketplaces' in d\""
  assert "hooks still registered" "python3 -c \"import json; d=json.load(open('$HOME/.claude/settings.json')); assert 'hooks' in d\""
}

# ── Test 4: Hook path migration ──────────────────────────────────────────────

test_4_hook_path_migration() {
  section "Test 4: Hook path migration"

  # Replace a hook path with a stale root-repo path
  local seed_output
  seed_output=$(python3 -c "
import json, sys
path = '$HOME/.claude/settings.json'
with open(path) as f:
    data = json.load(f)

# Find the first hook with a skills-worktree path and replace it
migrated_seeded = False
for event_key, event_groups in data.get('hooks', {}).items():
    for group in event_groups:
        for hook in group.get('hooks', []):
            if 'command' in hook and 'skills-worktree' in hook['command']:
                hook['command'] = hook['command'].replace('/.claude/skills-worktree/', '/')
                migrated_seeded = True
                break
        if migrated_seeded:
            break
    if migrated_seeded:
        break

if not migrated_seeded:
    print('ERROR: No hook with skills-worktree path found to seed migration test', file=sys.stderr)
    sys.exit(1)

with open(path, 'w') as f:
    json.dump(data, f, indent=2)
print('Seeded stale path for migration test')
" 2>&1)
  local seed_exit=$?
  echo "  Seed output: $seed_output"
  assert "Stale path seed succeeded" "[ $seed_exit -eq 0 ]"

  # Run setup-skills-worktree.sh which handles migration
  cd "$REPO_ROOT" || { assert "Can cd to REPO_ROOT" "false"; return; }
  local migrate_output
  migrate_output=$(bash setup-skills-worktree.sh 2>&1)
  local migrate_exit_code=$?
  echo "$migrate_output" | tail -10
  assert "setup-skills-worktree.sh exits 0" "[ $migrate_exit_code -eq 0 ]"

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

if checked == 0:
    print('FAIL: No hooks found to check — settings.json may have empty hooks object')
    raise SystemExit(1)
elif errors:
    for e in errors:
        print(e)
    raise SystemExit(1)
else:
    print(f'All {checked} hook paths resolve to existing executables')
" 2>&1)
  local hooks_exit=$?

  echo "  $result"
  assert "All hook paths resolve" "[ $hooks_exit -eq 0 ]"
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

# ── Test 8: Stale hook registration pruned ───────────────────────────────────

test_8_stale_hook_pruned() {
  section "Test 8: Stale hook registration pruned"

  # Simulate a decommissioned hook (e.g. the /quota rollback) whose registration
  # still lives in settings.json pointing at a now-deleted managed hook script.
  # setup.sh Step 7 would fail on the missing path; setup-skills-worktree.sh
  # Step 6 must prune it — but ONLY managed roots, and it must respect command
  # arguments. Seed three registrations:
  #   1. stale managed hook (missing)          -> pruned
  #   2. stale hook under a NON-managed root    -> preserved (not ours)
  #   3. active managed hook WITH arguments     -> preserved (argv0 parsing)
  # Use a generic name for (1) so the test survives quota being long forgotten.
  local stale_cmd="$HOME/.claude/skills-worktree/.claude/hooks/decommissioned-quota-hook.sh"
  local ext_cmd="/tmp/other-tool/.claude/hooks/external-hook.sh"          # different tool's dir
  local args_cmd="$HOME/.claude/skills-worktree/.claude/hooks/trust-flag-repair.sh --check"  # real hook + args
  assert "Stale hook target does not exist" "[ ! -f '$stale_cmd' ]"
  assert "External hook target does not exist" "[ ! -f '$ext_cmd' ]"

  local seed_output
  seed_output=$(python3 -c "
import json, sys
path = '$HOME/.claude/settings.json'
with open(path, encoding='utf-8') as f:
    data = json.load(f)

hooks = data.setdefault('hooks', {})
stop = hooks.setdefault('Stop', [])
stop.append({'hooks': [{'type': 'command', 'command': '$stale_cmd', 'timeout': 5}]})
stop.append({'hooks': [{'type': 'command', 'command': '$ext_cmd', 'timeout': 5}]})
stop.append({'hooks': [{'type': 'command', 'command': '$args_cmd', 'timeout': 10}]})

with open(path, 'w', encoding='utf-8') as f:
    json.dump(data, f, indent=2)
print('Seeded stale + external + args hook registrations')
" 2>&1)
  local seed_exit=$?
  echo "  Seed output: $seed_output"
  assert "Stale hook seed succeeded" "[ $seed_exit -eq 0 ]"
  assert "Stale hook is registered before setup" "grep -q 'decommissioned-quota-hook.sh' '$HOME/.claude/settings.json'"

  # Run setup-skills-worktree.sh which prunes stale managed-hook registrations
  cd "$REPO_ROOT" || { assert "Can cd to REPO_ROOT" "false"; return; }
  local prune_output prune_exit_code
  prune_output=$(bash setup-skills-worktree.sh 2>&1)
  prune_exit_code=$?
  echo "$prune_output" | grep -i 'pruned' || true
  assert "setup-skills-worktree.sh exits 0" "[ $prune_exit_code -eq 0 ]"

  # (1) stale managed registration is gone
  assert "Stale managed hook registration pruned" "! grep -q 'decommissioned-quota-hook.sh' '$HOME/.claude/settings.json'"
  # (2) non-managed external hook is preserved (only OUR hooks dirs are pruned)
  assert "External non-managed hook preserved" "grep -q 'external-hook.sh' '$HOME/.claude/settings.json'"
  # (3) active hook with arguments preserved (argv0, not whole string, is checked)
  assert "Managed hook with arguments preserved" "grep -q 'trust-flag-repair.sh --check' '$HOME/.claude/settings.json'"
  assert "settings.json still valid JSON" "python3 -c \"import json; json.load(open('$HOME/.claude/settings.json'))\""
  assert "Active hook still registered (trust-flag-repair.sh)" "grep -q 'trust-flag-repair.sh' '$HOME/.claude/settings.json'"

  # setup.sh Step 7 now extracts argv0 from each hook command, so the args-bearing
  # entry (whose argv0 trust-flag-repair.sh IS a real file) must pass a full setup
  # run untouched. Only the non-managed external hook — whose argv0 file genuinely
  # does not exist — would (correctly) trip Step 7, so remove just that one
  # artifact and keep the args-bearing entry to exercise the argv0 path check.
  python3 -c "
import json
path = '$HOME/.claude/settings.json'
with open(path, encoding='utf-8') as f:
    data = json.load(f)
def is_artifact(cmd):
    return 'external-hook.sh' in cmd
for ev, groups in list(data.get('hooks', {}).items()):
    groups[:] = [g for g in groups
                 if not any(is_artifact(h.get('command', '')) for h in g.get('hooks', []))]
with open(path, 'w', encoding='utf-8') as f:
    json.dump(data, f, indent=2)
"

  # Full setup.sh passes Step 7 even with the args-bearing hook still registered:
  # Step 7 checks argv0 (the real trust-flag-repair.sh), not the raw command.
  local output exit_code
  output=$(run_setup)
  exit_code=$?
  echo "$output" | tail -40
  assert "setup.sh exits 0 with args-bearing hook registered" "[ $exit_code -eq 0 ]"
  # Step 7 tolerated the args-bearing hook — it survives the full setup run.
  assert "Args-bearing hook survives full setup (Step 7 checks argv0)" "grep -q 'trust-flag-repair.sh --check' '$HOME/.claude/settings.json'"

  # Negative case (#507): a command-type hook with a blank/non-string command is
  # malformed. Step 7 must FLAG it as a verification failure, not silently skip it
  # — otherwise setup.sh reports success on an unusable registration. Seed one
  # under a custom event (not in the manifest, so registration/prune leave it be).
  python3 -c "
import json
path = '$HOME/.claude/settings.json'
with open(path, encoding='utf-8') as f:
    data = json.load(f)
data.setdefault('hooks', {}).setdefault('CustomEvent', []).append(
    {'hooks': [{'type': 'command', 'command': ''}]})
with open(path, 'w', encoding='utf-8') as f:
    json.dump(data, f, indent=2)
"
  local malformed_out malformed_exit
  malformed_out=$(run_setup)
  malformed_exit=$?
  assert "setup.sh FAILS Step 7 on a malformed (blank) command hook" "[ $malformed_exit -ne 0 ]"
  assert "Step 7 reports the invalid command value" "grep -qi 'invalid command value' <<<\"\$malformed_out\""
  # Restore a clean state so the suite ends green.
  python3 -c "
import json
path = '$HOME/.claude/settings.json'
with open(path, encoding='utf-8') as f:
    data = json.load(f)
data.get('hooks', {}).pop('CustomEvent', None)
with open(path, 'w', encoding='utf-8') as f:
    json.dump(data, f, indent=2)
"
}

# ── Test 9: User-owned skill symlinks are preserved (issue #1198) ────────────

test_9_user_owned_skill_symlinks() {
  section "Test 9: User-owned skill symlinks preserved (prune and publish)"

  # This test verifies three behaviours from issue #1198:
  #  (a) A user-owned symlink whose target is outside the skills worktree survives
  #      a setup run and is named in the output (not silently deleted).
  #  (b) A genuinely stale setup-owned symlink (target inside the worktree but the
  #      skill no longer exists there) is still pruned.
  #  (c) When a skill NAME exists in the worktree AND the user already has a symlink
  #      for that name pointing elsewhere, setup does NOT silently repoint it to the
  #      worktree target.

  local skills_wt="$HOME/.claude/skills-worktree"
  local skills_dir="$HOME/.claude/skills"
  local worktree_skills="$skills_wt/.claude/skills"

  # Determine the first available worktree skill for test (c).
  local same_name_skill
  same_name_skill="$(find "$worktree_skills" -maxdepth 1 -mindepth 1 -exec basename {} \; 2>/dev/null | head -1)"
  if [[ -z "$same_name_skill" ]]; then
    echo "  SKIP: no skills in worktree — cannot test same-name preservation"
    return
  fi

  # External directory acting as the user's personal skill targets.
  local ext_dir
  ext_dir="$(mktemp -d)"

  # Snapshot the current state of the same-named link so we can restore it on exit.
  local same_name_link="$skills_dir/$same_name_skill"
  local same_name_orig_target=""
  local same_name_orig_existed=false
  local same_name_is_symlink=false
  if [[ -L "$same_name_link" ]]; then
    same_name_orig_target="$(readlink "$same_name_link")"
    same_name_orig_existed=true
    same_name_is_symlink=true
  elif [[ -e "$same_name_link" ]]; then
    # Pre-existing regular file or directory — do not overwrite; skip test (c).
    same_name_orig_existed=true
  fi

  # Register a cleanup trap that runs even on early return or assertion failure.
  local user_skill_link="$skills_dir/my-personal-skill-test-1198"
  local stale_link="$skills_dir/nonexistent-worktree-skill-test-1198"
  _test9_cleanup() {
    rm -rf "$ext_dir" 2>/dev/null || true
    rm -f "$user_skill_link" 2>/dev/null || true
    rm -f "$stale_link" 2>/dev/null || true
    if [[ "$same_name_orig_existed" == true && "$same_name_is_symlink" == true && -n "$same_name_orig_target" ]]; then
      ln -sfn "$same_name_orig_target" "$same_name_link" 2>/dev/null || true
    elif [[ "$same_name_orig_existed" == false ]]; then
      rm -f "$same_name_link" 2>/dev/null || true
    fi
    # If same_name was a non-symlink file/dir, we never touched it — nothing to restore.
  }
  trap _test9_cleanup RETURN

  # (a) Create a user-owned personal skill symlink pointing outside the worktree.
  mkdir -p "$ext_dir/my-personal-skill-test-1198"
  ln -sfn "$ext_dir/my-personal-skill-test-1198" "$user_skill_link"
  assert "(a) User-owned skill symlink created" "[ -L '$user_skill_link' ]"

  # (b) Create a stale setup-owned symlink (points into worktree, skill is gone).
  ln -sfn "$worktree_skills/nonexistent-worktree-skill-test-1198" "$stale_link"
  assert "(b) Stale setup-owned symlink created" "[ -L '$stale_link' ]"

  # (c) Test same-name preservation when either:
  #   - The existing entry is already a symlink (we snapshot+restore it), OR
  #   - There is no existing entry at all (cleanup removes the link we create).
  # Skip only if it is a regular file or directory — we must not overwrite those.
  local run_same_name_test=false
  if [[ "$same_name_is_symlink" == true || "$same_name_orig_existed" == false ]]; then
    run_same_name_test=true
    mkdir -p "$ext_dir/$same_name_skill"
    ln -sfn "$ext_dir/$same_name_skill" "$same_name_link"
    # Use direct [[ ]] checks: same_name_skill is filesystem-derived and must not
    # be interpolated into an eval'd string (shell-injection risk via metacharacters).
    # Use explicit if/else to avoid SC2015 — A && B || C is not if-then-else.
    if [[ -L "$same_name_link" ]]; then
      assert "(c) Same-name user-owned symlink placed" "true"
    else
      assert "(c) Same-name user-owned symlink placed" "false"
    fi
    local _c_actual_target
    _c_actual_target="$(readlink "$same_name_link" 2>/dev/null || true)"
    if [[ "$_c_actual_target" = "$ext_dir/$same_name_skill" ]]; then
      assert "(c) Same-name link points to external dir" "true"
    else
      assert "(c) Same-name link points to external dir" "false"
    fi
  elif [[ -e "$same_name_link" ]]; then
    echo "  SKIP (c): $same_name_skill exists as a non-symlink — skipping same-name preservation test"
  fi

  # Run setup-skills-worktree.sh (the code under test).
  cd "$REPO_ROOT" || { assert "Can cd to REPO_ROOT" "false"; return; }
  local setup_output
  setup_output=$(bash setup-skills-worktree.sh 2>&1)
  local setup_exit=$?
  echo "$setup_output" | tail -20

  assert "setup-skills-worktree.sh exits 0" "[ $setup_exit -eq 0 ]"

  # (a) User-owned link must still exist and still point to the external dir.
  assert "(a) User-owned symlink survived" "[ -L '$user_skill_link' ]"
  assert "(a) User-owned symlink target unchanged" \
    "[ \"\$(readlink '$user_skill_link')\" = '$ext_dir/my-personal-skill-test-1198' ]"
  assert "(a) Output names the user-owned link" \
    "grep -q 'my-personal-skill-test-1198' <<<\"\$setup_output\""

  # (b) Stale setup-owned link must have been removed.
  assert "(b) Stale setup-owned link pruned" "[ ! -L '$stale_link' ]"

  # (c) Same-name user-owned link must NOT have been repointed to the worktree.
  if [[ "$run_same_name_test" == true ]]; then
    # Direct check — same_name_skill is filesystem-derived; avoid interpolating
    # it into an eval'd string (shell-injection risk via metacharacters).
    # Explicit if/else avoids SC2015 (A && B || C is not if-then-else).
    local _c_after_target
    _c_after_target="$(readlink "$same_name_link" 2>/dev/null || true)"
    if [[ "$_c_after_target" = "$ext_dir/$same_name_skill" ]]; then
      assert "(c) Same-name link not repointed" "true"
    else
      assert "(c) Same-name link not repointed" "false"
    fi
  fi

  # Cleanup happens via the RETURN trap registered above.
}

# ── Main ─────────────────────────────────────────────────────────────────────

echo ""
echo -e "${BOLD}╔══════════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}║  claude-code-config setup.sh test suite              ║${NC}"
echo -e "${BOLD}╚══════════════════════════════════════════════════════╝${NC}"

ensure_safe_environment

test_1_fresh_install
test_2_idempotent
test_3_settings_preserved
test_4_hook_path_migration
test_5_broken_symlink_recovery
test_6_hooks_resolve
test_7_no_settings_json
test_8_stale_hook_pruned
test_9_user_owned_skill_symlinks

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
