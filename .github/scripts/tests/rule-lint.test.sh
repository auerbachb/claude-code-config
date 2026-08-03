#!/usr/bin/env bash
# Unit tests for rule-lint.sh --update-cap one-way ratchet (issue #832)
#
# Covers the acceptance criteria:
#   (a) small cut  → formula exceeds current cap  → cap unchanged (ratchet holds)
#   (b) large cut  → formula below current cap    → cap lowered to formula
#   (c) --allow-raise                             → cap raised, old/new/delta printed
# Plus six bonus cases:
#   (d) bootstrap  → corrupt/missing prior cap    → formula result written
#   (e) real repo conformance (default run, no --update-cap)
#   (f) equal case → formula == current cap       → unchanged, no "would raise" message
#   (g) hermeticity — the real cap file was never written during the run
#   (h) ratchet breach (no --update-cap)          → hard fail: exit 1 + ::error (#879)
#   (i) nested rule files                          → recursively indexed, counted, warned (#939)
#
# HERMETICITY (issue #906)
# ------------------------
# Every --update-cap fixture runs against a disposable sandbox copy of the
# working tree, never the real checkout. This suite used to point CAP_FILE at
# the real .claude/rules/.budget-soft-cap, mutate it per fixture, and restore
# it from an EXIT trap. That left a multi-second window per fixture in which
# the real file held an inflated value (count + 750):
#
#   * a killed run (runner/agent timeout, SIGKILL) skips the trap and strands
#     the inflated cap in the working tree, where `git add -A` commits it
#     silently — and the one-way ratchet can never lower it again; and
#   * two concurrent runs each captured their own ORIG_CAP, so the second
#     run's trap could restore a value the first had only written temporarily.
#
# rule-lint.sh addresses everything through cwd-relative paths, so relocating
# cwd into the sandbox is a complete override — no production-script change is
# needed. Case (e) still reads the real repo because it is a default run with
# no --update-cap, i.e. strictly read-only.

set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
# Case (e) alone runs the real script against the real checkout (read-only).
# Kept as its own variable so that read-only run stays explicit rather than a
# temporary reassignment of the sandbox LINT that every other case depends on.
REAL_LINT="${REPO_ROOT}/.github/scripts/rule-lint.sh"
REAL_CAP_FILE="${REPO_ROOT}/.claude/rules/.budget-soft-cap"

failures=0
case_num=0

# ---------------------------------------------------------------------------
# Sandbox: a disposable copy of the working tree that the mutating fixtures
# own outright.
# ---------------------------------------------------------------------------
SANDBOX="$(mktemp -d -t rule-lint-sandbox.XXXXXX)"
trap 'rm -rf "$SANDBOX"' EXIT

# Copy the non-ignored WORKING TREE — not HEAD — so uncommitted edits to the
# script under test are what gets exercised. `--cached --others
# --exclude-standard` is tracked plus untracked-but-not-ignored: it skips
# ignored junk, and it keeps the sandbox self-consistent while a rule file is
# added but not yet committed (a tracked-only copy would pair a modified
# CLAUDE.md indexing that file with an absent file, and every fixture would
# then fail on rule-index misalignment).
while IFS= read -r -d '' f; do
  mkdir -p "${SANDBOX}/$(dirname "$f")"
  cp "${REPO_ROOT}/${f}" "${SANDBOX}/${f}"
done < <(git -C "$REPO_ROOT" ls-files -z --cached --others --exclude-standard)

# Required, not cosmetic: rule-lint.sh's step 4 shells chip-model-guard-lint.test.sh,
# which resolves REPO_ROOT via `git rev-parse --show-toplevel` under `set -e`.
# Without a repo at the sandbox root that call walks out of the temp dir and
# fails, taking the whole lint to exit 1.
git -C "$SANDBOX" init -q

LINT="${SANDBOX}/.github/scripts/rule-lint.sh"
CAP_FILE="${SANDBOX}/.claude/rules/.budget-soft-cap"

# Fail closed on an incomplete sandbox. A guard that silently skips reports
# success; without this, a broken copy would either fail every fixture with a
# confusing error or — worse — pass vacuously.
for required in "${SANDBOX}/CLAUDE.md" "$CAP_FILE" "$LINT"; do
  if [[ ! -f "$required" ]]; then
    echo "BAIL: sandbox is incomplete — missing ${required#"${SANDBOX}"/}"
    exit 1
  fi
done
if [[ "$CAP_FILE" == "$REAL_CAP_FILE" ]]; then
  echo "BAIL: sandbox cap file resolves to the real one (${REAL_CAP_FILE})"
  exit 1
fi

# ---------------------------------------------------------------------------
# Hermeticity fingerprint of the REAL cap file: content hash, mtime, size.
#
# Checking mtime as well as bytes is what makes this rigorous. A byte
# comparison alone cannot tell "never written" from "written and restored",
# and written-then-restored is exactly the state a SIGKILL freezes into a
# dirty tree. Bytes AND mtime unchanged across the whole run proves no write
# ever happened, so no kill signal at any instant can strand an inflated cap —
# a stronger guarantee than a one-shot kill test, which samples one moment.
# ---------------------------------------------------------------------------
real_cap_fingerprint() {
  python3 - "$REAL_CAP_FILE" <<'PY'
import hashlib
import os
import sys

path = sys.argv[1]
st = os.stat(path)
digest = hashlib.sha256(open(path, "rb").read()).hexdigest()
sys.stdout.write("sha256=%s mtime_ns=%d size=%d" % (digest, st.st_mtime_ns, st.st_size))
PY
}

REAL_CAP_FINGERPRINT=""
REAL_CAP_FINGERPRINT="$(real_cap_fingerprint)" \
  || { echo "BAIL: could not fingerprint ${REAL_CAP_FILE}"; exit 1; }

# Records a failure rather than returning non-zero: callers run under `set -e`
# and must not abort the suite on a mismatch.
assert_real_cap_untouched() {
  local where="$1" now=""
  now="$(real_cap_fingerprint)" || now="<unreadable>"
  if [[ "$now" != "$REAL_CAP_FINGERPRINT" ]]; then
    echo "FAIL — ${where}: the real ${REAL_CAP_FILE} was modified during the run"
    echo "       before: ${REAL_CAP_FINGERPRINT}"
    echo "       after:  ${now}"
    failures=$(( failures + 1 ))
  fi
}

set_cap() {
  printf '%s' "$1" > "$CAP_FILE"
}

read_cap() {
  cat "$CAP_FILE"
}

# Read and validate an integer cap value from a file.
read_cap_value() {
  python3 - "$1" <<'PY'
import re
import sys

data = open(sys.argv[1], "rb").read()
if not re.fullmatch(rb"[0-9]+(\r?\n)?", data):
    sys.stderr.write("INVALID CAP FILE\n")
    sys.exit(1)
sys.stdout.write(str(int(data.strip().decode("ascii"))))
PY
}

# The sandbox's starting cap value. Each fixture resets to it on the way out so
# a future `pre_cap="keep"` case still means "the baseline value", exactly as
# the old per-case restore-to-ORIG_CAP did.
BASELINE_CAP=""
BASELINE_CAP="$(read_cap_value "$CAP_FILE")" \
  || { echo "BAIL: could not read initial cap value from sandbox ${CAP_FILE}"; exit 1; }

# Run rule-lint.sh --update-cap [extra flags] from the SANDBOX root.
# Returns combined stdout+stderr; exits with the script's exit code.
# "$@" expansion of an empty "$@" is safe under set -u (unlike "${arr[@]}").
# The sandbox's own copy of the script is used so its step-4 children, which
# resolve through SCRIPT_DIR, stay inside the sandbox too.
run_update_cap() {
  ( cd "$SANDBOX" && bash "$LINT" --update-cap "$@" 2>&1 )
}

# expect NAME WANT_EXIT WANT_RE PRE_CAP POST_CAP [extra_flags...]
#   WANT_RE  — ERE pattern that must appear in combined output
#   PRE_CAP  — value to write before running (or "keep" to leave as-is)
#   POST_CAP — expected cap value after running  (or "any" to skip check)
expect() {
  local name="$1" want_exit="$2" want_re="$3" pre_cap="$4" post_cap="$5"
  shift 5
  # Remaining "$@" are optional extra flags for --update-cap.
  # We do NOT collect them into a local array — "${arr[@]}" with an empty
  # array triggers "unbound variable" under set -u on bash < 4.4.
  case_num=$(( case_num + 1 ))

  if [[ "$pre_cap" != "keep" ]]; then
    set_cap "$pre_cap"
  fi

  local out=""
  local got=0
  out=$(run_update_cap "$@") || got=$?

  # The window the old suite left open is precisely here — a --update-cap run
  # has just completed. Check the real file mid-run, not only at exit.
  # A hermeticity breach is its own failure, independent of the ratchet
  # assertions: the case must NOT print "ok" just because the ratchet still
  # behaved. assert_real_cap_untouched already printed its own FAIL line and
  # counted itself, so the delta below only suppresses the "ok".
  local pre_assert_failures=$failures
  assert_real_cap_untouched "during ${name}"
  local hermetic_ok=1
  if (( failures != pre_assert_failures )); then
    hermetic_ok=0
  fi

  local ratchet_ok=1
  if (( got != want_exit )); then
    echo "FAIL — ${name}: expected exit ${want_exit}, got ${got}"
    ratchet_ok=0
  elif ! grep -qE "$want_re" <<< "$out"; then
    echo "FAIL — ${name}: exit ${got} as expected, but output did not match /${want_re}/"
    ratchet_ok=0
  elif [[ "$post_cap" != "any" ]]; then
    local actual_cap
    actual_cap=$(read_cap)
    if [[ "$actual_cap" != "$post_cap" ]]; then
      echo "FAIL — ${name}: cap expected ${post_cap}, got ${actual_cap}"
      ratchet_ok=0
    fi
  fi

  if (( ratchet_ok == 0 )); then
    printf '%s\n' "$out" | sed 's/^/       /'
    failures=$(( failures + 1 ))
  fi

  if (( ratchet_ok == 1 && hermetic_ok == 1 )); then
    echo "ok   — ${name}"
  fi

  set_cap "$BASELINE_CAP"
}

# ---------------------------------------------------------------------------
# Derive the formula value from the SANDBOX corpus so the expectations always
# match what the sandboxed lint computes.
# ---------------------------------------------------------------------------
RATCHET_HEADROOM=750
RATCHET_FLOOR=8500
# Count the same recursive corpus as the production lint.
CURRENT_COUNT=""
CURRENT_COUNT="$(
  cd "$SANDBOX"
  { cat CLAUDE.md; find .claude/rules -type f -name '*.md' -exec cat {} +; } \
    | wc -w | tr -d ' '
)"
FORMULA=$(( CURRENT_COUNT + RATCHET_HEADROOM ))
if (( FORMULA < RATCHET_FLOOR )); then
  FORMULA=$RATCHET_FLOOR
fi
echo "# sandbox corpus=${CURRENT_COUNT} words, formula cap=${FORMULA}"

# ---------------------------------------------------------------------------
# (a) Small cut — formula exceeds current cap — ratchet holds
# ---------------------------------------------------------------------------
# Set cap to FORMULA-1: a single-word cut would produce formula > cap.
# The ratchet must block the raise and keep the cap at FORMULA-1.
A_CAP=$(( FORMULA - 1 ))
expect \
  "(a) small cut: formula > cap — ratchet holds, cap unchanged" \
  0 \
  "unchanged.*formula ${FORMULA} would raise" \
  "$A_CAP" \
  "$A_CAP"

# ---------------------------------------------------------------------------
# (b) Large cut — formula falls below current cap — cap lowers to formula
# ---------------------------------------------------------------------------
B_CAP=$(( FORMULA + 500 ))
expect \
  "(b) large cut: formula < cap — cap lowered to formula" \
  0 \
  "${B_CAP} → ${FORMULA}.*\[lowered\]" \
  "$B_CAP" \
  "$FORMULA"

# ---------------------------------------------------------------------------
# (c) --allow-raise overrides the ratchet and raises the cap
# ---------------------------------------------------------------------------
C_CAP=$(( FORMULA - 1 ))
expect \
  "(c) --allow-raise: cap raised, old/new/delta printed" \
  0 \
  "${C_CAP} → ${FORMULA}.*\[--allow-raise\]" \
  "$C_CAP" \
  "$FORMULA" \
  "--allow-raise"

# ---------------------------------------------------------------------------
# (d) Bootstrap: corrupt prior cap — formula result written
# ---------------------------------------------------------------------------
expect \
  "(d) bootstrap: corrupt cap file — formula written" \
  0 \
  "no valid prior value — bootstrapping to formula result" \
  "NOT_A_NUMBER" \
  "$FORMULA"

# ---------------------------------------------------------------------------
# (f) Equal case: formula == prev_cap — cap unchanged, no "would raise" message
# ---------------------------------------------------------------------------
F_CAP=$FORMULA
expect \
  "(f) equal: formula == cap — unchanged, no 'would raise'" \
  0 \
  "unchanged.*formula matches cap" \
  "$F_CAP" \
  "$F_CAP"

# ---------------------------------------------------------------------------
# (h) Ratchet breach is a HARD FAIL, not a warning (issue #879)
# ---------------------------------------------------------------------------
# #879 decided that the ratchet cap is a visibility mechanism raisable with a
# PR-body justification line — and that it stays an ERROR while doing so. The
# alternative on the table (CodeRabbit's plan for that issue) was to downgrade
# this branch to ::warning, which would have made a cap breach invisible in the
# diff and actionable by nobody. This case pins the decided behaviour so a
# future edit cannot silently soften it back; see
# .claude/reference/budget-cap-raise-decision.md.
#
# Runs WITHOUT --update-cap, so it needs its own runner rather than expect().
H_CAP=$(( CURRENT_COUNT - 1 ))   # corpus overruns the committed cap by 1 word
set_cap "$H_CAP"
h_out=""
h_got=0
h_out=$( ( cd "$SANDBOX" && bash "$LINT" 2>&1 ) ) || h_got=$?

# Fingerprint the real cap file before any cleanup runs, matching expect()'s
# ordering: the check belongs immediately after the lint invocation so nothing
# in between can mask a transient mutation.
h_pre_assert_failures=$failures
assert_real_cap_untouched "during (h) ratchet breach"
set_cap "$BASELINE_CAP"
h_ok=1
if (( failures != h_pre_assert_failures )); then
  h_ok=0
fi
# Assert the guard RAN and failed for the ratchet reason — an exit 1 alone
# could come from any other check in the script.
if (( h_got != 1 )); then
  echo "FAIL — (h) ratchet breach: expected exit 1, got ${h_got}"
  h_ok=0
elif ! grep -qE "^::error file=[^:]*\.budget-soft-cap::Auto-loaded word count ${CURRENT_COUNT} exceeds ratchet cap ${H_CAP}" <<< "$h_out"; then
  echo "FAIL — (h) ratchet breach: no ::error annotation naming the ratchet cap"
  h_ok=0
elif grep -qE "^::warning file=[^:]*\.budget-soft-cap::" <<< "$h_out"; then
  echo "FAIL — (h) ratchet breach: cap breach was emitted as a ::warning"
  h_ok=0
elif ! grep -qF "See .claude/reference/budget-cap-raise-decision.md to raise the cap." <<< "$h_out"; then
  echo "FAIL — (h) ratchet breach: annotation does not point to the cap-raise decision record"
  h_ok=0
fi
case_num=$(( case_num + 1 ))
if (( h_ok == 1 )); then
  echo "ok   — (h) ratchet breach without --update-cap is a hard fail (exit 1 + ::error)"
else
  printf '%s\n' "$h_out" | sed 's/^/       /'
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
# (e) Real repo conformance — default run (no --update-cap), read-only
# ---------------------------------------------------------------------------
if ( cd "$REPO_ROOT" && bash "$REAL_LINT" >/dev/null 2>&1 ); then
  echo "ok   — (e) real repo conformance is intact"
else
  echo "FAIL — rule-lint.sh does not pass against the real repo"
  ( cd "$REPO_ROOT" && bash "$REAL_LINT" 2>&1 | sed 's/^/       /' ) || true
  failures=$(( failures + 1 ))
fi

# ---------------------------------------------------------------------------
# (g) Hermeticity — the real cap file survived the whole run untouched
# ---------------------------------------------------------------------------
before_g=$failures
assert_real_cap_untouched "(g) full run"
if (( failures == before_g )); then
  echo "ok   — (g) real .budget-soft-cap untouched (bytes + mtime) across the run"
fi

# ---------------------------------------------------------------------------
# Final result
# ---------------------------------------------------------------------------
if (( failures > 0 )); then
  echo "rule-lint.test: ${failures} failure(s)"
  exit 1
fi

echo "OK: rule-lint.test passed (${case_num} ratchet fixtures)"
