#!/usr/bin/env bash
# Runtime regression for the script-usage.log telemetry guard (issue #1406).
# catalog: tests — Runtime regression that converted telemetry writes stay silent without `~/.claude` and still log with it (issue #1406)
#
# Proves, against real converted scripts, that:
#   (a/b) with HOME pointing at a directory WITHOUT .claude/, a converted
#         script emits NOTHING on stderr and keeps its normal exit status —
#         the redirection-order leak ("No such file or directory" from the
#         failed >> open) stays fixed;
#   (c)   with $HOME/.claude/ present, the usage log still gains a line —
#         the fix must not silently disable telemetry.
#
# Representatives cover both source layouts:
#   - ac-gate.sh    — single-line telemetry write
#   - repo-root.sh  — continuation-line telemetry write
# Both have offline, argument-safe invocations (--help / no-arg resolve).
#
# HOME is sandboxed to a mktemp tree throughout (silence-watchdog.test.sh
# pattern), so the real ~/.claude is never touched.
#
# Auto-discovered by run-hook-tests.sh — no workflow edit needed.

set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
TMP_DIR=$(mktemp -d -t usage-log-redirect.XXXXXX)
trap 'rm -rf "$TMP_DIR"' EXIT

failures=0
fail() { echo "FAIL: $*"; failures=$((failures + 1)); }

SANDBOX="${TMP_DIR}/home"
mkdir -p "$SANDBOX"   # note: deliberately NO .claude/ inside yet

# ---------------------------------------------------------------------------
# (a) single-line site, HOME without .claude/: silent stderr, normal exit,
#     and no stray log materializes.
# ---------------------------------------------------------------------------
RC=0
ERR="$(cd "$REPO_ROOT" && HOME="$SANDBOX" bash .claude/scripts/ac-gate.sh --help 2>&1 >/dev/null)" || RC=$?
[[ "$RC" -eq 0 ]] || fail "(a) ac-gate.sh --help without ~/.claude exited rc=$RC (expected 0)"
[[ -z "$ERR" ]] || fail "(a) ac-gate.sh --help leaked stderr without ~/.claude: $ERR"
[[ ! -e "$SANDBOX/.claude/script-usage.log" ]] || fail "(a) log file materialized without .claude/ present"

# ---------------------------------------------------------------------------
# (b) continuation-line site, HOME without .claude/: same contract.
# ---------------------------------------------------------------------------
RC=0
ERR="$(cd "$REPO_ROOT" && HOME="$SANDBOX" bash .claude/scripts/repo-root.sh 2>&1 >/dev/null)" || RC=$?
[[ "$RC" -eq 0 ]] || fail "(b) repo-root.sh without ~/.claude exited rc=$RC (expected 0)"
[[ -z "$ERR" ]] || fail "(b) repo-root.sh leaked stderr without ~/.claude: $ERR"

# ---------------------------------------------------------------------------
# (c) positive control: with $HOME/.claude/ present the telemetry line IS
#     written (one per script), and stderr stays empty.
# ---------------------------------------------------------------------------
mkdir -p "$SANDBOX/.claude"

RC=0
ERR="$(cd "$REPO_ROOT" && HOME="$SANDBOX" bash .claude/scripts/ac-gate.sh --help 2>&1 >/dev/null)" || RC=$?
[[ "$RC" -eq 0 && -z "$ERR" ]] || fail "(c) ac-gate.sh --help with ~/.claude: rc=$RC stderr: $ERR"

RC=0
ERR="$(cd "$REPO_ROOT" && HOME="$SANDBOX" bash .claude/scripts/repo-root.sh 2>&1 >/dev/null)" || RC=$?
[[ "$RC" -eq 0 && -z "$ERR" ]] || fail "(c) repo-root.sh with ~/.claude: rc=$RC stderr: $ERR"

LOG="$SANDBOX/.claude/script-usage.log"
if [[ ! -f "$LOG" ]]; then
  fail "(c) $LOG was not written — telemetry silently disabled"
else
  grep -q 'ac-gate.sh' "$LOG"   || fail "(c) log has no ac-gate.sh line (telemetry regressed for single-line sites)"
  grep -q 'repo-root.sh' "$LOG" || fail "(c) log has no repo-root.sh line (telemetry regressed for continuation sites)"
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
if (( failures > 0 )); then
  echo "script-usage-log-redirect.test: ${failures} check(s) FAILED"
  exit 1
fi
echo "script-usage-log-redirect.test: all checks passed"
