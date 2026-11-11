#!/usr/bin/env bash
# run-hook-tests-parallel.test.sh — Offline tests for the parallel pool in run-hook-tests.sh
# (issue #2176).
#
# HERMETIC: the runner is copied into a throwaway fixture repo under mktemp -d and run
# against fixture suites there (the runner resolves its repo root as dirname($0)/../..).
# Running the real runner against the real repo would recurse into this suite and depend
# on the live test set. Every fixture suite appends its own path to a shared record file,
# so "each selected suite runs exactly once" is checked from what actually ran.
#
# Run from repo root: bash .github/scripts/tests/run-hook-tests-parallel.test.sh
set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
RUNNER_SRC="$REPO_ROOT/.github/scripts/run-hook-tests.sh"

TMP="$(mktemp -d)"
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT
export HOME="$TMP/home"; mkdir -p "$HOME/.claude"

PASS=0
FAIL=0
ok()  { echo "PASS: $1"; PASS=$((PASS + 1)); }
bad() { echo "FAIL: $1" >&2; FAIL=$((FAIL + 1)); }
check_eq() { if [[ "$1" == "$2" ]]; then ok "$3"; else bad "$3 (expected: $1, got: $2)"; fi; }

# new_fixture <name> -> prints the fixture repo root with the runner installed.
new_fixture() {
  local fix="$TMP/$1"
  mkdir -p "$fix/.github/scripts/tests" "$fix/.claude/hooks/tests" "$fix/.claude/scripts/tests" \
           "$fix/desk/tests" "$fix/logs"
  cp "$RUNNER_SRC" "$fix/.github/scripts/run-hook-tests.sh"
  echo "$fix"
}

# add_suite <fixture> <relpath> <body> <exit_code>: each run appends its path to $RAN_RECORD
# (exported per test) and sleeps briefly so suites genuinely overlap under concurrency.
add_suite() {
  {
    echo '#!/usr/bin/env bash'
    echo 'sleep 0.3'
    printf '%s\n' "printf '%s\\n' \"$2\" >> \"\$RAN_RECORD\""
    printf '%s\n' "$3"
    printf 'exit %s\n' "$4"
  } > "$1/$2"
}

# add_uneven_fixture <fixture>: 7 passing suites across three dirs (7 is not divisible by 2, 3 or 4).
add_uneven_fixture() {
  local fix="$1" i
  for i in 1 2 3; do add_suite "$fix" ".claude/hooks/tests/h$i.test.sh" 'true' 0; done
  for i in 1 2; do add_suite "$fix" ".claude/scripts/tests/s$i.test.sh" 'true' 0; done
  for i in 1 2; do add_suite "$fix" ".github/scripts/tests/g$i.test.sh" 'true' 0; done
}

# exactly_once <record-file> <expected-count>: true when the record has <expected-count> lines and
# every line is distinct. Pure bash/awk, no pipefail-sensitive grep pipelines.
exactly_once() {
  local rec="$1" want="$2" lines dups
  [ -f "$rec" ] || { echo "no record"; return 1; }
  lines="$(wc -l < "$rec" | tr -d ' ')"
  dups="$(LC_ALL=C sort "$rec" | awk 'prev == $0 { d++ } { prev = $0 } END { print d + 0 }')"
  [ "$lines" -eq "$want" ] && [ "$dups" -eq 0 ]
}

# ==========================================================================
# Coverage: every selected suite runs exactly once, for uneven counts,
# an empty selection, ALL, and a partial selection.
# ==========================================================================

FIX="$(new_fixture uneven)"
add_uneven_fixture "$FIX"
export RAN_RECORD="$FIX/ran.txt"

: > "$RAN_RECORD"
OUT="$(RUN_TESTS_LOG_DIR="$FIX/logs" bash "$FIX/.github/scripts/run-hook-tests.sh" --jobs 3 --json 2>"$FIX/err.txt")"
RC=$?
check_eq 0 "$RC" "pool: 7 green suites at --jobs 3 exit 0"
if exactly_once "$RAN_RECORD" 7; then ok "pool: 7 suites with --jobs 3 each ran exactly once"; else bad "pool: suite coverage wrong: $(cat "$RAN_RECORD" | tr '\n' ' ')"; fi
check_eq 7 "$(printf '%s' "$OUT" | jq -r '.total')" "pool: total counts all 7 selected suites"
check_eq "true" "$(printf '%s' "$OUT" | jq -r '.ok')" "pool: green run reports ok"

# More workers than suites must not drop or repeat anything.
: > "$RAN_RECORD"
RUN_TESTS_LOG_DIR="$FIX/logs" bash "$FIX/.github/scripts/run-hook-tests.sh" --jobs 64 --json >/dev/null 2>&1
if exactly_once "$RAN_RECORD" 7; then ok "pool: --jobs larger than the suite count runs each suite exactly once"; else bad "pool: oversized --jobs changed coverage"; fi

# --jobs 1 is the serial path and must still run each suite once.
: > "$RAN_RECORD"
RUN_TESTS_LOG_DIR="$FIX/logs" bash "$FIX/.github/scripts/run-hook-tests.sh" --jobs 1 --json >/dev/null 2>&1
if exactly_once "$RAN_RECORD" 7; then ok "pool: --jobs 1 runs each suite exactly once"; else bad "pool: --jobs 1 changed coverage"; fi

# HOOK_TEST_JOBS is honored when --jobs is absent.
: > "$RAN_RECORD"
HOOK_TEST_JOBS=4 RUN_TESTS_LOG_DIR="$FIX/logs" bash "$FIX/.github/scripts/run-hook-tests.sh" --json >/dev/null 2>&1
if exactly_once "$RAN_RECORD" 7; then ok "pool: HOOK_TEST_JOBS sets concurrency and coverage holds"; else bad "pool: HOOK_TEST_JOBS changed coverage"; fi

# Empty selection: nothing runs, exit 0, and the summary says so.
printf '# reason: no suite affected\n# end-of-selection\n' > "$FIX/sel-empty.txt"
: > "$RAN_RECORD"
OUT="$(RUN_TESTS_LOG_DIR="$FIX/logs" bash "$FIX/.github/scripts/run-hook-tests.sh" --jobs 3 --only-file "$FIX/sel-empty.txt" --json 2>/dev/null)"
RC=$?
check_eq 0 "$RC" "pool: empty selection exits 0"
check_eq 0 "$(wc -l < "$RAN_RECORD" | tr -d ' ')" "pool: empty selection runs no suite"
check_eq 0 "$(printf '%s' "$OUT" | jq -r '.total')" "pool: empty selection reports total 0"

# ALL: every suite runs exactly once.
printf '# reason: runner changed\nALL\n# end-of-selection\n' > "$FIX/sel-all.txt"
: > "$RAN_RECORD"
RUN_TESTS_LOG_DIR="$FIX/logs" bash "$FIX/.github/scripts/run-hook-tests.sh" --jobs 3 --only-file "$FIX/sel-all.txt" --json >/dev/null 2>&1
if exactly_once "$RAN_RECORD" 7; then ok "pool: ALL runs every suite exactly once"; else bad "pool: ALL coverage wrong"; fi

# Partial selection: only the listed suites run, each once, distributed across workers.
printf '# reason: two hook tests\n.claude/hooks/tests/h1.test.sh\n.claude/hooks/tests/h3.test.sh\n.github/scripts/tests/g2.test.sh\n# end-of-selection\n' > "$FIX/sel-part.txt"
: > "$RAN_RECORD"
OUT="$(RUN_TESTS_LOG_DIR="$FIX/logs" bash "$FIX/.github/scripts/run-hook-tests.sh" --jobs 2 --only-file "$FIX/sel-part.txt" --json 2>/dev/null)"
if exactly_once "$RAN_RECORD" 3 && grep -Fxq '.claude/hooks/tests/h1.test.sh' "$RAN_RECORD" && grep -Fxq '.claude/hooks/tests/h3.test.sh' "$RAN_RECORD" && grep -Fxq '.github/scripts/tests/g2.test.sh' "$RAN_RECORD"; then
  ok "pool: partial selection runs exactly the listed suites, each once"
else
  bad "pool: partial selection ran the wrong set: $(tr '\n' ' ' < "$RAN_RECORD")"
fi
check_eq 3 "$(printf '%s' "$OUT" | jq -r '.total')" "pool: partial selection total is the selected count"
check_eq 7 "$(printf '%s' "$OUT" | jq -r '.discovered')" "pool: partial selection still reports discovery count"

# A truncated selection (no terminator) runs ALL, as before.
printf '# reason: cut short\n.claude/hooks/tests/h1.test.sh\n' > "$FIX/sel-trunc.txt"
: > "$RAN_RECORD"
RUN_TESTS_LOG_DIR="$FIX/logs" bash "$FIX/.github/scripts/run-hook-tests.sh" --jobs 3 --only-file "$FIX/sel-trunc.txt" --json >/dev/null 2>&1
if exactly_once "$RAN_RECORD" 7; then ok "pool: truncated selection still runs ALL exactly once"; else bad "pool: truncated selection did not run ALL"; fi

# Usage errors stay usage errors: empty --only-file path, and bad concurrency values.
RUN_TESTS_LOG_DIR="$FIX/logs" bash "$FIX/.github/scripts/run-hook-tests.sh" --only-file "" >/dev/null 2>&1
check_eq 2 "$?" "pool: empty --only-file path is a usage error (exit 2)"
RUN_TESTS_LOG_DIR="$FIX/logs" bash "$FIX/.github/scripts/run-hook-tests.sh" --jobs 0 >/dev/null 2>&1
check_eq 2 "$?" "pool: --jobs 0 is a usage error (exit 2)"
RUN_TESTS_LOG_DIR="$FIX/logs" bash "$FIX/.github/scripts/run-hook-tests.sh" --jobs many >/dev/null 2>&1
check_eq 2 "$?" "pool: non-numeric --jobs is a usage error (exit 2)"
HOOK_TEST_JOBS=0 RUN_TESTS_LOG_DIR="$FIX/logs" bash "$FIX/.github/scripts/run-hook-tests.sh" >/dev/null 2>&1
check_eq 2 "$?" "pool: HOOK_TEST_JOBS=0 is a usage error (exit 2)"
HOOK_TEST_SUITE_TIMEOUT=abc RUN_TESTS_LOG_DIR="$FIX/logs" bash "$FIX/.github/scripts/run-hook-tests.sh" >/dev/null 2>&1
check_eq 2 "$?" "pool: non-numeric HOOK_TEST_SUITE_TIMEOUT is a usage error (exit 2)"
RUN_TESTS_LOG_DIR="$FIX/logs" bash "$FIX/.github/scripts/run-hook-tests.sh" --jobs "" >/dev/null 2>&1
check_eq 2 "$?" "pool: an explicitly empty --jobs is a usage error, not the default (exit 2)"
HOOK_TEST_JOBS="" RUN_TESTS_LOG_DIR="$FIX/logs" bash "$FIX/.github/scripts/run-hook-tests.sh" >/dev/null 2>&1
check_eq 2 "$?" "pool: an explicitly empty HOOK_TEST_JOBS is a usage error (exit 2)"
HOOK_TEST_JOBS=2.5 RUN_TESTS_LOG_DIR="$FIX/logs" bash "$FIX/.github/scripts/run-hook-tests.sh" >/dev/null 2>&1
check_eq 2 "$?" "pool: a non-integer HOOK_TEST_JOBS is a usage error (exit 2)"
HOOK_TEST_JOBS=3 RUN_TESTS_LOG_DIR="$FIX/logs" bash "$FIX/.github/scripts/run-hook-tests.sh" --jobs 1 --json >/dev/null 2>&1
check_eq 0 "$?" "pool: --jobs wins over HOOK_TEST_JOBS when both are valid (exit 0)"

# Per-suite TMPDIR: every suite sees a distinct TMPDIR.
FIX="$(new_fixture tmpdirs)"
for i in 1 2 3 4 5; do
  add_suite "$FIX" ".claude/scripts/tests/t$i.test.sh" "printf '%s\\n' \"\$TMPDIR\" >> \"\$TMPDIRS_RECORD\"" 0
done
export TMPDIRS_RECORD="$FIX/tmpdirs.txt"
: > "$TMPDIRS_RECORD"
export RAN_RECORD="$FIX/ran.txt"; : > "$RAN_RECORD"
RUN_TESTS_LOG_DIR="$FIX/logs" bash "$FIX/.github/scripts/run-hook-tests.sh" --jobs 3 --json >/dev/null 2>&1
if exactly_once "$TMPDIRS_RECORD" 5; then ok "pool: each suite gets its own TMPDIR"; else bad "pool: suites shared a TMPDIR"; fi

# ==========================================================================
# Concurrency: suites overlap (the pool is parallel), never exceed --jobs, the serial
# group runs after the pool, and the report keeps discovery order.
# ==========================================================================

# add_event_suite <fixture> <relpath>: records "start <path>" and "end <path>" lines to $EVENTS,
# so overlap and the peak number of concurrent suites can be read back from the record.
add_event_suite() {
  {
    printf '%s\n' '#!/usr/bin/env bash'
    printf '%s\n' "printf 'start %s\\n' \"\$0\" >> \"\$EVENTS\""
    printf '%s\n' 'sleep 0.5'
    printf '%s\n' "printf 'end %s\\n' \"\$0\" >> \"\$EVENTS\""
  } > "$1/$2"
}

FIX="$(new_fixture overlap)"
add_event_suite "$FIX" .claude/hooks/tests/silence-detector-time-dedupe.test.sh
add_event_suite "$FIX" .claude/hooks/tests/session-start-sync-publish-bounds.test.sh
for i in 1 2 3 4 5 6 7; do
  add_event_suite "$FIX" ".claude/scripts/tests/o$i.test.sh"
done
export EVENTS="$FIX/events.txt"
: > "$EVENTS"
RUN_TESTS_LOG_DIR="$FIX/logs" bash "$FIX/.github/scripts/run-hook-tests.sh" --jobs 3 --json >/dev/null 2>&1
check_eq 9 "$(grep -c '^start ' "$EVENTS")" "pool: every event suite started exactly once (7 pooled + 2 serial)"
PEAK="$(awk '/^start /{ c++; if (c > p) p = c } /^end /{ c-- } END { print p + 0 }' "$EVENTS")"
if [ "$PEAK" -ge 2 ] && [ "$PEAK" -le 3 ]; then
  ok "pool: suites overlap and never exceed --jobs 3 (peak $PEAK)"
else
  bad "pool: peak concurrency $PEAK is outside 2..3 for --jobs 3"
fi
# Pooled starts that happen after the first serial-group start (both serial suites are
# recognised by name, so the second serial start is never counted as a pooled one).
POOLED_AFTER_SERIAL="$(awk '
  /^start .*(silence-detector-time-dedupe|session-start-sync-publish-bounds)/ { s = 1; next }
  s && /^start / { v++ }
  END { print v + 0 }' "$EVENTS")"
check_eq 0 "$POOLED_AFTER_SERIAL" "pool: no pooled suite starts after a serial-group suite"
SERIAL_STARTS="$(grep -c -E '^start .*(silence-detector-time-dedupe|session-start-sync-publish-bounds)' "$EVENTS")"
check_eq 2 "$SERIAL_STARTS" "pool: both serial-group suites ran in this fixture"
POOL_ENDED_FIRST="$(awk '/^start .*(silence-detector-time-dedupe|session-start-sync-publish-bounds)/ { exit } /^end / { e++ } END { print e + 0 }' "$EVENTS")"
check_eq 7 "$POOL_ENDED_FIRST" "pool: every pooled suite ended before the first serial-group suite started"
SERIAL_PEAK="$(awk 'f { if ($1 == "start") c++; else c--; if (c > m) m = c } !f && /^start .*(silence-detector-time-dedupe|session-start-sync-publish-bounds)/ { f = 1; c = 1; m = 1 } END { print m + 0 }' "$EVENTS")"
check_eq 1 "$SERIAL_PEAK" "pool: serial-group suites never overlap each other"

# Discovery-order reporting: the default-mode folds come out in discovery order, whatever the
# completion order was.
EXPECTED_ORDER="$(cd "$FIX" && shopt -s nullglob && for t in .claude/hooks/tests/*.test.sh .claude/scripts/tests/*.test.sh .github/scripts/tests/*.test.sh desk/tests/*.test.sh; do printf '%s\n' "$t"; done)"
RUN_TESTS_LOG_DIR="$FIX/logs" bash "$FIX/.github/scripts/run-hook-tests.sh" --jobs 3 > "$FIX/default.out" 2>&1
ACTUAL_ORDER="$(grep '^::group::' "$FIX/default.out" | sed 's/^::group:://')"
check_eq "$EXPECTED_ORDER" "$ACTUAL_ORDER" "pool: default-mode folds are reported in discovery order"

# Failure handling: a failing suite turns the run red and is named; a hanging
# suite is killed by the per-suite timeout and reported as failed.
# ==========================================================================

FIX="$(new_fixture failing)"
add_uneven_fixture "$FIX"
add_suite "$FIX" .claude/scripts/tests/zz-red.test.sh 'echo "FAIL: expects exit 3, got 0"' 1
export RAN_RECORD="$FIX/ran.txt"; : > "$RAN_RECORD"
OUT="$(RUN_TESTS_LOG_DIR="$FIX/logs" bash "$FIX/.github/scripts/run-hook-tests.sh" --jobs 3 --json 2>"$FIX/err.txt")"
RC=$?
check_eq 1 "$RC" "pool: a failing suite exits 1"
check_eq "false" "$(printf '%s' "$OUT" | jq -r '.ok')" "pool: a failing suite makes the run not ok"
check_eq ".claude/scripts/tests/zz-red.test.sh" "$(printf '%s' "$OUT" | jq -r '.failed_tests[0]')" "pool: failed_tests names the failing suite"
check_eq 1 "$(printf '%s' "$OUT" | jq -r '.failed_tests | length')" "pool: only the failing suite is in failed_tests"
check_eq 8 "$(printf '%s' "$OUT" | jq -r '.total')" "pool: a red run still ran every other suite"
if exactly_once "$RAN_RECORD" 8; then ok "pool: a red run still runs each suite exactly once"; else bad "pool: a red run changed coverage"; fi
if printf '%s' "$OUT" | jq -e '.relevant_error | test("expects exit 3")' >/dev/null; then
  ok "pool: relevant_error carries the failing suite's decisive line"
else
  bad "pool: relevant_error lost the failing suite's FAIL line"
fi
if grep -q 'expects exit 3' "$FIX/err.txt"; then ok "pool: failing suite output still prints in full (stderr)"; else bad "pool: failing suite output was not printed"; fi

FIX="$(new_fixture hanging)"
add_suite "$FIX" .claude/scripts/tests/a-fast.test.sh 'true' 0
add_suite "$FIX" .claude/scripts/tests/b-fast.test.sh 'true' 0
add_suite "$FIX" .claude/scripts/tests/c-hang.test.sh "sleep 297 & printf '%s\\n' \"\$!\" > \"\$HANG_PID_FILE\"; wait" 0
export HANG_PID_FILE="$FIX/hang.pid"
export RAN_RECORD="$FIX/ran.txt"; : > "$RAN_RECORD"
START="$(date +%s)"
OUT="$(HOOK_TEST_SUITE_TIMEOUT=3 RUN_TESTS_LOG_DIR="$FIX/logs" bash "$FIX/.github/scripts/run-hook-tests.sh" --jobs 2 --json 2>"$FIX/err.txt")"
RC=$?
ELAPSED=$(( $(date +%s) - START ))
check_eq 1 "$RC" "pool: a hanging suite makes the run exit 1"
# A 3 s timeout must fire near 3 s: under 15 s proves the kill came from the timeout (the hang
# would otherwise run 297 s), with headroom for a loaded runner.
if [ "$ELAPSED" -lt 15 ]; then ok "pool: a hanging suite is bounded by the per-suite timeout (${ELAPSED}s)"; else bad "pool: run took ${ELAPSED}s for a 3s timeout; the timeout did not bound the hang"; fi
HANG_LOG="$(printf '%s' "$OUT" | jq -r '.log_path')"
if grep -q '^===== .*c-hang.test.sh (rc=124) =====' "$HANG_LOG" && grep -q 'exceeded the per-suite timeout (3s)' "$HANG_LOG"; then
  ok "pool: the hung suite is recorded as rc 124 (timed out), not as a slow pass"
else
  bad "pool: the hung suite was not recorded as a timeout (rc 124) in $HANG_LOG"
fi
check_eq ".claude/scripts/tests/c-hang.test.sh" "$(printf '%s' "$OUT" | jq -r '.failed_tests[0]')" "pool: the hanging suite is reported as failed"
check_eq 1 "$(printf '%s' "$OUT" | jq -r '.failed_tests | length')" "pool: only the hanging suite is failed"
if exactly_once "$RAN_RECORD" 3; then ok "pool: every suite, the hung one included, started exactly once"; else bad "pool: the hang disturbed the other suites"; fi
# The backgrounded child of the hung suite must die with its group.
# The hung suite records its background child's PID; that exact process must be gone afterwards.
HANG_CHILD="$(cat -- "$FIX/hang.pid" 2>/dev/null)"
sleep 1
if [ -z "$HANG_CHILD" ]; then
  bad "pool: the hung suite never recorded its child PID, so the kill cannot be checked"
elif kill -0 "$HANG_CHILD" 2>/dev/null; then
  bad "pool: the hung suite's child process survived the kill"
else
  ok "pool: the hung suite's child process was killed with its group"
fi

# ==========================================================================
# Structure: bash 3.2 safe constructs, and the serial group is a real suite list.
# ==========================================================================

if grep -Eq 'mapfile|readarray|wait -n|declare -A|\$\{[A-Za-z_]+,,\}' "$RUNNER_SRC"; then
  bad "structure: runner uses a bash-4+ construct (mapfile, wait -n, declare -A, ,, case)"
else
  ok "structure: runner uses no bash-4+ constructs"
fi
if grep -Eq 'run_pool [^ ]+ *\$\{[A-Z_]+\[@\]\}' "$RUNNER_SRC"; then
  bad "structure: an array expansion is unguarded under set -u"
else
  ok "structure: array expansions are guarded for bash 3.2"
fi

# ==========================================================================
# Timing report (issue #2207): the job log names the worker count and the effective
# concurrency, and lists the slowest suites. Human mode prints it; --json keeps stdout to JSON.
# ==========================================================================

FIX="$(new_fixture timing)"
add_uneven_fixture "$FIX"
export RAN_RECORD="$FIX/ran.txt"
: > "$RAN_RECORD"
HUMAN="$(RUN_TESTS_LOG_DIR="$FIX/logs" bash "$FIX/.github/scripts/run-hook-tests.sh" --jobs 2 2>/dev/null)"
if grep -Fq '[CONCURRENCY] pool jobs=2 ' <<<"$HUMAN"; then ok "timing: human mode names the worker count"; else bad "timing: worker count line missing"; fi
if grep -Eq '^\[CONCURRENCY\] pool jobs=2 .*$' <<<"$HUMAN" && grep -Eq '^\[TIMING\] wall=' <<<"$HUMAN" && ! grep -Eq '\[CONCURRENCY\].*\[TIMING\]' <<<"$HUMAN"; then ok "timing: CONCURRENCY and TIMING wall lines are separate lines"; else bad "timing: CONCURRENCY and TIMING wall lines are joined"; fi
if grep -Fq '[TIMING] slowest 30 suites:' <<<"$HUMAN"; then ok "timing: human mode prints the slowest-suites table"; else bad "timing: slowest-suites table missing"; fi
if grep -Eq '\[TIMING\] pool: 7 suites, sum [0-9]+s, effective concurrency [0-9.]+ of 2 jobs' <<<"$HUMAN"; then ok "timing: pool summary counts suites and concurrency"; else bad "timing: pool summary wrong"; fi
if grep -Eq '\[TIMING\] serial: 0 suites, sum 0s' <<<"$HUMAN"; then ok "timing: serial summary is zero when no suite is serial"; else bad "timing: serial summary wrong"; fi
# The timing table lands in the aggregate log too, so a CI artifact carries it.
LOGFILE="$(ls -t "$FIX"/logs/run-hook-tests-*.log 2>/dev/null | head -n 1)"
if [ -n "$LOGFILE" ] && grep -Fq '[TIMING] wall=' "$LOGFILE"; then ok "timing: aggregate log carries the timing summary"; else bad "timing: aggregate log lacks the timing summary"; fi
# JSON mode: stdout stays the single JSON object, with no timing text leaking onto it.
JOUT="$(RUN_TESTS_LOG_DIR="$FIX/logs" bash "$FIX/.github/scripts/run-hook-tests.sh" --jobs 2 --json 2>/dev/null)"
if printf '%s' "$JOUT" | jq -e '.ok == true' >/dev/null 2>&1; then ok "timing: --json stdout remains pure JSON"; else bad "timing: --json stdout polluted"; fi

echo ""
echo "run-hook-tests-parallel: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
