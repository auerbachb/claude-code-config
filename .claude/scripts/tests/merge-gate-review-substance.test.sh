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

echo "=== (m) evaluator rejects malformed stdin ==="
echo "not json" | "$EVAL_SUT" >/dev/null 2>&1
check_eq "4" "$?" "(m) non-JSON stdin exits 4"
printf '' | "$EVAL_SUT" >/dev/null 2>&1
check_eq "4" "$?" "(m) empty stdin exits 4"

echo
echo "----------------------------------------"
echo "PASS: $PASS   FAIL: $FAIL"
[[ "$FAIL" -eq 0 ]] || exit 1
