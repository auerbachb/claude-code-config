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
#   (ee) sha_tokens admission rules on a decimal HEAD -> issue #894, both
#        directions plus the invariant that the code-span rule can only ever
#        withhold coverage, never grant it
#   (ff-933) a bot echoing the AUTHOR's SHA-bearing text  -> does not name HEAD
#        (issue #933, trace on PR #929), with the parity, ordering and
#        self-quotation controls that keep the rule from over-stripping;
#        (k)/(l): the fence exemption covers the DELIMITER, not the whole line,
#        so an echoed "```<sha>" smuggles nothing yet still masks its block;
#        (n): an echo edited in place into an older bot comment is stripped on
#        updated_at, with the unedited case as the ordering control
#   (gg-927) a long post-run-start descriptive comment without a SHA grants
#        external evidence; timing/failure/start-marker/completion-marker
#        negatives stay hollow, and an existing wrong-SHA self-report remains
#        disqualifying
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

echo "=== (v) an edited older comment cannot mask a newer SHA self-report (BugBot, PR #883) ==="
# $cidx sorts on updated_at, and these bots edit in place — CodeRabbit rewrites
# its rate-limit notice to name each new range. An older comment naming HEAD,
# edited after a newer comment named a different commit, used to sort last and
# win the self-report. Post time is the stable dimension.
FAKE_REVIEWS="$(approval "codeant-ai[bot]" "")"
FAKE_ISSUE_COMMENTS="$(jq -cn --arg sha "$HEAD_SHA" '[
  {user:{login:"codeant-ai[bot]",type:"Bot"},
   body:("CodeAnt AI finished reviewing commit " + $sha + " and found no blocking issues in the changes."),
   created_at:"2026-07-31T10:01:00Z", updated_at:"2026-07-31T10:09:00Z"},
  {user:{login:"codeant-ai[bot]",type:"Bot"},
   body:"CodeAnt AI finished reviewing commit 98f0bd0 and found no blocking issues in the changes.",
   created_at:"2026-07-31T10:03:00Z", updated_at:"2026-07-31T10:03:00Z"}]')"
OUT="$(run_gate)"
check_eq "codeant-ai[bot]" "$(echo "$OUT" | jq -r '.review_evidence.mismatched[0]')" "(v) newest POSTED self-report wins over an edited older one"
check_eq "false" "$(echo "$OUT" | jq -r '.met')" "(v) gate blocks on the mismatch"

echo "=== (w) same-second approval and run marker counts as inversion (BugBot, PR #883) ==="
# GitHub timestamps are whole-second, so this ordering is unknowable from the
# data — and no real review starts and finishes inside one second.
FAKE_REVIEWS="$(approval "codeant-ai[bot]" "" "2026-07-31T10:00:22Z")"
FAKE_ISSUE_COMMENTS="$(convo "codeant-ai[bot]" "CodeAnt AI is running the review." "2026-07-31T10:00:22Z")"
OUT="$(run_gate)"
check_eq "codeant-ai[bot]" "$(echo "$OUT" | jq -r '.review_evidence.inverted[0]')" "(w) same-second marker still inverts"
# ...and the innocent shape is still protected by external evidence.
FAKE_PR_COMMENTS="$(jq -cn --arg sha "$HEAD_SHA" '[{user:{login:"codeant-ai[bot]",type:"Bot"},commit_id:$sha,original_commit_id:$sha,created_at:"2026-07-31T10:00:30Z",path:"a.sh",body:"Suggestion: unreachable branch."}]')"
OUT="$(run_gate)"
check_eq "false" "$(echo "$OUT" | jq -r '.review_evidence.reviewers["codeant-ai[bot]"].temporal_inversion')" "(w) real inline evidence still clears it"
FAKE_PR_COMMENTS='[]'

echo "=== (x) a duplicate empty APPROVED does not discard the substantive one (BugBot, PR #883) ==="
# These bots approve in bursts — CodeAnt posted four identical APPROVEDs in the
# same second on this PR. Keying substance off only the latest one threw away a
# real review body whenever an empty duplicate landed after it.
FAKE_REVIEWS="$(jq -cn --arg sha "$HEAD_SHA" \
  '[{user:{login:"codeant-ai[bot]",type:"Bot"},commit_id:$sha,state:"APPROVED",
     body:"Actionable comments posted: 0. Reviewed all changed files; no blocking issues found.",
     submitted_at:"2026-07-31T10:04:00Z"},
    {user:{login:"codeant-ai[bot]",type:"Bot"},commit_id:$sha,state:"APPROVED",
     body:"",submitted_at:"2026-07-31T10:04:02Z"}]')"
FAKE_ISSUE_COMMENTS='[]'
OUT="$(run_gate)"
check_eq "true" "$(echo "$OUT" | jq -r '.met')" "(x) the substantive approval still counts"
check_eq "codeant-ai[bot]" "$(echo "$OUT" | jq -r '.review_evidence.substantive[0]')" "(x) reported as substantive, not hollow"

echo "=== (y) a 'review triggered' ack is not a run-start marker (BugBot, PR #883) ==="
# pr-state.sh and poll-watermarks.sh both classify this as an acknowledgment.
# Admitting it as a marker let a content-free ack become the EARLIEST post-push
# marker and mask a real inversion against the genuine notice that followed.
FAKE_REVIEWS="$(approval "codeant-ai[bot]" "" "2026-07-31T10:00:16Z")"
FAKE_ISSUE_COMMENTS="$(convo \
  "codeant-ai[bot]" "Actions performed: Full review triggered." "2026-07-31T10:00:05Z" \
  "codeant-ai[bot]" "CodeAnt AI is running the review." "2026-07-31T10:00:22Z")"
OUT="$(run_gate)"
check_eq "codeant-ai[bot]" "$(echo "$OUT" | jq -r '.review_evidence.inverted[0]')" "(y) ack does not mask the real inversion"
check_eq "2026-07-31T10:00:22Z" "$(echo "$OUT" | jq -r '.review_evidence.reviewers["codeant-ai[bot]"].run_start_marker_at')" "(y) marker is the genuine notice, not the ack"

echo "=== (z) a substantive COMMENTED review on HEAD is evidence (BugBot, PR #883) ==="
# BugBot's normal shape, and CodeAnt's genuine pass on a1c03ed, are COMMENTED
# reviews. Pooling substance from APPROVED bodies only ignored them.
FAKE_REVIEWS="$(jq -cn --arg sha "$HEAD_SHA" \
  '[{user:{login:"codeant-ai[bot]",type:"Bot"},commit_id:$sha,state:"COMMENTED",
     body:"Reviewed the changed files. The evaluator now folds inversion and capability failure into one rule; no blocking issues.",
     submitted_at:"2026-07-31T10:03:00Z"},
    {user:{login:"codeant-ai[bot]",type:"Bot"},commit_id:$sha,state:"APPROVED",
     body:"",submitted_at:"2026-07-31T10:04:00Z"}]')"
FAKE_ISSUE_COMMENTS='[]'
OUT="$(run_gate)"
check_eq "true" "$(echo "$OUT" | jq -r '.met')" "(z) a real COMMENTED review backs the empty approval"
check_eq "true" "$(echo "$OUT" | jq -r '.review_evidence.reviewers["codeant-ai[bot]"].external_evidence_on_head')" "(z) counted as evidence outside the approval"

echo "=== (aa) a STALE retargeted review cannot supply substance (CodeAnt, PR #883) ==="
# GitHub retargets commit_id onto HEAD after a force-push without touching
# submitted_at, so an older substantive review can surface attached to a commit
# it never saw. FAKE_COMMIT_TS is 10:00:00Z; both reviews below predate it.
FAKE_REVIEWS="$(jq -cn --arg sha "$HEAD_SHA" \
  '[{user:{login:"codeant-ai[bot]",type:"Bot"},commit_id:$sha,state:"APPROVED",
     body:"Actionable comments posted: 0. Reviewed every changed file; no blocking issues found here.",
     submitted_at:"2026-07-30T09:00:00Z"},
    {user:{login:"codeant-ai[bot]",type:"Bot"},commit_id:$sha,state:"COMMENTED",
     body:"Reviewed the changed files in detail and found nothing blocking in this revision.",
     submitted_at:"2026-07-30T09:00:30Z"}]')"
FAKE_ISSUE_COMMENTS='[]'
OUT="$(run_gate)"
check_eq "0" "$(echo "$OUT" | jq -r '.review_evidence.reviewers["codeant-ai[bot]"].body_len')" "(aa) pre-commit approval body contributes nothing"
check_eq "0" "$(echo "$OUT" | jq -r '.review_evidence.reviewers["codeant-ai[bot]"].other_review_body_len')" "(aa) pre-commit COMMENTED body contributes nothing"
check_eq "false" "$(echo "$OUT" | jq -r '.met')" "(aa) stale evidence does not satisfy the gate"

echo "=== (bb) a pooled approval body does NOT clear inversion (BugBot, PR #883) ==="
# Pins a deliberate decision. BugBot asked that case (x)'s pooled APPROVED body
# suppress temporal_inversion too. Declined: $ext_substantive excludes every
# approval body ON PURPOSE, because CodeAnt raised the circular form of exactly
# this as a Critical earlier on this PR — a verbose stamp posted before its own
# start marker would exonerate itself and inversion would never fire on it.
# Content produced before the bot says it began working is the anomaly, not the
# alibi. The innocent shape stays clear via evidence outside the approval, which
# cases (w) and (z) cover.
FAKE_REVIEWS="$(jq -cn --arg sha "$HEAD_SHA" \
  '[{user:{login:"codeant-ai[bot]",type:"Bot"},commit_id:$sha,state:"APPROVED",
     body:"Actionable comments posted: 0. Reviewed all changed files; no blocking issues found.",
     submitted_at:"2026-07-31T10:04:00Z"},
    {user:{login:"codeant-ai[bot]",type:"Bot"},commit_id:$sha,state:"APPROVED",
     body:"",submitted_at:"2026-07-31T10:04:02Z"}]')"
FAKE_ISSUE_COMMENTS="$(convo \
  "codeant-ai[bot]" "CodeAnt AI is running the review, this may take a few minutes." "2026-07-31T10:05:00Z")"
OUT="$(run_gate)"
check_eq "84" "$(echo "$OUT" | jq -r '.review_evidence.reviewers["codeant-ai[bot]"].body_len')" "(bb) the pooled body is still reported"
check_eq "true" "$(echo "$OUT" | jq -r '.review_evidence.reviewers["codeant-ai[bot]"].substantive')" "(bb) and still counts as substance"
check_eq "false" "$(echo "$OUT" | jq -r '.review_evidence.reviewers["codeant-ai[bot]"].external_evidence_on_head')" "(bb) but is not evidence outside the approval"
check_eq "true" "$(echo "$OUT" | jq -r '.review_evidence.reviewers["codeant-ai[bot]"].temporal_inversion')" "(bb) so the inversion stands"
check_eq "false" "$(echo "$OUT" | jq -r '.met')" "(bb) and the gate does not pass on it"

echo "=== (cc) a run marker in the PUSH second is still post-push (BugBot, PR #883) ==="
# FAKE_COMMIT_TS is 10:00:00Z. The marker selector used a STRICT "> \$push" while
# review freshness one screen above used an INCLUSIVE ">=", so a marker landing
# in the same second as the commit was discarded and temporal_inversion could not
# fire at all — exactly when these bots post, seconds either side of a push.
# canon_ts has already dropped fractional seconds, so "a fraction of a second
# after the push" IS the push second. With a body long enough to clear min_chars,
# the old asymmetry let a stamp that announced its own start after approving
# count as full coverage.
FAKE_REVIEWS="$(approval "codeant-ai[bot]" "Actionable comments posted: 0. Reviewed all changed files; no blocking issues found." "2026-07-31T10:00:00Z")"
FAKE_ISSUE_COMMENTS="$(convo "codeant-ai[bot]" "CodeAnt AI is running the review." "2026-07-31T10:00:00Z")"
FAKE_PR_COMMENTS='[]'
OUT="$(run_gate)"
check_eq "true" "$(echo "$OUT" | jq -r '.review_evidence.reviewers["codeant-ai[bot]"].substantive')" "(cc) the body alone still reads as substance"
check_eq "true" "$(echo "$OUT" | jq -r '.review_evidence.reviewers["codeant-ai[bot]"].temporal_inversion')" "(cc) but the same-second marker now inverts it"
check_eq "false" "$(echo "$OUT" | jq -r '.review_evidence.reviewers["codeant-ai[bot]"].counts_as_coverage')" "(cc) so it is not coverage"
check_eq "false" "$(echo "$OUT" | jq -r '.met')" "(cc) and the gate does not pass on it"
# The innocent shape is still protected: evidence outside the approval clears it.
FAKE_PR_COMMENTS="$(jq -cn --arg sha "$HEAD_SHA" '[{user:{login:"codeant-ai[bot]",type:"Bot"},commit_id:$sha,original_commit_id:$sha,created_at:"2026-07-31T10:00:40Z",path:"a.sh",body:"Suggestion: unreachable branch."}]')"
OUT="$(run_gate)"
check_eq "false" "$(echo "$OUT" | jq -r '.review_evidence.reviewers["codeant-ai[bot]"].temporal_inversion')" "(cc) external evidence still clears the same-second inversion"
FAKE_PR_COMMENTS='[]'

echo "=== (dd) a capability-failure notice in the PUSH second still counts (BugBot, PR #883) ==="
# Same off-by-one on the sibling selector: a "cannot review" notice posted in the
# commit second was ignored, so an approval right behind it read as clean.
FAKE_REVIEWS="$(approval "coderabbitai[bot]" "" "2026-07-31T10:00:30Z")"
FAKE_ISSUE_COMMENTS="$(convo "coderabbitai[bot]" "We could not run the review due to a rate limit on your organization." "2026-07-31T10:00:00Z")"
OUT="$(run_gate)"
check_eq "true" "$(echo "$OUT" | jq -r '.review_evidence.reviewers["coderabbitai[bot]"].capability_failure')" "(dd) same-second failure notice is still post-push"
check_eq "false" "$(echo "$OUT" | jq -r '.met')" "(dd) and the gate does not pass on it"

echo "=== (ee) sha_tokens admission rules, at the evaluator (issue #894) ==="
# Case (k) above pins that BARE digit runs are not commit ids. This case pins the
# two all-decimal admissions added for #894 and, more importantly, the ASYMMETRY
# that makes the second one safe. Driven through review-substance.sh directly so
# the token rules are pinned independently of merge-gate.sh's plumbing.
#
# HEAD here has an ALL-DECIMAL 7-char short form — 3.5% of real commits (15 of
# the last 431 on main). Under the pre-#894 rule NO token could be extracted from
# a comment naming it, so status_comment_names_head was structurally false and
# the #876 redemption could never fire on those commits.
DEC_HEAD="1234567abcdef0123456789abcdef0123456789a"
ee_eval() { # <comment-body>  -> the codeant reviewer object
  jq -cn --arg sha "$DEC_HEAD" --arg b "$1" \
    '{head_sha:$sha, push_ts:"2026-07-31T10:00:00Z",
      reviews:[{user:{login:"codeant-ai[bot]"},commit_id:$sha,state:"APPROVED",
                submitted_at:"2026-07-31T10:04:00Z",body:""}],
      pr_comments:[],
      issue_comments:[{user:{login:"codeant-ai[bot]"},
                       created_at:"2026-07-31T10:05:00Z",
                       updated_at:"2026-07-31T10:05:00Z", body:$b}]}' \
  | "$EVAL_SUT" 2>/dev/null | jq -c '.reviewers["codeant-ai[bot]"]'
}
SUMMARY_TAIL=$'\n\nReviewed the modal root change and the two updated call sites. No blocking issues found.'

# Rule 2 — IDENTITY. An all-decimal run that prefix-matches HEAD is a commit id.
R2="$(ee_eval "## Review summary for \`1234567\`${SUMMARY_TAIL}")"
check_eq "true"  "$(echo "$R2" | jq -r '.status_comment_names_head')"  "(ee) rule 2: a decimal run prefix-matching HEAD names HEAD"
check_eq "true"  "$(echo "$R2" | jq -r '.external_evidence_on_head')"  "(ee) rule 2: and so supplies evidence outside the approval"
check_eq "false" "$(echo "$R2" | jq -r '.self_report_mismatch')"       "(ee) rule 2: with no mismatch, because it names this commit"

# Rule 3 — CODE SPAN. An all-decimal run in a complete inline code span is a
# self-report candidate even when it is NOT HEAD. This is what keeps the #875
# mismatch diagnostic alive when the SHA a rubber stamp names is all decimal.
R3="$(ee_eval "## Review summary for \`9998887\`${SUMMARY_TAIL}")"
check_eq "true"  "$(echo "$R3" | jq -r '.self_report_mismatch')"       "(ee) rule 3: an older all-decimal SHA is still recorded as a mismatch"
check_eq "9998887" "$(echo "$R3" | jq -r '.status_comment_shas[0] // "NONE"')" "(ee) rule 3: and is reported, so the blocker names the SHA it read"

# THE INVARIANT that makes rule 3 safe, asserted rather than argued. A token
# admitted by rule 3 and not by rule 2 is by construction an all-decimal run that
# does NOT prefix-match HEAD, so it can never satisfy tokens_name_head. Rule 3
# therefore cannot move names_head or external_evidence_on_head at all — its ONLY
# reachable effect is self_report_mismatch false -> true, i.e. WITHHOLDING
# coverage. If a future change ever lets a code-span token redeem an approval,
# these two flip to true and this case fails.
check_eq "false" "$(echo "$R3" | jq -r '.status_comment_names_head')"  "(ee) invariant: a rule-3-only token can never name HEAD"
check_eq "false" "$(echo "$R3" | jq -r '.external_evidence_on_head')"  "(ee) invariant: and can never redeem a stale approval"

# Neither rule admits bare prose decimals — the (k) guarantee, restated against a
# decimal HEAD so the widening cannot have quietly relaxed it.
R0="$(ee_eval "CodeAnt AI reviewed 20260801 files across 1234567890 lines of diff for issue 4128773 and found nothing worth reporting.")"
check_eq "false" "$(echo "$R0" | jq -r '.status_comment_names_head')"  "(ee) prose decimals still name nothing"
check_eq "false" "$(echo "$R0" | jq -r '.self_report_mismatch')"       "(ee) prose decimals still manufacture no mismatch"
check_eq "[]"    "$(echo "$R0" | jq -c '.status_comment_shas')"        "(ee) prose decimals yield no tokens at all"

# Rule 3 reads FENCE-STRIPPED text (CodeRabbit CLI review of PR for #894). A
# walkthrough quotes diff hunks in ``` fences, and quoted code carries backticks
# of its own — a JS template literal is a numeric literal being DISCUSSED, not a
# commit the bot claims to have read. Without the strip this fixture manufactures
# a self_report_mismatch out of someone else's source code and withholds coverage
# from an honest reviewer.
# Backticks are escaped inside double quotes rather than protected by single
# quotes: the single-quoted form is equivalent but trips shellcheck SC2016, and
# the fix here is to write it unambiguously, not to silence the check.
RF="$(ee_eval "$(printf "Walkthrough of the changed files, covering both call sites in detail.\n\n\`\`\`js\nconst id = \`1234599\`;\n\`\`\`\n")")"
check_eq "false" "$(echo "$RF" | jq -r '.self_report_mismatch')"       "(ee) fenced code: a template literal is not a self-report"
check_eq "[]"    "$(echo "$RF" | jq -c '.status_comment_shas')"        "(ee) fenced code: and yields no tokens"
# Prose is still scanned when a fence appears elsewhere in the same comment —
# the strip must remove the block, not give up on the whole body.
RF2="$(ee_eval "$(printf "Reviewed for \`9998887\`, which changed both call sites.\n\n\`\`\`js\nconst id = \`1234599\`;\n\`\`\`\n")")"
check_eq "true"  "$(echo "$RF2" | jq -r '.self_report_mismatch')"      "(ee) fenced code: a real self-report outside the fence still counts"
check_eq "9998887" "$(echo "$RF2" | jq -r '.status_comment_shas[0] // "NONE"')" "(ee) fenced code: and only the out-of-fence token is admitted"
# Rule 2 is NOT fence-stripped, deliberately: it is anchored on HEAD's identity,
# so a run that matches HEAD is HEAD wherever it appears.
RF3="$(ee_eval "$(printf "Walkthrough of the changed files, covering both call sites in detail.\n\n\`\`\`\nreviewed 1234567 across both call sites\n\`\`\`\n")")"
check_eq "true"  "$(echo "$RF3" | jq -r '.status_comment_names_head')" "(ee) rule 2 is not fence-stripped: HEAD is HEAD wherever it appears"

# Rule 1 is untouched: a hex-letter token still works exactly as before, and a
# hex SHA that is NOT HEAD still mismatches on a decimal-short HEAD.
R1="$(ee_eval "Re-analysis complete. The reviewed commit for this run was \`abc1234\`, covering the modal root change.")"
check_eq "true"  "$(echo "$R1" | jq -r '.self_report_mismatch')"       "(ee) rule 1: an older hex SHA still mismatches"
check_eq "false" "$(echo "$R1" | jq -r '.external_evidence_on_head')"  "(ee) rule 1: and still cannot redeem"

# --- Issue #897: extend fence strip to tilde fences, indented blocks, unclosed openers ---
# Rules 1 and 2 keep reading $btxt (raw) by design — "HEAD is HEAD wherever it
# appears" — so only rule 3 (code-span) reads fence-stripped text. The cases
# below pin the three new shapes. All three must FAIL before the fix in
# review-substance.sh is applied (pre-fix-fail evidence) and pass after.

echo "=== (ee-897) tilde fence: decimal run inside is not a self-report ==="
RF_TILDE="$(ee_eval "$(printf "Walkthrough of the changed files, covering both call sites in detail.\n\n~~~js\nconst id = \`1234599\`;\n~~~\n")")"
check_eq "false" "$(echo "$RF_TILDE" | jq -r '.self_report_mismatch')"      "(ee-897) tilde fence: a template literal is not a self-report"
check_eq "[]"    "$(echo "$RF_TILDE" | jq -c '.status_comment_shas')"       "(ee-897) tilde fence: and yields no tokens"
check_eq "false" "$(echo "$RF_TILDE" | jq -r '.status_comment_names_head')" "(ee-897) tilde fence: one-directional invariant: cannot name HEAD"
check_eq "false" "$(echo "$RF_TILDE" | jq -r '.external_evidence_on_head')" "(ee-897) tilde fence: one-directional invariant: cannot redeem"
RF_TILDE2="$(ee_eval "$(printf "Reviewed for \`9998887\`, which changed both call sites.\n\n~~~js\nconst id = \`1234599\`;\n~~~\n")")"
check_eq "true"  "$(echo "$RF_TILDE2" | jq -r '.self_report_mismatch')"     "(ee-897) tilde fence: a real self-report outside the fence still counts"
check_eq "9998887" "$(echo "$RF_TILDE2" | jq -r '.status_comment_shas[0] // "NONE"')" "(ee-897) tilde fence: and only the out-of-fence token is admitted"
RF_TILDE3="$(ee_eval "$(printf "Walkthrough of the changed files, covering both call sites in detail.\n\n~~~\nreviewed 1234567 across both call sites\n~~~\n")")"
check_eq "true"  "$(echo "$RF_TILDE3" | jq -r '.status_comment_names_head')" "(ee-897) rule 2 not tilde-stripped: HEAD is HEAD wherever it appears"

echo "=== (ee-897) four-space-indented block: decimal run inside is not a self-report ==="
RF_INDENT="$(ee_eval "$(printf "Walkthrough of the changed files, covering both call sites in detail.\n\n    const id = \`1234599\`;\n")")"
check_eq "false" "$(echo "$RF_INDENT" | jq -r '.self_report_mismatch')"      "(ee-897) indented block: a template literal is not a self-report"
check_eq "[]"    "$(echo "$RF_INDENT" | jq -c '.status_comment_shas')"       "(ee-897) indented block: and yields no tokens"
check_eq "false" "$(echo "$RF_INDENT" | jq -r '.status_comment_names_head')" "(ee-897) indented block: one-directional invariant: cannot name HEAD"
check_eq "false" "$(echo "$RF_INDENT" | jq -r '.external_evidence_on_head')" "(ee-897) indented block: one-directional invariant: cannot redeem"
RF_INDENT3="$(ee_eval "$(printf "Walkthrough of the changed files, covering both call sites in detail.\n\n    reviewed 1234567 across both call sites\n")")"
check_eq "true"  "$(echo "$RF_INDENT3" | jq -r '.status_comment_names_head')" "(ee-897) rule 2 not indented-stripped: HEAD is HEAD wherever it appears"

echo "=== (ee-897) unclosed triple-backtick opener: decimal run inside is not a self-report ==="
RF_UNCLOSED="$(ee_eval "$(printf "Walkthrough of the changed files, covering both call sites in detail.\n\n\`\`\`js\nconst id = \`1234599\`;\n")")"
check_eq "false" "$(echo "$RF_UNCLOSED" | jq -r '.self_report_mismatch')"      "(ee-897) unclosed fence: a template literal is not a self-report"
check_eq "[]"    "$(echo "$RF_UNCLOSED" | jq -c '.status_comment_shas')"       "(ee-897) unclosed fence: and yields no tokens"
check_eq "false" "$(echo "$RF_UNCLOSED" | jq -r '.status_comment_names_head')" "(ee-897) unclosed fence: one-directional invariant: cannot name HEAD"
check_eq "false" "$(echo "$RF_UNCLOSED" | jq -r '.external_evidence_on_head')" "(ee-897) unclosed fence: one-directional invariant: cannot redeem"

echo "=== (ee-897) inline triple-backtick in prose: code span AFTER it is still scanned ==="
# A ``` that appears mid-sentence (not at start of line) must not strip the rest of
# the body. Without the line-start anchor fix, gsub("```.*";"m") swallows everything
# from the inline ``` forward, hiding the mismatch-inducing code span `1234599`.
RF_INLINE_TICK="$(ee_eval "$(printf "Review uses \`\`\` syntax for fences. Old commit \`1234599\` was not HEAD.\n")")"
check_eq "true"  "$(echo "$RF_INLINE_TICK" | jq -r '.self_report_mismatch')"   "(ee-897) inline-tick: code span after inline fence marker is not suppressed"
check_eq "1234599" "$(echo "$RF_INLINE_TICK" | jq -r '.status_comment_shas[0] // "NONE"')" "(ee-897) inline-tick: token is collected correctly"
# Same assertion for start-of-body ``` (the sub() path) — must still strip the fence
RF_BODY_START_FENCE="$(ee_eval "$(printf "\`\`\`js\nconst id = \`1234599\`;\n")")"
check_eq "false" "$(echo "$RF_BODY_START_FENCE" | jq -r '.self_report_mismatch')"   "(ee-897) body-start fence: template literal inside fence is not a self-report"
check_eq "[]"    "$(echo "$RF_BODY_START_FENCE" | jq -c '.status_comment_shas')"    "(ee-897) body-start fence: yields no tokens"

echo "=== (ee-917) UUID-embedded hex fragments are not admitted as SHA candidates (issue #917) ==="
# CodeRabbit embeds an invocation UUID (8-4-4-4-12 hyphenated hex, e.g.
# "9f69125b-29d9-47d4-bf8f-8b5df9dcb5a6") in run-tracking HTML comments. \b
# treats a hyphen as a non-word boundary, so the UUID splits into 5 segments
# at scan time — its first (8 hex chars) and last (12 hex chars) groups
# independently satisfy rule 1's shape (7-40 chars, >= one a-f letter) and
# were admitted as SHA-like tokens the bot never actually claimed.
UUID_BODY="A comment carrying only CodeRabbit's own run-tracking metadata. <!-- request id 9f69125b-29d9-47d4-bf8f-8b5df9dcb5a6 -->"
RU0="$(ee_eval "$UUID_BODY")"
check_eq "[]"    "$(echo "$RU0" | jq -c '.status_comment_shas')" "(ee-917) a bare invocation UUID yields no tokens at all"
check_eq "false" "$(echo "$RU0" | jq -r '.self_report_mismatch')" "(ee-917) and manufactures no mismatch on its own"

# Identifier-glued UUID (CodeAnt review, PR #923): \b treats "_" as a word
# character equal to a hex digit, so a UUID glued directly to a preceding
# identifier with no separator ("request_id_9f69125b-…") has NO \b boundary
# before its first hex digit. The first fix used \b and never stripped this
# shape at all — rule 1's own scan still admitted the trailing 12-char group
# as a bare hex token, reproducing the original bug for this one adjacency.
UUID_GLUED_BODY="Comment ref request_id_9f69125b-29d9-47d4-bf8f-8b5df9dcb5a6 posted."
RU_GLUED="$(ee_eval "$UUID_GLUED_BODY")"
check_eq "[]"    "$(echo "$RU_GLUED" | jq -c '.status_comment_shas')" "(ee-917) an identifier-glued UUID yields no tokens either"
check_eq "false" "$(echo "$RU_GLUED" | jq -r '.self_report_mismatch')" "(ee-917) and manufactures no mismatch"

# Real-world shape (auerbachb/longlove PR #161, 2026-08-01): a single comment
# mixing the UUID with a genuine HEAD-naming token does NOT reproduce the
# reported failure — tokens_name_head is an any(...) over one comment's own
# token list, so the genuine token alone makes that comment's names_head true
# regardless of UUID noise sitting beside it. The actual production shape
# needs TWO comments from the same bot: an earlier, substantive comment that
# names HEAD (setting the bot-level status_comment_names_head), followed by a
# LATER, separate status comment carrying only the invocation UUID and no SHA
# mention. self_report_mismatch is computed from $selfrep — the bot's most
# recently CREATED comment that has ANY tokens — so pre-fix, that later
# UUID-only comment became $selfrep, and since none of ITS tokens named HEAD,
# self_report_mismatch flipped true even though status_comment_names_head was
# already true from the earlier comment. That contradictory pair — both true
# at once — is exactly what was observed on PR #161.
UUID_HEAD="a1b2c3d4e5f60718293a4b5c6d7e8f9012345678"
uuid_eval() { # <earlier-body> <later-body>  -> the coderabbitai reviewer object
  jq -cn --arg sha "$UUID_HEAD" --arg b1 "$1" --arg b2 "$2" \
    '{head_sha:$sha, push_ts:"2026-07-31T10:00:00Z",
      reviews:[{user:{login:"coderabbitai[bot]"},commit_id:$sha,state:"APPROVED",
                submitted_at:"2026-07-31T10:06:00Z",body:""}],
      pr_comments:[],
      issue_comments:[
        {user:{login:"coderabbitai[bot]"},
         created_at:"2026-07-31T10:03:00Z",
         updated_at:"2026-07-31T10:03:00Z", body:$b1},
        {user:{login:"coderabbitai[bot]"},
         created_at:"2026-07-31T10:05:00Z",
         updated_at:"2026-07-31T10:05:00Z", body:$b2}
      ]}' \
  | "$EVAL_SUT" 2>/dev/null | jq -c '.reviewers["coderabbitai[bot]"]'
}
WALKTHROUGH_BODY="$(printf "## Walkthrough\n\nReviewed the modal root change and the two updated call sites for commit \`a1b2c3d\`. No blocking issues found.")"
UUID_STATUS_BODY="<!-- This is an auto-generated comment by CodeRabbit with request id 9f69125b-29d9-47d4-bf8f-8b5df9dcb5a6 -->"

RU="$(uuid_eval "$WALKTHROUGH_BODY" "$UUID_STATUS_BODY")"
check_eq "true"     "$(echo "$RU" | jq -r '.status_comment_names_head')" "(ee-917) an earlier comment naming HEAD still sets status_comment_names_head"
check_eq '["a1b2c3d"]' "$(echo "$RU" | jq -c '.status_comment_shas')"    "(ee-917) only the genuine token is admitted — no UUID fragments"
check_eq "false"    "$(echo "$RU" | jq -r '.self_report_mismatch')"     "(ee-917) a later UUID-only status comment no longer manufactures a mismatch"
check_eq "[]"       "$(echo "$RU" | jq -c '.disqualified_by')"          "(ee-917) and the reviewer is not disqualified"

echo "=== (xx-408) review command invocation UUID does not wedge a genuine approval (issue #1248) ==="
# auerbachb/inventory issue #408 / this repo issue #1248. CodeRabbit's "Action
# performed" reply embeds a GUID in a <!-- CodeRabbit review command invocation:
# UUID --> HTML comment. A GUID's first segment (8 hex chars) and last segment
# (12 hex chars) satisfy rule 1's shape (7-40 chars, >= one a-f letter) and
# were misread as SHAs the bot claimed to have reviewed. The production shape
# requires two comments: an earlier walkthrough naming HEAD, then a LATER
# "Action performed" comment whose only SHA-shaped tokens are GUID segments.
# $selfrep (most-recently-created comment with tokens) becomes the "Action
# performed" comment pre-fix, and its GUID segments don't match HEAD.
#
# This fixture uses the real GUID (df440ae1-9ab9-4b17-bb0a-caae8c17534a) and
# HEAD SHA (05b928597c90aebd91f9eb644808a25a20a01d82) from inventory PR #403.
GUID_HEAD="05b928597c90aebd91f9eb644808a25a20a01d82"
guid_eval() { # <earlier-body> <later-body> -> the coderabbitai reviewer object
  jq -cn --arg sha "$GUID_HEAD" --arg b1 "$1" --arg b2 "$2" \
    '{head_sha:$sha, push_ts:"2026-08-01T09:00:00Z",
      reviews:[{user:{login:"coderabbitai[bot]"},commit_id:$sha,state:"APPROVED",
                submitted_at:"2026-08-01T11:00:00Z",body:""}],
      pr_comments:[],
      issue_comments:[
        {user:{login:"coderabbitai[bot]"},
         created_at:"2026-08-01T09:24:55Z",
         updated_at:"2026-08-01T09:24:55Z", body:$b1},
        {user:{login:"coderabbitai[bot]"},
         created_at:"2026-08-01T09:51:15Z",
         updated_at:"2026-08-01T09:51:15Z", body:$b2}
      ]}' \
  | "$EVAL_SUT" 2>/dev/null | jq -c '.reviewers["coderabbitai[bot]"]'
}
GUID_WALKTHROUGH_BODY="$(printf "## Walkthrough\n\nReviewed the space-membership ACL changes and the personal-space derivation for commit \`05b9285\`. No blocking issues found.")"
GUID_INVOCATION_BODY="$(printf '<!-- This is an auto-generated reply by CodeRabbit -->\n<!-- CodeRabbit review command invocation: df440ae1-9ab9-4b17-bb0a-caae8c17534a -->\n<details>\n<summary>Action performed</summary>\n\nFull review finished.\n\n</details>')"

RI="$(guid_eval "$GUID_WALKTHROUGH_BODY" "$GUID_INVOCATION_BODY")"
check_eq "true"        "$(echo "$RI" | jq -r '.status_comment_names_head')"  "(xx-408) walkthrough naming HEAD still sets status_comment_names_head"
check_eq '["05b9285"]' "$(echo "$RI" | jq -c '.status_comment_shas')"        "(xx-408) only the genuine short SHA is admitted — no GUID segments"
check_eq "false"       "$(echo "$RI" | jq -r '.self_report_mismatch')"       "(xx-408) invocation GUID does not manufacture a self_report_mismatch"
check_eq "[]"          "$(echo "$RI" | jq -c '.disqualified_by')"            "(xx-408) and the approval is not disqualified"
# Negative control: a genuine non-HEAD SHA in the later comment still trips mismatch,
# proving the fixture discriminates and is not trivially passing.
GUID_NONHEAD_BODY="$(printf 'Reviewed changes for commit deadbeef1234567890abcdef1234567890abcdef in this round.')"
RI_NEG="$(guid_eval "$GUID_WALKTHROUGH_BODY" "$GUID_NONHEAD_BODY")"
check_eq "true"        "$(echo "$RI_NEG" | jq -r '.self_report_mismatch')"   "(xx-408) negative control: genuine non-HEAD SHA still triggers mismatch"

echo "=== (xx-408b) run-start marker + invocation-only comment does not grant descriptive evidence (CodeAnt PR #1280) ==="
# CodeAnt finding (PR #1280): a run-start marker followed by a GUID invocation
# comment whose authored_len >= $min_chars used to satisfy $descriptive_ev,
# granting counts_as_coverage on a hollow approval without any genuine review
# substance. The invocation_comment flag (issue #1248 follow-up) must suppress
# this path. The eval here uses two comments anchored to the same GUID_HEAD:
#   b1: run-start marker (CodeRabbit is running the review…)
#   b2: GUID invocation comment (Action performed / Full review finished)
# with a concurrent empty APPROVED on HEAD.
#
# guid_eval puts b1 before b2 (created order), so $marker = b1 and b2 is the
# only candidate for $descriptive_ev. The fix means b2 is excluded (invocation_comment).
GUID_MARKER_BODY="CodeRabbit is running the review. Please wait while the analysis completes."
RI_B="$(guid_eval "$GUID_MARKER_BODY" "$GUID_INVOCATION_BODY")"
check_eq "false"  "$(echo "$RI_B" | jq -r '.descriptive_evidence_on_head')"  "(xx-408b) invocation-only comment does not satisfy descriptive_evidence_on_head"
check_eq "false"  "$(echo "$RI_B" | jq -r '.external_evidence_on_head')"     "(xx-408b) no external substance without genuine review content"
check_eq "false"  "$(echo "$RI_B" | jq -r '.counts_as_coverage')"            "(xx-408b) hollow approval + invocation comment is not coverage"
# Positive control 1: a genuine descriptive comment (after the marker) still grants evidence.
GUID_GENUINE_DESC="This change looks reasonable. The GUID handling is correct and the test coverage is thorough."
RI_C="$(guid_eval "$GUID_MARKER_BODY" "$GUID_GENUINE_DESC")"
check_eq "true"   "$(echo "$RI_C" | jq -r '.descriptive_evidence_on_head')"  "(xx-408b) positive control: genuine descriptive comment after marker grants evidence"
# Positive control 2: invocation HTML metadata FOLLOWED by genuine prose is NOT invocation_comment.
# A comment with both shapes must have its prose part evaluated, not excluded wholesale.
# (CodeRabbit finding, PR #1280 — pattern must not over-match prose that mentions
# invocation phrases outside of the HTML-comment wrapper, nor exclude comments that
# carry both metadata and genuine substance.)
GUID_HYBRID_BODY="$(printf '%s\n\n%s' "$GUID_INVOCATION_BODY" "The new invocation_comment flag is well-targeted. The implementation correctly identifies invocation-only metadata.")"
RI_D="$(guid_eval "$GUID_MARKER_BODY" "$GUID_HYBRID_BODY")"
check_eq "true"   "$(echo "$RI_D" | jq -r '.descriptive_evidence_on_head')"  "(xx-408b) invocation metadata + genuine prose still satisfies descriptive_evidence_on_head"

echo "=== (xx-408c) invocation_comment requires phrase inside complete HTML comment with full UUID ==="
# CodeRabbit finding (PR #1280): the v2 invocation_comment check must:
#   1. Bind the phrase only to COMPLETE <!-- --> blocks (scan prevents crossing -->).
#   2. Require a full 8-4-4-4-12 UUID inside the block (not a prefix or UUID-less phrase).
# Each case below would have had invocation_comment=true with the v1 pattern
# (excluding the comment from $descriptive_ev), but must be false with v2.
#
# (a) Phrase outside comment: the v1 regex crossed --> into prose on the next
# line (the "m" flag made . match newlines). Residual = 37 chars < 40, so
# invocation_comment flipped true — the comment was wrongly excluded even
# though the phrase appeared in prose, not inside any HTML comment.
GUID_OUTSIDE_BODY="$(printf '<!-- a longer unrelated HTML comment -->\nreview command invocation: documented')"
RI_E="$(guid_eval "$GUID_MARKER_BODY" "$GUID_OUTSIDE_BODY")"
check_eq "true" "$(echo "$RI_E" | jq -r '.descriptive_evidence_on_head')"  "(xx-408c) phrase outside HTML comment is not invocation_comment; comment still eligible for descriptive_ev"
# (b) UUID-less invocation phrase: the v1 regex matched the bare phrase with no
# UUID requirement, so the invocation-keyword-only comment was incorrectly excluded.
GUID_NOUID_BODY="<!-- review command invocation: documented and thoroughly explained -->"
RI_F="$(guid_eval "$GUID_MARKER_BODY" "$GUID_NOUID_BODY")"
check_eq "true" "$(echo "$RI_F" | jq -r '.descriptive_evidence_on_head')"  "(xx-408c) UUID-less invocation phrase in HTML comment is not invocation_comment"
# (c) Incomplete UUID (prefix only, missing 4-4-12 tail): the v1 regex accepted
# "request id [8hex]-[4hex]-" with no further constraint, so a partial UUID also
# flipped invocation_comment=true incorrectly.
GUID_SHORTUID_BODY="<!-- This is a partial request id 9f69125b-29d9-47d4- without full uuid -->"
RI_G="$(guid_eval "$GUID_MARKER_BODY" "$GUID_SHORTUID_BODY")"
check_eq "true" "$(echo "$RI_G" | jq -r '.descriptive_evidence_on_head')"  "(xx-408c) incomplete UUID prefix in HTML comment is not invocation_comment"

echo "=== (xx-408d) invocation_comment boundary: overlong UUID and echoed-line residual inflation ==="
# CodeRabbit findings (PR #1280, PRRT_kwDORbRzR86bdTJq / PRRT_kwDORbRzR86bdTJs):
#
# (a) Overlong UUID — PRRT_kwDORbRzR86bdTJq (Minor):
# The UUID regex had no boundary after {12}. A 37-char last group matched the
# first 12 hex chars without rejecting the extra digit. Adding (?![0-9a-f])
# after {12} prevents a hex run longer than 12 from matching.
# Expected: invocation_comment=false (no valid full-UUID match) and
# descriptive_evidence_on_head=true (comment is eligible for $descriptive_ev).
GUID_LONGUID_BODY="<!-- review command invocation: df440ae1-9ab9-4b17-bb0a-caae8c17534a0 -->"
RI_H="$(guid_eval "$GUID_MARKER_BODY" "$GUID_LONGUID_BODY")"
check_eq "true" "$(echo "$RI_H" | jq -r '.descriptive_evidence_on_head')"  "(xx-408d) overlong UUID in last segment is not a valid invocation_comment"

# (b) Echoed line inflates residual — PRRT_kwDORbRzR86bdTJs (Major):
# The residual check for invocation_comment scanned raw $b. If a bot comment
# contained the invocation metadata HTML comment plus a verbatim copy of the
# author's (or an earlier bot) text, the echoed line kept the residual >=
# $min_chars, flipping invocation_comment=false even though no genuine
# reviewer-authored prose remained. Applying strip_echoed($cts) before the
# residual check removes echoed lines, so the residual only reflects prose the
# reviewer actually wrote.
# Here b2 = GUID_INVOCATION_BODY + GUID_MARKER_BODY (marker echoed from b1).
# Without strip_echoed: residual includes the marker line (~75 chars) >= 40 ->
# invocation_comment=false -> descriptive_evidence_on_head=true (WRONG).
# With strip_echoed: marker line stripped -> residual ~38 chars < 40 ->
# invocation_comment=true -> descriptive_evidence_on_head=false (CORRECT).
GUID_ECHOED_BODY="$(printf '%s\n%s' "$GUID_INVOCATION_BODY" "$GUID_MARKER_BODY")"
RI_I="$(guid_eval "$GUID_MARKER_BODY" "$GUID_ECHOED_BODY")"
check_eq "false" "$(echo "$RI_I" | jq -r '.descriptive_evidence_on_head')"  "(xx-408d) echoed line does not inflate residual past min_chars in invocation_comment filter"

echo "=== (ff-933) a reviewer echoing the author's SHA-bearing text does not name HEAD ==="
# Issue #933, trace on PR #929 (2026-08-02). CodeAnt answers a re-review request
# by reproducing the requester's comment verbatim (lowercased) under a
# "Question:" heading and putting its own verdict under "Answer:". The author's
# trigger prose named HEAD's short SHA, so the bot's body contained `5acd1e2`
# without the bot ever having written it — and status_comment_names_head, the
# flag that asserts "this reviewer demonstrably read HEAD", went true on the
# strength of the AUTHOR's words. Replayed on the live payload, main scored that
# CodeAnt approval counts_as_coverage=true; the fix scores it false.
#
# The rule is "a line someone else already posted", NOT "a blockquote line".
# Case (e) is the negative control for that distinction and must not be deleted:
# the only ">" lines on the real PR #929 thread were CodeRabbit quoting ITSELF.
FF_HEAD="5acd1e20ef431444c38695923f73e1f30f6f1d39"
ff_eval() { # <issue-comments-json> -> the codeant reviewer object
  jq -cn --arg sha "$FF_HEAD" --argjson cs "$1" \
    '{head_sha:$sha, push_ts:"2026-07-31T10:00:00Z",
      reviews:[{user:{login:"codeant-ai[bot]"},commit_id:$sha,state:"APPROVED",
                submitted_at:"2026-07-31T10:10:00Z",body:""}],
      pr_comments:[],
      issue_comments:($cs | map({user:{login:.login}, created_at:.created,
                                 updated_at:(.updated // .created), body:.body}))}' \
  | "$EVAL_SUT" 2>/dev/null | jq -c '.reviewers["codeant-ai[bot]"]'
}
ff_pair() { # <author-body> <bot-body> [author_ts] [bot_ts]
  jq -cn --arg ab "$1" --arg bb "$2" \
         --arg at "${3:-2026-07-31T10:02:00Z}" --arg bt "${4:-2026-07-31T10:05:00Z}" \
    '[{login:"auerbachb",         created:$at, body:$ab},
      {login:"codeant-ai[bot]",   created:$bt, body:$bb}]'
}
# The author's line, and the bot's lowercased copy of it. Identical after the
# evaluator's ascii_downcase — which is what makes it an echo and not authorship.
FF_TRIGGER_LINE="Re-review requested on \`5acd1e2\`. The approval posted 43s after that push has an empty body and no inline comments, so it cannot be counted as review coverage on this SHA."
FF_ECHO_LINE="re-review requested on \`5acd1e2\`. the approval posted 43s after that push has an empty body and no inline comments, so it cannot be counted as review coverage on this sha."
FF_AUTHOR="$(printf '@codeant-ai: review\n\n%s\n' "$FF_TRIGGER_LINE")"
FF_OWN_VERDICT='## Review

No blocking findings. The documentation now matches the unchanged behavior of the extractor.'
FF_UNRELATED='Please take another look when you get a chance — the CI run is green now and the branch is rebased.'

# (a) THE TRACE. HEAD's SHA reaches the bot's body only through the echo.
FF_A="$(ff_eval "$(ff_pair "$FF_AUTHOR" "$(printf 'Question: review\n\n%s\n\nAnswer:\n%s\n' "$FF_ECHO_LINE" "$FF_OWN_VERDICT")")")"
check_eq "false" "$(echo "$FF_A" | jq -r '.status_comment_names_head')" "(ff-933) echoed author text does not name HEAD"
check_eq "false" "$(echo "$FF_A" | jq -r '.external_evidence_on_head')" "(ff-933) and so supplies no evidence outside the approval"
check_eq "false" "$(echo "$FF_A" | jq -r '.counts_as_coverage')"        "(ff-933) so the empty approval no longer counts as coverage"
check_not_contains "5acd1e2" "$(echo "$FF_A" | jq -c '.status_comment_shas')" "(ff-933) and no HEAD token is admitted from the echo"

# (b) PARITY. A genuine status comment naming HEAD in the bot's own prose is
# untouched — the whole point is to separate quoting from reviewing.
FF_B="$(ff_eval "$(ff_pair "$FF_AUTHOR" "$(printf "## Review summary for \`5acd1e2\`\n\nReviewed the modal root change and both call sites. No blocking issues found.\n")")")"
check_eq "true" "$(echo "$FF_B" | jq -r '.status_comment_names_head')" "(ff-933) parity: the bot's own prose naming HEAD still counts"
check_eq "true" "$(echo "$FF_B" | jq -r '.counts_as_coverage')"        "(ff-933) parity: and still redeems the empty approval"

# (c) PAIRED. Echo AND own prose in one body: only the echoed line is removed.
FF_C="$(ff_eval "$(ff_pair "$FF_AUTHOR" "$(printf "Question: review\n\n%s\n\nAnswer:\nReviewed commit \`5acd1e2\` end to end; no blocking issues found.\n" "$FF_ECHO_LINE")")")"
check_eq "true" "$(echo "$FF_C" | jq -r '.status_comment_names_head')" "(ff-933) the strip removes the quoted line, not the whole body"

# (d) GitHub "Quote reply" shape: "> " + the original line. Quote markers are
# normalised out of the lookup key, so this is the same echo as (a).
FF_D="$(ff_eval "$(ff_pair "$FF_AUTHOR" "$(printf '> %s\n\nAcknowledged. No blocking findings after a full pass over the diff.\n' "$FF_ECHO_LINE")")")"
check_eq "false" "$(echo "$FF_D" | jq -r '.status_comment_names_head')" "(ff-933) a blockquoted echo of the author is caught too"

# (e) NEGATIVE CONTROL — self-quotation is NOT an echo. CodeRabbit renders its
# own reviewed range as "> Reviewing files that changed ... between X and Y";
# on the real PR #929 thread those were the ONLY ">" lines present. A rule that
# dropped every blockquote line would delete a reviewer's own self-report here
# while closing none of case (a). If this flips to false, the rule has drifted
# back to "strip all quotes".
FF_E="$(ff_eval "$(ff_pair "$FF_UNRELATED" "$(printf '> Reviewing files that changed from the base of the PR and between c441771 and 5acd1e2\n\nStatus: review complete, no blocking findings on this commit.\n')")")"
check_eq "true" "$(echo "$FF_E" | jq -r '.status_comment_names_head')" "(ff-933) a bot's own blockquoted callout is not an echo"

# (f) ORDER MATTERS. The same line posted by the author AFTER the bot is not
# something the bot could have echoed; the bot's own line survives.
FF_F="$(ff_eval "$(ff_pair "$(printf 'Confirming for the record.\n\n%s\n' "$FF_TRIGGER_LINE")" "$(printf 'Reviewed. %s\n' "$FF_ECHO_LINE")" "2026-07-31T10:08:00Z" "2026-07-31T10:05:00Z")")"
check_eq "true" "$(echo "$FF_F" | jq -r '.status_comment_names_head')" "(ff-933) a later author comment cannot retroactively strip the bot"

# (g) A quoted OLDER SHA is not the reviewer's self-report (issue #933; same
# direction #917 accepted for UUID fragments). The bot never claimed to have
# read c441771 — the author did — so no mismatch is manufactured from it.
FF_OLD_LINE="Please re-check \`c441771\`; that is the commit the earlier approval actually covered."
FF_G="$(ff_eval "$(ff_pair "$(printf '@codeant-ai: review\n\n%s\n' "$FF_OLD_LINE")" "$(printf 'Question: review\n\n%s\n\nAnswer:\n%s\n' "$(echo "$FF_OLD_LINE" | tr '[:upper:]' '[:lower:]')" "$FF_OWN_VERDICT")")")"
check_eq "[]"    "$(echo "$FF_G" | jq -c '.status_comment_shas')"   "(ff-933) a quoted older SHA yields no tokens"
check_eq "false" "$(echo "$FF_G" | jq -r '.self_report_mismatch')"  "(ff-933) and manufactures no self-report mismatch"

# (h) A reviewer can never strip ITSELF. Only non-reviewer comments seed the
# index, so a bot repeating its own status line keeps its evidence both times.
FF_SELF_LINE="Reviewed commit \`5acd1e2\` end to end; no blocking issues found."
FF_H="$(ff_eval "$(jq -cn --arg l "$FF_SELF_LINE" --arg u "$FF_UNRELATED" \
  '[{login:"auerbachb",       created:"2026-07-31T10:02:00Z", body:$u},
    {login:"codeant-ai[bot]", created:"2026-07-31T10:05:00Z", body:$l},
    {login:"codeant-ai[bot]", created:"2026-07-31T10:07:00Z", body:$l}]')")"
check_eq "true" "$(echo "$FF_H" | jq -r '.status_comment_names_head')" "(ff-933) a reviewer repeating its own line does not erase itself"

# (i) SCOPE BOUNDARY, pinned deliberately: corroborator bots are reviewers too,
# so one reviewer quoting another is out of scope and changes nothing. Widening
# the index to bot-authored text must be a conscious decision, not a drift.
FF_I="$(ff_eval "$(jq -cn --arg l "$FF_SELF_LINE" --arg u "$FF_UNRELATED" \
  '[{login:"auerbachb",       created:"2026-07-31T10:02:00Z", body:$u},
    {login:"cursor[bot]",     created:"2026-07-31T10:03:00Z", body:$l},
    {login:"codeant-ai[bot]", created:"2026-07-31T10:05:00Z", body:$l}]')")"
check_eq "true" "$(echo "$FF_I" | jq -r '.status_comment_names_head')" "(ff-933) reviewer-quotes-reviewer stays out of scope"

# (j) Fence delimiters are STRUCTURE, not content, and are never dropped as
# echoes (CodeRabbit CLI review of this PR). A bare "```" line is one of the
# most reproducible lines a human can post — any comment containing a code block
# has one — so without an exception the delimiters of a reviewer's own fenced
# block get stripped, the #897 masking silently stops matching, and numeric
# literals in quoted diff hunks become self-report candidates again. Stripping
# only the CLOSER is worse: the opener then runs to end-of-body and deletes
# rule-3 tokens that should have been admitted, which is the grant direction.
FF_J_AUTHOR="$(printf "Repro for the failing case:\n\n\`\`\`\nbash .claude/scripts/tests/merge-gate-review-substance.test.sh\n\`\`\`\n\nShould be green after the rebase.\n")"
FF_J_BOT="$(printf "Walkthrough of the changed files, covering both call sites in detail.\n\n\`\`\`\nconst id = \`1234599\`;\n\`\`\`\n")"
FF_J="$(ff_eval "$(ff_pair "$FF_J_AUTHOR" "$FF_J_BOT")")"
check_eq "[]"    "$(echo "$FF_J" | jq -c '.status_comment_shas')"  "(ff-933) an echoed fence delimiter still masks its block"
check_eq "false" "$(echo "$FF_J" | jq -r '.self_report_mismatch')" "(ff-933) so quoted source code is still not a self-report"

# (k) THE EXEMPTION IS THE DELIMITER, NOT THE LINE (CodeAnt PR #951 review).
# Markdown info strings are free-form, so a fence opener can carry arbitrary
# text — including HEAD's SHA. Exempting the whole line because it STARTS with
# a fence marker readmits exactly the token the echo rule just refused, which
# is the grant direction: before the fix these bodies scored
# status_comment_names_head=true and counts_as_coverage=true off the AUTHOR's
# words. Both spellings are the same class: fence marker + SHA-bearing info
# string.
for FF_K_LINE in '```5acd1e2' '``` reviewed at 5acd1e2'; do
  FF_K_AUTHOR="$(printf 'Please re-review:\n\n%s\nsome quoted source\n```\n' "$FF_K_LINE")"
  FF_K_BOT="$(printf 'Question:\n\n%s\nsome quoted source\n```\n\nAnswer: no blocking findings.\n' "$FF_K_LINE")"
  FF_K="$(ff_eval "$(ff_pair "$FF_K_AUTHOR" "$FF_K_BOT")")"
  check_eq "false" "$(echo "$FF_K" | jq -r '.status_comment_names_head')" \
    "(ff-933)(k) an echoed fence line does not smuggle its info-string SHA [$FF_K_LINE]"
  check_eq "false" "$(echo "$FF_K" | jq -r '.counts_as_coverage')" \
    "(ff-933)(k) so the empty approval still gets no coverage [$FF_K_LINE]"
done

# (l) …and truncating it does not cost the masking the exemption exists for.
# The echoed opener keeps its delimiter (only the info string goes), so the
# #897 paired matching still finds an opener and a closer, the block is masked,
# and the numeric literal inside quoted source is still not a rule-3 token.
# If the truncation ever stops being delimiter-preserving, this pair regresses
# to the failure mode (j) exists to prevent.
FF_L_AUTHOR="$(printf "Repro for the failing case:\n\n\`\`\`js\nconst a = 1;\n\`\`\`\n\nShould be green after the rebase.\n")"
FF_L_BOT="$(printf "Walkthrough of the changed files, covering both call sites.\n\n\`\`\`js\nconst id = \`1234599\`;\n\`\`\`\n")"
FF_L="$(ff_eval "$(ff_pair "$FF_L_AUTHOR" "$FF_L_BOT")")"
check_eq "[]"    "$(echo "$FF_L" | jq -c '.status_comment_shas')"  "(ff-933)(l) a truncated echoed opener still pairs and masks its block"
check_eq "false" "$(echo "$FF_L" | jq -r '.self_report_mismatch')" "(ff-933)(l) so quoted source is still not a self-report"

# (n) IN-PLACE EDITS (BugBot review of PR #951). GitHub freezes created_at when
# a comment is edited, and editing in place is the norm for these bots — CodeAnt
# PATCHes its review body on re-review (#876), CodeRabbit rewrites its
# walkthrough. Scanning on created_at let a bot EDIT an echo of the author's
# prose into a comment it had opened BEFORE the author wrote it: the bot's
# comment sorted ahead of the index entry, the line survived, and HEAD evidence
# was manufactured without the bot ever writing the SHA. The scan now takes
# updated_at, so the echo is stripped on the edited body's real timing.
FF_N="$(ff_eval "$(jq -cn --arg t "$FF_TRIGGER_LINE" --arg e "$FF_ECHO_LINE" '
  [ {login:"codeant-ai[bot]", created:"2026-07-31T10:01:00Z", updated:"2026-07-31T10:09:00Z",
     body:("Status: reviewing this PR.\n\n" + $e + "\n\nNo blocking findings.\n")},
    {login:"auerbachb", created:"2026-07-31T10:05:00Z",
     body:("@codeant-ai: review\n\n" + $t + "\n")} ]')")"
check_eq "false" "$(echo "$FF_N" | jq -r '.status_comment_names_head')" "(ff-933)(n) an echo edited into an older bot comment is still stripped"
check_eq "false" "$(echo "$FF_N" | jq -r '.counts_as_coverage')"        "(ff-933)(n) so an in-place edit cannot manufacture coverage"

# (n) control: the same two comments with the bot's body NEVER edited. This is
# the (f) ordering guard — the author's line came later, so it cannot have been
# echoed — and it must stay true, or the change has turned an ordering rule into
# "strip whenever the text matches".
FF_N2="$(ff_eval "$(jq -cn --arg t "$FF_TRIGGER_LINE" --arg e "$FF_ECHO_LINE" '
  [ {login:"codeant-ai[bot]", created:"2026-07-31T10:01:00Z",
     body:("Status: reviewing this PR.\n\n" + $e + "\n\nNo blocking findings.\n")},
    {login:"auerbachb", created:"2026-07-31T10:05:00Z",
     body:("@codeant-ai: review\n\n" + $t + "\n")} ]')")"
check_eq "true" "$(echo "$FF_N2" | jq -r '.status_comment_names_head')" "(ff-933)(n) control: an unedited earlier bot comment keeps its line"

echo "=== (gg-927) descriptive current-round comments are external evidence ==="
RUN_START="CodeAnt AI is running the review."
DESCRIPTIVE_SUMMARY="## Sequence Diagram
This change preserves the merge gate while recognizing a detailed reviewer summary tied to the current review round without requiring the summary to repeat a commit SHA."

FAKE_REVIEWS="$(approval "codeant-ai[bot]" "")"
FAKE_ISSUE_COMMENTS="$(convo \
  "codeant-ai[bot]" "$RUN_START" "2026-07-31T10:01:00Z" \
  "codeant-ai[bot]" "$DESCRIPTIVE_SUMMARY" "2026-07-31T10:03:00Z")"
OUT="$(run_gate)"
GG_REVIEWER="$(echo "$OUT" | jq -c '.review_evidence.reviewers["codeant-ai[bot]"]')"
check_eq "true"  "$(echo "$OUT" | jq -r '.met')" "(gg-927) long post-marker description satisfies the gate"
check_eq "false" "$(echo "$GG_REVIEWER" | jq -r '.status_comment_names_head')" "(gg-927) description does not need to name HEAD"
check_eq "true"  "$(echo "$GG_REVIEWER" | jq -r '.descriptive_evidence_on_head')" "(gg-927) descriptive evidence is inspectable"
check_eq "true"  "$(echo "$GG_REVIEWER" | jq -r '.external_evidence_on_head')" "(gg-927) description contributes external evidence"
check_eq "true"  "$(echo "$GG_REVIEWER" | jq -r '.counts_as_coverage')" "(gg-927) description grants substantive coverage"
check_not_contains "no_substantive_footprint" "$(echo "$GG_REVIEWER" | jq -r '.disqualified_by | join(" | ")')" "(gg-927) hollow reason is removed"

echo "=== (gg-927) short description remains hollow ==="
FAKE_ISSUE_COMMENTS="$(convo \
  "codeant-ai[bot]" "$RUN_START" "2026-07-31T10:01:00Z" \
  "codeant-ai[bot]" "Reviewed the change." "2026-07-31T10:03:00Z")"
OUT="$(run_gate)"
check_eq "false" "$(echo "$OUT" | jq -r '.review_evidence.reviewers["codeant-ai[bot]"].descriptive_evidence_on_head')" "(gg-927) short description is rejected"
check_contains "no_substantive_footprint" "$(echo "$OUT" | jq -r '.review_evidence.reviewers["codeant-ai[bot]"].disqualified_by | join(" | ")')" "(gg-927) short description stays hollow"

LONG_RUN_START="CodeAnt AI is running the review and will post a separate analysis when the review work has completed."
FAKE_ISSUE_COMMENTS="$(convo "codeant-ai[bot]" "$LONG_RUN_START" "2026-07-31T10:01:00Z")"
OUT="$(run_gate)"
check_eq "false" "$(echo "$OUT" | jq -r '.review_evidence.reviewers["codeant-ai[bot]"].descriptive_evidence_on_head')" "(gg-927) a long run-start marker is not its own descriptive evidence"
check_contains "no_substantive_footprint" "$(echo "$OUT" | jq -r '.review_evidence.reviewers["codeant-ai[bot]"].disqualified_by | join(" | ")')" "(gg-927) a content-free run marker stays hollow"

# The production completion notice is 39 characters, just below the default
# threshold. Lower the supported threshold to prove the exclusion is semantic,
# not an accidental consequence of that current spelling's length.
FAKE_ISSUE_COMMENTS="$(convo \
  "codeant-ai[bot]" "$RUN_START" "2026-07-31T10:01:00Z" \
  "codeant-ai[bot]" "CodeAnt AI finished running the review." "2026-07-31T10:03:00Z")"
export MERGE_GATE_SUBSTANCE_MIN_CHARS=20
OUT="$(run_gate)"
unset MERGE_GATE_SUBSTANCE_MIN_CHARS
check_eq "false" "$(echo "$OUT" | jq -r '.review_evidence.reviewers["codeant-ai[bot]"].descriptive_evidence_on_head')" "(gg-927) a fixed completion marker is not descriptive evidence"
check_contains "no_substantive_footprint" "$(echo "$OUT" | jq -r '.review_evidence.reviewers["codeant-ai[bot]"].disqualified_by | join(" | ")')" "(gg-927) a content-free completion marker stays hollow"

FAKE_ISSUE_COMMENTS="$(convo \
  "codeant-ai[bot]" "$RUN_START" "2026-07-31T10:01:00Z" \
  "auerbachb" "$DESCRIPTIVE_SUMMARY" "2026-07-31T10:02:00Z" \
  "codeant-ai[bot]" "$DESCRIPTIVE_SUMMARY" "2026-07-31T10:03:00Z")"
OUT="$(run_gate)"
check_eq "false" "$(echo "$OUT" | jq -r '.review_evidence.reviewers["codeant-ai[bot]"].descriptive_evidence_on_head')" "(gg-927) echoed author prose is not reviewer-authored descriptive evidence"
check_contains "no_substantive_footprint" "$(echo "$OUT" | jq -r '.review_evidence.reviewers["codeant-ai[bot]"].disqualified_by | join(" | ")')" "(gg-927) an echo-only description stays hollow"

ECHO_SOURCE="$(jq -nr '[range(1; 51) | "Author evidence line \(.)."] | join("\n")')"
ECHO_WITH_BLANKS="$(printf '%s\n' "$ECHO_SOURCE" | sed 'G')"
FAKE_ISSUE_COMMENTS="$(convo \
  "codeant-ai[bot]" "$RUN_START" "2026-07-31T10:01:00Z" \
  "auerbachb" "$ECHO_SOURCE" "2026-07-31T10:02:00Z" \
  "codeant-ai[bot]" "$ECHO_WITH_BLANKS" "2026-07-31T10:03:00Z")"
OUT="$(run_gate)"
check_eq "false" "$(echo "$OUT" | jq -r '.review_evidence.reviewers["codeant-ai[bot]"].descriptive_evidence_on_head')" "(gg-927) blank separators left after echo stripping are not authored evidence"
check_contains "no_substantive_footprint" "$(echo "$OUT" | jq -r '.review_evidence.reviewers["codeant-ai[bot]"].disqualified_by | join(" | ")')" "(gg-927) echo-only whitespace remnants stay hollow"

echo "=== (gg-927) pre-marker and pre-push descriptions remain hollow ==="
FAKE_ISSUE_COMMENTS="$(convo \
  "codeant-ai[bot]" "$DESCRIPTIVE_SUMMARY" "2026-07-31T10:00:30Z" \
  "codeant-ai[bot]" "$RUN_START" "2026-07-31T10:01:00Z")"
OUT="$(run_gate)"
check_eq "false" "$(echo "$OUT" | jq -r '.review_evidence.reviewers["codeant-ai[bot]"].descriptive_evidence_on_head')" "(gg-927) pre-marker description is rejected"

FAKE_ISSUE_COMMENTS="$(convo \
  "codeant-ai[bot]" "$DESCRIPTIVE_SUMMARY" "2026-07-31T09:59:00Z" \
  "codeant-ai[bot]" "$RUN_START" "2026-07-31T10:01:00Z")"
OUT="$(run_gate)"
check_eq "false" "$(echo "$OUT" | jq -r '.review_evidence.reviewers["codeant-ai[bot]"].descriptive_evidence_on_head')" "(gg-927) pre-push description is rejected"

echo "=== (gg-927) failure notice and missing marker remain hollow ==="
FAILURE_SUMMARY="CodeAnt could not run the requested review because its usage limit was reached, so no analysis of the current diff was performed."
FAKE_ISSUE_COMMENTS="$(convo \
  "codeant-ai[bot]" "$RUN_START" "2026-07-31T10:01:00Z" \
  "codeant-ai[bot]" "$FAILURE_SUMMARY" "2026-07-31T10:03:00Z")"
OUT="$(run_gate)"
check_eq "false" "$(echo "$OUT" | jq -r '.review_evidence.reviewers["codeant-ai[bot]"].descriptive_evidence_on_head')" "(gg-927) capability-failure notice is rejected"

FAKE_ISSUE_COMMENTS="$(convo "codeant-ai[bot]" "$DESCRIPTIVE_SUMMARY" "2026-07-31T10:03:00Z")"
OUT="$(run_gate)"
check_eq "false" "$(echo "$OUT" | jq -r '.review_evidence.reviewers["codeant-ai[bot]"].descriptive_evidence_on_head')" "(gg-927) description without a run-start marker is rejected"
check_contains "no_substantive_footprint" "$(echo "$OUT" | jq -r '.review_evidence.reviewers["codeant-ai[bot]"].disqualified_by | join(" | ")')" "(gg-927) no-marker description stays hollow"

echo "=== (gg-927) descriptive evidence cannot launder a wrong-SHA self-report ==="
FAKE_ISSUE_COMMENTS="$(convo \
  "codeant-ai[bot]" "$RUN_START" "2026-07-31T10:01:00Z" \
  "codeant-ai[bot]" "CodeAnt AI finished reviewing commit 98f0bd0 and found no blocking issues in the changes." "2026-07-31T10:02:00Z" \
  "codeant-ai[bot]" "$DESCRIPTIVE_SUMMARY" "2026-07-31T10:03:00Z")"
OUT="$(run_gate)"
GG_REVIEWER="$(echo "$OUT" | jq -c '.review_evidence.reviewers["codeant-ai[bot]"]')"
check_eq "true"  "$(echo "$GG_REVIEWER" | jq -r '.descriptive_evidence_on_head')" "(gg-927) descriptive channel is active beside mismatch"
check_eq "true"  "$(echo "$GG_REVIEWER" | jq -r '.self_report_mismatch')" "(gg-927) wrong-SHA self-report remains a mismatch"
check_eq "false" "$(echo "$GG_REVIEWER" | jq -r '.counts_as_coverage')" "(gg-927) mismatch still disqualifies the approval"
check_contains "self_report_mismatch" "$(echo "$GG_REVIEWER" | jq -r '.disqualified_by | join(" | ")')" "(gg-927) mismatch reason remains explicit"
check_not_contains "no_substantive_footprint" "$(echo "$GG_REVIEWER" | jq -r '.disqualified_by | join(" | ")')" "(gg-927) only the hollow reason is cleared"

echo "=== (m) evaluator rejects malformed stdin ==="
echo "not json" | "$EVAL_SUT" >/dev/null 2>&1
check_eq "4" "$?" "(m) non-JSON stdin exits 4"
printf '' | "$EVAL_SUT" >/dev/null 2>&1
check_eq "4" "$?" "(m) empty stdin exits 4"

echo
echo "----------------------------------------"
echo "PASS: $PASS   FAIL: $FAIL"
[[ "$FAIL" -eq 0 ]] || exit 1
