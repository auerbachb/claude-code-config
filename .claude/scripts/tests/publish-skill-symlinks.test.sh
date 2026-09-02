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

# ── Test 12: regression — a broken python3 must not disable the publish ──────
#
# _normpath shells out to python3. Before the fix, normalize_arg fell back to
# the RAW argument while skill_owned_by_setup hard-failed to "not ours", so on
# a machine without a usable python3 every managed symlink was misclassified as
# user-owned: no repoint, no prune, and a "leaving user-owned symlink alone"
# advisory per link that was flatly untrue. Both sides must now agree.

test_12_regression_normpath_unavailable() {
  section "Test 12: regression — a broken python3 does not disable the publish"

  local tmp_home fake_wt legacy_root stub_dir output exit_code
  tmp_home="$(make_test_home)"
  fake_wt="$tmp_home/.claude/skills-worktree"

  # A legacy root-repo checkout holding the same skill, plus a link pointing at
  # it — the exact state the migration leg exists to repair.
  legacy_root="$tmp_home/legacy-repo"
  mkdir -p "$legacy_root/.claude/skills/alpha" "$tmp_home/.claude/skills"
  printf '# alpha (legacy copy)\n' > "$legacy_root/.claude/skills/alpha/SKILL.md"
  ln -s "$legacy_root/.claude/skills/alpha" "$tmp_home/.claude/skills/alpha"

  # Stub python3 as present-but-broken. It exits non-zero without printing, the
  # same shape as a missing interpreter from _normpath's point of view. It does
  # NOT forward to a real python3 — a stub that falls through would silently
  # test nothing.
  stub_dir="$tmp_home/stub-bin"
  mkdir -p "$stub_dir"
  printf '#!/bin/sh\nexit 1\n' > "$stub_dir/python3"
  chmod +x "$stub_dir/python3"

  output="$(HOME="$tmp_home" PATH="$stub_dir:$PATH" \
    bash "$PUBLISH_SCRIPT" "$fake_wt" "$legacy_root" 2>&1)"
  exit_code=$?

  assert "publish still exits 0 with a broken python3" "[ $exit_code -eq 0 ]"
  assert "the degradation is announced once, not silently absorbed" \
    "printf '%s' \"\$output\" | grep -q 'python3 unavailable'"
  assert "the legacy link was NOT misread as user-owned" \
    "! printf '%s' \"\$output\" | grep -q 'alpha — leaving user-owned'"
  assert "the legacy link was migrated into the worktree" \
    "[ \"\$(readlink '$tmp_home/.claude/skills/alpha')\" = '$fake_wt/.claude/skills/alpha' ]"
  assert "beta was still published" \
    "[ -L '$tmp_home/.claude/skills/beta' ]"

  # Control: with a WORKING python3 the same run emits no degradation notice,
  # so the assertion above is keyed to the stub and not to something the
  # publisher prints unconditionally.
  rm -f "$tmp_home/.claude/skills/alpha" "$tmp_home/.claude/skills/beta"
  ln -s "$legacy_root/.claude/skills/alpha" "$tmp_home/.claude/skills/alpha"
  output="$(HOME="$tmp_home" bash "$PUBLISH_SCRIPT" "$fake_wt" "$legacy_root" 2>&1)"
  assert "(control) a working python3 prints no degradation notice" \
    "! printf '%s' \"\$output\" | grep -q 'python3 unavailable'"
  assert "(control) and it migrates the legacy link just the same" \
    "[ \"\$(readlink '$tmp_home/.claude/skills/alpha')\" = '$fake_wt/.claude/skills/alpha' ]"

  cleanup "$tmp_home"
}

# ── Test 13: regression — setup preflights the publisher before mutating ─────

test_13_regression_setup_preflight() {
  section "Test 13: regression — setup checks for the publisher before Step 1"

  local setup="$REPO_ROOT/setup-skills-worktree.sh"
  local guard_line create_line
  # The existence guard must sit ABOVE the worktree-creating `worktree add`, so
  # a checkout missing the publisher fails without leaving a half-built install.
  guard_line="$(grep -n 'publish-skill-symlinks.sh not found' "$setup" | head -1 | cut -d: -f1)"
  create_line="$(grep -n 'worktree add' "$setup" | head -1 | cut -d: -f1)"

  assert "setup carries a missing-publisher guard" "[ -n '$guard_line' ]"
  assert "(control) setup still creates the worktree somewhere" "[ -n '$create_line' ]"
  assert "the guard precedes worktree creation" "[ '$guard_line' -lt '$create_line' ]"
  assert "the guard states that nothing was changed" \
    "grep -q 'Nothing has been changed' '$setup'"
}

# ── Test 14: regression — setup resolves the repo root without a usable cwd ──
#
# setup-skills-worktree.sh is invoked BY ABSOLUTE PATH from claude-config-sync.sh
# on the bootstrap path. That runs under launchd with cwd `/`, so a repo-root
# lookup anchored to the working directory finds no repository and the script
# aborts with "Could not find the root repo" — failing exactly the fresh-machine
# bootstrap it exists to perform. Both lookups must anchor to SCRIPT_DIR.

test_14_regression_setup_repo_root_is_cwd_independent() {
  section "Test 14: setup resolves the repo root independently of cwd"

  # Source-level assertions by necessity: the behavioural check would mean
  # running setup-skills-worktree.sh for real, and that script fetches and
  # resets ~/.claude/skills-worktree and adds a worktree to the developer's
  # actual repo. A test must never do that. These pin the two exact call sites
  # the fix changed, and the control below fails if either regresses to an
  # unanchored form.
  local setup="$REPO_ROOT/setup-skills-worktree.sh"
  local anchored_helper anchored_fallback
  anchored_helper="$(grep -c 'REPO_ROOT_HELPER" "\$SCRIPT_DIR"' "$setup")"
  anchored_fallback="$(grep -c 'git -C "\$SCRIPT_DIR" worktree list' "$setup")"

  assert "the helper call passes SCRIPT_DIR as its anchor" \
    "[ '$anchored_helper' -ge 1 ]"
  assert "the inline fallback anchors with git -C SCRIPT_DIR" \
    "[ '$anchored_fallback' -ge 1 ]"
  assert "(control) no unanchored root lookup survives anywhere in the script" \
    "! grep -q 'REPO_ROOT=\"\$(git worktree list' '$setup'"
  assert "the cwd-independence reason is recorded next to the lookup" \
    "grep -q 'never from the' '$setup'"
}

# ── Test 15: regression — a RELATIVE legacy link survives the prune ───────────
#
# Test 6 covers the absolute legacy link. The prune guard and the Step 3 trigger
# used to compare readlink's raw text against the absolute legacy path, while
# skill_owned_by_setup normalized the same target and called it setup-owned — so
# a relative legacy link for a skill not yet on main reached the prune loop and
# was deleted instead of preserved with the not-on-main warning.

test_15_regression_relative_legacy_link_preserved() {
  section "Test 15: regression — relative legacy link is preserved, not pruned"

  local tmp_home fake_wt fake_root stderr_out exit_code
  tmp_home="$(make_test_home)"
  fake_wt="$tmp_home/.claude/skills-worktree"
  fake_root="$tmp_home/root-repo"

  # 'gamma' exists in the root repo but NOT in the worktree — same shape as
  # test 6, except the link is written RELATIVE to ~/.claude/skills/.
  mkdir -p "$fake_root/.claude/skills/gamma" "$tmp_home/.claude/skills"
  ln -s "../../root-repo/.claude/skills/gamma" "$tmp_home/.claude/skills/gamma"

  # Precondition: the link really is relative and really does resolve to the
  # legacy location. Without this the test could pass by not exercising the
  # relative path at all.
  assert "fixture link is stored as a relative target" \
    "[ \"\$(readlink '$tmp_home/.claude/skills/gamma')\" = '../../root-repo/.claude/skills/gamma' ]"
  assert "fixture link resolves into the root repo" \
    "[ -d '$tmp_home/.claude/skills/gamma' ]"

  stderr_out="$(HOME="$tmp_home" bash "$PUBLISH_SCRIPT" "$fake_wt" "$fake_root" 2>&1 >/dev/null)"
  exit_code=$?

  assert "publish exits 0" "[ $exit_code -eq 0 ]"
  assert "relative legacy gamma link preserved (not pruned)" \
    "[ -L '$tmp_home/.claude/skills/gamma' ]"
  assert "gamma still points at the root repo" \
    "[ \"\$(readlink '$tmp_home/.claude/skills/gamma')\" = '../../root-repo/.claude/skills/gamma' ]"
  assert "warning names the not-on-main case" \
    "printf '%s' \"\$stderr_out\" | grep -q 'not in worktree'"
  assert "no stale-prune line was emitted for gamma" \
    "! printf '%s' \"\$stderr_out\" | grep -q 'removing stale symlink'"

  cleanup "$tmp_home"
}

# ── Test 16: regression — an un-removable stale link exits 1 ──────────────────
#
# The EXIT CODES block promises 1 when "a symlink could not be created or
# removed". The prune loop deliberately keeps going after a failed rm so the
# rest of the publish still happens, and that `|| warn` used to swallow the
# status entirely — the script warned on stderr and still exited 0.

test_16_regression_unremovable_stale_link_exits_1() {
  section "Test 16: regression — a stale link that cannot be removed exits 1"

  local tmp_home fake_wt stderr_out exit_code
  tmp_home="$(make_test_home)"
  fake_wt="$tmp_home/.claude/skills-worktree"

  # Empty the worktree's skills directory so Step 1 publishes nothing and needs
  # no write access to ~/.claude/skills — the read-only directory below then
  # blocks ONLY the prune, which is what this test is about.
  rm -rf "${fake_wt:?}/.claude/skills/alpha" "${fake_wt:?}/.claude/skills/beta"

  # A setup-owned link whose skill no longer exists in the worktree: the prune
  # loop's target. Making its PARENT read-only is what makes `rm` fail.
  mkdir -p "$tmp_home/.claude/skills"
  ln -s "$fake_wt/.claude/skills/ghost" "$tmp_home/.claude/skills/ghost"
  chmod 555 "$tmp_home/.claude/skills"

  stderr_out="$(HOME="$tmp_home" bash "$PUBLISH_SCRIPT" "$fake_wt" 2>&1 >/dev/null)"
  exit_code=$?

  chmod 755 "$tmp_home/.claude/skills"

  # Assert the failure path actually RAN. Running as root (or on a filesystem
  # that ignores the mode) would let rm succeed, and then an exit-0 assertion
  # would be vacuous rather than meaningful.
  assert "the removal genuinely failed (warning emitted)" \
    "printf '%s' \"\$stderr_out\" | grep -q 'could not remove'"
  assert "publish exits 1 per the documented exit-code contract" "[ $exit_code -eq 1 ]"
  assert "the un-removable link is still present" \
    "[ -L '$tmp_home/.claude/skills/ghost' ]"
  assert "CLAUDE.md still published despite the prune failure" \
    "[ -L '$tmp_home/.claude/CLAUDE.md' ]"
  assert "rules still published despite the prune failure" \
    "[ -L '$tmp_home/.claude/rules' ]"

  cleanup "$tmp_home"
}

# ── Test 17: regression — repointing never manufactures a dangling link ──────
#
# The repoint branch relinked to new_target WITHOUT the existence test its two
# sibling branches (legacy migration, first creation) both apply. So when the
# worktree did not carry the target — not yet on main, or the definition removed
# upstream — a link that was resolving a moment earlier was replaced with a
# dangling one. Leaving it alone is strictly better: it still points at something
# that exists, and the warning says why it was not moved.

test_17_regression_repoint_never_creates_a_dangling_link() {
  section "Test 17: a repoint with no worktree target leaves the working link alone"

  local tmp_home fake_wt output exit_code
  tmp_home="$(make_test_home)"
  fake_wt="$tmp_home/.claude/skills-worktree"

  # A worktree with no CLAUDE.md — the "not on main yet" shape — while the
  # installed link is setup-owned but points elsewhere inside the worktree, which
  # is exactly the repoint branch.
  rm -f "$fake_wt/CLAUDE.md"
  mkdir -p "$tmp_home/.claude"
  ln -s "$fake_wt/.claude/rules" "$tmp_home/.claude/CLAUDE.md"

  assert "(setup) the link resolves before the run" \
    "[ -e '$tmp_home/.claude/CLAUDE.md' ]"
  assert "(setup) the worktree really has no CLAUDE.md to point at" \
    "[ ! -e '$fake_wt/CLAUDE.md' ]"

  output="$(HOME="$tmp_home" bash "$PUBLISH_SCRIPT" "$fake_wt" 2>&1)"
  exit_code=$?

  assert "publish still exits 0" "[ $exit_code -eq 0 ]"
  # The assertion that fails against the pre-fix script: it relinked to the
  # missing target, leaving a symlink that no longer resolves.
  assert "the link still resolves — it was not repointed at a missing target" \
    "[ -e '$tmp_home/.claude/CLAUDE.md' ]"
  assert "and it was left exactly where it was" \
    "[ \"\$(readlink '$tmp_home/.claude/CLAUDE.md')\" = '$fake_wt/.claude/rules' ]"
  assert "the skip is explained rather than silent" \
    "printf '%s' \"\$output\" | grep -q 'worktree target is missing'"

  cleanup "$tmp_home"
}

# ── Test 18: the directory-copy migration is never destructive ───────────────
#
# The migration used to `rm -rf` the copy and THEN `ln -s`. That destroyed the
# working configuration before its replacement existed: a session reading
# ~/.claude/skills/<name> in the window found nothing, and an `ln` that failed
# left the skill gone with nothing to restore. rename(2) cannot swap a directory
# for a symlink atomically, so the window cannot be closed — but the ORDER can
# stop being destructive, which is the half that loses data.

test_18_directory_copy_migration_is_not_destructive() {
  section "Test 18: replacing a directory copy never destroys it before linking"

  local tmp_home fake_wt output exit_code
  tmp_home="$(make_test_home)"
  fake_wt="$tmp_home/.claude/skills-worktree"

  # A pre-worktree COPY of alpha: a real directory where the symlink belongs.
  mkdir -p "$tmp_home/.claude/skills/alpha"
  printf '# stale copy\n' > "$tmp_home/.claude/skills/alpha/SKILL.md"

  output="$(HOME="$tmp_home" bash "$PUBLISH_SCRIPT" "$fake_wt" 2>&1)"
  exit_code=$?

  assert "publish exits 0" "[ $exit_code -eq 0 ]"
  assert "the copy was replaced by a symlink" \
    "[ -L '$tmp_home/.claude/skills/alpha' ]"
  assert "pointing at the worktree skill" \
    "[ \"\$(readlink '$tmp_home/.claude/skills/alpha')\" = '$fake_wt/.claude/skills/alpha' ]"
  assert "the migration was reported" \
    "printf '%s' \"\$output\" | grep -q 'replacing directory copy'"
  # No move-aside temp may survive a successful run, or the migration trades a
  # data-loss window for a litter of orphaned copies.
  assert "no move-aside temporary was left behind" \
    "[ -z \"\$(find '$tmp_home/.claude/skills' -maxdepth 1 -name 'alpha.pre-symlink.*' 2>/dev/null)\" ]"
  # The ordering itself: the copy must be moved aside, never removed first.
  assert "the source moves the copy aside instead of removing it first" \
    "[ -n \"\$(grep -A2 'replacing directory copy with symlink' '$PUBLISH_SCRIPT' | grep 'mv ')\" ]"
  assert "(control) no rm precedes the link in that branch" \
    "[ -z \"\$(grep -A2 'replacing directory copy with symlink' '$PUBLISH_SCRIPT' | grep 'rm -rf \"\$link\"')\" ]"

  cleanup "$tmp_home"
}

# ── Test 19: setup completes its independent legs before failing ─────────────
#
# setup-skills-worktree.sh runs under `set -e`, so a publisher failure aborted it
# on the spot — leaving no agent links and no registered hooks, which are
# independent of the skills leg. Completing them and THEN exiting non-zero is
# strictly better than abandoning them, provided the run still reports failure.

test_19_setup_continues_past_publisher_failure_then_fails() {
  section "Test 19: a publisher failure does not abandon setup's other legs"

  local setup="$REPO_ROOT/setup-skills-worktree.sh"
  assert "(setup) the script was located" "[ -f '$setup' ]"
  assert "the publisher failure is captured, not left to set -e" \
    "grep -q 'SETUP_EXIT=1' '$setup'"
  assert "and it says the remaining legs still run" \
    "grep -q 'Continuing with the agent publish and hook registration' '$setup'"
  assert "the run still exits non-zero at the end" \
    "grep -q 'exit \"\$SETUP_EXIT\"' '$setup'"
  # Control: a failed run must NOT print the success banner, or a caller keying
  # off output rather than status would read it as a completed setup. Checked by
  # line number, since the two lines are further apart than a grep window.
  local err_line exit_line done_line
  err_line="$(grep -n 'Finished WITH ERRORS' "$setup" | head -1 | cut -d: -f1)"
  exit_line="$(grep -n 'exit "\$SETUP_EXIT"' "$setup" | head -1 | cut -d: -f1)"
  done_line="$(grep -n '^echo "Done. Skills worktree' "$setup" | head -1 | cut -d: -f1)"
  assert "(setup) all three banner lines were located" \
    "[ -n '$err_line' ] && [ -n '$exit_line' ] && [ -n '$done_line' ]"
  assert "the failure banner precedes the non-zero exit" \
    "[ '${err_line:-0}' -lt '${exit_line:-0}' ]"
  assert "(control) the success banner sits after that exit, so it cannot run" \
    "[ '${done_line:-0}' -gt '${exit_line:-0}' ]"
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
test_12_regression_normpath_unavailable
test_13_regression_setup_preflight
test_14_regression_setup_repo_root_is_cwd_independent
test_15_regression_relative_legacy_link_preserved
test_16_regression_unremovable_stale_link_exits_1
test_17_regression_repoint_never_creates_a_dangling_link
test_18_directory_copy_migration_is_not_destructive
test_19_setup_continues_past_publisher_failure_then_fails

echo ""
echo -e "${BOLD}━━━ Summary ━━━${NC}"
if [ $FAIL -eq 0 ]; then
  echo -e "${GREEN}${BOLD}ALL PASSED${NC}: $PASS/$TOTAL tests"
  exit 0
else
  echo -e "${RED}${BOLD}FAILURES${NC}: $FAIL/$TOTAL tests failed ($PASS passed)"
  exit 1
fi
