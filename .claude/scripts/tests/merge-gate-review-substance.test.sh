#!/usr/bin/env bash
# merge-gate-review-substance.test.sh — Regression tests for issue #875:
# merge-gate.sh must not count a bot APPROVED as review coverage when nothing
# evidences that the reviewer actually read the commit.
#
# Every case below is drawn from a real observed trace:
#   #171 3634336 — CodeAnt APPROVED bodylen=0, status comment naming 98f0bd0
#   #172 d5976d8 — CodeAnt APPROVED bodylen=0 8s post-push, naming 396ced5
#   #172 396ced5 — CodeRabbit APPROVED bodylen=0 but walkthrough named the exact
#                  95febff…396ced5 range and listed 3 files — GENUINE, must pass
#   #867 f54effb — CodeAnt APPROVED 06:24:44Z, its own "is running the review"
#                  marker at 06:24:50Z (6s LATER) and a "does not have a PR
#                  Review subscription" notice 11s before the approval
#
# Acceptance criteria covered:
#   (a) substantive review body                       -> met
#   (b) bodylen=0 + walkthrough naming HEAD range     -> met  (false-negative guard)
#   (c) bodylen=0 + status comment naming another SHA -> NOT met, mismatch reason
#   (d) bodylen=0 + no footprint at all               -> NOT met, hollow reason
#   (e) hollow CodeAnt + substantive CodeRabbit       -> met  (either bot suffices)
#   (f) --allow-hollow-approval                       -> met, evidence still reports it
#   (g) bodylen=0 + inline comments on HEAD           -> met
#   (h) approval predating its own run-start marker   -> NOT met, temporal inversion
#   (i) capability-failure notice on this SHA         -> NOT met, capability failure
#   (j) rate-limit notice followed by a real review   -> met  (false-negative guard)
#   (k) digit-only hex-shaped tokens                  -> no manufactured mismatch
#   (l) review_evidence present on non-cr paths       -> emitted, does not gate
#
# Only `gh` is stubbed; merge-gate.sh, review-substance.sh, ci-status.sh,
# check-runs-dedup.sh and session-state.sh are the real scripts.
#
# Run from repo root: bash .claude/scripts/tests/merge-gate-review-substance.test.sh
set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
SUT="$REPO_ROOT/.claude/scripts/merge-gate.sh"
EVAL_SUT="$REPO_ROOT/.claude/scripts/review-substance.sh"

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
check_contains() { # needle haystack label
  case "$2" in
    *"$1"*) ok "$3" ;;
    *) bad "$3 (missing '$1' in: $2)" ;;
  esac
}
check_not_contains() { # needle haystack label
  case "$2" in
    *"$1"*) bad "$3 (unexpectedly found '$1')" ;;
    *) ok "$3" ;;
  esac
}

HEAD_SHA="396ced5aabbccddeeff001122334455667788990"
COMMIT_TS="2026-07-31T10:00:00Z"
APPROVE_TS="2026-07-31T10:04:00Z"

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
      '{number:1, state:"OPEN", headRefOid:$sha, baseRefName:"main",
        mergeStateStatus:"CLEAN", mergeable:"MERGEABLE", reviewDecision:"APPROVED",
        author:{login:"solouser", type:"User"}}'
    exit 0 ;;
  *"git/commits/"*)
    jq -cn --arg d "$FAKE_COMMIT_TS" '{committer:{date:$d}}'; exit 0 ;;
  *check-runs*)
    jq -cn '{check_runs:[{id:1,name:"ci",status:"completed",conclusion:"success",
               completed_at:"2026-07-31T10:02:00Z",
               check_suite:{id:1},app:{slug:"gha",id:1}}]}'
    exit 0 ;;
  *pulls/*/reviews*)
    printf '%s' "${FAKE_REVIEWS:-[]}"; exit 0 ;;
  *pulls/*/comments*)
    printf '%s' "${FAKE_PR_COMMENTS:-[]}"; exit 0 ;;
  *issues/*/comments*)
    printf '%s' "${FAKE_ISSUE_COMMENTS:-[]}"; exit 0 ;;
  *graphql*)
    jq -cn '{data:{repository:{pullRequest:{reviewThreads:{nodes:[]}}}}}'; exit 0 ;;
  *contents/*)
    echo "Not Found" >&2; exit 1 ;;
esac
echo "unexpected gh call: $ARGS" >&2
exit 1
GHEOF
chmod +x "$BIN/gh"
export PATH="$BIN:$PATH"
export HEAD_SHA
export FAKE_COMMIT_TS="$COMMIT_TS"
# Marked for export once, then assigned plainly per case: `export VAR="$(cmd)"`
# would mask the command substitution's exit status (SC2155), and the stub reads
# these from the environment, so the export attribute has to be set up front.
export FAKE_REVIEWS FAKE_PR_COMMENTS FAKE_ISSUE_COMMENTS
FAKE_REVIEWS='[]'; FAKE_PR_COMMENTS='[]'; FAKE_ISSUE_COMMENTS='[]'

# --- Fixture builders ---------------------------------------------------
approval() { # <login> <body> [submitted_at]
  jq -cn --arg l "$1" --arg b "$2" --arg sha "$HEAD_SHA" --arg t "${3:-$APPROVE_TS}" \
    '[{user:{login:$l,type:"Bot"}, commit_id:$sha, state:"APPROVED", body:$b, submitted_at:$t}]'
}
convo() { # <login> <body> <created_at> [<login2> <body2> <created2>]
  jq -cn --args '[ $ARGS.positional | _nwise(3) | {user:{login:.[0],type:"Bot"}, body:.[1], created_at:.[2], updated_at:.[2]} ]' "$@"
}

run_gate() { # extra args...
  "$SUT" 1 --reviewer cr "$@" 2>"$TMP/err.txt"
}

WALKTHROUGH="## Walkthrough
Reviewed the range 95febff...396ced5. Files processed: 3. The change adds the
flow-dispatch seam plus its unit tests and updates the reference doc."

echo "=== (a) substantive review body -> met ==="
FAKE_REVIEWS="$(approval "coderabbitai[bot]" "Actionable comments posted: 0. Reviewed 3 files; behaviour preserved.")"
FAKE_PR_COMMENTS='[]'
FAKE_ISSUE_COMMENTS='[]'
OUT="$(run_gate)"
check_eq "true" "$(echo "$OUT" | jq -r '.met')" "(a) gate met on a substantive body"
check_eq "true" "$(echo "$OUT" | jq -r '.primary_review_met')" "(a) primary_review_met true"
check_eq "coderabbitai[bot]" "$(echo "$OUT" | jq -r '.review_evidence.substantive[0]')" "(a) evidence names the substantive reviewer"

echo "=== (b) bodylen=0 + walkthrough naming HEAD range -> met (false-negative guard) ==="
FAKE_REVIEWS="$(approval "coderabbitai[bot]" "")"
FAKE_ISSUE_COMMENTS="$(convo "coderabbitai[bot]" "$WALKTHROUGH" "2026-07-31T10:03:40Z")"
OUT="$(run_gate)"
check_eq "true" "$(echo "$OUT" | jq -r '.met')" "(b) empty body + naming walkthrough still passes"
check_eq "true" "$(echo "$OUT" | jq -r '.review_evidence.reviewers["coderabbitai[bot]"].status_comment_names_head')" "(b) status comment recognised as naming HEAD"
check_eq "0" "$(echo "$OUT" | jq -r '.review_evidence.reviewers["coderabbitai[bot]"].body_len')" "(b) body really was empty"

echo "=== (c) status comment naming a different SHA -> not met ==="
FAKE_REVIEWS="$(approval "codeant-ai[bot]" "")"
FAKE_ISSUE_COMMENTS="$(convo "codeant-ai[bot]" "CodeAnt AI finished reviewing commit 98f0bd0 and found no blocking issues in the changes." "2026-07-31T10:03:00Z")"
OUT="$(run_gate)"
check_eq "false" "$(echo "$OUT" | jq -r '.met')" "(c) different-SHA self-report blocks"
check_eq "false" "$(echo "$OUT" | jq -r '.primary_review_met')" "(c) primary_review_met false"
check_eq "codeant-ai[bot]" "$(echo "$OUT" | jq -r '.review_evidence.mismatched[0]')" "(c) evidence flags the mismatch"
check_contains "own status comment names" "$(echo "$OUT" | jq -r '.missing | join(" | ")')" "(c) missing[] explains the mismatch"
check_not_contains "no explicit APPROVED review" "$(echo "$OUT" | jq -r '.missing | join(" | ")')" "(c) no contradictory absent-approval message"

echo "=== (d) no footprint at all -> not met, hollow ==="
FAKE_REVIEWS="$(approval "coderabbitai[bot]" "")"
FAKE_ISSUE_COMMENTS='[]'
OUT="$(run_gate)"
check_eq "false" "$(echo "$OUT" | jq -r '.met')" "(d) bare empty approval blocks"
check_eq "coderabbitai[bot]" "$(echo "$OUT" | jq -r '.review_evidence.hollow[0]')" "(d) evidence flags it hollow"
check_contains "no substantive review footprint" "$(echo "$OUT" | jq -r '.missing | join(" | ")')" "(d) missing[] explains the hollowness"

echo "=== (e) hollow CodeAnt + substantive CodeRabbit -> met ==="
FAKE_REVIEWS="$(jq -cn --arg sha "$HEAD_SHA" --arg t "$APPROVE_TS" \
  '[{user:{login:"codeant-ai[bot]",type:"Bot"},commit_id:$sha,state:"APPROVED",body:"",submitted_at:$t},
    {user:{login:"coderabbitai[bot]",type:"Bot"},commit_id:$sha,state:"APPROVED",body:"Actionable comments posted: 0. Reviewed 3 files; behaviour preserved.",submitted_at:$t}]')"
FAKE_ISSUE_COMMENTS='[]'
OUT="$(run_gate)"
check_eq "true" "$(echo "$OUT" | jq -r '.met')" "(e) one substantive approver is enough"
check_eq "codeant-ai[bot]" "$(echo "$OUT" | jq -r '.review_evidence.hollow[0]')" "(e) the hollow one is still reported"

echo "=== (f) --allow-hollow-approval override ==="
FAKE_REVIEWS="$(approval "coderabbitai[bot]" "")"
FAKE_ISSUE_COMMENTS='[]'
OUT="$(run_gate --allow-hollow-approval)"
check_eq "true" "$(echo "$OUT" | jq -r '.met')" "(f) override lets a hollow approval through"
check_eq "coderabbitai[bot]" "$(echo "$OUT" | jq -r '.review_evidence.hollow[0]')" "(f) evidence still records the hollow approval"
check_contains "allow-hollow-approval" "$(cat "$TMP/err.txt")" "(f) override is announced on stderr"

echo "=== (g) inline comments on HEAD -> substantive ==="
FAKE_REVIEWS="$(approval "coderabbitai[bot]" "")"
FAKE_PR_COMMENTS="$(jq -cn --arg sha "$HEAD_SHA" \
  '[{user:{login:"coderabbitai[bot]",type:"Bot"},commit_id:$sha,original_commit_id:$sha,created_at:"2026-07-31T10:03:00Z",body:"nit: prefer const"}]')"
FAKE_ISSUE_COMMENTS='[]'
OUT="$(run_gate)"
check_eq "true" "$(echo "$OUT" | jq -r '.met')" "(g) inline diff comments count as substance"
FAKE_PR_COMMENTS='[]'

echo "=== (h) temporal inversion (PR #867 shape) -> not met ==="
FAKE_REVIEWS="$(approval "codeant-ai[bot]" "" "2026-07-31T10:00:16Z")"
FAKE_ISSUE_COMMENTS="$(convo "codeant-ai[bot]" "CodeAnt AI is running the review." "2026-07-31T10:00:22Z")"
OUT="$(run_gate)"
check_eq "false" "$(echo "$OUT" | jq -r '.met')" "(h) approval predating its own run marker blocks"
check_eq "codeant-ai[bot]" "$(echo "$OUT" | jq -r '.review_evidence.inverted[0]')" "(h) evidence flags temporal inversion"
check_contains "announced it had started reviewing" "$(echo "$OUT" | jq -r '.missing | join(" | ")')" "(h) missing[] explains the inversion"

echo "=== (i) capability failure on this SHA -> not met ==="
FAKE_REVIEWS="$(approval "codeant-ai[bot]" "" "2026-07-31T10:00:16Z")"
FAKE_ISSUE_COMMENTS="$(convo "codeant-ai[bot]" "User ci@example.com does not have a PR Review subscription." "2026-07-31T10:00:05Z")"
OUT="$(run_gate)"
check_eq "false" "$(echo "$OUT" | jq -r '.met')" "(i) an approval after a capability failure blocks"
check_eq "codeant-ai[bot]" "$(echo "$OUT" | jq -r '.review_evidence.capability_failed[0]')" "(i) evidence flags the capability failure"
check_contains "reported it could not review" "$(echo "$OUT" | jq -r '.missing | join(" | ")')" "(i) missing[] explains the capability failure"

echo "=== (j) rate limit THEN a real review -> met (false-negative guard) ==="
FAKE_REVIEWS="$(approval "coderabbitai[bot]" "" "2026-07-31T10:10:00Z")"
FAKE_ISSUE_COMMENTS="$(convo \
  "coderabbitai[bot]" "Review rate limit exceeded. Please wait 37 minutes before requesting another review." "2026-07-31T10:00:30Z" \
  "coderabbitai[bot]" "$WALKTHROUGH" "2026-07-31T10:09:00Z")"
OUT="$(run_gate)"
check_eq "true" "$(echo "$OUT" | jq -r '.met')" "(j) later real work overrides an earlier rate-limit notice"
check_eq "false" "$(echo "$OUT" | jq -r '.review_evidence.reviewers["coderabbitai[bot]"].capability_failure')" "(j) capability_failure cleared by later evidence"

echo "=== (k) digit-only hex-shaped tokens do not manufacture a mismatch ==="
FAKE_REVIEWS="$(approval "codeant-ai[bot]" "")"
FAKE_ISSUE_COMMENTS="$(convo "codeant-ai[bot]" "CodeAnt AI reviewed 20260731 files across 1234567 lines and found nothing to report." "2026-07-31T10:03:00Z")"
OUT="$(run_gate)"
check_eq "false" "$(echo "$OUT" | jq -r '.review_evidence.reviewers["codeant-ai[bot]"].self_report_mismatch')" "(k) bare digit runs are not read as commit ids"
check_eq "codeant-ai[bot]" "$(echo "$OUT" | jq -r '.review_evidence.hollow[0]')" "(k) still hollow, just not for the wrong reason"

echo "=== (l) review_evidence is emitted on the bugbot path without gating it ==="
FAKE_REVIEWS="$(jq -cn --arg sha "$HEAD_SHA" --arg t "$APPROVE_TS" \
  '[{user:{login:"cursor[bot]",type:"Bot"},commit_id:$sha,state:"COMMENTED",body:"Reviewed the diff; no issues found in the changed files.",submitted_at:$t}]')"
FAKE_ISSUE_COMMENTS='[]'
OUT="$("$SUT" 1 --reviewer bugbot 2>/dev/null)"
check_eq "true" "$(echo "$OUT" | jq -e 'has("review_evidence")' >/dev/null && echo true || echo false)" "(l) review_evidence key present on the bugbot path"
# Scoped to the cr path on purpose: running the evaluator here would let its
# failure block a PR over a guard the bugbot path never consults.
check_eq "{}" "$(echo "$OUT" | jq -c '.review_evidence')" "(l) evidence is empty off the cr path"
check_eq "true" "$(echo "$OUT" | jq -r '.met')" "(l) bugbot path verdict unchanged by #875"

############################################################################
# (n)-(r): review findings on PR #883 itself. Each is a way the FIRST cut of
# this guard could still be satisfied by a reviewer that never read the commit.
############################################################################

echo "=== (n) a capability-failure notice naming HEAD is not substance (CodeAnt, PR #883) ==="
FAKE_REVIEWS="$(approval "coderabbitai[bot]" "" "2026-07-31T10:05:00Z")"
# The live shape: CodeRabbit's rate-limit notice quotes the exact commit range it
# DECLINED to review, so it is long and it names HEAD. Counting it as a status
# comment made it substance and — by becoming the newest evidence — also
# suppressed the capability_failure check that exists to catch precisely this.
FAKE_ISSUE_COMMENTS="$(convo "coderabbitai[bot]" "Review limit reached. You have reached a temporary PR review limit under our Fair Usage Limits Policy. Next review available in 18 minutes. Reviewing files that changed between 97149cc and $HEAD_SHA." "2026-07-31T10:04:30Z")"
OUT="$(run_gate)"
check_eq "false" "$(echo "$OUT" | jq -r '.met')" "(n) a declined review does not satisfy the gate"
check_eq "coderabbitai[bot]" "$(echo "$OUT" | jq -r '.review_evidence.capability_failed[0]')" "(n) still flagged as a capability failure"
check_eq "false" "$(echo "$OUT" | jq -r '.review_evidence.reviewers["coderabbitai[bot]"].status_comment_names_head')" "(n) failure notice rejected as status evidence"

echo "=== (o) a VERBOSE approval predating its own run marker still inverts (CodeAnt, PR #883) ==="
# The first cut let $ev include the approval's own body, so a long-bodied rubber
# stamp exonerated itself and inversion could never fire on it. Same trace as
# (h), only the body is no longer empty.
FAKE_REVIEWS="$(approval "codeant-ai[bot]" "Actionable comments posted: 0. Reviewed the changed files; no blocking issues found anywhere." "2026-07-31T10:00:16Z")"
FAKE_ISSUE_COMMENTS="$(convo "codeant-ai[bot]" "CodeAnt AI is running the review." "2026-07-31T10:00:22Z")"
OUT="$(run_gate)"
check_eq "false" "$(echo "$OUT" | jq -r '.met')" "(o) a verbose body cannot vouch for its own timing"
check_eq "codeant-ai[bot]" "$(echo "$OUT" | jq -r '.review_evidence.inverted[0]')" "(o) evidence still flags temporal inversion"
check_eq "false" "$(echo "$OUT" | jq -r '.review_evidence.reviewers["codeant-ai[bot]"].external_evidence_on_head')" "(o) no evidence outside the approval object"

echo "=== (p) evidence outside the approval redeems the inversion (BugBot, PR #883) ==="
# Symmetric false-negative guard: the documented genuine bodylen=0 + walkthrough
# shape must survive even when a later re-review posts its own start marker.
FAKE_REVIEWS="$(approval "coderabbitai[bot]" "" "2026-07-31T10:00:16Z")"
FAKE_ISSUE_COMMENTS="$(convo \
  "coderabbitai[bot]" "CodeRabbit is running the review." "2026-07-31T10:00:22Z" \
  "coderabbitai[bot]" "$WALKTHROUGH" "2026-07-31T10:00:40Z")"
OUT="$(run_gate)"
check_eq "true" "$(echo "$OUT" | jq -r '.met')" "(p) a real walkthrough redeems the approval whenever it lands"
check_eq "false" "$(echo "$OUT" | jq -r '.review_evidence.reviewers["coderabbitai[bot]"].temporal_inversion')" "(p) inversion suppressed by external evidence"

echo "=== (q) --allow-hollow-approval never launders an integrity failure (CodeAnt, PR #883) ==="
# The flag's documented scope is 'no substantive footprint'. An approval naming
# ANOTHER SHA is not unevidenced — it is evidence against a review of this one.
FAKE_REVIEWS="$(approval "codeant-ai[bot]" "")"
FAKE_ISSUE_COMMENTS="$(convo "codeant-ai[bot]" "CodeAnt AI finished reviewing commit 98f0bd0 and found no blocking issues in the changes." "2026-07-31T10:03:00Z")"
OUT="$(run_gate --allow-hollow-approval)"
check_eq "false" "$(echo "$OUT" | jq -r '.met')" "(q) override does not cover a self-report SHA mismatch"
check_eq "codeant-ai[bot]" "$(echo "$OUT" | jq -r '.review_evidence.mismatched[0]')" "(q) mismatch still reported"
# ...while the case it IS scoped to keeps working (regression guard on (f)).
FAKE_ISSUE_COMMENTS='[]'
OUT="$(run_gate --allow-hollow-approval)"
check_eq "true" "$(echo "$OUT" | jq -r '.met')" "(q) override still covers a plain empty footprint"

echo "=== (r) a hollow CodeAnt is reported, not blocking, when CodeRabbit passes (BugBot, PR #883) ==="
# BugBot argued this should BLOCK. It must not: cr-merge-gate.md's CR path is
# "either bot alone suffices" and CodeRabbit's coverage here is genuine, so
# blocking would hold every PR hostage to whichever bot is rubber-stamping today
# — the false-negative cost this evaluator is written to avoid. The guarantee
# BugBot actually wanted (never absorbed SILENTLY) is met by hollow[] plus the
# stderr notice, which is what this case pins.
FAKE_REVIEWS="$(jq -cn --arg sha "$HEAD_SHA" --arg t "$APPROVE_TS" \
  '[{user:{login:"coderabbitai[bot]",type:"Bot"},commit_id:$sha,state:"APPROVED",
     body:"Actionable comments posted: 0. Reviewed 3 files; behaviour preserved.",submitted_at:$t},
    {user:{login:"codeant-ai[bot]",type:"Bot"},commit_id:$sha,state:"APPROVED",
     body:"",submitted_at:$t}]')"
FAKE_ISSUE_COMMENTS='[]'
OUT="$(run_gate)"
check_eq "codeant-ai[bot]" "$(echo "$OUT" | jq -r '.review_evidence.hollow[0]')" "(r) hollow CodeAnt still reported in evidence"
check_eq "true" "$(echo "$OUT" | jq -r '.met')" "(r) a genuine CodeRabbit pass still satisfies the CR path"
check_contains "discounted APPROVED review(s)" "$(cat "$TMP/err.txt")" "(r) the rubber stamp is announced on stderr, not absorbed"

echo "=== (s) +00:00 timestamps order correctly against Z (BugBot, PR #883) ==="
# All ordering below is string comparison, and '…T10:00:22+00:00' sorts BEFORE
# '…T10:00:16Z'. Without normalisation this inversion silently disappears.
FAKE_REVIEWS="$(approval "codeant-ai[bot]" "" "2026-07-31T10:00:16+00:00")"
FAKE_ISSUE_COMMENTS="$(convo "codeant-ai[bot]" "CodeAnt AI is running the review." "2026-07-31T10:00:22+00:00")"
OUT="$(run_gate)"
check_eq "codeant-ai[bot]" "$(echo "$OUT" | jq -r '.review_evidence.inverted[0]')" "(s) inversion detected across mixed timestamp spellings"

echo "=== (t) a long approval after a capability failure does not clear it (BugBot, PR #883) ==="
# The mia#172 476798e trace with a non-empty body. The approval's own timestamp
# used to count as post-failure evidence, so the bot could say "I cannot review
# this", post a generic paragraph, and clear its own capability_failure.
FAKE_REVIEWS="$(approval "coderabbitai[bot]" "Actionable comments posted: 0. The changes look correct and consistent with the surrounding code." "2026-07-31T10:01:30Z")"
FAKE_ISSUE_COMMENTS="$(convo "coderabbitai[bot]" "Review rate limit exceeded. Please wait 37 minutes before requesting another review." "2026-07-31T10:00:30Z")"
OUT="$(run_gate)"
check_eq "false" "$(echo "$OUT" | jq -r '.met')" "(t) a paragraph cannot vouch for a review that never ran"
check_eq "coderabbitai[bot]" "$(echo "$OUT" | jq -r '.review_evidence.capability_failed[0]')" "(t) capability failure survives the approval body"

echo "=== (u) a failure notice AFTER genuine work does not void it (BugBot, PR #883) ==="
# Converse guard: a rate limit hit on a LATER re-review request must not
# retroactively void the walkthrough that already named this SHA.
FAKE_REVIEWS="$(approval "coderabbitai[bot]" "" "2026-07-31T10:03:50Z")"
FAKE_ISSUE_COMMENTS="$(convo \
  "coderabbitai[bot]" "$WALKTHROUGH" "2026-07-31T10:03:40Z" \
  "coderabbitai[bot]" "Review rate limit exceeded. Please wait 37 minutes before requesting another review." "2026-07-31T10:20:00Z")"
OUT="$(run_gate)"
check_eq "true" "$(echo "$OUT" | jq -r '.met')" "(u) a later rate limit does not erase completed work"
check_eq "false" "$(echo "$OUT" | jq -r '.review_evidence.reviewers["coderabbitai[bot]"].capability_failure')" "(u) capability_failure cleared by external evidence"

echo "=== (m) evaluator rejects malformed stdin ==="
echo "not json" | "$EVAL_SUT" >/dev/null 2>&1
check_eq "4" "$?" "(m) non-JSON stdin exits 4"
printf '' | "$EVAL_SUT" >/dev/null 2>&1
check_eq "4" "$?" "(m) empty stdin exits 4"

echo
echo "----------------------------------------"
echo "PASS: $PASS   FAIL: $FAIL"
[[ "$FAIL" -eq 0 ]] || exit 1
