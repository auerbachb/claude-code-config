#!/usr/bin/env bash
# Offline review-tier tests for escalate-review.sh (issue #1728).
# catalog: tests — Review-tier `tier_gate` verdict tests for `escalate-review.sh`
# Shared fixtures live in tests/lib/escalate-review-fixtures.sh.
#
# WHAT IS UNDER TEST
#   A repo may declare review tiers (.claude/reference/review-policy.md). On a
#   ci-only or ci+codeant-one-round PR the escalation chain must never hand the
#   PR to BugBot: at the two points that emit switch_bugbot, the script emits
#   STATUS=tier_gate instead. full and legacy keep switch_bugbot, an
#   unresolvable tier falls back to switch_bugbot (fail-open), and every other
#   verdict — the grace window, the Greptile branches — is unchanged.
#   Since issue #1807 a repo can turn escalation off (REVIEW_ESCALATION=off):
#   then tier_gate also replaces trigger_greptile and budget_exhausted on any
#   gate, and the Greptile budget is never touched (cases e1–e8).
#
# HOW IT IS OBSERVED
#   The shared fixture copies no tier helper, which is how every older suite
#   keeps its switch_bugbot verdicts. This suite adds the REAL
#   bugbot-tier-excluded.sh plus a stub review-tier.sh whose answer each
#   scenario sets, and whose argument log proves which PR and repo were asked.
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/escalate-review-fixtures.sh
source "$TEST_DIR/lib/escalate-review-fixtures.sh"

cp "$REPO_ROOT/.claude/scripts/bugbot-tier-excluded.sh" "$STUB_DIR/bugbot-tier-excluded.sh"
chmod +x "$STUB_DIR/bugbot-tier-excluded.sh"
cat > "$STUB_DIR/review-tier.sh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$TIER_CALLS"
if [[ -n "${FIXTURE_TIER_OUT:-}" ]]; then printf '%s\n' "$FIXTURE_TIER_OUT"; fi
exit "${FIXTURE_TIER_RC:-0}"
STUB
export TIER_CALLS="$TMP/tier-calls"

tier_json() { printf '{"policy":"present","gate":"%s","tier":"t","source":"base:main","error":null,"matches":[]}' "$1"; }
set_tier() { # <resolver stdout> [resolver exit code]
  export FIXTURE_TIER_OUT="$1" FIXTURE_TIER_RC="${2:-0}"
  : > "$TIER_CALLS"
}
tier_calls() { tr '\n' ';' < "$TIER_CALLS"; }

# The two switch_bugbot shapes, each rebuilt per call (fresh timestamps).
shape_never_invited() {  # escalate-review-never-invited.test.sh (n1)
  reset_state
  write_commits "$(ts_seconds_ago 7200)"
  write_state "[]" "[]" "[]" "[]"
}
shape_genuine() {        # escalate-review-bugbot-classification.test.sh (b)
  reset_state
  write_commits "$(ts_seconds_ago 7200)"
  write_state "[$BUGBOT_CHECK_RUN_OK]" "[]" "[]" "[$(genuine_comment "$(ts_seconds_ago 7000)")]"
}

############################################################################
for gate in ci-only ci+codeant-one-round; do
  for shape in never_invited genuine; do
    echo "== (t1): $shape + gate $gate -> tier_gate, never switch_bugbot =="
    set_tier "$(tier_json "$gate")"
    "shape_$shape"
    OUT=$(run_script 2>/dev/null); RC=$?
    check_eq "exit 0" 0 "$RC"
    check_eq "STATUS=tier_gate" "STATUS=tier_gate" "$OUT"
    check_eq "resolver asked about THIS PR in THIS repo" \
      "$PR_NUM --repo $OWNER/$REPO --json;" "$(tier_calls)"
  done
done

############################################################################
for gate in full legacy; do
  for shape in never_invited genuine; do
    echo "== (t2): $shape + gate $gate -> switch_bugbot, exactly as today =="
    set_tier "$(tier_json "$gate")"
    "shape_$shape"
    OUT=$(run_script 2>/dev/null); RC=$?
    check_eq "exit 0" 0 "$RC"
    check_eq "STATUS=switch_bugbot" "STATUS=switch_bugbot" "$OUT"
  done
done

############################################################################
echo "== (t3): FAILS OPEN — the resolver fails -> switch_bugbot =="
set_tier "" 4
shape_never_invited
OUT=$(run_script 2>/dev/null); RC=$?
check_eq "exit 0 (an unresolvable tier is not a missing verdict)" 0 "$RC"
check_eq "STATUS=switch_bugbot" "STATUS=switch_bugbot" "$OUT"
check_eq "the resolver was actually consulted" "1" "$(grep -c . "$TIER_CALLS" | tr -d ' ')"

echo "== (t3b): FAILS OPEN — the helper cannot launch (not executable) -> switch_bugbot =="
set_tier "$(tier_json ci-only)"
chmod -x "$STUB_DIR/bugbot-tier-excluded.sh"
shape_never_invited
OUT=$(run_script 2>/dev/null); RC=$?
chmod +x "$STUB_DIR/bugbot-tier-excluded.sh"
check_eq "exit 0" 0 "$RC"
check_eq "STATUS=switch_bugbot despite a ci-only resolver" "STATUS=switch_bugbot" "$OUT"

############################################################################
# Precedence controls: an excluded tier changes ONLY the switch_bugbot outcome.
echo "== (t4): gate ci-only inside the grace window -> polling_cr (earlier verdict keeps precedence) =="
set_tier "$(tier_json ci-only)"
reset_state
seed_bugbot_absent
write_commits "$(ts_seconds_ago 120)"
write_state "[]" "[]" "[]" "[]"
OUT=$(run_script 2>/dev/null); RC=$?
check_eq "exit 0" 0 "$RC"
check_eq "STATUS=polling_cr" "STATUS=polling_cr" "$OUT"
check_eq "no tier lookup on a cycle that never reaches a switch" "" "$(tier_calls)"

echo "== (t5): gate ci-only + BugBot failure -> trigger_greptile (Greptile branch unchanged) =="
set_tier "$(tier_json ci-only)"
reset_state
write_commits "$(ts_seconds_ago 7200)"
write_state "[]" "[]" "[]" "[$(failure_comment "$(ts_seconds_ago 3000)")]"
OUT=$(run_script 2>/dev/null); RC=$?
check_eq "exit 0" 0 "$RC"
check_eq "STATUS=trigger_greptile" "STATUS=trigger_greptile" "$OUT"

echo "== (t6): gate ci-only + invited but silent -> trigger_greptile (Greptile branch unchanged) =="
set_tier "$(tier_json ci-only)"
reset_state
write_commits "$(ts_seconds_ago 7200)"
write_state "[]" "[]" "[]" "[$(trigger_comment "$(ts_seconds_ago 3000)")]"
OUT=$(run_script 2>/dev/null); RC=$?
check_eq "exit 0" 0 "$RC"
check_eq "STATUS=trigger_greptile" "STATUS=trigger_greptile" "$OUT"

echo "== (t7): --help documents the new verdict =="
HELP="$(bash "$STUB_DIR/escalate-review.sh" --help 2>/dev/null)"
check_eq "--help names STATUS=tier_gate" "1" "$(grep -c 'STATUS=tier_gate' <<<"$HELP" | tr -d ' ')"

############################################################################
# REVIEW_ESCALATION=off (issue #1807). The repo turned escalation off, so on
# ANY gate the chain never hands the PR to BugBot or Greptile: tier_gate where
# switch_bugbot, trigger_greptile or budget_exhausted would have been emitted,
# and the Greptile budget is never touched.
#
# The real greptile-budget.sh is swapped for a stub that logs every call and
# answers a controllable `exhausted`, so "never touched" is observed rather
# than inferred — and the on-controls below prove the log does record calls.
cat > "$STUB_DIR/greptile-budget.sh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$BUDGET_CALLS"
if [[ "${FIXTURE_BUDGET_EXHAUSTED:-false}" == "true" ]]; then
  printf '{"date":"2026-10-07","reviews_used":40,"budget":40,"exhausted":true}\n'
  exit 1
fi
printf '{"date":"2026-10-07","reviews_used":0,"budget":40,"exhausted":false}\n'
STUB
chmod +x "$STUB_DIR/greptile-budget.sh"
export BUDGET_CALLS="$TMP/budget-calls"
budget_calls() { tr '\n' ';' < "$BUDGET_CALLS"; }
tier_json_esc() { printf '{"policy":"present","gate":"%s","tier":"t","source":"base:main","error":null,"matches":[],"escalation":"%s"}' "$1" "$2"; }
set_escalation() { # <gate> <on|off> [budget exhausted: true|false]
  set_tier "$(tier_json_esc "$1" "$2")"
  export FIXTURE_BUDGET_EXHAUSTED="${3:-false}"
  : > "$BUDGET_CALLS"
}

# The two Greptile shapes, each rebuilt per call (fresh timestamps).
shape_bugbot_failed() {   # (t5): BugBot refused for a usage limit
  reset_state
  write_commits "$(ts_seconds_ago 7200)"
  write_state "[]" "[]" "[]" "[$(failure_comment "$(ts_seconds_ago 3000)")]"
}
shape_invited_silent() {  # (t6): invited, then silent past the grace window
  reset_state
  write_commits "$(ts_seconds_ago 7200)"
  write_state "[]" "[]" "[]" "[$(trigger_comment "$(ts_seconds_ago 3000)")]"
}

for gate in full legacy ci-only; do
  for shape in bugbot_failed invited_silent; do
    echo "== (e1): $shape + gate $gate + escalation off -> tier_gate, budget untouched =="
    set_escalation "$gate" off
    "shape_$shape"
    OUT=$(run_script 2>"$TMP/e1-stderr.txt"); RC=$?
    check_eq "exit 0" 0 "$RC"
    check_eq "STATUS=tier_gate, not trigger_greptile" "STATUS=tier_gate" "$OUT"
    check_eq "greptile-budget.sh never called (no --check, no --consume)" "" "$(budget_calls)"
    check_eq "resolver asked once, about THIS PR in THIS repo" \
      "$PR_NUM --repo $OWNER/$REPO --json;" "$(tier_calls)"
    check_eq "stderr names the reason" "1" "$(grep -c 'REVIEW_ESCALATION=off' "$TMP/e1-stderr.txt" | tr -d ' ')"
  done
done

echo "== (e2): budget exhausted + escalation off -> tier_gate, not budget_exhausted =="
set_escalation full off true
shape_bugbot_failed
OUT=$(run_script 2>/dev/null); RC=$?
check_eq "exit 0" 0 "$RC"
check_eq "STATUS=tier_gate" "STATUS=tier_gate" "$OUT"
check_eq "greptile-budget.sh never called" "" "$(budget_calls)"

echo "== (e3): CONTROL — the same shapes with escalation on keep today's verdicts =="
set_escalation full on
shape_bugbot_failed
OUT=$(run_script 2>/dev/null); RC=$?
check_eq "full + on + BugBot failure -> trigger_greptile" "STATUS=trigger_greptile" "$OUT"
check_eq "…and the budget stub saw the --check (so its silence above is real)" "--check;" "$(budget_calls)"
set_escalation full on true
shape_bugbot_failed
OUT=$(run_script 2>/dev/null); RC=$?
check_eq "full + on + exhausted budget -> budget_exhausted" "STATUS=budget_exhausted" "$OUT"
check_eq "…after one --check" "--check;" "$(budget_calls)"

for shape in never_invited genuine; do
  echo "== (e4): $shape + gate full + escalation off -> tier_gate at the BugBot arm =="
  set_escalation full off
  "shape_$shape"
  OUT=$(run_script 2>"$TMP/e4-stderr.txt"); RC=$?
  check_eq "exit 0" 0 "$RC"
  check_eq "STATUS=tier_gate, not switch_bugbot" "STATUS=tier_gate" "$OUT"
  check_eq "greptile-budget.sh never called" "" "$(budget_calls)"
  check_eq "the helper names escalation off as the reason" "1" "$(grep -c 'escalation off' "$TMP/e4-stderr.txt" | tr -d ' ')"
done

echo "== (e5): FAILS OPEN — resolver fails at the Greptile arm -> trigger_greptile as today =="
set_tier "" 4
export FIXTURE_BUDGET_EXHAUSTED=false
: > "$BUDGET_CALLS"
shape_bugbot_failed
OUT=$(run_script 2>"$TMP/e5-stderr.txt"); RC=$?
check_eq "exit 0 (an unresolvable switch is not a missing verdict)" 0 "$RC"
check_eq "STATUS=trigger_greptile" "STATUS=trigger_greptile" "$OUT"
check_eq "the resolver was actually consulted" "1" "$(grep -c . "$TIER_CALLS" | tr -d ' ')"
check_eq "stderr says the switch read as on" "1" "$(grep -c 'treating escalation as on' "$TMP/e5-stderr.txt" | tr -d ' ')"

echo "== (e6): FAILS OPEN — review-tier.sh missing -> trigger_greptile as today =="
set_escalation full off
mv "$STUB_DIR/review-tier.sh" "$TMP/review-tier.bak"
shape_bugbot_failed
OUT=$(run_script 2>/dev/null); RC=$?
mv "$TMP/review-tier.bak" "$STUB_DIR/review-tier.sh"
check_eq "STATUS=trigger_greptile" "STATUS=trigger_greptile" "$OUT"

echo "== (e7): a free wait still wins — escalation off inside a CR retry window -> polling_cr =="
set_escalation full off
reset_state
write_commits "$(ts_seconds_ago 7200)"
write_state "[]" "[]" "[]" "[$(failure_comment "$(ts_seconds_ago 3000)"), $(cr_limit_banner "$(ts_seconds_ago 60)" "12 minutes")]"
OUT=$(run_script 2>/dev/null); RC=$?
check_eq "STATUS=polling_cr" "STATUS=polling_cr" "$OUT"
check_eq "no tier lookup on a cycle that never reaches a hand-off" "" "$(tier_calls)"
check_eq "greptile-budget.sh never called" "" "$(budget_calls)"

echo "== (e8): --help documents escalation off =="
check_eq "--help names REVIEW_ESCALATION=off on the tier_gate verdict" "1" \
  "$(grep -c 'turned escalation off (REVIEW_ESCALATION=off' <<<"$HELP" | tr -d ' ')"
check_eq "--help documents the fail-open known limit" "1" \
  "$(grep -c 'ESCALATION OFF — KNOWN LIMIT' <<<"$HELP" | tr -d ' ')"

finish_escalate_review_tests "review-tier tier_gate"
