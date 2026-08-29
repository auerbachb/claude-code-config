#!/usr/bin/env bash
# escalate-review-merge-gate-freshness-parity.test.sh — cross-evaluator drift
# guard for the #836 approval-freshness rule (issue #1387).
#
# THE BUG THIS EXISTS TO CATCH
#   merge-gate.sh is the merge decision authority; escalate-review.sh decides
#   whether to spend a PAID Greptile review. Escalation is a CALLER of the gate,
#   so the two must reach the same verdict on the same PR state. They did not:
#
#     - merge-gate.sh redeems a stale `submitted_at` when review-substance.sh
#       reports `external_evidence_on_head` for that reviewer (issue #876).
#     - escalate-review.sh compared `submitted_at >= push` and nothing else.
#
#   CodeAnt PATCHes its EXISTING review object on a re-review — same review id,
#   commit_id advanced to the new HEAD, submitted_at frozen at the original
#   submission — so EVERY in-place re-review read as permanently stale to the
#   escalation gate. Observed on PR #1373 at HEAD 39d0442: merge-gate.sh said
#   `primary_review_met: true` while escalate-review.sh said trigger_greptile on
#   the same SHA. A caller STRICTER than the gate burns money, exactly as a
#   caller more permissive than the gate strands PRs — both are divergence.
#
# WHAT THIS SUITE PINS
#   ONE canonical PR state, projected into the two input shapes the evaluators
#   actually read, run through BOTH real scripts, asserted to agree. Two
#   projections, both directions:
#
#     (P) in-place re-review WITH external evidence naming HEAD -> both grant
#     (N) the identical review object with the evidence removed  -> both withhold
#
#   (N) is the discrimination control: the two projections differ ONLY in the
#   inline-comment payload, so a fix that granted unconditionally — an identity
#   waiver, or dropping the staleness test — fails there rather than passing here.
#
# SCOPE NOTE — what "one canonical state" means here
#   The review, inline-comment and conversation payloads are built ONCE into
#   shared variables and handed to both evaluators byte for byte: those are the
#   only inputs to the rule under test. The check-run sets deliberately differ,
#   because the two scripts read check-runs for unrelated jobs (escalation reads
#   the CodeRabbit rate-limit and BugBot classification runs; the gate reads CI).
#   Neither `primary_review_met` nor the freshness filter reads a check-run, so
#   that difference cannot carry the verdict — and asserting merge-gate.sh's
#   `primary_review_met` rather than its `met` keeps CI out of the comparison,
#   which is also the exact field the issue #1387 report cites.
#
#   Sibling guard: tests/ts-normalizer-parity.test.sh pins the same "one rule,
#   two implementations" invariant for the TIMESTAMP NORMALISER. This file pins
#   the freshness DECISION built on top of it. Neither subsumes the other.
#
# Only `gh` and `pr-state.sh` are stubbed; escalate-review.sh, merge-gate.sh,
# review-substance.sh, ci-status.sh, check-runs-dedup.sh and session-state.sh
# are the real scripts.
#
# Run from repo root: bash .claude/scripts/tests/escalate-review-merge-gate-freshness-parity.test.sh

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# The escalate-review side of the harness: stub SCRIPT_DIR, stub gh, stub
# pr-state.sh, write_commits/write_state, check_eq, and the summary footer.
# shellcheck source=lib/escalate-review-fixtures.sh
source "$TEST_DIR/lib/escalate-review-fixtures.sh"

MERGE_GATE="$REPO_ROOT/.claude/scripts/merge-gate.sh"
if [[ ! -x "$MERGE_GATE" ]]; then
  echo "FAIL — merge-gate.sh not found or not executable at $MERGE_GATE" >&2
  exit 1
fi

############################################################################
# The canonical PR state — the PR #1373 / #876 in-place re-review shape.
############################################################################
# HEAD_SHA comes from the shared fixture lib and is used verbatim by BOTH
# projections, so neither side can be reading a different commit.
OLD_SHA="1a2b3c4d5e6f708192a3b4c5d6e7f8091a2b3c4d"   # pre-rebase SHA, full 40 chars
PUSH_TS="$(ts_seconds_ago 300)"        # HEAD commit committer date
APPROVAL_TS="$(ts_seconds_ago 3600)"   # FROZEN at the original submission
EVIDENCE_TS="$(ts_seconds_ago 120)"    # post-push, HEAD-anchored
BUGBOT_FAIL_TS="$(ts_seconds_ago 60)"

# The in-place-edited review object: one id throughout, commit_id advanced to
# HEAD, submitted_at frozen, body EMPTY. An empty body is deliberate — if the
# body could vouch for the object it sits in, the approval would be certifying
# its own frozen timestamp, and projection (N) below would start passing.
REVIEW_INPLACE="$(jq -cn --arg sha "$HEAD_SHA" --arg ts "$APPROVAL_TS" \
  '{id: 4833716091, user: {login: "codeant-ai[bot]", type: "Bot"},
    commit_id: $sha, state: "APPROVED", submitted_at: $ts, body: ""}')"

# The redeeming evidence: an inline finding anchored to HEAD by BOTH commit_id
# and original_commit_id, created after the push. First-party proof this
# reviewer read the current diff, produced OUTSIDE the review object whose
# timestamp is in doubt.
INLINE_ON_HEAD="$(jq -cn --arg sha "$HEAD_SHA" --arg ts "$EVIDENCE_TS" \
  '{user: {login: "codeant-ai[bot]", type: "Bot"}, commit_id: $sha,
    original_commit_id: $sha, created_at: $ts, path: "a.sh",
    body: "Suggestion: this early return leaves the advisory lock held on the error path."}')"

# The SAME inline comment with only `original_commit_id` moved back to the
# pre-rebase SHA — the shape GitHub produces when it repoints a round-1 comment
# onto HEAD. It must NOT redeem anything, so (N) keeps a comment payload rather
# than an empty one: an empty array would also test "no evidence", but this
# tests the harder, live case where a HEAD-looking comment is present.
INLINE_REPOINTED="$(jq -cn --arg sha "$HEAD_SHA" --arg old "$OLD_SHA" --arg ts "$EVIDENCE_TS" \
  '{user: {login: "codeant-ai[bot]", type: "Bot"}, commit_id: $sha,
    original_commit_id: $old, created_at: $ts, path: "a.sh",
    body: "Suggestion: this early return leaves the advisory lock held on the error path."}')"

# BugBot has failed with a usage-limit refusal, so on the escalation side a
# withheld gate_met lands on trigger_greptile — the paid outcome issue #1387
# reports. Carried in BOTH projections so the conversation payload is identical.
BUGBOT_FAILURE="$(failure_comment "$BUGBOT_FAIL_TS")"

############################################################################
# Projection 1 — the aggregated pr-state.sh bundle escalate-review.sh reads.
############################################################################
run_escalation() { # <inline-array-json>
  # Fresh session state per projection: no cached bugbot_installed carried over
  # from the projection before it, so (P) and (N) are genuinely independent runs.
  reset_state
  write_commits "$PUSH_TS"
  write_state "[$BUGBOT_CHECK_RUN_OK]" "[$REVIEW_INPLACE]" "$1" "[$BUGBOT_FAILURE]"
  run_script 2>/dev/null
}

############################################################################
# Projection 2 — the raw `gh` responses merge-gate.sh reads. Stub shape follows
# tests/lib/merge-gate-test-fixtures.sh; it is rebuilt here rather than sourced
# because that library installs its own TMP dir, EXIT trap, HOME and check_eq
# (with a different argument order), all of which would clobber the escalation
# harness already sourced above.
############################################################################
MG_BIN="$TMP/mg-bin"; mkdir -p "$MG_BIN"
cat > "$MG_BIN/gh" <<'GHEOF'
#!/usr/bin/env bash
ARGS="$*"
case "$ARGS" in
  "repo view --json nameWithOwner --jq .nameWithOwner")
    echo "solo/repo"; exit 0 ;;
  "api user --jq .login")
    # Authorship guard (issue #733): viewer login matches the PR author below,
    # so authorship == "mine" and the gate is not blocked on authorship.
    echo "solouser"; exit 0 ;;
  *"pr view "*headRefOid*)
    jq -cn --arg sha "$FIXTURE_HEAD_SHA" \
      '{number:1373, state:"OPEN", headRefOid:$sha, baseRefName:"main",
        mergeStateStatus:"CLEAN", mergeable:"MERGEABLE", reviewDecision:"APPROVED",
        author:{login:"solouser", type:"User"}}'
    exit 0 ;;
  *"git/commits/"*)
    jq -cn --arg d "$FIXTURE_PUSH_TS" '{committer:{date:$d}}'; exit 0 ;;
  *check-runs*)
    jq -cn --arg d "$FIXTURE_PUSH_TS" \
      '{check_runs:[{id:1,name:"ci",status:"completed",conclusion:"success",
                     completed_at:$d,check_suite:{id:1},app:{slug:"gha",id:1}}]}'
    exit 0 ;;
  *commits/*/statuses*) printf '%s' "[]"; exit 0 ;;
  *pulls/*/reviews*)    printf '%s' "${FAKE_REVIEWS:-[]}"; exit 0 ;;
  *pulls/*/comments*)   printf '%s' "${FAKE_PR_COMMENTS:-[]}"; exit 0 ;;
  *issues/*/comments*)  printf '%s' "${FAKE_ISSUE_COMMENTS:-[]}"; exit 0 ;;
  *graphql*)
    jq -cn '{data:{repository:{pullRequest:{reviewThreads:{nodes:[]}}}}}'; exit 0 ;;
  *"/branches/"*"/protection/required_status_checks"*)
    echo "gh: Not Found (HTTP 404)" >&2; exit 1 ;;
  *"/branches/"*)
    jq -cn '{name:"main", protected:false,
             protection:{required_status_checks:{contexts:[]}}}'
    exit 0 ;;
  *contents/*)
    # No CODEOWNERS file — merge-gate.sh tolerates the 404.
    echo "Not Found" >&2; exit 1 ;;
esac
echo "unexpected gh call: $ARGS" >&2
exit 1
GHEOF
chmod +x "$MG_BIN/gh"

run_merge_gate() { # <inline-array-json>
  ( cd "$REPO_ROOT" && PATH="$MG_BIN:$PATH" \
      FIXTURE_HEAD_SHA="$HEAD_SHA" \
      FIXTURE_PUSH_TS="$PUSH_TS" \
      FAKE_REVIEWS="[$REVIEW_INPLACE]" \
      FAKE_PR_COMMENTS="$1" \
      FAKE_ISSUE_COMMENTS="[$BUGBOT_FAILURE]" \
      "$MERGE_GATE" 1373 --reviewer cr 2>/dev/null )
}

# Reads .primary_review_met out of merge-gate.sh's JSON. Any failure to produce
# a literal true/false is reported verbatim rather than defaulted, so a broken
# run cannot masquerade as a withheld gate (guards-that-pass-by-not-running).
primary_met() { # <merge-gate-json>
  jq -r 'if has("primary_review_met") then (.primary_review_met | tostring)
         else "MISSING" end' <<<"$1" 2>/dev/null || echo "UNPARSEABLE"
}

############################################################################
echo "== Projection (P): in-place re-review WITH external evidence naming HEAD =="
############################################################################
ESC_P="$(run_escalation "[$INLINE_ON_HEAD]")"
MG_P="$(run_merge_gate "[$INLINE_ON_HEAD]")"
MG_P_MET="$(primary_met "$MG_P")"

check_eq "(P) merge-gate.sh: primary_review_met == true" "true" "$MG_P_MET"
check_eq "(P) escalate-review.sh: STATUS=gate_met" "STATUS=gate_met" "$ESC_P"

# The parity assertion proper: same payload, both evaluators, one verdict.
ESC_P_SATISFIED=$([[ "$ESC_P" == "STATUS=gate_met" ]] && echo true || echo false)
check_eq "(P) both evaluators agree the primary review is satisfied" \
  "$MG_P_MET" "$ESC_P_SATISFIED"

############################################################################
echo "== Projection (N): identical review object, evidence repointed off HEAD =="
############################################################################
ESC_N="$(run_escalation "[$INLINE_REPOINTED]")"
MG_N="$(run_merge_gate "[$INLINE_REPOINTED]")"
MG_N_MET="$(primary_met "$MG_N")"

check_eq "(N) merge-gate.sh: primary_review_met == false" "false" "$MG_N_MET"
check_eq "(N) escalate-review.sh: STATUS=trigger_greptile (not gate_met)" \
  "STATUS=trigger_greptile" "$ESC_N"

ESC_N_SATISFIED=$([[ "$ESC_N" == "STATUS=gate_met" ]] && echo true || echo false)
check_eq "(N) both evaluators agree the primary review is NOT satisfied" \
  "$MG_N_MET" "$ESC_N_SATISFIED"

# Both projections must not be the same run: if the two inline payloads somehow
# produced identical verdicts, every assertion above could pass while the suite
# discriminated nothing.
check_eq "(P)/(N) the two projections reach DIFFERENT verdicts" \
  "true" "$([[ "$MG_P_MET" != "$MG_N_MET" && "$ESC_P" != "$ESC_N" ]] && echo true || echo false)"

finish_escalate_review_tests "merge-gate freshness parity"
