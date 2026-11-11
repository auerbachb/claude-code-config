#!/usr/bin/env bash
# select-hook-tests.test.sh — Behavioral test for the hook-test selector and the
# --only-file contract of run-hook-tests.sh / run-python-tests.sh (issue #2153).
#
# Each case builds its own fixture tree in a temp dir and copies the selector and both
# runners into it, so the result never depends on the live repo's suite list. Covered:
#   - selection: docs-only change, single hook, a suite itself, rules read as fixtures;
#   - fail toward ALL: shared helper, runner, unmapped path, glob-only path, empty input,
#     a non-pull_request event, an unreadable diff base, a broken `# covers:` mapping;
#   - runners: no selection is unchanged, ALL runs everything, a selected subset runs only
#     itself, an empty selection exits 0 with an explanation, an unreadable selection is
#     a usage error.
# Written to run under macOS bash 3.2 and bash 5 (no associative arrays, mapfile,
# GNU-only sed/grep syntax).
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)" || {
  echo "FAIL: cannot resolve repo root"
  exit 1
}
SEL_SRC="$ROOT/.github/scripts/select-hook-tests.sh"
RUN_SRC="$ROOT/.github/scripts/run-hook-tests.sh"
PY_SRC="$ROOT/.github/scripts/run-python-tests.sh"

passes=0
failures=0
ok()  { passes=$((passes + 1)); printf 'PASS: %s\n' "$1"; }
bad() { failures=$((failures + 1)); printf 'FAIL: %s\n' "$1"; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/select-hook-tests-test-XXXXXX")" || { echo "FAIL: mktemp"; exit 1; }
trap 'rm -rf "$TMP"' EXIT
export RUN_TESTS_LOG_DIR="$TMP/logs"
mkdir -p "$RUN_TESTS_LOG_DIR"

# A fixture repo: the selector and both runners, a small suite set with one failing
# suite, one Python module that names a hook, one that names nothing, and a glob-reading
# suite that must NOT make an unmapped script look covered.
make_fixture() {
  local d="$1"
  mkdir -p "$d/.github/scripts/tests/lib" "$d/.claude/hooks/tests" "$d/.claude/scripts" \
           "$d/.claude/reference" "$d/.claude/rules" "$d/tests" "$d/desk/tests"
  cp "$SEL_SRC" "$d/.github/scripts/select-hook-tests.sh"
  cp "$RUN_SRC" "$d/.github/scripts/run-hook-tests.sh"
  cp "$PY_SRC" "$d/.github/scripts/run-python-tests.sh"
  echo 'echo a' > "$d/.claude/hooks/a.sh"
  echo 'echo b' > "$d/.claude/hooks/b.sh"
  echo 'echo x' > "$d/.claude/scripts/x.sh"
  echo '# rule' > "$d/.claude/rules/r.md"
  echo '# doc' > "$d/.claude/reference/doc.md"
  echo ': helper' > "$d/.github/scripts/tests/lib/helper.sh"
  printf '# reads .claude/hooks/a.sh\nexit 0\n' > "$d/.claude/hooks/tests/a.test.sh"
  printf '# reads .claude/hooks/b.sh\nexit 0\n' > "$d/.claude/hooks/tests/b.test.sh"
  printf '# reads .claude/hooks/c.sh, which is absent on purpose\nexit 1\n' > "$d/.claude/hooks/tests/c.test.sh"
  printf '# reads the .claude/rules directory as fixtures\nexit 0\n' > "$d/.github/scripts/tests/shared.test.sh"
  printf '# globs .claude/scripts/*.sh\nexit 0\n' > "$d/.github/scripts/tests/glob.test.sh"
  printf 'import unittest\n\nHOOK = ".claude/hooks/a.sh"\n\n\nclass ATest(unittest.TestCase):\n    def test_ok(self):\n        self.assertTrue(HOOK)\n' > "$d/tests/test_a.py"
  printf 'import unittest\n\n\nclass CTest(unittest.TestCase):\n    def test_ok(self):\n        self.assertTrue(True)\n' > "$d/tests/test_c.py"
}

# Run the selector in fixture $1 with the remaining arguments as changed paths.
select_for() {
  local d="$1"
  shift
  printf '%s\n' "$@" | bash "$d/.github/scripts/select-hook-tests.sh"
}

has_line() { grep -Fxq -- "$2" <<<"$1"; }
is_all()   { grep -Fxq 'ALL' <<<"$1"; }
suite_count() { printf '%s\n' "$1" | awk '!/^#/ && NF { n++ } END { print n + 0 }'; }

F="$TMP/main"
make_fixture "$F"

# --- Selection --------------------------------------------------------------------
out="$(select_for "$F" .claude/reference/doc.md)"
if [ "$(suite_count "$out")" -eq 0 ] && ! is_all "$out"; then
  ok "docs-only change selects no suite (and does not force ALL)"
else
  bad "docs-only change selects no suite: $out"
fi

out="$(select_for "$F" .claude/rules/r.md)"
if has_line "$out" .github/scripts/tests/shared.test.sh && ! is_all "$out"; then
  ok "a rules file selects the suite that reads its directory as a fixture"
else
  bad "a rules file did not select its fixture reader: $out"
fi

out="$(select_for "$F" .claude/hooks/a.sh)"
if has_line "$out" .claude/hooks/tests/a.test.sh && ! has_line "$out" .claude/hooks/tests/b.test.sh \
   && ! has_line "$out" .claude/hooks/tests/c.test.sh && ! is_all "$out"; then
  ok "single-hook change selects only the suite that reads it"
else
  bad "single-hook change selected the wrong suites: $out"
fi

out="$(select_for "$F" .claude/hooks/tests/b.test.sh)"
if has_line "$out" .claude/hooks/tests/b.test.sh && ! has_line "$out" .claude/hooks/tests/a.test.sh \
   && ! is_all "$out"; then
  ok "a suite file selects itself and nothing else"
else
  bad "a changed suite did not select only itself: $out"
fi

# --- Fail toward ALL --------------------------------------------------------------
out="$(select_for "$F" .github/scripts/tests/lib/helper.sh)"
if is_all "$out"; then ok "shared test helper change selects ALL"; else bad "shared helper did not select ALL: $out"; fi

out="$(select_for "$F" .github/scripts/run-hook-tests.sh)"
if is_all "$out"; then ok "runner change selects ALL"; else bad "runner change did not select ALL: $out"; fi

out="$(select_for "$F" .claude/scripts/new-thing.sh)"
if is_all "$out"; then ok "unmapped new path selects ALL"; else bad "unmapped path did not select ALL: $out"; fi

# Transitive dependency (PR #2154 review): hook a.sh sources helper.sh, and a.test.sh names
# only a.sh. An unrelated suite mentions helper.sh in passing, which used to suppress ALL and
# select only that unrelated suite, so a regression in helper.sh merged green. The helper
# change must select ALL.
T="$TMP/transitive"
make_fixture "$T"
echo '. .claude/scripts/helper.sh' >> "$T/.claude/hooks/a.sh"
echo ': helper' > "$T/.claude/scripts/helper.sh"
printf '# mentions .claude/scripts/helper.sh in passing\nexit 0\n' > "$T/.github/scripts/tests/mentions-helper.test.sh"
out="$(select_for "$T" .claude/scripts/helper.sh)"
if is_all "$out"; then
  ok "a helper sourced by a hook selects ALL, not only the suite that mentions it in passing"
else
  bad "helper called by a hook under-selected (a.test.sh skipped): $out"
fi

# Basename is not coverage (PR #2154 review): a new code file whose basename appears only in an
# unrelated suite's text, with no literal, declared, or caller link. The selector must answer ALL,
# never that unrelated suite alone (which would skip the suite that really depends on the file).
N="$TMP/basename"
make_fixture "$N"
printf '# unrelated: mentions newhook.sh in passing\nexit 0\n' > "$N/.github/scripts/tests/unrelated.test.sh"
out="$(select_for "$N" .claude/hooks/newhook.sh)"
if is_all "$out"; then
  ok "a code path matched only by another suite's basename selects ALL"
else
  bad "basename-only match selected a partial list: $out"
fi

# Constructed-path reader (PR #2154 round-3 review): a suite reaches a script through a
# variable path, so it names only the basename, while another suite names the literal path.
# The basename suite must still be selected alongside the literal one, never skipped.
K="$TMP/constructed"
make_fixture "$K"
printf 'D=.claude/hooks\nbash "$D/a.sh"\nexit 0\n' > "$K/.github/scripts/tests/constructed.test.sh"
out="$(select_for "$K" .claude/hooks/a.sh)"
if ! is_all "$out" && has_line "$out" .claude/hooks/tests/a.test.sh \
   && has_line "$out" .github/scripts/tests/constructed.test.sh; then
  ok "a basename-only constructed-path suite is selected alongside the suite that names the literal path"
else
  bad "constructed-path suite skipped beside a literal suite: $out"
fi

# Round-2 rule intact: a code path whose only mention is a basename in a constructed path
# (no literal, declared, or self match) still fails toward ALL.
J="$TMP/constructed-only"
make_fixture "$J"
printf 'D=.claude/hooks\nbash "$D/b.sh"\nexit 0\n' > "$J/.github/scripts/tests/constructed-only.test.sh"
rm -f "$J/.claude/hooks/tests/b.test.sh"
out="$(select_for "$J" .claude/hooks/b.sh)"
if is_all "$out"; then
  ok "a path with only a constructed-path basename mention still selects ALL"
else
  bad "basename-only constructed path did not select ALL: $out"
fi

# Whole-token only: a longer filename that merely contains the basename is not a mention.
L="$TMP/whole-token"
make_fixture "$L"
printf 'bash "$D/extra-a.sh" "$D/xa.sh" "$D/a.sh.bak"\nexit 0\n' > "$L/.github/scripts/tests/longer.test.sh"
out="$(select_for "$L" .claude/hooks/a.sh)"
if ! has_line "$out" .github/scripts/tests/longer.test.sh && ! is_all "$out" \
   && has_line "$out" .claude/hooks/tests/a.test.sh; then
  ok "a longer filename that contains the basename as a substring is not a mention"
else
  bad "substring of a longer filename was matched as a mention: $out"
fi

# A failed write of the selection (PR #2154 review): stdout on a full device must not exit 0.
# The workflow turns a non-zero selector exit into ALL.
printf '.claude/hooks/a.sh\n' | bash "$F/.github/scripts/select-hook-tests.sh" --event pull_request >&- 2>/dev/null
rc=$?
if [ "$rc" -ne 0 ]; then
  ok "a failed write of the selection exits non-zero (the workflow then runs ALL)"
else
  bad "selector exited 0 after a failed write of its output"
fi

out="$(select_for "$F" .claude/scripts/x.sh)"
if is_all "$out"; then
  ok "a path matched only by a suite's glob selects ALL (a glob is not proof of coverage)"
else
  bad "glob-only path did not select ALL: $out"
fi

out="$(select_for "$F")"
if is_all "$out"; then ok "empty change list selects ALL"; else bad "empty change list did not select ALL: $out"; fi

out="$(printf '.claude/hooks/a.sh\n' | bash "$F/.github/scripts/select-hook-tests.sh" --event push)"
if is_all "$out"; then ok "a push event selects ALL"; else bad "push event did not select ALL: $out"; fi

out="$(printf '' | bash "$F/.github/scripts/select-hook-tests.sh" --event pull_request --base deadbeef0000 2>/dev/null)"
if is_all "$out"; then
  ok "an unreadable diff base selects ALL"
else
  bad "unreadable diff base did not select ALL: $out"
fi

# A deliberately broken mapping: a suite whose `# covers:` names a path that does not
# exist. The selector must answer ALL, never skip the suite on the broken mapping.
B="$TMP/broken"
make_fixture "$B"
printf '# covers: .claude/hooks/missing.sh\nexit 0\n' > "$B/.claude/hooks/tests/broken.test.sh"
out="$(select_for "$B" .claude/hooks/b.sh)"
if is_all "$out" && grep -Fq 'broken mapping' <<<"$out"; then
  ok "a broken # covers: mapping selects ALL and says why"
else
  bad "broken # covers: mapping did not fail toward ALL: $out"
fi

# --- Runners ----------------------------------------------------------------------
RUN="$F/.github/scripts/run-hook-tests.sh"
PYRUN="$F/.github/scripts/run-python-tests.sh"

json="$(bash "$RUN" --json 2>/dev/null)"
if printf '%s' "$json" | jq -e '.total == 5 and .failed == 1 and (has("selection") | not)' >/dev/null; then
  ok "no --only-file: runs every suite and keeps the unchanged JSON shape"
else
  bad "no --only-file changed behaviour: $json"
fi

printf '# reason: test\nALL\n# end-of-selection\n' > "$TMP/sel-all"
json="$(bash "$RUN" --only-file "$TMP/sel-all" --json 2>/dev/null)"
if printf '%s' "$json" | jq -e '.total == 5 and .failed == 1' >/dev/null; then
  ok "selection ALL runs every suite"
else
  bad "selection ALL did not run every suite: $json"
fi

printf '# reason: b only\n.claude/hooks/tests/b.test.sh\n# end-of-selection\n' > "$TMP/sel-b"
bash "$RUN" --only-file "$TMP/sel-b" --json >"$TMP/out-b" 2>/dev/null
rc=$?
if [ "$rc" -eq 0 ] && jq -e '.total == 1 and .failed == 0 and .skipped == 4 and .selection == "b only"' "$TMP/out-b" >/dev/null; then
  ok "a selected passing suite runs alone; the failing suite it skips does not fail the run"
else
  bad "selected subset ran the wrong set (rc=$rc): $(cat "$TMP/out-b")"
fi

printf '# reason: c\n.claude/hooks/tests/c.test.sh\n# end-of-selection\n' > "$TMP/sel-c"
json="$(bash "$RUN" --only-file "$TMP/sel-c" --json 2>/dev/null)"
rc=$?
if [ "$rc" -eq 1 ] && printf '%s' "$json" | jq -e '.total == 1 and .failed == 1' >/dev/null; then
  ok "a selected failing suite still fails the run"
else
  bad "selected failing suite did not fail the run (rc=$rc): $json"
fi

printf '# reason: nothing touches a suite\n# end-of-selection\n' > "$TMP/sel-none"
json="$(bash "$RUN" --only-file "$TMP/sel-none" --json 2>/dev/null)"
rc=$?
human="$(bash "$RUN" --only-file "$TMP/sel-none" 2>&1)"
if [ "$rc" -eq 0 ] && printf '%s' "$json" | jq -e '.ok == true and .total == 0' >/dev/null \
   && grep -Fq 'No bash test suites selected' <<<"$human"; then
  ok "an empty selection exits 0 and says so in the summary"
else
  bad "empty selection was not an explained zero-run (rc=$rc): $json"
fi

# A selection cut short by a failed write has a header but no terminator: it must run ALL.
printf '# reason: cut short\n.claude/hooks/tests/b.test.sh\n' > "$TMP/sel-trunc"
json="$(bash "$RUN" --only-file "$TMP/sel-trunc" --json 2>/dev/null)"
rc=$?
if [ "$rc" -eq 1 ] && printf '%s' "$json" | jq -e '.total == 5 and .failed == 1' >/dev/null; then
  ok "a selection without the end-of-selection terminator is cut short and runs ALL"
else
  bad "truncated selection did not run ALL (rc=$rc): $json"
fi

bash "$RUN" --only-file "$TMP/does-not-exist" >/dev/null 2>&1
rc=$?
if [ "$rc" -eq 2 ]; then ok "an unreadable selection file is a usage error (exit 2)"; else bad "unreadable selection exited $rc, expected 2"; fi

: > "$TMP/sel-empty"
bash "$RUN" --only-file "$TMP/sel-empty" >/dev/null 2>&1
rc=$?
if [ "$rc" -eq 2 ]; then
  ok "an empty selection file (no # reason: header) is a usage error, never a silent zero-run"
else
  bad "empty selection file exited $rc, expected 2"
fi

if command -v python3 >/dev/null 2>&1 && command -v jq >/dev/null 2>&1; then
  json="$(bash "$PYRUN" --json 2>/dev/null)"
  if printf '%s' "$json" | jq -e '.modules == 2 and (has("selection") | not)' >/dev/null; then
    ok "python: no --only-file runs every module with the unchanged shape"
  else
    bad "python no-selection run changed: $json"
  fi

  printf '# reason: hook\ntests/test_a.py\n# end-of-selection\n' > "$TMP/py-a"
  printf '# reason: cut short\ntests/test_a.py\n' > "$TMP/py-trunc"
  json="$(bash "$PYRUN" --only-file "$TMP/py-trunc" --json 2>/dev/null)"
  rc=$?
  if [ "$rc" -eq 0 ] && printf '%s' "$json" | jq -e '.ok == true and .modules == 2' >/dev/null; then
    ok "python: a selection without the terminator is cut short and runs every module"
  else
    bad "python truncated selection did not run ALL (rc=$rc): $json"
  fi
  json="$(bash "$PYRUN" --only-file "$TMP/py-a" --json 2>/dev/null)"
  rc=$?
  if [ "$rc" -eq 0 ] && printf '%s' "$json" | jq -e '.ok == true and .modules == 1' >/dev/null; then
    ok "python: a selected module runs alone"
  else
    bad "python selected module run wrong (rc=$rc): $json"
  fi

  json="$(bash "$PYRUN" --only-file "$TMP/sel-none" --json 2>/dev/null)"
  rc=$?
  if [ "$rc" -eq 0 ] && printf '%s' "$json" | jq -e '.ok == true and .modules == 0' >/dev/null; then
    ok "python: an empty selection exits 0 with modules 0"
  else
    bad "python empty selection was not an explained zero-run (rc=$rc): $json"
  fi
else
  echo "SKIP: python3 or jq not available; python runner cases not run"
fi

printf '\n%s passed, %s failed\n' "$passes" "$failures"
[ "$failures" -eq 0 ]
