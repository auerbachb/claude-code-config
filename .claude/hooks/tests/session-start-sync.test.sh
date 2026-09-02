#!/usr/bin/env bash
# Regression tests for the SessionStart migration of session-start-sync.sh (issue #792).
# Asserts correct registration wiring across global-settings.json and
# setup-skills-worktree.sh, and that the script itself no longer uses a
# /tmp sentinel and emits the correct event name on the error path.
set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
HOOK="$REPO_ROOT/.claude/hooks/session-start-sync.sh"
SETTINGS="$REPO_ROOT/global-settings.json"
SETUP_SCRIPT="$REPO_ROOT/setup-skills-worktree.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }

# --- 1. Registration: must be under SessionStart in global-settings.json ---
python3 - "$SETTINGS" <<'PY' || fail "session-start-sync.sh not found under SessionStart in global-settings.json"
import json, sys
with open(sys.argv[1]) as f:
    data = json.load(f)
hooks = data.get("hooks", {})
session_start = hooks.get("SessionStart", [])
found = any(
    h.get("command", "").endswith("session-start-sync.sh")
    for group in session_start
    for h in group.get("hooks", [])
)
sys.exit(0 if found else 1)
PY

# --- 2. Must NOT be under PostToolUse in global-settings.json ---
python3 - "$SETTINGS" <<'PY' || fail "session-start-sync.sh still registered under PostToolUse in global-settings.json"
import json, sys
with open(sys.argv[1]) as f:
    data = json.load(f)
hooks = data.get("hooks", {})
post_tool_use = hooks.get("PostToolUse", [])
found = any(
    h.get("command", "").endswith("session-start-sync.sh")
    for group in post_tool_use
    for h in group.get("hooks", [])
)
sys.exit(1 if found else 0)
PY

# --- 3. SessionStart registration must have timeout 30 in global-settings.json ---
python3 - "$SETTINGS" <<'PY' || fail "session-start-sync.sh SessionStart registration does not have timeout 30"
import json, sys
with open(sys.argv[1]) as f:
    data = json.load(f)
hooks = data.get("hooks", {})
session_start = hooks.get("SessionStart", [])
for group in session_start:
    for h in group.get("hooks", []):
        if h.get("command", "").endswith("session-start-sync.sh"):
            sys.exit(0 if h.get("timeout") == 30 else 1)
sys.exit(1)
PY

# --- 4. HOOKS_MANIFEST must NOT be defined in setup-skills-worktree.sh ---
# HOOKS_MANIFEST was retired by issue #1019 — global-settings.json is now the
# single source of truth and register-hooks.py reads it directly.  This check
# guards against accidental re-introduction of the duplicated manifest array.
if grep -q "HOOKS_MANIFEST=" "$SETUP_SCRIPT" 2>/dev/null; then
  fail "HOOKS_MANIFEST array is still defined in setup-skills-worktree.sh — it should have been retired (issue #1019)"
fi

# --- 5. setup-skills-worktree.sh must delegate to register-hooks.py in full mode ---
# Full-mode invocation (no --statusline-only) registers all hooks from
# global-settings.json, including the SessionStart entry for session-start-sync.sh.
# Match the actual invocation, not comments or the REGISTER_HOOKS_PY assignment.
grep -qE 'python3[[:space:]]+"?\$(\{)?REGISTER_HOOKS_PY' "$SETUP_SCRIPT" \
  || fail "setup-skills-worktree.sh does not invoke register-hooks.py — hook registration may be broken"
# Full-mode must not pass --statusline-only: that flag skips hook registration entirely.
if grep -E 'python3[[:space:]]+"?\$(\{)?REGISTER_HOOKS_PY' "$SETUP_SCRIPT" | grep -q -- "--statusline-only"; then
  fail "setup-skills-worktree.sh invokes register-hooks.py with --statusline-only — this skips hook registration"
fi

# --- 6. Hook script must not reference /tmp/claude-config-synced- sentinel ---
grep -q 'claude-config-synced' "$HOOK" \
  && fail "session-start-sync.sh still references /tmp/claude-config-synced-* sentinel"
true

# --- 7. Hook script error path must emit hookEventName: "SessionStart" ---
# Trigger the error path by running the hook with a sandboxed HOME that has
# no skills-worktree present (setup_script check is skipped via a non-existent
# path, so the script reaches the "skills worktree not found" error).
TMP_HOME="$(mktemp -d)"
cleanup() { rm -rf "$TMP_HOME"; }
trap cleanup EXIT

out=$(HOME="$TMP_HOME" echo '{}' | bash "$HOOK" 2>/dev/null || true)
# The script should produce JSON with hookEventName: "SessionStart" on error.
# Pass hook output via an environment variable — combining a pipe with a
# heredoc (echo "$out" | python3 - <<'PY') silently discards the pipe because
# the heredoc wins fd 0 (see feedback_bash_heredoc_pipe_stdin.md), leaving
# sys.stdin.read() empty and the hookEventName assertion unreachable.
HOOK_OUT="$out" python3 - <<'PY' || fail "error path does not emit hookEventName: 'SessionStart'; got: $out"
import json, sys, os
text = os.environ.get("HOOK_OUT", "").strip()
if not text or text == '{}':
    # Clean exit (e.g. idempotent setup script ran and succeeded) — no assertion needed
    sys.exit(0)
try:
    d = json.loads(text)
except json.JSONDecodeError:
    sys.exit(1)
event = d.get("hookSpecificOutput", {}).get("hookEventName", "")
sys.exit(0 if event == "SessionStart" else 1)
PY

# --- 8. Config-sync mutex: the worktree/symlink region runs under the lock ---
# Issue #1524: claude-config-sync.sh performs the same fast-forward, symlink
# publish and hook registration on an hourly LaunchAgent. Both sides must take
# the one lock, or a scheduled `git reset --hard` can race this hook's publish.
grep -q 'state-lock.sh' "$HOOK" \
  || fail "session-start-sync.sh does not source state-lock.sh — the config-sync region is unserialized"
grep -q 'state_lock_acquire' "$HOOK" \
  || fail "session-start-sync.sh never calls state_lock_acquire"
grep -q 'state_lock_release' "$HOOK" \
  || fail "session-start-sync.sh never releases the lock"
grep -qF '.claude/logs/claude-config-sync-state.json' "$HOOK" \
  || fail "session-start-sync.sh does not use claude-config-sync.sh's canonical lock base"

# Sub-second contention probe (BugBot 6f97b65b, PR #1553): a holder that
# appears after the structural lockdir test and releases within the same whole
# second defeats both the structural and the whole-second timing checks — the
# startup then reads as uncontended and clears the restart marker for
# definitions this session never loaded. The zero-timeout acquire is a single
# non-blocking attempt (state-lock.sh tries mkdir before its first deadline
# check), so any wait at all implies a failed probe.
grep -qF 'state_lock_acquire "$_sync_lock_base" 0 ' "$HOOK" \
  || fail "session-start-sync.sh lacks the zero-timeout contention probe — a sub-second lock wait reads as uncontended and can clear the restart marker for definitions this session never loaded"
grep -qF '_lock_probe_waited == 1' "$HOOK" \
  || fail "session-start-sync.sh does not feed the probe result into _lock_contended"

# Post-region budget honesty (BugBot 111e48c9, PR #1553): repo-root.sh defaults
# to 10s per git call and may run two, which alone exceeds the hook's 9s
# post-region reserve — a slow-but-successful reset could then have the hook
# killed before publish with nothing recorded. Both lookups must carry the
# explicit 3s-per-call bound so the reserve arithmetic actually covers them.
[ "$(grep -cF 'REPO_ROOT_TIMEOUT_SECS=3 bash "$_repo_root_helper"' "$HOOK")" -eq 2 ] \
  || fail "session-start-sync.sh must bound BOTH repo-root.sh lookups with REPO_ROOT_TIMEOUT_SECS=3 — the 10s/call default exceeds the 9s post-region reserve"

# The lock must be released BEFORE the root-repo sync: that is a different
# resource, and holding the config-sync lock across a `git pull` would block
# every scheduled tick for the duration of the pull.
# Matched by symbol with a word boundary, on the first non-comment line: keying
# on exact indentation would break on any reformat that leaves the contract
# intact.
line_release="$(grep -nE '^[^#]*\bstate_lock_release\b' "$HOOK" | head -1 | cut -d: -f1)"
line_root_sync="$(grep -n 'Sync root repo' "$HOOK" | head -1 | cut -d: -f1)"
[[ -n "$line_release" && -n "$line_root_sync" ]] \
  || fail "could not locate the lock release / root-repo sync markers in session-start-sync.sh"
[[ "$line_release" -lt "$line_root_sync" ]] \
  || fail "session-start-sync.sh holds the config-sync lock across the root-repo sync"

# --- 9. The hook publishes skill symlinks, not just agent symlinks ---
grep -q 'publish-skill-symlinks' "$HOOK" \
  || fail "session-start-sync.sh does not publish skill/CLAUDE.md/rules symlinks (issue #1524)"

# --- 10. Marker handling: surfaced always, restart portion cleared on startup ---
grep -qF '.claude/sync-restart-recommended.json' "$HOOK" \
  || fail "session-start-sync.sh does not read the config-sync marker"
grep -q 'del(.restart_recommended)' "$HOOK" \
  || fail "session-start-sync.sh never clears the restart portion of the marker"

# --- 11. Functional: marker surfaced on resume, cleared only on startup ---
# A skills-worktree shaped just enough to skip the bootstrap branch keeps this
# fast: the fetch fails, the hook records that as an error, and the marker path
# — the part under test — still runs.
MARKER_HOME="$(mktemp -d)"
marker_cleanup() { rm -rf "$TMP_HOME" "$MARKER_HOME"; }
trap marker_cleanup EXIT
mkdir -p "$MARKER_HOME/.claude/skills-worktree/.claude/skills"
: > "$MARKER_HOME/.claude/skills-worktree/.git"
cat > "$MARKER_HOME/.claude/sync-restart-recommended.json" <<'JSON'
{
  "restart_recommended": {
    "reason": "config sync updated agents, rules",
    "categories": ["agents", "rules"],
    "head_sha": "0123456789abcdef0123456789abcdef01234567",
    "at": "2026-09-01T00:00:00Z"
  },
  "sync_failure": {
    "message": "config sync has been failing for 2 day(s) — 5 consecutive failures",
    "consecutive_failures": 5,
    "first_failure_at": "2026-08-30T00:00:00Z",
    "at": "2026-09-01T00:00:00Z"
  }
}
JSON

resume_out=$(printf '{"source":"resume"}' | HOME="$MARKER_HOME" bash "$HOOK" 2>/dev/null || true)
RESUME_OUT="$resume_out" python3 - <<'PY' || fail "resume did not surface both marker portions; got: $resume_out"
import json, os, sys
text = os.environ.get("RESUME_OUT", "").strip()
try:
    ctx = json.loads(text)["hookSpecificOutput"]["additionalContext"]
except Exception:
    sys.exit(1)
sys.exit(0 if "RESTART RECOMMENDED" in ctx and "CONFIG SYNC FAILING" in ctx else 1)
PY

python3 - "$MARKER_HOME/.claude/sync-restart-recommended.json" <<'PY' || fail "resume cleared the restart portion — only a true startup may clear it"
import json, sys
with open(sys.argv[1]) as f:
    d = json.load(f)
sys.exit(0 if d.get("restart_recommended") is not None else 1)
PY

startup_out=$(printf '{"source":"startup"}' | HOME="$MARKER_HOME" bash "$HOOK" 2>/dev/null || true)
STARTUP_OUT="$startup_out" python3 - <<'PY' || fail "startup did not surface the marker before clearing it; got: $startup_out"
import json, os, sys
text = os.environ.get("STARTUP_OUT", "").strip()
try:
    ctx = json.loads(text)["hookSpecificOutput"]["additionalContext"]
except Exception:
    sys.exit(1)
sys.exit(0 if "RESTART RECOMMENDED" in ctx else 1)
PY

# This fixture's fetch fails on purpose (see above), and a startup whose own
# sync region FAILED has not demonstrably loaded the current definitions — so
# the restart portion must survive here. Clearing it was the bug: the guard now
# requires success as well as `source == startup`, an un-skipped region and an
# unchanged marker.
python3 - "$MARKER_HOME/.claude/sync-restart-recommended.json" <<'PY' || fail "a startup whose sync region failed wrongly cleared the restart portion"
import json, os, sys
path = sys.argv[1]
if not os.path.exists(path):
    sys.exit(1)
with open(path) as f:
    d = json.load(f)
ok = d.get("restart_recommended") is not None and d.get("sync_failure") is not None
sys.exit(0 if ok else 1)
PY

# --- 11b. A startup whose sync SUCCEEDED does clear the restart portion ---
# The case above proves the guard blocks a failed startup; without this one the
# suite could pass with a guard that never clears at all. Needs a worktree the
# fetch and reset actually succeed against, so build a real local origin.
OK_HOME="$(mktemp -d)"
ok_cleanup() { rm -rf "$TMP_HOME" "$MARKER_HOME" "$OK_HOME"; }
trap ok_cleanup EXIT
OK_ORIGIN="$OK_HOME/origin"
mkdir -p "$OK_ORIGIN/.claude/skills/alpha" "$OK_HOME/.claude/logs"
printf '# alpha\n' > "$OK_ORIGIN/.claude/skills/alpha/SKILL.md"
printf '# CLAUDE\n' > "$OK_ORIGIN/CLAUDE.md"
git init -q "$OK_ORIGIN" >/dev/null 2>&1
git -C "$OK_ORIGIN" symbolic-ref HEAD refs/heads/main >/dev/null 2>&1
git -C "$OK_ORIGIN" add -A >/dev/null 2>&1
git -C "$OK_ORIGIN" -c user.email=t@e.invalid -c user.name=T -c commit.gpgsign=false \
  commit -q -m "seed" >/dev/null 2>&1
# A real git WORKTREE, not a clone: the hook's bootstrap branch tests for a
# `.git` FILE, which is what a worktree has and a clone does not — a clone would
# send this fixture down the setup path and error, defeating the point. Detached
# so it does not contend for `main`, which the intermediate clone has checked
# out; the worktree inherits that clone's `origin`, so fetch and reset resolve.
git clone -q "$OK_ORIGIN" "$OK_HOME/repo" >/dev/null 2>&1
git -C "$OK_HOME/repo" worktree add -q --detach "$OK_HOME/.claude/skills-worktree" main >/dev/null 2>&1

cat > "$OK_HOME/.claude/sync-restart-recommended.json" <<'JSON'
{
  "restart_recommended": {
    "reason": "config sync updated agents, rules",
    "categories": ["agents", "rules"],
    "head_sha": "0123456789abcdef0123456789abcdef01234567",
    "at": "2026-09-01T00:00:00Z"
  },
  "sync_failure": {
    "message": "config sync has been failing for 2 day(s) — 5 consecutive failures",
    "consecutive_failures": 5,
    "first_failure_at": "2026-08-30T00:00:00Z",
    "at": "2026-09-01T00:00:00Z"
  }
}
JSON

ok_out=$(printf '{"source":"startup"}' | HOME="$OK_HOME" bash "$HOOK" 2>/dev/null || true)
# Assert the premise before the conclusion: if this run also errored, the check
# below would pass for the wrong reason — by never reaching the clear at all.
OK_OUT="$ok_out" python3 - <<'PY' || fail "the success fixture still reported a sync error, so the clear path was not exercised; got: $ok_out"
import json, os, sys
text = os.environ.get("OK_OUT", "").strip()
if not text:
    sys.exit(0)
try:
    ctx = json.loads(text)["hookSpecificOutput"]["additionalContext"]
except Exception:
    sys.exit(0)
sys.exit(1 if "Config sync encountered errors" in ctx else 0)
PY

python3 - "$OK_HOME/.claude/sync-restart-recommended.json" <<'PY' || fail "a startup whose sync succeeded did not clear the restart portion, or wrongly cleared the failure portion"
import json, os, sys
path = sys.argv[1]
if not os.path.exists(path):
    sys.exit(1)
with open(path) as f:
    d = json.load(f)
ok = d.get("restart_recommended") is None and d.get("sync_failure") is not None
sys.exit(0 if ok else 1)
PY

# --- 12. A startup that SKIPPED the sync region must not clear the marker ---
# At login, launchd's RunAtLoad tick and a new session overlap. If the hook
# loses the config-sync lock it skips the worktree and symlink refresh — so this
# session is running the OLD definitions — and must not then delete the restart
# marker the scheduled job just wrote. Doing so left the user on stale agents,
# rules and skills with neither the context notice nor the statusline badge.
SKIP_HOME="$(mktemp -d)"
skip_cleanup() { rm -rf "$TMP_HOME" "$MARKER_HOME" "$SKIP_HOME"; }
trap skip_cleanup EXIT
mkdir -p "$SKIP_HOME/.claude/skills-worktree/.claude/skills" "$SKIP_HOME/.claude/logs"
: > "$SKIP_HOME/.claude/skills-worktree/.git"
cat > "$SKIP_HOME/.claude/sync-restart-recommended.json" <<'JSON'
{
  "restart_recommended": {
    "reason": "config sync updated agents",
    "categories": ["agents"],
    "head_sha": "0123456789abcdef0123456789abcdef01234567",
    "at": "2026-09-01T00:00:00Z"
  }
}
JSON

# Hold the config-sync lock the way state-lock.sh would, naming THIS test
# process as the owner so the stale-lock breaker sees a live pid and declines
# to steal it. Without a valid owner file the lock is breakable and the hook
# would sail through, testing nothing.
SKIP_LOCK="$SKIP_HOME/.claude/logs/claude-config-sync-state.json.lock"
mkdir -p "$SKIP_LOCK"
{ printf 'pid=%s\n' "$$"
  printf 'host=%s\n' "${HOSTNAME:-$(hostname)}"
  printf 'epoch=%s\n' "$(date +%s)"
  printf 'started=%s\n' "$(date -u +%FT%TZ)"
  printf 'cmd=%s\n' "concurrent-scheduled-sync"
  printf 'token=%s\n' "test-token"
} > "$SKIP_LOCK/owner"

# The lock must be RELEASED partway through the run, not held for the whole of
# it. Holding it throughout makes even the buggy code look correct: the clear
# block takes the same lock, so a still-held lock blocks the deletion for the
# wrong reason and the test passes vacuously (verified — it did).
#
# The real login race is: the scheduled sync holds the lock while the hook tries
# to sync (hook skips), then the scheduled sync FINISHES — writing the marker
# and releasing — and only then does the hook reach its clear, which now
# succeeds. Releasing after ~2s lands inside that window: past the 1s
# sync-region timeout, inside the 5s clear timeout.
( sleep 2; rm -rf "$SKIP_LOCK" ) &
_skip_releaser=$!

skip_out=$(printf '{"source":"startup"}' \
  | HOME="$SKIP_HOME" CLAUDE_CONFIG_SYNC_HOOK_LOCK_TIMEOUT=1 bash "$HOOK" 2>/dev/null || true)
wait "$_skip_releaser" 2>/dev/null || true

# Control: the run must actually have taken the skip path, or the assertion
# below would pass for the wrong reason.
SKIP_OUT="$skip_out" python3 - <<'PY' || fail "the hook did not take the lock-contention skip path; got: $skip_out"
import json, os, sys
try:
    ctx = json.loads(os.environ["SKIP_OUT"])["hookSpecificOutput"]["additionalContext"]
except Exception:
    sys.exit(1)
sys.exit(0 if "holds the lock" in ctx else 1)
PY

python3 - "$SKIP_HOME/.claude/sync-restart-recommended.json" <<'PY' || fail "a startup that skipped the sync region cleared the restart marker — the session is on stale definitions with no signal"
import json, os, sys
path = sys.argv[1]
if not os.path.exists(path):
    sys.exit(1)
with open(path) as f:
    d = json.load(f)
sys.exit(0 if d.get("restart_recommended") is not None else 1)
PY

rm -rf "$SKIP_LOCK"

# --- 13. A startup that WAITED for the lock must not clear the marker ------
# The skip guard in case 12 is not sufficient on its own. A hook that waits out
# some of the lock timeout and then successfully acquires it HAS run the sync
# region — so that guard passes — yet whoever held the lock may have finished,
# written the marker and released during the wait, describing changes this
# session does not have. The clear is therefore also gated on the acquire being
# uncontended.
FRESH_HOME="$(mktemp -d)"
fresh_cleanup() { rm -rf "$TMP_HOME" "$MARKER_HOME" "$SKIP_HOME" "$FRESH_HOME"; }
trap fresh_cleanup EXIT
mkdir -p "$FRESH_HOME/.claude/skills-worktree/.claude/skills" "$FRESH_HOME/.claude/logs"
: > "$FRESH_HOME/.claude/skills-worktree/.git"
cat > "$FRESH_HOME/.claude/sync-restart-recommended.json" <<'JSON'
{
  "restart_recommended": {
    "reason": "config sync updated agents",
    "categories": ["agents"],
    "head_sha": "0123456789abcdef0123456789abcdef01234567",
    "at": "2026-09-01T00:00:00Z"
  }
}
JSON

# Hold the lock, then release it partway through the DEFAULT 10s wait so the
# hook waits, acquires, and runs the region — the exact shape case 12 does not
# cover. `at` is deliberately old here: the guard under test is contention, not
# the timestamp, so an old marker proves the contention check is what fires.
FRESH_LOCK="$FRESH_HOME/.claude/logs/claude-config-sync-state.json.lock"
mkdir -p "$FRESH_LOCK"
{ printf 'pid=%s\n' "$$"
  printf 'host=%s\n' "${HOSTNAME:-$(hostname)}"
  printf 'epoch=%s\n' "$(date +%s)"
  printf 'started=%s\n' "$(date -u +%FT%TZ)"
  printf 'cmd=%s\n' "concurrent-scheduled-sync"
  printf 'token=%s\n' "test-token"
} > "$FRESH_LOCK/owner"
( sleep 2; rm -rf "$FRESH_LOCK" ) &
_fresh_releaser=$!

fresh_out=$(printf '{"source":"startup"}' | HOME="$FRESH_HOME" bash "$HOOK" 2>/dev/null || true)
wait "$_fresh_releaser" 2>/dev/null || true

# Control: this run must NOT have taken the skip path. If it did, case 12's
# guard is what kept the marker and the contention check went untested.
FRESH_OUT="$fresh_out" python3 - <<'PY' || fail "case 13 took the lock-skip path; it must acquire the lock after waiting"
import json, os, sys
try:
    ctx = json.loads(os.environ["FRESH_OUT"])["hookSpecificOutput"]["additionalContext"]
except Exception:
    sys.exit(0)
sys.exit(1 if ("holds the lock" in ctx or "state-lock.sh not found" in ctx) else 0)
PY

python3 - "$FRESH_HOME/.claude/sync-restart-recommended.json" <<'PY' || fail "a startup that waited for the lock cleared the marker — the session may be on stale definitions with no signal"
import json, os, sys
path = sys.argv[1]
if not os.path.exists(path):
    sys.exit(1)
with open(path) as f:
    d = json.load(f)
sys.exit(0 if d.get("restart_recommended") is not None else 1)
PY

echo "OK: session-start-sync.sh SessionStart migration tests passed"
