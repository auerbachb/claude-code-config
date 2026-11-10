#!/usr/bin/env bash
# Registration, migration wiring and capture structure for session-start-sync.
set -euo pipefail
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/session-start-sync-fixtures.sh
source "$TEST_DIR/lib/session-start-sync-fixtures.sh"

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
if grep -q -- "--statusline-only" <<<"$(grep -E 'python3[[:space:]]+"?\$(\{)?REGISTER_HOOKS_PY' "$SETUP_SCRIPT")"; then
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
ssync_register_tmp "$TMP_HOME"

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

# Contention comes from the lock itself (issue #1567). state_lock_acquire
# reports whether it waited in STATE_LOCK_WAITED; the hook must read that, and
# read it fail-closed — anything but an explicit 0 is contended — rather than
# infer contention from outside. Cases 11b, 11c and 13 prove the behaviour; these
# pin the wiring.
grep -qF '[[ "${STATE_LOCK_WAITED:-}" == 0 ]] || _lock_contended=1' "$HOOK" \
  || fail "session-start-sync.sh does not derive _lock_contended from state-lock.sh's STATE_LOCK_WAITED (fail-closed: anything but 0 is contended)"
# The outside guesses it replaced (PR #1553) must not creep back. The whole-
# second `date` stamps are the harmful one — a slow uncontended acquire crossing
# a second boundary read as contended (issue #1751) — and case 11b fails on them
# functionally; these catch the names too.
for _gone in '_lock_t0' '_lock_t1' '_lock_contended_pre' '_lock_probe_waited'; do
  if grep -qE "^[^#]*${_gone}" "$HOOK"; then
    fail "session-start-sync.sh still carries the ${_gone} contention heuristic — read STATE_LOCK_WAITED instead (issues #1567, #1751)"
  fi
done

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

# --- 17. A failed handover allocation must decline, not silently no-op --------
# bounded-run.sh's rotation calls mktemp twice and checks neither, so a full or
# read-only $TMPDIR leaves CAPTURE/CAPTURE_ERR empty. The NEXT bounded call's
# `: > "$CAPTURE"` redirection would then fail and its command would never run
# — silently, with nothing recorded, which is the exact failure this whole
# change exists to prevent (CodeAnt, PR #1640). Opting into the handover is
# what creates that path, so the caller must detect it.
bounded_body="$(awk '/^_run_hook_bounded\(\) \{/,/^\}$/' "$HOOK")"
[ -n "$bounded_body" ] || fail "could not extract the _run_hook_bounded body from session-start-sync.sh"
case "$bounded_body" in
  *'-z "${CAPTURE:-}"'*) : ;;
  *) fail "_run_hook_bounded does not check that the capture pair survived the orphan handover — a failed mktemp there makes every later bounded call a silent no-op (CodeAnt, PR #1640)" ;;
esac
case "$bounded_body" in
  *_bound_available=0*) : ;;
  *) fail "a failed handover allocation does not disable bounding, so later calls would run with an empty \$CAPTURE instead of declining (CodeAnt, PR #1640)" ;;
esac
grep -q '_bound_unavailable_reason' "$HOOK" \
  || fail "the decline message is hard-coded to \"bounded-run.sh unavailable\", so a handover-allocation decline would be reported as a missing library (CodeAnt, PR #1640)"

echo "OK: session-start-sync.sh SessionStart migration tests passed"
