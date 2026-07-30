#!/usr/bin/env bash
# Unit tests for rule-lint.sh --update-cap one-way ratchet (issue #832)
#
# Covers the acceptance criteria:
#   (a) small cut  → formula exceeds current cap  → cap unchanged (ratchet holds)
#   (b) large cut  → formula below current cap    → cap lowered to formula
#   (c) --allow-raise                             → cap raised, old/new/delta printed
# Plus three bonus cases:
#   (d) bootstrap  → corrupt/missing prior cap    → formula result written
#   (e) real repo conformance (default run, no --update-cap)
#   (f) equal case → formula == current cap       → unchanged, no "would raise" message

set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
LINT="${REPO_ROOT}/.github/scripts/rule-lint.sh"
CAP_FILE="${REPO_ROOT}/.claude/rules/.budget-soft-cap"

failures=0
case_num=0

# ---------------------------------------------------------------------------
# Save the cap and restore it on EXIT so every test starts from a known state
# and a test failure cannot corrupt the cap file permanently.
# ---------------------------------------------------------------------------
ORIG_CAP=""
ORIG_CAP="$(python3 - "$CAP_FILE" <<'PY'
import re, sys
data = open(sys.argv[1], "rb").read()
if not re.fullmatch(rb"[0-9]+(\r?\n)?", data):
    sys.stderr.write("INVALID CAP FILE\n")
    sys.exit(1)
sys.stdout.write(str(int(data.strip().decode("ascii"))))
PY
)" || { echo "BAIL: could not read initial cap value from ${CAP_FILE}"; exit 1; }

trap 'printf "%s" "$ORIG_CAP" > "$CAP_FILE"' EXIT

set_cap() {
  printf '%s' "$1" > "$CAP_FILE"
}

read_cap() {
  cat "$CAP_FILE"
}

# Run rule-lint.sh --update-cap [extra flags] from REPO_ROOT.
# Returns combined stdout+stderr; exits with the script's exit code.
# "$@" expansion of an empty "$@" is safe under set -u (unlike "${arr[@]}").
run_update_cap() {
  ( cd "$REPO_ROOT" && bash "$LINT" --update-cap "$@" 2>&1 )
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

  if (( got != want_exit )); then
    echo "FAIL — ${name}: expected exit ${want_exit}, got ${got}"
    echo "$out" | sed 's/^/       /'
    failures=$(( failures + 1 ))
    printf '%s' "$ORIG_CAP" > "$CAP_FILE"
    return
  fi

  if ! grep -qE "$want_re" <<< "$out"; then
    echo "FAIL — ${name}: exit ${got} as expected, but output did not match /${want_re}/"
    echo "$out" | sed 's/^/       /'
    failures=$(( failures + 1 ))
    printf '%s' "$ORIG_CAP" > "$CAP_FILE"
    return
  fi

  if [[ "$post_cap" != "any" ]]; then
    local actual_cap
    actual_cap=$(read_cap)
    if [[ "$actual_cap" != "$post_cap" ]]; then
      echo "FAIL — ${name}: cap expected ${post_cap}, got ${actual_cap}"
      echo "$out" | sed 's/^/       /'
      failures=$(( failures + 1 ))
      printf '%s' "$ORIG_CAP" > "$CAP_FILE"
      return
    fi
  fi

  echo "ok   — ${name}"
  printf '%s' "$ORIG_CAP" > "$CAP_FILE"
}

# ---------------------------------------------------------------------------
# Derive the formula value for the current corpus so tests self-calibrate
# even when the word count changes.
# ---------------------------------------------------------------------------
RATCHET_HEADROOM=750
RATCHET_FLOOR=8500
# Count words using wc -l via pipe (avoid grep -c exit-1 on empty output).
CURRENT_COUNT=""
CURRENT_COUNT="$(cd "$REPO_ROOT" && cat CLAUDE.md .claude/rules/*.md | wc -w | tr -d ' ')"
FORMULA=$(( CURRENT_COUNT + RATCHET_HEADROOM ))
if (( FORMULA < RATCHET_FLOOR )); then
  FORMULA=$RATCHET_FLOOR
fi
echo "# corpus=${CURRENT_COUNT} words, formula cap=${FORMULA}"

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
# (e) Real repo conformance — default run (no --update-cap)
# ---------------------------------------------------------------------------
if ( cd "$REPO_ROOT" && bash "$LINT" >/dev/null 2>&1 ); then
  echo "ok   — (e) real repo conformance is intact"
else
  echo "FAIL — rule-lint.sh does not pass against the real repo"
  ( cd "$REPO_ROOT" && bash "$LINT" 2>&1 | sed 's/^/       /' ) || true
  failures=$(( failures + 1 ))
fi

# ---------------------------------------------------------------------------
# Final result
# ---------------------------------------------------------------------------
if (( failures > 0 )); then
  echo "rule-lint.test: ${failures} failure(s)"
  exit 1
fi

echo "OK: rule-lint.test passed (${case_num} ratchet fixtures)"
