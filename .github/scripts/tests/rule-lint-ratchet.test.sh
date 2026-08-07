#!/usr/bin/env bash
# Ratchet suite for rule-lint.sh --update-cap (extracted from rule-lint.test.sh).
#
# Covers ratchet-subsystem cases (a–d, f–h) and hermeticity case (g):
#   (a) small cut  → formula exceeds current cap  → cap unchanged (ratchet holds)
#   (b) large cut  → formula below current cap    → cap lowered to formula
#   (c) --allow-raise                             → cap raised, old/new/delta printed
#   (d) bootstrap  → corrupt/missing prior cap    → formula result written
#   (f) equal case → formula == current cap       → unchanged, no "would raise" message
#   (g) hermeticity — the real cap file was never written during the run
#   (h) ratchet breach (no --update-cap)          → hard fail: exit 1 + ::error (#879)
#
# Index-alignment and per-file-size tests live in rule-lint.test.sh (cases e, i).
# Real-repo conformance (case e) lives in rule-lint.test.sh.
#
# Shared sandbox setup and fixture helpers are sourced from:
#   lib/rule-lint-sandbox.sh
#
# HERMETICITY (issue #906)
# Every --update-cap fixture runs against a disposable sandbox copy of the
# working tree, never the real checkout. The shared lib sets up the sandbox.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

failures=0
case_num=0

# Source the shared sandbox setup (sets SANDBOX, LINT, CAP_FILE, BASELINE_CAP,
# CURRENT_COUNT, FORMULA, REAL_CAP_FILE, REAL_CAP_FINGERPRINT, and defines
# the fixture helper functions).
# shellcheck source=lib/rule-lint-sandbox.sh
source "${SCRIPT_DIR}/lib/rule-lint-sandbox.sh"

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
# PR-body justification line — and that it stays an ERROR while doing so. This
# case pins the decided behaviour so a future edit cannot silently soften it
# back; see .claude/reference/budget-cap-raise-decision.md.
#
# Runs WITHOUT --update-cap, so it needs its own runner rather than expect().
H_CAP=$(( CURRENT_COUNT - 1 ))   # corpus overruns the committed cap by 1 word
set_cap "$H_CAP"
h_out=""
h_got=0
h_out=$( ( cd "$SANDBOX" && bash "$LINT" 2>&1 ) ) || h_got=$?

# Fingerprint the real cap file before any cleanup runs.
h_pre_assert_failures=$failures
assert_real_cap_untouched "during (h) ratchet breach"
set_cap "$BASELINE_CAP"
h_ok=1
if (( failures != h_pre_assert_failures )); then
  h_ok=0
fi
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
  echo "rule-lint-ratchet.test: ${failures} failure(s)"
  exit 1
fi

echo "OK: rule-lint-ratchet.test passed (${case_num} ratchet fixtures)"
