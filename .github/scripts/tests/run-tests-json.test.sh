#!/usr/bin/env bash
# run-tests-json.test.sh — Offline tests for the --json compact mode added to
# run-hook-tests.sh and run-python-tests.sh (issue #782).
#
# HERMETIC: the runners are copied into a throwaway fixture repo under mktemp -d and
# exercised against fixture suites there. They resolve the repo root as
# `dirname($0)/../..`, so a copy at $FIX/.github/scripts/ discovers only $FIX's tests.
# Running the real runner against the real repo would recurse (it would discover and
# re-run this very suite) and would depend on the repo's live test set.
#
# Run from repo root: bash .github/scripts/tests/run-tests-json.test.sh
set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
BASH_RUNNER_SRC="$REPO_ROOT/.github/scripts/run-hook-tests.sh"
PY_RUNNER_SRC="$REPO_ROOT/.github/scripts/run-python-tests.sh"

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
  mkdir -p "$fix/.github/scripts" "$fix/.claude/hooks/tests" "$fix/.claude/scripts/tests" \
           "$fix/.github/scripts/tests" "$fix/tests" "$fix/logs"
  cp "$BASH_RUNNER_SRC" "$fix/.github/scripts/run-hook-tests.sh"
  cp "$PY_RUNNER_SRC" "$fix/.github/scripts/run-python-tests.sh"
  echo "$fix"
}

add_suite() { # fixture relpath body exit_code
  { echo '#!/usr/bin/env bash'; printf '%s\n' "$3"; printf 'exit %s\n' "$4"; } > "$1/$2"
}

# ==========================================================================
# run-hook-tests.sh
# ==========================================================================

# --- 1. All green -------------------------------------------------------
FIX="$(new_fixture green)"
add_suite "$FIX" .claude/scripts/tests/a.test.sh 'echo "PASS: alpha assertion"' 0
add_suite "$FIX" .claude/hooks/tests/b.test.sh 'echo "PASS: beta assertion"' 0

OUT="$(RUN_TESTS_LOG_DIR="$FIX/logs" bash "$FIX/.github/scripts/run-hook-tests.sh" --json 2>"$FIX/err.txt")"
RC=$?
check_eq 0 "$RC" "bash runner: all-green exits 0"
check_eq 1 "$(printf '%s\n' "$OUT" | wc -l | tr -d ' ')" "bash runner: --json stdout is exactly one line"
check_eq "true" "$(printf '%s' "$OUT" | jq -r '.ok')" "bash runner: all-green reports ok"
check_eq "[]" "$(printf '%s' "$OUT" | jq -c '.failed_tests')" "bash runner: all-green has empty failed_tests"
check_eq "null" "$(printf '%s' "$OUT" | jq -r '.relevant_error')" "bash runner: all-green has null relevant_error"
check_eq 2 "$(printf '%s' "$OUT" | jq -r '.total')" "bash runner: total counts every discovered suite"

# The savings claim: a passing suite's own output must not reach stdout OR stderr.
if grep -q 'alpha assertion' <<<"$OUT" || grep -q 'alpha assertion' "$FIX/err.txt"; then
  bad "bash runner: passing suite output leaked into --json output"
else
  ok "bash runner: passing suite output is silenced in --json mode"
fi

# ...but it is never destroyed — log_path holds the full capture.
LOG="$(printf '%s' "$OUT" | jq -r '.log_path')"
if grep -q 'alpha assertion' "$LOG" 2>/dev/null && grep -q 'beta assertion' "$LOG" 2>/dev/null; then
  ok "bash runner: full capture of every suite is persisted at log_path"
else
  bad "bash runner: log_path is missing suite output"
fi
case "$LOG" in *//*) bad "bash runner: log_path has a doubled slash" ;; *) ok "bash runner: log_path has no doubled slash" ;; esac

# --- 2. A red suite -----------------------------------------------------
FIX="$(new_fixture red)"
add_suite "$FIX" .claude/scripts/tests/a.test.sh 'echo "PASS: alpha assertion"' 0
add_suite "$FIX" .claude/scripts/tests/bad.test.sh 'echo "FAIL: expects exit 3, got 0"; echo "  context line that only matters in the log"' 1

OUT="$(RUN_TESTS_LOG_DIR="$FIX/logs" bash "$FIX/.github/scripts/run-hook-tests.sh" --json 2>"$FIX/err.txt")"
RC=$?
check_eq 1 "$RC" "bash runner: a failing suite exits 1"
check_eq "false" "$(printf '%s' "$OUT" | jq -r '.ok')" "bash runner: failing run is not ok"
check_eq ".claude/scripts/tests/bad.test.sh" \
  "$(printf '%s' "$OUT" | jq -r '.failed_tests[0]')" "bash runner: failed_tests names the failing suite"
check_eq 1 "$(printf '%s' "$OUT" | jq -r '.failed_tests | length')" "bash runner: passing suite is not in failed_tests"
if printf '%s' "$OUT" | jq -e '.relevant_error | test("expects exit 3")' >/dev/null; then
  ok "bash runner: relevant_error carries the decisive FAIL line"
else
  bad "bash runner: relevant_error missing the FAIL line"
fi
# relevant_error is an index into the failure, not a copy of it.
if printf '%s' "$OUT" | jq -e '.relevant_error | test("context line")' >/dev/null; then
  bad "bash runner: relevant_error copied non-decisive log lines"
else
  ok "bash runner: relevant_error stays decisive-lines-only"
fi
# NON-NEGOTIABLE: a red suite still prints in full, on stderr.
if grep -q 'context line that only matters in the log' "$FIX/err.txt"; then
  ok "bash runner: failing suite output still prints in full (stderr)"
else
  bad "bash runner: failing suite output was compacted away — hard-stop detail must never be hidden"
fi
check_eq 1 "$(printf '%s\n' "$OUT" | wc -l | tr -d ' ')" "bash runner: stdout stays one line even with a failure"

# --- 3. A suite that fails with no recognizable marker ------------------
FIX="$(new_fixture bare)"
add_suite "$FIX" .claude/scripts/tests/quiet.test.sh 'true' 7
OUT="$(RUN_TESTS_LOG_DIR="$FIX/logs" bash "$FIX/.github/scripts/run-hook-tests.sh" --json 2>/dev/null)"
if printf '%s' "$OUT" | jq -e '.relevant_error | test("quiet.test.sh")' >/dev/null; then
  ok "bash runner: a marker-less failure still names the suite in relevant_error"
else
  bad "bash runner: marker-less failure produced an unhelpful relevant_error"
fi

# --- 4. Empty discovery must never pass green (issue #681) --------------
FIX="$(new_fixture empty)"
OUT="$(RUN_TESTS_LOG_DIR="$FIX/logs" bash "$FIX/.github/scripts/run-hook-tests.sh" --json 2>/dev/null)"
RC=$?
check_eq 3 "$RC" "bash runner: empty discovery exits 3"
check_eq "false" "$(printf '%s' "$OUT" | jq -r '.ok')" "bash runner: empty discovery is not ok"
if printf '%s' "$OUT" | jq -e '.relevant_error | test("glob is broken")' >/dev/null; then
  ok "bash runner: empty discovery explains itself in relevant_error"
else
  bad "bash runner: empty discovery gave no explanation"
fi

# --- 5. Default mode is unchanged ---------------------------------------
FIX="$(new_fixture default)"
add_suite "$FIX" .claude/scripts/tests/a.test.sh 'echo "PASS: alpha assertion"' 0
OUT="$(RUN_TESTS_LOG_DIR="$FIX/logs" bash "$FIX/.github/scripts/run-hook-tests.sh" 2>&1)"
RC=$?
check_eq 0 "$RC" "bash runner: default mode still exits 0 when green"
grep -q '::group::.claude/scripts/tests/a.test.sh' <<<"$OUT" \
  && ok "bash runner: default mode still emits ::group:: folds" \
  || bad "bash runner: default mode lost its ::group:: folds"
grep -q 'alpha assertion' <<<"$OUT" \
  && ok "bash runner: default mode still streams suite output" \
  || bad "bash runner: default mode stopped streaming suite output"
grep -q 'PASS: .claude/scripts/tests/a.test.sh' <<<"$OUT" \
  && ok "bash runner: default mode still emits per-suite PASS lines" \
  || bad "bash runner: default mode lost its PASS lines"
grep -q 'Discovered and ran 1 bash test suite' <<<"$OUT" \
  && ok "bash runner: default mode still prints the tally" \
  || bad "bash runner: default mode lost its tally"
# Default mode must not emit the contract — that would break existing log scrapers.
grep -q '"ok":' <<<"$OUT" \
  && bad "bash runner: default mode leaked the JSON contract" \
  || ok "bash runner: default mode does not emit the contract"

# --- 6. Argument handling -----------------------------------------------
FIX="$(new_fixture args)"
add_suite "$FIX" .claude/scripts/tests/a.test.sh 'true' 0
bash "$FIX/.github/scripts/run-hook-tests.sh" --bogus >/dev/null 2>&1
check_eq 2 "$?" "bash runner: unknown flag exits 2"
HELP="$(bash "$FIX/.github/scripts/run-hook-tests.sh" --help 2>&1)"
check_eq 0 "$?" "bash runner: --help exits 0"
grep -q 'compact result contract' <<<"$HELP" \
  && ok "bash runner: --help documents the compact contract" \
  || bad "bash runner: --help does not mention the contract"

# ==========================================================================
# run-python-tests.sh
# ==========================================================================
if ! command -v python3 >/dev/null 2>&1; then
  echo "SKIP: python3 not available — python runner cases skipped"
else
  # --- 7. Green python run ---------------------------------------------
  FIX="$(new_fixture pygreen)"
  cat > "$FIX/tests/test_ok.py" <<'PY'
import unittest


class OkCase(unittest.TestCase):
    def test_adds(self):
        self.assertEqual(1 + 1, 2)
PY
  OUT="$(cd "$FIX" && RUN_TESTS_LOG_DIR="$FIX/logs" bash "$FIX/.github/scripts/run-python-tests.sh" --json 2>"$FIX/err.txt")"
  RC=$?
  check_eq 0 "$RC" "python runner: green run exits 0"
  check_eq 1 "$(printf '%s\n' "$OUT" | wc -l | tr -d ' ')" "python runner: --json stdout is exactly one line"
  check_eq "true" "$(printf '%s' "$OUT" | jq -r '.ok')" "python runner: green run reports ok"
  check_eq "[]" "$(printf '%s' "$OUT" | jq -c '.failed_tests')" "python runner: green run has empty failed_tests"
  check_eq "null" "$(printf '%s' "$OUT" | jq -r '.relevant_error')" "python runner: green run has null relevant_error"
  # The verbose per-test lines are the noise this mode exists to remove.
  if grep -q 'test_adds' <<<"$OUT" || grep -q 'test_adds' "$FIX/err.txt"; then
    bad "python runner: verbose per-test output leaked into --json output"
  else
    ok "python runner: verbose per-test output is silenced in --json mode"
  fi
  LOG="$(printf '%s' "$OUT" | jq -r '.log_path')"
  grep -q 'test_adds' "$LOG" 2>/dev/null \
    && ok "python runner: full unittest output is persisted at log_path" \
    || bad "python runner: log_path is missing the unittest output"

  # --- 8. Red python run ------------------------------------------------
  FIX="$(new_fixture pyred)"
  cat > "$FIX/tests/test_bad.py" <<'PY'
import unittest


class BadCase(unittest.TestCase):
    def test_wrong(self):
        self.assertEqual(3, 4)
PY
  OUT="$(cd "$FIX" && RUN_TESTS_LOG_DIR="$FIX/logs" bash "$FIX/.github/scripts/run-python-tests.sh" --json 2>"$FIX/err.txt")"
  RC=$?
  check_eq 1 "$RC" "python runner: failing run exits 1"
  check_eq "false" "$(printf '%s' "$OUT" | jq -r '.ok')" "python runner: failing run is not ok"
  if printf '%s' "$OUT" | jq -e '.failed_tests[0] | test("test_wrong")' >/dev/null; then
    ok "python runner: failed_tests names the failing test id"
  else
    bad "python runner: failed_tests did not name the failing test"
  fi
  if printf '%s' "$OUT" | jq -e '.relevant_error | test("AssertionError")' >/dev/null; then
    ok "python runner: relevant_error carries the assertion"
  else
    bad "python runner: relevant_error missing the assertion"
  fi
  if grep -q 'AssertionError' "$FIX/err.txt"; then
    ok "python runner: failing run still prints in full (stderr)"
  else
    bad "python runner: failing run output was compacted away"
  fi

  # --- 9. Empty discovery ----------------------------------------------
  FIX="$(new_fixture pyempty)"
  OUT="$(cd "$FIX" && RUN_TESTS_LOG_DIR="$FIX/logs" bash "$FIX/.github/scripts/run-python-tests.sh" --json 2>/dev/null)"
  RC=$?
  check_eq 3 "$RC" "python runner: empty discovery exits 3"
  check_eq "false" "$(printf '%s' "$OUT" | jq -r '.ok')" "python runner: empty discovery is not ok"

  # --- 10. Default mode unchanged ---------------------------------------
  FIX="$(new_fixture pydefault)"
  cat > "$FIX/tests/test_ok.py" <<'PY'
import unittest


class OkCase(unittest.TestCase):
    def test_adds(self):
        self.assertEqual(1 + 1, 2)
PY
  OUT="$(cd "$FIX" && RUN_TESTS_LOG_DIR="$FIX/logs" bash "$FIX/.github/scripts/run-python-tests.sh" 2>&1)"
  RC=$?
  check_eq 0 "$RC" "python runner: default mode exits 0 when green"
  grep -q 'test_adds' <<<"$OUT" \
    && ok "python runner: default mode still streams verbose output" \
    || bad "python runner: default mode stopped streaming verbose output"
  grep -q 'Discovered 1 Python test module' <<<"$OUT" \
    && ok "python runner: default mode still prints the discovery line" \
    || bad "python runner: default mode lost its discovery line"
  grep -q '"ok":' <<<"$OUT" \
    && bad "python runner: default mode leaked the JSON contract" \
    || ok "python runner: default mode does not emit the contract"

  # A red default run must still exit non-zero through the tee pipeline
  # (PIPESTATUS, not $? — a pipe would otherwise report tee's success).
  FIX="$(new_fixture pydefaultred)"
  cat > "$FIX/tests/test_bad.py" <<'PY'
import unittest


class BadCase(unittest.TestCase):
    def test_wrong(self):
        self.assertEqual(3, 4)
PY
  (cd "$FIX" && RUN_TESTS_LOG_DIR="$FIX/logs" bash "$FIX/.github/scripts/run-python-tests.sh" >/dev/null 2>&1)
  check_eq 1 "$?" "python runner: default mode propagates failure through the tee pipeline"

  bash "$FIX/.github/scripts/run-python-tests.sh" --bogus >/dev/null 2>&1
  check_eq 2 "$?" "python runner: unknown flag exits 2"
fi

echo "----"
echo "run-tests-json.test.sh: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
