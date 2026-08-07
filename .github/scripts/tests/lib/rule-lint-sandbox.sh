#!/usr/bin/env bash
# Shared sandbox construction and fixture helpers for rule-lint test suites.
# Source this file; do NOT execute it directly.
#
# This file intentionally does not end in .test.sh so run-hook-tests.sh will
# not execute it as a standalone test suite.
#
# Provides:
#   SANDBOX          — path to a disposable working-tree copy; every mutating
#                      fixture operates here and never touches the real repo
#   LINT             — path to rule-lint.sh inside the sandbox
#   REAL_LINT        — path to the real rule-lint.sh (for case e read-only run)
#   REAL_CAP_FILE    — path to the real .budget-soft-cap
#   CAP_FILE         — path to .budget-soft-cap inside the sandbox
#   BASELINE_CAP     — integer cap value at sandbox construction time
#   CURRENT_COUNT    — word count of the sandbox corpus (CLAUDE.md + rules)
#   FORMULA          — ratchet formula result: max(CURRENT_COUNT+750, 8500)
#   RATCHET_HEADROOM — 750 (matches production constant)
#   RATCHET_FLOOR    — 8500 (matches production constant)
#
#   real_cap_fingerprint()   — sha256+mtime+size of REAL_CAP_FILE
#   assert_real_cap_untouched WHERE — records a failure if real cap changed
#   set_cap VALUE            — write VALUE into sandbox CAP_FILE
#   read_cap                 — cat the sandbox CAP_FILE
#   read_cap_value FILE      — validate and print the integer in FILE
#   run_update_cap [flags…]  — run sandbox rule-lint.sh --update-cap [flags]
#   expect NAME EXIT RE PRE POST [flags…]  — single ratchet fixture

set -uo pipefail   # -e intentionally omitted: sourcing files may set it; callers own it

REPO_ROOT="$(git rev-parse --show-toplevel)"
REAL_LINT="${REPO_ROOT}/.github/scripts/rule-lint.sh"
REAL_CAP_FILE="${REPO_ROOT}/.claude/rules/.budget-soft-cap"

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
  source_path="${REPO_ROOT}/${f}"
  if [[ ! -e "$source_path" && ! -L "$source_path" ]]; then
    continue
  fi
  mkdir -p "${SANDBOX}/$(dirname "$f")"
  cp "$source_path" "${SANDBOX}/${f}"
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
# ever happened.
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
# a future `pre_cap="keep"` case still means "the baseline value".
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
  case_num=$(( case_num + 1 ))

  if [[ "$pre_cap" != "keep" ]]; then
    set_cap "$pre_cap"
  fi

  local out=""
  local got=0
  out=$(run_update_cap "$@") || got=$?

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
