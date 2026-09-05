#!/usr/bin/env bash
# bounded-run.test.sh — Offline tests for lib/bounded-run.sh, the shared
# wall-clock bound extracted in issue #1404 from repo-root.sh (issue #1363).
# catalog: tests — Tests `lib/bounded-run.sh` — real exit status on the healthy path, 124 at the bound, the process-group kill, a late finisher's own status (failures included) rather than a false timeout, `normalize_bound` fallbacks, the source-only guard, and `kill_child`'s `ps`/`tr` guards keeping a missing helper off a caller's stderr contract
#
# The library is the one definition four scripts now rely on to never hang, so
# this suite locks its contract directly rather than only through its consumers:
# a fast command comes back with its REAL status and no timeout flag, a wedged
# one is killed at the bound with 124, the kill reaches the whole process group,
# a bad bound override falls back to the default instead of vanishing, and the
# file refuses to be executed rather than sourced — and, since the extraction
# left ONE copy of kill_child where there were two, that its `ps`/`tr` guards
# keep a missing helper from narrating over a consumer's stderr contract (T11,
# issues #1435/#1474).
#
# T5 is the negative control: the same stall, started WITHOUT the bound, is
# still running when the bounded call had already returned. Without it T4 could
# pass against a command that simply exits quickly on its own.
#
# Requires bash. Run from repo root: bash .claude/scripts/tests/bounded-run.test.sh
set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
LIB="$REPO_ROOT/.claude/scripts/lib/bounded-run.sh"

TMP="$(mktemp -d)"
cleanup() {
  # Anything a stall stub left behind dies with the suite, so a failing
  # process-group test cannot leak sleepers into the runner.
  pkill -f "$TMP/stub-sleeper" >/dev/null 2>&1 || true
  pkill -f "$TMP/stub-wedged" >/dev/null 2>&1 || true
  rm -rf "$TMP"
}
trap cleanup EXIT

PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); echo "ok   — $1"; }
fail() { FAIL=$((FAIL + 1)); echo "FAIL — $1"; }

check_eq() {
  local desc="$1" want="$2" got="$3"
  if [[ "$want" == "$got" ]]; then pass "$desc"; else fail "$desc (want '$want', got '$got')"; fi
}

check_contains() {
  local desc="$1" needle="$2" haystack="$3"
  if [[ "$haystack" == *"$needle"* ]]; then pass "$desc"; else fail "$desc (missing '$needle' in: $haystack)"; fi
}

CAPTURE="$TMP/capture"
CAPTURE_ERR="$TMP/capture-err"
: > "$CAPTURE"
: > "$CAPTURE_ERR"

# shellcheck source=../lib/bounded-run.sh
source "$LIB"

# ---- T1: a fast command returns its REAL exit status, no timeout -----------
RC=0
run_bounded 5 bash -c 'exit 7' || RC=$?
check_eq "T1 a fast command's real exit status is returned" "7" "$RC"
check_eq "T1b and no timeout is reported" "0" "$BOUNDED_TIMED_OUT"

RC=0
run_bounded 5 printf 'hello\n' || RC=$?
check_eq "T2 a successful command returns 0" "0" "$RC"
check_eq "T2b stdout lands in \$CAPTURE" "hello" "$(cat "$CAPTURE")"
RC=0
run_bounded 5 bash -c 'echo boom >&2; exit 3' || RC=$?
check_eq "T2c stderr lands in \$CAPTURE_ERR" "boom" "$(cat "$CAPTURE_ERR")"
check_eq "T2d and the status still comes back" "3" "$RC"

# ---- T3: BOUNDED_REQUIRE_OUTPUT does not affect the healthy path -----------
# The flag only ever decides whether a LATE-but-complete child is trusted; a
# child that finishes inside the bound must be unaffected by it.
BOUNDED_REQUIRE_OUTPUT=1
RC=0
run_bounded 5 true || RC=$?
check_eq "T3 an empty-output success is still a success inside the bound" "0" "$RC"
check_eq "T3b and still not a timeout" "0" "$BOUNDED_TIMED_OUT"
BOUNDED_REQUIRE_OUTPUT=0

# ---- T4: a wedged command is killed at the bound, 124 ----------------------
# The stub spawns a descendant that keeps ticking, so T6 can tell "we killed the
# process group" from "we killed one pid and walked away".
TICK_FILE="$TMP/tick"
export TICK_FILE
cat > "$TMP/stub-sleeper" <<'EOF'
#!/usr/bin/env bash
# Self-limited (~10s) so a failing process-group kill cannot leave a sleeper
# behind for the rest of the run.
for _ in $(seq 1 50); do
  printf 'tick\n' >> "$TICK_FILE"
  sleep 0.2
done
EOF
chmod +x "$TMP/stub-sleeper"

cat > "$TMP/waller" <<EOF
#!/usr/bin/env bash
"$TMP/stub-sleeper" &
sleep 30
EOF
chmod +x "$TMP/waller"

# A 3s bound, not 1s: \`date +%s\` is whole-second, so an N-second bound trips
# anywhere in (N-1, N] of real time — at N=1 the kill can land before the
# descendant has even been exec'd, and T6 would measure nothing.
: > "$TICK_FILE"
START="$(date +%s)"
RC=0
run_bounded 3 "$TMP/waller" || RC=$?
ELAPSED=$(( $(date +%s) - START ))
check_eq "T4 a wedged command returns 124" "124" "$RC"
check_eq "T4b and sets BOUNDED_TIMED_OUT" "1" "$BOUNDED_TIMED_OUT"
check_eq "T4c and not the clock-unreadable diagnosis" "0" "$BOUNDED_CLOCK_UNREADABLE"
if (( ELAPSED < 15 )); then
  pass "T4d returned in ${ELAPSED}s, well inside the bound + grace"
else
  fail "T4d took ${ELAPSED}s — the bound did not hold"
fi

# ---- T5: negative control — the same stall really outlives the bound -------
# If the wedged command exited on its own inside 3s, T4 would pass without any
# bound at all. Start it unbounded and prove it is still running at the moment
# the bounded call had already returned.
"$TMP/waller" >/dev/null 2>&1 &
UNBOUNDED_PID=$!
sleep 4
if kill -0 "$UNBOUNDED_PID" 2>/dev/null; then
  pass "T5 control: unbounded, the same command is still running after 4s"
else
  fail "T5 control: the command exited on its own — T4 proved nothing"
fi
kill -- -"$UNBOUNDED_PID" 2>/dev/null || kill "$UNBOUNDED_PID" 2>/dev/null || true
pkill -f "$TMP/stub-sleeper" >/dev/null 2>&1 || true

# ---- T6: the kill reaches the whole process group --------------------------
# T4's sleeper self-limits at 50 ticks (~10s) and T4 returned in ~4s, so the
# sample below sits strictly INSIDE its natural life: 0 ticks means it never
# started, 50 means it had already finished on its own — either would make the
# comparison pass vacuously.
: > "$TICK_FILE"
START="$(date +%s)"
RC=0
run_bounded 3 "$TMP/waller" || RC=$?
BEFORE="$(wc -l < "$TICK_FILE" | tr -d ' ')"
if (( BEFORE > 0 && BEFORE < 50 )); then
  pass "T6 descendant sampled mid-life (${BEFORE}/50 ticks), so T6b is a live check"
else
  fail "T6 descendant at ${BEFORE}/50 ticks — outside its life, T6b would pass vacuously"
fi
sleep 2
AFTER="$(wc -l < "$TICK_FILE" | tr -d ' ')"
check_eq "T6b descendants of the killed child stop ticking too" "$BEFORE" "$AFTER"

# ---- T7: normalize_bound never yields "no bound" ---------------------------
check_eq "T7 a plain value passes through" "5" "$(normalize_bound 5 10)"
check_eq "T7b empty falls back to the default" "10" "$(normalize_bound "" 10)"
check_eq "T7c non-numeric falls back to the default" "10" "$(normalize_bound abc 10)"
check_eq "T7d zero falls back to the default" "10" "$(normalize_bound 0 10)"
check_eq "T7e a leading-zero value is read as decimal, not octal" "9" "$(normalize_bound 09 10)"
check_eq "T7f and 010 means ten, not eight" "10" "$(normalize_bound 010 4)"

# ---- T8: the library refuses to be executed --------------------------------
RC=0
OUT="$(bash "$LIB" 2>&1)" || RC=$?
check_eq "T8 executing the library directly exits 2" "2" "$RC"
check_contains "T8b and says to source it instead" "source this file" "$OUT"

# ---- T9: every consumer ships the library beside it -------------------------
# The four scripts source it by a path relative to their own location, so a
# consumer that moved without it would fail at run time, not here. Cheap
# structural check that the file is where they all look for it.
if [[ -r "$REPO_ROOT/.claude/scripts/lib/bounded-run.sh" ]]; then
  pass "T9 the library sits at .claude/scripts/lib/bounded-run.sh"
else
  fail "T9 the library is not where its consumers source it from"
fi
for consumer in repo-root.sh dirty-main-guard.sh stale-cleanup.sh admin-merge.sh; do
  if grep -q 'lib/bounded-run.sh' "$REPO_ROOT/.claude/scripts/$consumer"; then
    pass "T9b $consumer sources the shared bound"
  else
    fail "T9b $consumer does not reference lib/bounded-run.sh"
  fi
done

# ---- T10: a late child's real FAILURE status survives the trip --------------
# The exception for a child that finished around the trip used to be gated on a
# ZERO status, so an ordinary git failure landing a moment before the bound came
# back as 124: dirty-main-guard would announce "the repo is not answering" for a
# plain error, and git's own stderr diagnostic was thrown away with it.
#
# Deterministic by construction rather than by racing the clock. The stub clock
# below is CAUSAL, not timed: it reads the same instant until the child says it
# is ready, then jumps past the bound. So the trip provably lands after the
# child is up with its TERM handler installed — a plain "make the clock
# unreadable" trip fires on the first pass instead, often before the child has
# even been exec'd, and measures the kill rather than the late completion.
#
# The child then ignores that TERM and exits 3 on its own, so at the decision
# point the status is genuinely the child's and not our kill's.
TERM_FILE="$TMP/termed"
READY_FILE="$TMP/ready"
: > "$TERM_FILE"
rm -f "$READY_FILE"
cat > "$TMP/stub-late-failure" <<EOF
#!/usr/bin/env bash
trap "echo x >> '$TERM_FILE'" TERM
echo late-failure-diagnostic >&2
: > '$READY_FILE'
sleep 1
exit 3
EOF
chmod +x "$TMP/stub-late-failure"

# now_epoch calls \`date\`; a shell function shadows the binary for the duration.
date() {
  if [[ -e "$READY_FILE" ]]; then printf '%s' 1999; else printf '%s' 1000; fi
}
RC=0
run_bounded 3 "$TMP/stub-late-failure" || RC=$?
unset -f date

check_eq "T10 a child that failed on its own reports its real status, not 124" "3" "$RC"
check_eq "T10b and it is not reported as a timeout" "0" "$BOUNDED_TIMED_OUT"
# check_contains, not check_eq: the stub's own shell also reports the `sleep` it
# lost to the process-group TERM. What matters is that the child's diagnostic is
# still there to hand back — under the old gate the whole capture was discarded.
check_contains "T10c and its stderr diagnostic survives" "late-failure-diagnostic" "$(cat "$CAPTURE_ERR")"
# Non-vacuity control: if the bound never tripped, T10 would be testing the
# ordinary fast path (T1 already covers that) and would prove nothing about the
# late-completion branch. The TERM receipt is the proof that it did trip.
if [[ -s "$TERM_FILE" ]]; then
  pass "T10d control: the bound really tripped and signalled the child"
else
  fail "T10d control: no TERM was delivered, so T10 never reached the late-completion branch"
fi
# The guard in the other direction — a child that our kill really did stop must
# still read as a timeout — is T4: its stub dies from the signal (143) and comes
# back 124.

# ---- T11: kill_child's ps/tr absence degrades QUIETLY -----------------------
# kill_child shells out to `ps` and `tr` for the pgid lookup and both carry their
# own `2>/dev/null`. Losing a guard costs nothing functionally — the lookup comes
# back empty, the group kill is skipped, and the builtin single-pid `kill` still
# stops the child — but the SHELL narrates `command not found` on the CALLER's
# stderr, and every consumer here documents a one-line-on-failure stderr contract
# (repo-root.sh exit 3, dirty-main-guard exit 2, stale-cleanup's per-item
# `failed:`). That leak is issue #1435, and suppressing it is why the guards
# exist.
#
# Issue #1474: until now the guards were pinned only through ONE consumer, end to
# end (repo-root.test.sh T16m). This library is the single definition all four
# share, so its own suite is where the guard belongs — otherwise a consumer that
# stops sourcing the lib, or a fixture that drifts, silently takes the only
# coverage with it, and the other three go back to leaking.
#
# The bound has to trip for kill_child to run at all, so every case asserts 124
# as well as the stderr count. The status was never the bug — this is the
# documented degradation narrating instead of staying quiet — and the two
# controls (all-present, ps-absent) are what make a failure here specifically the
# tr guard coming off rather than the harness breaking.
KILL_FIXT="$TMP/kill-nohelp"
KILL_TICKS="$TMP/kill-ticks"
KILL_STDERR=""
KILL_LINES=0
KILL_RC=0

# The wedged child leaves liveness evidence as it goes: it ticks every 0.2s and
# self-limits at 60 ticks (~12s), which outlives the 3s bound and its grace and
# reap windows — so "it stopped ticking" below is the kill's doing, not the
# stub's own exit — while still guaranteeing nothing leaks into the rest of the
# run. `printf` is a builtin, so the stub needs only `sleep` from the fixture.
cat > "$TMP/stub-wedged" <<'EOF'
#!/usr/bin/env bash
for ((i = 0; i < 60; i++)); do
  printf 'tick\n' >> "$KILL_TICKS"
  sleep 0.2
done
EOF
chmod +x "$TMP/stub-wedged"

# The bounded call has to happen in a shell whose ENTIRE PATH is the fixture, so
# a dropped helper is missing exactly where kill_child looks for it. Sourcing the
# library there is also the honest shape — it is how all four consumers use it —
# and it puts kill_child's narration on this child's stderr, which is the stream
# a consumer's contract is written about.
cat > "$TMP/bounded-runner" <<EOF
#!/usr/bin/env bash
CAPTURE="\$1"
CAPTURE_ERR="\$2"
source "$LIB"
rc=0
run_bounded 3 "$TMP/stub-wedged" || rc=\$?
printf '%s' "\$rc"
EOF
chmod +x "$TMP/bounded-runner"

run_kill_case() { # helper to drop ("" = keep them all)
  local drop="$1" b path
  rm -rf "$KILL_FIXT"; mkdir -p "$KILL_FIXT"
  # Everything the library and the stub reach for by NAME. `kill`, `wait` and
  # `printf` are builtins and need no entry, and `mktemp` is unreachable because
  # BOUNDED_CAPTURE_TEMPLATE is unset here. `env` and `bash` are for the stub's
  # own shebang: without them it would never start and every case would be
  # measuring an exec failure instead of a timeout.
  for b in env bash date sleep ps tr; do
    path="$(command -v "$b" 2>/dev/null)" || continue
    ln -sf "$path" "$KILL_FIXT/$b"
  done
  [[ -n "$drop" ]] && rm -f "$KILL_FIXT/$drop"
  : > "$KILL_TICKS"
  KILL_RC="$(env -i HOME="$HOME" PATH="$KILL_FIXT" TMPDIR=/tmp \
    KILL_TICKS="$KILL_TICKS" bash "$TMP/bounded-runner" \
    "$TMP/kill-capture" "$TMP/kill-capture-err" 2>"$TMP/kill-stderr")"
  KILL_STDERR="$(cat "$TMP/kill-stderr")"
  KILL_LINES="$(printf '%s\n' "$KILL_STDERR" | grep -c .)"
}

run_kill_case "tr"
# Fixture control FIRST: the cases below say something only if `tr` is genuinely
# unreachable in that PATH and this shell says so out loud. Run the very pipeline
# an unguarded kill_child would run, in the same environment, and require the
# narration the guard exists to suppress — a fixture that still resolved `tr`
# would otherwise make T11b-T11c pass while proving nothing.
KILL_PROBE="$(env -i HOME="$HOME" PATH="$KILL_FIXT" TMPDIR=/tmp \
  bash -c 'ps -o pgid= -p $$ 2>/dev/null | tr -d "[:space:]"' 2>&1 >/dev/null)"
check_contains "T11 fixture control: an unguarded tr really does narrate here" \
  "command not found" "$KILL_PROBE"
check_eq "T11b a wedged child with tr absent still times out (124)" "124" "$KILL_RC"
if [[ "$KILL_LINES" -eq 0 ]]; then
  pass "T11c and the library narrates nothing onto the caller's stderr"
else
  fail "T11c the library leaked $KILL_LINES stderr line(s) into a caller's one-line contract: $KILL_STDERR"
fi
# Quiet must not mean broken: with tr absent the group kill is skipped BY DESIGN,
# so the single-pid kill is all that stops the child. Sampling mid-life (>0 and
# <60 ticks) is what keeps the "it stopped" check below honest — 0 ticks would
# mean the stub never ran and 60 that it had already finished on its own, and
# either would satisfy the check for the wrong reason.
KILL_BEFORE="$(wc -l < "$KILL_TICKS" | tr -d ' ')"
if (( KILL_BEFORE > 0 && KILL_BEFORE < 60 )); then
  pass "T11d the wedged child was sampled mid-life (${KILL_BEFORE}/60 ticks), so T11e is a live check"
else
  fail "T11d wedged child at ${KILL_BEFORE}/60 ticks — outside its life, T11e would pass vacuously"
fi
: > "$KILL_TICKS"
sleep 0.6
if (( $(wc -l < "$KILL_TICKS") == 0 )); then
  pass "T11e and the child really was stopped — the skipped group kill degrades quietly, not silently-broken"
else
  fail "T11e the child is still ticking — a missing tr cost the kill, not just the narration"
fi

run_kill_case ""
check_eq "T11f control: with every helper present, still 124" "124" "$KILL_RC"
check_eq "T11g control: with every helper present, still nothing on stderr" "0" "$KILL_LINES"

run_kill_case "ps"
check_eq "T11h control: a missing ps still times out (124)" "124" "$KILL_RC"
check_eq "T11i control: a missing ps still emits nothing on stderr" "0" "$KILL_LINES"

echo
echo "Results: $PASS passed, $FAIL failed"
if (( FAIL > 0 )); then
  echo "FAILED: lib/bounded-run.sh"
  exit 1
fi
echo "OK: lib/bounded-run.sh — shared wall-clock bound (issues #1363, #1404, #1435, #1474)"
