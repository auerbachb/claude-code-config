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

# --- 13b. root-repo helper is resolved above the lock branch (BugBot High, PR #1553) ---
# The root-repo sync runs on the lock-skip path too; a helper assigned only
# inside the locked region is unset there, producing a false "root repo could
# not be resolved" error and a skipped main pull on every login overlap.
helper_line="$(grep -n '^_repo_root_helper=' "$HOOK" | head -1 | cut -d: -f1)"
lock_line="$(grep -n 'state_lock_acquire "$_sync_lock_base" 0' "$HOOK" | head -1 | cut -d: -f1)"
[ -n "$helper_line" ] && [ -n "$lock_line" ] \
  || fail "could not locate the repo-root helper assignment / lock acquire in the hook"
[ "$helper_line" -lt "$lock_line" ] \
  || fail "_repo_root_helper is assigned after the lock branch — unset on the lock-skip path, so a contended login falsely fails the root-repo sync"

# --- 14. resume-source fast-forward writes the restart signal (BugBot High, PR #1553) ---
# A resumed session keeps the definitions it loaded at its original start. When
# the hook's own fast-forward brings in new content on resume/compact/clear,
# nothing else will ever signal it: the scheduled job only reports changes its
# own run made, and its next tick sees an unchanged HEAD. The hook must write
# restart_recommended itself — and a startup control must NOT trip this path.
R14="$(mktemp -d)"
R14_HOME="$R14/home"; mkdir -p "$R14_HOME/.claude/logs"
R14_UP="$R14/upstream"
git init -q -b main "$R14_UP"
mkdir -p "$R14_UP/.claude/skills/alpha"
printf '# one\n' > "$R14_UP/.claude/skills/alpha/SKILL.md"
git -C "$R14_UP" add -A >/dev/null 2>&1
git -C "$R14_UP" -c user.email=t@t -c user.name=t commit -qm one
# A real skills-worktree is a `git worktree` (its .git is a FILE); a plain clone
# has a .git DIRECTORY and trips the hook's bootstrap branch instead.
git clone -q "$R14_UP" "$R14/base"
git -C "$R14/base" worktree add -q --detach "$R14_HOME/.claude/skills-worktree" main
printf '# two\n' > "$R14_UP/.claude/skills/alpha/SKILL.md"
git -C "$R14_UP" add -A >/dev/null 2>&1
git -C "$R14_UP" -c user.email=t@t -c user.name=t commit -qm two
printf '{"source":"resume"}' | HOME="$R14_HOME" bash "$HOOK" >/dev/null 2>&1 || true
python3 - "$R14_HOME/.claude/sync-restart-recommended.json" <<'PY' || fail "a resume-source fast-forward left no restart signal — the resumed session runs stale definitions with no reminder (BugBot High, PR #1553)"
import json, sys
try:
    with open(sys.argv[1]) as f:
        d = json.load(f)
except Exception:
    sys.exit(1)
rr = d.get("restart_recommended") or {}
sys.exit(0 if "skills" in (rr.get("categories") or []) else 1)
PY
# Control: the same fast-forward on a STARTUP source must not leave a restart
# signal — a fresh session already loaded what it just fetched.
R14B_HOME="$R14/home-b"; mkdir -p "$R14B_HOME/.claude/logs"
git clone -q "$R14_UP" "$R14/base-b"
git -C "$R14/base-b" worktree add -q --detach "$R14B_HOME/.claude/skills-worktree" main
git -C "$R14B_HOME/.claude/skills-worktree" reset -q --hard HEAD~1
printf '{"source":"startup"}' | HOME="$R14B_HOME" bash "$HOOK" >/dev/null 2>&1 || true
# The control is only a control if the startup actually fast-forwarded: a
# failed fetch would leave the marker absent for the wrong reason.
[ "$(git -C "$R14B_HOME/.claude/skills-worktree" rev-parse HEAD)" = "$(git -C "$R14_UP" rev-parse main)" ] \
  || fail "the startup control did not fast-forward — its no-signal result would be vacuous"
python3 - "$R14B_HOME/.claude/sync-restart-recommended.json" <<'PY' || fail "a startup-source fast-forward wrote a restart signal — a fresh session already loaded what it fetched"
import json, os, sys
path = sys.argv[1]
if not os.path.exists(path):
    sys.exit(0)
try:
    with open(path) as f:
        d = json.load(f)
except Exception:
    sys.exit(1)
sys.exit(1 if d.get("restart_recommended") is not None else 0)
PY
# Link-only leg: a resume whose publish CREATED links with an unchanged HEAD is
# just as forever-silent (a later tick sees a stable HEAD and the links already
# in place), so it must write the signal too.
R14C_HOME="$R14/home-c"; mkdir -p "$R14C_HOME/.claude/logs"
git clone -q "$R14_UP" "$R14/base-c"
git -C "$R14/base-c" worktree add -q --detach "$R14C_HOME/.claude/skills-worktree" main
printf '{"source":"resume"}' | HOME="$R14C_HOME" bash "$HOOK" >/dev/null 2>&1 || true
python3 - "$R14C_HOME/.claude/sync-restart-recommended.json" <<'PY' || fail "a resume whose publish created links on an unchanged HEAD left no restart signal (BugBot Medium, PR #1553)"
import json, sys
try:
    with open(sys.argv[1]) as f:
        d = json.load(f)
except Exception:
    sys.exit(1)
rr = d.get("restart_recommended") or {}
sys.exit(0 if "skills" in (rr.get("categories") or []) else 1)
PY
# Phantom control: a user-owned AGENT link makes the agents publisher print its
# standing advisory on stdout. With links already settled and nothing changed,
# a resume must NOT raise a restart signal off that advisory.
printf '# beta agent\n' > "$R14_UP/.claude/agents-placeholder" 2>/dev/null || true
mkdir -p "$R14_UP/.claude/agents"
printf '# beta\n' > "$R14_UP/.claude/agents/beta.md"
git -C "$R14_UP" add -A >/dev/null 2>&1
git -C "$R14_UP" -c user.email=t@t -c user.name=t commit -qm three
R14D_HOME="$R14/home-d"; mkdir -p "$R14D_HOME/.claude/logs"
git clone -q "$R14_UP" "$R14/base-d"
git -C "$R14/base-d" worktree add -q --detach "$R14D_HOME/.claude/skills-worktree" main
# First run (startup) settles every link and writes no signal by design.
printf '{"source":"startup"}' | HOME="$R14D_HOME" bash "$HOOK" >/dev/null 2>&1 || true
# Plant a personal agent link, then resume with nothing else changed.
mkdir -p "$R14D_HOME/.claude/agents"
ln -sf /tmp/does-not-matter "$R14D_HOME/.claude/agents/gamma.md" 2>/dev/null || true
printf '{"source":"resume"}' | HOME="$R14D_HOME" bash "$HOOK" >/dev/null 2>&1 || true
python3 - "$R14D_HOME/.claude/sync-restart-recommended.json" <<'PY' || fail "a settled resume with only a user-owned agent link raised a phantom restart signal (BugBot d377f4b1, PR #1553)"
import json, os, sys
path = sys.argv[1]
if not os.path.exists(path):
    sys.exit(0)
try:
    with open(path) as f:
        d = json.load(f)
except Exception:
    sys.exit(1)
sys.exit(1 if d.get("restart_recommended") is not None else 0)
PY
# Error-independence leg: a resume whose FETCH fails but whose publish still
# lands link changes must still write the signal — a later unrelated error must
# not suppress work that already landed (the scheduled job can never recover
# it: its next tick sees a stable HEAD and the links already in place).
R14E_HOME="$R14/home-e"; mkdir -p "$R14E_HOME/.claude/logs"
git clone -q "$R14_UP" "$R14/base-e"
git -C "$R14/base-e" worktree add -q --detach "$R14E_HOME/.claude/skills-worktree" main
git -C "$R14E_HOME/.claude/skills-worktree" remote set-url origin "$R14/nonexistent-upstream"
printf '{"source":"resume"}' | HOME="$R14E_HOME" bash "$HOOK" >/dev/null 2>&1 || true
python3 - "$R14E_HOME/.claude/sync-restart-recommended.json" <<'PY' || fail "a resume with a failed fetch but a landed publish left no restart signal — a later unrelated error suppressed landed work (BugBot High, PR #1553)"
import json, sys
try:
    with open(sys.argv[1]) as f:
        d = json.load(f)
except Exception:
    sys.exit(1)
rr = d.get("restart_recommended") or {}
sys.exit(0 if "skills" in (rr.get("categories") or []) else 1)
PY
# CLAUDE.md label mapping: a resume that links CLAUDE.md must record claude-md,
# not blanket-'skills' — the two marker writers must agree on category names.
printf '# global claude md\n' > "$R14_UP/CLAUDE.md"
git -C "$R14_UP" add -A >/dev/null 2>&1
git -C "$R14_UP" -c user.email=t@t -c user.name=t commit -qm four
R14F_HOME="$R14/home-f"; mkdir -p "$R14F_HOME/.claude/logs"
git clone -q "$R14_UP" "$R14/base-f"
git -C "$R14/base-f" worktree add -q --detach "$R14F_HOME/.claude/skills-worktree" main
printf '{"source":"resume"}' | HOME="$R14F_HOME" bash "$HOOK" >/dev/null 2>&1 || true
python3 - "$R14F_HOME/.claude/sync-restart-recommended.json" <<'PY' || fail "a resume that linked CLAUDE.md did not record the claude-md category (BugBot 7454568b, PR #1553)"
import json, sys
try:
    with open(sys.argv[1]) as f:
        d = json.load(f)
except Exception:
    sys.exit(1)
rr = d.get("restart_recommended") or {}
sys.exit(0 if "claude-md" in (rr.get("categories") or []) else 1)
PY
# Harvest-before-rc ordering: the category harvest must precede the non-zero
# exit branch, or a publisher that lands links then fails hides them. The bound
# trip is the ONE branch that legitimately precedes the harvest: a killed
# publisher's capture is not a trustworthy account of what it landed, and it is
# recorded as incomplete rather than harvested.
harvest_line="$(grep -n '_publish_change_verbs" <<< "\$out"' "$HOOK" | head -1 | cut -d: -f1)"
rcbranch_line="$(grep -n 'symlink publish failed: \${err:-\$out}' "$HOOK" | head -1 | cut -d: -f1)"
[ -n "$harvest_line" ] && [ -n "$rcbranch_line" ] \
  || fail "could not locate the harvest / rc-branch lines in _publish_one"
[ "$harvest_line" -lt "$rcbranch_line" ] \
  || fail "_publish_one branches on rc before harvesting change categories — landed links from a failing publisher are hidden (BugBot, PR #1553)"
rm -rf "$R14"

# --- 15. The symlink publishers are BOUNDED (issue #1593) -------------------
# PR #1553 bounded the git region but deliberately left the publishers outside
# it, on the grounds that a few dozen readlink/ln/mv calls finish in well under
# a second. On a stalled network home they do not: an unbounded publisher
# outlives the registered 30s hook timeout mid-publish — some links rewritten,
# some not — and a KILL records nothing, so the marker-clear guard cannot see
# that the publish was partial and deletes a signal for definitions still stale
# on disk.
#
# Structural checks first, so a refactor that drops the bound fails loudly even
# where the functional fixture below cannot run.
grep -q '_HOOK_TAIL_RESERVE_SECS' "$HOOK" \
  || fail "session-start-sync.sh has no post-region reserve — the publishers and root-repo sync leg are not scheduled against the hook deadline (issue #1593)"
# The whole function body, not a fixed -A window: a comment added inside it
# must not silently push an assertion off the end and make it pass vacuously.
publish_one_body="$(awk '/^  _publish_one\(\) \{/,/^  \}$/' "$HOOK")"
[ -n "$publish_one_body" ] \
  || fail "could not extract the _publish_one body from session-start-sync.sh"
case "$publish_one_body" in
  *_run_hook_bounded*) : ;;
  *) fail "_publish_one runs its publisher unbounded — a stall outlives the 30s hook timeout with nothing recorded (issue #1593)" ;;
esac
case "$publish_one_body" in
  *'symlink publish failed: $(_bound_trip_reason)'*) : ;;
  *) fail "a publisher bound trip does not carry the '… symlink publish failed' token the publish guard keys off (issue #1593)" ;;
esac
case "$publish_one_body" in
  *_publish_incomplete=1*) : ;;
  *) fail "a publisher bound trip does not set _publish_incomplete — a partial publish could still clear the restart marker (issue #1593)" ;;
esac
# The root-repo sync leg (owner scope addition from PR #1553 BugBot 3922462913):
# it runs after the marker clear and before additionalContext is emitted, so an
# overrun there loses the session's informational notice.
[ "$(grep -c '_run_hook_bounded --reserve "\$_HOOK_TAIL_RESERVE_SECS" --context ' "$HOOK")" -eq 2 ] \
  || fail "session-start-sync.sh does not bound BOTH root-repo sync legs (main-sync.sh and the inline pull fallback) — issue #1593"
# ...and the decline message must not claim the lock is held: this leg runs
# AFTER the release, so a hard-coded lock rationale would be a false statement
# the reader cannot act on.
[ -z "$(grep '_run_hook_bounded --reserve "\$_HOOK_TAIL_RESERVE_SECS" --context ' "$HOOK" | grep 'holding the config-sync lock')" ] \
  || fail "the root-repo sync leg's decline message claims the config-sync lock is held, but the leg runs after the release (issue #1593)"

# Functional fixture. The hook resolves its publishers from its OWN directory,
# so the stub has to live in a copied hook tree rather than in the temp HOME.
# Only the helpers the hook actually reaches are copied; register-hooks.py is
# stubbed so a registration error cannot masquerade as the publish failure
# under test (or, in the control below, block the marker clear).
build_publish_fixture() { # build_publish_fixture <root> <skill-publisher-body>
  local root="$1" body="$2"
  mkdir -p "$root/tree/.claude/hooks" "$root/tree/.claude/scripts/lib" "$root/home/.claude/logs"
  cp "$HOOK" "$root/tree/.claude/hooks/session-start-sync.sh"
  cp "$REPO_ROOT/.claude/scripts/state-lock.sh" "$REPO_ROOT/.claude/scripts/repo-root.sh" \
     "$root/tree/.claude/scripts/"
  cp "$REPO_ROOT/.claude/scripts/lib/bounded-run.sh" "$root/tree/.claude/scripts/lib/"
  printf '#!/usr/bin/env python3\nprint("hooks registered (stub)")\n' \
    > "$root/tree/.claude/hooks/register-hooks.py"
  printf '%s' "$body" > "$root/tree/.claude/scripts/publish-skill-symlinks.sh"
  printf '#!/bin/sh\nexit 0\n' > "$root/tree/.claude/scripts/publish-agent-symlinks.sh"
  chmod +x "$root/tree/.claude/scripts/publish-skill-symlinks.sh" \
           "$root/tree/.claude/scripts/publish-agent-symlinks.sh"
  # A real git worktree: the hook's bootstrap branch tests for a `.git` FILE,
  # which a clone does not have.
  # `git init -q` + symbolic-ref rather than `init -b`: -b needs git 2.28+, and
  # the sync suite's own fixture already uses this spelling.
  git init -q "$root/up"
  git -C "$root/up" symbolic-ref HEAD refs/heads/main >/dev/null 2>&1
  mkdir -p "$root/up/.claude/skills/alpha"
  printf '# alpha\n' > "$root/up/.claude/skills/alpha/SKILL.md"
  git -C "$root/up" add -A >/dev/null 2>&1
  git -C "$root/up" -c user.email=t@t -c user.name=t commit -qm seed >/dev/null 2>&1
  git clone -q "$root/up" "$root/base" >/dev/null 2>&1
  git -C "$root/base" worktree add -q --detach "$root/home/.claude/skills-worktree" main >/dev/null 2>&1
  cat > "$root/home/.claude/sync-restart-recommended.json" <<'JSON'
{
  "restart_recommended": {
    "reason": "config sync updated skills",
    "categories": ["skills"],
    "head_sha": "0123456789abcdef0123456789abcdef01234567",
    "at": "2026-09-01T00:00:00Z"
  }
}
JSON
}

P15="$(mktemp -d)"
p15_cleanup() { rm -rf "$TMP_HOME" "$MARKER_HOME" "$SKIP_HOME" "$FRESH_HOME" "$OK_HOME" "$P15"; }
trap p15_cleanup EXIT

# Stalled leg: a publisher that sleeps far past its bound.
STALL="$P15/stall"
build_publish_fixture "$STALL" '#!/bin/sh
sleep 60
'
stall_started="$(date +%s)"
stall_out="$(printf '{"source":"startup"}' \
  | HOME="$STALL/home" CLAUDE_CONFIG_SYNC_HOOK_PUBLISH_BOUND=2 \
    bash "$STALL/tree/.claude/hooks/session-start-sync.sh" 2>/dev/null || true)"
stall_elapsed=$(( $(date +%s) - stall_started ))

[ "$stall_elapsed" -lt 45 ] \
  || fail "a stalled publisher was not cut short — the hook ran ${stall_elapsed}s (issue #1593)"
STALL_OUT="$stall_out" python3 - <<'PY' || fail "a stalled publisher left no recorded failure; got: $stall_out"
import json, os, sys
text = os.environ.get("STALL_OUT", "").strip()
try:
    ctx = json.loads(text)["hookSpecificOutput"]["additionalContext"]
except Exception:
    sys.exit(1)
# The TOKEN is the contract — it is what the publish guard and the marker clear
# key off. The exact "2s" is not: the bound is min(budget left, ceiling), so a
# slow preamble legitimately shortens it, and on a very slow machine the call is
# DECLINED outright rather than exceeded. Asserting the literal 2s would turn
# either into a red suite for a fix that worked.
ok = "skill symlink publish failed" in ctx and ("exceeded its" in ctx or "declined:" in ctx)
sys.exit(0 if ok else 1)
PY
python3 - "$STALL/home/.claude/sync-restart-recommended.json" <<'PY' || fail "a startup whose publisher tripped its bound cleared the restart marker — the session sits on a partial publish with no signal (issue #1593)"
import json, os, sys
path = sys.argv[1]
if not os.path.exists(path):
    sys.exit(1)
with open(path) as f:
    d = json.load(f)
sys.exit(0 if d.get("restart_recommended") is not None else 1)
PY

# Negative control: the SAME fixture with a publisher that finishes inside an
# ample bound. Without it the assertions above would pass for a hook that had
# simply stopped publishing altogether.
OKP="$P15/okp"
build_publish_fixture "$OKP" '#!/bin/sh
echo "  alpha — creating symlink"
exit 0
'
okp_out="$(printf '{"source":"startup"}' \
  | HOME="$OKP/home" CLAUDE_CONFIG_SYNC_HOOK_PUBLISH_BOUND=20 \
    bash "$OKP/tree/.claude/hooks/session-start-sync.sh" 2>/dev/null || true)"
OKP_OUT="$okp_out" python3 - <<'PY' || fail "the ample-budget control reported a publish failure, so the bound is tripping on a healthy publisher; got: $okp_out"
import json, os, sys
text = os.environ.get("OKP_OUT", "").strip()
if not text or text == "{}":
    sys.exit(0)
try:
    ctx = json.loads(text)["hookSpecificOutput"]["additionalContext"]
except Exception:
    sys.exit(0)
sys.exit(1 if "publish failed" in ctx else 0)
PY
python3 - "$OKP/home/.claude/sync-restart-recommended.json" <<'PY' || fail "the ample-budget control did not clear the restart marker — the stall assertion above would pass vacuously (issue #1593)"
import json, os, sys
path = sys.argv[1]
if not os.path.exists(path):
    sys.exit(0)
with open(path) as f:
    d = json.load(f)
sys.exit(1 if d.get("restart_recommended") is not None else 0)
PY
rm -rf "$P15"

# --- 16. The capture pair is handed over on a wedged child (CodeAnt, PR #1640) -
# A bound trip in this hook is NOT fatal: _publish_one records the failure and
# returns 0, so the run continues to the second publisher and then to both
# root-repo sync legs — each truncating and re-reading the SAME $CAPTURE pair.
# A child still alive after SIGKILL is wedged in uninterruptible I/O and still
# holds those descriptors open, so without bounded-run.sh's orphan handover a
# later call can read the wedged publisher's late output as its own.
#
# Structural only, on purpose: a process that survives SIGKILL cannot be
# manufactured portably in a test, so the library's own rotation logic is
# covered by bounded-run.test.sh and what is asserted here is that this caller
# OPTS IN — the failure mode being a refactor that drops the opt-in silently.
grep -q '^  ORPHANED_CAPTURES=()' "$HOOK" \
  || fail "session-start-sync.sh does not declare ORPHANED_CAPTURES — bounded-run.sh's orphan handover is off, so a wedged publisher's late output can contaminate a later call's capture (CodeAnt, PR #1640)"
grep -q '^  BOUNDED_CAPTURE_TEMPLATE=' "$HOOK" \
  || fail "session-start-sync.sh does not set BOUNDED_CAPTURE_TEMPLATE — the capture pair is never rotated away from a wedged child (CodeAnt, PR #1640)"
grep -q '^  BOUNDED_CAPTURE_ERR_TEMPLATE=' "$HOOK" \
  || fail "session-start-sync.sh does not set BOUNDED_CAPTURE_ERR_TEMPLATE — the stderr half of the pair is never rotated (CodeAnt, PR #1640)"
# The handover only removes contamination if the rotated-away files are still
# unlinked at exit; otherwise it trades a correctness bug for a temp-file leak.
hook_trap_line="$(grep -n "trap 'rm -f" "$HOOK" | head -1 | cut -d: -f2-)"
case "$hook_trap_line" in
  *'${ORPHANED_CAPTURES[@]+"${ORPHANED_CAPTURES[@]}"}'*) : ;;
  *) fail "the EXIT trap does not unlink ORPHANED_CAPTURES — handed-over captures leak in \$TMPDIR (CodeAnt, PR #1640)" ;;
esac

echo "OK: session-start-sync.sh SessionStart migration tests passed"
