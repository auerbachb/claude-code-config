#!/usr/bin/env bash
# summarize-test-run.test.sh — Offline tests for summarize-test-run.sh (issue #782).
#
# The runners it wraps are stubs here, so these assert the CI surfacing behaviour
# (step summary, ::error:: annotation, exit propagation, and the fail-loud path when
# a runner emits no contract) without running a real test suite.
#
# Run from repo root: bash .github/scripts/tests/summarize-test-run.test.sh
set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
SUT="$REPO_ROOT/.github/scripts/summarize-test-run.sh"

TMP="$(mktemp -d)"
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT
export HOME="$TMP/home"; mkdir -p "$HOME/.claude"

PASS=0
FAIL=0
ok()  { echo "PASS: $1"; PASS=$((PASS + 1)); }
bad() { echo "FAIL: $1" >&2; FAIL=$((FAIL + 1)); }
check_eq() { if [[ "$1" == "$2" ]]; then ok "$3"; else bad "$3 (expected: $1, got: $2)"; fi; }

# make_runner <name> <stdout> <exit-code> — a stub standing in for a --json runner.
# It records the argv it was handed so the "--json is appended" contract is testable.
make_runner() {
  local path="$TMP/$1"
  {
    echo '#!/usr/bin/env bash'
    printf 'printf "%%s\\n" "$*" > "%s.argv"\n' "$path"
    printf 'cat <<%s\n%s\n%s\n' "'RUNNER_EOF'" "$2" "RUNNER_EOF"
    printf 'exit %s\n' "$3"
  } > "$path"
  chmod +x "$path"
  echo "$path"
}

GREEN='{"ok":true,"failed_tests":[],"relevant_error":null,"log_path":"/tmp/green.log","total":3,"failed":0}'
RED='{"ok":false,"failed_tests":["a.test.sh","b.test.sh"],"relevant_error":"a.test.sh: FAIL: boom\nsecond line of detail","log_path":"/tmp/red.log","total":3,"failed":2}'

# --------------------------------------------------------------------------
# 1. Usage.
# --------------------------------------------------------------------------
"$SUT" >/dev/null 2>&1; check_eq 2 "$?" "no args exits 2"
"$SUT" "Label only" >/dev/null 2>&1; check_eq 2 "$?" "missing runner exits 2"
"$SUT" "Label" "$TMP/does-not-exist.sh" >/dev/null 2>&1; check_eq 2 "$?" "nonexistent runner exits 2"
"$SUT" --help >/dev/null 2>&1; check_eq 0 "$?" "--help exits 0"

# --------------------------------------------------------------------------
# 2. Green run — exit 0, summary written, no annotation.
# --------------------------------------------------------------------------
R="$(make_runner green.sh "$GREEN" 0)"
SUMMARY_FILE="$TMP/summary-green.md"
: > "$SUMMARY_FILE"
ERRF="$TMP/green.err"
GITHUB_STEP_SUMMARY="$SUMMARY_FILE" "$SUT" "Bash test suites" "$R" >/dev/null 2>"$ERRF"
check_eq 0 "$?" "green run exits 0"
grep -q -- '--json' "$R.argv" \
  && ok "runner is invoked with --json" \
  || bad "runner was not given --json (argv: $(cat "$R.argv" 2>/dev/null))"
grep -q 'Bash test suites — passed' "$SUMMARY_FILE" \
  && ok "green run writes a passed heading to the step summary" \
  || bad "green run did not write the passed heading"
grep -q '"ok":true' "$SUMMARY_FILE" \
  && ok "step summary embeds the raw contract" \
  || bad "step summary is missing the contract"
grep -q '/tmp/green.log' "$SUMMARY_FILE" \
  && ok "step summary names log_path so the raw output stays reachable" \
  || bad "step summary omits log_path"
grep -q '::error::' "$ERRF" \
  && bad "green run emitted an ::error:: annotation" \
  || ok "green run emits no ::error:: annotation"

# --------------------------------------------------------------------------
# 3. Red run — exit propagates, annotation carries the decisive line + log path.
# --------------------------------------------------------------------------
R="$(make_runner red.sh "$RED" 1)"
SUMMARY_FILE="$TMP/summary-red.md"
: > "$SUMMARY_FILE"
ERRF="$TMP/red.err"
GITHUB_STEP_SUMMARY="$SUMMARY_FILE" "$SUT" "Bash test suites" "$R" >/dev/null 2>"$ERRF"
check_eq 1 "$?" "red run propagates the runner's exit code"
grep -q 'Bash test suites — FAILED' "$SUMMARY_FILE" \
  && ok "red run writes a FAILED heading" \
  || bad "red run did not write the FAILED heading"
grep -q 'a.test.sh' "$SUMMARY_FILE" \
  && ok "red run lists the failing suites in the summary" \
  || bad "red run did not list the failing suites"
grep -q 'Failing (2)' "$SUMMARY_FILE" \
  && ok "red run reports the failing count" \
  || bad "red run did not report the failing count"
grep -q '::error::Bash test suites: a.test.sh: FAIL: boom' "$ERRF" \
  && ok "red run annotation carries the decisive line" \
  || bad "red run annotation is wrong: $(cat "$ERRF")"
grep -q '/tmp/red.log' "$ERRF" \
  && ok "red run annotation points at the full log" \
  || bad "red run annotation omits the log path"
# A GitHub annotation is single-line; a multi-line relevant_error must be trimmed.
check_eq 1 "$(grep -c '::error::' "$ERRF")" "annotation is a single line"
grep -q 'second line of detail' "$ERRF" \
  && bad "annotation leaked a second line (breaks the annotation)" \
  || ok "annotation drops trailing detail lines"

# --------------------------------------------------------------------------
# 4. A runner that emits no contract must fail LOUD, never pass green
#    (memory: guards that pass by not running).
# --------------------------------------------------------------------------
R="$(make_runner garbage.sh 'Traceback (most recent call last): everything is on fire' 0)"
ERRF="$TMP/garbage.err"
"$SUT" "Bash test suites" "$R" >/dev/null 2>"$ERRF"
check_eq 4 "$?" "unparseable contract with a 0 exit still fails (exit 4)"
grep -q 'no parseable result contract' "$ERRF" \
  && ok "unparseable contract says so on stderr" \
  || bad "unparseable contract produced no explanation"
grep -q 'everything is on fire' "$ERRF" \
  && ok "unparseable contract echoes the raw stdout for diagnosis" \
  || bad "unparseable contract swallowed the raw stdout"

# When the runner ALSO failed, its own code wins over the wrapper's 4.
R="$(make_runner garbage-red.sh 'not json' 3)"
"$SUT" "Bash test suites" "$R" >/dev/null 2>&1
check_eq 3 "$?" "unparseable contract propagates the runner's own failure code"

# A partial object (no log_path) is not a contract either.
R="$(make_runner partial.sh '{"ok":true}' 0)"
"$SUT" "Bash test suites" "$R" >/dev/null 2>&1
check_eq 4 "$?" "contract missing log_path is rejected"

# --------------------------------------------------------------------------
# 5. No GITHUB_STEP_SUMMARY (local run) — must not crash.
# --------------------------------------------------------------------------
R="$(make_runner nosummary.sh "$GREEN" 0)"
( unset GITHUB_STEP_SUMMARY; "$SUT" "Local" "$R" >/dev/null 2>&1 )
check_eq 0 "$?" "runs cleanly with no GITHUB_STEP_SUMMARY set"

echo "----"
echo "summarize-test-run.test.sh: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
