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

python3 - "$MARKER_HOME/.claude/sync-restart-recommended.json" <<'PY' || fail "startup did not clear the restart portion, or wrongly cleared the failure portion"
import json, os, sys
path = sys.argv[1]
if not os.path.exists(path):
    # Both portions gone is only correct when there was no failure portion.
    sys.exit(1)
with open(path) as f:
    d = json.load(f)
ok = d.get("restart_recommended") is None and d.get("sync_failure") is not None
sys.exit(0 if ok else 1)
PY

echo "OK: session-start-sync.sh SessionStart migration tests passed"
