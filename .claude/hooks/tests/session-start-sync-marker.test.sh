#!/usr/bin/env bash
# Restart-marker lifecycle and lock eligibility for session-start-sync.
set -euo pipefail
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/session-start-sync-fixtures.sh
source "$TEST_DIR/lib/session-start-sync-fixtures.sh"

# --- 11. Functional: marker surfaced on resume, cleared only on startup ---
# A skills-worktree shaped just enough to skip the bootstrap branch keeps this
# fast: the fetch fails, the hook records that as an error, and the marker path
# — the part under test — still runs.
MARKER_HOME="$(mktemp -d)"
ssync_register_tmp "$MARKER_HOME"
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
#
# Contention is driven through the LOCK, never through the clock (issues #1567,
# #1751). The hook reads state-lock.sh's STATE_LOCK_WAITED, which is exact, so
# this leg deliberately makes its UNCONTENDED acquire slow: a mkdir shim holds
# the hook's first lock attempt for 1.1s before letting it succeed. An acquire
# lasting over a second always straddles a whole-second boundary, which the old
# whole-second `date` heuristic read as contended — keeping the marker on a
# startup that had loaded everything. That was this case's intermittent macOS CI
# failure, now reproduced on every run instead of only on a slow runner. The
# 1.1s is a floor on the acquire's duration, not a race: nothing here depends on
# when anything else happens. 11c below is the negative control.

# A skills worktree the hook's fetch and reset succeed against, plus a marker
# carrying both portions. Usage: build_ok_home <home>
build_ok_home() {
  local home="$1" origin="$1/origin"
  mkdir -p "$origin/.claude/skills/alpha" "$home/.claude/logs"
  printf '# alpha\n' > "$origin/.claude/skills/alpha/SKILL.md"
  printf '# CLAUDE\n' > "$origin/CLAUDE.md"
  git init -q "$origin" >/dev/null 2>&1
  git -C "$origin" symbolic-ref HEAD refs/heads/main >/dev/null 2>&1
  git -C "$origin" add -A >/dev/null 2>&1
  git -C "$origin" -c user.email=t@e.invalid -c user.name=T -c commit.gpgsign=false \
    commit -q -m "seed" >/dev/null 2>&1
  # A real git WORKTREE, not a clone: the hook's bootstrap branch tests for a
  # `.git` FILE, which is what a worktree has and a clone does not — a clone would
  # send this fixture down the setup path and error, defeating the point. Detached
  # so it does not contend for `main`, which the intermediate clone has checked
  # out; the worktree inherits that clone's `origin`, so fetch and reset resolve.
  git clone -q "$origin" "$home/repo" >/dev/null 2>&1
  git -C "$home/repo" worktree add -q --detach "$home/.claude/skills-worktree" main >/dev/null 2>&1
  cat > "$home/.claude/sync-restart-recommended.json" <<'JSON'
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
}

# 0 when the hook's additionalContext contains <needle>; 1 when it does not, or
# when there is no parseable output at all. Usage: ctx_has <hook-output> <needle>
ctx_has() {
  HOOK_CTX_OUT="$1" HOOK_CTX_NEEDLE="$2" python3 - <<'PY'
import json, os, sys
text = os.environ.get("HOOK_CTX_OUT", "").strip()
try:
    ctx = json.loads(text)["hookSpecificOutput"]["additionalContext"]
except Exception:
    sys.exit(1)
sys.exit(0 if os.environ["HOOK_CTX_NEEDLE"] in ctx else 1)
PY
}

# Prints "restart=<present|absent> failure=<present|absent>", or "missing" /
# "unreadable". Usage: marker_state <marker-file>
marker_state() {
  python3 - "$1" <<'PY'
import json, os, sys
path = sys.argv[1]
if not os.path.exists(path):
    print("missing")
    sys.exit(0)
try:
    with open(path) as f:
        d = json.load(f)
except Exception:
    print("unreadable")
    sys.exit(0)
def state(key):
    return "present" if d.get(key) is not None else "absent"
print("restart=%s failure=%s" % (state("restart_recommended"), state("sync_failure")))
PY
}

# Bounded poll for a hand-off sentinel. The bound only stops a broken run from
# hanging the suite; no assertion depends on how long anything takes.
wait_for() {
  local path="$1" tries=400
  while (( tries-- > 0 )); do [ -e "$path" ] && return 0; sleep 0.05; done
  return 1
}

OK_HOME="$(mktemp -d)"
ssync_register_tmp "$OK_HOME"
LOCK_SHIM_BIN="$(mktemp -d)"
ssync_register_tmp "$LOCK_SHIM_BIN"
build_ok_home "$OK_HOME"

# The shim is transparent for every call except a bare `mkdir <SHIM_LOCK_DIR>` —
# state-lock.sh's own acquire attempt on the config-sync lock:
#   SHIM_SLOW_ONCE=<file>  the FIRST such attempt creates <file>, sleeps 1.1s,
#                          then runs (11b: a slow, uncontended acquire).
#   SHIM_LOST_FILE=<file>  touched whenever such an attempt FAILS — the lock was
#                          held — so a holder knows it may now let go (11c).
# The real mkdir comes from SHIM_REAL_MKDIR, resolved below before PATH changes.
REAL_MKDIR="$(command -v mkdir)"
cat > "$LOCK_SHIM_BIN/mkdir" <<'SHIM'
#!/bin/sh
if [ "$#" -eq 1 ] && [ -n "${SHIM_LOCK_DIR:-}" ] && [ "$1" = "$SHIM_LOCK_DIR" ]; then
  if [ -n "${SHIM_SLOW_ONCE:-}" ] && [ ! -e "$SHIM_SLOW_ONCE" ]; then
    : > "$SHIM_SLOW_ONCE"
    sleep 1.1
  fi
  "$SHIM_REAL_MKDIR" "$1" && exit 0
  rc=$?
  if [ -n "${SHIM_LOST_FILE:-}" ]; then : > "$SHIM_LOST_FILE"; fi
  exit "$rc"
fi
exec "$SHIM_REAL_MKDIR" "$@"
SHIM
chmod +x "$LOCK_SHIM_BIN/mkdir"

ok_out=$(printf '{"source":"startup"}' \
  | HOME="$OK_HOME" PATH="$LOCK_SHIM_BIN:$PATH" SHIM_REAL_MKDIR="$REAL_MKDIR" \
    SHIM_LOCK_DIR="$OK_HOME/.claude/logs/claude-config-sync-state.json.lock" \
    SHIM_SLOW_ONCE="$OK_HOME/slow-acquire-ran" bash "$HOOK" 2>/dev/null || true)
# Assert the premises before the conclusion. Without the shim's sentinel, the
# slow acquire never happened and the boundary claim went untested; with a sync
# error, the check below would pass for the wrong reason — by never reaching the
# clear at all.
[ -e "$OK_HOME/slow-acquire-ran" ] \
  || fail "(11b premise) the mkdir shim never intercepted the hook's lock acquire, so the slow uncontended acquire was not exercised"
if ctx_has "$ok_out" "Config sync encountered errors"; then
  fail "the success fixture still reported a sync error, so the clear path was not exercised; got: $ok_out"
fi
[ "$(marker_state "$OK_HOME/.claude/sync-restart-recommended.json")" = "restart=absent failure=present" ] \
  || fail "a startup whose sync succeeded did not clear the restart portion, or wrongly cleared the failure portion — a slow but UNCONTENDED acquire must not read as contended (issue #1751)"

# --- 11c. Negative control for 11b: the same success under REAL contention keeps the marker ---
# Without this, 11b would pass against a hook that clears on every successful
# startup. A live holder takes the config-sync lock through state-lock.sh itself
# and lets go only on an explicit hand-off: once the hook has demonstrably LOST
# an acquire attempt to it. The hook then acquires after waiting, runs the
# region successfully — so the skip and error guards both pass — and only the
# contention guard stands between it and a clear for definitions a concurrent
# sync may have changed under it. No sleeps decide anything.
C_HOME="$(mktemp -d)"
ssync_register_tmp "$C_HOME"
build_ok_home "$C_HOME"
C_HAND="$C_HOME/handoff"
mkdir -p "$C_HAND"
C_BASE="$C_HOME/.claude/logs/claude-config-sync-state.json"
bash -c 'source "$1"; state_lock_acquire "$2" 5 || exit 6; : > "$3/held"
         while [ ! -e "$3/release" ]; do sleep 0.05; done
         state_lock_release' _ "$REPO_ROOT/.claude/scripts/state-lock.sh" "$C_BASE" "$C_HAND" &
c_holder=$!
if ! wait_for "$C_HAND/held"; then
  : > "$C_HAND/release"
  fail "(11c setup) the holder never took the config-sync lock"
fi
# A generous lock timeout: the hand-off completes in milliseconds, and the bound
# only matters if it breaks.
( printf '{"source":"startup"}' \
    | HOME="$C_HOME" PATH="$LOCK_SHIM_BIN:$PATH" SHIM_REAL_MKDIR="$REAL_MKDIR" \
      SHIM_LOCK_DIR="$C_BASE.lock" SHIM_LOST_FILE="$C_HAND/lost" \
      CLAUDE_CONFIG_SYNC_HOOK_LOCK_TIMEOUT=20 bash "$HOOK" > "$C_HAND/out" 2>/dev/null || true ) &
c_hook=$!
c_lost=0
wait_for "$C_HAND/lost" || c_lost=1
: > "$C_HAND/release"   # unconditional, so a failed hand-off can never wedge the holder
wait "$c_hook" 2>/dev/null || true
wait "$c_holder" 2>/dev/null || true
c_out="$(cat "$C_HAND/out" 2>/dev/null || true)"
[ "$c_lost" -eq 0 ] \
  || fail "(11c premise) the hook never lost an acquire attempt to the live holder, so no contention was exercised"
if ctx_has "$c_out" "holds the lock" || ctx_has "$c_out" "state-lock.sh not found"; then
  fail "(11c premise) the hook took the lock-skip path; it must acquire after waiting; got: $c_out"
fi
if ctx_has "$c_out" "Config sync encountered errors"; then
  fail "(11c premise) the success fixture reported a sync error, so the error guard — not contention — kept the marker; got: $c_out"
fi
[ "$(marker_state "$C_HOME/.claude/sync-restart-recommended.json")" = "restart=present failure=present" ] \
  || fail "a startup that waited out a live holder cleared the restart marker — the session may be on stale definitions with no signal"

# --- 12. A startup that SKIPPED the sync region must not clear the marker ---
# At login, launchd's RunAtLoad tick and a new session overlap. If the hook
# loses the config-sync lock it skips the worktree and symlink refresh — so this
# session is running the OLD definitions — and must not then delete the restart
# marker the scheduled job just wrote. Doing so left the user on stale agents,
# rules and skills with neither the context notice nor the statusline badge.
SKIP_HOME="$(mktemp -d)"
ssync_register_tmp "$SKIP_HOME"
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

# --- 13. A startup that had to BREAK a stale lock must not clear the marker ---
# The skip guard in case 12 is not sufficient on its own: a hook that acquires
# the lock only after losing its first attempt HAS run the sync region, so that
# guard passes — yet another holder was in the lock around this startup. 11c
# covers a live holder the hook waited out; this covers the other way an acquire
# loses its first attempt — a stale lock left by a holder that died, possibly
# mid-sync after changing the tree. state-lock.sh reports a stale recovery as
# STATE_LOCK_WAITED=1 on purpose (its header), so the marker stays.
#
# Deterministic: the planted lock is far older than state-lock.sh's staleness
# age, so the library breaks it on positive evidence and nothing is timed. Its
# pid is this live test process on purpose — a pid that has merely exited could
# be reused by an unrelated process before the hook looks, making the lock read
# as live and the run time out. The fixture is
# the SUCCESS one — on a failing fetch the error guard would keep the marker
# for the wrong reason, which is how this case used to pass vacuously. `at` is
# deliberately old: the guard under test is contention, not the timestamp.
FRESH_HOME="$(mktemp -d)"
ssync_register_tmp "$FRESH_HOME"
build_ok_home "$FRESH_HOME"
FRESH_LOCK="$FRESH_HOME/.claude/logs/claude-config-sync-state.json.lock"
mkdir -p "$FRESH_LOCK"
{ printf 'pid=%s\n' "$$"
  printf 'host=%s\n' "${HOSTNAME:-$(hostname)}"
  printf 'epoch=%s\n' "$(( $(date +%s) - 9999 ))"
  printf 'started=%s\n' "2026-01-01T00:00:00Z"
  printf 'cmd=%s\n' "crashed-scheduled-sync"
  printf 'token=%s\n' "test-stale-token"
} > "$FRESH_LOCK/owner"

fresh_out=$(printf '{"source":"startup"}' | HOME="$FRESH_HOME" bash "$HOOK" 2>/dev/null || true)

# Controls: the run must have broken the planted lock and run the region
# cleanly. A skip or a sync error would keep the marker for the wrong reason.
if ctx_has "$fresh_out" "holds the lock" || ctx_has "$fresh_out" "state-lock.sh not found"; then
  fail "case 13 took the lock-skip path; it must break the stale lock and acquire; got: $fresh_out"
fi
if ctx_has "$fresh_out" "Config sync encountered errors"; then
  fail "(case 13 premise) the success fixture reported a sync error, so the error guard — not contention — kept the marker; got: $fresh_out"
fi
if grep -qF 'token=test-stale-token' "$FRESH_LOCK/owner" 2>/dev/null; then
  fail "(case 13 premise) the planted stale lock is still in place — the hook never broke it"
fi
[ "$(marker_state "$FRESH_HOME/.claude/sync-restart-recommended.json")" = "restart=present failure=present" ] \
  || fail "a startup that broke a stale lock cleared the marker — a holder that died mid-sync may have changed definitions this session never loaded"

# --- 13b. root-repo helper is resolved above the lock branch (BugBot High, PR #1553) ---
# The root-repo sync runs on the lock-skip path too; a helper assigned only
# inside the locked region is unset there, producing a false "root repo could
# not be resolved" error and a skipped main pull on every login overlap.
helper_line="$(grep -n '^_repo_root_helper=' "$HOOK" | head -1 | cut -d: -f1)"
# The first non-comment acquire of the config-sync lock is the sync region's.
lock_line="$(grep -nE '^[^#]*state_lock_acquire "\$_sync_lock_base"' "$HOOK" | head -1 | cut -d: -f1)"
[ -n "$helper_line" ] && [ -n "$lock_line" ] \
  || fail "could not locate the repo-root helper assignment / lock acquire in the hook"
[ "$helper_line" -lt "$lock_line" ] \
  || fail "_repo_root_helper is assigned after the lock branch — unset on the lock-skip path, so a contended login falsely fails the root-repo sync"

echo "OK: session-start-sync marker and lock tests passed"
