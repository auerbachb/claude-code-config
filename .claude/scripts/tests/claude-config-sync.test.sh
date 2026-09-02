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

  section "Test 3b: session start on 'startup' surfaces the marker and clears it"

  local hook_out
  hook_out="$(printf '{"source":"startup"}' | HOME="$home" bash "$HOOK" 2>/dev/null)"

  assert "hook surfaced the restart notice" \
    "printf '%s' \"\$hook_out\" | jq -r '.hookSpecificOutput.additionalContext // \"\"' | grep -q 'RESTART RECOMMENDED'"
  assert "restart portion cleared after a true startup" \
    "[ ! -f '$home/.claude/sync-restart-recommended.json' ] || jq -e '(.restart_recommended // null) == null' '$home/.claude/sync-restart-recommended.json'"
  assert "statusline no longer shows the restart badge" \
    "! printf '{}' | HOME='$home' bash '$STATUSLINE' | grep -q 'restart'"

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
  assert "the categories are collected in a named helper" \
    "grep -q 'collect_head_change_categories()' '$SYNC'"
  assert "the helper is invoked at the fast-forward" \
    "awk '/HEAD_CHANGED=\"true\"/,/^  else\$/' '$SYNC' | grep -q 'collect_head_change_categories'"
  assert "record_failure re-emits restart_recommended" \
    "awk '/^record_failure\\(\\)/,/^}/' '$SYNC' | grep -q 'restart_recommended'"
  assert "record_failure only does so when categories exist" \
    "awk '/^record_failure\\(\\)/,/^}/' '$SYNC' | grep -qF 'if (( \${#RESTART_CATEGORIES[@]} > 0 )); then'"

  # Negative control: Step 5 must no longer carry the diff itself, or the fix
  # would be a duplicate rather than a move.
  assert "(control) Step 5 no longer runs the diff" \
    "! awk '/Step 5 — change detection/,/De-duplicate while preserving order/' '$SYNC' | grep -q 'diff --name-only'"
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
  local producer captured rc
  producer='printf "worktree /Users/me/repo\nHEAD abc\n\n"; for i in $(seq 1 20000); do printf "worktree /Users/me/repo/.claude/worktrees/wt-%s\nHEAD def\n\n" "$i"; done'

  # The expression under test, lifted from the script rather than retyped, so a
  # future edit that reintroduces `exit` fails this test instead of passing a
  # stale copy.
  local expr
  expr="$(grep -o "awk '/\^worktree /{if (!seen++).*}'" "$SYNC" | head -1)"
  assert "the awk expression was found in the script" "[ -n \"\$expr\" ]"
  assert "and it does NOT early-exit" \
    "case \"\$expr\" in *exit*) false ;; *) : ;; esac"

  captured="$(bash -c "set -o pipefail; { $producer; } | $expr")"
  rc=$?
  assert "the pipeline succeeds despite a huge producer" "[ $rc -eq 0 ]"
  assert "and it yields the main worktree path" \
    "[ \"\$captured\" = '/Users/me/repo' ]"

  # Negative control: the pre-fix expression really does fail this way, so the
  # assertions above are testing the hazard rather than a tautology.
  local old_rc=0
  bash -c "set -o pipefail; { $producer; } | awk '/^worktree /{sub(/^worktree /, \"\"); print; exit}' >/dev/null" || old_rc=$?
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

echo ""
echo -e "${BOLD}━━━ Summary ━━━${NC}"
if [ $FAIL -eq 0 ]; then
  echo -e "${GREEN}${BOLD}ALL PASSED${NC}: $PASS/$TOTAL tests"
  exit 0
else
  echo -e "${RED}${BOLD}FAILURES${NC}: $FAIL/$TOTAL tests failed ($PASS passed)"
  exit 1
fi
