#!/usr/bin/env bash
# Sibling-sweep regressions for the empty-array-under-`set -u` abort (issue #1371).
#
# Expanding a bare "${ARR[@]}" when ARR is EMPTY aborts under `set -u` on macOS
# bash 3.2 (and bash 4.0-4.3). estimate-resolve.sh's own coverage lives in
# estimate-resolve.test.sh; this suite pins the two siblings fixed in the same
# sweep, both of which failed SILENTLY rather than loudly:
#
#   overrun-check.sh          — no --repo => REPO_ARGS empty; the abort was
#                               swallowed and the script exited 0 ("no breach")
#                               instead of emitting the first-breach alert.
#   verify-exit-report-block.sh — a header-only block yields no field lines, so
#                               lines[] is empty; the validator crashed instead
#                               of reporting the missing required fields.
#
# Each case carries a NEGATIVE CONTROL against a vacuous pass, in two halves:
#
#   * A structural check that the production script still carries the guarded
#     idiom. This holds on EVERY bash, and on modern bash it is the only thing
#     standing between a revert and macOS breakage.
#   * A behavioral check that the rebuilt pre-fix form still aborts — run ONLY
#     where the abort is reproducible. bash >= 4.4 tolerates expanding an empty
#     array under `set -u`, so on CI's modern bash the pre-fix form runs clean
#     and the complementary assertion is made instead.
#
# Run from repo root: bash .claude/scripts/tests/empty-array-expansion.test.sh
set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
OVERRUN="$REPO_ROOT/.claude/scripts/overrun-check.sh"
VERIFY="$REPO_ROOT/.claude/scripts/verify-exit-report-block.sh"

# Does the `bash` that runs the child scripts abort when an EMPTY array is
# expanded under `set -u`? bash < 4.4 (macOS ships 3.2) aborts; bash >= 4.4
# tolerates it. Probe the BEHAVIOR rather than parsing a version string: the
# child `bash` resolved from PATH need not be the one running this suite, and a
# behavioral probe cannot drift from the thing it gates.
if bash -c 'set -u; a=(); : "${a[@]}"' >/dev/null 2>&1; then  # empty-array-ok: the bare expansion IS the probe — this line deliberately triggers the abort it is measuring
  EMPTY_EXPANSION_ABORTS=0
else
  EMPTY_EXPANSION_ABORTS=1
fi
# overrun-check.sh resolves session-state.sh from a relative candidate path, so
# run from the repo root regardless of the caller's cwd. Without it the helper
# would go unresolved and overrun-check.sh would exit 0 before ever reaching the
# expansion under test.
cd "$REPO_ROOT" || { echo "cannot cd to repo root" >&2; exit 1; }

TMP="$(mktemp -d)"
TMP_HOME="$(mktemp -d)"
cleanup() { rm -rf "$TMP" "$TMP_HOME"; }
trap cleanup EXIT
export HOME="$TMP_HOME"
mkdir -p "$HOME/.claude"
# Give overrun-check.sh a deterministic repo key WITHOUT passing --repo, so
# REPO_ARGS stays empty while the state-read path is still reached. Without
# this, a checkout lacking an 'origin' remote would exit early and the case
# would pass without executing the expansion under test.
export CLAUDE_SESSION_REPO="auerbachb/claude-code-config"

PASS=0
FAIL=0
check_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [[ "$actual" == "$expected" ]]; then
    PASS=$((PASS + 1)); echo "ok   — $desc"
  else
    FAIL=$((FAIL + 1)); echo "FAIL — $desc (expected '$expected', got '$actual')"
  fi
}
check_contains() {
  local desc="$1" needle="$2" haystack="$3"
  if [[ "$haystack" == *"$needle"* ]]; then
    PASS=$((PASS + 1)); echo "ok   — $desc"
  else
    FAIL=$((FAIL + 1)); echo "FAIL — $desc (output does not contain '$needle')"
  fi
}
check_not_contains() {
  local desc="$1" needle="$2" haystack="$3"
  if [[ "$haystack" != *"$needle"* ]]; then
    PASS=$((PASS + 1)); echo "ok   — $desc"
  else
    FAIL=$((FAIL + 1)); echo "FAIL — $desc (output unexpectedly contains '$needle')"
  fi
}

run_capture() {  # run_capture <command...> — stdout in OUT, stderr in ERR, rc in RC
  OUT="$("$@" 2>"$TMP/stderr")"
  RC=$?
  ERR="$(cat "$TMP/stderr")"
}

# =============================================================================
# 1. overrun-check.sh — no --repo, so REPO_ARGS is empty.
# =============================================================================
run_capture bash "$OVERRUN" --pr 99999 --bound-min 30 \
  --started-at 2026-08-26T00:00:00Z --now 2026-08-26T12:00:00Z || true
check_not_contains "overrun-check: no abort without --repo" "unbound variable" "$ERR"
check_eq "overrun-check: first breach exits 1" "1" "$RC"
check_contains "overrun-check: emits the breach alert" "PR #99999 overrun" "$OUT"

# Second call for the same PR must be suppressed — proves the marker WRITE at
# the second expansion site landed too, not just the read.
run_capture bash "$OVERRUN" --pr 99999 --bound-min 30 \
  --started-at 2026-08-26T00:00:00Z --now 2026-08-26T12:00:00Z || true
check_not_contains "overrun-check: no abort on the marker path" "unbound variable" "$ERR"
check_eq "overrun-check: repeat breach is suppressed (exit 2)" "2" "$RC"
check_eq "overrun-check: suppressed call prints nothing" "" "$OUT"

# ---- NEGATIVE CONTROL -------------------------------------------------------
# Half one, portable: the production script must still carry the guarded idiom.
if grep -qF '${REPO_ARGS[@]+"${REPO_ARGS[@]}"}' "$OVERRUN"; then
  PASS=$((PASS + 1)); echo "ok   — overrun-check: production script still carries the guarded idiom"
else
  FAIL=$((FAIL + 1)); echo "FAIL — overrun-check: production script no longer carries the guarded idiom"
fi

# Half two: rebuild the pre-fix expansion and assert it STILL aborts, where that
# abort is reproducible at all.
OVERRUN_PREFIX="$TMP/overrun-check-prefix.sh"
sed 's/\${REPO_ARGS\[@\]+"\${REPO_ARGS\[@\]}"}/"${REPO_ARGS[@]}"/g' "$OVERRUN" > "$OVERRUN_PREFIX"
if grep -q '"\${REPO_ARGS\[@\]}"' "$OVERRUN_PREFIX" && \
   ! grep -q 'REPO_ARGS\[@\]+' "$OVERRUN_PREFIX"; then
  PASS=$((PASS + 1)); echo "ok   — overrun-check: negative control rebuilt the pre-fix expansion"
else
  FAIL=$((FAIL + 1)); echo "FAIL — overrun-check: negative control could not rebuild the pre-fix expansion"
fi
run_capture bash "$OVERRUN_PREFIX" --pr 88888 --bound-min 30 \
  --started-at 2026-08-26T00:00:00Z --now 2026-08-26T12:00:00Z || true
if [[ "$EMPTY_EXPANSION_ABORTS" -eq 1 ]]; then
  check_contains "overrun-check: pre-fix form aborts on the empty array" \
    "unbound variable" "$ERR"
  check_eq "overrun-check: pre-fix form silently reports no breach" "" "$OUT"
else
  # bash >= 4.4 tolerates the pre-fix expansion, so the silent-exit-0 failure
  # cannot be reproduced here; the alert path runs normally instead.
  check_not_contains "overrun-check: modern bash tolerates the pre-fix form" \
    "unbound variable" "$ERR"
  check_contains "overrun-check: modern bash still emits the breach alert" \
    "PR #88888 overrun" "$OUT"
fi

# =============================================================================
# 2. verify-exit-report-block.sh — header-only block, so lines[] is empty.
# =============================================================================
OUT="$(printf 'EXIT_REPORT\n' | bash "$VERIFY" 2>"$TMP/stderr")"; RC=$?
ERR="$(cat "$TMP/stderr")"
check_not_contains "verify-exit-report: no abort on a header-only block" \
  "unbound variable" "$ERR"
check_eq "verify-exit-report: header-only block exits 1" "1" "$RC"
check_contains "verify-exit-report: reports the missing fields" \
  "missing required field(s): PHASE_COMPLETE" "$ERR"

# A complete block must still validate — the idiom preserves element boundaries,
# so a value containing spaces stays a single element.
VALID_BLOCK="$(printf '%s\n' \
  'EXIT_REPORT' \
  'PHASE_COMPLETE: A' \
  'PR_NUMBER: 1372' \
  'HEAD_SHA: abc1234' \
  'REVIEWER: cr' \
  'OUTCOME: pushed_fixes' \
  'FILES_CHANGED: a.sh, b.sh, c.sh' \
  'NEXT_PHASE: B' \
  'HANDOFF_FILE: ~/.claude/handoffs/o/r/pr-1372-handoff.json')"
OUT="$(printf '%s\n' "$VALID_BLOCK" | bash "$VERIFY" 2>"$TMP/stderr")"; RC=$?
check_eq "verify-exit-report: complete block still exits 0" "0" "$RC"

# Negative control for the format check: two spaces after the colon must still
# be caught, proving the loop still inspects every element.
BAD_BLOCK="$(printf '%s\n' "$VALID_BLOCK" | sed 's/^PR_NUMBER: /PR_NUMBER:  /')"
OUT="$(printf '%s\n' "$BAD_BLOCK" | bash "$VERIFY" 2>"$TMP/stderr")"; RC=$?
ERR="$(cat "$TMP/stderr")"
check_eq "verify-exit-report: double space after colon still exits 1" "1" "$RC"
check_contains "verify-exit-report: names the offending line" \
  "disallowed multiple spaces after colon" "$ERR"

# ---- NEGATIVE CONTROL -------------------------------------------------------
# Half one, portable: the production script must still carry the guarded idiom.
if grep -qF '${lines[@]+"${lines[@]}"}' "$VERIFY"; then
  PASS=$((PASS + 1)); echo "ok   — verify-exit-report: production script still carries the guarded idiom"
else
  FAIL=$((FAIL + 1)); echo "FAIL — verify-exit-report: production script no longer carries the guarded idiom"
fi

# Half two: rebuild the pre-fix expansion and assert it STILL aborts, where that
# abort is reproducible at all.
VERIFY_PREFIX="$TMP/verify-exit-report-block-prefix.sh"
sed 's/\${lines\[@\]+"\${lines\[@\]}"}/"${lines[@]}"/g' "$VERIFY" > "$VERIFY_PREFIX"
if grep -q '"\${lines\[@\]}"' "$VERIFY_PREFIX" && \
   ! grep -q 'lines\[@\]+' "$VERIFY_PREFIX"; then
  PASS=$((PASS + 1)); echo "ok   — verify-exit-report: negative control rebuilt the pre-fix expansion"
else
  FAIL=$((FAIL + 1)); echo "FAIL — verify-exit-report: negative control could not rebuild the pre-fix expansion"
fi
OUT="$(printf 'EXIT_REPORT\n' | bash "$VERIFY_PREFIX" 2>"$TMP/stderr")"; RC=$?
ERR="$(cat "$TMP/stderr")"
if [[ "$EMPTY_EXPANSION_ABORTS" -eq 1 ]]; then
  check_contains "verify-exit-report: pre-fix form aborts on the empty array" \
    "unbound variable" "$ERR"
  check_not_contains "verify-exit-report: pre-fix form never reports the missing fields" \
    "missing required field(s)" "$ERR"
else
  # bash >= 4.4 tolerates the pre-fix expansion, so the crash cannot be
  # reproduced here; the validator reaches its normal missing-field report.
  check_not_contains "verify-exit-report: modern bash tolerates the pre-fix form" \
    "unbound variable" "$ERR"
  check_contains "verify-exit-report: modern bash still reports the missing fields" \
    "missing required field(s)" "$ERR"
fi

echo
echo "empty-array-expansion.test.sh: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
