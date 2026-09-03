#!/usr/bin/env bash
# overrun-check.sh ET clock under a missing-tzdata system (issue #1529).
#
# WHY THIS SUITE EXISTS
#
# overrun-check.sh renders wall clocks under column headers that say "Start (ET)"
# / "Projected end (ET)", and a breach alert that spells " ET" into its text. It
# reached those renderings through a fallback chain that trusted `date`'s exit
# code:
#
#   TZ='America/New_York' date -j -f %s … ||   # BSD
#   TZ='America/New_York' date -d @…    || …   # GNU  <-- the silent one
#
# On glibc with no tzdata installed, `TZ='America/New_York'` does NOT fail. libc
# silently falls back to UTC and `date -d` exits 0, so the second alternative
# prints a UTC time in 12-hour form with no marker — a four- or five-hour error
# under a header that asserts Eastern. PR #1522's own cross-platform run hit this
# in a container without tzdata; only that suite's pinned strings caught it, and
# nothing in the production path would have.
#
# HOW THE ENVIRONMENT IS SIMULATED
#
# Deleting tzdata is not available to a test, and TZDIR is honoured by glibc but
# not by BSD libc, so neither reproduces on both platforms. Instead a `date` shim
# is prepended to PATH that reproduces the LIBC BEHAVIOUR directly and is
# therefore platform-independent:
#
#   - `TZ='America/New_York' date +%z`  ->  "+0000", exit 0   (zone unresolved)
#   - any other TZ='America/New_York' call  ->  re-run with TZ=UTC (so it
#     renders a UTC clock in whatever format was asked for — the actual bug)
#   - everything else  ->  delegated unchanged to the real date binary
#
# The real binary's absolute path is baked into the shim at creation time. It is
# NOT looked up with `command -v` at call time: the shim's own directory is on
# PATH by then, so that would resolve to the shim and recurse forever.
#
# WHAT IS ASSERTED
#
#   1. Cell mode under the shim renders a LABELLED UTC value and no 12-hour
#      meridiem, so no row ever shows an unlabelled UTC clock under an (ET)
#      header. — AC1
#   2. The breach alert under the shim labels both of its clocks (revised finish
#      and the window-blown cut suggestion) as UTC, never "… ET" over a UTC
#      time. That alert is where the mislabel is literally spelled out. — AC2
#   3. NEGATIVE CONTROL: the identical inputs WITHOUT the shim still render the
#      pinned Eastern strings. Without this the suite could pass by breaking ET
#      everywhere. — AC3
#   4. SHIM FIDELITY CONTROL: under the shim, the pre-fix expression is shown to
#      emit an unlabelled 12-hour UTC time. If this stops reproducing, the shim
#      no longer simulates the bug and assertions 1-2 have gone vacuous.
#
# Run from anywhere: bash .claude/scripts/tests/overrun-check-tzdata.test.sh
set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)" || { echo "cannot resolve repo root" >&2; exit 1; }
OVERRUN="$REPO_ROOT/.claude/scripts/overrun-check.sh"
cd "$REPO_ROOT" || { echo "cannot cd to repo root" >&2; exit 1; }

TMP="$(mktemp -d)"
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

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
check_lacks() {
  local desc="$1" needle="$2" haystack="$3"
  if [[ "$haystack" != *"$needle"* ]]; then
    PASS=$((PASS + 1)); echo "ok   — $desc"
  else
    FAIL=$((FAIL + 1)); echo "FAIL — $desc (output must not contain '$needle': '$haystack')"
  fi
}

# ---------------------------------------------------------------------------
# The shim. REAL_DATE is resolved BEFORE $TMP/bin joins PATH.
# ---------------------------------------------------------------------------
REAL_DATE="$(command -v date)" || { echo "no date binary on PATH" >&2; exit 1; }
case "$REAL_DATE" in
  /*) : ;;
  *) echo "date resolved to a non-absolute path: $REAL_DATE" >&2; exit 1 ;;
esac

mkdir -p "$TMP/bin"
cat > "$TMP/bin/date" <<SHIM_EOF
#!/usr/bin/env bash
# Simulates a system whose tzdata lacks America/New_York: the zone does not
# resolve, libc falls back to UTC, and date still exits 0.
if [ "\${TZ:-}" = "America/New_York" ]; then
  if [ "\${1:-}" = "+%z" ]; then printf '+0000\n'; exit 0; fi
  export TZ=UTC
fi
exec "$REAL_DATE" "\$@"
SHIM_EOF
chmod +x "$TMP/bin/date"

# Confirm the shim is what it claims before relying on it.
check_eq "shim: reports +0000 for America/New_York" "+0000" \
  "$(TZ='America/New_York' PATH="$TMP/bin:$PATH" date +%z)"
check_eq "shim: leaves an unrelated zone alone" \
  "$(TZ=UTC "$REAL_DATE" +%z)" "$(TZ=UTC PATH="$TMP/bin:$PATH" date +%z)"

# ---------------------------------------------------------------------------
# Fixed clocks — 2026-09-01 is EDT (UTC-4), so ET and UTC are unmistakably
# different and a mislabel cannot hide behind a coincidence.
# ---------------------------------------------------------------------------
START='2026-09-01T16:00:50Z'        # 12:00:50 PM ET / 16:00:50 UTC
ON_TRACK_NOW='2026-09-01T16:45:50Z' # 45 min in, bound 90
OVERRUN_NOW='2026-09-01T17:52:50Z'  # 112 min in — past the bound, breach fires
BOUND=90

NOW_EPOCH=$("$REAL_DATE" -u -j -f '%Y-%m-%dT%H:%M:%SZ' "$OVERRUN_NOW" '+%s' 2>/dev/null \
  || "$REAL_DATE" -u -d "$OVERRUN_NOW" '+%s' 2>/dev/null) \
  || { echo "cannot compute the fixed epoch" >&2; exit 1; }
# Deadline sits 10 min out while the revised finish is 30 min out, so the
# window-blown cut suggestion (the second " ET" site) is always exercised.
WINDOW_DEADLINE=$((NOW_EPOCH + 600))

RC=0
OUT=""
ERR=""
# run_overrun <shim|noshim> <args...>
run_overrun() {
  local mode="$1"; shift
  local home="$TMP/home-$mode"
  mkdir -p "$home/.claude"
  local path="$PATH"
  [[ "$mode" == "shim" ]] && path="$TMP/bin:$PATH"
  RC=0
  OUT=$(HOME="$home" PATH="$path" bash "$OVERRUN" "$@" 2>"$TMP/err") || RC=$?
  ERR=$(cat "$TMP/err")
}

cell() { printf '%s\n' "$2" | cut -f"$1"; }

echo "=== 1. Cell mode on a system where Eastern does not resolve (AC1) ==="

run_overrun shim --readout-cells --pr 1529 --bound-min "$BOUND" \
  --started-at "$START" --now "$ON_TRACK_NOW"
check_eq "no-tzdata cell mode: still exits 0" "0" "$RC"
check_eq "no-tzdata cell mode: start cell is labelled UTC" \
  "16:00 UTC" "$(cell 1 "$OUT")"
check_eq "no-tzdata cell mode: projected-end cell is labelled UTC" \
  "17:30 UTC" "$(cell 2 "$OUT")"
# The bug's signature is a 12-hour clock with no zone marker. Meridiem is the
# tell: the labelled UTC branch is 24-hour and never carries AM/PM.
check_lacks "no-tzdata cell mode: never renders a bare 12-hour clock (AM)" "AM" "$OUT"
check_lacks "no-tzdata cell mode: never renders a bare 12-hour clock (PM)" "PM" "$OUT"
check_eq "no-tzdata cell mode: third cell is untouched by the zone guard" \
  "45 min" "$(cell 3 "$OUT")"
check_eq "no-tzdata cell mode: writes nothing to stderr" "" "$ERR"

echo
echo "=== 2. Breach alert, where ' ET' is spelled into the text (AC2) ==="

run_overrun shim --pr 1529 --repo test/repo --bound-min "$BOUND" \
  --started-at "$START" --now "$OVERRUN_NOW" --window-deadline "$WINDOW_DEADLINE"
check_eq "no-tzdata breach: still reports first breach (exit 1)" "1" "$RC"
check_contains "no-tzdata breach: revised finish is labelled UTC" \
  "revised finish ~18:22 UTC" "$OUT"
check_contains "no-tzdata breach: window-blown clock is labelled UTC" \
  "window blown (18:02 UTC)" "$OUT"
# The whole point of the issue: the suffix must never sit on a UTC clock.
check_lacks "no-tzdata breach: never labels a UTC clock as ET (PM ET)" "PM ET" "$OUT"
check_lacks "no-tzdata breach: never labels a UTC clock as ET (AM ET)" "AM ET" "$OUT"

echo
echo "=== 3. NEGATIVE CONTROL — unchanged where Eastern resolves (AC3) ==="

# If this half stops passing, the guard has broken ET on healthy systems, and
# assertions 1-2 would be "passing" only because ET never renders at all.
#
# It pins Eastern strings, so it can only run where the HOST resolves
# America/New_York — which is exactly what a tzdata-less container does not do,
# and this suite is meant to be honest about that environment rather than red in
# it. Probe the unshimmed host for the fixed date's offset first (2026-09-01 is
# EDT, -0400) and skip loudly if Eastern is unavailable. The skip is counted and
# reported so it can never look like a silent pass; sections 1, 2 and 4 use the
# shim and are unaffected either way.
SKIPPED=0
HOST_OFF=$(TZ='America/New_York' "$REAL_DATE" -j -f '%s' "$NOW_EPOCH" +'%z' 2>/dev/null \
  || TZ='America/New_York' "$REAL_DATE" -d "@$NOW_EPOCH" +'%z' 2>/dev/null) || HOST_OFF=""

if [[ "$HOST_OFF" != "-0400" ]]; then
  SKIPPED=$((SKIPPED + 1))
  echo "SKIP — host does not resolve America/New_York for 2026-09-01 (offset '${HOST_OFF:-none}',"
  echo "       expected -0400). The healthy-zone control cannot run here; this is the very"
  echo "       environment issue #1529 is about, so it is reported, not failed."
else
  run_overrun noshim --readout-cells --pr 1529 --bound-min "$BOUND" \
    --started-at "$START" --now "$ON_TRACK_NOW"
  check_eq "control: cell mode still renders the pinned Eastern row" \
    "12:00 PM	1:30 PM	45 min" "$OUT"

  run_overrun noshim --pr 1529 --repo test/repo --bound-min "$BOUND" \
    --started-at "$START" --now "$OVERRUN_NOW" --window-deadline "$WINDOW_DEADLINE"
  check_eq "control: breach still reports first breach (exit 1)" "1" "$RC"
  check_contains "control: revised finish still renders Eastern with its suffix" \
    "revised finish ~2:22 PM ET" "$OUT"
  check_contains "control: window-blown clock still renders Eastern" \
    "window blown (2:02 PM ET)" "$OUT"
  check_lacks "control: healthy system never falls back to the UTC label" "UTC" "$OUT"
fi

echo
echo "=== 4. SHIM FIDELITY CONTROL — the shim really does reproduce the bug ==="

# Rebuild the pre-fix expression and run it under the shim. It must produce an
# unlabelled 12-hour UTC time — the exact defect. If this stops reproducing, the
# simulation has drifted and sections 1-2 prove nothing.
PREFIX_OUT=$(PATH="$TMP/bin:$PATH" bash -c '
  epoch="$1"
  TZ="America/New_York" date -j -f "%s" "$epoch" +"%-I:%M %p" 2>/dev/null \
    || TZ="America/New_York" date -d "@$epoch" +"%-I:%M %p" 2>/dev/null \
    || printf "(unknown)"
' _ "$NOW_EPOCH")
check_eq "fidelity: pre-fix chain renders an unlabelled 12-hour UTC clock" \
  "5:52 PM" "$PREFIX_OUT"
check_lacks "fidelity: and it carries no zone marker at all" "UTC" "$PREFIX_OUT"

# The same expression WITHOUT the shim renders true Eastern — 4 hours apart.
# That gap is the size of the error the guard prevents. Host-dependent for the
# same reason as section 3, so it is skipped loudly rather than failed where
# Eastern is unavailable.
if [[ "$HOST_OFF" != "-0400" ]]; then
  SKIPPED=$((SKIPPED + 1))
  echo "SKIP — unshimmed Eastern rendering needs host tzdata (offset '${HOST_OFF:-none}')"
else
  PREFIX_ET=$(bash -c '
    epoch="$1"
    TZ="America/New_York" date -j -f "%s" "$epoch" +"%-I:%M %p" 2>/dev/null \
      || TZ="America/New_York" date -d "@$epoch" +"%-I:%M %p" 2>/dev/null \
      || printf "(unknown)"
  ' _ "$NOW_EPOCH")
  check_eq "fidelity: unshimmed, the same chain renders true Eastern" \
    "1:52 PM" "$PREFIX_ET"
fi

# Structural half: the production script must still consult the guard before
# every ET rendering, and must not have regrown a bare ET chain.
if grep -q 'et_zone_available' "$OVERRUN"; then
  PASS=$((PASS + 1)); echo "ok   — production script still carries the zone guard"
else
  FAIL=$((FAIL + 1)); echo "FAIL — production script no longer carries the zone guard"
fi
# Exactly three America/New_York call sites may exist: the +%z probe inside
# et_zone_available, and the BSD and GNU arms inside format_et_clock. A fourth
# means a bare chain has regrown somewhere outside the guard.
SITES=$(grep -c "TZ='America/New_York' date" "$OVERRUN")
check_eq "no America/New_York call site exists outside the two guarded helpers" \
  "3" "$SITES"
# …and both breach-alert clocks must reach ET through the formatter, not inline.
check_eq "breach alert routes its revised finish through the guarded formatter" \
  "1" "$(grep -c 'REVISED_FINISH_ET=$(format_et_clock' "$OVERRUN")"
check_eq "cut suggestion routes its window clock through the guarded formatter" \
  "1" "$(grep -c 'WINDOW_END_ET=$(format_et_clock' "$OVERRUN")"

echo
if [[ "$SKIPPED" -gt 0 ]]; then
  echo "overrun-check-tzdata.test.sh: $PASS passed, $FAIL failed, $SKIPPED host-dependent control(s) skipped"
else
  echo "overrun-check-tzdata.test.sh: $PASS passed, $FAIL failed"
fi
[[ "$FAIL" -eq 0 ]]
