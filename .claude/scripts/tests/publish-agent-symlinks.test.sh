#!/bin/bash
# publish-agent-symlinks.test.sh — Tests for .claude/scripts/publish-agent-symlinks.sh
# catalog: tests — Tests for `publish-agent-symlinks.sh` against a throwaway `HOME`
# Issue #1197: agents symlink leg publishes on existing installs from session start
#
# Each test creates a temporary HOME with a fake skills-worktree structure,
# calls publish-agent-symlinks.sh, and asserts the expected results.
#
# Does NOT require Docker or ALLOW_LOCAL_DESTRUCTIVE_TESTS — these tests use a
# throwaway HOME= override and never touch the real filesystem. Does NOT require
# a real git repo since publish-agent-symlinks.sh only reads from the filesystem.
#
# Usage: bash .claude/scripts/tests/publish-agent-symlinks.test.sh
# Exit code: 0 = all pass, 1 = any fail

set -uo pipefail

PASS=0; FAIL=0; TOTAL=0
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/../../.." && pwd)"
PUBLISH_SCRIPT="$REPO_ROOT/.claude/scripts/publish-agent-symlinks.sh"
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

# Create a temp HOME with a fake skills-worktree containing agent definitions.
# Writes: phase-a-fixer.md, phase-b-reviewer.md, README.md (non-agent doc).
# Returns the temp HOME path on stdout.
make_test_home() {
  local tmp_home
  tmp_home="$(mktemp -d)"
  local fake_wt="$tmp_home/.claude/skills-worktree"
  mkdir -p "$fake_wt/.claude/agents"
  printf '# phase-a-fixer agent\nname: phase-a-fixer\n' > "$fake_wt/.claude/agents/phase-a-fixer.md"
  printf '# phase-b-reviewer agent\nname: phase-b-reviewer\n' > "$fake_wt/.claude/agents/phase-b-reviewer.md"
  printf '# README — not an agent definition\n' > "$fake_wt/.claude/agents/README.md"
  echo "$tmp_home"
}

cleanup() {
  local tmp_home="$1"
  rm -rf "$tmp_home"
}

# ── Prerequisite ──────────────────────────────────────────────────────────────

section "Prerequisite"
assert "publish-agent-symlinks.sh exists" "[ -f '$PUBLISH_SCRIPT' ]"
assert "publish-agent-symlinks.sh is executable" "[ -x '$PUBLISH_SCRIPT' ]"

# ── Test 1: Existing install + absent ~/.claude/agents/ → symlinks published ─

test_1_creates_agents_dir_and_symlinks() {
  section "Test 1: Existing install + absent ~/.claude/agents/ → symlinks published"

  local tmp_home fake_wt
  tmp_home="$(make_test_home)"
  fake_wt="$tmp_home/.claude/skills-worktree"

  local output exit_code
  output="$(HOME="$tmp_home" bash "$PUBLISH_SCRIPT" "$fake_wt" 2>&1)"
  exit_code=$?

  assert "publish exits 0" "[ $exit_code -eq 0 ]"
  assert "~/.claude/agents/ directory created" "[ -d '$tmp_home/.claude/agents' ]"
  assert "phase-a-fixer.md symlinked" "[ -L '$tmp_home/.claude/agents/phase-a-fixer.md' ]"
  assert "phase-b-reviewer.md symlinked" "[ -L '$tmp_home/.claude/agents/phase-b-reviewer.md' ]"
  assert "README.md NOT symlinked (excluded)" \
    "[ ! -e '$tmp_home/.claude/agents/README.md' ] && [ ! -L '$tmp_home/.claude/agents/README.md' ]"
  assert "phase-a-fixer.md symlink resolves to a real file" \
    "[ -e '$tmp_home/.claude/agents/phase-a-fixer.md' ]"
  assert "phase-a-fixer.md points into the worktree" \
    "[ \"\$(readlink '$tmp_home/.claude/agents/phase-a-fixer.md')\" = '$fake_wt/.claude/agents/phase-a-fixer.md' ]"
  assert "Restart caveat in output (directory was just created)" \
    "grep -q 'Restart your Claude Code session' <<<\"\$output\""

  cleanup "$tmp_home"
}

# ── Test 2: User-owned symlink (target outside worktree) is preserved ─────────

test_2_user_owned_symlink_preserved() {
  section "Test 2: User-owned symlink (target outside worktree) survives"

  local tmp_home fake_wt
  tmp_home="$(make_test_home)"
  fake_wt="$tmp_home/.claude/skills-worktree"

  # Pre-create the agents dir with a user-owned symlink for phase-a-fixer
  mkdir -p "$tmp_home/.claude/agents"
  local user_target="$tmp_home/my-custom-phase-a.md"
  printf '# user-owned agent\n' > "$user_target"
  ln -s "$user_target" "$tmp_home/.claude/agents/phase-a-fixer.md"

  local output exit_code
  output="$(HOME="$tmp_home" bash "$PUBLISH_SCRIPT" "$fake_wt" 2>&1)"
  exit_code=$?

  assert "publish exits 0" "[ $exit_code -eq 0 ]"
  assert "User-owned symlink still points to the user's target" \
    "[ \"\$(readlink '$tmp_home/.claude/agents/phase-a-fixer.md')\" = '$user_target' ]"
  assert "Output reports user-owned symlink left alone" \
    "grep -q 'user-owned symlink' <<<\"\$output\""
  # Non-conflicting agent is still published
  assert "phase-b-reviewer.md (non-conflicting) is symlinked" \
    "[ -L '$tmp_home/.claude/agents/phase-b-reviewer.md' ]"
  # No restart caveat because agents dir already existed
  assert "No restart caveat (agents dir pre-existed)" \
    "! grep -q 'Restart your Claude Code session' <<<\"\$output\""

  cleanup "$tmp_home"
}

# ── Test 3: Re-run is idempotent ──────────────────────────────────────────────

test_3_idempotent() {
  section "Test 3: Re-run is idempotent (second publish produces no changes)"

  local tmp_home fake_wt
  tmp_home="$(make_test_home)"
  fake_wt="$tmp_home/.claude/skills-worktree"

  # First run — establishes symlinks
  HOME="$tmp_home" bash "$PUBLISH_SCRIPT" "$fake_wt" >/dev/null 2>&1
  local target_before
  target_before="$(readlink "$tmp_home/.claude/agents/phase-a-fixer.md")"

  # Second run
  local output exit_code
  output="$(HOME="$tmp_home" bash "$PUBLISH_SCRIPT" "$fake_wt" 2>&1)"
  exit_code=$?

  assert "Second run exits 0" "[ $exit_code -eq 0 ]"
  assert "Symlink target unchanged after second run" \
    "[ \"\$(readlink '$tmp_home/.claude/agents/phase-a-fixer.md')\" = '$target_before' ]"
  assert "No 'creating' or 'updating' in second-run output (true no-op)" \
    "! grep -qiE '(creating|updating|migrating)' <<<\"\$output\""
  assert "No restart caveat on second run (agents dir already existed)" \
    "! grep -q 'Restart your Claude Code session' <<<\"\$output\""

  cleanup "$tmp_home"
}

# ── Test 4: Stale symlink for removed agent is pruned ─────────────────────────

test_4_stale_symlink_pruned() {
  section "Test 4: Stale symlink (agent removed from main) is pruned"

  local tmp_home fake_wt
  tmp_home="$(make_test_home)"
  fake_wt="$tmp_home/.claude/skills-worktree"

  # First run — publishes both agents
  HOME="$tmp_home" bash "$PUBLISH_SCRIPT" "$fake_wt" >/dev/null 2>&1
  assert "(setup) phase-b-reviewer.md symlinked before removal" \
    "[ -L '$tmp_home/.claude/agents/phase-b-reviewer.md' ]"

  # Simulate agent being removed on main
  rm "$fake_wt/.claude/agents/phase-b-reviewer.md"

  # Second run — should prune the stale symlink
  local output exit_code
  output="$(HOME="$tmp_home" bash "$PUBLISH_SCRIPT" "$fake_wt" 2>&1)"
  exit_code=$?

  assert "Publish exits 0 after agent removal from worktree" "[ $exit_code -eq 0 ]"
  assert "Stale symlink removed" \
    "[ ! -e '$tmp_home/.claude/agents/phase-b-reviewer.md' ] && [ ! -L '$tmp_home/.claude/agents/phase-b-reviewer.md' ]"
  assert "Remaining agent symlink still intact" \
    "[ -L '$tmp_home/.claude/agents/phase-a-fixer.md' ]"
  assert "Prune reported in output" \
    "grep -q 'stale symlink' <<<\"\$output\""

  cleanup "$tmp_home"
}

# ── Test 5: Regression guard — session-start-sync.sh calls publish ────────────

test_5_regression_hook_calls_publish() {
  section "Test 5: Regression — session-start-sync.sh invokes publish on steady-state path"

  local hook_file="$REPO_ROOT/.claude/hooks/session-start-sync.sh"
  assert "session-start-sync.sh exists" "[ -f '$hook_file' ]"
  assert "Hook references publish-agent-symlinks.sh" \
    "grep -q 'publish-agent-symlinks' '$hook_file'"

  # The publish call must appear OUTSIDE the bootstrap-only block (the block
  # that runs only when the skills worktree is missing). Bootstrap block pattern:
  #   if [[ ! -d "$skills_wt/.claude/skills" || ! -f "$skills_wt/.git" ]]; then
  # The publish call must appear after the bootstrap fi closes.
  local line_publish line_bootstrap_open line_bootstrap_close
  # Match the INVOCATION specifically, not the variable assignment above it, so a
  # removed call fails the assertion even when the assignment line remains. The
  # hook routes both publishers through the `_publish_one` helper (issue #1524),
  # which captures stdout and stderr separately; a direct `bash "$..."` call is
  # still accepted so this guard survives a refactor back to the simpler shape.
  # `^[^#]*` keeps a comment that merely mentions the call from satisfying this.
  line_publish="$(grep -nE '^[^#]*(bash|_publish_one) .*_agents_publish_script' "$hook_file" | head -1 | cut -d: -f1)"
  # Bootstrap opens at the "if [[ ! -d" block checking for the missing worktree
  line_bootstrap_open="$(grep -n 'Bootstrap missing skills worktree' "$hook_file" | head -1 | cut -d: -f1)"
  # Estimate the bootstrap's fi as the first bare "fi" after the bootstrap open
  line_bootstrap_close="$(awk -v start="${line_bootstrap_open:-0}" 'NR>start && /^fi$/{print NR; exit}' "$hook_file")"

  assert "Publish call line number is non-zero" \
    "[ '${line_publish:-0}' -gt 0 ]"
  assert "Bootstrap close line number is non-zero" \
    "[ '${line_bootstrap_close:-0}' -gt 0 ]"
  assert "Publish call appears after the bootstrap fi (not inside bootstrap block)" \
    "[ '${line_publish:-0}' -gt '${line_bootstrap_close:-0}' ]"
}

# ── Main ──────────────────────────────────────────────────────────────────────

echo ""
echo -e "${BOLD}╔══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}║  publish-agent-symlinks.sh test suite (issue #1197)          ║${NC}"
echo -e "${BOLD}╚══════════════════════════════════════════════════════════════╝${NC}"

test_1_creates_agents_dir_and_symlinks
test_2_user_owned_symlink_preserved
test_3_idempotent
test_4_stale_symlink_pruned
test_5_regression_hook_calls_publish

echo ""
echo -e "${BOLD}━━━ Summary ━━━${NC}"
if [ $FAIL -eq 0 ]; then
  echo -e "${GREEN}${BOLD}ALL PASSED${NC}: $PASS/$TOTAL tests"
  exit 0
else
  echo -e "${RED}${BOLD}FAILURES${NC}: $FAIL/$TOTAL tests failed ($PASS passed)"
  exit 1
fi
