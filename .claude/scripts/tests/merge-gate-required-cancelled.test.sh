#!/usr/bin/env bash
# merge-gate-required-cancelled.test.sh — Offline integration tests for issue
# catalog: tests — Tests that `merge-gate.sh` does not score a cancelled or unknown-conclusion required check as passing
# #1846: a branch-protection REQUIRED check that ended `cancelled` read as a pass.
#
# The reported trace (auerbachb/sales-kit PR 319, HEAD 752daf7, CI run
# 37363347524 attempt 1, 2026-10-05): the required `install` job was cancelled
# after GitHub could not acquire a hosted runner, which left its five dependents
# (`typecheck`, `lint`, `build`, `test`, `migrate-check`) skipped. The installed
# gate answered `met: true`, `ci_status.passing: 8`, `missing: []` and
# `required_contexts.unsatisfied: []` while GitHub reported `BLOCKED`.
#
# Cause: the required-context evaluation was a BLACKLIST (`failure`, `timed_out`,
# `action_required`, `startup_failure`, `stale`). `cancelled`, and any conclusion
# GitHub adds later, fell through to "passing". The fix is a WHITELIST that
# mirrors GitHub's own rule — a required check is satisfied only by `success`,
# `neutral`, or `skipped`.
#
# This is the #1361 defect class again (a required signal that never reached a
# verdict scoring as a pass), through a present-but-cancelled signal rather than
# an absent one. The rest of that family lives in merge-gate-required-contexts.test.sh.
#
# What is deliberately NOT changed, and pinned here so a later edit fails loudly:
#   - a NON-required cancelled check stays non-blocking (issues #211, #1361)
#   - skipped-only, and success + skipped under one name, stay satisfied
#   - BLOCKED stays a diagnostic: it adds no `missing[]` entry of its own
#
# Cases:
#   (n) the verbatim PR 319 attempt-1 payload, BLOCKED -> NOT met, install named
#   (o) control: the same payload with install successful -> nothing unsatisfied,
#       and the end-to-end gate flips met true/false on that one check alone
#   (p) every conclusion against a required context, one by one
#   (q) a non-required cancelled check does not block
#   (r) same-name legs in one suite: success+cancelled fails, success+skipped holds
#   (s) a cancelled run from the wrong app is wrong_app, not cancelled
#
# Only `gh` is stubbed; merge-gate.sh, ci-status.sh and check-runs-dedup.sh are
# the real scripts. Shared harness lives in tests/lib/merge-gate-test-fixtures.sh.
# Run from repo root: bash .claude/scripts/tests/merge-gate-required-cancelled.test.sh

# The PR 319 HEAD, so the replay runs at the exact commit the incident did. Must
# be set BEFORE the fixture lib is sourced: the gh stub bakes it in when written.
FAKE_HEAD_SHA="752daf7943966629da8e6e86938af640f4f91b8f"
# shellcheck source=tests/lib/merge-gate-test-fixtures.sh
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/merge-gate-test-fixtures.sh"

check_contains() { # needle haystack label
  case "$2" in
    *"$1"*) ok "$3" ;;
    *) bad "$3 (missing '$1' in: $2)" ;;
  esac
}

OUT=""
RC=0
run_gate() { # $1 = check-runs JSON; extra args forwarded to merge-gate.sh
  local runs="$1"; shift
  OUT=$(PATH="$BIN:$PATH" FAKE_CHECK_RUNS="$runs" \
        FAKE_REVIEWS="${FAKE_REVIEWS:-[]}" \
        "$SUT" 1 --reviewer cr "$@" 2>/dev/null)
  RC=$?
}

unsat_state() { echo "$OUT" | jq -r --arg c "$1" '.required_contexts.unsatisfied[]? | select(.context == $c) | .state'; }
unsat_count() { echo "$OUT" | jq -r '.required_contexts.unsatisfied | length'; }
met() { echo "$OUT" | jq -r '.met'; }
missing_joined() { echo "$OUT" | jq -r '.missing | join(" | ")'; }

# Protection exactly as sales-kit main has it: seven contexts, each pinned to the
# GitHub Actions app (id 15368), strict off.
SK_CONTEXTS=(install typecheck lint build test migrate-check ac-gate)
sk_protection() { jq -cn --args '{strict: false, contexts: $ARGS.positional,
                                  checks: ($ARGS.positional | map({context: ., app_id: 15368}))}' -- "${SK_CONTEXTS[@]}"; }
protection() { jq -cn --args '{strict: true, contexts: $ARGS.positional,
                               checks: ($ARGS.positional | map({context: ., app_id: 15368}))}' -- "$@"; }

# A check-run record exactly as GitHub returned it for PR 319 (ids, suite ids,
# completion times and publisher are the originals; the unused fields are dropped).
real() { # id name conclusion completed_at suite_id
  jq -cn --argjson id "$1" --arg name "$2" --arg concl "$3" --arg at "$4" \
         --argjson suite "$5" --arg sha "$FAKE_HEAD_SHA" \
    '{id:$id, name:$name, status:"completed", conclusion:$concl, completed_at:$at,
      head_sha:$sha, check_suite:{id:$suite}, app:{id:15368, slug:"github-actions"}}'
}

# The eight check-runs of run 37363347524 attempt 1 (suite 101204331641), plus
# `ac-gate` from its own suite (101204331244). $1 = install's conclusion.
pr319_payload() {
  bundle \
    "$(real 111942835527 refresh-references success 2026-10-05T19:26:34Z 101204331641)" \
    "$(real 111942835888 install            "$1"    2026-10-05T19:41:04Z 101204331641)" \
    "$(real 111947875925 build              skipped 2026-10-05T19:41:04Z 101204331641)" \
    "$(real 111947875926 typecheck          skipped 2026-10-05T19:41:04Z 101204331641)" \
    "$(real 111947875974 migrate-check      skipped 2026-10-05T19:41:04Z 101204331641)" \
    "$(real 111947876178 test               skipped 2026-10-05T19:41:04Z 101204331641)" \
    "$(real 111947876977 lint               skipped 2026-10-05T19:41:04Z 101204331641)" \
    "$(real 111942834456 ac-gate            success 2026-10-05T19:31:30Z 101204331244)"
}

# Everything ELSE about the PR is mergeable — a fresh, substantive CodeRabbit
# APPROVED on HEAD, no threads, clean mergeability — so `met` can only move on the
# required-context signal. Without it, "met: false" could be any other blocker and
# the assertion would prove nothing about this fix.
export FAKE_REVIEWS
FAKE_REVIEWS=$(jq -cn --arg sha "$HEAD_SHA" '[{
  user: {login: "coderabbitai[bot]", type: "Bot"},
  state: "APPROVED", commit_id: $sha,
  submitted_at: "2026-10-05T20:00:00Z",
  body: "Reviewed all changed files in this pull request and found no blocking issues worth raising."
}]')

# --------------------------------------------------------------------------
# (n) The reported bug. This exact payload used to produce met:true, missing:[].
# --------------------------------------------------------------------------
FAKE_REQUIRED_STATUS_CHECKS="$(sk_protection)" \
FAKE_BRANCH_PROTECTED=true \
FAKE_MERGE_STATE=BLOCKED \
run_gate "$(pr319_payload cancelled)"
check_eq "752daf7943966629da8e6e86938af640f4f91b8f" "$(echo "$OUT" | jq -r '.head_sha')" \
  "(n) PR 319 replay: evaluated at the incident's exact HEAD"
check_eq 8 "$(echo "$OUT" | jq -r '.ci_status.total')" "(n) PR 319 replay: all eight check-runs present"
check_eq "false" "$(met)" "(n) PR 319 replay: gate NOT met (was met:true)"
check_eq 1 "$RC" "(n) PR 319 replay: exit 1"
check_eq 1 "$(unsat_count)" "(n) PR 319 replay: exactly one required context unsatisfied"
check_eq "cancelled" "$(unsat_state install)" "(n) PR 319 replay: it is install, state 'cancelled'"
check_eq 7 "$(echo "$OUT" | jq -r '.required_contexts.contexts | length')" \
  "(n) PR 319 replay: all seven required contexts were read"
check_eq "branch_protection" "$(echo "$OUT" | jq -r '.required_contexts.source')" \
  "(n) PR 319 replay: contexts came from the protection endpoint"
check_contains "install (cancelled)" "$(missing_joined)" \
  "(n) PR 319 replay: the missing[] reason names the check and its state"
check_eq 1 "$(echo "$OUT" | jq -r '.missing | length')" \
  "(n) PR 319 replay: that required-context entry is the ONLY blocker (BLOCKED adds none)"
check_eq "BLOCKED" "$(echo "$OUT" | jq -r '.merge_state')" \
  "(n) PR 319 replay: GitHub's BLOCKED is still reported as the diagnostic it was"
check_eq "true" "$(echo "$OUT" | jq -r '.primary_review_met')" \
  "(n) PR 319 replay: review coverage is unaffected — this is a CI-completeness blocker"
check_eq 0 "$(echo "$OUT" | jq -r '.ci_status.failing')" \
  "(n) PR 319 replay: the general CI count still treats cancelled as non-blocking (policy kept)"

# --------------------------------------------------------------------------
# (o) Control. Without it (n) could pass simply because the entry is always
#     emitted. Same payload, install successful: the five skipped dependents
#     must still satisfy their contexts, and `met` flips on install alone.
# --------------------------------------------------------------------------
FAKE_REQUIRED_STATUS_CHECKS="$(sk_protection)" \
FAKE_BRANCH_PROTECTED=true \
run_gate "$(pr319_payload success)"
check_eq 0 "$(unsat_count)" \
  "(o) install successful: nothing unsatisfied — five skipped dependents still satisfy"
check_eq "true" "$(met)" "(o) install successful: mergeable PR -> met"
check_eq 0 "$RC" "(o) install successful: exit 0"

FAKE_REQUIRED_STATUS_CHECKS="$(sk_protection)" \
FAKE_BRANCH_PROTECTED=true \
run_gate "$(pr319_payload cancelled)"
check_eq "false" "$(met)" "(o) same PR, install cancelled -> NOT met (the #1846 flip)"

# GitHub's BLOCKED and the required-context verdict are independent signals: the
# BLOCKED state must not change which contexts are satisfied in either direction.
FAKE_REQUIRED_STATUS_CHECKS="$(sk_protection)" \
FAKE_BRANCH_PROTECTED=true \
FAKE_MERGE_STATE=BLOCKED \
run_gate "$(pr319_payload success)"
check_eq 0 "$(unsat_count)" "(o) BLOCKED with install successful: still nothing unsatisfied"
check_eq "BLOCKED" "$(echo "$OUT" | jq -r '.merge_state')" "(o) BLOCKED is reported, not swallowed"

# --------------------------------------------------------------------------
# (p) The conclusion table for ONE required context. GitHub accepts exactly
#     success, neutral and skipped; the whitelist is what makes a value nobody
#     has seen yet fail closed.
# --------------------------------------------------------------------------
for concl in success neutral skipped; do
  FAKE_REQUIRED_STATUS_CHECKS="$(protection build)" \
  FAKE_BRANCH_PROTECTED=true \
  run_gate "$(bundle "$(cr 1 build "$concl" 100)")"
  check_eq 0 "$(unsat_count)" "(p) required context ending '$concl': satisfied"
done

for concl in cancelled failure timed_out action_required startup_failure stale brand_new_conclusion; do
  FAKE_REQUIRED_STATUS_CHECKS="$(protection build)" \
  FAKE_BRANCH_PROTECTED=true \
  run_gate "$(bundle "$(cr 1 build "$concl" 100)")"
  check_eq "$concl" "$(unsat_state build)" "(p) required context ending '$concl': unsatisfied, state names it"
  check_eq "false" "$(met)" "(p) required context ending '$concl': gate NOT met"
done

# A run marked completed that carries no conclusion at all cannot be read as a pass.
FAKE_REQUIRED_STATUS_CHECKS="$(protection build)" \
FAKE_BRANCH_PROTECTED=true \
run_gate "$(bundle "$(cr 1 build null 100)")"
check_eq "none" "$(unsat_state build)" "(p) completed with no conclusion: unsatisfied, state 'none'"

# --------------------------------------------------------------------------
# (q) The policy this fix must NOT disturb: a cancelled check that is not
#     required does not hold a merge. A superseded or concurrency-cancelled
#     optional run is noise; only a required one is a missing verdict.
# --------------------------------------------------------------------------
FAKE_REQUIRED_STATUS_CHECKS="$(protection build)" \
FAKE_BRANCH_PROTECTED=true \
run_gate "$(bundle "$(cr 1 build success 100)" "$(cr 2 'optional-scan' cancelled 100)")"
check_eq 0 "$(unsat_count)" "(q) non-required cancelled check: required context unaffected"
check_eq 0 "$(echo "$OUT" | jq -r '.ci_status.failing')" "(q) non-required cancelled check: not counted failing"
check_eq "true" "$(met)" "(q) non-required cancelled check: gate still met"

# And with no protection at all the pre-#1361 behaviour is untouched.
run_gate "$(bundle "$(cr 1 build cancelled 100)")"
check_eq "none" "$(echo "$OUT" | jq -r '.required_contexts.source')" "(q) unprotected base: no required contexts"
check_eq "true" "$(met)" "(q) unprotected base: a cancelled check does not block (nothing requires it)"

# --------------------------------------------------------------------------
# (r) Two same-named runs in one suite (the still-point `build` shape from
#     #1361). Every leg must satisfy: a skipped leg is fine beside a success,
#     a cancelled leg is not.
# --------------------------------------------------------------------------
FAKE_REQUIRED_STATUS_CHECKS="$(protection build)" \
FAKE_BRANCH_PROTECTED=true \
run_gate "$(bundle "$(cr 1 build success 100)" "$(cr 2 build cancelled 100)")"
check_eq "cancelled" "$(unsat_state build)" "(r) success + cancelled legs in one suite: unsatisfied"

FAKE_REQUIRED_STATUS_CHECKS="$(protection build)" \
FAKE_BRANCH_PROTECTED=true \
run_gate "$(bundle "$(cr 1 build success 100)" "$(cr 2 build skipped 100)")"
check_eq 0 "$(unsat_count)" "(r) success + skipped legs in one suite: still satisfied"

# A cancelled run in a SUPERSEDED suite is not the verdict: dedup (#675) keeps
# only the newest suite, so a re-run that succeeded clears an earlier cancel.
FAKE_REQUIRED_STATUS_CHECKS="$(protection build)" \
FAKE_BRANCH_PROTECTED=true \
run_gate "$(bundle "$(cr 1 build cancelled 100)" "$(cr 2 build success 200)")"
check_eq 0 "$(unsat_count)" "(r) cancelled in an older suite, success in the newest: satisfied (re-run clears it)"

FAKE_REQUIRED_STATUS_CHECKS="$(protection build)" \
FAKE_BRANCH_PROTECTED=true \
run_gate "$(bundle "$(cr 1 build success 100)" "$(cr 2 build cancelled 200)")"
check_eq "cancelled" "$(unsat_state build)" "(r) success in an older suite, cancelled in the newest: unsatisfied"

# --------------------------------------------------------------------------
# (s) Publisher scoping (#1383) is checked before the conclusion. A cancelled
#     run from an app protection does not accept is not the required check's
#     verdict at all; it must stay `wrong_app`, not turn into `cancelled`.
# --------------------------------------------------------------------------
FAKE_REQUIRED_STATUS_CHECKS="$(protection rule-lint)" \
FAKE_BRANCH_PROTECTED=true \
run_gate "$(bundle "$(cr 1 'rule-lint' cancelled 100 impostor completed 99)")"
check_eq "wrong_app" "$(unsat_state rule-lint)" "(s) cancelled run from the wrong app: wrong_app, not cancelled"

# ...and a cancelled impostor does not veto the required app's own passing check.
FAKE_REQUIRED_STATUS_CHECKS="$(protection rule-lint)" \
FAKE_BRANCH_PROTECTED=true \
run_gate "$(bundle \
  "$(cr 1 'rule-lint' cancelled 100 impostor completed 99)" \
  "$(cr 2 'rule-lint' success 100 gha completed 15368)")"
check_eq 0 "$(unsat_count)" "(s) a cancelled impostor does not veto the required app's passing check"

unset FAKE_REVIEWS

echo "----------------------------------------"
echo "merge-gate-required-cancelled.test.sh: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
