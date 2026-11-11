#!/usr/bin/env bash
# select-hook-sweep.test.sh — Under-selection sweep over EVERY code file in .claude/hooks,
# .claude/scripts and .github/scripts (issue #2177). Not a sample.
#
# For each non-docs file the selector (batch mode, --per-path) must answer ALL, or select every
# suite whose non-comment text names the file's basename as a whole token. A suite that names a
# changed file outside a comment and is left out of the selection is a violation: the suite would
# have been skipped for a change that can break it. Also checks that the batch answer covers every
# file exactly once, so a file silently dropped from the sweep cannot pass.
#
# Written to run under macOS bash 3.2 and bash 5 (no associative arrays, mapfile, GNU-only syntax).
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)" || {
  echo "FAIL: cannot resolve repo root"
  exit 1
}
SEL="$ROOT/.github/scripts/select-hook-tests.sh"

passes=0
failures=0
ok()  { passes=$((passes + 1)); printf 'PASS: %s\n' "$1"; }
bad() { failures=$((failures + 1)); printf 'FAIL: %s\n' "$1"; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/select-hook-sweep-XXXXXX")" || { echo "FAIL: mktemp"; exit 1; }
trap 'rm -rf "$TMP"' EXIT
export LC_ALL=C

cd "$ROOT" || { echo "FAIL: cannot cd to repo root"; exit 1; }

# Every code file in the three directories (docs excluded: a docs path never forces a suite list).
find .claude/hooks .claude/scripts .github/scripts -type f ! -name '*.md' | LC_ALL=C sort > "$TMP/files"
NFILES="$(awk 'END { print NR }' "$TMP/files")"
if [ "$NFILES" -lt 50 ]; then
  bad "sweep found only $NFILES code files; expected the whole tree"
  printf '\n%s passed, %s failed\n' "$passes" "$failures"
  exit 1
fi

# Every bash suite (the python modules always run and are not part of this sweep).
find .claude/hooks/tests .claude/scripts/tests .github/scripts/tests desk/tests -name '*.test.sh' 2>/dev/null \
  | LC_ALL=C sort > "$TMP/suites"

# Expected "suite<TAB>token": every whole token on a non-comment line of each suite.
: > "$TMP/expect-tokens"
while IFS= read -r S; do
  grep -vE '^[[:space:]]*#' "$S" | grep -oE '[[:alnum:]_.-]+' | awk -v s="$S" '{
      t = $0
      if (substr(t, length(t), 1) == ".") t = substr(t, 1, length(t) - 1)
      if (t != "") printf "%s\t%s\n", s, t
    }' >> "$TMP/expect-tokens"
done < "$TMP/suites"

# Expected "file<TAB>suite": the suite names the file's basename outside comments.
awk -F'\t' -v tf="$TMP/expect-tokens" '
  FILENAME == tf { s[$2] = s[$2] " " $1; next }
  {
    n = split($0, parts, "/"); base = parts[n]
    m = split(s[base], ss, " ")
    for (i = 1; i <= m; i++) printf "%s\t%s\n", $0, ss[i]
  }' "$TMP/expect-tokens" "$TMP/files" | LC_ALL=C sort -u > "$TMP/expect-pairs"
NEXP="$(awk 'END { print NR }' "$TMP/expect-pairs")"

# The batch answer for every file, in one run of the selector.
bash "$SEL" --per-path < "$TMP/files" > "$TMP/answer" 2> "$TMP/answer-err"
NANS="$(awk 'END { print NR }' "$TMP/answer")"
if [ "$NANS" -eq "$NFILES" ]; then
  ok "batch selector answered every one of the $NFILES code files exactly once"
else
  bad "batch selector answered $NANS of $NFILES files: $(head -n 3 "$TMP/answer-err")"
fi

# Files answered ALL, and the "file<TAB>suite" pairs the answer lists for the other files.
awk -F'\t' '$2 == "ALL" { print $1 }' "$TMP/answer" | LC_ALL=C sort -u > "$TMP/all-files"
awk -F'\t' '$2 != "ALL" { n = split($2, ss, " "); for (i = 1; i <= n; i++) printf "%s\t%s\n", $1, ss[i] }' \
  "$TMP/answer" | LC_ALL=C sort -u > "$TMP/answer-pairs"

# A violation: an expected pair whose file is not answered ALL and whose suite is not listed.
awk -F'\t' -v af="$TMP/all-files" -v ap="$TMP/answer-pairs" '
  FILENAME == af { all[$0] = 1; next }
  FILENAME == ap { listed[$1 "\t" $2] = 1; next }
  { if (!($1 in all) && !(($1 "\t" $2) in listed)) print $1 "\t" $2 }' \
  "$TMP/all-files" "$TMP/answer-pairs" "$TMP/expect-pairs" > "$TMP/violations"
NV="$(awk 'END { print NR }' "$TMP/violations")"
if [ "$NV" -eq 0 ]; then
  ok "under-selection sweep: zero violations over $NFILES files ($NEXP expected file/suite pairs checked)"
else
  bad "under-selection sweep: $NV violation(s), first: $(head -n 1 "$TMP/violations")"
fi

NALL="$(awk 'END { print NR }' "$TMP/all-files")"
printf 'INFO: sweep summary: %s files, %s answered ALL, %s file/suite pairs expected\n' "$NFILES" "$NALL" "$NEXP"

# No code file may come back with an empty suite list: a code path always depends on something
# or fails toward ALL.
EMPTY="$(awk -F'\t' '$2 == "" { n++ } END { print n + 0 }' "$TMP/answer")"
if [ "$EMPTY" -eq 0 ]; then
  ok "no code file is answered with an empty suite list"
else
  bad "$EMPTY code file(s) answered with an empty suite list"
fi

printf '\n%s passed, %s failed\n' "$passes" "$failures"
[ "$failures" -eq 0 ]
