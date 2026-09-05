#!/usr/bin/env bash
# overrun-check.sh --readout-cells: the "Running now" table cells (issue #1512).
# catalog: tests — Tests `overrun-check.sh --readout-cells` — ET cell rendering, the pace-scaled overrun row, and the negative control proving the projected finish is floored at now
#
# Cell mode emits ONE tab-separated line — start ET, projected end ET, and either
# the remaining duration or an overrun marker — for a single pipeline row. Every
# case here pins BOTH --started-at and --now to fixed ISO-8601 values, so the
# clocks are deterministic regardless of when or where the suite runs (the script
# forces TZ='America/New_York' itself; 2026-09-01 is EDT, UTC-4).
#
# Three things this suite exists to hold:
#
#   1. Projected end is NEVER a clock time in the past. Truncating the pace-scaled
#      revised total to whole minutes can land it a hair behind the wall clock in
#      the first seconds past the bound, so cell mode floors it at --now. The
#      NEGATIVE CONTROL rebuilds the unclamped form and proves it renders a
#      past ETA — without it the clamp assertions would pass vacuously.
#   2. --readout output stays byte-for-byte what it was. Cell mode shares the
#      epoch-parsing block with it, so a regression there is one edit away.
#   3. The two modes share one degradation contract: an unparseable or future
#      start prints nothing and exits 0 in BOTH.
#
# Run from repo root: bash .claude/scripts/tests/overrun-check.test.sh
set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
OVERRUN="$REPO_ROOT/.claude/scripts/overrun-check.sh"
cd "$REPO_ROOT" || { echo "cannot cd to repo root" >&2; exit 1; }

TMP="$(mktemp -d)"
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

# Fixed clocks. START is at :50 seconds on purpose — the past-ETA edge only
# becomes VISIBLE at minute granularity when the sub-minute truncation crosses a
# minute boundary, which a :00-second start would hide.
START='2026-09-01T16:00:50Z'          # 12:00:50 PM ET
ON_TRACK_NOW='2026-09-01T16:45:50Z'   #  12:45:50 PM ET — 45 min in, bound 90
EDGE_NOW='2026-09-01T17:31:00Z'       #   1:31:00 PM ET — 10 s past the bound
OVERRUN_NOW='2026-09-01T17:52:50Z'    #   1:52:50 PM ET — 22 min past the bound
BOUND=90

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
check_ne() {
  local desc="$1" forbidden="$2" actual="$3"
  if [[ "$actual" != "$forbidden" ]]; then
    PASS=$((PASS + 1)); echo "ok   — $desc"
  else
    FAIL=$((FAIL + 1)); echo "FAIL — $desc (value is '$forbidden', which it must not be)"
  fi
}

run_capture() {  # run_capture <command...> — stdout in OUT, stderr in ERR, rc in RC
  OUT="$("$@" 2>"$TMP/stderr")"
  RC=$?
  ERR="$(cat "$TMP/stderr")"
}

cell() {  # cell <n> <line> — nth tab-separated field, without IFS read (which
          # collapses empty fields and shifts the rest)
  printf '%s\n' "$2" | cut -f"$1"
}

# =============================================================================
# 1. On-track row: start + bound is the projected end, remaining counts down.
# =============================================================================
run_capture bash "$OVERRUN" --readout-cells --pr 1512 --bound-min "$BOUND" \
  --started-at "$START" --now "$ON_TRACK_NOW"
check_eq "on-track: exits 0" "0" "$RC"
check_eq "on-track: start cell is the ET launch clock" "12:00 PM" "$(cell 1 "$OUT")"
check_eq "on-track: projected end is start + bound" "1:30 PM" "$(cell 2 "$OUT")"
check_eq "on-track: remaining is bound - elapsed" "45 min" "$(cell 3 "$OUT")"
check_eq "on-track: emits exactly three tab-separated fields" "3" \
  "$(printf '%s\n' "$OUT" | awk -F'\t' '{print NF}')"
check_eq "on-track: emits exactly one line" "1" "$(printf '%s\n' "$OUT" | wc -l | tr -d ' ')"

# At launch the row must show the FULL planning bound as remaining, and start +
# bound as the projected end — the shape the table renders the instant a
# pipeline is spawned.
run_capture bash "$OVERRUN" --readout-cells --pr 1512 --bound-min "$BOUND" \
  --started-at "$START" --now "$START"
check_eq "at launch: projected end is start + bound" "1:30 PM" "$(cell 2 "$OUT")"
check_eq "at launch: remaining is the full planning bound" "1.5 h" "$(cell 3 "$OUT")"

# =============================================================================
# 2. Overrun row: revised finish in the future + the overrun marker.
# =============================================================================
run_capture bash "$OVERRUN" --readout-cells --pr 1512 --bound-min "$BOUND" \
  --started-at "$START" --now "$OVERRUN_NOW"
check_eq "overrun: exits 0" "0" "$RC"
check_eq "overrun: start cell is unchanged from the on-track tick" "12:00 PM" "$(cell 1 "$OUT")"
check_contains "overrun: third cell is the overrun marker" "over plan" "$OUT"
check_eq "overrun: marker names the minutes past plan" "+22 min over plan" "$(cell 3 "$OUT")"
# Pace-scaled revised finish: elapsed 112 min against a 90 min bound projects
# ~139 min total, i.e. ~2:19 PM ET — comfortably ahead of the 1:52 PM "now".
check_eq "overrun: projected end is the pace-scaled revised finish" "2:19 PM" "$(cell 2 "$OUT")"
check_ne "overrun: projected end is not the stale start + bound ETA" "1:30 PM" "$(cell 2 "$OUT")"

# =============================================================================
# 3. Past-ETA edge — the reason the projected finish is floored at --now.
#    10 s past the bound: the truncated revised total lands at 1:30:50 PM while
#    the clock already reads 1:31 PM.
# =============================================================================
run_capture bash "$OVERRUN" --readout-cells --pr 1512 --bound-min "$BOUND" \
  --started-at "$START" --now "$EDGE_NOW"
check_eq "past-ETA edge: exits 0" "0" "$RC"
check_eq "past-ETA edge: projected end is floored at now, never behind it" \
  "1:31 PM" "$(cell 2 "$OUT")"
check_ne "past-ETA edge: projected end is not the pre-clamp past clock" \
  "1:30 PM" "$(cell 2 "$OUT")"
check_contains "past-ETA edge: still reports the overrun form" "over plan" "$OUT"
# 10 s past the bound truncates to zero whole minutes. Pin the exact cell: a bare
# "contains over plan" passes just as happily on "+0 min over plan", which reads
# as on-plan while the row is in the overrun branch.
check_eq "past-ETA edge: sub-minute overrun is not rounded down to +0 min" \
  "+<1 min over plan" "$(cell 3 "$OUT")"
check_ne "past-ETA edge: never renders a zero-minute overrun" \
  "+0 min over plan" "$(cell 3 "$OUT")"

# ---- NEGATIVE CONTROL -------------------------------------------------------
# Half one, portable: the production script must still carry the floor.
if grep -qF '(( PROJECTED_EPOCH < READOUT_NOW )) && PROJECTED_EPOCH="$READOUT_NOW"' "$OVERRUN"; then
  PASS=$((PASS + 1)); echo "ok   — negative control: production script still floors the projected end at now"
else
  FAIL=$((FAIL + 1)); echo "FAIL — negative control: production script no longer floors the projected end at now"
fi

# Half two: rebuild the unclamped form and assert it DOES render a past ETA. If
# this half stops reproducing, the edge case above has gone vacuous and the
# assertions no longer prove the clamp is load-bearing.
NOCLAMP="$TMP/overrun-check-noclamp.sh"
grep -v 'PROJECTED_EPOCH < READOUT_NOW' "$OVERRUN" > "$NOCLAMP"
if grep -q 'PROJECTED_EPOCH=\$(( READOUT_START + REVISED \* 60 ))' "$NOCLAMP" && \
   ! grep -q 'PROJECTED_EPOCH < READOUT_NOW' "$NOCLAMP"; then
  PASS=$((PASS + 1)); echo "ok   — negative control: rebuilt the unclamped form"
else
  FAIL=$((FAIL + 1)); echo "FAIL — negative control: could not rebuild the unclamped form"
fi
run_capture bash "$NOCLAMP" --readout-cells --pr 1512 --bound-min "$BOUND" \
  --started-at "$START" --now "$EDGE_NOW"
check_eq "negative control: unclamped form renders an ETA one minute in the past" \
  "1:30 PM" "$(cell 2 "$OUT")"

# =============================================================================
# 4. Degradation contract — shared with --readout.
# =============================================================================
run_capture bash "$OVERRUN" --readout-cells --pr 1512 --bound-min "$BOUND" \
  --started-at '2026-09-01T18:00:00Z' --now "$ON_TRACK_NOW"
check_eq "future start: exits 0" "0" "$RC"
check_eq "future start: prints nothing so the caller renders an em dash" "" "$OUT"

run_capture bash "$OVERRUN" --readout-cells --pr 1512 --bound-min "$BOUND" \
  --started-at 'not-a-timestamp' --now "$ON_TRACK_NOW"
check_eq "unparseable start: exits 0" "0" "$RC"
check_eq "unparseable start: prints nothing" "" "$OUT"

run_capture bash "$OVERRUN" --readout --readout-cells --pr 1512 --bound-min "$BOUND" \
  --started-at "$START" --now "$ON_TRACK_NOW"
check_eq "both modes at once: usage error, not a silently-picked shape" "3" "$RC"
check_contains "both modes at once: names the conflict" "mutually exclusive" "$ERR"
check_eq "both modes at once: prints nothing on stdout" "" "$OUT"

# =============================================================================
# 5. --readout is untouched by the new mode.
# =============================================================================
run_capture bash "$OVERRUN" --readout --pr 1512 --bound-min "$BOUND" \
  --started-at "$START" --now "$ON_TRACK_NOW"
check_eq "readout: on-track line is unchanged" \
  "Est 1.5 h · 45 min elapsed · on track — likely done in ~45 min" "$OUT"
run_capture bash "$OVERRUN" --readout --pr 1512 --bound-min "$BOUND" \
  --started-at "$START" --now "$OVERRUN_NOW"
check_eq "readout: running-slow line is unchanged" \
  "Est 1.5 h · 1.9 h elapsed · running slow — revised finish ~2.3 h total" "$OUT"
run_capture bash "$OVERRUN" --readout --pr 1512 --bound-min "$BOUND" \
  --started-at "$START" --now "$START"
check_contains "readout: still emits no tab-separated cells" "on track" "$OUT"
check_eq "readout: is a single field, not a cell row" "1" \
  "$(printf '%s\n' "$OUT" | awk -F'\t' '{print NF}')"

# =============================================================================
# 6. Cell mode does not require --pr.
#    During Phase A the pipeline has a started_at (issue-keyed) but no PR yet.
#    Cell mode is pure computation and exits before any session-state I/O, so
#    demanding a PR blanked the row for exactly those pipelines: the launch
#    table showed real clocks, then every later heartbeat tick rendered em
#    dashes. The breach path DOES key session state by PR, so it still requires
#    one.
# =============================================================================
run_capture bash "$OVERRUN" --readout-cells --bound-min "$BOUND" \
  --started-at "$START" --now "$ON_TRACK_NOW"
check_eq "no --pr: cell mode exits 0" "0" "$RC"
check_eq "no --pr: renders the same three cells as the --pr call" \
  "12:00 PM	1:30 PM	45 min" "$OUT"

# The heartbeat passes "$PR_NUM" unquoted-empty during Phase A — the exact shape
# BugBot flagged. An empty value must behave like an absent one, not like a
# malformed one.
run_capture bash "$OVERRUN" --readout-cells --pr "" --bound-min "$BOUND" \
  --started-at "$START" --now "$ON_TRACK_NOW"
check_eq "empty --pr: cell mode exits 0" "0" "$RC"
check_eq "empty --pr: still renders clocks, never an empty row" \
  "12:00 PM	1:30 PM	45 min" "$OUT"

run_capture bash "$OVERRUN" --readout --bound-min "$BOUND" \
  --started-at "$START" --now "$ON_TRACK_NOW"
check_eq "no --pr: --readout mode is equally PR-free" "0" "$RC"
check_contains "no --pr: --readout still emits its line" "on track" "$OUT"

# Guard both halves of the narrowing: the breach path must still demand a PR,
# and a malformed PR must still be rejected wherever it is supplied.
run_capture bash "$OVERRUN" --bound-min "$BOUND" --started-at "$START"
check_eq "breach mode without --pr: still a usage error" "3" "$RC"
check_contains "breach mode without --pr: names --pr" "--pr" "$ERR"
run_capture bash "$OVERRUN" --readout-cells --pr abc --bound-min "$BOUND" \
  --started-at "$START"
check_eq "malformed --pr: still rejected in cell mode" "3" "$RC"
check_contains "malformed --pr: names the integer requirement" \
  "positive integer" "$ERR"

echo
echo "overrun-check.test.sh: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
