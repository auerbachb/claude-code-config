#!/usr/bin/env bash
# Offline tests: escalate-review.sh never hands a PR to a paid reviewer (issue #1897).
# catalog: tests — No-paid-review verdict tests for `escalate-review.sh`: no_reviewer, never switch_bugbot/trigger_greptile
# Shared fixtures live in tests/lib/escalate-review-fixtures.sh.
#
# Owner policy: no paid AI review (BugBot, Greptile) without explicit approval
# in chat. Every fixture below is CodeRabbit-rate-limited (write_state always
# includes CR_RATE_LIMIT_CHECK_RUN) and old enough that every grace window has
# closed, so each one reaches a point that used to emit switch_bugbot or
# trigger_greptile. Each must now print exactly `STATUS=no_reviewer`, name the
# refused route on stderr, and leave the Greptile budget ledger untouched.
#
# The override rows pin the #1899 integration: once merge-gate.sh is met through
# the no-review override, the same paid points answer gate_met instead — the
# blocked paid path falls through to the override rather than stalling.
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/escalate-review-fixtures.sh
source "$TEST_DIR/lib/escalate-review-fixtures.sh"

budget_used() {
  jq -r '[.. | objects | select(has("reviews_used")) | .reviews_used] | first // 0' \
    "$HOME/.claude/session-state.json" 2>/dev/null || echo 0
}

# <label> <expected route> — run, then assert the whole contract.
assert_denied() {
  local label="$1" route="$2" out rc=0 before after
  before="$(budget_used)"
  out="$(run_script_raw 2>"$TMP/pd-stderr.txt")" || rc=$?
  after="$(budget_used)"
  check_eq "($label) exit 0" 0 "$rc"
  check_eq "($label) stdout is exactly STATUS=no_reviewer" "STATUS=no_reviewer" "$out"
  check_eq "($label) never switch_bugbot or trigger_greptile" "0" \
    "$(grep -cE 'switch_bugbot|trigger_greptile|budget_exhausted' <<<"$out" || true)"
  check_eq "($label) stderr names the refused route" "1" \
    "$(grep -c "paid_route=$route" "$TMP/pd-stderr.txt" || true)"
  check_eq "($label) stderr says owner approval is required" "1" \
    "$(grep -c "explicit approval in chat" "$TMP/pd-stderr.txt" || true)"
  check_eq "($label) Greptile budget not consumed" "$before" "$after"
}

echo "== (p1): BugBot genuine response -> no_reviewer, not switch_bugbot =="
reset_state
write_commits "$(ts_seconds_ago 7200)"
write_state "[$BUGBOT_CHECK_RUN_OK]" "[]" "[]" "[$(genuine_comment "$(ts_seconds_ago 3000)")]"
assert_denied p1 switch_bugbot

echo "== (p2): BugBot never invited -> no_reviewer, nothing posted =="
reset_state
write_commits "$(ts_seconds_ago 7200)"
write_state "[]" "[]" "[]" "[]"
assert_denied p2 switch_bugbot

echo "== (p3): BugBot refused for a usage limit -> no_reviewer, not trigger_greptile =="
reset_state
write_commits "$(ts_seconds_ago 7200)"
write_state "[]" "[]" "[]" "[$(failure_comment "$(ts_seconds_ago 3000)")]"
assert_denied p3 trigger_greptile

echo "== (p4): BugBot invited but silent past the grace window -> no_reviewer =="
reset_state
write_commits "$(ts_seconds_ago 7200)"
write_state "[]" "[]" "[]" "[$(trigger_comment "$(ts_seconds_ago 3000)")]"
assert_denied p4 trigger_greptile

echo "== (p5): an exhausted Greptile budget is never even read -> no_reviewer, not budget_exhausted =="
reset_state
"$STUB_DIR/session-state.sh" --set '.greptile_daily={"date":"'"$(TZ=America/New_York date +%F)"'","reviews_used":40,"budget":40}' >/dev/null 2>&1 \
  || { echo "FAIL — could not seed the exhausted Greptile budget"; exit 1; }
check_eq "(p5) premise: budget seeded as exhausted" "40" "$(budget_used)"
write_commits "$(ts_seconds_ago 7200)"
write_state "[]" "[]" "[]" "[$(failure_comment "$(ts_seconds_ago 3000)")]"
assert_denied p5 trigger_greptile

echo "== (p6): no-review override met -> gate_met at both paid points (issue #1899 fall-through) =="
# merge-gate.sh stub answering "met through the override", plus a gh that
# reports the cwd repo as the PR's repo (override_gate_met refuses otherwise).
cat > "$STUB_DIR/merge-gate.sh" <<'STUB'
#!/usr/bin/env bash
printf '{"met":true,"no_review_override":{"applied":true}}\n'
STUB
chmod +x "$STUB_DIR/merge-gate.sh"
OVR_BIN="$TMP/ovr-bin"
mkdir -p "$OVR_BIN"
cat > "$OVR_BIN/gh" <<STUB
#!/usr/bin/env bash
if [[ "\${1:-}" == "repo" && "\${2:-}" == "view" ]]; then echo "$OWNER/$REPO"; exit 0; fi
exec "$STUB_BIN/gh" "\$@"
STUB
chmod +x "$OVR_BIN/gh"
for shape in never_invited refused; do
  reset_state
  write_commits "$(ts_seconds_ago 7200)"
  if [[ "$shape" == "refused" ]]; then
    write_state "[]" "[]" "[]" "[$(failure_comment "$(ts_seconds_ago 3000)")]"
  else
    write_state "[]" "[]" "[]" "[]"
  fi
  OUT="$(PATH="$OVR_BIN:$PATH" run_script_raw 2>"$TMP/p6-stderr.txt")"; RC=$?
  check_eq "(p6 $shape) exit 0" 0 "$RC"
  check_eq "(p6 $shape) STATUS=gate_met" "STATUS=gate_met" "$OUT"
  check_eq "(p6 $shape) stderr names the override" "1" \
    "$(grep -c 'no-review override' "$TMP/p6-stderr.txt" || true)"
done
# Control: the same stub answering "not met" falls back to no_reviewer, so the
# gate_met above is the override's doing.
cat > "$STUB_DIR/merge-gate.sh" <<'STUB'
#!/usr/bin/env bash
printf '{"met":false,"no_review_override":{"applied":false}}\n'
exit 1
STUB
reset_state
write_commits "$(ts_seconds_ago 7200)"
write_state "[]" "[]" "[]" "[]"
OUT="$(PATH="$OVR_BIN:$PATH" run_script_raw 2>/dev/null)"
check_eq "(p6 control) override not met -> no_reviewer" "STATUS=no_reviewer" "$OUT"
rm -f "$STUB_DIR/merge-gate.sh"

echo "== (p7): no bypass — the script carries no paid emit outside the denial =="
SRC="$REPO_ROOT/.claude/scripts/escalate-review.sh"
check_eq "no literal emit of a paid verdict" "0" \
  "$(grep -cE 'emit "(switch_bugbot|trigger_greptile|budget_exhausted)"' "$SRC" || true)"
check_eq "--help documents no_reviewer" "1" \
  "$(bash "$SRC" --help 2>/dev/null | grep -c 'STATUS=no_reviewer' || true)"

finish_escalate_review_tests "paid-review denial"
