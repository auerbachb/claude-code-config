#!/usr/bin/env bash
# bounded-run.test.sh — Offline tests for lib/bounded-run.sh, the shared
# wall-clock bound extracted in issue #1404 from repo-root.sh (issue #1363).
#
# The library is the one definition four scripts now rely on to never hang, so
# this suite locks its contract directly rather than only through its consumers:
# a fast command comes back with its REAL status and no timeout flag, a wedged
# one is killed at the bound with 124, the kill reaches the whole process group,
# a bad bound override falls back to the default instead of vanishing, and the
# file refuses to be executed rather than sourced.
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

echo
echo "Results: $PASS passed, $FAIL failed"
if (( FAIL > 0 )); then
  echo "FAILED: lib/bounded-run.sh"
  exit 1
fi
echo "OK: lib/bounded-run.sh — shared wall-clock bound (issues #1363, #1404)"
