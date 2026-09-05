#!/bin/bash
# claude-config-sync.test.sh — Tests for .claude/scripts/claude-config-sync.sh
# Issue #1524: the per-machine auto-sync entrypoint.
#
# Every test builds a throwaway HOME containing a REAL git clone of a REAL local
# origin repo, so the stale-machine path (fetch, reset, diff) is exercised end to
# end rather than against a stubbed `git`. Nothing outside the temp HOME is read
# or written: the fixture worktree carries its own copies of the publish scripts
# plus tiny stubs for register-hooks.py and repair-trust-all.sh, and
# claude-config-sync.sh resolves helpers from the worktree first — so the run
# never reaches the developer's real settings.json or ~/.claude.json.
#
# Covers:
#   1. Stale-machine simulation — worktree behind origin/main with a skill
#      merged since; entrypoint lands on origin/main and links the new skill.
#   2. Immediate re-run is a no-op.
#   3. Change detection writes the restart-recommended marker.
#   4. Failure counter, threshold marker, and recovery on the next good tick.
#   5. Overlap: a held lock makes the run skip cleanly instead of racing.
#   6. Root-repo scope guard — the job never pulls or resets the root checkout.
#   7. Canonical-path agreement across the three files that name the marker and
#      the lock base.
#
# Usage: bash .claude/scripts/tests/claude-config-sync.test.sh
# Exit code: 0 = all pass, 1 = any fail

set -uo pipefail

PASS=0; FAIL=0; TOTAL=0
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/../../.." && pwd)"
SYNC="$REPO_ROOT/.claude/scripts/claude-config-sync.sh"
HOOK="$REPO_ROOT/.claude/hooks/session-start-sync.sh"
STATUSLINE="$REPO_ROOT/.claude/scripts/statusline.sh"
GREEN='\033[0;32m'; RED='\033[0;31m'; BOLD='\033[1m'; NC='\033[0m'

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

# awk_block <start-regex> <end-regex> <file> — print one awk range.
#
# Callers CAPTURE this and match with `contains`; they must never pipe it into
# `grep -q`. This file runs under `set -o pipefail`, where `grep -q` exits at the
# first match, awk dies of SIGPIPE, and the PIPELINE reports FAILURE on a
# SUCCESSFUL match. Whether it trips depends on how much awk still had left to
# write, so it is size- AND platform-dependent: the record_failure assertions in
# Test 14 passed on macOS and failed on Linux CI for exactly this reason, which
# makes the idiom read as a broken assertion rather than a broken pipeline
# (repo memory: pipefail-sigpipe-false-failure). The deliberate SIGPIPE in
# Test 11's control is the one place the shape is allowed, and its stderr is
# redirected there so the runner does not see a real "Broken pipe" diagnostic.
awk_block() { awk "/$1/,/$2/" "$3"; }

# contains <haystack> <needle> — literal substring test in the shell, with no
# subprocess and therefore no pipeline to break.
contains() { case "$1" in *"$2"*) return 0 ;; *) return 1 ;; esac; }

git_commit() {
  local repo="$1" message="$2"
  git -C "$repo" add -A >/dev/null 2>&1
  git -C "$repo" \
    -c user.email="test@example.invalid" \
    -c user.name="Config Sync Test" \
    -c commit.gpgsign=false \
    commit -q -m "$message" >/dev/null 2>&1
}

# File mode in octal, portable across BSD and GNU stat. Prints nothing when it
# cannot be determined — never a fabricated value.
file_mode() {
  local m
  m="$(stat -c '%a' "$1" 2>/dev/null)"
  [[ "$m" =~ ^[0-7]+$ ]] && { printf '%s' "$m"; return 0; }
  m="$(stat -f '%Lp' "$1" 2>/dev/null)"
  [[ "$m" =~ ^[0-7]+$ ]] && { printf '%s' "$m"; return 0; }
  return 1
}

# ---------------------------------------------------------------------------
# make_fixture — build a temp HOME with:
#   $TMP/origin                       a real git repo, TWO commits
#   $TMP_HOME/.claude/skills-worktree a clone pinned at the FIRST commit
#
# Commit 1: CLAUDE.md, skills/alpha, agents/phase-a-fixer.md, rules/safety.md,
#           the two real publish scripts, and stubs for register-hooks.py and
#           repair-trust-all.sh that record having run.
# Commit 2: adds skills/beta and edits rules/safety.md — the "merged since"
#           content a stale machine has not seen.
#
# Prints "<tmp_root>" on stdout; TMP_HOME is "<tmp_root>/home".
# ---------------------------------------------------------------------------
make_fixture() {
  local tmp origin home wt
  tmp="$(mktemp -d)"
  origin="$tmp/origin"
  home="$tmp/home"
  wt="$home/.claude/skills-worktree"

  mkdir -p "$home/.claude"
  mkdir -p "$origin/.claude/skills/alpha" "$origin/.claude/agents" \
           "$origin/.claude/rules" "$origin/.claude/scripts" "$origin/.claude/hooks"

  printf '# CLAUDE.md v1\n'            > "$origin/CLAUDE.md"
  printf '# alpha skill\n'             > "$origin/.claude/skills/alpha/SKILL.md"
  printf 'name: phase-a-fixer\n'       > "$origin/.claude/agents/phase-a-fixer.md"
  printf '# safety rules v1\n'         > "$origin/.claude/rules/safety.md"

  cp "$REPO_ROOT/.claude/scripts/publish-skill-symlinks.sh" "$origin/.claude/scripts/"
  cp "$REPO_ROOT/.claude/scripts/publish-agent-symlinks.sh" "$origin/.claude/scripts/"

  # Stubs: prove the entrypoint invokes the idempotent setup steps without
  # letting them touch the developer's real ~/.claude.json or settings.json.
  cat > "$origin/.claude/scripts/repair-trust-all.sh" <<'STUB'
#!/bin/bash
printf 'stub\n' >> "$HOME/.claude/repair-trust-ran"
echo "trust flags repaired (stub)"
STUB
  cat > "$origin/.claude/hooks/register-hooks.py" <<'STUB'
#!/usr/bin/env python3
import os, sys
with open(os.path.join(os.environ["HOME"], ".claude", "register-hooks-ran"), "a") as fh:
    fh.write((sys.argv[1] if len(sys.argv) > 1 else "") + "\n")
print("hooks registered (stub)")
STUB
  chmod +x "$origin/.claude/scripts/repair-trust-all.sh" "$origin/.claude/hooks/register-hooks.py"

  git init -q "$origin" >/dev/null 2>&1
  git -C "$origin" symbolic-ref HEAD refs/heads/main >/dev/null 2>&1
  git_commit "$origin" "commit 1"

  git clone -q "$origin" "$wt" >/dev/null 2>&1

  # Commit 2 lands in origin AFTER the clone — the machine is now stale.
  mkdir -p "$origin/.claude/skills/beta"
  printf '# beta skill (merged since)\n' > "$origin/.claude/skills/beta/SKILL.md"
  printf '# safety rules v2\n'           > "$origin/.claude/rules/safety.md"
  git_commit "$origin" "commit 2"

  printf '%s' "$tmp"
}

run_sync() { # run_sync <tmp_home> → the run's JSON summary on stdout
  local home="$1"
  HOME="$home" bash "$SYNC" --json 2>/dev/null
}

# ── Prerequisites ─────────────────────────────────────────────────────────────

section "Prerequisites"
HELP_ERR="$(mktemp -t ccs-help-err.XXXXXX)"
trap 'rm -f "$HELP_ERR"' EXIT
assert "claude-config-sync.sh exists" "[ -f '$SYNC' ]"
assert "claude-config-sync.sh is executable" "[ -x '$SYNC' ]"
assert "--help exits 0 with no stderr and real content" \
  "out=\$(bash '$SYNC' --help 2>'$HELP_ERR'); [ \$? -eq 0 ] && [ ! -s '$HELP_ERR' ] && [ \${#out} -gt 200 ]"
assert "--help documents the flags and the exit-code contract" \
  "out=\$(bash '$SYNC' --help 2>/dev/null); case \"\$out\" in *--json*--quiet*) : ;; *) false ;; esac && printf '%s' \"\$out\" | grep -q 'EXIT CODES'"
assert "unknown argument is a usage error (exit 2)" \
  "bash '$SYNC' --nope >/dev/null 2>&1; [ \$? -eq 2 ]"

# ── Test 1 + 2 + 3: stale machine, marker, and the no-op re-run ───────────────

test_1_stale_machine() {
  section "Test 1: stale-machine simulation — lands on origin/main and links the new skill"

  local tmp home wt origin_sha out
  tmp="$(make_fixture)"
  home="$tmp/home"
  wt="$home/.claude/skills-worktree"
  origin_sha="$(git -C "$tmp/origin" rev-parse HEAD)"

  assert "(setup) worktree starts BEHIND origin/main" \
    "[ \"\$(git -C '$wt' rev-parse HEAD)\" != '$origin_sha' ]"
  assert "(setup) the merged-since skill is absent from the worktree" \
    "[ ! -d '$wt/.claude/skills/beta' ]"

  out="$(run_sync "$home")"

  assert "run exits with outcome ok" \
    "[ \"\$(printf '%s' \"\$out\" | jq -r .outcome)\" = 'ok' ]"
  assert "worktree now at origin/main" \
    "[ \"\$(git -C '$wt' rev-parse HEAD)\" = '$origin_sha' ]"
  assert "summary reports the head change" \
    "[ \"\$(printf '%s' \"\$out\" | jq -r .head_changed)\" = 'true' ]"
  assert "summary new_sha matches origin/main" \
    "[ \"\$(printf '%s' \"\$out\" | jq -r .new_sha)\" = '$origin_sha' ]"

  # The whole point: a skill merged on another machine gets LINKED here.
  assert "new skill beta is symlinked into ~/.claude/skills/" \
    "[ -L '$home/.claude/skills/beta' ]"
  assert "beta symlink resolves" "[ -d '$home/.claude/skills/beta' ]"
  assert "pre-existing skill alpha still linked" "[ -L '$home/.claude/skills/alpha' ]"
  assert "agent definition linked into ~/.claude/agents/" \
    "[ -L '$home/.claude/agents/phase-a-fixer.md' ]"
  assert "CLAUDE.md linked" "[ -L '$home/.claude/CLAUDE.md' ]"
  assert "rules linked" "[ -L '$home/.claude/rules' ]"

  # The other idempotent setup steps really ran.
  assert "register-hooks.py was invoked" "[ -f '$home/.claude/register-hooks-ran' ]"
  assert "repair-trust-all.sh was invoked" "[ -f '$home/.claude/repair-trust-ran' ]"

  # Logs and state.
  assert "run log written" "[ -s '$home/.claude/logs/claude-config-sync.log' ]"
  assert "state file written with a success timestamp" \
    "jq -e '.last_success_at != null and .consecutive_failures == 0' '$home/.claude/logs/claude-config-sync-state.json'"
  assert "state file is owner-only (600)" \
    "[ \"\$(file_mode '$home/.claude/logs/claude-config-sync-state.json')\" = '600' ]"

  section "Test 2: change detection writes the restart-recommended marker"

  assert "marker file exists" "[ -f '$home/.claude/sync-restart-recommended.json' ]"
  assert "marker carries a restart_recommended portion" \
    "jq -e '.restart_recommended != null' '$home/.claude/sync-restart-recommended.json'"
  assert "marker names the skills category" \
    "jq -e '.restart_recommended.categories | index(\"skills\")' '$home/.claude/sync-restart-recommended.json'"
  assert "marker names the rules category" \
    "jq -e '.restart_recommended.categories | index(\"rules\")' '$home/.claude/sync-restart-recommended.json'"
  assert "marker records the new HEAD sha" \
    "[ \"\$(jq -r .restart_recommended.head_sha '$home/.claude/sync-restart-recommended.json')\" = '$origin_sha' ]"
  assert "marker has no failure portion on a healthy run" \
    "jq -e '(.sync_failure // null) == null' '$home/.claude/sync-restart-recommended.json'"
  assert "marker is owner-only (600)" \
    "[ \"\$(file_mode '$home/.claude/sync-restart-recommended.json')\" = '600' ]"
  assert "statusline renders the restart badge" \
    "printf '{}' | HOME='$home' bash '$STATUSLINE' | grep -q 'restart'"

  section "Test 3: an immediate re-run is a no-op"

  local out2
  out2="$(run_sync "$home")"

  assert "second run exits with outcome ok" \
    "[ \"\$(printf '%s' \"\$out2\" | jq -r .outcome)\" = 'ok' ]"
  assert "second run reports no head change" \
    "[ \"\$(printf '%s' \"\$out2\" | jq -r .head_changed)\" = 'false' ]"
  assert "second run recommends no new restart" \
    "[ \"\$(printf '%s' \"\$out2\" | jq -r .restart_recommended)\" = 'false' ]"
  # The agents-directory leg must require the directory to EXIST after the
  # publish before treating its prior absence as a change. Keying on the prior
  # absence alone would nag forever on a machine where the publisher is missing
  # and the directory is therefore never created — a state this fixture cannot
  # reach, since resolve_helper always finds the repo's own copy, so the guard's
  # shape is asserted directly.
  assert "the agents existence check requires post-run existence, not just prior absence" \
    "grep -q 'agents_dir_exists\" == true && \"\$agents_dir_existed\" != true' '$SYNC'"
  assert "second run reports no warnings" \
    "[ \"\$(printf '%s' \"\$out2\" | jq -r '.warnings | length')\" = '0' ]"
  assert "worktree HEAD unchanged by the second run" \
    "[ \"\$(git -C '$wt' rev-parse HEAD)\" = '$origin_sha' ]"
  assert "links still intact after the second run" \
    "[ -L '$home/.claude/skills/beta' ] && [ -L '$home/.claude/agents/phase-a-fixer.md' ]"
  # Success alone must NOT clear the restart signal: a live session still has to
  # restart. Only a real session startup clears it.
  assert "restart marker survives a later successful tick" \
    "jq -e '.restart_recommended != null' '$home/.claude/sync-restart-recommended.json'"

  section "Test 3a: a publisher advisory is a warning, never a phantom change"

  # A user-owned symlink shadowing a worktree skill makes the publisher write to
  # stderr on EVERY run. Merging the streams would turn that standing condition
  # into a change on every hourly tick, and — for the agents publisher — into a
  # false restart recommendation. The run must classify it as a warning instead.
  local out3a user_target
  user_target="$home/my-personal-alpha"
  mkdir -p "$user_target"
  rm -f "$home/.claude/skills/alpha"
  ln -s "$user_target" "$home/.claude/skills/alpha"

  out3a="$(run_sync "$home")"

  assert "run with a shadowing user-owned link still exits ok" \
    "[ \"\$(printf '%s' \"\$out3a\" | jq -r .outcome)\" = 'ok' ]"
  assert "the advisory is reported as a warning" \
    "printf '%s' \"\$out3a\" | jq -r '.warnings[]?' | grep -q 'user-owned symlink'"
  assert "the advisory did NOT become a restart recommendation" \
    "[ \"\$(printf '%s' \"\$out3a\" | jq -r .restart_recommended)\" = 'false' ]"
  assert "the user-owned link was left exactly as it was" \
    "[ \"\$(readlink '$home/.claude/skills/alpha')\" = '$user_target' ]"

  # Restore the managed link so the later assertions see a normal machine.
  rm -f "$home/.claude/skills/alpha"
  run_sync "$home" >/dev/null

  section "Test 3b: a startup whose own sync failed surfaces the marker but keeps it"

  # This fixture's worktree is a plain CLONE, not a git worktree of this repo,
  # so the hook's sync region reports a setup error — which makes it exactly the
  # case that matters here. Clearing requires four things (see the hook's clear
  # guard): source == startup, the region ran, the region SUCCEEDED, and the
  # marker still holds what this session surfaced. A startup that ran and failed
  # has not demonstrably loaded the current definitions, so the reminder has to
  # survive: a duplicate next startup, never a lost one.
  local hook_out
  hook_out="$(printf '{"source":"startup"}' | HOME="$home" bash "$HOOK" 2>/dev/null)"

  assert "hook surfaced the restart notice" \
    "printf '%s' \"\$hook_out\" | jq -r '.hookSpecificOutput.additionalContext // \"\"' | grep -q 'RESTART RECOMMENDED'"
  # (setup) the premise — without a reported error the assertions below would be
  # testing the success path by accident.
  assert "(setup) this startup's sync region did report an error" \
    "printf '%s' \"\$hook_out\" | jq -r '.hookSpecificOutput.additionalContext // \"\"' | grep -q 'Config sync encountered errors'"
  assert "restart portion survives a startup whose sync failed" \
    "jq -e '(.restart_recommended // null) != null' '$home/.claude/sync-restart-recommended.json'"
  assert "statusline still shows the restart badge" \
    "printf '{}' | HOME='$home' bash '$STATUSLINE' | grep -q 'restart'"
  # Surfacing and clearing are independent: the notice was delivered above even
  # though the marker stays, so nothing is suppressed by declining to clear.
  assert "the failure portion was not invented by the clear path" \
    "jq -e '(.sync_failure // null) == null' '$home/.claude/sync-restart-recommended.json'"

  rm -rf "$tmp"
}

# ── Test 4: failure counter, threshold marker, recovery ──────────────────────

test_4_failure_and_recovery() {
  section "Test 4: failures are counted and surfaced, then cleared by recovery"

  local tmp home wt out1 out2 out3 out4 origin_url
  tmp="$(make_fixture)"
  home="$tmp/home"
  wt="$home/.claude/skills-worktree"
  origin_url="$(git -C "$wt" remote get-url origin)"

  # Break the remote so `git fetch` fails for real — no stubbing.
  git -C "$wt" remote set-url origin "$tmp/does-not-exist" >/dev/null 2>&1

  out1="$(run_sync "$home")"
  out2="$(run_sync "$home")"
  out3="$(run_sync "$home")"

  assert "a failing fetch reports outcome failed" \
    "[ \"\$(printf '%s' \"\$out1\" | jq -r .outcome)\" = 'failed' ]"
  assert "a failing run exits non-zero" \
    "HOME='$home' bash '$SYNC' --json >/dev/null 2>&1; [ \$? -eq 1 ]"
  assert "the error text names the fetch failure" \
    "printf '%s' \"\$out1\" | jq -r .error | grep -q 'fetch failed'"
  assert "first failure counts 1" \
    "[ \"\$(printf '%s' \"\$out1\" | jq -r .consecutive_failures)\" = '1' ]"
  assert "second failure counts 2" \
    "[ \"\$(printf '%s' \"\$out2\" | jq -r .consecutive_failures)\" = '2' ]"
  assert "third failure counts 3" \
    "[ \"\$(printf '%s' \"\$out3\" | jq -r .consecutive_failures)\" = '3' ]"
  assert "state records the first-failure timestamp" \
    "jq -e '.first_failure_at != null' '$home/.claude/logs/claude-config-sync-state.json'"
  assert "failures are appended to the events log" \
    "[ \"\$(grep -c '\"event\":\"failure\"' '$home/.claude/logs/claude-config-sync-events.jsonl')\" -ge 3 ]"
  assert "events log is owner-only (600)" \
    "[ \"\$(file_mode '$home/.claude/logs/claude-config-sync-events.jsonl')\" = '600' ]"
  assert "marker carries the failure notice once the threshold is crossed" \
    "jq -e '.sync_failure != null' '$home/.claude/sync-restart-recommended.json'"
  assert "failure notice names the streak" \
    "jq -e '.sync_failure.consecutive_failures >= 3' '$home/.claude/sync-restart-recommended.json'"
  assert "failure message reads as 'failing for N day(s)'" \
    "jq -r .sync_failure.message '$home/.claude/sync-restart-recommended.json' | grep -q 'failing for'"
  assert "statusline shows the sync-failing badge" \
    "printf '{}' | HOME='$home' bash '$STATUSLINE' | grep -q 'sync failing'"
  assert "a session start surfaces the failure notice" \
    "printf '{\"source\":\"startup\"}' | HOME='$home' bash '$HOOK' 2>/dev/null | jq -r '.hookSpecificOutput.additionalContext // \"\"' | grep -q 'CONFIG SYNC FAILING'"

  # Recover.
  git -C "$wt" remote set-url origin "$origin_url" >/dev/null 2>&1
  out4="$(run_sync "$home")"

  assert "the next good tick reports outcome ok" \
    "[ \"\$(printf '%s' \"\$out4\" | jq -r .outcome)\" = 'ok' ]"
  assert "the failure streak is reset in state" \
    "jq -e '.consecutive_failures == 0 and (.first_failure_at == null)' '$home/.claude/logs/claude-config-sync-state.json'"
  assert "recovery is recorded in the events log" \
    "grep -q '\"event\":\"recovered\"' '$home/.claude/logs/claude-config-sync-events.jsonl'"
  assert "the failure portion of the marker is gone" \
    "[ ! -f '$home/.claude/sync-restart-recommended.json' ] || jq -e '(.sync_failure // null) == null' '$home/.claude/sync-restart-recommended.json'"
  assert "statusline no longer shows the sync-failing badge" \
    "! printf '{}' | HOME='$home' bash '$STATUSLINE' | grep -q 'sync failing'"

  rm -rf "$tmp"
}

# ── Test 5: overlap — a held lock makes the run skip, not race ───────────────

test_5_lock_overlap() {
  section "Test 5: overlap — a held config-sync lock makes the tick skip cleanly"

  local tmp home wt lock_dir before out rc
  tmp="$(make_fixture)"
  home="$tmp/home"
  wt="$home/.claude/skills-worktree"
  before="$(git -C "$wt" rev-parse HEAD)"

  # A LIVE holder on this host: state-lock only breaks a lock whose owner pid is
  # dead or whose age is past the stale ceiling, so this one must be waited on.
  lock_dir="$home/.claude/logs/claude-config-sync-state.json.lock"
  mkdir -p "$lock_dir"
  {
    printf 'pid=%s\n' "$$"
    printf 'host=%s\n' "${HOSTNAME:-$(hostname)}"
    printf 'epoch=%s\n' "$(date +%s)"
    printf 'started=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf 'cmd=%s\n' "claude-config-sync.test.sh"
    printf 'token=%s\n' "test-token-$$"
  } > "$lock_dir/owner"

  out="$(HOME="$home" CLAUDE_CONFIG_SYNC_LOCK_TIMEOUT=1 bash "$SYNC" --json 2>/dev/null)"
  rc=$?

  assert "a contended run exits 0 (a skip is not a failure)" "[ $rc -eq 0 ]"
  assert "outcome is reported as skipped, never silently ok" \
    "[ \"\$(printf '%s' \"\$out\" | jq -r .outcome)\" = 'skipped' ]"
  assert "the skip reason is stated" \
    "printf '%s' \"\$out\" | jq -r .error | grep -q 'holds the lock'"
  assert "the worktree was NOT touched while the lock was held" \
    "[ \"\$(git -C '$wt' rev-parse HEAD)\" = '$before' ]"
  assert "no symlinks were published during the skip" \
    "[ ! -e '$home/.claude/skills/beta' ]"
  assert "the failure counter was NOT incremented by a skip" \
    "[ ! -f '$home/.claude/logs/claude-config-sync-state.json' ] || jq -e '(.consecutive_failures // 0) == 0' '$home/.claude/logs/claude-config-sync-state.json'"
  assert "the skip is written to the run log" \
    "grep -q 'skipping this tick' '$home/.claude/logs/claude-config-sync.log'"

  # The session-start hook takes the SAME lock and must skip its own region too.
  local hook_out
  hook_out="$(printf '{"source":"startup"}' | HOME="$home" CLAUDE_CONFIG_SYNC_HOOK_LOCK_TIMEOUT=1 bash "$HOOK" 2>/dev/null)"
  assert "the session-start hook reports its own clean skip" \
    "printf '%s' \"\$hook_out\" | jq -r '.hookSpecificOutput.additionalContext // \"\"' | grep -q 'holds the lock'"
  assert "the hook left the worktree untouched while the lock was held" \
    "[ \"\$(git -C '$wt' rev-parse HEAD)\" = '$before' ]"

  # Release and confirm the very next run does the work.
  rm -rf "$lock_dir"
  out="$(run_sync "$home")"
  assert "the next uncontended run completes normally" \
    "[ \"\$(printf '%s' \"\$out\" | jq -r .outcome)\" = 'ok' ]"
  assert "and links the skill the skipped tick did not" \
    "[ -L '$home/.claude/skills/beta' ]"

  rm -rf "$tmp"
}

# ── Test 6: the job never mutates the root repo checkout ─────────────────────

test_6_root_repo_untouched() {
  section "Test 6: scope guard — the sync never mutates the root repo checkout"

  # `^[^#]*` keeps these off comment lines — the header names both scripts
  # precisely to say it does NOT call them, and that prose must not read as a
  # violation.
  assert "no main-sync.sh invocation" "! grep -qE '^[^#]*main-sync\.sh' '$SYNC'"
  assert "no dirty-main-guard.sh invocation" \
    "! grep -qE '^[^#]*dirty-main-guard\.sh' '$SYNC'"
  assert "no git pull anywhere" "! grep -qE '^[^#]*git .*(pull)' '$SYNC'"
  assert "no git checkout / stash / clean anywhere" \
    "! grep -qE '^[^#]*git .*(checkout|stash|clean)' '$SYNC'"

  # Every git call is scoped to the skills worktree with -C. Counted into a
  # variable rather than chained into `grep -q`: a short-circuiting `-q` at the
  # end of a pipeline SIGPIPEs its producer, and under pipefail that failure
  # would make a negated assertion pass vacuously (repo memory:
  # pipefail-sigpipe-false-failure).
  local git_lines stray_git
  git_lines="$(grep -E '^[^#]*[[:space:]]*git ' "$SYNC")"
  stray_git="$(printf '%s\n' "$git_lines" | grep -Fvc 'git -C "$SKILLS_WT"')"
  assert "(control) the scan found real git invocations to check" \
    "[ -n \"\$(printf '%s' \"\$git_lines\")\" ]"
  assert "every git invocation targets the skills worktree" "[ '$stray_git' -eq 0 ]"
  assert "the scope boundary is documented in the header" \
    "grep -q 'SCOPE BOUNDARY' '$SYNC'"
}

# ── Test 7: canonical-path agreement across the three consumers ──────────────

test_7_path_agreement() {
  section "Test 7: the marker and lock-base paths agree across every consumer"

  local marker='.claude/sync-restart-recommended.json'
  local lock_base='.claude/logs/claude-config-sync-state.json'

  assert "claude-config-sync.sh names the marker path" "grep -qF '$marker' '$SYNC'"
  assert "session-start-sync.sh names the same marker path" "grep -qF '$marker' '$HOOK'"
  assert "statusline.sh names the same marker path" "grep -qF '$marker' '$STATUSLINE'"

  assert "claude-config-sync.sh names the lock base" "grep -qF '$lock_base' '$SYNC'"
  assert "session-start-sync.sh names the same lock base" "grep -qF '$lock_base' '$HOOK'"

  # Negative control: a path this suite does NOT expect must not match, so a
  # grep that accidentally matched everything would fail here.
  assert "(control) an invented path matches nothing" \
    "! grep -qF '.claude/sync-restart-NOT-A-REAL-PATH.json' '$SYNC'"

  # The hook must take the lock, not merely mention it.
  assert "session-start-sync.sh actually acquires the lock" \
    "grep -q 'state_lock_acquire' '$HOOK'"
  assert "session-start-sync.sh releases the lock" \
    "grep -q 'state_lock_release' '$HOOK'"
}

# ── Test 14: a failed tick still reports the restart that landed ─────────────
#
# record_failure exits the run. The fast-forward has already been written to the
# worktree by then, so the NEXT tick sees an unchanged HEAD and an empty diff —
# meaning a restart signal dropped here can never be recovered. The categories
# are therefore collected at the fast-forward and re-emitted by record_failure.

test_14_restart_signal_survives_a_failed_tick() {
  section "Test 14: a failed tick preserves the restart signal for landed content"

  # The collection must happen at the fast-forward, NOT in Step 5 — Step 5 sits
  # after the publishers, which are exactly what record_failure aborts on.
  # Captured, then matched in the shell — see awk_block's note on why piping a
  # range into `grep -q` under pipefail fails on a SUCCESSFUL match.
  local rf_body ff_body step5_body
  rf_body="$(awk_block '^record_failure\(\)' '^}' "$SYNC")"
  ff_body="$(awk_block 'HEAD_CHANGED="true"' '^  else$' "$SYNC")"
  step5_body="$(awk_block 'Step 5 — change detection' 'De-duplicate while preserving order' "$SYNC")"

  assert "the categories are collected in a named helper" \
    "grep -q 'collect_head_change_categories()' '$SYNC'"
  assert "(setup) record_failure's body was located" "[ -n \"\$rf_body\" ]"
  assert "the helper is invoked at the fast-forward" \
    "contains \"\$ff_body\" 'collect_head_change_categories'"
  assert "record_failure re-emits restart_recommended" \
    "contains \"\$rf_body\" 'restart_recommended'"
  assert "record_failure only does so when categories exist" \
    "contains \"\$rf_body\" 'if (( \${#RESTART_CATEGORIES[@]} > 0 )); then'"

  # Negative control: Step 5 must no longer carry the diff itself, or the fix
  # would be a duplicate rather than a move.
  assert "(setup) Step 5's block was located" "[ -n \"\$step5_body\" ]"
  assert "(control) Step 5 no longer runs the diff" \
    "! contains \"\$step5_body\" 'diff --name-only'"
}

# ── Test 15: the marker clear re-checks under the lock ───────────────────────
#
# The hook releases the sync lock, then re-acquires it to clear the marker. A
# scheduled tick can complete entirely inside that gap, so both acquires look
# uncontended while the marker now describes changes this session never loaded.

test_15_marker_clear_rechecks_under_the_lock() {
  section "Test 15: the hook clears only the restart_recommended it surfaced"

  assert "the hook records what it surfaced" \
    "grep -q '_surfaced_restart' '$HOOK'"
  assert "the hook re-reads the marker under the clear lock" \
    "grep -q '_current_restart' '$HOOK'"
  assert "a mismatch skips the clear" \
    "grep -q '_current_restart\" != \"\$_surfaced_restart' '$HOOK'"

  # Negative control: the pre-existing contention guard must still be there —
  # the re-check supplements it, it does not replace it.
  assert "(control) the uncontended-acquire guard survives" \
    "grep -q '_lock_contended\" == 0' '$HOOK'"
}

# ── Test 16: the hook's git region is bounded by a deadline ─────────────────
#
# The number of bounded calls varies by path — steady state runs fetch then
# reset, a first-time bootstrap runs setup AND THEN both — so no fixed sum of
# per-call bounds can honour the registered timeout for every path. The region
# is scheduled against one deadline instead, and a call with too little budget
# left is declined rather than started and killed. Being killed is the outcome
# that matters: it leaves a half-updated worktree and records nothing, which is
# exactly what the publish guard cannot defend against.

test_16_hook_git_bounds_fit_the_hook_timeout() {
  section "Test 16: the hook's git region is scheduled against one deadline"

  local manifest registered budgeted reserve setup_cap sync_cap
  manifest="$REPO_ROOT/global-settings.json"

  registered="$(jq -r '
    [ .hooks.SessionStart[]?.hooks[]?
      | select(.command | test("session-start-sync\\.sh"))
      | .timeout ] | first // empty
  ' "$manifest" 2>/dev/null)" || registered=""
  budgeted="$(sed -n 's/^_HOOK_TIMEOUT_SECS=\([0-9][0-9]*\)$/\1/p' "$HOOK" | head -1)"
  reserve="$(sed -n 's/^_HOOK_GIT_RESERVE_SECS=\([0-9][0-9]*\)$/\1/p' "$HOOK" | head -1)"
  setup_cap="$(sed -n 's/^_setup_bound_secs=\([0-9][0-9]*\)$/\1/p' "$HOOK" | head -1)"
  sync_cap="$(sed -n 's/^_sync_bound_secs=\([0-9][0-9]*\)$/\1/p' "$HOOK" | head -1)"

  # Read every term before comparing: a missing value must fail loudly here
  # rather than making the comparisons below vacuously true.
  assert "the manifest registers a timeout for this hook" "[ -n '$registered' ]"
  assert "the hook records the timeout it budgets against" "[ -n '$budgeted' ]"
  assert "the hook reserves time for the work after the git region" "[ -n '$reserve' ]"
  assert "setup carries its own, larger ceiling" "[ -n '$setup_cap' ]"
  assert "fetch and reset carry the smaller ceiling" "[ -n '$sync_cap' ]"

  assert "(control) the budgeted timeout matches the manifest" \
    "[ '$budgeted' = '$registered' ]"
  assert "the git region ends with the reserve still unspent" \
    "[ $(( budgeted - reserve )) -lt $registered ]"
  assert "the reserve leaves real room for the rest of the hook" \
    "[ '$reserve' -ge 5 ]"
  assert "setup is allowed more than a single fetch — it does strictly more" \
    "[ '$setup_cap' -gt '$sync_cap' ]"

  # The deadline, not the per-call ceilings, is what bounds the region. Setup
  # alone exceeds the reserve-adjusted window, which is safe ONLY because
  # _bound_for clamps it — so assert the clamp exists rather than the sum.
  assert "each call is clamped to what is left of the budget" \
    "grep -q '_budget_remaining()' '$HOOK'"
  # The floor must be applied to the REMAINING BUDGET and the ceiling to the
  # bound, separately. Clamping first and then testing the floor made any
  # configured ceiling below the floor decline every call instead of honouring
  # it — which is how a 2s test bound turned into "declined" rather than a real
  # 2s run. Both files carry the same shape, so pin both.
  local hook_budget_body sync_budget_body run_bounded_body
  hook_budget_body="$(awk_block '^_budget_remaining\(\)' '^}' "$HOOK")"
  sync_budget_body="$(awk_block '^_git_region_remaining\(\)' '^}' "$SYNC")"
  run_bounded_body="$(awk_block '^_run_hook_bounded\(\)' '^}' "$HOOK")"
  assert "(setup) both budget helpers were located" \
    "[ -n \"\$hook_budget_body\" ] && [ -n \"\$sync_budget_body\" ]"
  assert "the hook's budget helper returns the budget, not a clamped bound" \
    "! contains \"\$hook_budget_body\" 'remaining > cap'"
  assert "the sync's budget helper returns the budget, not a clamped bound" \
    "! contains \"\$sync_budget_body\" 'remaining > GIT_BOUND_SECS'"
  assert "the hook tests the floor against the budget, not the clamped bound" \
    "grep -q 'budget_left < _HOOK_MIN_BOUND_SECS' '$HOOK'"
  assert "the sync tests the floor against the budget, not the clamped bound" \
    "grep -q 'region_left < _GIT_MIN_BOUND_SECS' '$SYNC'"
  assert "the lock wait counts against the same budget" \
    "grep -q '_hook_t0=' '$HOOK'"
  assert "a call with too little budget left is declined, not started" \
    "grep -q '_HOOK_MIN_BOUND_SECS' '$HOOK'"
  assert "the decline is recorded as a bound trip so the publish guard holds" \
    "contains \"\$run_bounded_body\" 'BOUNDED_TIMED_OUT=1'"
  # (control) no call site may still pass the old single-bound signature.
  assert "(control) every bounded call passes an explicit ceiling" \
    "! grep -qE '_run_hook_bounded (bash|git) ' '$HOOK'"
}

# ── Test 8: a REPOINTED agent symlink is restart-worthy ──────────────────────
#
# The restart signal used to snapshot ~/.claude/agents/ with `ls -1`, i.e. names
# only. Repointing an existing link at a different source file leaves the name
# set byte-identical while changing which definition a session would load, so
# the one case the worktree indirection exists for produced no signal at all.
# The snapshot now records "name -> target".

test_8_agent_repoint_recommends_restart() {
  section "Test 8: repointing an agent symlink recommends a restart"

  local tmp home wt marker names_before names_after
  tmp="$(make_fixture)"
  home="$tmp/home"
  wt="$home/.claude/skills-worktree"
  marker="$home/.claude/sync-restart-recommended.json"

  # A managed link (inside the worktree agents dir, so the publisher owns it)
  # aimed at a stale filename. The publisher will repoint it to the canonical
  # target; the NAME stays phase-a-fixer.md throughout.
  mkdir -p "$home/.claude/agents"
  ln -s "$wt/.claude/agents/phase-a-fixer.md.old" \
        "$home/.claude/agents/phase-a-fixer.md"
  names_before="$(ls -1 "$home/.claude/agents" | sort)"

  run_sync "$home" >/dev/null

  names_after="$(ls -1 "$home/.claude/agents" | sort)"

  assert "(setup) the agent NAME set is unchanged across the run" \
    "[ \"$names_before\" = \"$names_after\" ]"
  assert "(setup) but the link was actually repointed" \
    "[ \"\$(readlink '$home/.claude/agents/phase-a-fixer.md')\" = '$wt/.claude/agents/phase-a-fixer.md' ]"
  assert "a marker was written" "[ -f '$marker' ]"
  assert "and it names the agents category despite the identical name set" \
    "jq -e '.restart_recommended.categories | index(\"agents\")' '$marker'"

  rm -rf "$tmp"
}

# ── Test 9: a failed durable-state commit is reported, never swallowed ───────
#
# Both commit sites used `|| true`. On the failure path that silently discarded
# the bumped streak, so a machine whose state file is unwritable could fail
# forever without consecutive_failures ever reaching FAILURE_THRESHOLD — the
# repeated-failure badge, the only in-session symptom, would never appear.

test_9_state_commit_failure_is_reported() {
  section "Test 9: an uncommittable state file is reported, not swallowed"

  local tmp home logs state out
  tmp="$(make_fixture)"
  home="$tmp/home"
  logs="$home/.claude/logs"
  state="$logs/claude-config-sync-state.json"

  # First run creates the log/state files normally.
  run_sync "$home" >/dev/null
  assert "(setup) the state file exists after a healthy run" \
    "[ -f '$state' ]"

  # Fault injection has to break the COMMIT and nothing else. Making the
  # directory read-only is not usable: state-lock.sh puts its lockdir at
  # "${STATE_FILE}.lock" in that same directory, so the run would abort at lock
  # acquisition and never reach the code under test. Marking just the state file
  # immutable leaves the lock, the temp file and the log untouched while making
  # commit_json's rename fail with EPERM — precisely one broken step.
  if [[ "$(uname -s)" == "Darwin" ]] && chflags uchg "$state" 2>/dev/null; then
    out="$(HOME="$home" bash "$SYNC" 2>&1)"
    chflags nouchg "$state" 2>/dev/null

    assert "the run names the CONSEQUENCE, not just the failed write" \
      "printf '%s' \"\$out\" | grep -q 'state not persisted'"
    assert "the degradation is also recorded as a durable event" \
      "grep -q 'state_commit_failed' '$logs/claude-config-sync-events.jsonl'"
    assert "(control) the next healthy run says no such thing" \
      "out2=\$(HOME='$home' bash '$SYNC' 2>&1); ! printf '%s' \"\$out2\" | grep -q 'state not persisted'"
  else
    # Non-Darwin (or a filesystem without user flags): the runtime injection is
    # unavailable, so assert the wiring instead of silently claiming a pass.
    assert "(source) the success path reports an uncommitted state" \
      "grep -q 'success state not persisted' '$SYNC'"
    assert "(source) the failure path reports an uncommitted streak" \
      "grep -q 'failure streak not persisted' '$SYNC'"
    assert "(source) both paths record a state_commit_failed event" \
      "[ \"\$(grep -c 'state_commit_failed' '$SYNC')\" -eq 2 ]"
  fi

  assert "neither commit site still swallows the result with || true" \
    "! grep -q 'commit_json \"\$new_state\" \"\$STATE_FILE\" || true' '$SYNC'"

  rm -rf "$tmp"
}

# ── Test 10: the legacy hooks root reaches BOTH automated registrars ─────────
#
# register-hooks.py only migrates or prunes a settings.json hook entry whose
# current path sits inside a managed root. MANAGED_LEGACY_HOOKS_DIR is what adds
# the pre-worktree root-repo hooks directory to that set. install-time set it;
# the two automated paths did not, so neither could ever finish the migration
# they exist to perform.

test_10_legacy_hooks_dir_reaches_both_automated_paths() {
  section "Test 10: MANAGED_LEGACY_HOOKS_DIR is passed by every registrar"

  local hook="$REPO_ROOT/.claude/hooks/session-start-sync.sh"
  local setup="$REPO_ROOT/setup-skills-worktree.sh"

  assert "(control) install-time still sets it" \
    "grep -q 'MANAGED_LEGACY_HOOKS_DIR=' '$setup'"
  assert "the scheduled sync sets it too" \
    "grep -q 'MANAGED_LEGACY_HOOKS_DIR=' '$SYNC'"
  assert "the session-start hook sets it too" \
    "grep -q 'MANAGED_LEGACY_HOOKS_DIR=' '$hook'"
  assert "the scheduled sync derives it from the resolved root repo" \
    "grep -q 'MANAGED_LEGACY_HOOKS_DIR=\"\$ROOT_REPO_HINT/.claude/hooks\"' '$SYNC'"
  assert "the hook derives it from the resolved root repo" \
    "grep -q 'MANAGED_LEGACY_HOOKS_DIR=\"\$_root_repo/.claude/hooks\"' '$hook'"
}

# ── Test 11: the root-repo lookup survives pipefail + SIGPIPE ────────────────
#
# This file runs under `set -o pipefail`. An awk that `exit`s on the first match
# closes the pipe while `git worktree list` is still writing; git dies of
# SIGPIPE and the PIPELINE reports failure even though the correct path already
# reached stdout. Paired with `|| ROOT_REPO_HINT=""` that erased a good answer —
# and an empty hint silently drops MANAGED_LEGACY_HOOKS_DIR and the publishers'
# legacy-migration argument. It only bites once the repo has enough worktrees
# for git to still be writing, which is why a single-worktree test fixture never
# reproduced it.

test_11_root_repo_lookup_survives_sigpipe() {
  section "Test 11: the root-repo lookup is not wiped by pipefail + SIGPIPE"

  # A producer shaped like `git worktree list --porcelain` on a long-lived
  # machine: the main worktree first, then thousands of registered worktrees.
  # Used only by the negative control below, which keeps the hazard executable.
  local producer
  producer='printf "worktree /Users/me/repo\nHEAD abc\n\n"; for i in $(seq 1 20000); do printf "worktree /Users/me/repo/.claude/worktrees/wt-%s\nHEAD def\n\n" "$i"; done'

  # The lookup no longer parses that stream inline: it delegates to repo-root.sh,
  # which owns this pattern AND bounds its git calls via lib/bounded-run.sh —
  # required here because the lookup runs while the config-sync lock is held, so
  # an unbounded call could carry the locked region past STALE_AGE.
  assert "the root-repo lookup goes through repo-root.sh" \
    "grep -q 'resolve_helper repo-root.sh' '$SYNC'"
  assert "the hook resolves it through the same helper" \
    "grep -q 'repo-root.sh' '$HOOK'"

  # The structural reason SIGPIPE can no longer bite: there is no pipeline left
  # on either assignment. This is the assertion that must fail if someone
  # reintroduces an inline `git worktree list | …` here.
  assert "the sync's hint is not built from a pipeline" \
    "! grep -qE '^[^#]*ROOT_REPO_HINT=.*\\|' '$SYNC'"
  assert "the hook's root-repo is not built from a pipeline" \
    "! grep -qE '^[^#]*_root_repo=.*\\|' '$HOOK'"
  assert "no inline worktree listing remains in either writer" \
    "! grep -qE '^[^#]*worktree list --porcelain' '$SYNC' '$HOOK'"

  # The hazard itself, kept as executable documentation: this is what an inline
  # early-exiting consumer does under pipefail, and why the shape is banned.
  # stderr is redirected because the SIGPIPE here is DELIBERATE: bash's printf
  # writes "printf: write error: Broken pipe" when the pipe closes under it, and
  # the CI runner treats any suite stderr as a failed suite — so this control
  # failed the whole `hook-tests` job while every assertion in it passed.
  local old_rc=0
  bash -c "set -o pipefail; { $producer; } | awk '/^worktree /{sub(/^worktree /, \"\"); print; exit}' >/dev/null" 2>/dev/null || old_rc=$?
  assert "(control) the pre-fix early-exit expression DOES report failure" \
    "[ $old_rc -ne 0 ]"

  # Code only — `^[^#]*` cannot cross the leading `#` of the comment that
  # explains why the fallback was removed.
  assert "no wiping fallback remains on the ROOT_REPO_HINT assignment" \
    "! grep -qE '^[^#]*\\|\\| ROOT_REPO_HINT=' '$SYNC'"
  assert "(control) the guard would still see such a fallback if one existed" \
    "printf 'X=\"\$(cmd)\" || ROOT_REPO_HINT=\"\"\n' | grep -qE '^[^#]*\\|\\| ROOT_REPO_HINT='"
}

# ── Test 12: newly created skill links recommend a restart with no SHA move ──
#
# The skills / CLAUDE.md / rules categories used to come only from the Step 5
# `git diff`, which requires HEAD to have moved. That misses the migration this
# feature exists to perform: on a machine where the old session-start hook kept
# the worktree at origin/main but published only AGENT symlinks, the first run
# of this sync creates the missing links with no SHA change at all — definitions
# a live session cannot pick up, and no restart was ever recommended for them.

test_12_new_skill_links_recommend_restart_without_sha_move() {
  section "Test 12: links created without a SHA move still recommend a restart"

  local tmp home wt marker before_sha after_sha
  tmp="$(make_fixture)"
  home="$tmp/home"
  wt="$home/.claude/skills-worktree"
  marker="$home/.claude/sync-restart-recommended.json"

  # Bring the worktree to origin/main WITHOUT publishing anything, standing in
  # for the old hook: it fast-forwarded the tree but never linked skills.
  git -C "$wt" fetch origin main --quiet 2>/dev/null
  git -C "$wt" reset --hard origin/main --quiet 2>/dev/null
  before_sha="$(git -C "$wt" rev-parse HEAD)"

  assert "(setup) the worktree is already current — no SHA move to detect" \
    "[ \"\$(git -C '$tmp/origin' rev-parse HEAD)\" = '$before_sha' ]"
  assert "(setup) no skill links exist yet" \
    "[ ! -e '$home/.claude/skills/alpha' ]"

  run_sync "$home" >/dev/null
  after_sha="$(git -C "$wt" rev-parse HEAD)"

  assert "the run really did NOT move HEAD" "[ '$before_sha' = '$after_sha' ]"
  assert "(control) the publish nevertheless created the skill links" \
    "[ -L '$home/.claude/skills/alpha' ]"
  assert "a marker was written despite the unchanged SHA" "[ -f '$marker' ]"
  assert "and it names the skills category" \
    "jq -e '.restart_recommended.categories | index(\"skills\")' '$marker'"
  assert "and the CLAUDE.md category" \
    "jq -e '.restart_recommended.categories | index(\"claude-md\")' '$marker'"
  assert "and the rules category" \
    "jq -e '.restart_recommended.categories | index(\"rules\")' '$marker'"

  # A second, genuinely idempotent run must NOT re-recommend: the links are now
  # identical, so the snapshots compare equal. Without this the new comparison
  # would be a permanent nag rather than a change signal.
  rm -f "$marker"
  run_sync "$home" >/dev/null
  assert "an unchanged re-run raises no new restart recommendation" \
    "[ ! -f '$marker' ] || jq -e '(.restart_recommended // null) == null' '$marker'"

  rm -rf "$tmp"
}

# ── Test 13: the fetch inside the lock is bounded ───────────────────────────
#
# state-lock.sh breaks a lock on AGE ALONE — its own header says "Holder alive
# but wedged >STALE_AGE: the lock IS broken" — so an unbounded `git fetch` over
# a hanging network lets a healthy holder be dispossessed mid-run: another
# process resets and publishes against the same worktree, and this run's later
# commit_json is refused by state_lock_assert_held, so the restart marker it
# owed never lands. The git calls are therefore bounded to well under the
# staleness window, and a tripped bound is a RECORDED failure.

test_13_fetch_is_bounded_inside_the_lock() {
  section "Test 13: a hanging fetch trips its bound instead of losing the lock"

  local tmp home stub real_git out started elapsed
  tmp="$(make_fixture)"
  home="$tmp/home"

  real_git="$(command -v git)"
  assert "(setup) a real git was found to forward to" "[ -n '$real_git' ]"

  # A git that hangs ONLY on `fetch` and forwards every other subcommand to the
  # real binary by ABSOLUTE path. Resolving the real git inside the stub (via
  # command -v / PATH) would find the stub itself and recurse.
  stub="$tmp/stub"
  mkdir -p "$stub"
  {
    printf '#!/bin/sh\n'
    printf 'for a in "$@"; do\n'
    printf '  if [ "$a" = "fetch" ]; then sleep 120; exit 0; fi\n'
    printf 'done\n'
    printf 'exec %s "$@"\n' "$real_git"
  } > "$stub/git"
  chmod +x "$stub/git"

  started="$(date +%s)"
  out="$(HOME="$home" PATH="$stub:$PATH" CLAUDE_CONFIG_SYNC_GIT_BOUND=2 \
         bash "$SYNC" --json 2>/dev/null)" || true
  elapsed=$(( $(date +%s) - started ))

  assert "the run returned instead of hanging on the fetch" "[ $elapsed -lt 60 ]"
  assert "it reports a failed outcome" \
    "[ \"\$(printf '%s' \"\$out\" | jq -r .outcome)\" = 'failed' ]"
  assert "and names the bound it exceeded, not a generic git error" \
    "printf '%s' \"\$out\" | grep -q 'exceeded its 2s bound'"
  assert "the failure is durable in the log" \
    "grep -q 'exceeded its 2s bound' '$home/.claude/logs/claude-config-sync.log'"

  # Control: the same fixture with the real git succeeds, so the assertions
  # above are keyed to the hanging stub and not to a broken fixture.
  local ok_out
  ok_out="$(HOME="$home" bash "$SYNC" --json 2>/dev/null)" || true
  assert "(control) the same fixture succeeds with a working git" \
    "[ \"\$(printf '%s' \"\$ok_out\" | jq -r .outcome)\" = 'ok' ]"

  rm -rf "$tmp"
}

# ── Test 17: a missing bound declines the call, never runs it unbounded ─────
#
# The two callers of this lock disagreed: the hook REFUSED to run without a
# bound, the scheduled sync WARNED and proceeded. Same lock, same 120s staleness
# window, opposite answers — and the permissive one is the path least able to
# diagnose what follows, since state-lock.sh breaks a lock on AGE ALONE under a
# live holder: another sync then mutates the same worktree while this run's
# commit_json is refused by state_lock_assert_held, so the marker never lands.
#
# Source-level, like Test 16: the library sits next to the script it serves, so
# "bounded-run.sh is missing" cannot be staged without relocating the script away
# from the helpers it resolves relatively.
#
# Every downstream grep in a pipe here is deliberately WITHOUT -q and captured
# into a string tested with -n. `producer | grep -q` returns non-zero on a
# SUCCESSFUL match under pipefail — the producer takes SIGPIPE — which would
# invert these assertions (repo memory: pipefail-sigpipe-false-failure).

test_17_missing_bound_declines_instead_of_running_unbounded() {
  section "Test 17: a missing bound declines the call instead of running it unbounded"

  assert "the sync declines its lock-held calls when the bound is unavailable" \
    "grep -q 'declined: bounded-run.sh unavailable' '$SYNC'"
  # Two greps rather than one literal: the hook now carries a SECOND decline
  # reason (a failed capture handover, CodeAnt PR #1640), so the reason is a
  # variable with the missing-library text as its default. Asserting the two
  # halves keeps this pinned to the behaviour — it declines, and the default
  # reason still names the missing library — without re-pinning one string that
  # any added reason would split again.
  assert "the hook declines its lock-held calls for the same reason" \
    "grep -q 'refusing to run unbounded' '$HOOK' && grep -q 'bounded-run.sh unavailable' '$HOOK'"
  assert "the sync refuses to bootstrap unbounded as well" \
    "grep -q 'refusing to run setup-skills-worktree.sh unbounded' '$SYNC'"

  # The regression itself: the old code ANNOUNCED that it was proceeding without
  # a bound. No caller may say that again, because no caller may do it.
  assert "neither caller warns that it is proceeding unbounded" \
    "! grep -qE 'runs unbounded' '$SYNC' '$HOOK'"

  # A decline has to be a RECORDED failure, not a quiet skip: it returns the
  # same 124 every other bound trip returns, which is what the call sites key
  # their '…failed' message off.
  assert "the sync's decline returns the bound-trip status" \
    "[ -n \"\$(grep -A2 'declined: bounded-run.sh unavailable' '$SYNC' | grep 'return 124')\" ]"
  assert "the hook's decline returns the bound-trip status" \
    "[ -n \"\$(grep -A2 'refusing to run unbounded' '$HOOK' | grep 'return 124')\" ]"
}

# ── Test 18: the hook's bootstrap and steady-state paths are exclusive ──────
#
# A successful setup-skills-worktree.sh already leaves the worktree AT
# origin/main, but the hook then ran fetch and reset anyway — against the same
# budget the setup had just spent most of. The reset was declined for lack of
# time, recorded as "reset failed", and the publish guard read that as a
# partial-tree hazard: a stale-config warning for a tree that had just been
# built correctly. The two paths must be mutually exclusive, as they already are
# in claude-config-sync.sh.

test_18_hook_bootstrap_and_steady_state_are_exclusive() {
  section "Test 18: a successful bootstrap does not then re-fetch on the same budget"

  assert "the hook records that it bootstrapped" \
    "grep -q '_bootstrapped=1' '$HOOK'"
  # Anchored on the FULL unique gate line (fixed-string), not the bare
  # '_bootstrapped == 0' token: that token now appears at several sites, and a
  # pooled -A window could supply the fetch from the wrong match. -A3 spans the
  # _old_head capture that sits between the gate and the fetch.
  assert "the steady-state fetch/reset is gated on NOT having bootstrapped" \
    "[ -n \"\$(grep -A3 -F 'if (( _bootstrapped == 0 )) && [[ -z' '$HOOK' | grep 'fetch origin main')\" ]"
  # The trap this fix could have set: skipping the branch above without also
  # guarding the else would make a fresh bootstrap report its own new worktree
  # as missing.
  assert "the 'not found' fallback is guarded too, so a bootstrap is not reported missing" \
    "grep -q 'elif (( _bootstrapped == 0 ))' '$HOOK'"
}

# ── Test 19: the marker clear is anchored to the locked region's exit ───────
#
# The clear compared the marker surfaced against the marker present at clear
# time, which catches a sync landing between the READ and the clear — but not
# one landing between the lock RELEASE and that read. In that window the NEW
# marker is what gets surfaced, so surfaced and current agree and the clear
# deletes a restart signal for definitions this session never loaded. The
# snapshot has to be taken while the lock is still held.

test_19_marker_clear_is_anchored_at_region_exit() {
  section "Test 19: the clear compares against the marker held at region exit"

  local snap_line release_line clear_line
  # Line numbers, not text proximity: the ordering is the whole property, and
  # `head -1` keeps a single match even if the token recurs.
  snap_line="$(grep -n '_region_exit_restart=\$(jq' "$HOOK" | head -1 | cut -d: -f1)"
  release_line="$(grep -n '^  state_lock_release' "$HOOK" | head -1 | cut -d: -f1)"
  clear_line="$(grep -n '_region_exit_restart" == "\$_surfaced_restart' "$HOOK" | head -1 | cut -d: -f1)"

  assert "a region-exit snapshot of the marker is taken" "[ -n '$snap_line' ]"
  assert "(setup) the lock release was located" "[ -n '$release_line' ]"
  # Load-bearing ordering: taken BEFORE the release, or it is merely a second
  # post-release read and closes nothing.
  assert "the snapshot is taken while the lock is still held" \
    "[ '${snap_line:-0}' -lt '${release_line:-0}' ]"
  assert "the clear requires the marker to still match that snapshot" \
    "[ -n '$clear_line' ]"
}

# ── Test 20: a missing skills publisher is an error in BOTH writers ─────────
#
# The sync already treats a missing publish-skill-symlinks.sh as a hard failure
# — it refreshes exactly as few links as a failing one. The hook skipped it
# silently, which was worse there than it would have been in the sync: `errors`
# stayed empty, so the marker clear read the run as clean and deleted the
# restart signal while every skill, CLAUDE.md and rules link was still stale.
#
# The agent publisher is deliberately NOT symmetrical — a notice in both — so
# this test pins the asymmetry too. Symmetry here would be the easy wrong fix.

test_20_missing_skills_publisher_is_an_error_in_both_writers() {
  section "Test 20: a missing skills publisher is recorded, not skipped"

  assert "the sync records a missing skills publisher as a failure" \
    "grep -q 'publish-skill-symlinks.sh not found' '$SYNC'"
  assert "the hook records one too, instead of skipping silently" \
    "grep -q 'skill symlink publish failed: .* not found' '$HOOK'"
  # The consequence that made the hook's silence worse than the sync's would
  # have been: an empty `errors` lets the clear delete the marker.
  assert "the hook's message uses the publish-failure shape the clear keys off" \
    "[ -n \"\$(grep 'not found — skill/CLAUDE.md/rules links not refreshed' '$HOOK' | grep 'errors=')\" ]"

  # Category union (BugBot 8eacd570, PR #1553): both restart_recommended write
  # sites must UNION into existing categories, never replace them — a later
  # skills-only tick must not drop an earlier agents/rules signal the user has
  # not restarted for. The union shape is the behavior; assert both sites carry it.
  assert "both marker write sites union restart categories instead of replacing" \
    "[ \"\$(grep -c 'restart_recommended.categories // \\[\\]' '$SYNC')\" -eq 2 ]"

  # Readability guard on helper resolution (CodeAnt 3920027124, PR #1553): an
  # unreadable stale worktree copy must not be selected over a readable later
  # candidate — every caller runs `bash "$candidate"`.
  assert "resolve_helper requires candidates to be readable, not just present" \
    "grep -q -- '-f \"\$candidate\" && -r \"\$candidate\"' '$SYNC'"

  # Two asserts, not one: the old single grep was vacuous — `grep -A1` emits
  # the matched warn line itself, which never contains record_failure, so the
  # `grep -v` pipeline was always non-empty. Assert presence first, then that
  # the LINE AFTER the warn is not a record_failure call.
  assert "the sync has the agent-publisher warning at all" \
    "grep -q 'publish-agent-symlinks.sh not found' '$SYNC'"
  assert "the agent publisher stays a warning in the sync" \
    "[ -z \"\$(grep -A1 'publish-agent-symlinks.sh not found' '$SYNC' | sed -n '2p' | grep 'record_failure')\" ]"
  assert "and a notice, not an error, in the hook" \
    "[ -z \"\$(grep 'publish-agent-symlinks.sh not found' '$HOOK' | grep 'errors=')\" ]"
}

# ── Test 21: removing the marker is lock-checked, like writing it ───────────
#
# write_marker's commit path inherits state_lock_assert_held from
# state_lock_commit; its REMOVAL path used a bare `rm` and returned 0. That made
# the delete the only mutation in the file a dispossessed holder could still
# land — a run whose lock had already been broken on age wiping a restart or
# failure marker the new owner had just written. The delete is the worst shape
# for that loss, because nothing is left to show a signal was dropped.

test_21_marker_removal_is_lock_checked() {
  section "Test 21: a dispossessed holder cannot delete the marker"

  # The assert must appear INSIDE write_marker, before the rm — not merely
  # somewhere in the file, which the commit path already guarantees.
  local body
  body="$(awk '/^write_marker\(\) \{/,/^\}/' "$SYNC")"
  assert "(setup) write_marker's body was located" "[ -n \"\$body\" ]"
  assert "the removal path asserts the lock is still held" \
    "[ -n \"\$(printf '%s' \"\$body\" | grep 'state_lock_assert_held')\" ]"
  assert "the assert precedes the rm" \
    "[ \"\$(printf '%s' \"\$body\" | grep -n 'state_lock_assert_held' | head -1 | cut -d: -f1)\" -lt \"\$(printf '%s' \"\$body\" | grep -n 'rm -f' | head -1 | cut -d: -f1)\" ]"
  assert "a refused removal is reported to the caller, not swallowed as success" \
    "[ -n \"\$(printf '%s' \"\$body\" | grep 'return 1')\" ]"

  # Control: the commit path's own check still comes from state_lock_commit, so
  # this test is pinning the removal path specifically.
  assert "(control) the commit path still goes through commit_json" \
    "[ -n \"\$(printf '%s' \"\$body\" | grep 'commit_json')\" ]"
}

# ── Test 22: clear-safety is tracked apart from error severity ──────────────
#
# The agent publisher's absence is reported as a NOTICE, matching the sync. But
# the marker's restart_recommended covers the AGENTS category, so a startup that
# never refreshed those links must not delete a signal describing them — and the
# clear keys off `errors`, which a notice deliberately does not set. Severity and
# clear-safety are different questions; `_publish_incomplete` answers the second
# one so the answer to the first stays free to be quiet.

test_22_publisher_miss_blocks_the_clear_regardless_of_severity() {
  section "Test 22: a publisher that never ran blocks the clear, loudly or not"

  assert "the hook tracks publisher completeness separately from errors" \
    "grep -q '_publish_incomplete=0' '$HOOK'"
  assert "a missing agent publisher sets it, even though it is only a notice" \
    "[ -n \"\$(grep -A3 'publish-agent-symlinks.sh not found' '$HOOK' | grep '_publish_incomplete=1')\" ]"
  assert "a missing skills publisher sets it too" \
    "[ -n \"\$(grep -A2 'skill symlink publish failed: .* not found' '$HOOK' | grep '_publish_incomplete=1')\" ]"
  assert "the clear requires it to be clear" \
    "grep -q '_publish_incomplete\" == 0' '$HOOK'"
  # Control: the agent miss must still NOT be an error, or this fix has silently
  # changed what the session is told rather than what it is allowed to clear.
  assert "(control) the agent miss is still not an error" \
    "[ -z \"\$(grep -A3 'publish-agent-symlinks.sh not found' '$HOOK' | grep 'errors=')\" ]"
}

# ── Test 23: the bootstrap bound is clamped to the region, not the ceiling ───
#
# GIT_BOUND_SECS is a per-call CEILING; the region budget is what defends the
# lock. Passing the ceiling raw let an operator override — normalize_bound
# accepts any size — schedule one lock-held call for longer than the staleness
# window, so the bound meant to prevent dispossession could licence it instead.
# git_sync already clamped; the bootstrap did not.

test_23_bootstrap_bound_is_clamped_to_the_region() {
  section "Test 23: the bootstrap bound cannot exceed the lock-held region budget"

  assert "the bootstrap consults the remaining region budget" \
    "grep -q '_bootstrap_region_left=' '$SYNC'"
  assert "and clamps the per-call ceiling against it" \
    "[ -n \"\$(grep -A2 '_bootstrap_region_left=' '$SYNC' | grep 'GIT_LAST_BOUND > GIT_BOUND_SECS')\" ]"
  assert "the bounded call uses the clamped value, not the raw ceiling" \
    "grep -q 'run_bounded \"\$GIT_LAST_BOUND\" bash' '$SYNC'"
  assert "too little region left declines rather than starting the call" \
    "[ -n \"\$(grep -A2 '_bootstrap_region_left < _GIT_MIN_BOUND_SECS' '$SYNC' | grep 'GIT_TIMED_OUT=1')\" ]"
  # Control: the raw ceiling must no longer be handed to run_bounded anywhere.
  assert "(control) no call passes the unclamped ceiling" \
    "! grep -q 'run_bounded \"\$GIT_BOUND_SECS\"' '$SYNC'"
}

# ── Test 24: the hook's clear re-asserts the lock before mutating ───────────
#
# Test 21 closed this in the sync's write_marker. The hook's clear had the same
# shape: acquire, then a raw `rm`/`mv` with no re-assert. state-lock.sh breaks a
# lock on AGE ALONE, so acquiring it is not proof of still holding it a few lines
# later — and a dispossessed hook could delete or overwrite a marker the new
# owner had just written, which is the exact loss this clear path is guarded
# against everywhere else.

test_24_hook_clear_reasserts_the_lock() {
  section "Test 24: the hook re-asserts ownership before touching the marker"

  assert "the clear re-asserts the lock" \
    "grep -q 'state_lock_assert_held' '$HOOK'"
  # Ordering is the property: the assert must sit between the clear-lock acquire
  # and the mutation, or it proves nothing.
  local acquire_line assert_line rm_line
  acquire_line="$(grep -n 'state_lock_acquire \"\$_sync_lock_base\" 5' "$HOOK" | head -1 | cut -d: -f1)"
  # The first assert_held AFTER the clear-lock acquire — the file now carries an
  # earlier one (the resume-path restart write guards its own mutation the same
  # way), so a file-global first match would name the wrong site.
  assert_line="$(awk -v a="${acquire_line:-0}" 'NR > (a+0) && /! state_lock_assert_held/ { print NR; exit }' "$HOOK")"
  rm_line="$(grep -n 'rm -f \"\$_marker_file\"' "$HOOK" | head -1 | cut -d: -f1)"
  assert "(setup) acquire, assert and removal were all located" \
    "[ -n '$acquire_line' ] && [ -n '$assert_line' ] && [ -n '$rm_line' ]"
  assert "the assert comes after the clear-lock acquire" \
    "[ '${assert_line:-0}' -gt '${acquire_line:-0}' ]"
  assert "and before the marker is removed" \
    "[ '${assert_line:-0}' -lt '${rm_line:-0}' ]"
  assert "a lost lock leaves the marker alone rather than mutating it" \
    "grep -q 'Lock lost mid-clear' '$HOOK'"
}

# ── Test 25: a stalled symlink publisher trips its bound (issue #1593) ───────
#
# PR #1553 bounded the git region but deliberately left the publishers outside
# it: a few dozen readlink/ln/mv calls finish in well under a second. On a
# stalled network home they do not, and an unbounded publisher then holds this
# lock past STALE_AGE — at which point a second sync treats this LIVE holder's
# lock as stale, breaks it, and rewrites the same ~/.claude links concurrently,
# while this run's own commit_json is refused by state_lock_assert_held so the
# restart marker it owed never lands. Both halves of the race the lock exists to
# prevent, reached by the one call that was never bounded.

test_25_publisher_is_bounded_inside_the_lock() {
  section "Test 25: a hanging publisher trips its bound instead of losing the lock"

  # Structural first, so a refactor that drops the bound fails loudly even where
  # the functional fixture below cannot run.
  local publisher_body
  publisher_body="$(awk_block '^run_publisher\(\)' '^}' "$SYNC")"
  assert "(setup) run_publisher was located" "[ -n \"\$publisher_body\" ]"
  assert "the publisher runs under the bound, not a bare bash call" \
    "contains \"\$publisher_body\" 'run_bounded \"\$PUBLISH_LAST_BOUND\" bash'"
  assert "its ceiling is clamped to what is left of the publish region" \
    "contains \"\$publisher_body\" 'PUBLISH_LAST_BOUND > PUBLISH_BOUND_SECS'"
  assert "the floor is tested against the region, not the clamped bound" \
    "contains \"\$publisher_body\" 'region_left < _PUBLISH_MIN_BOUND_SECS'"
  assert "a missing bound declines rather than running unbounded under the lock" \
    "contains \"\$publisher_body\" 'refusing to run unbounded'"
  # A decline must be recognised by an explicit flag, never by matching the
  # child's own stderr: run_publisher overwrites PUBLISH_STDERR with captured
  # child stderr, so a publisher whose stderr began with "declined:" would have
  # a real timeout reported as a decline (CodeRabbit, PR #1640).
  assert "a decline is tracked by a flag, not inferred from child stderr" \
    "[ -n \"\$(grep 'PUBLISH_DECLINED=1' '$SYNC')\" ]"
  assert "and the trip reason tests that flag rather than the stderr text" \
    "[ -z \"\$(grep -A2 '^_publish_trip_reason()' '$SYNC' | grep 'PUBLISH_STDERR.*==.*declined')\" ]"
  assert "the publish region reserves room for the rest of the locked pass" \
    "[ -n \"\$(grep '_publish_region_budget=' '$SYNC')\" ]"
  # The functional leg below stalls the SKILL publisher only, so on its own it
  # would not notice an agents publisher that regressed to a bare `bash` call
  # (CodeAnt, PR #1640). Both call sites are pinned structurally instead —
  # cheaper and less flaky than a second sleeping-stub fixture, and it fails on
  # exactly the regression the functional leg would miss.
  assert "BOTH publishers go through run_publisher, not just the stalled one" \
    "[ \"\$(grep -c '^  if ! run_publisher \"\$publish_' '$SYNC')\" -eq 2 ]"
  assert "and neither publisher is invoked with a bare bash call" \
    "[ -z \"\$(grep -E '^[^#]*bash \"\$publish_(skills|agents)\"' '$SYNC')\" ]"
  # (control) the region budget must stay INSIDE the staleness window it defends.
  assert "(control) the publish budget is smaller than the staleness window" \
    "grep -q '_publish_region_budget=\$(( _stale_age - _PUBLISH_TAIL_RESERVE_SECS ))' '$SYNC'"

  local tmp home origin out started elapsed
  tmp="$(make_fixture)"
  home="$tmp/home"
  origin="$tmp/origin"

  # The sleeping publisher has to be COMMITTED: the run resets the worktree to
  # origin/main before resolve_helper picks a publisher, so a stub written
  # straight into the worktree would be overwritten by the run under test.
  printf '#!/bin/sh\nsleep 120\n' > "$origin/.claude/scripts/publish-skill-symlinks.sh"
  chmod +x "$origin/.claude/scripts/publish-skill-symlinks.sh"
  git_commit "$origin" "stalling publisher"

  started="$(date +%s)"
  out="$(HOME="$home" CLAUDE_CONFIG_SYNC_PUBLISH_BOUND=2 bash "$SYNC" --json 2>/dev/null)" || true
  elapsed=$(( $(date +%s) - started ))

  assert "the run returned instead of hanging on the publisher" "[ $elapsed -lt 60 ]"
  assert "and well inside the 120s lock staleness window it defends" "[ $elapsed -lt 100 ]"
  assert "it reports a failed outcome" \
    "[ \"\$(printf '%s' \"\$out\" | jq -r .outcome)\" = 'failed' ]"
  assert "and names the bound it exceeded, not a generic publisher error" \
    "printf '%s' \"\$out\" | grep -q 'exceeded its 2s bound'"
  assert "the failure names the publisher that stalled" \
    "printf '%s' \"\$out\" | grep -q 'publish-skill-symlinks.sh'"
  assert "the failure is durable in the log" \
    "grep -q 'exceeded its 2s bound' '$home/.claude/logs/claude-config-sync.log'"

  # Control: restore the REAL publisher in origin and re-run the SAME home. The
  # assertions above are keyed to the sleeping stub, not to a broken fixture —
  # and a bound that tripped on a healthy publisher would show up right here.
  cp "$REPO_ROOT/.claude/scripts/publish-skill-symlinks.sh" "$origin/.claude/scripts/"
  git_commit "$origin" "working publisher"
  local ok_out
  # A generous bound here on purpose: 2s is the value the STALL leg needs, and
  # reusing it would make this control flake on a slow CI filesystem — reporting
  # the fix as broken when only the fixture was slow. The control's job is to
  # prove the failure above is keyed to the sleeping stub, which it still does.
  ok_out="$(HOME="$home" CLAUDE_CONFIG_SYNC_PUBLISH_BOUND=20 bash "$SYNC" --json 2>/dev/null)" || true
  assert "(control) the same fixture succeeds with a working publisher" \
    "[ \"\$(printf '%s' \"\$ok_out\" | jq -r .outcome)\" = 'ok' ]"
  # -L alone only proves SOMETHING was created at that path; a publisher that
  # linked the wrong target, or left a stale link from an earlier fixture, would
  # still pass (CodeAnt, PR #1640). Assert the link resolves AND that it points
  # into the managed skills worktree, which is the property the publish is for.
  assert "(control) and the links the stalled tick never made are now published" \
    "[ -L '$home/.claude/skills/beta' ]"
  assert "(control) that link resolves rather than dangling" \
    "[ -e '$home/.claude/skills/beta' ]"
  assert "(control) and it points into the managed skills worktree" \
    "case \"\$(readlink '$home/.claude/skills/beta')\" in \
       '$home/.claude/skills-worktree/.claude/skills/beta') true ;; \
       *) false ;; esac"

  rm -rf "$tmp"
}

# ── Main ──────────────────────────────────────────────────────────────────────

echo ""
echo -e "${BOLD}╔══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}║  claude-config-sync.sh test suite (issue #1524)              ║${NC}"
echo -e "${BOLD}╚══════════════════════════════════════════════════════════════╝${NC}"

if ! command -v git >/dev/null 2>&1; then
  echo "SKIP-FAIL: git is required for this suite" >&2
  exit 1
fi

# jq is as load-bearing as git here: most assertions parse the JSON summary or
# the marker with it, and `assert` routes all output to /dev/null. Without this
# gate a machine missing jq reports dozens of unrelated ✗ lines instead of the
# one fact that explains them.
if ! command -v jq >/dev/null 2>&1; then
  echo "SKIP-FAIL: jq is required for this suite" >&2
  exit 1
fi

test_1_stale_machine
test_8_agent_repoint_recommends_restart
test_9_state_commit_failure_is_reported
test_10_legacy_hooks_dir_reaches_both_automated_paths
test_11_root_repo_lookup_survives_sigpipe
test_12_new_skill_links_recommend_restart_without_sha_move
test_13_fetch_is_bounded_inside_the_lock
test_4_failure_and_recovery
test_5_lock_overlap
test_6_root_repo_untouched
test_7_path_agreement
test_14_restart_signal_survives_a_failed_tick
test_15_marker_clear_rechecks_under_the_lock
test_16_hook_git_bounds_fit_the_hook_timeout
test_17_missing_bound_declines_instead_of_running_unbounded
test_18_hook_bootstrap_and_steady_state_are_exclusive
test_19_marker_clear_is_anchored_at_region_exit
test_20_missing_skills_publisher_is_an_error_in_both_writers
test_21_marker_removal_is_lock_checked
test_22_publisher_miss_blocks_the_clear_regardless_of_severity
test_23_bootstrap_bound_is_clamped_to_the_region
test_24_hook_clear_reasserts_the_lock
test_25_publisher_is_bounded_inside_the_lock

echo ""
echo -e "${BOLD}━━━ Summary ━━━${NC}"
if [ $FAIL -eq 0 ]; then
  echo -e "${GREEN}${BOLD}ALL PASSED${NC}: $PASS/$TOTAL tests"
  exit 0
else
  echo -e "${RED}${BOLD}FAILURES${NC}: $FAIL/$TOTAL tests failed ($PASS passed)"
  exit 1
fi
