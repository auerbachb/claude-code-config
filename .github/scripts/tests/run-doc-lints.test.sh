#!/usr/bin/env bash
# run-doc-lints.test.sh — hermetic tests for run-doc-lints.sh (issue #1138).
#
# HERMETIC: the runner is copied into a throwaway fixture repo under mktemp -d
# and exercised against fixture lint scripts there.  The runner resolves the
# repo root as `dirname($0)/../..`, so a copy at $FIX/.github/scripts/
# discovers only $FIX's lints.  Running the real runner against the real repo
# would re-run all production lints (slow + fragile).
#
# Run from repo root: bash .github/scripts/tests/run-doc-lints.test.sh
set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
RUNNER_SRC="$REPO_ROOT/.github/scripts/run-doc-lints.sh"

TMP="$(mktemp -d)"
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT
export HOME="$TMP/home"; mkdir -p "$HOME/.claude"

PASS=0
FAIL=0
ok()  { echo "PASS: $1"; PASS=$((PASS + 1)); }
bad() { echo "FAIL: $1" >&2; FAIL=$((FAIL + 1)); }
check_eq() { if [[ "$1" == "$2" ]]; then ok "$3"; else bad "$3 (expected: $1, got: $2)"; fi; }

# new_fixture <name> -> prints the fixture repo root, runner already installed.
new_fixture() {
  local fix="$TMP/$1"
  mkdir -p "$fix/.github/scripts" "$fix/.claude/scripts" "$fix/logs"
  cp "$RUNNER_SRC" "$fix/.github/scripts/run-doc-lints.sh"
  echo "$fix"
}

add_lint() { # fixture relpath exit_code [body]
  local body="${4:-}"
  {
    echo '#!/usr/bin/env bash'
    if [[ -n "$body" ]]; then printf '%s\n' "$body"; fi
    printf 'exit %s\n' "$3"
  } > "$1/$2"
}

# ==========================================================================
# 1. All lints pass
# ==========================================================================
FIX="$(new_fixture green)"
add_lint "$FIX" .github/scripts/alpha-lint.sh 0 'echo "alpha-lint: OK"'
add_lint "$FIX" .github/scripts/beta-lint.sh  0 'echo "beta-lint: OK"'
# The explicit extra path
add_lint "$FIX" .claude/scripts/reference-catalog-lint.sh 0 'echo "reference-catalog-lint: OK (0 files indexed)"'

OUT="$(RUN_TESTS_LOG_DIR="$FIX/logs" bash "$FIX/.github/scripts/run-doc-lints.sh" --json 2>"$FIX/err.txt")"
RC=$?
check_eq 0 "$RC" "all-green: exits 0"
check_eq 1 "$(printf '%s\n' "$OUT" | wc -l | tr -d ' ')" "all-green: --json stdout is exactly one line"
check_eq "true" "$(printf '%s' "$OUT" | jq -r '.ok')" "all-green: ok is true"
check_eq "[]" "$(printf '%s' "$OUT" | jq -c '.failed_tests')" "all-green: failed_tests is empty"
check_eq "null" "$(printf '%s' "$OUT" | jq -r '.relevant_error')" "all-green: relevant_error is null"
check_eq 3 "$(printf '%s' "$OUT" | jq -r '.total')" "all-green: total counts all discovered lints"
check_eq 0 "$(printf '%s' "$OUT" | jq -r '.failed')" "all-green: failed count is 0"

# Passing lint output must not reach stdout or stderr in --json mode.
if grep -q 'alpha-lint: OK' <<<"$OUT" || grep -q 'alpha-lint: OK' "$FIX/err.txt"; then
  bad "all-green: passing lint output leaked into --json output"
else
  ok "all-green: passing lint output is silenced in --json mode"
fi

# Full capture is always persisted.
LOG="$(printf '%s' "$OUT" | jq -r '.log_path')"
if grep -q 'alpha-lint: OK' "$LOG" 2>/dev/null && grep -q 'beta-lint: OK' "$LOG" 2>/dev/null; then
  ok "all-green: full capture persisted at log_path"
else
  bad "all-green: log_path is missing lint output"
fi
case "$LOG" in *//*) bad "all-green: log_path has a doubled slash" ;; *) ok "all-green: log_path has no doubled slash" ;; esac

# ==========================================================================
# 2. A failing lint
# ==========================================================================
FIX="$(new_fixture red)"
add_lint "$FIX" .github/scripts/alpha-lint.sh 0 'echo "alpha-lint: OK"'
add_lint "$FIX" .github/scripts/bad-lint.sh   1 'echo "::error::bad-lint: 1 error(s) found"; echo "  context: only matters in the log"'
add_lint "$FIX" .claude/scripts/reference-catalog-lint.sh 0 'echo "reference-catalog-lint: OK (0 files indexed)"'

OUT="$(RUN_TESTS_LOG_DIR="$FIX/logs" bash "$FIX/.github/scripts/run-doc-lints.sh" --json 2>"$FIX/err.txt")"
RC=$?
check_eq 1 "$RC" "failing lint: exits 1"
check_eq "false" "$(printf '%s' "$OUT" | jq -r '.ok')" "failing lint: ok is false"
check_eq ".github/scripts/bad-lint.sh" \
  "$(printf '%s' "$OUT" | jq -r '.failed_tests[0]')" "failing lint: failed_tests names the failing script"
check_eq 1 "$(printf '%s' "$OUT" | jq -r '.failed_tests | length')" "failing lint: passing lint not in failed_tests"
if printf '%s' "$OUT" | jq -e '.relevant_error | test("bad-lint: 1 error")' >/dev/null; then
  ok "failing lint: relevant_error carries the decisive error line"
else
  bad "failing lint: relevant_error missing the error line"
fi
# relevant_error is an index, not a copy of the log.
if printf '%s' "$OUT" | jq -e '.relevant_error | test("context: only matters")' >/dev/null; then
  bad "failing lint: relevant_error copied non-decisive log lines"
else
  ok "failing lint: relevant_error stays decisive-lines-only"
fi
# NON-NEGOTIABLE: failing lint still prints in full on stderr.
if grep -q 'context: only matters in the log' "$FIX/err.txt"; then
  ok "failing lint: failing output still prints in full (stderr)"
else
  bad "failing lint: output was compacted away — failing detail must never be hidden"
fi
check_eq 1 "$(printf '%s\n' "$OUT" | wc -l | tr -d ' ')" "failing lint: stdout stays one line even with a failure"

# ==========================================================================
# 3. Exclusion list: excluded scripts are not run
# ==========================================================================
FIX="$(new_fixture exclusions)"
add_lint "$FIX" .github/scripts/real-lint.sh                0 'echo "real-lint: OK"'
add_lint "$FIX" .github/scripts/chip-model-guard-lint.sh    1 'echo "::error::should not run"'
add_lint "$FIX" .github/scripts/env-template-allowlist-lint.sh 1 'echo "::error::should not run"'
add_lint "$FIX" .github/scripts/merge-authority-lint.sh     1 'echo "::error::should not run"'
add_lint "$FIX" .claude/scripts/reference-catalog-lint.sh   0 'echo "reference-catalog-lint: OK (0 files indexed)"'

OUT="$(RUN_TESTS_LOG_DIR="$FIX/logs" bash "$FIX/.github/scripts/run-doc-lints.sh" --json 2>"$FIX/err.txt")"
RC=$?
check_eq 0 "$RC" "exclusions: excluded scripts do not cause failures"
check_eq "true" "$(printf '%s' "$OUT" | jq -r '.ok')" "exclusions: result is ok when only excluded scripts would fail"
check_eq 2 "$(printf '%s' "$OUT" | jq -r '.total')" "exclusions: only non-excluded lints are counted"

# ==========================================================================
# 4. rule-lint-ratchet.sh (*-ratchet.sh pattern) is NOT discovered
# ==========================================================================
FIX="$(new_fixture ratchet)"
add_lint "$FIX" .github/scripts/rule-lint.sh         0 'echo "rule-lint: OK"'
add_lint "$FIX" .github/scripts/rule-lint-ratchet.sh 1 'echo "::error::ratchet: should not run standalone"'
add_lint "$FIX" .claude/scripts/reference-catalog-lint.sh 0 'echo "reference-catalog-lint: OK (0 files indexed)"'

OUT="$(RUN_TESTS_LOG_DIR="$FIX/logs" bash "$FIX/.github/scripts/run-doc-lints.sh" --json 2>"$FIX/err.txt")"
RC=$?
check_eq 0 "$RC" "ratchet: *-ratchet.sh is not matched by the *-lint.sh glob"
check_eq 2 "$(printf '%s' "$OUT" | jq -r '.total')" "ratchet: only *-lint.sh scripts are counted"

# ==========================================================================
# 5. Empty discovery must never pass green (precedent: issue #681)
# ==========================================================================
FIX="$(new_fixture empty)"
# No lints at all — .claude/scripts/reference-catalog-lint.sh also absent
OUT="$(RUN_TESTS_LOG_DIR="$FIX/logs" bash "$FIX/.github/scripts/run-doc-lints.sh" --json 2>/dev/null)"
RC=$?
check_eq 3 "$RC" "empty discovery: exits 3"
check_eq "false" "$(printf '%s' "$OUT" | jq -r '.ok')" "empty discovery: ok is false"
if printf '%s' "$OUT" | jq -e '.relevant_error | test("glob is broken")' >/dev/null; then
  ok "empty discovery: explains itself in relevant_error"
else
  bad "empty discovery: gave no explanation"
fi

# ==========================================================================
# 6. Default (non-JSON) mode is unchanged
# ==========================================================================
FIX="$(new_fixture default)"
add_lint "$FIX" .github/scripts/alpha-lint.sh 0 'echo "alpha-lint: OK"'
add_lint "$FIX" .claude/scripts/reference-catalog-lint.sh 0 'echo "reference-catalog-lint: OK (0 files indexed)"'

OUT="$(RUN_TESTS_LOG_DIR="$FIX/logs" bash "$FIX/.github/scripts/run-doc-lints.sh" 2>&1)"
RC=$?
check_eq 0 "$RC" "default mode: exits 0 when all green"
grep -q '::group::.github/scripts/alpha-lint.sh' <<<"$OUT" \
  && ok "default mode: emits ::group:: folds" \
  || bad "default mode: lost ::group:: folds"
grep -q 'alpha-lint: OK' <<<"$OUT" \
  && ok "default mode: streams lint output" \
  || bad "default mode: stopped streaming lint output"
grep -q 'PASS: .github/scripts/alpha-lint.sh' <<<"$OUT" \
  && ok "default mode: emits per-lint PASS lines" \
  || bad "default mode: lost PASS lines"
grep -q 'Discovered and ran 2 doc-lint script(s)' <<<"$OUT" \
  && ok "default mode: prints the tally" \
  || bad "default mode: lost the tally"
# Default mode must not emit the JSON contract.
grep -q '"ok":' <<<"$OUT" \
  && bad "default mode: leaked the JSON contract" \
  || ok "default mode: does not emit the JSON contract"

# ==========================================================================
# 7. Unknown flag exits 2; --help exits 0
# ==========================================================================
FIX="$(new_fixture args)"
add_lint "$FIX" .github/scripts/alpha-lint.sh 0 ''
bash "$FIX/.github/scripts/run-doc-lints.sh" --bogus >/dev/null 2>&1
check_eq 2 "$?" "args: unknown flag exits 2"
bash "$FIX/.github/scripts/run-doc-lints.sh" --help >/dev/null 2>&1
check_eq 0 "$?" "args: --help exits 0"
HELP="$(bash "$FIX/.github/scripts/run-doc-lints.sh" --help 2>&1)"
grep -q 'compact result contract' <<<"$HELP" \
  && ok "args: --help mentions the compact contract" \
  || bad "args: --help does not mention the compact contract"

# ==========================================================================
# 8. Bare non-zero exit (no recognizable marker) still names the lint
# ==========================================================================
FIX="$(new_fixture bare)"
add_lint "$FIX" .github/scripts/quiet-lint.sh 7 ''
add_lint "$FIX" .claude/scripts/reference-catalog-lint.sh 0 ''

OUT="$(RUN_TESTS_LOG_DIR="$FIX/logs" bash "$FIX/.github/scripts/run-doc-lints.sh" --json 2>/dev/null)"
if printf '%s' "$OUT" | jq -e '.relevant_error | test("quiet-lint.sh")' >/dev/null; then
  ok "bare failure: marker-less failure still names the lint in relevant_error"
else
  bad "bare failure: marker-less failure produced unhelpful relevant_error"
fi

echo "----"
echo "run-doc-lints.test.sh: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
