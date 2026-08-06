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
grep -q "register-hooks.py" "$SETUP_SCRIPT" \
  || fail "setup-skills-worktree.sh does not invoke register-hooks.py — hook registration may be broken"
# Full-mode must not pass --statusline-only: that flag skips hook registration entirely.
if grep "register-hooks.py" "$SETUP_SCRIPT" | grep -q "\-\-statusline-only"; then
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

echo "OK: session-start-sync.sh SessionStart migration tests passed"
