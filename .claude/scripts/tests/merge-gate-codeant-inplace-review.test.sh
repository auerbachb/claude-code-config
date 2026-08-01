#!/usr/bin/env bash
# merge-gate-codeant-inplace-review.test.sh — Regression tests for issue #876:
# a CodeAnt IN-PLACE review edit must not read as a #836-stale approval.
#
# THE BUG
#   CodeAnt PATCHes its EXISTING review object on a re-review rather than posting
#   a new one. After a force-push its review keeps the same `id`, has `commit_id`
#   correctly advanced to the new HEAD — and `submitted_at` frozen at the
#   original submission, because GitHub treats that field as immutable creation
#   time. The #836 staleness guard compares submitted_at against the HEAD
#   commit's committer date, so a genuinely completed post-push re-review is
#   permanently "stale" and the gate never opens.
#
#   Live trace (auerbachb/skingod PR #2596), reproduced by the fixtures below:
#     04:57:00Z  CodeAnt APPROVED review id 4833716091 on the pre-rebase SHA
#     04:59:42Z  force-push to the new HEAD  <-- committer date
#     05:02:01Z  @codeant-ai review posted
#     05:02:06Z  "CodeAnt AI is running the review."
#     05:02:34Z  sequence-diagram summary, naming the new SHA, describing the
#                actual diff
#     05:03:35Z  "CodeAnt AI finished running the review."
#     ...and the review object is STILL id 4833716091, commit_id now the new
#     HEAD, submitted_at still 04:57:00Z. merge-gate.sh sat on
#     "predates the HEAD commit" for 8 poll ticks / 15+ minutes.
#
# THE FIX BEING PINNED
#   A stale submitted_at is REDEEMED by external evidence on the current SHA —
#   review-substance.sh's `external_evidence_on_head`, i.e. substance produced
#   OUTSIDE the review object whose timestamp is in doubt. Never waived by
#   reviewer identity, because CodeAnt also emits genuinely hollow approvals
#   (issue #875) and an identity waiver would re-open that hole.
#
#   Every case below is therefore a DISCRIMINATION test: (a) and (b) are the same
#   review object and differ only in whether the reviewer left corroborating
#   evidence on HEAD. If the fix is reverted, (a) fails. If the fix is widened
#   into an identity waiver or a self-vouch, (b)/(c)/(d)/(g) fail.
#
# Only `gh` is stubbed; merge-gate.sh, review-substance.sh, ci-status.sh,
# check-runs-dedup.sh and session-state.sh are the real scripts.
#
# Run from repo root: bash .claude/scripts/tests/merge-gate-codeant-inplace-review.test.sh
set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
SUT="$REPO_ROOT/.claude/scripts/merge-gate.sh"

TMP="$(mktemp -d)"
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

export HOME="$TMP/home"; mkdir -p "$HOME/.claude"

PASS=0; FAIL=0
ok()  { echo "PASS: $1"; PASS=$((PASS + 1)); }
bad() { echo "FAIL: $1" >&2; FAIL=$((FAIL + 1)); }
check_eq() { # expected actual label
  if [[ "$1" == "$2" ]]; then ok "$3"; else bad "$3 (expected: '$1', got: '$2')"; fi
}

# --- The PR #2596 timeline ----------------------------------------------
HEAD_SHA="f9b6041c7d3e2a5b8c9d0e1f2a3b4c5d6e7f8091"   # post-rebase HEAD
OLD_SHA="3e9dfd0eb1c2d3e4f5061728394a5b6c7d8e9f01"    # pre-rebase SHA
APPROVAL_TS="2026-08-01T04:57:00Z"   # frozen at the ORIGINAL submission
COMMIT_TS="2026-08-01T04:59:42Z"     # force-push committer date
MARKER_TS="2026-08-01T05:02:06Z"     # "is running the review"
SUMMARY_TS="2026-08-01T05:02:34Z"    # substantive summary naming HEAD
FINISH_TS="2026-08-01T05:03:35Z"     # "finished running the review"
export HEAD_SHA

# --- Fake gh stub -------------------------------------------------------
BIN="$TMP/bin"; mkdir -p "$BIN"
cat > "$BIN/gh" <<'GHEOF'
#!/usr/bin/env bash
ARGS="$*"
case "$ARGS" in
  "repo view --json nameWithOwner --jq .nameWithOwner")
    echo "solo/repo"; exit 0 ;;
  "api user --jq .login")
    echo "solouser"; exit 0 ;;
  *"pr view "*headRefOid*)
    jq -cn --arg sha "$HEAD_SHA" \
      '{number:2596, state:"OPEN", headRefOid:$sha, baseRefName:"main",
        mergeStateStatus:"CLEAN", mergeable:"MERGEABLE", reviewDecision:"APPROVED",
        author:{login:"solouser", type:"User"}}'
    exit 0 ;;
  *"git/commits/"*)
    jq -cn --arg d "$FAKE_COMMIT_TS" '{committer:{date:$d}}'; exit 0 ;;
  *check-runs*)
    jq -cn '{check_runs:[{id:1,name:"ci",status:"completed",conclusion:"success",
               completed_at:"2026-08-01T05:01:00Z",
               check_suite:{id:1},app:{slug:"gha",id:1}}]}'
    exit 0 ;;
  *pulls/*/reviews*)   printf '%s' "${FAKE_REVIEWS:-[]}"; exit 0 ;;
  *pulls/*/comments*)  printf '%s' "${FAKE_PR_COMMENTS:-[]}"; exit 0 ;;
  *issues/*/comments*) printf '%s' "${FAKE_ISSUE_COMMENTS:-[]}"; exit 0 ;;
  *graphql*)
    jq -cn '{data:{repository:{pullRequest:{reviewThreads:{nodes:[]}}}}}'; exit 0 ;;
  *contents/*)
    echo "Not Found" >&2; exit 1 ;;
esac
echo "unexpected gh call: $ARGS" >&2
exit 1
GHEOF
chmod +x "$BIN/gh"

# --- Fixture builders ---------------------------------------------------
# The in-place-edited review object: SAME id throughout, commit_id advanced to
# HEAD, submitted_at frozen. The body is deliberately substantive-looking — and
# deliberately irrelevant, because review-substance.sh only pools review bodies
# whose submitted_at postdates the push. If a future change let this body count,
# the approval would be vouching for its own frozen timestamp, and case (b)
# below (identical review, no external evidence) would start passing.
ca_inplace_review() {
  jq -cn --arg sha "$HEAD_SHA" --arg ts "$APPROVAL_TS" \
    '[{id:4833716091, user:{login:"codeant-ai[bot]",type:"Bot"},
       commit_id:$sha, state:"APPROVED", submitted_at:$ts,
       body:"CodeAnt AI has reviewed this pull request and found no blocking issues."}]'
}

# Same object shape, empty body — the #875 rubber-stamp spelling.
ca_empty_review() { # submitted_at
  jq -cn --arg sha "$HEAD_SHA" --arg ts "$1" \
    '[{id:4833716091, user:{login:"codeant-ai[bot]",type:"Bot"},
       commit_id:$sha, state:"APPROVED", submitted_at:$ts, body:""}]'
}

cr_inplace_review() {
  jq -cn --arg sha "$HEAD_SHA" --arg ts "$APPROVAL_TS" \
    '[{id:4833716092, user:{login:"coderabbitai[bot]",type:"Bot"},
       commit_id:$sha, state:"APPROVED", submitted_at:$ts, body:""}]'
}

# The genuine post-push conversation trail: run-start marker, then a substantive
# summary NAMING HEAD, then the completion notice. The summary is the redeemer;
# the completion notice deliberately is NOT (it is a fixed, content-free string,
# so accepting it would let a bot certify its own freshness with a constant).
ca_convo_genuine() { # login
  jq -cn --arg login "${1:-codeant-ai[bot]}" \
    --arg sha "$HEAD_SHA" --arg m "$MARKER_TS" --arg s "$SUMMARY_TS" --arg f "$FINISH_TS" \
    '[{user:{login:$login,type:"Bot"}, created_at:$m, updated_at:$m,
       body:"CodeAnt AI is running the review."},
      {user:{login:$login,type:"Bot"}, created_at:$s, updated_at:$s,
       body:("## Review summary for `" + $sha + "`\n\nThis change adds a SafeAreaProvider inside the native modal root so the sheet respects the notch inset. Two call sites were updated and the snapshot baseline regenerated. No blocking issues found.")},
      {user:{login:$login,type:"Bot"}, created_at:$f, updated_at:$f,
       body:"CodeAnt AI finished running the review."}]'
}

# The completion notice ALONE — no substantive summary. This is the shape the
# corroboration-by-status-string design would have accepted.
ca_convo_marker_only() {
  jq -cn --arg m "$MARKER_TS" --arg f "$FINISH_TS" \
    '[{user:{login:"codeant-ai[bot]",type:"Bot"}, created_at:$m, updated_at:$m,
       body:"CodeAnt AI is running the review."},
      {user:{login:"codeant-ai[bot]",type:"Bot"}, created_at:$f, updated_at:$f,
       body:"CodeAnt AI finished running the review."}]'
}

# A substantive summary naming the PRE-REBASE SHA — the reviewer's own record
# saying it read a different commit.
ca_convo_old_sha() {
  jq -cn --arg sha "$OLD_SHA" --arg s "$SUMMARY_TS" \
    '[{user:{login:"codeant-ai[bot]",type:"Bot"}, created_at:$s, updated_at:$s,
       body:("## Review summary for `" + $sha + "`\n\nReviewed the modal root change and the two updated call sites. No blocking issues found.")}]'
}

OUT=""; ERRTXT=""; RC=0
run_gate() { # <reviews-json> <issue-comments-json> [reviewer]
  local reviews="$1" convo="$2" reviewer="${3:-cr}"
  OUT=$(PATH="$BIN:$PATH" \
        FAKE_COMMIT_TS="$COMMIT_TS" \
        FAKE_REVIEWS="$reviews" \
        FAKE_PR_COMMENTS="[]" \
        FAKE_ISSUE_COMMENTS="$convo" \
        "$SUT" 2596 --reviewer "$reviewer" 2>"$TMP/err")
  RC=$?
  ERRTXT="$(cat "$TMP/err")"
}

met()           { echo "$OUT" | jq -r '.met'; }
primary_met()   { echo "$OUT" | jq -r '.primary_review_met'; }
missing_count() { echo "$OUT" | jq -r '.missing | length'; }
missing_has()   { echo "$OUT" | jq -e --arg s "$1" \
                    '[.missing[]? | select(contains($s))] | length > 0' \
                  >/dev/null && echo yes || echo no; }
ev()            { echo "$OUT" | jq -r --arg l "$1" --arg f "$2" '.review_evidence.reviewers[$l][$f]'; }

STALE_MSG="predates the HEAD commit (force-push retargeting)"
HOLLOW_MSG="is not review coverage"

# -------------------------------------------------------------------------
# (a) THE #876 CASE — in-place re-review edit with a corroborating trail.
#     Frozen submitted_at, commit_id == HEAD, post-push summary naming HEAD.
#     Must count as coverage.
# -------------------------------------------------------------------------
echo "--- (a) CodeAnt in-place re-review with corroborating post-push evidence ---"
run_gate "$(ca_inplace_review)" "$(ca_convo_genuine)"
check_eq "true"  "$(met)"                      "(a) in-place re-review: met == true"
check_eq "true"  "$(primary_met)"              "(a) in-place re-review: primary_review_met == true"
check_eq "0"     "$(missing_count)"            "(a) in-place re-review: no missing entries"
check_eq "0"     "$RC"                         "(a) in-place re-review: exit 0"
check_eq "no"    "$(missing_has "$STALE_MSG")" "(a) in-place re-review: no stale-retargeting blocker"
# The redemption must be announced, never silent.
if [[ "$ERRTXT" == *"issue #876"* ]]; then
  ok "(a) in-place re-review: redemption announced on stderr"
else
  bad "(a) in-place re-review: redemption was silent (stderr: '$ERRTXT')"
fi
# And it must come from evidence OUTSIDE the review object.
check_eq "true"  "$(ev "codeant-ai[bot]" external_evidence_on_head)" \
                                               "(a) in-place re-review: external_evidence_on_head is what redeemed it"
# The frozen approval body contributed nothing — proving the approval did not
# vouch for its own timestamp.
check_eq "0"     "$(ev "codeant-ai[bot]" body_len)" \
                                               "(a) in-place re-review: the stale approval body counted for 0"
# The approval predates the bot's own run marker, yet is NOT an inversion,
# because external evidence on HEAD exists (issue #875's documented exemption).
check_eq "false" "$(ev "codeant-ai[bot]" temporal_inversion)" \
                                               "(a) in-place re-review: external evidence suppresses temporal_inversion"

# -------------------------------------------------------------------------
# (b) THE DISCRIMINATOR — byte-identical review object, NO corroborating
#     evidence on HEAD. Must stay blocked with the unchanged #836 reason.
#     (a) and (b) differ ONLY in the issue-comments payload.
# -------------------------------------------------------------------------
echo "--- (b) same in-place review shape, no corroborating evidence (genuinely stale) ---"
run_gate "$(ca_inplace_review)" "[]"
check_eq "false" "$(met)"                       "(b) uncorroborated stale: met == false"
check_eq "false" "$(primary_met)"               "(b) uncorroborated stale: primary_review_met == false"
check_eq "yes"   "$(missing_has "$STALE_MSG")"  "(b) uncorroborated stale: unchanged #836 reason"
check_eq "1"     "$RC"                          "(b) uncorroborated stale: exit 1"
check_eq "false" "$(ev "codeant-ai[bot]" external_evidence_on_head)" \
                                                "(b) uncorroborated stale: no external evidence to redeem with"

# -------------------------------------------------------------------------
# (c) The completion notice ALONE does not redeem. A fixed, content-free
#     status string must never let a bot certify its own freshness — that is
#     the weaker design this fix deliberately did not take.
# -------------------------------------------------------------------------
echo "--- (c) 'finished running the review' marker alone does NOT redeem ---"
run_gate "$(ca_inplace_review)" "$(ca_convo_marker_only)"
check_eq "false" "$(met)"                       "(c) marker-only: met == false"
check_eq "yes"   "$(missing_has "$STALE_MSG")"  "(c) marker-only: still the #836 reason"
check_eq "1"     "$RC"                          "(c) marker-only: exit 1"

# -------------------------------------------------------------------------
# (d) RUBBER STAMP — empty body, status comment naming the PRE-REBASE SHA.
#     The reviewer's own record says it read a different commit. Rejected.
# -------------------------------------------------------------------------
echo "--- (d) rubber stamp: bodylen=0, status comment names an OLDER SHA ---"
run_gate "$(ca_empty_review "$APPROVAL_TS")" "$(ca_convo_old_sha)"
check_eq "false" "$(met)"                       "(d) rubber stamp: met == false"
check_eq "false" "$(primary_met)"               "(d) rubber stamp: primary_review_met == false"
check_eq "1"     "$RC"                          "(d) rubber stamp: exit 1"
check_eq "true"  "$(ev "codeant-ai[bot]" self_report_mismatch)" \
                                                "(d) rubber stamp: self_report_mismatch recorded"
check_eq "false" "$(ev "codeant-ai[bot]" external_evidence_on_head)" \
                                                "(d) rubber stamp: nothing external to redeem with"

# -------------------------------------------------------------------------
# (e) THE STRONGEST DISCRIMINATOR — redemption must not bypass the substance
#     verdict. Here the reviewer DOES have a summary naming HEAD (so it is
#     redeemable), but a LATER status comment names the old SHA, so its own
#     newest self-report contradicts the approval. Must stay blocked, and on
#     the #875 hollow reason rather than the #836 stale one.
# -------------------------------------------------------------------------
echo "--- (e) redeemable but self-contradicting: substance still blocks ---"
E_CONVO=$(jq -cn --arg head "$HEAD_SHA" --arg old "$OLD_SHA" \
  --arg s "$SUMMARY_TS" --arg f "$FINISH_TS" \
  '[{user:{login:"codeant-ai[bot]",type:"Bot"}, created_at:$s, updated_at:$s,
     body:("## Review summary for `" + $head + "`\n\nReviewed the modal root change and the two updated call sites. No blocking issues found.")},
    {user:{login:"codeant-ai[bot]",type:"Bot"}, created_at:$f, updated_at:$f,
     body:("Re-analysis complete. The reviewed commit for this run was `" + $old + "` — a long enough notice to clear the substance threshold.")}]')
run_gate "$(ca_empty_review "$APPROVAL_TS")" "$E_CONVO"
check_eq "false" "$(met)"                        "(e) self-contradicting: met == false"
check_eq "false" "$(primary_met)"                "(e) self-contradicting: primary_review_met == false"
check_eq "yes"   "$(missing_has "$HOLLOW_MSG")"  "(e) self-contradicting: blocked on the #875 substance reason"
check_eq "no"    "$(missing_has "$STALE_MSG")"   "(e) self-contradicting: staleness was redeemed, substance was not"
check_eq "true"  "$(ev "codeant-ai[bot]" self_report_mismatch)" \
                                                 "(e) self-contradicting: self_report_mismatch recorded"
check_eq "1"     "$RC"                           "(e) self-contradicting: exit 1"

# -------------------------------------------------------------------------
# (f) IDENTITY IS NOT THE TEST — CodeRabbit gets the identical redemption on
#     the identical evidence. If this ever fails while (a) passes, the fix has
#     drifted into a per-bot waiver, which is the #875 hole.
# -------------------------------------------------------------------------
echo "--- (f) same redemption applies to CodeRabbit (evidence, not identity) ---"
run_gate "$(cr_inplace_review)" "$(ca_convo_genuine "coderabbitai[bot]")"
check_eq "true"  "$(met)"                       "(f) CodeRabbit redemption: met == true"
check_eq "true"  "$(primary_met)"               "(f) CodeRabbit redemption: primary_review_met == true"
check_eq "no"    "$(missing_has "$STALE_MSG")"  "(f) CodeRabbit redemption: no stale blocker"
check_eq "0"     "$RC"                          "(f) CodeRabbit redemption: exit 0"
# Same evidence assertions as (a). Equal outcomes could otherwise be reached by
# unequal routes — the point of this case is that the SAME mechanism carries
# both bots, so pin the mechanism, not just the verdict.
check_eq "true"  "$(ev "coderabbitai[bot]" external_evidence_on_head)" \
                                                "(f) CodeRabbit redemption: external_evidence_on_head is what redeemed it"
check_eq "0"     "$(ev "coderabbitai[bot]" body_len)" \
                                                "(f) CodeRabbit redemption: the stale approval body counted for 0"
check_eq "false" "$(ev "coderabbitai[bot]" temporal_inversion)" \
                                                "(f) CodeRabbit redemption: external evidence suppresses temporal_inversion"

# -------------------------------------------------------------------------
# (g) A genuinely FRESH CHANGES_REQUESTED still beats a redeemed approval —
#     redemption restores freshness, never precedence.
# -------------------------------------------------------------------------
echo "--- (g) fresh CHANGES_REQUESTED still outranks a redeemed approval ---"
G_REVIEWS=$(jq -cn --arg sha "$HEAD_SHA" --arg ap "$APPROVAL_TS" --arg cr "$FINISH_TS" \
  '[{id:4833716091, user:{login:"codeant-ai[bot]",type:"Bot"},
     commit_id:$sha, state:"APPROVED", submitted_at:$ap,
     body:"CodeAnt AI has reviewed this pull request and found no blocking issues."},
    {id:4833716093, user:{login:"codeant-ai[bot]",type:"Bot"},
     commit_id:$sha, state:"CHANGES_REQUESTED", submitted_at:$cr,
     body:"Blocking: the new provider is mounted outside the modal root."}]')
run_gate "$G_REVIEWS" "$(ca_convo_genuine)"
check_eq "false" "$(met)"             "(g) fresh CHANGES_REQUESTED: met == false"
check_eq "false" "$(primary_met)"     "(g) fresh CHANGES_REQUESTED: primary_review_met == false"
check_eq "1"     "$RC"                "(g) fresh CHANGES_REQUESTED: exit 1"
# The point of this case is WHICH blocker fires. The corroborating evidence is
# present, so the rejection must come from the fresh CHANGES_REQUESTED — not
# from a leftover staleness verdict that would have blocked anyway. Without
# these two, (g) would still pass on a build where redemption never worked.
check_eq "true"  "$(ev "codeant-ai[bot]" external_evidence_on_head)" \
                                      "(g) fresh CHANGES_REQUESTED: the corroborating evidence is present"
check_eq "no"    "$(missing_has "$STALE_MSG")" \
                                      "(g) fresh CHANGES_REQUESTED: rejected on the newer review, not on staleness"
# Name the blocker positively, not just by the absence of the other one.
check_eq "yes"   "$(missing_has "retracted by later CHANGES_REQUESTED")" \
                                      "(g) fresh CHANGES_REQUESTED: blocker is the retraction, stated as such"

# -------------------------------------------------------------------------
# (h) A FRESH approval is unaffected: redemption is gated on the approval
#     already being stale, so the normal path must not touch the redemption
#     code at all (no stderr note).
# -------------------------------------------------------------------------
echo "--- (h) fresh approval path is unchanged (no redemption involved) ---"
FRESH_REVIEW=$(jq -cn --arg sha "$HEAD_SHA" --arg ts "$SUMMARY_TS" \
  '[{id:4833716094, user:{login:"codeant-ai[bot]",type:"Bot"},
     commit_id:$sha, state:"APPROVED", submitted_at:$ts,
     body:"CodeAnt AI reviewed the modal root change and the two updated call sites. No blocking issues found."}]')
run_gate "$FRESH_REVIEW" "$(ca_convo_genuine)"
check_eq "true"  "$(met)"          "(h) fresh approval: met == true"
check_eq "0"     "$RC"             "(h) fresh approval: exit 0"
if [[ "$ERRTXT" != *"issue #876"* ]]; then
  ok "(h) fresh approval: redemption code never fired"
else
  bad "(h) fresh approval: redemption fired on a non-stale approval (stderr: '$ERRTXT')"
fi

# -------------------------------------------------------------------------
echo "----------------------------------------"
echo "merge-gate-codeant-inplace-review.test.sh: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
