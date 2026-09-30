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

finish_escalate_review_tests "review-tier tier_gate"
