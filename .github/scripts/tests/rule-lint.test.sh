#!/usr/bin/env bash
# rule-lint.sh — index-alignment, per-file-size, and real-repo conformance tests.
#
# This suite covers the two non-ratchet concerns:
#
#   (e) real-repo conformance — default run (no --update-cap), strictly read-only
#   (i) nested rule files     — recursively indexed, counted, and size-checked (#939)
#
# Ratchet cases (a, b, c, d, f, g, h) live in rule-lint-ratchet.test.sh.
# Shared sandbox construction and fixture helpers are sourced from:
#   lib/rule-lint-sandbox.sh
#
# HERMETICITY (issue #906)
# Case (e) is a read-only run against the real checkout. All mutating fixtures
# (case i) operate inside the disposable sandbox built by lib/rule-lint-sandbox.sh.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

failures=0
case_num=0

# Source the shared sandbox setup (sets SANDBOX, LINT, CAP_FILE, BASELINE_CAP,
# CURRENT_COUNT, FORMULA, REAL_CAP_FILE, REAL_CAP_FINGERPRINT, REPO_ROOT,
# REAL_LINT, and defines the fixture helpers including assert_real_cap_untouched,
# set_cap, read_cap, and expect).
# shellcheck source=lib/rule-lint-sandbox.sh
source "${SCRIPT_DIR}/lib/rule-lint-sandbox.sh"

# ---------------------------------------------------------------------------
# (e) Real repo conformance — default run (no --update-cap), read-only
# ---------------------------------------------------------------------------
case_num=$(( case_num + 1 ))
if ( cd "$REPO_ROOT" && bash "$REAL_LINT" >/dev/null 2>&1 ); then
  echo "ok   — (e) real repo conformance is intact"
else
  echo "FAIL — rule-lint.sh does not pass against the real repo"
  ( cd "$REPO_ROOT" && bash "$REAL_LINT" 2>&1 | sed 's/^/       /' ) || true
  failures=$(( failures + 1 ))
fi

# ---------------------------------------------------------------------------
# (i) Nested rule files are recursively indexed, counted, and size-checked
# ---------------------------------------------------------------------------
NESTED_DIR="${SANDBOX}/.claude/rules/subdir"
NESTED_RULE="${NESTED_DIR}/foo.md"
NESTED_LARGE_RULE="${NESTED_DIR}/large.md"
NESTED_DUP_DIR="${SANDBOX}/.claude/rules/another-subdir"
NESTED_DUP_RULE="${NESTED_DUP_DIR}/foo.md"
CLAUDE_MD_BACKUP="${SANDBOX}/CLAUDE.md.before-nested-fixture"
BASE_RULE_FILE_COUNT="$(find "${SANDBOX}/.claude/rules" -type f -name '*.md' | wc -l | tr -d ' ')"

mkdir -p "$NESTED_DIR"
cp "${SANDBOX}/CLAUDE.md" "$CLAUDE_MD_BACKUP"
printf '%s\n' 'nested recursive fixture words' > "$NESTED_RULE"
set_cap 13000

i_missing_out=""
i_missing_got=0
i_missing_out=$( ( cd "$SANDBOX" && bash "$LINT" 2>&1 ) ) || i_missing_got=$?
i_ok=1
if (( i_missing_got == 0 )); then
  echo "FAIL — (i) nested rule missing from index unexpectedly passed"
  i_ok=0
elif ! grep -qF "Rule file 'foo.md' exists in .claude/rules/ but is missing from the CLAUDE.md rule index table" <<< "$i_missing_out"; then
  echo "FAIL — (i) nested rule missing from index did not emit the expected error"
  i_ok=0
fi

printf '%s\n' "| \`foo.md\` | Nested fixture |" >> "${SANDBOX}/CLAUDE.md"
i_expected_total="$(
  cd "$SANDBOX"
  { cat CLAUDE.md; find .claude/rules -type f -name '*.md' -exec cat {} +; } \
    | wc -w | tr -d ' '
)"
i_expected_file_count=$(( BASE_RULE_FILE_COUNT + 1 ))
i_indexed_out=""
i_indexed_got=0
i_indexed_out=$( ( cd "$SANDBOX" && bash "$LINT" 2>&1 ) ) || i_indexed_got=$?
if (( i_indexed_got != 0 )); then
  echo "FAIL — (i) indexed nested rule: expected exit 0, got ${i_indexed_got}"
  i_ok=0
elif ! grep -qF "Rule index alignment: OK (${i_expected_file_count} files)" <<< "$i_indexed_out"; then
  echo "FAIL — (i) indexed nested rule was not included in the alignment count"
  i_ok=0
elif ! grep -qF "Total auto-loaded word count: ${i_expected_total}" <<< "$i_indexed_out"; then
  echo "FAIL — (i) indexed nested rule was not included in the corpus word count"
  i_ok=0
fi

mkdir -p "$NESTED_DUP_DIR"
printf '%s\n' 'duplicate basename fixture words' > "$NESTED_DUP_RULE"
i_duplicate_out=""
i_duplicate_got=0
i_duplicate_out=$( ( cd "$SANDBOX" && bash "$LINT" 2>&1 ) ) || i_duplicate_got=$?
if (( i_duplicate_got == 0 )); then
  echo "FAIL — (i) duplicate nested-rule basename unexpectedly passed index alignment"
  i_ok=0
elif ! grep -qF "Rule basename 'foo.md' is ambiguous across the recursive corpus" <<< "$i_duplicate_out"; then
  echo "FAIL — (i) duplicate nested-rule basename did not emit the ambiguity error"
  i_ok=0
elif ! grep -qF ".claude/rules/subdir/foo.md" <<< "$i_duplicate_out" \
  || ! grep -qF ".claude/rules/another-subdir/foo.md" <<< "$i_duplicate_out"; then
  echo "FAIL — (i) duplicate-basename error did not name both colliding rule paths"
  i_ok=0
elif grep -qF "Rule index alignment: OK" <<< "$i_duplicate_out"; then
  echo "FAIL — (i) duplicate nested-rule basename also emitted a false-clean alignment result"
  i_ok=0
fi
unlink "$NESTED_DUP_RULE"

python3 - "$NESTED_LARGE_RULE" <<'PY'
import sys

with open(sys.argv[1], "w", encoding="utf-8") as output:
    output.write("word " * 2001)
PY
printf '%s\n' "| \`large.md\` | Large nested fixture |" >> "${SANDBOX}/CLAUDE.md"
i_large_out=""
i_large_got=0
( cd "$SANDBOX" && bash "$LINT" >"${SANDBOX}/nested-large.out" 2>&1 ) || i_large_got=$?
i_large_out="$(cat "${SANDBOX}/nested-large.out")"
if (( i_large_got == 0 )); then
  echo "FAIL — (i) oversized nested-rule fixture unexpectedly passed the hard corpus limit"
  i_ok=0
elif ! grep -qF "Rule file .claude/rules/subdir/large.md is 2001 words (>2000)" <<< "$i_large_out"; then
  echo "FAIL — (i) nested rule did not participate in the per-file size check"
  i_ok=0
fi

cp "$CLAUDE_MD_BACKUP" "${SANDBOX}/CLAUDE.md"
set_cap "$BASELINE_CAP"
case_num=$(( case_num + 1 ))
if (( i_ok == 1 )); then
  echo "ok   — (i) nested rules are recursively indexed, counted, and size-checked"
else
  failures=$(( failures + 1 ))
fi

# ---------------------------------------------------------------------------
# Final result
# ---------------------------------------------------------------------------
if (( failures > 0 )); then
  echo "rule-lint.test: ${failures} failure(s)"
  exit 1
fi

echo "OK: rule-lint.test passed (${case_num} cases)"
