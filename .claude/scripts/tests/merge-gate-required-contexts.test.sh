#!/usr/bin/env bash
# merge-gate-required-contexts.test.sh — Offline integration tests for issue
# #1361: merge-gate.sh scored a clean pass when every branch-protection required
# context was ABSENT from HEAD.
#
# The observed trace (auerbachb/still-point PR #673, HEAD 4688aea, during the
# 2026-08-26 GitHub Actions major outage): five required contexts — typecheck,
# StillPointShared swift test, build, unit-tests, Info.plist in sync with
# project.yml — had NO check-runs at all, because `unit-tests.yml` and
# `infoplist-sync.yml` ended in `startup_failure` with zero jobs. The only runs
# present were four non-required ones (Cursor Bugbot, Graphite / AI Reviews,
# Vercel Agent Review, Vercel Preview Comments), all green. Result:
# `ci_status: 4/4 passed`, `met: true`, `missing: []`.
#
# The defect class is distinct from #962 / #875 / #1219, which are all about a
# PRESENT signal being misread. This one is an ABSENT signal read as success —
# and it inverts the gate: the less CI reports, the cleaner the PR looks. A
# total CI outage produces the most confident green.
#
# Cases:
#   (a) every required context absent          -> NOT satisfied, all named
#   (b) required present + success             -> satisfied, no new entry
#   (c) two same-named runs in one suite, one
#       skipped one success (still-point ships
#       a `build` from TestFlight and a `build`
#       from Web Build)                        -> satisfied; skipped does not veto
#   (d) superseded failure + newer success     -> satisfied (#675 dedup consumed)
#   (e) no branch protection (404)             -> pre-#1361 behaviour, unchanged
#   (f) required present but in_progress       -> NOT satisfied
#   (g) required present but failing           -> NOT satisfied
#   (h) protection unreadable                  -> BLOCKS, says so, never "clean"
#   (i) --allow-unverified-required-checks     -> clears (h) only
#   (j) protection endpoint refused, branch
#       object readable                        -> falls back, still enforces
#   (k) commit status satisfies a context      -> satisfied (not check-runs only)
#   (l) end-to-end control pair: an otherwise
#       fully mergeable PR flips met true/false
#       on this signal alone
#
# Only `gh` is stubbed; merge-gate.sh, ci-status.sh and check-runs-dedup.sh are
# the real scripts. Shared harness lives in tests/lib/merge-gate-test-fixtures.sh.
# Run from repo root: bash .claude/scripts/tests/merge-gate-required-contexts.test.sh
# shellcheck source=tests/lib/merge-gate-test-fixtures.sh
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/merge-gate-test-fixtures.sh"

OUT=""
RC=0
run_gate() { # $1 = check-runs JSON; extra args forwarded to merge-gate.sh
  local runs="$1"; shift
  OUT=$(PATH="$BIN:$PATH" FAKE_CHECK_RUNS="$runs" \
        FAKE_REVIEWS="${FAKE_REVIEWS:-[]}" \
        "$SUT" 1 --reviewer cr "$@" 2>/dev/null)
  RC=$?
}

# Does `missing` carry the required-context blocker?
has_required_entry() {
  echo "$OUT" | jq -e '[.missing[]? | select(contains("branch protection requires status check"))] | length > 0' \
    >/dev/null && echo yes || echo no
}
has_unreadable_entry() {
  echo "$OUT" | jq -e '[.missing[]? | select(contains("cannot read branch-protection required status checks"))] | length > 0' \
    >/dev/null && echo yes || echo no
}
req_field() { echo "$OUT" | jq -r ".required_contexts.$1"; }
unsat_state() { echo "$OUT" | jq -r --arg c "$1" '.required_contexts.unsatisfied[]? | select(.context == $c) | .state'; }

# A protection payload naming the given contexts, in the endpoint's own shape
# (both the legacy `contexts` list and the newer app-scoped `checks` array, which
# is what the UI writes today — merge-gate.sh unions them).
protection() { jq -cn --args '{strict: true, contexts: $ARGS.positional,
                               checks: ($ARGS.positional | map({context: ., app_id: 15368}))}' -- "$@"; }

# The still-point required list, verbatim.
SP_CONTEXTS=(typecheck "StillPointShared swift test" build unit-tests "Info.plist in sync with project.yml")

# --------------------------------------------------------------------------
# (a) The reported bug: every required context absent, only green non-required
#     runs present. This exact payload used to produce met:true, missing:[].
# --------------------------------------------------------------------------
FAKE_REQUIRED_STATUS_CHECKS="$(protection "${SP_CONTEXTS[@]}")" \
FAKE_BRANCH_PROTECTED=true \
run_gate "$(bundle \
  "$(cr 1 'Cursor Bugbot' success 100 cursor)" \
  "$(cr 2 'Graphite / AI Reviews' success 100 graphite-app)" \
  "$(cr 3 'Vercel Agent Review' success 100 vercel)" \
  "$(cr 4 'Vercel Preview Comments' success 100 vercel)")"
check_eq 0 "$(echo "$OUT" | jq -r '.ci_status.failing')" \
  "(a) outage trace: ci_status still reports zero failures — the old signal"
check_eq "yes" "$(has_required_entry)" \
  "(a) outage trace: required-context blocker present (was met:true, missing:[])"
check_eq "false" "$(echo "$OUT" | jq -r '.met')" "(a) outage trace: gate NOT met"
check_eq 1 "$RC" "(a) outage trace: exit 1"
check_eq 5 "$(echo "$OUT" | jq -r '.required_contexts.unsatisfied | length')" \
  "(a) outage trace: all five required contexts reported unsatisfied"
check_eq "absent" "$(unsat_state build)" "(a) outage trace: state is 'absent', not 'failing'"
check_eq "absent" "$(unsat_state 'Info.plist in sync with project.yml')" \
  "(a) outage trace: a context whose name contains dots is matched literally"
check_eq "branch_protection" "$(req_field source)" "(a) outage trace: source is the protection endpoint"
check_contains "typecheck (absent)" "$(echo "$OUT" | jq -r '.missing | join(" | ")')" \
  "(a) outage trace: the missing[] reason names the context and its state"

# --------------------------------------------------------------------------
# (b) Negative control — required contexts PRESENT and successful.
#     Without this, (a) could pass simply because the entry is always emitted.
# --------------------------------------------------------------------------
FAKE_REQUIRED_STATUS_CHECKS="$(protection typecheck build)" \
FAKE_BRANCH_PROTECTED=true \
run_gate "$(bundle "$(cr 1 typecheck success 100)" "$(cr 2 build success 100)")"
check_eq "no" "$(has_required_entry)" "(b) present + success: no required-context blocker"
check_eq 0 "$(echo "$OUT" | jq -r '.required_contexts.unsatisfied | length')" \
  "(b) present + success: nothing unsatisfied"
check_eq 2 "$(echo "$OUT" | jq -r '.required_contexts.contexts | length')" \
  "(b) present + success: both contexts recorded"

# --------------------------------------------------------------------------
# (c) The dedup trap named in #1361: still-point publishes a `build` check-run
#     from the TestFlight workflow and another from Web Build. Both are GitHub
#     Actions, so check-runs-dedup.sh groups them under one (app, name) key —
#     and because Actions puts every workflow triggered by one event into ONE
#     check suite, BOTH survive the newest-suite filter. The required context
#     must be satisfied by the successful leg without the skipped leg vetoing
#     it: `skipped` is non-blocking under the same rule ci-status.sh applies.
# --------------------------------------------------------------------------
FAKE_REQUIRED_STATUS_CHECKS="$(protection build)" \
FAKE_BRANCH_PROTECTED=true \
run_gate "$(bundle "$(cr 1 build skipped 100)" "$(cr 2 build success 100)")"
check_eq "no" "$(has_required_entry)" \
  "(c) skipped TestFlight build beside a successful Web Build build: context satisfied"
check_eq 0 "$(echo "$OUT" | jq -r '.ci_status.failing')" "(c) skipped leg does not fail CI either"

# A required context whose ONLY run was skipped is still satisfied — same rule,
# stated separately so a later change to it fails loudly rather than silently.
FAKE_REQUIRED_STATUS_CHECKS="$(protection build)" \
FAKE_BRANCH_PROTECTED=true \
run_gate "$(bundle "$(cr 1 build skipped 100)")"
check_eq "no" "$(has_required_entry)" "(c) skipped-only required context: non-blocking, per cr-merge-gate.md"

# --------------------------------------------------------------------------
# (d) The by-name assertion consumes the DEDUPED list (#675): a superseded
#     failure must not mark a required context failed.
# --------------------------------------------------------------------------
FAKE_REQUIRED_STATUS_CHECKS="$(protection build)" \
FAKE_BRANCH_PROTECTED=true \
run_gate "$(bundle "$(cr 1 build failure 100)" "$(cr 2 build success 200)")"
check_eq "no" "$(has_required_entry)" "(d) superseded failure + newer success: context satisfied"

# --------------------------------------------------------------------------
# (e) No branch protection at all -> exactly the pre-#1361 behaviour. This is
#     the compatibility guarantee: an unprotected repo gains no new blocker.
# --------------------------------------------------------------------------
run_gate "$(bundle "$(cr 1 'Some Check' success 100)")"
check_eq "no" "$(has_required_entry)" "(e) unprotected base: no required-context blocker"
check_eq "no" "$(has_unreadable_entry)" "(e) unprotected base: not reported as unreadable either"
check_eq "none" "$(req_field source)" "(e) unprotected base: source 'none'"
check_eq 0 "$(echo "$OUT" | jq -r '.required_contexts.contexts | length')" \
  "(e) unprotected base: empty context list"

# Protected, but with no required status checks configured (review-only
# protection) — also `none`, and also must not wedge the repo.
FAKE_BRANCH_PROTECTED=true \
run_gate "$(bundle "$(cr 1 'Some Check' success 100)")"
check_eq "no" "$(has_required_entry)" "(e) protected with no required checks: no blocker"
check_eq "none" "$(req_field source)" "(e) protected with no required checks: source 'none'"

# --------------------------------------------------------------------------
# (f) Present but not finished. "Not finished" is not "passed" — the null
#     conclusion of an in-progress run is exactly what #1361 warns about.
# --------------------------------------------------------------------------
FAKE_REQUIRED_STATUS_CHECKS="$(protection build)" \
FAKE_BRANCH_PROTECTED=true \
run_gate "$(bundle "$(cr 1 build null 100 gha in_progress)")"
check_eq "yes" "$(has_required_entry)" "(f) in-progress required context: blocked"
check_eq "in_progress" "$(unsat_state build)" "(f) in-progress required context: state names the status"

# --------------------------------------------------------------------------
# (g) Present and failing -> unsatisfied, with the conclusion as the state.
# --------------------------------------------------------------------------
FAKE_REQUIRED_STATUS_CHECKS="$(protection build)" \
FAKE_BRANCH_PROTECTED=true \
run_gate "$(bundle "$(cr 1 build failure 100)")"
check_eq "yes" "$(has_required_entry)" "(g) failing required context: blocked"
check_eq "failure" "$(unsat_state build)" "(g) failing required context: state is the conclusion"

# --------------------------------------------------------------------------
# (h) Degraded read. #1361 is explicit that degraded must mean SAY SO, not
#     score clean: a required check that never reported is indistinguishable
#     from no requirement, so an unreadable list fails closed.
# --------------------------------------------------------------------------
FAKE_BRANCH_JSON='{"message":"Not Found","status":"404"}' \
run_gate "$(bundle "$(cr 1 'Some Check' success 100)")"
check_eq "yes" "$(has_unreadable_entry)" "(h) unreadable protection: blocker present"
check_eq "false" "$(echo "$OUT" | jq -r '.met')" "(h) unreadable protection: gate NOT met"
check_eq "unavailable" "$(req_field source)" "(h) unreadable protection: source 'unavailable'"
check_eq "no" "$(has_required_entry)" \
  "(h) unreadable protection: reported as unreadable, not as an unsatisfied context"

# --------------------------------------------------------------------------
# (i) The override covers (h) and nothing else.
# --------------------------------------------------------------------------
FAKE_BRANCH_JSON='{"message":"Not Found","status":"404"}' \
run_gate "$(bundle "$(cr 1 'Some Check' success 100)")" --allow-unverified-required-checks
check_eq "no" "$(has_unreadable_entry)" "(i) --allow-unverified-required-checks: unreadable blocker cleared"

# ...but it must NOT launder a list that WAS read and contains an absent
# context. That is not "we could not check", it is the defect itself.
FAKE_REQUIRED_STATUS_CHECKS="$(protection build)" \
FAKE_BRANCH_PROTECTED=true \
run_gate "$(bundle "$(cr 1 'Some Check' success 100)")" --allow-unverified-required-checks
check_eq "yes" "$(has_required_entry)" \
  "(i) --allow-unverified-required-checks does NOT wave through a verified-absent context"

# --------------------------------------------------------------------------
# (j) The protection endpoints need admin access, so a collaborator token gets
#     403 there while the branch object — readable by anyone with repo read —
#     still carries the same contexts list. Falling back keeps enforcement on
#     for exactly the tokens that would otherwise silently skip it.
# --------------------------------------------------------------------------
FAKE_BRANCH_JSON='{"name":"main","protected":true,"protection":{"required_status_checks":{"contexts":["typecheck"],"enforcement_level":"non_admins"}}}' \
run_gate "$(bundle "$(cr 1 'Some Check' success 100)")"
check_eq "branch_object" "$(req_field source)" "(j) protection endpoint refused: fell back to the branch object"
check_eq "yes" "$(has_required_entry)" "(j) protection endpoint refused: absent context still blocks"
check_eq "absent" "$(unsat_state typecheck)" "(j) protection endpoint refused: state still resolved"

# --------------------------------------------------------------------------
# (k) A required context can be a legacy commit status rather than a check-run
#     (Vercel, CircleCI). Blocking one of those as "absent" would be a false
#     block, so statuses are matched too.
# --------------------------------------------------------------------------
FAKE_REQUIRED_STATUS_CHECKS="$(protection ci/legacy)" \
FAKE_BRANCH_PROTECTED=true \
FAKE_COMMIT_STATUSES='[{"context":"ci/legacy","state":"success","created_at":"2026-07-21T10:00:00Z"}]' \
run_gate "$(bundle "$(cr 1 'Some Check' success 100)")"
check_eq "no" "$(has_required_entry)" "(k) commit status satisfies a required context"

FAKE_REQUIRED_STATUS_CHECKS="$(protection ci/legacy)" \
FAKE_BRANCH_PROTECTED=true \
FAKE_COMMIT_STATUSES='[{"context":"ci/legacy","state":"pending","created_at":"2026-07-21T10:00:00Z"}]' \
run_gate "$(bundle "$(cr 1 'Some Check' success 100)")"
check_eq "yes" "$(has_required_entry)" "(k) a pending commit status does not satisfy it"
check_eq "pending" "$(unsat_state ci/legacy)" "(k) pending commit status: state reported"

# --------------------------------------------------------------------------
# (l) End-to-end control pair. Everything else about this PR is mergeable — a
#     fresh substantive CodeRabbit APPROVED on HEAD, clean CI, no threads — so
#     `met` flips on the required-context signal ALONE. This is the assertion
#     that would have caught the #673 near-miss.
# --------------------------------------------------------------------------
export FAKE_REVIEWS
FAKE_REVIEWS=$(jq -cn --arg sha "$HEAD_SHA" '[{
  user: {login: "coderabbitai[bot]", type: "Bot"},
  state: "APPROVED", commit_id: $sha,
  submitted_at: "2026-07-21T10:05:00Z",
  body: "Reviewed all changed files in this pull request and found no blocking issues worth raising."
}]')

FAKE_REQUIRED_STATUS_CHECKS="$(protection build)" \
FAKE_BRANCH_PROTECTED=true \
run_gate "$(bundle "$(cr 1 build success 100)")"
check_eq "true" "$(echo "$OUT" | jq -r '.met')" "(l) control: mergeable PR with its required context green -> met"
check_eq 0 "$RC" "(l) control: exit 0"

FAKE_REQUIRED_STATUS_CHECKS="$(protection build)" \
FAKE_BRANCH_PROTECTED=true \
run_gate "$(bundle "$(cr 1 'Some Other Check' success 100)")"
check_eq "false" "$(echo "$OUT" | jq -r '.met')" \
  "(l) control: same PR, required context absent -> NOT met (the #1361 flip)"
check_eq "true" "$(echo "$OUT" | jq -r '.primary_review_met')" \
  "(l) control: review coverage is unaffected — this is a CI-completeness blocker"
unset FAKE_REVIEWS

echo "----------------------------------------"
echo "merge-gate-required-contexts.test.sh: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
