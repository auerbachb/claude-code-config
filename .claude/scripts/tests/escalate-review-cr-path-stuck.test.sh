#!/usr/bin/env bash
# escalate-review-cr-path-stuck.test.sh — issue #1736: the CR-path stuck state
# escalates instead of polling CodeRabbit forever, and merge-gate.sh and
# escalate-review.sh agree on the evidence.
# catalog: tests — Pins the CR-path stuck-state escalation in `escalate-review.sh` (comment-only CodeRabbit + unredeemable pre-run CodeAnt stub) and its parity with `merge-gate.sh`
#
# THE DEAD END (auerbachb/sales-kit PR #114 at 69650c8, 2026-09-30)
#   CodeRabbit posts only COMMENTED reviews in that org, so CodeAnt is the only
#   reviewer that can satisfy the CR path. CodeAnt's only APPROVED on HEAD was a
#   pre-run stub, and its completed run on HEAD did not redeem it. CI green, 0
#   unresolved threads — and escalate-review.sh said polling_cr indefinitely,
#   because CodeRabbit HAD a review on HEAD. Nothing could ever change.
#
# CASES (one canonical state, mutated one term at a time)
#   (S)  stuck shape                      -> escalates (switch_bugbot), stderr
#                                            names #1736; merge-gate withholds and
#                                            reports the SAME approver stuck
#   (M)  findings resolved from an EARLIER run (the #1736 scoping fix)
#                                         -> gate_met here, primary_review_met there
#   (N1) CodeRabbit approved somewhere    -> polling_cr (it CAN approve here)
#   (N2) one thread unresolved            -> polling_cr
#   (N3) CodeAnt run still in flight      -> polling_cr (it may still redeem)
#   (N4) CI check failing                 -> polling_cr
#   (N5) CodeRabbit reviewed HEAD < 12 min ago -> polling_cr
#   (N6) a FOREIGN app's pending "CodeRabbit" check -> polling_cr (it is CI)
#   (S2) the real CodeRabbit app's pending check -> still escalates (positive
#        control for N6: the exclusion is by app identity, not removed)
#
# Only `gh` and `pr-state.sh` are stubbed; escalate-review.sh, merge-gate.sh and
# review-substance.sh are the real scripts.
#
# Run from repo root: bash .claude/scripts/tests/escalate-review-cr-path-stuck.test.sh

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/escalate-review-fixtures.sh
source "$TEST_DIR/lib/escalate-review-fixtures.sh"

MERGE_GATE="$REPO_ROOT/.claude/scripts/merge-gate.sh"
if [[ ! -x "$MERGE_GATE" ]]; then
  echo "FAIL — merge-gate.sh not found or not executable at $MERGE_GATE" >&2
  exit 1
fi

CA="codeant-ai[bot]"
PUSH_TS="$(ts_seconds_ago 7200)"
APPROVAL_TS="$(ts_seconds_ago 7150)"     # pre-run: before run 1 starts
RUN1_START="$(ts_seconds_ago 7100)"; RUN1_END="$(ts_seconds_ago 7000)"
RUN2_START="$(ts_seconds_ago 6000)"; RUN2_END="$(ts_seconds_ago 5900)"
CR_REVIEW_TS="$(ts_seconds_ago 6900)"

ca_approval() {
  jq -cn --arg sha "$HEAD_SHA" --arg at "$APPROVAL_TS" --arg l "$CA" \
    '{id: 7001, user:{login:$l,type:"Bot"}, state:"APPROVED", commit_id:$sha, submitted_at:$at, body:""}'
}
ca_findings_review() { # frozen submitted_at, empty body — the live shape
  jq -cn --arg sha "$HEAD_SHA" --arg at "$APPROVAL_TS" --arg l "$CA" \
    '{id: 7003, user:{login:$l,type:"Bot"}, state:"COMMENTED", commit_id:$sha, submitted_at:$at, body:""}'
}
cr_review() { # state commit submitted_at
  jq -cn --arg st "$1" --arg sha "$2" --arg at "$3" \
    '{id: (if $st == "APPROVED" then 7101 else 7100 end),
      user:{login:"coderabbitai[bot]",type:"Bot"}, state:$st, commit_id:$sha, submitted_at:$at,
      body:"Actionable comments posted: 0"}'
}
thread_root() { # created_at
  jq -cn --arg sha "$HEAD_SHA" --arg at "$1" --arg l "$CA" \
    '{id: 905, pull_request_review_id: 7003, in_reply_to_id: null,
      user:{login:$l,type:"Bot"}, commit_id:$sha, original_commit_id:$sha,
      created_at:$at, updated_at:$at, path:"a.sh",
      body:"This early return leaves the advisory lock held; release it first."}'
}
status_table() { # run2_done(true|false)
  local rows
  rows="$(jq -cn --arg c "$HEAD_SHA" --arg s1 "$RUN1_START" --arg f1 "$RUN1_END" \
              --arg s2 "$RUN2_START" --arg f2 "$RUN2_END" --argjson d2 "$1" '
    [ ({label:"Reviewed your PR", commit:$c, started:$s2, done:$d2}
       + (if $d2 then {finished:$f2} else {} end)),
      {label:"Reviewed your PR", commit:$c, started:$s1, finished:$f1, done:true} ]')"
  jq -cn --argjson rows "$rows" --arg c "$HEAD_SHA" --arg at "$RUN1_START" --arg l "$CA" '
    {user:{login:$l,type:"Bot"}, created_at:$at, updated_at:$at,
     body:("## CodeAnt AI — Review Status\n\n| Commit | Status |\n|---|---|\n| `"
           + ($c | .[0:7]) + "` | Reviewed your PR |\n\n<!-- codeant-review-status:"
           + ($rows | tojson) + " -->")}'
}

# ---- one scenario's shared payloads ------------------------------------------
REVIEWS="" INLINE="" CONVO="" THREADS="" CI_RUN="" EXTRA_RUNS="[]"
build() { # finding_created_at  thread_resolved  run2_done  cr_state  cr_commit  cr_ts  ci_conclusion
  REVIEWS="[$(ca_approval),$(ca_findings_review),$(cr_review "$4" "$5" "$6")]"
  [[ "$4" == "APPROVED" ]] && REVIEWS="[$(ca_approval),$(ca_findings_review),$(cr_review COMMENTED "$HEAD_SHA" "$6"),$(cr_review APPROVED "$5" "$6")]"
  INLINE="[$(thread_root "$1")]"
  CONVO="[$(status_table "$3")]"
  THREADS="$(jq -cn --argjson r "$2" '[{isResolved:$r, comments:{nodes:[{databaseId:905, body:"x", author:{login:"codeant-ai[bot]", __typename:"Bot"}}]}}]')"
  CI_RUN="$(jq -cn --arg c "$7" '{id: 9, name:"ci", status:"completed", conclusion:$c, app:{slug:"github-actions", id:15368}}')"
}

run_escalation() {
  reset_state
  write_commits "$PUSH_TS"
  jq -n --arg owner "$OWNER" --arg repo "$REPO" --arg sha "$HEAD_SHA" \
    --argjson ci "$CI_RUN" --argjson extra "$EXTRA_RUNS" --argjson reviews "$REVIEWS" --argjson inline "$INLINE" \
    --argjson conversation "$CONVO" --argjson threads "$THREADS" '
    { pr: {owner: $owner, repo: $repo, head_sha: $sha},
      check_runs: {all: ([$ci] + $extra)}, commit_statuses: [],
      threads: {all: $threads,
                unresolved_count: ([$threads[] | select(.isResolved | not)] | length)},
      comments: {reviews: $reviews, inline: $inline, conversation: $conversation} }' \
    > "$TMP/state.json"
  export FIXTURE_STATE_JSON="$TMP/state.json"
  ESC_ERR="$TMP/esc-stderr.txt"
  ESC_OUT="$(run_script 2>"$ESC_ERR")"
}

MG_BIN="$TMP/mg-bin"; mkdir -p "$MG_BIN"
cat > "$MG_BIN/gh" <<'GHEOF'
#!/usr/bin/env bash
ARGS="$*"
case "$ARGS" in
  "repo view --json nameWithOwner --jq .nameWithOwner") echo "solo/repo"; exit 0 ;;
  "api user --jq .login") echo "solouser"; exit 0 ;;
  *"pr view "*headRefOid*)
    jq -cn --arg sha "$FIXTURE_HEAD_SHA" \
      '{number:114, state:"OPEN", headRefOid:$sha, baseRefName:"main",
        mergeStateStatus:"CLEAN", mergeable:"MERGEABLE", reviewDecision:"APPROVED",
        author:{login:"solouser", type:"User"}}'
    exit 0 ;;
  *"git/commits/"*) jq -cn --arg d "$FIXTURE_PUSH_TS" '{committer:{date:$d}}'; exit 0 ;;
  *check-runs*)
    jq -cn --argjson r "$FAKE_CI_RUN" --arg d "$FIXTURE_PUSH_TS" \
      '{check_runs:[$r + {completed_at:$d, check_suite:{id:1}}]}'
    exit 0 ;;
  *commits/*/statuses*) printf '%s' "[]"; exit 0 ;;
  *pulls/*/reviews*)    printf '%s' "$FAKE_REVIEWS"; exit 0 ;;
  *pulls/*/comments*)   printf '%s' "$FAKE_PR_COMMENTS"; exit 0 ;;
  *issues/*/comments*)  printf '%s' "$FAKE_ISSUE_COMMENTS"; exit 0 ;;
  *graphql*)
    jq -cn --argjson t "$FAKE_THREADS" '{data:{repository:{pullRequest:{reviewThreads:{nodes:$t}}}}}'; exit 0 ;;
  *"/branches/"*"/protection/required_status_checks"*) echo "gh: Not Found (HTTP 404)" >&2; exit 1 ;;
  *"/branches/"*)
    jq -cn '{name:"main", protected:false, protection:{required_status_checks:{contexts:[]}}}'; exit 0 ;;
  *contents/*) echo "Not Found" >&2; exit 1 ;;
esac
echo "unexpected gh call: $ARGS" >&2
exit 1
GHEOF
chmod +x "$MG_BIN/gh"

run_merge_gate() {
  MG_OUT="$( cd "$REPO_ROOT" && PATH="$MG_BIN:$PATH" \
      FIXTURE_HEAD_SHA="$HEAD_SHA" FIXTURE_PUSH_TS="$PUSH_TS" \
      FAKE_REVIEWS="$REVIEWS" FAKE_PR_COMMENTS="$INLINE" FAKE_ISSUE_COMMENTS="$CONVO" \
      FAKE_THREADS="$THREADS" FAKE_CI_RUN="$CI_RUN" \
      "$MERGE_GATE" 114 --reviewer cr 2>/dev/null )"
}
mg() { jq -c "$1" <<<"$MG_OUT" 2>/dev/null || echo "UNPARSEABLE"; }

IN_RUN2="$(ts_seconds_ago 5950)"
IN_RUN1="$(ts_seconds_ago 7050)"
OLD_SHA="1a2b3c4d5e6f708192a3b4c5d6e7f8091a2b3c4d"

echo "== (S) stuck shape: the governing run's own finding, resolved =="
build "$IN_RUN2" true true COMMENTED "$HEAD_SHA" "$CR_REVIEW_TS" success
run_escalation; run_merge_gate
check_eq "(S) escalate-review: escalates instead of polling_cr" "STATUS=no_reviewer paid_route=switch_bugbot" "$ESC_OUT"
check_eq "(S) escalate-review: stderr names the stuck state" "1" "$(grep -c 'CR path stuck.*issue #1736' "$ESC_ERR")"
check_eq "(S) merge-gate: primary_review_met is false" "false" "$(mg .primary_review_met)"
check_eq "(S) parity: merge-gate reports the SAME stuck approver" '["codeant-ai[bot]"]' "$(mg .review_evidence.pre_run_stuck)"

echo "== (M) findings from an EARLIER run, resolved: the #1736 scoping redeems =="
build "$IN_RUN1" true true COMMENTED "$HEAD_SHA" "$CR_REVIEW_TS" success
run_escalation; run_merge_gate
check_eq "(M) escalate-review: gate_met" "STATUS=gate_met" "$ESC_OUT"
check_eq "(M) merge-gate: primary_review_met is true" "true" "$(mg .primary_review_met)"
check_eq "(M) parity: merge-gate reports the redemption" '["codeant-ai[bot]"]' "$(mg .review_evidence.redeemed_by_clean_run)"
check_eq "(M) parity: and nothing stuck" "[]" "$(mg .review_evidence.pre_run_stuck)"

echo "== negative controls: each term alone keeps polling_cr =="
build "$IN_RUN2" true true APPROVED "$OLD_SHA" "$CR_REVIEW_TS" success
run_escalation
check_eq "(N1) CodeRabbit approved an earlier commit -> it can approve here: polling_cr" "STATUS=polling_cr" "$ESC_OUT"

build "$IN_RUN2" false true COMMENTED "$HEAD_SHA" "$CR_REVIEW_TS" success
run_escalation
check_eq "(N2) an unresolved thread -> polling_cr" "STATUS=polling_cr" "$ESC_OUT"

build "$IN_RUN2" true false COMMENTED "$HEAD_SHA" "$CR_REVIEW_TS" success
run_escalation
check_eq "(N3) CodeAnt run still in flight -> polling_cr" "STATUS=polling_cr" "$ESC_OUT"

build "$IN_RUN2" true true COMMENTED "$HEAD_SHA" "$CR_REVIEW_TS" failure
run_escalation
check_eq "(N4) a failing CI check -> polling_cr" "STATUS=polling_cr" "$ESC_OUT"

build "$IN_RUN2" true true COMMENTED "$HEAD_SHA" "$(ts_seconds_ago 300)" success
run_escalation
check_eq "(N5) CodeRabbit reviewed HEAD 5 min ago -> polling_cr" "STATUS=polling_cr" "$ESC_OUT"

pending_cr_check() { # app_slug app_id
  jq -cn --arg s "$1" --argjson id "$2" \
    '[{id: 10, name:"CodeRabbit", status:"in_progress", conclusion:null, app:{slug:$s, id:$id}}]'
}
build "$IN_RUN2" true true COMMENTED "$HEAD_SHA" "$CR_REVIEW_TS" success
EXTRA_RUNS="$(pending_cr_check impostor-app 999999)"
run_escalation
check_eq "(N6) a foreign app's pending 'CodeRabbit' check is CI, not clear -> polling_cr" "STATUS=polling_cr" "$ESC_OUT"

EXTRA_RUNS="$(pending_cr_check coderabbitai 347564)"
run_escalation
check_eq "(S2) the real CodeRabbit app's pending check is not CI -> still escalates" "STATUS=no_reviewer paid_route=switch_bugbot" "$ESC_OUT"
EXTRA_RUNS="[]"

finish_escalate_review_tests "CR-path stuck-state (issue #1736)"
