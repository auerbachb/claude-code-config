#!/usr/bin/env bash
# Tests for canonical /stop handoff publication (issue #1311).

set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
SUT="$REPO_ROOT/.claude/scripts/portable-handoff-publish.sh"
LINT="$REPO_ROOT/.claude/scripts/portable-handoff-lint.sh"
LOCK="$REPO_ROOT/.claude/scripts/state-lock.sh"
TMP=$(mktemp -d)
trap 'chmod -R u+rwX "$TMP" 2>/dev/null; rm -rf "$TMP"' EXIT

passed=0
failed=0
check() {
  local name="$1"; shift
  if "$@"; then echo "ok   — $name"; passed=$((passed + 1));
  else echo "FAIL — $name"; failed=$((failed + 1)); fi
}

DOC="$TMP/handoff.md"
cat >"$DOC" <<'EOF'
# Session handoff — test/portable — 2026-08-24 12:00 ET

## Start here

Enter the recorded working directory and run `git status`.

## What we're working on

Testing canonical handoff publication.

## Open work

Nothing is in flight.

## Progress and verification

Completed: the publisher is implemented.
Remaining: run its test suite.
Blockers and decisions needed: none.
Tests: run the publisher test.
Review: not applicable — no pull request.
Next commands: run the publisher test.

## Decisions made this session

One canonical file replaces timestamped manual duplicates.

## Local state on this machine

Repository identity: test/portable
Repository root: /tmp/portable
Working directory: /tmp/portable
Worktree condition: main worktree
Branch: main
Base branch: main
HEAD commit: 0123456789abcdef0123456789abcdef01234567
Tracked changes: none
Untracked changes: none
Unpushed commits: none

## Resume safely

Resume command: /stop-resume
For another agent: run `cd -- '/tmp/portable'`, then `git status`.
Relaunch rule: inspect every recorded task outcome before replacing work.
EOF

OUT_DIR="$TMP/handoffs"
OUT1=$("$SUT" --input "$DOC" --repo test/portable --session session-1 \
  --out-dir "$OUT_DIR" --lint "$LINT" --lint-root "$REPO_ROOT")
check "first publish creates a readable canonical note" test -r "$OUT1"
check "canonical filename matches recorder discovery" sh -c 'case "$1" in */portable-handoff-*.md) exit 0;; *) exit 1;; esac' _ "$OUT1"

sed 's/publisher is implemented/publisher is implemented and verified/' "$DOC" >"$TMP/handoff-updated.md"
OUT2=$("$SUT" --input "$TMP/handoff-updated.md" --repo test/portable --session session-1 \
  --out-dir "$OUT_DIR" --lint "$LINT" --lint-root "$REPO_ROOT")
check "same repository/session updates the same path" test "$OUT1" = "$OUT2"
check "only one canonical file exists" test "$(find "$OUT_DIR" -maxdepth 1 -type f -name 'portable-handoff-*.md' | wc -l | tr -d ' ')" = 1
check "updated bytes replaced the previous complete note" grep -q 'implemented and verified' "$OUT2"

OUT3=$("$SUT" --input "$DOC" --repo test/portable --session session-2 \
  --out-dir "$OUT_DIR" --lint "$LINT" --lint-root "$REPO_ROOT")
check "a different session has a different canonical path" test "$OUT3" != "$OUT1"

printf '# invalid\n' >"$TMP/invalid.md"
"$SUT" --input "$TMP/invalid.md" --repo test/portable --session invalid \
  --out-dir "$OUT_DIR" --lint "$LINT" --lint-root "$REPO_ROOT" >/dev/null 2>&1
check "lint violations fail closed" test "$?" = 1
check "lint failure publishes no invalid note" test "$(find "$OUT_DIR" -maxdepth 1 -type f -name 'portable-handoff-*.md' | wc -l | tr -d ' ')" = 2

"$SUT" --input "$TMP/missing.md" --repo test/portable --session missing \
  --out-dir "$OUT_DIR" --lint "$LINT" --lint-root "$REPO_ROOT" >/dev/null 2>&1
check "missing input is distinguished" test "$?" = 3

printf 'not a directory\n' >"$TMP/not-a-directory"
"$SUT" --input "$DOC" --repo test/portable --session write-fail \
  --out-dir "$TMP/not-a-directory" --lint "$LINT" --lint-root "$REPO_ROOT" >/dev/null 2>&1
check "write failure is reported" test "$?" = 5

READY="$TMP/lock-ready"
( source "$LOCK"
  state_lock_acquire "$OUT1" || exit $?
  trap 'state_lock_release' EXIT
  : >"$READY"
  sleep 3
) &
holder=$!
for _ in 1 2 3 4 5 6 7 8 9 10; do [[ -f "$READY" ]] && break; sleep 0.1; done
if [[ ! -f "$READY" ]]; then
  kill "$holder" 2>/dev/null || true
  wait "$holder" 2>/dev/null || true
  echo "FAIL — lock holder did not become ready within the bounded wait"
  exit 1
fi
CLAUDE_STATE_LOCK_TIMEOUT=1 "$SUT" --input "$DOC" --repo test/portable --session session-1 \
  --out-dir "$OUT_DIR" --lint "$LINT" --lint-root "$REPO_ROOT" >/dev/null 2>&1
lock_rc=$?
wait "$holder"
check "lock contention is bounded and fails closed" test "$lock_rc" = 6
check "lock failure leaves the previous note intact" grep -q 'implemented and verified' "$OUT1"

printf '\npassed: %d   failed: %d\n' "$passed" "$failed"
(( failed == 0 ))
