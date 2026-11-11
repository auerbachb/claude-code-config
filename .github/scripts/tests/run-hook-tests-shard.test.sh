#!/usr/bin/env bash
# Issue #2207: `run-hook-tests.sh --shard i/n` partitions the selection. Uses --list, so no suite
# is run here. Asserts that shards 1/2 and 2/2 together cover the unsharded list exactly once (pool
# and serial entries alike), that --shard 1/1 equals the default, and that bad shard specs fail.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
RUNNER="$ROOT/.github/scripts/run-hook-tests.sh"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/run-hook-tests-shard-XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

PASS=0
FAIL=0
ok() { PASS=$((PASS + 1)); echo "PASS: $1"; }
bad() { FAIL=$((FAIL + 1)); echo "FAIL: $1"; }
check() { if eval "$2"; then ok "$1"; else bad "$1"; fi; }

bash "$RUNNER" --list > "$TMP/all" 2>"$TMP/all.err"
bash "$RUNNER" --list >/dev/null 2>&1; RC0=$?
check "--list exits 0" '[ "$RC0" -eq 0 ]'
check "unsharded list is not empty" '[ -s "$TMP/all" ]'
check "unsharded list has pool entries" 'grep -q "^pool " "$TMP/all"'
check "unsharded list has serial entries" 'grep -q "^serial " "$TMP/all"'

bash "$RUNNER" --list --shard 1/2 > "$TMP/s1" 2>"$TMP/s1.err"; RC1=$?
bash "$RUNNER" --list --shard 2/2 > "$TMP/s2" 2>"$TMP/s2.err"; RC2=$?
check "shard 1/2 lists successfully" '[ "$RC1" -eq 0 ]'
check "shard 2/2 lists successfully" '[ "$RC2" -eq 0 ]'

# Union equals the unsharded list, line for line (kind and path both).
cat "$TMP/s1" "$TMP/s2" | LC_ALL=C sort > "$TMP/union"
LC_ALL=C sort "$TMP/all" > "$TMP/all.sorted"
check "union of shards 1/2 and 2/2 equals the unsharded list" 'cmp -s "$TMP/union" "$TMP/all.sorted"'

# No suite in both shards (or twice in one), whatever its kind.
check "no suite appears in more than one shard" '[ -z "$(awk "{print \$2}" "$TMP/union" | sort | uniq -d)" ]'
check "no duplicate lines in the union" '[ -z "$(uniq -d "$TMP/union")" ]'

# The serial group is partitioned too, and split evenly by count (it runs one suite at a time).
S1_SERIAL="$(grep -c "^serial " "$TMP/s1")"
S2_SERIAL="$(grep -c "^serial " "$TMP/s2")"
check "shard 1/2 runs some serial-group suites" '[ "$S1_SERIAL" -gt 0 ]'
check "shard 2/2 runs some serial-group suites" '[ "$S2_SERIAL" -gt 0 ]'
check "serial-group split is even by count (differs by at most 1)" '[ $(( S1_SERIAL - S2_SERIAL )) -le 1 ] && [ $(( S2_SERIAL - S1_SERIAL )) -le 1 ]'
check "serial entries in the shards equal the unsharded serial count" '[ "$(( $(grep -c "^serial " "$TMP/s1") + $(grep -c "^serial " "$TMP/s2") ))" -eq "$(grep -c "^serial " "$TMP/all")" ]'
check "pool entries in the shards equal the unsharded pool count" '[ "$(( $(grep -c "^pool " "$TMP/s1") + $(grep -c "^pool " "$TMP/s2") ))" -eq "$(grep -c "^pool " "$TMP/all")" ]'

# --shard 1/1 is the default.
# Fail closed: when sort is broken, a sharded run refuses instead of running a short list.
mkdir -p "$TMP/badbin"
printf '#!/bin/sh\nexit 1\n' > "$TMP/badbin/sort"; chmod +x "$TMP/badbin/sort"
PATH="$TMP/badbin:$PATH" bash "$RUNNER" --list --shard 1/2 > "$TMP/bad.out" 2>"$TMP/bad.err"; RCB=$?
check "a failing sort makes a sharded run exit non-zero" '[ "$RCB" -ne 0 ]'
check "a failing sort lists no suites" '[ ! -s "$TMP/bad.out" ]'
printf '#!/bin/sh\nhead -n 3\n' > "$TMP/badbin/sort"
PATH="$TMP/badbin:$PATH" bash "$RUNNER" --list --shard 1/2 > "$TMP/short.out" 2>"$TMP/short.err"; RCS=$?
check "a sort that drops lines makes a sharded run exit non-zero" '[ "$RCS" -ne 0 ]'

# --json --list keeps stdout pure JSON, with the same entries as the plain list.
bash "$RUNNER" --json --list --shard 1/2 > "$TMP/s1.json" 2>/dev/null; RCJ=$?
check "--json --list exits 0" '[ "$RCJ" -eq 0 ]'
check "--json --list stdout is one JSON object" 'jq -e "type == \"object\" and (.pool | type == \"array\") and (.serial | type == \"array\")" "$TMP/s1.json" >/dev/null'
jq -r '(.pool[] | "pool " + .), (.serial[] | "serial " + .)' "$TMP/s1.json" > "$TMP/s1.fromjson" 2>/dev/null
check "--json --list names the same suites as the plain list" 'cmp -s "$TMP/s1.fromjson" "$TMP/s1"'

bash "$RUNNER" --list --shard 1/1 > "$TMP/one" 2>/dev/null
check "--shard 1/1 equals the default list" 'cmp -s "$TMP/one" "$TMP/all"'

# Deterministic: the same shard twice gives the same list.
bash "$RUNNER" --list --shard 1/2 > "$TMP/s1b" 2>/dev/null
check "shard 1/2 is deterministic across runs" 'cmp -s "$TMP/s1" "$TMP/s1b"'

# Leading zeros name the same shard (08/10 is shard 8 of 10, not an octal error).
bash "$RUNNER" --list --shard 01/02 > "$TMP/s1z" 2>/dev/null
check "--shard 01/02 equals --shard 1/2" 'cmp -s "$TMP/s1z" "$TMP/s1"'
bash "$RUNNER" --list --shard 08/10 > "$TMP/s8z" 2>/dev/null; RC8=$?
bash "$RUNNER" --list --shard 8/10 > "$TMP/s8" 2>/dev/null
check "--shard 08/10 runs and equals --shard 8/10" '[ "$RC8" -eq 0 ] && cmp -s "$TMP/s8z" "$TMP/s8"'

# A selection file is sharded the same way.
printf '%s\n' '# reason: shard test' '.claude/scripts/tests/help-output.test.sh' \
  '.claude/scripts/tests/bounded-run.test.sh' '# end-of-selection' > "$TMP/sel"
bash "$RUNNER" --list --only-file "$TMP/sel" --shard 1/2 > "$TMP/sel1" 2>/dev/null
bash "$RUNNER" --list --only-file "$TMP/sel" --shard 2/2 > "$TMP/sel2" 2>/dev/null
check "selection shard 1/2 takes the first sorted path" 'grep -q "bounded-run.test.sh" "$TMP/sel1" && ! grep -q "help-output" "$TMP/sel1"'
check "selection shard 2/2 takes the second sorted path" 'grep -q "help-output.test.sh" "$TMP/sel2" && ! grep -q "bounded-run" "$TMP/sel2"'

# Bad shard specs are usage errors (exit 2), never a silent full or empty run.
for spec in 0/2 3/2 2 x/2 1/0 ""; do
  bash "$RUNNER" --list --shard "$spec" >/dev/null 2>&1; rc=$?
  check "--shard $spec is a usage error (exit 2)" '[ "$rc" -eq 2 ]'
done

echo
echo "run-hook-tests-shard: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
