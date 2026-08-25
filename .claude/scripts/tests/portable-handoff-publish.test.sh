#!/usr/bin/env bash
# Tests for canonical /end handoff publication (issue #1311).

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

file_mode() {
  if [[ "$(uname -s)" == Darwin ]]; then stat -f %Lp "$1"; else stat -c %a "$1"; fi
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

Resume command: /end-resume
For another agent: run `cd -- '/tmp/portable'`, then `git status`.
Relaunch rule: inspect every recorded task outcome before replacing work.
EOF

OUT_DIR="$TMP/handoffs"
OUT1=$("$SUT" --input "$DOC" --repo test/portable --session session-1 \
  --out-dir "$OUT_DIR" --lint "$LINT" --lint-root "$REPO_ROOT")
check "first publish creates a readable canonical note" test -r "$OUT1"
check "canonical note is readable only by its owner" test "$(file_mode "$OUT1")" = 600
check "canonical filename matches recorder discovery" sh -c 'case "$1" in */portable-handoff-*.md) exit 0;; *) exit 1;; esac' _ "$OUT1"

sed 's/publisher is implemented/publisher is implemented and verified/' "$DOC" >"$TMP/handoff-updated.md"
OUT2=$("$SUT" --input "$TMP/handoff-updated.md" --repo test/portable --session session-1 \
  --out-dir "$OUT_DIR" --lint "$LINT" --lint-root "$REPO_ROOT")
check "same repository/session updates the same path" test "$OUT1" = "$OUT2"
check "only one canonical file exists" test "$(find "$OUT_DIR" -maxdepth 1 -type f -name 'portable-handoff-*.md' | wc -l | tr -d ' ')" = 1
check "updated bytes replaced the previous complete note" grep -q 'implemented and verified' "$OUT2"
OUT_CASE=$("$SUT" --input "$TMP/handoff-updated.md" --repo Test/Portable --session session-1 \
  --out-dir "$OUT_DIR" --lint "$LINT" --lint-root "$REPO_ROOT")
check "repository identity casing cannot split the canonical note" test "$OUT_CASE" = "$OUT1"

OUT3=$("$SUT" --input "$DOC" --repo test/portable --session session-2 \
  --out-dir "$OUT_DIR" --lint "$LINT" --lint-root "$REPO_ROOT")
check "a different session has a different canonical path" test "$OUT3" != "$OUT1"

# External validation must run before the canonical lock is acquired. Otherwise
# a slow/custom lint can outlive the stale-lock age and make valid concurrent
# publications fail.
UNLOCKED_LINT="$TMP/unlocked-lint.sh"
cat >"$UNLOCKED_LINT" <<'EOF'
#!/usr/bin/env bash
[[ ! -e "$EXPECTED_OUTPUT.lock" ]] || exit 88
exec "$REAL_LINT" "$@"
EOF
chmod +x "$UNLOCKED_LINT"
OBSERVED_OUT=$(EXPECTED_OUTPUT="$OUT3" REAL_LINT="$LINT" \
  "$SUT" --input "$DOC" --repo test/portable --session session-2 \
  --out-dir "$OUT_DIR" --lint "$UNLOCKED_LINT" --lint-root "$REPO_ROOT")
check "publisher does not hold the canonical lock while lint runs" test "$?" = 0
check "post-lint lock still publishes to the canonical path" test "$OBSERVED_OUT" = "$OUT3"

# The publisher must lint the immutable staged copy, not a mutable source path.
# This wrapper changes the source immediately after the delegated lint returns;
# the old lint-then-copy ordering would publish the replacement bytes.
MUTATING_LINT="$TMP/mutating-lint.sh"
cat >"$MUTATING_LINT" <<'EOF'
#!/usr/bin/env bash
"$REAL_LINT" "$@"
rc=$?
(( rc == 0 )) || exit "$rc"
printf '# replaced after lint\n' >"$ORIGINAL_INPUT"
EOF
chmod +x "$MUTATING_LINT"
MUTABLE_INPUT="$TMP/mutable-input.md"
cp "$DOC" "$MUTABLE_INPUT"
RACE_OUT=$(REAL_LINT="$LINT" ORIGINAL_INPUT="$MUTABLE_INPUT" \
  "$SUT" --input "$MUTABLE_INPUT" --repo test/portable --session mutable-source \
  --out-dir "$OUT_DIR" --lint "$MUTATING_LINT" --lint-root "$REPO_ROOT")
check "publisher validates and publishes the same staged bytes" cmp -s "$DOC" "$RACE_OUT"
check "source mutation happened during the lint window" grep -q 'replaced after lint' "$MUTABLE_INPUT"

printf '# invalid\n' >"$TMP/invalid.md"
"$SUT" --input "$TMP/invalid.md" --repo test/portable --session invalid \
  --out-dir "$OUT_DIR" --lint "$LINT" --lint-root "$REPO_ROOT" >/dev/null 2>&1
check "lint violations fail closed" test "$?" = 1
check "lint failure publishes no invalid note" test "$(find "$OUT_DIR" -maxdepth 1 -type f -name 'portable-handoff-*.md' | wc -l | tr -d ' ')" = 3

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
