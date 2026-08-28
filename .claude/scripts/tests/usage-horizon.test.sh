#!/usr/bin/env bash
# usage-horizon.test.sh — coverage for .claude/scripts/usage-horizon.sh (issue #1427).
#
# Covers the acceptance-criteria matrix:
#   - threshold matrix, with and without a known limit
#   - hysteresis: worsening immediate, improving must clear the margin,
#     adjacent readings do not flap, a foreign session anchors nothing
#   - every fail-closed path -> STATUS=unknown with the unknown exit code
#   - observe-then-check round trip (jsonl append + session-state update)
#   - negative controls proving a missing helper, unreadable state, or a broken
#     jq can never yield `clear`, each PAIRED with a positive control proving
#     the same path does return `clear` when the reading is genuinely fine
#   - observation log mode 600 and single-generation rotation
#   - the comparison-only guarantee: no transcript read, no estimation path

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
SCRIPT="$ROOT/.claude/scripts/usage-horizon.sh"
SCRIPTS_DIR="$ROOT/.claude/scripts"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

PASS=0
FAILED=0

ok() { PASS=$((PASS + 1)); echo "ok   — $*"; }
bad() { FAILED=$((FAILED + 1)); echo "FAIL — $*" >&2; }

check_eq() { # <actual> <expected> <label>
  if [[ "$1" == "$2" ]]; then ok "$3"; else bad "$3 (got '$1', want '$2')"; fi
}

check_contains() { # <haystack> <needle> <label>
  case "$1" in
    *"$2"*) ok "$3" ;;
    *) bad "$3 (output did not contain '$2'): $1" ;;
  esac
}

# Every degraded path must land here: not clear, and not exit 0.
check_not_clear() { # <status> <rc> <label>
  if [[ "$1" != "clear" && "$2" != "0" ]]; then
    ok "$3"
  else
    bad "$3 (unknown/degraded path yielded status='$1' rc=$2 — a caller would read this as permission)"
  fi
}

# Path assertions as named helpers rather than `[[ ... ]] && ok || bad`: that
# idiom silently runs `bad` whenever `ok` returns non-zero.
check_absent() { # <path> <label>
  if [[ ! -e "$1" ]]; then ok "$2"; else bad "$2 (unexpectedly exists: $1)"; fi
}
check_present() { # <path> <label>
  if [[ -e "$1" ]]; then ok "$2"; else bad "$2 (missing: $1)"; fi
}

OUT=""
RC=0
run() { # run <args...> — populates OUT / RC; stderr lands in $TMP/stderr
  OUT="$("$SCRIPT" "$@" 2>"$TMP/stderr")"
  RC=$?
}

status_of() { printf '%s\n' "$OUT" | sed -n 's/^STATUS=//p'; }
reason_of() { printf '%s\n' "$OUT" | sed -n 's/^REASON=//p'; }

FAKE_HOME="$TMP/home"
export HOME="$FAKE_HOME"
reset_home() {
  rm -rf "$FAKE_HOME"
  mkdir -p "$FAKE_HOME/.claude"
}

STATE() { printf '%s' "$FAKE_HOME/.claude/session-state.json"; }
LOG() { printf '%s' "$FAKE_HOME/.claude/usage-horizon.jsonl"; }

# Hermetic knobs: every threshold test pins the configuration through the env
# overrides so a later edit to pm-config.md cannot silently move a boundary out
# from under an assertion.
export CLAUDE_USAGE_HORIZON_APPROACHING_PCT=25
export CLAUDE_USAGE_HORIZON_CRITICAL_PCT=10
export CLAUDE_USAGE_HORIZON_FLOOR_TOKENS=2000000
export CLAUDE_USAGE_HORIZON_HYSTERESIS_PCT=3
export CLAUDE_USAGE_HORIZON_TTL_SECONDS=1800

echo "== usage-horizon.sh =="

# --- 0. sanity ------------------------------------------------------------------
if [[ -x "$SCRIPT" ]]; then ok "script exists and is executable"; else bad "script missing or not executable: $SCRIPT"; fi
if bash -n "$SCRIPT" 2>"$TMP/synerr"; then ok "bash -n clean"; else bad "bash -n failed: $(cat "$TMP/synerr")"; fi

reset_home
run --help
check_eq "$RC" "0" "--help exits 0"
check_contains "$OUT" "3  unknown" "--help documents the unknown exit code"

# --- 1. usage errors ------------------------------------------------------------
reset_home
run
check_eq "$RC" "4" "no mode is a usage error"

run --observe abc --session u1
check_eq "$RC" "4" "non-numeric remaining is a usage error"

run --observe 12.5 --session u1
check_eq "$RC" "4" "non-integer remaining is a usage error"

run --observe
check_eq "$RC" "4" "--observe without a value is a usage error"

run --observe 1000000000000 --session u1
check_eq "$RC" "4" "a 13-digit remaining is refused rather than truncated"

run --observe 100 --limit 0 --session u1
check_eq "$RC" "4" "--limit 0 is refused (not a denominator)"

run --observe 200 --limit 100 --session u1
check_eq "$RC" "4" "remaining above limit is refused as incoherent"

run --check --limit 100 --session u1
check_eq "$RC" "4" "--limit on --check is a usage error"

run --observe 100 --session u1 --frobnicate
check_eq "$RC" "4" "unknown flag is a usage error"

# A usage error must not have written anything.
check_absent "$(LOG)" "a refused reading writes no observation log"

# --- 2. fail-closed paths -------------------------------------------------------
reset_home
run --check --session f1
check_not_clear "$(status_of)" "$RC" "no state file cannot yield clear"
check_eq "$RC" "3" "no state file exits 3"
check_eq "$(status_of)" "unknown" "no state file reports unknown"
check_eq "$(reason_of)" "no-state-file" "no state file names its reason"

reset_home
printf '%s' '{oops' > "$(STATE)"
run --check --session f1
check_not_clear "$(status_of)" "$RC" "corrupt state cannot yield clear"
check_eq "$(reason_of)" "state-unreadable" "corrupt state names its reason"
check_eq "$RC" "3" "corrupt state exits 3"

reset_home
printf '%s' '{"monitoring_active":true}' > "$(STATE)"
run --check --session f1
check_not_clear "$(status_of)" "$RC" "valid state with no reading cannot yield clear"
check_eq "$(reason_of)" "no-reading" "absent reading names its reason"

# A reading recorded by a DIFFERENT session is not this session's runway.
reset_home
run --observe 14000000 --limit 15000000 --session s-one
check_eq "$RC" "0" "observe in session s-one succeeds"
run --check --session s-two
check_not_clear "$(status_of)" "$RC" "another session's reading cannot yield clear"
check_eq "$(reason_of)" "no-reading-this-session" "foreign-session reading names its reason"
run --check --session s-one
check_eq "$(status_of)" "clear" "the owning session still reads its own reading"

# Stale beyond TTL.
reset_home
run --observe 14000000 --limit 15000000 --session f2
jq '.usage_horizon.reading.ts = "2020-01-01T00:00:00Z"' "$(STATE)" > "$TMP/s.json" && mv "$TMP/s.json" "$(STATE)"
run --check --session f2
check_not_clear "$(status_of)" "$RC" "a stale reading cannot yield clear"
check_eq "$(reason_of)" "reading-stale" "stale reading names its reason"
check_eq "$RC" "3" "stale reading exits 3"

# A short TTL makes a fresh reading stale — proves the knob is actually read.
reset_home
run --observe 14000000 --limit 15000000 --session f3
sleep 2
CLAUDE_USAGE_HORIZON_TTL_SECONDS=1 run --check --session f3
check_not_clear "$(status_of)" "$RC" "a reading past a 1s TTL cannot yield clear"
check_eq "$(reason_of)" "reading-stale" "the TTL knob is honored"

# Unparseable timestamp — an age that cannot be computed is never fresh.
reset_home
run --observe 14000000 --limit 15000000 --session f4
jq '.usage_horizon.reading.ts = "not-a-timestamp"' "$(STATE)" > "$TMP/s.json" && mv "$TMP/s.json" "$(STATE)"
run --check --session f4
check_not_clear "$(status_of)" "$RC" "an unparseable timestamp cannot yield clear"
check_eq "$(reason_of)" "timestamp-unparseable" "unparseable timestamp names its reason"

# A future timestamp would pass every TTL comparison forever.
reset_home
run --observe 14000000 --limit 15000000 --session f5
jq '.usage_horizon.reading.ts = "2999-01-01T00:00:00Z"' "$(STATE)" > "$TMP/s.json" && mv "$TMP/s.json" "$(STATE)"
run --check --session f5
check_not_clear "$(status_of)" "$RC" "a future-dated reading cannot yield clear"

# Malformed stored values.
reset_home
run --observe 14000000 --limit 15000000 --session f6
jq '.usage_horizon.reading.remaining = "lots"' "$(STATE)" > "$TMP/s.json" && mv "$TMP/s.json" "$(STATE)"
run --check --session f6
check_not_clear "$(status_of)" "$RC" "a non-numeric stored remaining cannot yield clear"
check_eq "$(reason_of)" "reading-malformed" "non-numeric remaining names its reason"

reset_home
run --observe 14000000 --limit 15000000 --session f7
jq '.usage_horizon.reading.limit = "all of them"' "$(STATE)" > "$TMP/s.json" && mv "$TMP/s.json" "$(STATE)"
run --check --session f7
check_not_clear "$(status_of)" "$RC" "a non-numeric stored limit cannot yield clear"

reset_home
run --observe 14000000 --limit 15000000 --session f8
jq '.usage_horizon.status = "green"' "$(STATE)" > "$TMP/s.json" && mv "$TMP/s.json" "$(STATE)"
run --check --session f8
check_not_clear "$(status_of)" "$RC" "an out-of-enum stored verdict cannot yield clear"
check_eq "$(reason_of)" "status-malformed" "bad stored verdict names its reason"

reset_home
run --observe 14000000 --limit 15000000 --session f9
jq 'del(.usage_horizon.reading.session_id)' "$(STATE)" > "$TMP/s.json" && mv "$TMP/s.json" "$(STATE)"
run --check --session f9
check_not_clear "$(status_of)" "$RC" "a reading with no session_id cannot yield clear"

# A syntactically well-formed but calendar-invalid timestamp must not parse.
reset_home
run --observe 14000000 --limit 15000000 --session f10
jq '.usage_horizon.reading.ts = "2026-13-45T00:00:00Z"' "$(STATE)" > "$TMP/s.json" && mv "$TMP/s.json" "$(STATE)"
run --check --session f10
check_not_clear "$(status_of)" "$RC" "an impossible calendar date cannot yield clear"
check_eq "$(reason_of)" "timestamp-unparseable" "an out-of-range month/day is rejected, not coerced"

# In-range-but-nonexistent days are the harder case: every field passes a
# range check, and civil-from-days is total, so Feb 31 would quietly become
# Mar 3 rather than failing. Each of these must be refused outright.
for BAD_TS in 2026-02-31T00:00:00Z 2026-02-30T00:00:00Z 2025-02-29T00:00:00Z \
              2026-04-31T00:00:00Z 2026-06-31T00:00:00Z 2026-09-31T00:00:00Z \
              2026-11-31T00:00:00Z; do
  reset_home
  run --observe 14000000 --limit 15000000 --session f10b
  jq --arg ts "$BAD_TS" '.usage_horizon.reading.ts = $ts' "$(STATE)" > "$TMP/s.json" && mv "$TMP/s.json" "$(STATE)"
  run --check --session f10b
  check_not_clear "$(status_of)" "$RC" "nonexistent date $BAD_TS cannot yield clear"
  check_eq "$(reason_of)" "timestamp-unparseable" "$BAD_TS is refused, not coerced to a later day"
done

# Negative control for the same rule: real leap days and real month ends must
# still parse, or the fix would have bought fail-closed by breaking every read.
for GOOD_TS in 2024-02-29T00:00:00Z 2000-02-29T00:00:00Z 2026-02-28T00:00:00Z \
               2026-01-31T00:00:00Z 2026-04-30T00:00:00Z 2026-12-31T23:59:59Z; do
  reset_home
  run --observe 14000000 --limit 15000000 --session f10c
  jq --arg ts "$GOOD_TS" '.usage_horizon.reading.ts = $ts' "$(STATE)" > "$TMP/s.json" && mv "$TMP/s.json" "$(STATE)"
  # A real date parses, so the verdict turns on the TTL, never on parseability.
  run --check --session f10c
  check_eq "$(reason_of)" "reading-stale" "valid date $GOOD_TS still parses (aged out, not unparseable)"
done

# --check must accept exactly the value set --observe accepts. Each of these
# is a value the writer would have refused, paired with a stored `clear`:
# the read path must not hand back permission on any of them.
for BAD_VAL in '.usage_horizon.reading.remaining = -1' \
               '.usage_horizon.reading.remaining = 1400.5' \
               '.usage_horizon.reading.remaining = 1000000000000' \
               '.usage_horizon.reading.limit = 0' \
               '.usage_horizon.reading.limit = -15000000' \
               '.usage_horizon.reading.limit = 15000000.5' \
               '.usage_horizon.reading.remaining = 16000000'; do
  reset_home
  run --observe 14000000 --limit 15000000 --session f11
  jq "$BAD_VAL" "$(STATE)" > "$TMP/s.json" && mv "$TMP/s.json" "$(STATE)"
  check_eq "$(jq -r '.usage_horizon.status' "$(STATE)")" "clear" "corruption setup keeps status=clear ($BAD_VAL)"
  run --check --session f11
  check_not_clear "$(status_of)" "$RC" "out-of-range stored value cannot yield clear ($BAD_VAL)"
  check_eq "$(reason_of)" "reading-malformed" "out-of-range stored value names its reason ($BAD_VAL)"
done

# Negative control: the boundary values --observe DOES accept must still read
# back, so the tightened gate cannot be passing by refusing everything.
reset_home
run --observe 15000000 --limit 15000000 --session f11b
check_eq "$RC" "0" "remaining == limit is accepted by --observe"
run --check --session f11b
check_eq "$(status_of)" "clear" "remaining == limit still reads back as its verdict"
reset_home
run --observe 0 --limit 15000000 --session f11c
run --check --session f11c
check_eq "$(status_of)" "critical" "a zero remaining reads back rather than being called malformed"

# Documented concurrency behaviour: the state slot is machine-wide and
# last-writer-wins, so the displaced session degrades to unknown — never to
# the other session's verdict, and never to clear.
reset_home
run --observe 3000000 --limit 15000000 --session conc-a
check_eq "$(status_of)" "approaching" "concurrent-session setup: conc-a is approaching"
run --observe 14000000 --limit 15000000 --session conc-b
check_eq "$(status_of)" "clear" "concurrent-session setup: conc-b is clear"
run --check --session conc-b
check_eq "$(status_of)" "clear" "the most recent writer reads its own verdict"
run --check --session conc-a
check_not_clear "$(status_of)" "$RC" "the displaced session does not inherit the other session's clear"
check_eq "$(reason_of)" "no-reading-this-session" "the displaced session degrades to unknown"
check_eq "$(wc -l < "$(LOG)" | tr -d ' ')" "2" "both sessions' readings survive in the observation log"

# --- 3. observe-then-check round trip -------------------------------------------
reset_home
run --observe 12000000 --limit 15000000 --session rt
check_eq "$RC" "0" "observe exits 0 on a successful record"
check_eq "$(status_of)" "clear" "observe reports the verdict it computed"
check_eq "$(reason_of)" "recorded" "observe reports the recorded reason"

check_eq "$(wc -l < "$(LOG)" | tr -d ' ')" "1" "one observation appended to the jsonl"
LINE="$(cat "$(LOG)")"
check_eq "$(printf '%s' "$LINE" | jq -r '.remaining')" "12000000" "jsonl records remaining"
check_eq "$(printf '%s' "$LINE" | jq -r '.limit')" "15000000" "jsonl records limit"
check_eq "$(printf '%s' "$LINE" | jq -r '.session_id')" "rt" "jsonl records session_id"
check_eq "$(printf '%s' "$LINE" | jq -r '.ts | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$")')" \
  "true" "jsonl timestamp is ISO-8601 UTC"

check_eq "$(jq -r '.usage_horizon.reading.remaining' "$(STATE)")" "12000000" "session-state carries the reading"
check_eq "$(jq -r '.usage_horizon.status' "$(STATE)")" "clear" "session-state carries the verdict"
check_eq "$(jq -r '.usage_horizon.reading.session_id' "$(STATE)")" "rt" "session-state carries the session id"
check_eq "$(jq -r '.usage_horizon | has("status_at")' "$(STATE)")" "true" "session-state carries the verdict timestamp"

run --check --session rt
check_eq "$RC" "0" "round-trip check exits 0 for clear"
check_eq "$(status_of)" "clear" "round-trip check reports clear"
check_eq "$(reason_of)" "reading-fresh" "round-trip check reports a fresh reading"

# A reading with no limit records limit: null, not a string.
reset_home
run --observe 5000000 --session rt2
check_eq "$(printf '%s' "$(cat "$(LOG)")" | jq -r '.limit | type')" "null" "an unbounded reading stores a JSON null limit"

# The field-type contract knows about usage_horizon, so a wrong-typed write is
# rejected at the state helper rather than being read back later as a malformed
# verdict. Registering the field in session-state-schema.json is what makes this
# pass — without it the write would be accepted unvalidated.
reset_home
"$SCRIPTS_DIR/session-state.sh" --set '.usage_horizon="oops"' >/dev/null 2>&1
check_eq "$?" "4" "session-state.sh rejects a non-object usage_horizon (field-type contract)"
# Non-vacuity control: an UNREGISTERED field holding the same string value is
# accepted. Without this the rejection above would prove nothing about the
# schema entry — it could just be how --set treats every string.
"$SCRIPTS_DIR/session-state.sh" --set '.totally_unregistered_field="oops"' >/dev/null 2>&1
check_eq "$?" "0" "control: an unregistered field accepts the same string value"

# Sibling session-state fields survive the write.
reset_home
printf '%s' '{"monitoring_active":true,"greptile_daily":{"date":"2026-01-01"}}' > "$(STATE)"
run --observe 12000000 --limit 15000000 --session sib
check_eq "$(jq -r '.monitoring_active' "$(STATE)")" "true" "sibling session-state fields are preserved"
check_eq "$(jq -r '.greptile_daily.date' "$(STATE)")" "2026-01-01" "sibling objects are preserved"

# --- 4. threshold matrix, limit known -------------------------------------------
# approaching_pct=25, critical_pct=10 against a 15,000,000 window.
matrix_case() { # <remaining> <limit-or-empty> <expected> <label>
  reset_home
  if [[ -n "$2" ]]; then
    run --observe "$1" --limit "$2" --session "mx$1"
  else
    run --observe "$1" --session "mx$1"
  fi
  check_eq "$(status_of)" "$3" "$4"
}

matrix_case 4000000 15000000 clear       "26.7% of a known window is clear"
matrix_case 3750001 15000000 clear       "just above 25% is clear"
matrix_case 3750000 15000000 approaching "exactly 25% is approaching (boundary inclusive)"
matrix_case 1600000 15000000 approaching "10.7% is approaching"
matrix_case 1500000 15000000 critical    "exactly 10% is critical (boundary inclusive)"
matrix_case 0       15000000 critical    "an exhausted window is critical"

# --- 5. threshold matrix, no limit (absolute floor) -----------------------------
# floor=2,000,000 (approaching); critical floor = 2,000,000 * 10 / 25 = 800,000.
matrix_case 2000001 "" clear       "just above the floor is clear with no known total"
matrix_case 2000000 "" approaching "exactly the floor is approaching with no known total"
matrix_case 800001  "" approaching "just above the derived critical floor is approaching"
matrix_case 800000  "" critical    "the derived critical floor is critical"

# The derived critical floor tracks the percentage ratio, not a second knob.
reset_home
CLAUDE_USAGE_HORIZON_CRITICAL_PCT=5 run --observe 400000 --session ratio
check_eq "$(status_of)" "critical" "the critical floor rescales with critical_pct (5/25 of 2,000,000)"
reset_home
CLAUDE_USAGE_HORIZON_CRITICAL_PCT=5 run --observe 400001 --session ratio2
check_eq "$(status_of)" "approaching" "just above the rescaled critical floor is approaching"

# An inverted configuration falls back to the shipped defaults rather than
# emitting a verdict from a nonsensical pair.
reset_home
OUT="$(CLAUDE_USAGE_HORIZON_CRITICAL_PCT=40 "$SCRIPT" --observe 3000000 --limit 15000000 --session inv 2>"$TMP/stderr")"
RC=$?
check_eq "$(status_of)" "approaching" "an inverted critical/approaching pair falls back to defaults"
check_contains "$(cat "$TMP/stderr")" "must be below approaching_pct" "the inverted pair is reported on stderr"

# --- 6. hysteresis --------------------------------------------------------------
# Percentage mode: margin = 3 percentage points on top of the band being left.
reset_home
run --observe 3000000 --limit 15000000 --session hy   # 20% -> approaching
check_eq "$(status_of)" "approaching" "hysteresis setup: 20% is approaching"
run --observe 3800000 --limit 15000000 --session hy   # 25.33% — above 25, below 28
check_eq "$(status_of)" "approaching" "an adjacent reading just past the threshold does not flap to clear"
run --observe 4200000 --limit 15000000 --session hy   # 28.0% — still not past the margin
check_eq "$(status_of)" "approaching" "the verdict holds right up to the margin"
run --observe 4300000 --limit 15000000 --session hy   # 28.67% — past 28
check_eq "$(status_of)" "clear" "clearing the margin releases the verdict"

# Worsening is immediate — the wall is never recognized late.
run --observe 1400000 --limit 15000000 --session hy   # 9.33%
check_eq "$(status_of)" "critical" "a worsening reading takes effect immediately"
run --observe 1560000 --limit 15000000 --session hy   # 10.4% — above 10, below 13
check_eq "$(status_of)" "critical" "leaving critical also requires the margin"
run --observe 2000000 --limit 15000000 --session hy   # 13.33% — past 13, under 25
check_eq "$(status_of)" "approaching" "past the critical margin the verdict steps down one band"

# Floor mode: margin = 2,000,000 * 3 / 25 = 240,000 tokens.
reset_home
run --observe 700000 --session hf
check_eq "$(status_of)" "critical" "floor-mode hysteresis setup: below the critical floor"
run --observe 900000 --session hf     # above 800,000, below 1,040,000
check_eq "$(status_of)" "critical" "floor-mode adjacent reading does not flap out of critical"
run --observe 1100000 --session hf    # past 1,040,000
check_eq "$(status_of)" "approaching" "floor-mode margin release steps down one band"

# A different session anchors nothing: hysteresis is per-session runway.
reset_home
run --observe 3000000 --limit 15000000 --session hs-a
check_eq "$(status_of)" "approaching" "session hs-a is approaching"
run --observe 3800000 --limit 15000000 --session hs-b
check_eq "$(status_of)" "clear" "a foreign session's level does not make hs-b sticky"

# --- 7. negative controls: nothing degraded may yield clear ---------------------
# 7a. Missing sibling helper. Paired with a positive control on the identical
#     reading, so the negative result cannot pass vacuously.
ISOLATED="$TMP/isolated"
mkdir -p "$ISOLATED"
cp "$SCRIPT" "$ISOLATED/usage-horizon.sh"
chmod +x "$ISOLATED/usage-horizon.sh"

reset_home
OUT="$("$ISOLATED/usage-horizon.sh" --observe 14000000 --limit 15000000 --session neg 2>"$TMP/stderr")"
RC=$?
check_not_clear "$(status_of)" "$RC" "observe with no session-state.sh helper cannot yield clear"
check_eq "$RC" "5" "a missing helper is a write failure, not permission"
check_contains "$(cat "$TMP/stderr")" "missing sibling helper" "the missing helper is named on stderr"

run --check --session neg
check_not_clear "$(status_of)" "$RC" "check after a failed record cannot yield clear"
check_eq "$RC" "3" "check after a failed record exits 3"
# The record aborted before session-state existed at all, so the reason is the
# absent file rather than an empty reading. Either way nothing was persisted.
check_eq "$(reason_of)" "no-state-file" "the failed record persisted nothing at all"
check_absent "$(STATE)" "the failed record left no session-state file behind"

# Positive control: the identical reading, helper present, IS clear.
reset_home
run --observe 14000000 --limit 15000000 --session pos
check_eq "$RC" "0" "positive control: the same reading records successfully"
run --check --session pos
check_eq "$(status_of)" "clear" "positive control: the same reading is genuinely clear"
check_eq "$RC" "0" "positive control: clear exits 0"

# 7b. Unreadable state file. Same fixture: clear before, unknown after.
reset_home
run --observe 14000000 --limit 15000000 --session unr
run --check --session unr
check_eq "$(status_of)" "clear" "unreadable-state control is clear before corruption"
if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
  chmod 000 "$(STATE)"
  run --check --session unr
  check_not_clear "$(status_of)" "$RC" "an unreadable state file cannot yield clear"
  chmod 644 "$(STATE)"
else
  ok "unreadable-state control skipped (running as root, mode 000 is still readable)"
fi

# 7c. A broken jq. The stub exits non-zero and never forwards to the real jq,
#     so it cannot recurse into itself.
STUBDIR="$TMP/stub"
mkdir -p "$STUBDIR"
printf '%s\n' '#!/bin/sh' 'exit 1' > "$STUBDIR/jq"
chmod +x "$STUBDIR/jq"
reset_home
run --observe 14000000 --limit 15000000 --session jqs
check_eq "$(status_of)" "clear" "broken-jq control is clear with a working jq"
OUT="$(PATH="$STUBDIR:$PATH" "$SCRIPT" --check --session jqs 2>"$TMP/stderr")"
RC=$?
check_not_clear "$(status_of)" "$RC" "a failing jq cannot yield clear"
check_eq "$RC" "3" "a failing jq degrades to the unknown exit code"

# --- 8. observation log hygiene --------------------------------------------------
reset_home
run --observe 12000000 --limit 15000000 --session mode
# Portable mode read. A `stat -f '%Lp' || stat -c '%a'` chain is NOT a valid
# try-both: GNU reads `-f` as --file-system, so it prints a filesystem block
# for the real operand AND exits non-zero, which fires the fallback too and
# leaves the substitution holding both outputs — a non-numeric blob. That is
# why this assertion passed on macOS and failed only on Linux CI. Each form is
# therefore tried in isolation, GNU first, and the result must look like octal
# mode bits before it is trusted: "could not determine" must never read as a
# pass.
file_mode() { # file_mode <path> — octal permission bits, empty when unreadable
  local path="$1" bits
  bits="$(stat -c '%a' "$path" 2>/dev/null)" || bits=""
  if [[ ! "$bits" =~ ^[0-7]+$ ]]; then
    bits="$(stat -f '%Lp' "$path" 2>/dev/null)" || bits=""
  fi
  [[ "$bits" =~ ^[0-7]+$ ]] || return 1
  printf '%s' "$bits"
}
MODE_BITS="$(file_mode "$(LOG)")" || MODE_BITS="<undeterminable>"
check_eq "$MODE_BITS" "600" "the observation log is mode 600"

# Single-generation rotation at the 256 KiB cap.
reset_home
mkdir -p "$FAKE_HOME/.claude"
head -c 262144 /dev/zero | tr '\0' 'x' > "$(LOG)"
run --observe 12000000 --limit 15000000 --session rot
check_present "$(LOG).1" "an oversized log rotates to a single .1 generation"
check_eq "$(wc -l < "$(LOG)" | tr -d ' ')" "1" "the live log restarts with just the new record"
check_absent "$(LOG).2" "rotation stays single-generation"

# --- 9. knobs really come from pm-config.md -------------------------------------
# With the env overrides removed, the thresholds must come from the `## Budget`
# section of the pm-config.md belonging to the repo the script is invoked in.
# Asserting that against THIS repo's config would be vacuous — its values equal
# the shipped defaults — so the fixture uses deliberately different ones inside
# a throwaway git repo, and the boundary has to move with them.
FAKE_REPO="$TMP/fakerepo"
mkdir -p "$FAKE_REPO/.claude"
if git -C "$FAKE_REPO" init -q >/dev/null 2>&1; then
  cat > "$FAKE_REPO/.claude/pm-config.md" <<'CFG'
# PM Config

## Budget

```ini
usage_horizon_approaching_pct = 50
usage_horizon_critical_pct    = 20
usage_horizon_reading_ttl_s   = 1
```

## Notes
CFG
  UNSET_ENV=(env -u CLAUDE_USAGE_HORIZON_APPROACHING_PCT
                 -u CLAUDE_USAGE_HORIZON_CRITICAL_PCT
                 -u CLAUDE_USAGE_HORIZON_HYSTERESIS_PCT
                 -u CLAUDE_USAGE_HORIZON_TTL_SECONDS)

  reset_home
  OUT="$(cd "$FAKE_REPO" && "${UNSET_ENV[@]}" "$SCRIPT" --observe 7500000 --limit 15000000 --session cfg 2>"$TMP/stderr")"
  RC=$?
  check_eq "$(status_of)" "approaching" "the approaching knob is read from pm-config.md (50%, not the shipped 25%)"

  reset_home
  OUT="$(cd "$FAKE_REPO" && "${UNSET_ENV[@]}" "$SCRIPT" --observe 8000000 --limit 15000000 --session cfg2 2>"$TMP/stderr")"
  RC=$?
  check_eq "$(status_of)" "clear" "just above the configured approaching share is still clear"

  reset_home
  OUT="$(cd "$FAKE_REPO" && "${UNSET_ENV[@]}" "$SCRIPT" --observe 3000000 --limit 15000000 --session cfg3 2>"$TMP/stderr")"
  RC=$?
  check_eq "$(status_of)" "critical" "the critical knob is read from pm-config.md (20%, not the shipped 10%)"

  reset_home
  "$SCRIPT" --observe 14000000 --limit 15000000 --session cfg4 >/dev/null 2>&1
  sleep 2
  OUT="$(cd "$FAKE_REPO" && "${UNSET_ENV[@]}" "$SCRIPT" --check --session cfg4 2>"$TMP/stderr")"
  RC=$?
  check_not_clear "$(status_of)" "$RC" "the TTL knob is read from pm-config.md (1s) and ages the reading out"
  check_eq "$(reason_of)" "reading-stale" "the pm-config TTL produces a stale verdict"
else
  bad "could not create the throwaway git repo for the pm-config knob fixture"
fi

# --- 10. comparison-only guarantee -----------------------------------------------
# Strip comment lines, then assert the executable body references no transcript
# and no estimation source. This is the AC clause that no behavioural test can
# reach: the guarantee is the ABSENCE of a code path.
BODY="$(grep -v '^[[:space:]]*#' "$SCRIPT")"
for forbidden in transcript ccusage quota-usage estimate; do
  if printf '%s' "$BODY" | grep -qi "$forbidden"; then
    bad "the executable body references '$forbidden' — comparison-only is no longer true by construction"
  else
    ok "no '$forbidden' reference in the executable body"
  fi
done

# --- summary --------------------------------------------------------------------
echo
echo "passed: $PASS   failed: $FAILED"
[[ $FAILED -eq 0 ]] || exit 1
exit 0
