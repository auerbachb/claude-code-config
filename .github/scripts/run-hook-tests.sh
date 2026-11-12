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
#   bash .github/scripts/run-hook-tests.sh --shard <i>/<n>      # run only shard i of n (issue #2207)
#   bash .github/scripts/run-hook-tests.sh --timing-file <path> # also write per-suite seconds as TSV (advisory)
#   bash .github/scripts/run-hook-tests.sh --list               # print the suites it would run, no run
#   bash .github/scripts/run-hook-tests.sh --help
#
# --shard i/n (issue #2207): the pool and the serial group (after --only-file) are each split by
# weight: suites in descending weight go greedily to the currently lightest shard. Weights come
# from .github/hook-test-weights.tsv (override: HOOK_TEST_WEIGHTS_FILE; an absent or empty file
# gives every suite the same default weight). The n shards together run each selected suite
# exactly once. --shard 1/1 is the default and keeps discovery order.
#
# --timing-file <path> (issue #2207): writes one <seconds><TAB><pool|serial><TAB><path> row per
# suite. Advisory: it never changes the exit status and is not written by --list.
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
#  - desk/tests/*: the offline suites assert that a command finished within 1-2 s (no
#    connection attempt, hq_t_elapsed_under) or that a deadline stopped a call within 2.9 s.
#    Under pool load those wall-clock bounds become false failures, so they run alone.
#  - .claude/scripts/tests/local-review.test.sh and worktree-isolation-shapes.test.sh: use
#    1-3 s --timeout / --interval bounds as the behaviour under test.
#  - .github/scripts/tests/scripts-catalog-gen.test.sh: its real-repo check runs the generator
#    --check against the live checkout; with other suites in flight the first call reported
#    drift and the second, in the same job, reported none (CI run 42969745313). It must not
#    overlap a suite that touches the shared tree.
#  - .claude/scripts/tests/pr-state-stdout.test.sh: counts /tmp/pr-state-7-* entries, and
#    pr-state.sh writes its output under a fixed /tmp prefix, not TMPDIR, so a concurrent
#    suite that runs pr-state.sh for the same PR number would change the count.
#  - Wall-clock bounds of 10 s or less (issue #2200 review): a suite that measures an elapsed time
#    against a limit of 10 s or less, or runs a subprocess under a 10 s or shorter deadline, reports
#    a false failure when the pool is loaded. Covered: pause-lifecycle-hooks (lock contention under
#    5 s), ai-account-session-start (hook latency under 1 s), bounded-run (a 4 s bound inside 7 s),
#    help-output (--help returns inside 10 s), the 2-10 s subprocess deadlines in ac-checkboxes,
#    ai-account-ledger, estimate-log/rounds-bash, park-wake-publish, pmm-pre-dispatch,
#    register-hooks, spend-telemetry-maintenance, spend-telemetry-tracker and workspace-sweep, and
#    the 1-5 s desk deadlines in capture-offline, drilldown-offline, migrate, psql-bindings and
#    psql-discovery. Lock-timeout environment knobs are not deadline assertions and stay pooled.
#  - Per-entry review (issue #2207): .claude/reference/hook-test-serial-group.md records, for each
#    entry, the reason it stays serial and what must change before it can return to the pool.
SERIAL_GROUP="
.claude/hooks/tests/silence-detector-time-dedupe.test.sh
.claude/hooks/tests/session-start-sync-publish-bounds.test.sh
.github/scripts/tests/scripts-catalog-gen.test.sh
.claude/scripts/tests/pr-state-stdout.test.sh
.claude/scripts/tests/local-review.test.sh
.claude/scripts/tests/worktree-isolation-shapes.test.sh
desk/tests/cli.test.sh
desk/tests/checkin-offline.test.sh
desk/tests/desk-offline.test.sh
desk/tests/export-offline.test.sh
desk/tests/ideas-offline.test.sh
desk/tests/interrupts-offline.test.sh
desk/tests/items-cli.test.sh
desk/tests/lifecycle-cli.test.sh
desk/tests/longform-offline.test.sh
desk/tests/plan-offline.test.sh
desk/tests/question-leak-warn.test.sh
desk/tests/report-offline.test.sh
desk/tests/reviews-cli.test.sh
desk/tests/reviews-view-offline.test.sh
desk/tests/todo-offline.test.sh
.claude/hooks/tests/pause-lifecycle-hooks.test.sh
.claude/hooks/tests/ai-account-session-start.test.sh
.claude/hooks/tests/register-hooks.test.sh
.claude/hooks/tests/spend-telemetry-maintenance.test.sh
.claude/hooks/tests/spend-telemetry-tracker.test.sh
.claude/scripts/tests/bounded-run.test.sh
.claude/scripts/tests/help-output.test.sh
.claude/scripts/tests/ac-checkboxes.test.sh
.claude/scripts/tests/ai-account-ledger.test.sh
.claude/scripts/tests/estimate-log-locks-bash.test.sh
.claude/scripts/tests/estimate-rounds-batch-bash.test.sh
.claude/scripts/tests/park-wake-publish.test.sh
.claude/scripts/tests/pmm-pre-dispatch.test.sh
.claude/scripts/tests/workspace-sweep.test.sh
desk/tests/capture-offline.test.sh
desk/tests/drilldown-offline.test.sh
desk/tests/migrate.test.sh
desk/tests/psql-bindings.test.sh
desk/tests/psql-discovery.test.sh
"

JSON=0
ONLY_FILE=""
ONLY_FILE_GIVEN=0   # distinguishes "--only-file given (maybe empty)" from "not given"
JOBS_ARG=""
JOBS_GIVEN=0        # distinguishes "--jobs given (maybe empty)" from "not given"
SHARD_ARG=""
SHARD_GIVEN=0       # distinguishes "--shard given (maybe empty)" from "not given"
LIST_ONLY=0
TIMING_FILE=""      # --timing-file <path>: advisory per-suite TSV (issue #2207)
TIMING_FILE_GIVEN=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --json) JSON=1; shift ;;
    --list) LIST_ONLY=1; shift ;;
    --timing-file)
      [ "$#" -ge 2 ] || { echo "::error::run-hook-tests.sh: --timing-file needs a path" >&2; exit 2; }
      TIMING_FILE="$2"; TIMING_FILE_GIVEN=1; shift 2
      ;;
    --shard)
      [ "$#" -ge 2 ] || { echo "::error::run-hook-tests.sh: --shard needs i/n" >&2; exit 2; }
      SHARD_ARG="$2"; SHARD_GIVEN=1; shift 2
      ;;
    --only-file)
      [ "$#" -ge 2 ] || { echo "::error::run-hook-tests.sh: --only-file needs a path" >&2; exit 2; }
      ONLY_FILE="$2"; ONLY_FILE_GIVEN=1; shift 2
      ;;
    --jobs)
      [ "$#" -ge 2 ] || { echo "::error::run-hook-tests.sh: --jobs needs a count" >&2; exit 2; }
      JOBS_ARG="$2"; JOBS_GIVEN=1; shift 2
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

# An explicitly empty --timing-file path is a usage error, never a silent no-export.
if [ "$TIMING_FILE_GIVEN" -eq 1 ] && [ -z "$TIMING_FILE" ]; then
  echo "::error::run-hook-tests.sh: --timing-file was given an empty path" >&2
  exit 2
fi

# Concurrency and per-suite timeout. A positive integer or a usage error: a typo must never
# silently fall back to a different concurrency or an unbounded wait.
is_positive_int() { case "$1" in ''|*[!0-9]*) return 1 ;; esac; [ "$1" -ge 1 ]; }
if [ "$JOBS_GIVEN" -eq 1 ]; then
  JOBS="$JOBS_ARG"
  is_positive_int "$JOBS" || { echo "::error::run-hook-tests.sh: --jobs must be a positive integer, got: '$JOBS'" >&2; exit 2; }
elif [ -n "${HOOK_TEST_JOBS+x}" ]; then
  # Set but empty counts as set: an empty override is a typo, not a request for the default.
  JOBS="$HOOK_TEST_JOBS"
  is_positive_int "$JOBS" || { echo "::error::run-hook-tests.sh: HOOK_TEST_JOBS must be a positive integer, got: '$JOBS'" >&2; exit 2; }
else
  JOBS="$(getconf _NPROCESSORS_ONLN 2>/dev/null || true)"
  is_positive_int "$JOBS" || JOBS=2
fi
SUITE_TIMEOUT="${HOOK_TEST_SUITE_TIMEOUT:-900}"
is_positive_int "$SUITE_TIMEOUT" || { echo "::error::run-hook-tests.sh: HOOK_TEST_SUITE_TIMEOUT must be a positive integer of seconds: $SUITE_TIMEOUT" >&2; exit 2; }

# --shard i/n (issue #2207): run only shard i of n. Default 1/1 is the whole selection in
# discovery order, exactly as before. For n > 1 the selected suites (pool and serial alike) are
# sorted with LC_ALL=C and shard i takes every n-th entry starting at position i, so the shards
# partition the selection: each suite runs in exactly one shard.
SHARD_I=1
SHARD_N=1
if [ "$SHARD_GIVEN" -eq 1 ]; then
  case "$SHARD_ARG" in
    */*)
      SHARD_I="${SHARD_ARG%%/*}"
      SHARD_N="${SHARD_ARG#*/}"
      ;;
    *) SHARD_N=0 ;;
  esac
  is_positive_int "$SHARD_N" && is_positive_int "$SHARD_I" && [ "$SHARD_I" -le "$SHARD_N" ] ||
    { echo "::error::run-hook-tests.sh: --shard must be i/n with 1 <= i <= n, got: '$SHARD_ARG'" >&2; exit 2; }
  # Force decimal: a leading zero (08/10) would otherwise be read as octal by the arithmetic below.
  SHARD_I=$((10#$SHARD_I))
  SHARD_N=$((10#$SHARD_N))
fi

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
# A signal that lands while a suite is being launched (between the fork and the pid-file write)
# is held until that suite's pid is recorded, so cleanup always sees every live suite.
LAUNCHING=0
PENDING_SIGNAL=""
on_signal() {
  if [ "$LAUNCHING" -eq 1 ]; then PENDING_SIGNAL="$1"; return 0; fi
  exit "$1"
}
trap 'on_signal 130' INT
trap 'on_signal 143' TERM

# Discovery. SUITE_PATH is indexed by slot (the selected-suite position, in discovery order).
discovered=0
skipped=0
n=0
SUITE_PATH=()
POOL_SLOTS=()
SERIAL_SLOTS=()
SEL_LIST=""
POOL_SEL=""
SERIAL_SEL=""
for t in .claude/hooks/tests/*.test.sh \
         .claude/scripts/tests/*.test.sh \
         .github/scripts/tests/*.test.sh \
         desk/tests/*.test.sh; do
  discovered=$((discovered + 1))
  if ! is_selected "$t"; then
    skipped=$((skipped + 1))
    continue
  fi
  SEL_LIST="${SEL_LIST}${t}"$'\n'
  if grep -Fxq -- "$t" <<<"$SERIAL_GROUP"; then
    SERIAL_SEL="${SERIAL_SEL}${t}"$'\n'
  else
    POOL_SEL="${POOL_SEL}${t}"$'\n'
  fi
done
# Sharded runs split the pool and the serial group SEPARATELY, each by weight (issue #2207
# follow-up). Suites are taken in descending weight (ties by LC_ALL=C path order) and each goes to
# the currently lightest shard (ties to the lowest index). Weights come from WEIGHTS_FILE, one
# "<seconds><TAB><path>" row per suite; a suite missing from it gets the median weight of the file
# (1 when the file has no rows). The assignment is a pure function of (list, weights file), so every
# shard computes the same partition. Shard 1/1 keeps discovery order and is unchanged.
WEIGHTS_FILE="${HOOK_TEST_WEIGHTS_FILE-.github/hook-test-weights.tsv}"

# weighted_slice <shard> <count> <quiet>: reads the sorted suite list on stdin, prints the paths
# assigned to <shard>, sorted with LC_ALL=C. A malformed or repeated weights row is ignored; the
# warning goes to stderr once per run (only the pool call, quiet=0, prints it). Exits non-zero (and
# prints nothing) if the assignment loses a suite.
weighted_slice() {
  LC_ALL=C awk -v SHARD="$1" -v NSH="$2" -v QUIET="$3" -v WFILE="$WEIGHTS_FILE" '
    function before(a, b) { return WT[a] > WT[b] || (WT[a] == WT[b] && P[a] < P[b]) }
    BEGIN {
      nw = 0; bad = 0
      while ((getline line < WFILE) > 0) {
        if (line ~ /^#/ || line ~ /^[ \t]*$/) continue
        nf = split(line, f, "\t")
        if (nf != 2 || f[1] !~ /^[0-9]+(\.[0-9]+)?$/ || f[2] == "" || (f[2] in W)) { bad++; continue }
        W[f[2]] = f[1] + 0
        nw++; V[nw] = f[1] + 0
      }
      close(WFILE)
      if (bad > 0 && QUIET + 0 == 0) printf "run-hook-tests.sh: ignored %d malformed or repeated row(s) in %s\n", bad, WFILE > "/dev/stderr"
      for (i = 2; i <= nw; i++) {
        v = V[i]; j = i - 1
        while (j >= 1 && V[j] > v) { V[j + 1] = V[j]; j-- }
        V[j + 1] = v
      }
      if (nw == 0) def = 1
      else if (nw % 2 == 1) def = V[(nw + 1) / 2]
      else def = (V[nw / 2] + V[nw / 2 + 1]) / 2
      nl = 0
    }
    $0 != "" { nl++; P[nl] = $0; WT[nl] = ($0 in W) ? W[$0] : def }
    END {
      for (i = 1; i <= nl; i++) ORD[i] = i
      for (i = 2; i <= nl; i++) {
        x = ORD[i]; j = i - 1
        while (j >= 1 && before(x, ORD[j])) { ORD[j + 1] = ORD[j]; j-- }
        ORD[j + 1] = x
      }
      for (s = 1; s <= NSH; s++) LOAD[s] = 0
      for (i = 1; i <= nl; i++) {
        x = ORD[i]; best = 1
        for (s = 2; s <= NSH; s++) if (LOAD[s] < LOAD[best]) best = s
        LOAD[best] += (WT[x] < 1 ? 1 : WT[x]); OWN[x] = best
      }
      lost = 0
      for (i = 1; i <= nl; i++) if (!(i in OWN)) lost++
      if (lost > 0) { printf "run-hook-tests.sh: weighted split lost %d suite(s); refusing a partial shard\n", lost > "/dev/stderr"; exit 2 }
      for (i = 1; i <= nl; i++) if (OWN[i] == SHARD + 0) print P[i]
    }' | LC_ALL=C sort
}
if [ "$SHARD_N" -gt 1 ]; then
  # Fail closed: a sort that fails or drops lines would leave this shard with a short list, and a
  # runner that skipped suites would still exit 0. Sort each list on its own, check the status
  # and the line count against the unsorted list, and only then assign.
  count_lines() { printf '%s\n' "$1" | grep -c . || true; }
  if [ -e "$WEIGHTS_FILE" ] && { [ ! -f "$WEIGHTS_FILE" ] || [ ! -r "$WEIGHTS_FILE" ]; }; then
    echo "run-hook-tests: weights file is not a readable regular file: $WEIGHTS_FILE" >&2
    exit 2
  fi
  POOL_SORTED="$(printf '%s' "$POOL_SEL" | LC_ALL=C sort)" \
    || { echo "run-hook-tests: cannot sort the pool list for --shard" >&2; exit 2; }
  SERIAL_SORTED="$(printf '%s' "$SERIAL_SEL" | LC_ALL=C sort)" \
    || { echo "run-hook-tests: cannot sort the serial list for --shard" >&2; exit 2; }
  if [ "$(count_lines "$POOL_SORTED")" != "$(count_lines "$POOL_SEL")" ] \
     || [ "$(count_lines "$SERIAL_SORTED")" != "$(count_lines "$SERIAL_SEL")" ]; then
    echo "run-hook-tests: sorted suite list lost entries; refusing to run a partial shard" >&2
    exit 2
  fi
  POOL_SHARD="$(printf '%s\n' "$POOL_SORTED" | weighted_slice "$SHARD_I" "$SHARD_N" 0)" \
    || { echo "run-hook-tests: cannot assign the pool list to shard $SHARD_I/$SHARD_N" >&2; exit 2; }
  SERIAL_SHARD="$(printf '%s\n' "$SERIAL_SORTED" | weighted_slice "$SHARD_I" "$SHARD_N" 1)" \
    || { echo "run-hook-tests: cannot assign the serial list to shard $SHARD_I/$SHARD_N" >&2; exit 2; }
  SEL_LIST="$POOL_SHARD"$'\n'"$SERIAL_SHARD"$'\n'
fi
while IFS= read -r t; do
  [ -n "$t" ] || continue
  SUITE_PATH[n]="$t"
  if grep -Fxq -- "$t" <<<"$SERIAL_GROUP"; then
    SERIAL_SLOTS[${#SERIAL_SLOTS[@]}]="$n"
  else
    POOL_SLOTS[${#POOL_SLOTS[@]}]="$n"
  fi
  n=$((n + 1))
done <<<"$SEL_LIST"
total=$n

# --list (issue #2207): print the suites this invocation would run, pool first then serial, one
# "<kind> <path>" line each, and exit without running anything. The shard test uses it.
# With --json, stdout stays pure JSON: one {"pool":[...],"serial":[...]} object instead.
if [ "$LIST_ONLY" -eq 1 ]; then
  LIST_LINES="$(
    for s in ${POOL_SLOTS[@]+"${POOL_SLOTS[@]}"}; do printf 'pool %s\n' "${SUITE_PATH[$s]}"; done
    for s in ${SERIAL_SLOTS[@]+"${SERIAL_SLOTS[@]}"}; do printf 'serial %s\n' "${SUITE_PATH[$s]}"; done
  )"
  if [ "$JSON" -eq 1 ]; then
    printf '%s' "$LIST_LINES" | jq -Rnc '
      [inputs | select(length > 0) | capture("^(?<kind>pool|serial) (?<path>.*)$")]
      | {pool: [.[] | select(.kind == "pool") | .path], serial: [.[] | select(.kind == "serial") | .path]}' \
      || { echo "run-hook-tests: cannot render the suite list as JSON" >&2; exit 2; }
  elif [ -n "$LIST_LINES" ]; then
    printf '%s\n' "$LIST_LINES"
  fi
  exit 0
fi

# run_suite <slot> <path>: runs in a background subshell. Parse-checks the suite, runs it with
# its own TMPDIR and stdin closed, and records the exit code last (its presence means "finished").
run_suite() {
  local slot="$1" t="$2" d="$WORK/$1" rc=0 syn="" t0 t1
  mkdir -p "$d/tmp" || { printf '%s\n' 70 > "$d/rc"; return 0; }
  t0="$(date +%s)"
  if syn="$(bash -n "$t" 2>&1)"; then
    TMPDIR="$d/tmp" bash "$t" </dev/null >"$d/out" 2>&1 || rc=$?
  else
    rc=2
    printf "ERROR: %s does not parse — \`bash -n\` rejected it, so the suite never ran:\n%s\n" \
      "$t" "$syn" >"$d/out"
  fi
  t1="$(date +%s)"
  # Wall-clock seconds for this suite (issue #2207 timing table). Written before the rc marker,
  # so a finished slot always has its timing.
  printf '%s %s\n' "$t0" "$t1" > "$d/time"
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
  LAUNCHING=1
  set -m
  ( run_suite "$1" "${SUITE_PATH[$1]}" ) 2>/dev/null &
  LAUNCHED_PID=$!
  set +m
  printf '%s\n' "$LAUNCHED_PID" > "$WORK/$1/pid"
  LAUNCHING=0
  if [ -n "$PENDING_SIGNAL" ]; then exit "$PENDING_SIGNAL"; fi
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
        # Record the elapsed time the timing table needs, in the same format run_suite writes.
        printf '%s %s\n' "$s" "$(date +%s)" > "$WORK/$i/time"
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
RUN_T0="$(date +%s)"
run_pool "$JOBS" ${POOL_SLOTS[@]+"${POOL_SLOTS[@]}"}
POOL_T1="$(date +%s)"
run_pool 1 ${SERIAL_SLOTS[@]+"${SERIAL_SLOTS[@]}"}
RUN_T1="$(date +%s)"

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

# Timing table (issue #2207): per-suite wall seconds, the pool and serial-group totals, and the
# effective concurrency each phase reached. The same text lands in the log file, so a CI run's
# captured output carries its own measurements. Advisory: it never changes the exit status.
if [ "$total" -gt 0 ]; then
  TIMING_TSV="$WORK/timing.tsv"
  : > "$TIMING_TSV"
  slot=0
  while [ "$slot" -lt "$total" ]; do
    t="${SUITE_PATH[$slot]}"
    kind=pool
    if grep -Fxq -- "$t" <<<"$SERIAL_GROUP"; then kind=serial; fi
    t0=""; t1=""
    if [ -f "$WORK/$slot/time" ]; then read -r t0 t1 < "$WORK/$slot/time"; fi
    [ -n "$t0" ] && [ -n "$t1" ] || { t0=0; t1=0; }
    printf '%s\t%s\t%s\n' "$((t1 - t0))" "$kind" "$t" >> "$TIMING_TSV"
    slot=$((slot + 1))
  done
  POOL_WALL=$((POOL_T1 - RUN_T0))
  SERIAL_WALL=$((RUN_T1 - POOL_T1))
  TOTAL_WALL=$((RUN_T1 - RUN_T0))
  CPUS="$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo unknown)"
  timing_report="$(printf '\n[CONCURRENCY] pool jobs=%s cpus=%s runner=%s/%s\n' "$JOBS" "$CPUS" "$(uname -s)" "$(uname -m)")"
  timing_report="${timing_report}"$'\n'"$(awk -F'\t' -v pw="$POOL_WALL" -v sw="$SERIAL_WALL" -v tw="$TOTAL_WALL" -v jobs="$JOBS" '
      $2 == "pool"   { pn++; ps += $1 }
      $2 == "serial" { sn++; ss += $1 }
      END {
        printf "[TIMING] wall=%ss (pool %ss + serial %ss)\n", tw, pw, sw
        printf "[TIMING] pool: %d suites, sum %ss, effective concurrency %.2f of %s jobs\n", pn + 0, ps + 0, (pw > 0 ? ps / pw : 0), jobs
        printf "[TIMING] serial: %d suites, sum %ss\n", sn + 0, ss + 0
      }' "$TIMING_TSV")"
  timing_report="${timing_report}"$'\n'"[TIMING] slowest 30 suites:"$'\n'"$(sort -t$'\t' -k1,1nr "$TIMING_TSV" | head -n 30 \
    | awk -F'\t' '{ printf "  %5ss  %-6s  %s\n", $1, $2, $3 }')"
  say "$timing_report"
  printf '%s\n' "$timing_report" >> "$LOG"
  # Every suite's row, not only the slowest 30, so one full run yields the whole table (issue #2207).
  { printf '[TIMING] all %s suites, seconds<TAB>kind<TAB>path:\n' "$total"; cat "$TIMING_TSV"; } >> "$LOG"
fi

# --timing-file <path> (issue #2207): the same per-suite rows as TSV, <seconds>\t<pool|serial>\t<path>,
# in discovery order. Advisory: a write failure is a warning and never changes the exit status.
if [ "$TIMING_FILE_GIVEN" -eq 1 ]; then
  if [ -f "$WORK/timing.tsv" ]; then TIMING_SRC="$WORK/timing.tsv"; else TIMING_SRC="/dev/null"; fi
  cp -- "$TIMING_SRC" "$TIMING_FILE" 2>/dev/null \
    || echo "::warning::run-hook-tests.sh: cannot write --timing-file: $TIMING_FILE" >&2
fi

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
