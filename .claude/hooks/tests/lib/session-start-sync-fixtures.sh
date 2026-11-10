#!/usr/bin/env bash
# Source-only shared setup for the session-start-sync test family.
# Consumers register only freshly allocated private fixture directories here.
# This fixture owns EXIT cleanup; suites keep their process release/waits local.
REPO_ROOT="$(git rev-parse --show-toplevel)"
HOOK="$REPO_ROOT/.claude/hooks/session-start-sync.sh"
SETTINGS="$REPO_ROOT/global-settings.json"
SETUP_SCRIPT="$REPO_ROOT/setup-skills-worktree.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }

# --- Timing knobs for the bounded-run legs below (issue #1698) -------------
#
# Read the test-side knob FIRST, then drop the hook-side one from the
# environment. The two are deliberately different variables:
#
#   CLAUDE_CONFIG_SYNC_TEST_AMPLE_BUDGET_SECS — set by CI (the macOS lane), read
#     here, and applied to the ample-budget CONTROL only.
#   CLAUDE_CONFIG_SYNC_HOOK_TIMEOUT_SECS — the hook's own deadline. Unset here so
#     an exported value cannot silently widen the STALL leg, whose whole value is
#     that its bound stays tight enough to fail when the hook really stalls.
#   CLAUDE_CONFIG_SYNC_HOOK_TIMEOUT_RAISE_OK — the hook refuses to widen its
#     deadline past the registered timeout without this (CodeAnt, PR #1709).
#     Unset here for the same reason as the line above, and set explicitly on the
#     one invocation that legitimately widens.
#
# Each leg that wants a deadline passes it explicitly on the invocation line.
AMPLE_BUDGET_SECS="${CLAUDE_CONFIG_SYNC_TEST_AMPLE_BUDGET_SECS:-60}"
# Default 60 — double the production 30, which is headroom for a slow runner
# without being so large that a genuinely hung publisher would hold the suite.
case "$AMPLE_BUDGET_SECS" in ''|*[!0-9]*) AMPLE_BUDGET_SECS=60 ;; esac
[ "$AMPLE_BUDGET_SECS" -gt 0 ] 2>/dev/null || AMPLE_BUDGET_SECS=60
# Deliberately NO floor above the default: setting this small is how the
# vacuous-pass case is reproduced by hand, and a too-small value fails the
# control LOUDLY rather than passing it vacuously — the safe direction.
unset CLAUDE_CONFIG_SYNC_HOOK_TIMEOUT_SECS
unset CLAUDE_CONFIG_SYNC_HOOK_TIMEOUT_RAISE_OK

SSYNC_TMP_DIRS=()
ssync_register_tmp() { SSYNC_TMP_DIRS+=("$1"); }
ssync_cleanup() {
  local result=$? dir
  for dir in ${SSYNC_TMP_DIRS[@]+"${SSYNC_TMP_DIRS[@]}"}; do
    rm -rf -- "$dir"
  done
  return "$result"
}
trap ssync_cleanup EXIT
