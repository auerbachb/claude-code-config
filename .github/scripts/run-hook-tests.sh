#!/usr/bin/env bash
#
# Discover and run every bash hook/script test suite in the repo. Adding a test
# needs NO workflow edit: drop a `<name>.test.sh` into one of the discovered
# dirs and it runs automatically. This retired the per-test step list in
# .github/workflows/hook-scripts.yml that made that file a recurring
# merge-conflict hotspot (issue #681).
#
# Discovered dirs:
#   .claude/hooks/tests/    .claude/scripts/tests/    .github/scripts/tests/
#   desk/tests/             (the human-queue store, issue #1774 — its live
#                            database suite skips without HUMAN_QUEUE_DATABASE_URL,
#                            so CI runs only the offline ones)
#
# Test contract: exit 0 on pass / non-zero on fail; invoked via `bash` so the
# executable bit is NOT required (some suites are intentionally non-exec); no
# positional args needed.
#
# Every discovered suite is parse-checked with `bash -n` before it is run, and a
# suite that fails that check is reported as the syntax error it is rather than
# as the last line it managed to print before aborting (issue #1675).
# Runtime command-substitution parsing is not covered by bash -n (issue #1677).
# Decision: retain execution as the behavioral gate and move problematic case
# syntax / nested escaped-JSON construction out of substitutions in fixtures;
# do not claim that a syntax-only precheck proves native Bash 3.2 compatibility.
#
# Usage (CI or local, runnable from anywhere):
#   bash .github/scripts/run-hook-tests.sh            # human/CI folds (default)
#   bash .github/scripts/run-hook-tests.sh --json     # compact result contract
#   bash .github/scripts/run-hook-tests.sh --only-file <file>   # run only the selected suites
#   bash .github/scripts/run-hook-tests.sh --jobs <n>           # concurrent suites (default: CPU count)
#   bash .github/scripts/run-hook-tests.sh --help
#
# --only-file <file> (issue #2153): the file is the output of
# .github/scripts/select-hook-tests.sh. A line `ALL` runs every suite, exactly as with no
# argument. Otherwise only the suite paths listed in the file run; `# ...` lines are
# comments. A file without the selector's `# end-of-selection` terminator was cut short
# and runs ALL. An empty selection runs nothing and exits 0 with a summary that says so.
# An unreadable file is a usage error (exit 2), never a silent full or empty run.
#
# Parallel pool (issue #2176): selected suites run side by side, at most --jobs at a time
# (default: the CPU count; HOOK_TEST_JOBS overrides, --jobs wins). Each suite gets its own
# $TMPDIR under this run's work directory, its own captured output, and a per-suite
# timeout (HOOK_TEST_SUITE_TIMEOUT seconds, default 900). A suite that exceeds the timeout
# has its whole process group killed and is reported as failed (rc 124). Every selected
# suite runs exactly once. Suites listed in SERIAL_GROUP below cannot share the machine
# with other suites; they run after the pool, one at a time. Output is reported in
# discovery order, so the log and --json are the same shape whatever the concurrency.
#
# --json (issue #782): emits the compact result contract from
# .claude/reference/compact-result-contract.md as the ONLY thing on stdout:
#
#   {"ok":false,"failed_tests":[".claude/scripts/tests/foo.test.sh"],
#    "relevant_error":"foo.test.sh: FAIL: expects exit 3","log_path":"/tmp/run-hook-tests-....log",
#    "total":94,"failed":1}
#
# Compact mode silences PASSING suites — that is where the savings are. Failing
# suites still print their captured output IN FULL, on stderr, because a failing
# test must never be compacted down to a status line (token-efficiency-audit-2026-07.md
# §"What NOT to change"). The complete capture of every suite, pass or fail, is always
# written to `log_path` in both modes.
#
# Log location: $RUN_TESTS_LOG_DIR, else $RUNNER_TEMP (GitHub Actions), else $TMPDIR, else /tmp.
#
# Exit codes:
#   0  every discovered suite passed
#   1  one or more suites failed (including a suite killed by the per-suite timeout)
#   2  usage error (unknown flag, bad --jobs / HOOK_TEST_JOBS / HOOK_TEST_SUITE_TIMEOUT,
#      or an unreadable --only-file)
#   3  discovery found no suites — a glob is broken (issue #681); never a silent green
#
# Not `set -e`: the loop deliberately runs every suite and aggregates failures
# so one red test does not hide the rest. The final check is the exit gate.
set -uo pipefail
shopt -s nullglob

# Suites that cannot share the machine with other suites. They run after the parallel pool,
# one at a time, still under the per-suite timeout. One repo-relative path per line.
#  - silence-detector-time-dedupe: its hook keeps fixed /tmp/claude-*-<session-id> sentinels
#    (by design: sentinels live in /tmp), and the suite primes and clears those exact names.
#  - session-start-sync-publish-bounds: asserts wall-clock budgets (the ample-budget control
#    in CLAUDE_CONFIG_SYNC_TEST_AMPLE_BUDGET_SECS) that concurrent load can break.
SERIAL_GROUP="
.claude/hooks/tests/silence-detector-time-dedupe.test.sh
.claude/hooks/tests/session-start-sync-publish-bounds.test.sh
"

JSON=0
ONLY_FILE=""
ONLY_FILE_GIVEN=0   # distinguishes "--only-file given (maybe empty)" from "not given"
JOBS_ARG=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --json) JSON=1; shift ;;
    --only-file)
      [ "$#" -ge 2 ] || { echo "::error::run-hook-tests.sh: --only-file needs a path" >&2; exit 2; }
      ONLY_FILE="$2"; ONLY_FILE_GIVEN=1; shift 2
      ;;
    --jobs)
      [ "$#" -ge 2 ] || { echo "::error::run-hook-tests.sh: --jobs needs a count" >&2; exit 2; }
      JOBS_ARG="$2"; shift 2
      ;;
    -h|--help)
      awk 'NR == 1 { next } /^#/ { print; n = 1; next } { exit } END { exit(n ? 0 : 1) }' "$0" ||
        { printf '%s: --help header extraction produced no output\n' "$0" >&2; exit 70; }
      exit 0
      ;;
    *)
      echo "::error::run-hook-tests.sh: unknown argument: $1" >&2
      exit 2
      ;;
  esac
done

# Concurrency and per-suite timeout. A positive integer or a usage error: a typo must never
# silently fall back to a different concurrency or an unbounded wait.
is_positive_int() { case "$1" in ''|*[!0-9]*) return 1 ;; esac; [ "$1" -ge 1 ]; }
if [ -n "$JOBS_ARG" ]; then
  JOBS="$JOBS_ARG"
elif [ -n "${HOOK_TEST_JOBS:-}" ]; then
  JOBS="$HOOK_TEST_JOBS"
else
  JOBS="$(getconf _NPROCESSORS_ONLN 2>/dev/null || true)"
  is_positive_int "$JOBS" || JOBS=2
fi
is_positive_int "$JOBS" || { echo "::error::run-hook-tests.sh: --jobs / HOOK_TEST_JOBS must be a positive integer: $JOBS" >&2; exit 2; }
SUITE_TIMEOUT="${HOOK_TEST_SUITE_TIMEOUT:-900}"
is_positive_int "$SUITE_TIMEOUT" || { echo "::error::run-hook-tests.sh: HOOK_TEST_SUITE_TIMEOUT must be a positive integer of seconds: $SUITE_TIMEOUT" >&2; exit 2; }

# Read the selection before the cd below, so a relative --only-file path still resolves
# against the caller's directory.
SELECT_MODE=0
SELECTION=""
SEL_ALL=0
SEL_REASON=""
if [ "$ONLY_FILE_GIVEN" -eq 1 ]; then
  # An explicitly empty path is an unreadable selection, never a silent full run.
  [ -n "$ONLY_FILE" ] || { echo "::error::run-hook-tests.sh: --only-file was given an empty path" >&2; exit 2; }
  SELECT_MODE=1
  SELECTION="$(cat -- "$ONLY_FILE" 2>/dev/null)" || {
    echo "::error::run-hook-tests.sh: cannot read --only-file: $ONLY_FILE" >&2
    exit 2
  }
  SEL_REASON="$(printf '%s\n' "$SELECTION" | awk '/^# reason: / { sub(/^# reason: /, ""); print; exit }')"
  # The selector always writes a `# reason:` header. Its absence means an empty or
  # truncated file, which must never pass as an explained zero-run.
  if ! grep -q '^# reason: ' <<<"$SELECTION"; then
    echo "::error::run-hook-tests.sh: --only-file has no '# reason:' header (empty or truncated?): $ONLY_FILE" >&2
    exit 2
  fi
  if grep -Fxq 'ALL' <<<"$SELECTION"; then SEL_ALL=1; fi
  # The selector ends every selection with its terminator. A file without it was cut
  # short by a failed write, so run every suite rather than trust a partial list.
  if ! grep -Fxq '# end-of-selection' <<<"$SELECTION"; then
    echo "::warning::run-hook-tests.sh: --only-file has no '# end-of-selection' terminator (truncated?): running ALL" >&2
    SEL_ALL=1
    SEL_REASON="truncated selection file: full run"
  fi
fi

# A suite runs when no selection was given, the selection is ALL, or it is listed.
is_selected() {
  if [ "$SELECT_MODE" -eq 0 ] || [ "$SEL_ALL" -eq 1 ]; then return 0; fi
  grep -Fxq -- "$1" <<<"$SELECTION"
}

# Resolve to the repo root regardless of caller cwd so the globs below resolve.
cd "$(dirname "${BASH_SOURCE[0]}")/../.." || {
  echo "::error::run-hook-tests.sh: cannot cd to repo root" >&2
  exit 1
}

LOG_DIR="${RUN_TESTS_LOG_DIR:-${RUNNER_TEMP:-${TMPDIR:-/tmp}}}"
LOG_DIR="${LOG_DIR%/}"   # $TMPDIR usually ends in / — keep log_path free of a doubled slash
mkdir -p "$LOG_DIR" 2>/dev/null || LOG_DIR="/tmp"
LOG="$LOG_DIR/run-hook-tests-$(date -u +%s)-$$.log"
: > "$LOG"

# Every human-facing line goes to stderr in --json mode so stdout stays parseable.
say() { if [ "$JSON" -eq 1 ]; then printf '%s\n' "$1" >&2; else printf '%s\n' "$1"; fi; }

# Per-run work directory: one slot per selected suite holds its captured output (out), its exit
# code (rc, written last and atomically), and a private TMPDIR (tmp) so suites that mktemp
# never collide. Removed on exit.
WORK="$(mktemp -d "${TMPDIR:-/tmp}/run-hook-tests-work-XXXXXX")" || {
  echo "::error::run-hook-tests.sh: cannot create the per-run work directory" >&2
  exit 70
}
# On exit (including a TERM/INT from a cancelled CI job) stop every suite still running, so no
# orphan keeps writing into the shared checkout, then remove the work directory. A suite is still
# running when its slot has a pid file but no rc file.
cleanup() {
  local f p pids=""
  for f in "$WORK"/*/pid; do
    [ -f "$f" ] || continue
    [ -f "${f%/pid}/rc" ] && continue
    p="$(cat -- "$f")"
    [ -n "$p" ] || continue
    pids="$pids $p"
    { kill -TERM -- "-$p"; kill_tree "$p" TERM; } 2>/dev/null
  done
  if [ -n "$pids" ]; then
    sleep 1
    for p in $pids; do { kill -KILL -- "-$p"; kill_tree "$p" KILL; } 2>/dev/null; done
  fi
  rm -rf "$WORK"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# Discovery. SUITE_PATH is indexed by slot (the selected-suite position, in discovery order).
discovered=0
skipped=0
n=0
SUITE_PATH=()
POOL_SLOTS=()
SERIAL_SLOTS=()
for t in .claude/hooks/tests/*.test.sh \
         .claude/scripts/tests/*.test.sh \
         .github/scripts/tests/*.test.sh \
         desk/tests/*.test.sh; do
  discovered=$((discovered + 1))
  if ! is_selected "$t"; then
    skipped=$((skipped + 1))
    continue
  fi
  SUITE_PATH[n]="$t"
  if grep -Fxq -- "$t" <<<"$SERIAL_GROUP"; then
    SERIAL_SLOTS[${#SERIAL_SLOTS[@]}]="$n"
  else
    POOL_SLOTS[${#POOL_SLOTS[@]}]="$n"
  fi
  n=$((n + 1))
done
total=$n

# run_suite <slot> <path>: runs in a background subshell. Parse-checks the suite, runs it with
# its own TMPDIR and stdin closed, and records the exit code last (its presence means "finished").
run_suite() {
  local slot="$1" t="$2" d="$WORK/$1" rc=0 syn=""
  mkdir -p "$d/tmp" || { printf '%s\n' 70 > "$d/rc"; return 0; }
  if syn="$(bash -n "$t" 2>&1)"; then
    TMPDIR="$d/tmp" bash "$t" </dev/null >"$d/out" 2>&1 || rc=$?
  else
    rc=2
    printf "ERROR: %s does not parse — \`bash -n\` rejected it, so the suite never ran:\n%s\n" \
      "$t" "$syn" >"$d/out"
  fi
  printf '%s\n' "$rc" > "$d/rc.tmp" && mv "$d/rc.tmp" "$d/rc"
}

# kill_tree <pid> <signal>: signals a process's descendants first, then the process itself.
# Walks pgrep -P, so it works even where job control could not give the job its own group.
kill_tree() {
  local c
  for c in $(pgrep -P "$1" 2>/dev/null); do kill_tree "$c" "$2"; done
  kill "-$2" "$1" 2>/dev/null
  return 0
}

# kill_group <pid>: TERM, a grace second, then KILL the job's whole process group and tree.
# Job control gives each background job its own group, so the suite's children die with it.
kill_group() {
  {
    kill -TERM -- "-$1"
    kill_tree "$1" TERM
    sleep 1
    kill -KILL -- "-$1"
    kill_tree "$1" KILL
  } 2>/dev/null
  return 0
}

# start_suite <slot>: launches one suite in its own process group; sets LAUNCHED_PID. The
# subshell's stderr is discarded: the suite's own output is captured to its out file, and
# bash's "child setpgid" notice (no controlling terminal) is job-control noise, not a result.
start_suite() {
  mkdir -p "$WORK/$1" || return 1
  set -m
  ( run_suite "$1" "${SUITE_PATH[$1]}" ) 2>/dev/null &
  LAUNCHED_PID=$!
  set +m
  printf '%s\n' "$LAUNCHED_PID" > "$WORK/$1/pid"
}

# run_pool <concurrency> <slot...>: keeps at most <concurrency> suites running until every given
# slot has an rc file. A suite past the timeout is killed and recorded as rc 124.
run_pool() {
  local conc="$1"; shift
  local -a queue=("$@")
  local nq="$#" next=0
  local -a act_slot=() act_pid=() act_start=()
  local -a keep_slot=() keep_pid=() keep_start=()
  local k i p s now
  while :; do
    now="$(date +%s)"
    keep_slot=(); keep_pid=(); keep_start=()
    k=0
    while [ "$k" -lt "${#act_slot[@]}" ]; do
      i="${act_slot[$k]}"; p="${act_pid[$k]}"; s="${act_start[$k]}"
      k=$((k + 1))
      if [ -f "$WORK/$i/rc" ]; then
        wait "$p" 2>/dev/null
        continue
      fi
      if [ $((now - s)) -ge "$SUITE_TIMEOUT" ]; then
        kill_group "$p"
        wait "$p" 2>/dev/null
        printf 'ERROR: %s exceeded the per-suite timeout (%ss) and was killed\n' \
          "${SUITE_PATH[$i]}" "$SUITE_TIMEOUT" >> "$WORK/$i/out"
        printf '%s\n' 124 > "$WORK/$i/rc"
        continue
      fi
      keep_slot[${#keep_slot[@]}]="$i"
      keep_pid[${#keep_pid[@]}]="$p"
      keep_start[${#keep_start[@]}]="$s"
    done
    act_slot=(${keep_slot[@]+"${keep_slot[@]}"})
    act_pid=(${keep_pid[@]+"${keep_pid[@]}"})
    act_start=(${keep_start[@]+"${keep_start[@]}"})

    while [ "${#act_slot[@]}" -lt "$conc" ] && [ "$next" -lt "$nq" ]; do
      i="${queue[$next]}"
      start_suite "$i" || { echo "::error::run-hook-tests.sh: cannot start suite slot $i" >&2; exit 70; }
      act_slot[${#act_slot[@]}]="$i"
      act_pid[${#act_pid[@]}]="$LAUNCHED_PID"
      act_start[${#act_start[@]}]="$(date +%s)"
      next=$((next + 1))
    done

    [ "${#act_slot[@]}" -gt 0 ] || break
    sleep 0.2
  done
}

# The pool first (bounded concurrency), then the serial group one at a time.
run_pool "$JOBS" ${POOL_SLOTS[@]+"${POOL_SLOTS[@]}"}
run_pool 1 ${SERIAL_SLOTS[@]+"${SERIAL_SLOTS[@]}"}

failed=0
FAILED_LIST=""
RELEVANT=""
slot=0
while [ "$slot" -lt "$total" ]; do
  t="${SUITE_PATH[$slot]}"
  d="$WORK/$slot"
  rc="$(cat -- "$d/rc" 2>/dev/null)"
  [ -n "$rc" ] || rc=70
  SUITE_OUT="$d/out"
  slot=$((slot + 1))

  # The full capture always reaches the log, pass or fail, in both modes.
  {
    printf '===== %s (rc=%s) =====\n' "$t" "$rc"
    cat "$SUITE_OUT" 2>/dev/null
    printf '\n'
  } >> "$LOG"

  if [ "$rc" -eq 0 ]; then
    if [ "$JSON" -eq 0 ]; then
      printf '::group::%s\n' "$t"
      cat "$SUITE_OUT" 2>/dev/null
      printf 'PASS: %s\n' "$t"
      printf '::endgroup::\n'
    fi
  else
    # Failures print in full in BOTH modes — compaction never hides a red test.
    if [ "$JSON" -eq 0 ]; then
      printf '::group::%s\n' "$t"
      cat "$SUITE_OUT" 2>/dev/null
      printf '::endgroup::\n'
      printf '::error::FAIL (rc=%s): %s\n' "$rc" "$t"
    else
      {
        printf '::group::FAIL %s (rc=%s)\n' "$t" "$rc"
        cat "$SUITE_OUT" 2>/dev/null
        printf '::endgroup::\n'
      } >&2
    fi
    failed=$((failed + 1))
    FAILED_LIST="${FAILED_LIST}${t}"$'\n'
    # relevant_error: the decisive line(s) from THIS suite's capture only —
    # anchored so a suite's own "FAIL:" tally lines are picked up but ordinary
    # prose mentioning "fail" is not. Scanning the aggregate log instead would
    # attribute another suite's lines to this one.
    RELEVANT="${RELEVANT}$(awk -v s="$t" '
        /^(FAIL|ERROR|not ok)/ || /AssertionError/ || /^::error::/ || / line [0-9]+: / {
          print s ": " $0
          if (++n >= 3) exit
        }' "$SUITE_OUT" 2>/dev/null)"$'\n'
  fi
done

if [ "$SELECT_MODE" -eq 0 ]; then
  say "$(printf '\nDiscovered and ran %s bash test suite(s); %s failed.\nFull output: %s' "$total" "$failed" "$LOG")"
elif [ "$total" -eq 0 ]; then
  say "$(printf '\nNo bash test suites selected (%s); none run, %s discovered.\nFull output: %s' "$SEL_REASON" "$discovered" "$LOG")"
else
  say "$(printf '\nSelected and ran %s of %s bash test suite(s) (%s); %s failed.\nFull output: %s' "$total" "$discovered" "$SEL_REASON" "$failed" "$LOG")"
fi

# Fail loud if discovery found nothing — a silently-empty run must never pass
# green and masquerade as "all tests passed" (issue #681). Judged on discovery,
# not the selection: an empty selection is a legitimate, explained zero-run.
if [ "$discovered" -eq 0 ]; then
  if [ "$JSON" -eq 1 ]; then
    jq -cn --arg log "$LOG" \
      '{ok: false, failed_tests: [], relevant_error: "run-hook-tests.sh discovered no test suites — a glob is broken", log_path: $log, total: 0, failed: 0}'
  fi
  echo "::error::run-hook-tests.sh discovered no test suites — a glob is broken" >&2
  exit 3
fi

if [ "$JSON" -eq 1 ]; then
  # Cap per the contract — relevant_error indexes the failure, log_path holds it all.
  RELEVANT="$(printf '%s' "$RELEVANT" | sed '/^$/d' \
    | awk 'NR <= 20 { print } NR == 21 { print "… (truncated; see log_path)"; exit }' | cut -c1-2000)"
  # A suite can fail without printing any recognized marker (e.g. a bare non-zero
  # exit). Naming it is still better than a null error.
  [ -n "$RELEVANT" ] || RELEVANT="$(printf '%s' "$FAILED_LIST" | sed '/^$/d' | sed 's/^/failed suite: /' | head -n 20)"
  # Selection fields appear only when --only-file was given; without it the shape is unchanged.
  EXTRA_JSON='{}'
  if [ "$SELECT_MODE" -eq 1 ]; then
    EXTRA_JSON="$(jq -cn --arg r "$SEL_REASON" --argjson d "$discovered" --argjson s "$skipped" \
      '{selection: $r, discovered: $d, skipped: $s}')"
  fi
  jq -cn \
    --argjson ok "$( [ "$failed" -eq 0 ] && echo true || echo false )" \
    --arg failed_list "$FAILED_LIST" \
    --arg relevant "$RELEVANT" \
    --arg log "$LOG" \
    --argjson total "$total" \
    --argjson failed "$failed" \
    --argjson extra "$EXTRA_JSON" \
    '{ok: $ok,
      failed_tests: ($failed_list | split("\n") | map(select(length > 0))),
      relevant_error: (if $relevant == "" then null else $relevant end),
      log_path: $log, total: $total, failed: $failed} + $extra'
fi

[ "$failed" -eq 0 ]
