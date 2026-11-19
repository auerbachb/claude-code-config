#!/usr/bin/env bash
# catalog: tests — Proves window-plan.sh ends a clock-time window at second zero of the stated minute, and leaves duration windows at now + N
# Tests for issue #2339: window-plan.sh --window "until H:MM" must emit a deadline divisible by 60.
# Runs with a throwaway HOME so the live ~/.claude is never touched.
set -uo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
tmp=$(mktemp -d "${TMPDIR:-/tmp}/window-plan-test.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
export HOME="$tmp/home"
mkdir -p "$HOME/.claude"

WP="$root/.claude/scripts/window-plan.sh"
pass=0 fail=0
ok() { pass=$((pass + 1)); printf 'ok   — %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf 'FAIL — %s\n' "$1"; }
check() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (got '$2', want '$3')"; fi; }

# 2026-11-13T12:00:00Z is 07:00 EST (America/New_York, standard time after Nov 1).
NOW="2026-11-13T12:00:00Z"
NOW_EPOCH=1794571200
# 2026-11-13 21:15:00 EST == 2026-11-14 02:15:00 UTC.
EXPECT_CLOCK=1794622500

field() { printf '%s\n' "$1" | tr ' ' '\n' | sed -n "s/^$2=//p"; }

printf '== clock-time windows end at second zero\n'
out=$(bash "$WP" --window "until 9:15 PM" --now "$NOW" 2>/dev/null) || true
deadline=$(field "$out" deadline_epoch)
check "until 9:15 PM: deadline is 21:15:00 ET" "$deadline" "$EXPECT_CLOCK"
check "until 9:15 PM: deadline divisible by 60" "$(( deadline % 60 ))" 0
check "until 9:15 PM: window rounds up to 855 minutes" "$(field "$out" window_minutes)" 855

out=$(bash "$WP" --window "until 21:15" --now "$NOW" 2>/dev/null) || true
check "until 21:15 (24h form): same deadline" "$(field "$out" deadline_epoch)" "$EXPECT_CLOCK"

# A clock time with seconds already in the NOW value must still land on the minute.
out=$(bash "$WP" --window "until 9:15 PM" --now "2026-11-13T12:00:37Z" 2>/dev/null) || true
check "until 9:15 PM with NOW at :37 still ends at :00" "$(field "$out" deadline_epoch)" "$EXPECT_CLOCK"

printf '== duration windows keep now + N\n'
out=$(bash "$WP" --window "3 hours" --now "$NOW" 2>/dev/null) || true
check "3 hours: deadline is now + 10800" "$(field "$out" deadline_epoch)" "$(( NOW_EPOCH + 10800 ))"
out=$(bash "$WP" --window "90m" --now "2026-11-13T12:00:37Z" 2>/dev/null) || true
check "90m from :37: deadline is now + 5400 (unchanged form)" "$(field "$out" deadline_epoch)" "$(( NOW_EPOCH + 37 + 5400 ))"

printf '\n%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
