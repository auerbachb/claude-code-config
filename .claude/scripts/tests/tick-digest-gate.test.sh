#!/usr/bin/env bash
# Tests for tick-digest-gate.sh (issue #2435).
# catalog: tests — Unchanged tick prints nothing, changed tick prints one bounded line, first tick stays silent, huge input stays bounded
# covers: .claude/scripts/tick-digest-gate.sh
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
GATE="$ROOT/.claude/scripts/tick-digest-gate.sh"
[[ -f "$GATE" ]] || { echo "FAIL: $GATE not found" >&2; exit 1; }
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }

run() { # run ARGS... ; sets OUT and RC
  set +e; OUT=$(bash "$GATE" "$@" 2>/dev/null); RC=$?; set -e
}

run --key pr-1 --state-dir "$TMP" --digest d1
[[ $RC -eq 11 && -z "$OUT" ]] || fail "first tick must store a baseline silently (rc=$RC out=$OUT)"
pass "first observation is silent"

run --key pr-1 --state-dir "$TMP" --digest d1 --what "x"
[[ $RC -eq 10 && -z "$OUT" ]] || fail "unchanged digest must print nothing (rc=$RC out=$OUT)"
pass "unchanged digest emits nothing"

run --key pr-1 --state-dir "$TMP" --digest d2 --what "CI failed" --decision "fix or defer" --pointer /rec/1
[[ $RC -eq 0 ]] || fail "changed digest should exit 0 (rc=$RC)"
[[ $(printf '%s\n' "$OUT" | wc -l | tr -d ' ') -eq 1 ]] || fail "changed digest must print exactly one line"
case "$OUT" in *"CI failed"*"fix or defer"*"/rec/1"*) ;; *) fail "event line lacks what/decision/pointer: $OUT" ;; esac
pass "changed digest emits one summary line"

run --key pr-1 --state-dir "$TMP" --digest d2
[[ $RC -eq 10 && -z "$OUT" ]] || fail "digest stored after emit must make the next tick silent"
pass "emitted change is not re-emitted"

# Very large "what" (as if a whole review body or log were passed) stays bounded.
BIG=$(head -c 64000 /dev/zero | tr '\0' 'x')
run --key pr-1 --state-dir "$TMP" --digest d3 --what "$BIG" --pointer /rec/1
[[ $RC -eq 0 ]] || fail "large change should still exit 0"
(( ${#OUT} <= 400 )) || fail "event line exceeds the 400 byte bound (${#OUT})"
case "$OUT" in *"| record: /rec/1") ;; *) fail "pointer was truncated away: $OUT" ;; esac
run --key pr-1 --state-dir "$TMP" --digest d4 --what "$BIG" --max-bytes 120
(( ${#OUT} <= 120 )) || fail "custom bound ignored (${#OUT})"
pass "event line stays under its bound for a huge payload"

# Digest hashed from a very large stdin; a one-byte change flips it.
set +e
head -c 3000000 /dev/zero | bash "$GATE" --key big --state-dir "$TMP" >/dev/null 2>&1
BASE_RC=$?
OUT=$( (head -c 3000000 /dev/zero; printf 'y') | bash "$GATE" --key big --state-dir "$TMP" --what "grew" 2>/dev/null)
RC=$?
set -e
[[ $BASE_RC -eq 11 ]] || fail "stdin baseline should exit 11 (rc=$BASE_RC)"
[[ $RC -eq 0 && "$OUT" == *grew* ]] || fail "stdin digest change not detected (rc=$RC)"
pass "stdin digest detects a change in large input"

# Newlines and control characters in fields cannot split the event into several lines.
run --key pr-2 --state-dir "$TMP" --digest a
run --key pr-2 --state-dir "$TMP" --digest b --what $'line1\nline2\r\x07end'
[[ $(printf '%s\n' "$OUT" | wc -l | tr -d ' ') -eq 1 ]] || fail "multi-line field leaked into output"
pass "fields are flattened to one line"

# Unwritable state dir: fail toward waking the parent.
touch "$TMP/blocker"
run --key pr-3 --state-dir "$TMP/blocker/sub" --digest a
[[ $RC -eq 4 && "$OUT" == EVENT* ]] || fail "unstorable baseline should exit 4 and say so on stdout (rc=$RC out=$OUT)"
mkdir -p "$TMP/ok"
run --key pr-3 --state-dir "$TMP/ok" --digest a
rm -rf "$TMP/ok"; printf x > "$TMP/ok"
run --key pr-3 --state-dir "$TMP/ok" --digest b --what changed
[[ $RC -ne 0 ]] || fail "a store failure must not exit 0"
pass "store failure is loud"

# Baseline-failure event honors --max-bytes and stays non-empty.
LONGKEY=$(printf "k%.0s" $(seq 1 64))
run --key "$LONGKEY" --state-dir "$TMP/blocker/sub" --digest a --max-bytes 80
[[ $RC -eq 4 && -n "$OUT" && ${#OUT} -le 80 ]] || fail "baseline-failure event not bounded (rc=$RC len=${#OUT})"
pass "baseline-failure event is bounded"

# An existing but unreadable record is an event, never a silent new baseline.
mkdir -p "$TMP/unr"
printf 'a\n' > "$TMP/unr/pr-5.digest"
chmod 000 "$TMP/unr/pr-5.digest"
if [[ ! -r "$TMP/unr/pr-5.digest" ]]; then
  run --key pr-5 --state-dir "$TMP/unr" --digest a --max-bytes 120
  [[ $RC -eq 4 && "$OUT" == EVENT*unreadable* && ${#OUT} -le 120 ]] || fail "unreadable record must emit a bounded event (rc=$RC out=$OUT)"
  pass "unreadable record emits an event"
else
  pass "unreadable record check skipped (running as a user that reads mode 000)"
fi
chmod 644 "$TMP/unr/pr-5.digest" 2>/dev/null || true

# A failed digest write leaves no temp file behind.
mkdir -p "$TMP/clean"
run --key pr-6 --state-dir "$TMP/clean" --digest a
rm -f "$TMP/clean/pr-6.digest"; mkdir "$TMP/clean/pr-6.digest"
run --key pr-6 --state-dir "$TMP/clean" --digest b --what changed
leftover=$(find "$TMP/clean" -maxdepth 1 -name '.pr-6.*' | wc -l | tr -d ' ')
[[ "$leftover" -eq 0 ]] || fail "temp file left behind after a failed store ($leftover)"
pass "failed store cleans its temp file"

run --key 'bad key' --state-dir "$TMP" --digest a
[[ $RC -eq 2 ]] || fail "invalid key must be a usage error"
pass "invalid key rejected"
echo "All tick-digest-gate tests passed."
