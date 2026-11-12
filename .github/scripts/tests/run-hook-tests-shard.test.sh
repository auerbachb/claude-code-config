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

# The serial group is partitioned too. It is split by weight, not by count (see the weighted
# checks below), so the two shards may hold different numbers of serial suites.
S1_SERIAL="$(grep -c "^serial " "$TMP/s1")"
S2_SERIAL="$(grep -c "^serial " "$TMP/s2")"
check "shard 1/2 runs some serial-group suites" '[ "$S1_SERIAL" -gt 0 ]'
check "shard 2/2 runs some serial-group suites" '[ "$S2_SERIAL" -gt 0 ]'
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

# Weighted split (issue #2207 follow-up). Five pool suites with weights 100/60/50/40/10 (the
# fixture weights file), assigned in descending weight to the lightest shard:
#   100 -> S1 (S1 100), 60 -> S2 (S2 60), 50 -> S2 (S2 110), 40 -> S1 (S1 140), 10 -> S2 (S2 120).
# So S1 = {P1,P4} with sum 140 and S2 = {P2,P3,P5} with sum 120. A count split of the sorted list
# would give S1 = {P1,P3,P5} (sum 160), so the membership and sum checks below discriminate.
grep '^pool ' "$TMP/all" | cut -d' ' -f2 | LC_ALL=C sort | head -n 5 > "$TMP/five"
check "the weighted fixture has five pool suites" '[ "$(wc -l < "$TMP/five")" -eq 5 ]'
P1="$(sed -n 1p "$TMP/five")"; P2="$(sed -n 2p "$TMP/five")"; P3="$(sed -n 3p "$TMP/five")"
P4="$(sed -n 4p "$TMP/five")"; P5="$(sed -n 5p "$TMP/five")"
printf '100\t%s\n60\t%s\n50\t%s\n40\t%s\n10\t%s\n' "$P1" "$P2" "$P3" "$P4" "$P5" > "$TMP/w5.tsv"
{ printf '# reason: weighted shard test\n'; cat "$TMP/five"; printf '# end-of-selection\n'; } > "$TMP/sel"
HOOK_TEST_WEIGHTS_FILE="$TMP/w5.tsv" bash "$RUNNER" --list --only-file "$TMP/sel" --shard 1/2 > "$TMP/sel1" 2>/dev/null
HOOK_TEST_WEIGHTS_FILE="$TMP/w5.tsv" bash "$RUNNER" --list --only-file "$TMP/sel" --shard 2/2 > "$TMP/sel2" 2>/dev/null
check "weighted split: shard 1/2 takes the 100 and 40 suites" '[ "$(wc -l < "$TMP/sel1")" -eq 2 ] && grep -Fxq "pool $P1" "$TMP/sel1" && grep -Fxq "pool $P4" "$TMP/sel1"'
check "weighted split: shard 2/2 takes the 60, 50 and 10 suites" '[ "$(wc -l < "$TMP/sel2")" -eq 3 ] && grep -Fxq "pool $P2" "$TMP/sel2" && grep -Fxq "pool $P3" "$TMP/sel2" && grep -Fxq "pool $P5" "$TMP/sel2"'
sed 's/^pool //' "$TMP/sel1" > "$TMP/p1"; sed 's/^pool //' "$TMP/sel2" > "$TMP/p2"
S1_W="$(awk -F'\t' 'NR == FNR { w[$2] = $1; next } ($0 in w) { s += w[$0] } END { print s + 0 }' "$TMP/w5.tsv" "$TMP/p1")"
S2_W="$(awk -F'\t' 'NR == FNR { w[$2] = $1; next } ($0 in w) { s += w[$0] } END { print s + 0 }' "$TMP/w5.tsv" "$TMP/p2")"
check "weighted split: shard 1/2 weight sum is 140" '[ "$S1_W" -eq 140 ]'
check "weighted split: shard 2/2 weight sum is 120" '[ "$S2_W" -eq 120 ]'
check "weighted split: shard weight sums differ by at most the largest weight (100)" '[ $(( S1_W - S2_W )) -le 100 ] && [ $(( S2_W - S1_W )) -le 100 ]'
check "weighted split: 2 shards cover the five-suite selection exactly once" 'cat "$TMP/p1" "$TMP/p2" | LC_ALL=C sort | cmp -s - "$TMP/five"'

# Three shards over the same weighted selection: still an exact partition, no suite twice.
: > "$TMP/sel3"
for k in 1 2 3; do HOOK_TEST_WEIGHTS_FILE="$TMP/w5.tsv" bash "$RUNNER" --list --only-file "$TMP/sel" --shard "$k/3" >> "$TMP/sel3" 2>/dev/null; done
sed 's/^pool //' "$TMP/sel3" | LC_ALL=C sort > "$TMP/p3.sorted"
check "three shards cover the five-suite selection exactly once" 'cmp -s "$TMP/p3.sorted" "$TMP/five"'

# The real 2- and 3-shard splits partition the full list (pool and serial alike).
bash "$RUNNER" --list --shard 1/3 > "$TMP/t1" 2>/dev/null
bash "$RUNNER" --list --shard 2/3 > "$TMP/t2" 2>/dev/null
bash "$RUNNER" --list --shard 3/3 > "$TMP/t3" 2>/dev/null
check "shards 1/3, 2/3 and 3/3 together equal the unsharded list" 'cat "$TMP/t1" "$TMP/t2" "$TMP/t3" | LC_ALL=C sort | cmp -s - "$TMP/all.sorted"'

# Zero weights (whole-second timing rounds fast suites to 0): the assignment still spreads them. The
# load of a zero-weight suite counts as 1, so five zero rows split 3/2 (sorted P1,P3,P5 vs P2,P4),
# never 5/0. Without the floor every zero row would land on shard 1.
printf '0\t%s\n0\t%s\n0\t%s\n0\t%s\n0\t%s\n' "$P1" "$P2" "$P3" "$P4" "$P5" > "$TMP/w0.tsv"
HOOK_TEST_WEIGHTS_FILE="$TMP/w0.tsv" bash "$RUNNER" --list --only-file "$TMP/sel" --shard 1/2 > "$TMP/z1" 2>/dev/null
HOOK_TEST_WEIGHTS_FILE="$TMP/w0.tsv" bash "$RUNNER" --list --only-file "$TMP/sel" --shard 2/2 > "$TMP/z2" 2>/dev/null
check "zero weights: shards hold 3 and 2 suites, not 5 and 0" '[ "$(wc -l < "$TMP/z1")" -eq 3 ] && [ "$(wc -l < "$TMP/z2")" -eq 2 ]'

# Missing weights file: every suite gets the same default weight. Still a partition, no warning, and
# deterministic across runs.
HOOK_TEST_WEIGHTS_FILE="$TMP/absent.tsv" bash "$RUNNER" --list --shard 1/2 > "$TMP/no1" 2>"$TMP/no1.err"; RCN=$?
HOOK_TEST_WEIGHTS_FILE="$TMP/absent.tsv" bash "$RUNNER" --list --shard 2/2 > "$TMP/no2" 2>/dev/null
HOOK_TEST_WEIGHTS_FILE="$TMP/absent.tsv" bash "$RUNNER" --list --shard 1/2 > "$TMP/no1b" 2>/dev/null
check "absent weights file: sharded run exits 0 with no warning" '[ "$RCN" -eq 0 ] && [ ! -s "$TMP/no1.err" ]'
check "absent weights file: shards 1/2 and 2/2 partition the list" 'cat "$TMP/no1" "$TMP/no2" | LC_ALL=C sort | cmp -s - "$TMP/all.sorted"'
check "absent weights file: the split is deterministic" 'cmp -s "$TMP/no1" "$TMP/no1b"'

# Empty weights file: same default behaviour as an absent one.
: > "$TMP/empty.tsv"
HOOK_TEST_WEIGHTS_FILE="$TMP/empty.tsv" bash "$RUNNER" --list --shard 2/2 > "$TMP/em2" 2>/dev/null; RCE=$?
check "empty weights file: sharded run exits 0 and lists the same shard as an absent file" '[ "$RCE" -eq 0 ] && cmp -s "$TMP/em2" "$TMP/no2"'

# Malformed rows are ignored with ONE stderr warning; the valid row still applies and the split holds.
{ printf '# header\nabc\t%s\n' "$P1"; printf '40\t%s\n' "$P2"; printf 'no tab row\n'; } > "$TMP/mal.tsv"
HOOK_TEST_WEIGHTS_FILE="$TMP/mal.tsv" bash "$RUNNER" --list --only-file "$TMP/sel" --shard 1/2 > "$TMP/mal1" 2>"$TMP/mal1.err"; RCM=$?
HOOK_TEST_WEIGHTS_FILE="$TMP/mal.tsv" bash "$RUNNER" --list --only-file "$TMP/sel" --shard 2/2 > "$TMP/mal2" 2>/dev/null
check "malformed weights rows: run exits 0" '[ "$RCM" -eq 0 ]'
check "malformed weights rows: exactly one warning naming the 2 ignored rows" '[ "$(grep -c "ignored 2 malformed" "$TMP/mal1.err")" -eq 1 ] && [ "$(wc -l < "$TMP/mal1.err")" -eq 1 ]'
check "malformed weights rows: shards still partition the selection" 'cat "$TMP/mal1" "$TMP/mal2" | sed "s/^pool //" | LC_ALL=C sort | cmp -s - "$TMP/five"'

# A weights path that is a directory is unreadable as a file: a usage error, nothing listed.
HOOK_TEST_WEIGHTS_FILE="$TMP" bash "$RUNNER" --list --shard 1/2 > "$TMP/dir.out" 2>/dev/null; RCD=$?
check "weights path that is a directory is a usage error (exit 2) and lists nothing" '[ "$RCD" -eq 2 ] && [ ! -s "$TMP/dir.out" ]'

# A failing awk makes a weighted sharded run exit non-zero and list nothing (fail closed).
mkdir -p "$TMP/badawk"
printf '#!/bin/sh\nexit 1\n' > "$TMP/badawk/awk"; chmod +x "$TMP/badawk/awk"
PATH="$TMP/badawk:$PATH" HOOK_TEST_WEIGHTS_FILE="$TMP/w5.tsv" bash "$RUNNER" --list --only-file "$TMP/sel" --shard 1/2 > "$TMP/awkbad.out" 2>/dev/null; RCA=$?
check "a failing awk makes a weighted sharded run exit non-zero" '[ "$RCA" -ne 0 ]'
check "a failing awk lists no suites" '[ ! -s "$TMP/awkbad.out" ]'

# The committed weights file parses cleanly: no malformed-row warning, rows sorted with LC_ALL=C.
WEIGHTS="$ROOT/.github/hook-test-weights.tsv"
bash "$RUNNER" --list --shard 1/2 2>"$TMP/real.err" >/dev/null
check "committed weights file: no malformed rows" '[ "$(grep -c ignored "$TMP/real.err")" -eq 0 ]'
grep -v '^#' "$WEIGHTS" > "$TMP/w.rows"
check "committed weights file: rows sorted by path with LC_ALL=C" 'LC_ALL=C sort -c -t "$(printf "\t")" -k2,2 "$TMP/w.rows"'

# Bad shard specs are usage errors (exit 2), never a silent full or empty run.
for spec in 0/2 3/2 2 x/2 1/0 ""; do
  bash "$RUNNER" --list --shard "$spec" >/dev/null 2>&1; rc=$?
  check "--shard $spec is a usage error (exit 2)" '[ "$rc" -eq 2 ]'
done

echo
echo "run-hook-tests-shard: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
