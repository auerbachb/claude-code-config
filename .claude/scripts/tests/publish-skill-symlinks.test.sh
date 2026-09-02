#!/bin/bash
# publish-skill-symlinks.test.sh — Tests for .claude/scripts/publish-skill-symlinks.sh
# Issue #1524: the skill / CLAUDE.md / rules symlink legs, extracted out of
# setup-skills-worktree.sh so a steady-state pass can publish them.
#
# Each test creates a throwaway HOME with a fake skills-worktree tree, runs the
# publisher, and asserts the filesystem result. No git and no network: the
# publisher is pure filesystem manipulation, so nothing needs mocking.
#
# Covers all five migrate_symlink states — already-correct, legacy-repoint,
# repoint-elsewhere, non-symlink-warn, missing-create — plus the ownership
# predicate that leaves user-owned symlinks alone.
#
# Usage: bash .claude/scripts/tests/publish-skill-symlinks.test.sh
# Exit code: 0 = all pass, 1 = any fail

set -uo pipefail

PASS=0; FAIL=0; TOTAL=0
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/../../.." && pwd)"
PUBLISH_SCRIPT="$REPO_ROOT/.claude/scripts/publish-skill-symlinks.sh"
GREEN='\033[0;32m'; RED='\033[0;31m'; BOLD='\033[1m'; NC='\033[0m'

# ── Helpers ───────────────────────────────────────────────────────────────────

assert() {
  # NOTE: $condition is always a script-authored string (never user input).
  local description="$1" condition="$2"
  TOTAL=$((TOTAL + 1))
  if eval "$condition" >/dev/null 2>&1; then
    echo -e "  ${GREEN}✓${NC} $description"
    PASS=$((PASS + 1))
  else
    echo -e "  ${RED}✗${NC} $description"
    FAIL=$((FAIL + 1))
  fi
}

section() { echo ""; echo -e "${BOLD}━━━ $1 ━━━${NC}"; }

# Create a temp HOME holding a fake skills-worktree with two skills, a
# CLAUDE.md and a rules directory. Prints the temp HOME path.
make_test_home() {
  local tmp_home
  tmp_home="$(mktemp -d)"
  local fake_wt="$tmp_home/.claude/skills-worktree"
  mkdir -p "$fake_wt/.claude/skills/alpha" "$fake_wt/.claude/skills/beta" "$fake_wt/.claude/rules"
  printf '# alpha skill\n'  > "$fake_wt/.claude/skills/alpha/SKILL.md"
  printf '# beta skill\n'   > "$fake_wt/.claude/skills/beta/SKILL.md"
  printf '# rules\n'        > "$fake_wt/.claude/rules/safety.md"
  printf '# CLAUDE.md\n'    > "$fake_wt/CLAUDE.md"
  echo "$tmp_home"
}

cleanup() { rm -rf "$1"; }

# ── Prerequisite ──────────────────────────────────────────────────────────────

section "Prerequisite"
HELP_ERR="$(mktemp -t pss-help-err.XXXXXX)"
trap 'rm -f "$HELP_ERR"' EXIT
assert "publish-skill-symlinks.sh exists" "[ -f '$PUBLISH_SCRIPT' ]"
assert "publish-skill-symlinks.sh is executable" "[ -x '$PUBLISH_SCRIPT' ]"
assert "--help exits 0 with no stderr" \
  "out=\$(bash '$PUBLISH_SCRIPT' --help 2>'$HELP_ERR'); [ \$? -eq 0 ] && [ ! -s '$HELP_ERR' ] && [ -n \"\$out\" ]"
assert "--help documents the arguments and the exit-code contract" \
  "out=\$(bash '$PUBLISH_SCRIPT' --help 2>/dev/null); printf '%s' \"\$out\" | grep -q 'skills-worktree' && printf '%s' \"\$out\" | grep -q 'Exit 0'"
assert "missing argument is a usage error (exit 2)" \
  "bash '$PUBLISH_SCRIPT' >/dev/null 2>&1; [ \$? -eq 2 ]"

# ── Test 1: missing-create — fresh HOME gets every link ───────────────────────

test_1_missing_create() {
  section "Test 1: missing-create — fresh HOME gets skills, CLAUDE.md and rules"

  local tmp_home fake_wt output exit_code
  tmp_home="$(make_test_home)"
  fake_wt="$tmp_home/.claude/skills-worktree"

  output="$(HOME="$tmp_home" bash "$PUBLISH_SCRIPT" "$fake_wt" 2>&1)"
  exit_code=$?

  assert "publish exits 0" "[ $exit_code -eq 0 ]"
  assert "~/.claude/skills/ created" "[ -d '$tmp_home/.claude/skills' ]"
  assert "alpha symlinked" "[ -L '$tmp_home/.claude/skills/alpha' ]"
  assert "beta symlinked" "[ -L '$tmp_home/.claude/skills/beta' ]"
  assert "alpha resolves to a real directory" "[ -d '$tmp_home/.claude/skills/alpha' ]"
  assert "alpha points into the worktree" \
    "[ \"\$(readlink '$tmp_home/.claude/skills/alpha')\" = '$fake_wt/.claude/skills/alpha' ]"
  assert "CLAUDE.md symlinked into the worktree" \
    "[ -L '$tmp_home/.claude/CLAUDE.md' ] && [ \"\$(readlink '$tmp_home/.claude/CLAUDE.md')\" = '$fake_wt/CLAUDE.md' ]"
  assert "rules symlinked into the worktree" \
    "[ -L '$tmp_home/.claude/rules' ] && [ \"\$(readlink '$tmp_home/.claude/rules')\" = '$fake_wt/.claude/rules' ]"
  assert "output reports the created links" \
    "printf '%s' \"\$output\" | grep -q 'symlinked'"

  cleanup "$tmp_home"
}

# ── Test 2: already-correct — a second run is a silent no-op ──────────────────

test_2_already_correct_is_silent() {
  section "Test 2: already-correct — second run changes nothing and says nothing"

  local tmp_home fake_wt before output exit_code
  tmp_home="$(make_test_home)"
  fake_wt="$tmp_home/.claude/skills-worktree"

  HOME="$tmp_home" bash "$PUBLISH_SCRIPT" "$fake_wt" >/dev/null 2>&1
  before="$(readlink "$tmp_home/.claude/skills/alpha")"

  output="$(HOME="$tmp_home" bash "$PUBLISH_SCRIPT" "$fake_wt" 2>&1)"
  exit_code=$?

  assert "second run exits 0" "[ $exit_code -eq 0 ]"
  assert "alpha target unchanged" \
    "[ \"\$(readlink '$tmp_home/.claude/skills/alpha')\" = '$before' ]"
  assert "second run prints nothing (true no-op)" "[ -z \"\$output\" ]"
  assert "CLAUDE.md still correct" "[ -L '$tmp_home/.claude/CLAUDE.md' ]"

  cleanup "$tmp_home"
}

# ── Test 3: ownership — a user-owned symlink is left alone ────────────────────

test_3_user_owned_preserved() {
  section "Test 3: ownership — user-owned symlink survives, others still publish"

  local tmp_home fake_wt user_target output exit_code
  tmp_home="$(make_test_home)"
  fake_wt="$tmp_home/.claude/skills-worktree"

  mkdir -p "$tmp_home/.claude/skills"
  user_target="$tmp_home/my-personal-skill"
  mkdir -p "$user_target"
  ln -s "$user_target" "$tmp_home/.claude/skills/alpha"

  output="$(HOME="$tmp_home" bash "$PUBLISH_SCRIPT" "$fake_wt" 2>&1)"
  exit_code=$?

  assert "publish exits 0" "[ $exit_code -eq 0 ]"
  assert "user-owned alpha still points at the user's target" \
    "[ \"\$(readlink '$tmp_home/.claude/skills/alpha')\" = '$user_target' ]"
  assert "output names the user-owned link" \
    "printf '%s' \"\$output\" | grep -q 'user-owned symlink'"
  assert "non-conflicting beta is still published" \
    "[ -L '$tmp_home/.claude/skills/beta' ]"

  cleanup "$tmp_home"
}

# ── Test 4: prune — a stale setup-owned symlink is removed ────────────────────

test_4_stale_pruned() {
  section "Test 4: prune — stale setup-owned symlink for a removed skill"

  local tmp_home fake_wt output exit_code
  tmp_home="$(make_test_home)"
  fake_wt="$tmp_home/.claude/skills-worktree"

  HOME="$tmp_home" bash "$PUBLISH_SCRIPT" "$fake_wt" >/dev/null 2>&1
  assert "(setup) beta symlinked before removal" "[ -L '$tmp_home/.claude/skills/beta' ]"

  rm -rf "$fake_wt/.claude/skills/beta"

  output="$(HOME="$tmp_home" bash "$PUBLISH_SCRIPT" "$fake_wt" 2>&1)"
  exit_code=$?

  assert "publish exits 0 after the skill left the worktree" "[ $exit_code -eq 0 ]"
  assert "stale beta symlink removed" \
    "[ ! -e '$tmp_home/.claude/skills/beta' ] && [ ! -L '$tmp_home/.claude/skills/beta' ]"
  assert "alpha still intact" "[ -L '$tmp_home/.claude/skills/alpha' ]"
  assert "prune reported in output" "printf '%s' \"\$output\" | grep -q 'stale symlink'"

  cleanup "$tmp_home"
}

# ── Test 5: legacy-repoint — a root-repo symlink migrates to the worktree ─────

test_5_legacy_repoint() {
  section "Test 5: legacy-repoint — root-repo links migrate to the worktree"

  local tmp_home fake_wt fake_root output exit_code
  tmp_home="$(make_test_home)"
  fake_wt="$tmp_home/.claude/skills-worktree"
  fake_root="$tmp_home/root-repo"

  mkdir -p "$fake_root/.claude/skills/alpha" "$fake_root/.claude/rules"
  printf '# legacy CLAUDE.md\n' > "$fake_root/CLAUDE.md"
  mkdir -p "$tmp_home/.claude/skills"
  ln -s "$fake_root/.claude/skills/alpha" "$tmp_home/.claude/skills/alpha"
  ln -s "$fake_root/CLAUDE.md" "$tmp_home/.claude/CLAUDE.md"
  ln -s "$fake_root/.claude/rules" "$tmp_home/.claude/rules"

  output="$(HOME="$tmp_home" bash "$PUBLISH_SCRIPT" "$fake_wt" "$fake_root" 2>&1)"
  exit_code=$?

  assert "publish exits 0" "[ $exit_code -eq 0 ]"
  assert "alpha migrated to the worktree" \
    "[ \"\$(readlink '$tmp_home/.claude/skills/alpha')\" = '$fake_wt/.claude/skills/alpha' ]"
  assert "CLAUDE.md migrated to the worktree" \
    "[ \"\$(readlink '$tmp_home/.claude/CLAUDE.md')\" = '$fake_wt/CLAUDE.md' ]"
  assert "rules migrated to the worktree" \
    "[ \"\$(readlink '$tmp_home/.claude/rules')\" = '$fake_wt/.claude/rules' ]"
  assert "migration is reported" \
    "printf '%s' \"\$output\" | grep -qE '(migrating|updating|symlinked)'"

  cleanup "$tmp_home"
}

# ── Test 6: legacy link whose skill is not on main yet — preserved + warned ───

test_6_legacy_not_on_main_warns() {
  section "Test 6: legacy link for a skill not yet on main is kept, with a warning"

  local tmp_home fake_wt fake_root stderr_out exit_code
  tmp_home="$(make_test_home)"
  fake_wt="$tmp_home/.claude/skills-worktree"
  fake_root="$tmp_home/root-repo"

  # 'gamma' exists in the root repo but NOT in the worktree.
  mkdir -p "$fake_root/.claude/skills/gamma" "$tmp_home/.claude/skills"
  ln -s "$fake_root/.claude/skills/gamma" "$tmp_home/.claude/skills/gamma"

  stderr_out="$(HOME="$tmp_home" bash "$PUBLISH_SCRIPT" "$fake_wt" "$fake_root" 2>&1 >/dev/null)"
  exit_code=$?

  assert "publish exits 0" "[ $exit_code -eq 0 ]"
  assert "legacy gamma link preserved (not pruned)" \
    "[ -L '$tmp_home/.claude/skills/gamma' ]"
  assert "gamma still points at the root repo" \
    "[ \"\$(readlink '$tmp_home/.claude/skills/gamma')\" = '$fake_root/.claude/skills/gamma' ]"
  assert "warning names the not-on-main case" \
    "printf '%s' \"\$stderr_out\" | grep -q 'not in worktree'"

  cleanup "$tmp_home"
}

# ── Test 7: repoint-elsewhere — a setup-owned link at the wrong target ────────

test_7_repoint_elsewhere() {
  section "Test 7: repoint-elsewhere — setup-owned link pointing at the wrong skill"

  local tmp_home fake_wt output exit_code
  tmp_home="$(make_test_home)"
  fake_wt="$tmp_home/.claude/skills-worktree"

  # alpha's link points at beta's directory: inside the worktree, so setup owns
  # it, but at the wrong target — the repoint branch.
  mkdir -p "$tmp_home/.claude/skills"
  ln -s "$fake_wt/.claude/skills/beta" "$tmp_home/.claude/skills/alpha"

  output="$(HOME="$tmp_home" bash "$PUBLISH_SCRIPT" "$fake_wt" 2>&1)"
  exit_code=$?

  assert "publish exits 0" "[ $exit_code -eq 0 ]"
  assert "alpha repointed at its own worktree directory" \
    "[ \"\$(readlink '$tmp_home/.claude/skills/alpha')\" = '$fake_wt/.claude/skills/alpha' ]"
  assert "repoint reported in output" \
    "printf '%s' \"\$output\" | grep -q 'updating symlink'"

  cleanup "$tmp_home"
}

# ── Test 8: non-symlink-warn — a real file is never overwritten ───────────────

test_8_non_symlink_preserved() {
  section "Test 8: non-symlink-warn — a hand-authored CLAUDE.md is never clobbered"

  local tmp_home fake_wt stderr_out exit_code
  tmp_home="$(make_test_home)"
  fake_wt="$tmp_home/.claude/skills-worktree"

  mkdir -p "$tmp_home/.claude"
  printf 'hand written, do not touch\n' > "$tmp_home/.claude/CLAUDE.md"

  stderr_out="$(HOME="$tmp_home" bash "$PUBLISH_SCRIPT" "$fake_wt" 2>&1 >/dev/null)"
  exit_code=$?

  assert "publish exits 0" "[ $exit_code -eq 0 ]"
  assert "CLAUDE.md is still a regular file" \
    "[ -f '$tmp_home/.claude/CLAUDE.md' ] && [ ! -L '$tmp_home/.claude/CLAUDE.md' ]"
  assert "CLAUDE.md content untouched" \
    "grep -q 'hand written' '$tmp_home/.claude/CLAUDE.md'"
  assert "warning names the non-symlink" \
    "printf '%s' \"\$stderr_out\" | grep -q 'is not a symlink'"

  cleanup "$tmp_home"
}

# ── Test 9: directory copy is replaced with a symlink ─────────────────────────

test_9_directory_copy_replaced() {
  section "Test 9: a pre-worktree directory COPY is replaced with a symlink"

  local tmp_home fake_wt output exit_code
  tmp_home="$(make_test_home)"
  fake_wt="$tmp_home/.claude/skills-worktree"

  mkdir -p "$tmp_home/.claude/skills/alpha"
  printf '# stale copy\n' > "$tmp_home/.claude/skills/alpha/SKILL.md"

  output="$(HOME="$tmp_home" bash "$PUBLISH_SCRIPT" "$fake_wt" 2>&1)"
  exit_code=$?

  assert "publish exits 0" "[ $exit_code -eq 0 ]"
  assert "alpha is now a symlink" "[ -L '$tmp_home/.claude/skills/alpha' ]"
  assert "alpha points into the worktree" \
    "[ \"\$(readlink '$tmp_home/.claude/skills/alpha')\" = '$fake_wt/.claude/skills/alpha' ]"
  assert "replacement reported in output" \
    "printf '%s' \"\$output\" | grep -q 'replacing directory copy'"

  cleanup "$tmp_home"
}

# ── Test 10: a trailing slash on the worktree argument changes nothing ────────

test_10_trailing_slash_argument() {
  section "Test 10: a trailing slash on the worktree path does not break ownership"

  local tmp_home fake_wt output exit_code
  tmp_home="$(make_test_home)"
  fake_wt="$tmp_home/.claude/skills-worktree"

  # First run with the canonical path, then a second with a TRAILING SLASH.
  # skill_owned_by_setup normalizes the symlink target before its prefix test,
  # so an un-normalized prefix would make every managed link look user-owned —
  # the publisher would then silently refuse to touch anything it owns.
  HOME="$tmp_home" bash "$PUBLISH_SCRIPT" "$fake_wt" >/dev/null 2>&1
  output="$(HOME="$tmp_home" bash "$PUBLISH_SCRIPT" "$fake_wt/" 2>&1)"
  exit_code=$?

  assert "run with a trailing slash exits 0" "[ $exit_code -eq 0 ]"
  assert "it stays a true no-op (no output at all)" "[ -z \"\$output\" ]"
  assert "no managed link was misread as user-owned" \
    "! printf '%s' \"\$output\" | grep -q 'user-owned'"
  assert "alpha still points at the canonical worktree path" \
    "[ \"\$(readlink '$tmp_home/.claude/skills/alpha')\" = '$fake_wt/.claude/skills/alpha' ]"

  cleanup "$tmp_home"
}

# ── Test 11: regression — setup-skills-worktree.sh delegates here ─────────────

test_11_regression_setup_delegates() {
  section "Test 11: regression — setup-skills-worktree.sh delegates to this script"

  local setup="$REPO_ROOT/setup-skills-worktree.sh"
  assert "setup-skills-worktree.sh exists" "[ -f '$setup' ]"
  assert "setup invokes publish-skill-symlinks.sh" \
    "grep -qE 'bash \"?\\\$\\{?SKILLS_PUBLISH_SCRIPT' '$setup'"
  assert "setup no longer carries its own migrate_symlink state machine" \
    "! grep -q '^migrate_symlink()' '$setup'"
  assert "setup no longer carries its own skill_owned_by_setup predicate" \
    "! grep -q '^skill_owned_by_setup()' '$setup'"

  local hook="$REPO_ROOT/.claude/hooks/session-start-sync.sh"
  assert "session-start-sync.sh publishes skill symlinks too" \
    "grep -q 'publish-skill-symlinks' '$hook'"
}

# ── Main ──────────────────────────────────────────────────────────────────────

echo ""
echo -e "${BOLD}╔══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}║  publish-skill-symlinks.sh test suite (issue #1524)          ║${NC}"
echo -e "${BOLD}╚══════════════════════════════════════════════════════════════╝${NC}"

test_1_missing_create
test_2_already_correct_is_silent
test_3_user_owned_preserved
test_4_stale_pruned
test_5_legacy_repoint
test_6_legacy_not_on_main_warns
test_7_repoint_elsewhere
test_8_non_symlink_preserved
test_9_directory_copy_replaced
test_10_trailing_slash_argument
test_11_regression_setup_delegates

echo ""
echo -e "${BOLD}━━━ Summary ━━━${NC}"
if [ $FAIL -eq 0 ]; then
  echo -e "${GREEN}${BOLD}ALL PASSED${NC}: $PASS/$TOTAL tests"
  exit 0
else
  echo -e "${RED}${BOLD}FAILURES${NC}: $FAIL/$TOTAL tests failed ($PASS passed)"
  exit 1
fi
