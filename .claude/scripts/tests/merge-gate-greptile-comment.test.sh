#!/usr/bin/env bash
# merge-gate-greptile-comment.test.sh — Regression tests for issue #723:
# merge-gate.sh Greptile path must detect comment-based clean passes.
#
# Greptile posts via ISSUE COMMENTS (not formal PR review objects).
# A clean pass = fresh greptile-apps[bot] issue comment with 👍 reaction +
# zero inline diff comments on the PR.
#
# Tests:
#   1. Clean 👍 + no inline comments → gate met (primary fix)
#   2. 👍 + P0-badged inline findings → gate not met (severity gate)
#   3. 👍 comment created BEFORE last push (stale) → gate not met (freshness)
#
# Only `gh` is stubbed; merge-gate.sh, ci-status.sh and check-runs-dedup.sh
# are the real scripts run in place.
#
# Run from repo root: bash .claude/scripts/tests/merge-gate-greptile-comment.test.sh
set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
SUT="$REPO_ROOT/.claude/scripts/merge-gate.sh"

TMP="$(mktemp -d)"
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

# Sandbox HOME: no session-state.json → reviewer resolution uses --reviewer flag.
export HOME="$TMP/home"; mkdir -p "$HOME/.claude"

PASS=0
FAIL=0
ok()  { echo "PASS: $1"; PASS=$((PASS + 1)); }
bad() { echo "FAIL: $1" >&2; FAIL=$((FAIL + 1)); }

check_eq() { # expected actual label
  if [[ "$1" == "$2" ]]; then ok "$3"; else bad "$3 (expected: $1, got: $2)"; fi
}

HEAD_SHA="aabbccddeeff0011223344556677889900aabbcc"
# Last push: commit committer date. Tests set FAKE_COMMIT_TS relative to this.
PUSH_TS="2026-07-23T13:00:00Z"
# A timestamp clearly AFTER the push (comment is fresh).
FRESH_TS="2026-07-23T13:05:00Z"
# A timestamp clearly BEFORE the push (comment is stale).
STALE_TS="2026-07-23T12:55:00Z"
# A timestamp AFTER FRESH_TS — simulates a summary edited later than its inlines.
LATE_FRESH_TS="2026-07-23T13:10:00Z"

# --- Fake gh: stubs the endpoints merge-gate.sh calls. ----------------------
BIN="$TMP/bin"; mkdir -p "$BIN"
cat > "$BIN/gh" <<'GHEOF'
#!/usr/bin/env bash
ARGS="$*"
case "$ARGS" in
  "repo view --json nameWithOwner --jq .nameWithOwner")
    echo "solo/repo"; exit 0 ;;
  "api user --jq .login")
    # Authorship guard (issue #733): viewer login; matches the PR author below
    # so authorship == "mine" and the merge is not blocked.
    echo "solouser"; exit 0 ;;
  *"pr view "*headRefOid*)
    jq -cn \
      --arg sha  "$HEAD_SHA" \
      '{number:1, state:"OPEN", headRefOid:$sha, baseRefName:"main",
        mergeStateStatus:"CLEAN", mergeable:"MERGEABLE", reviewDecision:"APPROVED",
        author:{login:"solouser", type:"User"}}'
    exit 0 ;;
  *"git/commits/"*)
    # Return FAKE_COMMIT_TS as the committer date — used for Greptile freshness.
    jq -cn --arg d "$FAKE_COMMIT_TS" '{committer:{date:$d}}'
    exit 0 ;;
  *check-runs*)
    # Single passing check by default; focused tests can inject failures.
    if [[ -n "${FAKE_CHECK_RUNS:-}" ]]; then
      printf '%s' "$FAKE_CHECK_RUNS"
    else
      jq -cn '{check_runs:[{id:1,name:"ci",status:"completed",conclusion:"success",
        completed_at:"2026-07-23T13:01:00Z",check_suite:{id:1},app:{slug:"gha",id:1}}]}'
    fi
    exit 0 ;;
  *pulls/*/reviews*)
    # Greptile never posts formal reviews; return empty.
    printf '%s' "${FAKE_REVIEWS:-[]}"; exit 0 ;;
  *pulls/*/comments*)
    printf '%s' "${FAKE_PR_COMMENTS:-[]}"; exit 0 ;;
  *issues/*/comments*)
    printf '%s' "${FAKE_ISSUE_COMMENTS:-[]}"; exit 0 ;;
  *graphql*)
    if [[ -n "${FAKE_THREADS:-}" ]]; then
      printf '%s' "$FAKE_THREADS"
    else
      jq -cn '{data:{repository:{pullRequest:{reviewThreads:{nodes:[]}}}}}'
    fi
    exit 0 ;;
  *contents/*)
    echo "Not Found" >&2; exit 1 ;;
esac
echo "unexpected gh call: $ARGS" >&2
exit 1
GHEOF
chmod +x "$BIN/gh"

# Export HEAD_SHA so the heredoc-embedded gh stub can see it.
export HEAD_SHA
export PUSH_TS

# Helper: build a Greptile issue comment JSON object.
# Third arg (updated_at) is optional — defaults to created_at.
# GitHub's API always includes updated_at; we default it here so existing tests
# continue to produce a comment that has updated_at == created_at (pre-push when
# created_at is pre-push), preserving the stale-comment test expectations.
greptile_comment() { # created_at thumbsup_count [updated_at]
  local ts="$1" up="$2" upd="${3:-$1}"
  jq -cn --arg ts "$ts" --argjson up "$up" --arg upd "$upd" \
    '{id:1001, user:{login:"greptile-apps[bot]"},
      body:"<h3>Greptile Summary</h3>\nClean review.",
      created_at:$ts, updated_at:$upd,
      reactions:{url:"",total_count:$up,"+1":$up,"-1":0}}'
}

greptile_trigger() { # created_at
  jq -cn --arg ts "$1" \
    '{id:9001, user:{login:"solouser"}, body:"@greptileai",
      created_at:$ts, updated_at:$ts}'
}

# Helper: build a Greptile inline diff comment with a formal P0 severity badge.
# Uses the <img alt="P0"> format Greptile actually emits (issue #729).
greptile_p0_inline() {
  jq -cn --arg sha "$HEAD_SHA" \
    '{id:2001, user:{login:"greptile-apps[bot]"},
      body:"<img alt=\"P0\" src=\"badge.svg\" /> Critical issue found.",
      created_at:"'"$FRESH_TS"'",
      commit_id:$sha, original_commit_id:$sha}'
}

OUT=""
RC=0
run_gate() {
  # $1 = commit timestamp, $2 = issue comments, $3 = inline comments,
  # $4 = review threads, $5 = check-runs payload (last three optional).
  local commit_ts="$1" issue_comments="$2" pr_comments="${3:-[]}"
  local threads="${4:-}" checks="${5:-}"
  if [[ -z "$threads" ]]; then
    threads=$(jq -cn '{data:{repository:{pullRequest:{reviewThreads:{nodes:[]}}}}}')
  fi
  if [[ -z "$checks" ]]; then
    checks=$(jq -cn '{check_runs:[{id:1,name:"ci",status:"completed",conclusion:"success",
      completed_at:"2026-07-23T13:01:00Z",check_suite:{id:1},app:{slug:"gha",id:1}}]}')
  fi
  OUT=$(PATH="$BIN:$PATH" \
        FAKE_COMMIT_TS="$commit_ts" \
        FAKE_ISSUE_COMMENTS="$issue_comments" \
        FAKE_PR_COMMENTS="$pr_comments" \
        FAKE_REVIEWS="[]" \
        FAKE_THREADS="$threads" \
        FAKE_CHECK_RUNS="$checks" \
        "$SUT" 1 --reviewer greptile 2>/dev/null)
  RC=$?
}

# Helpers for common assertions.
met()           { echo "$OUT" | jq -r '.met'; }
missing_count() { echo "$OUT" | jq -r '.missing | length'; }
missing_has()   { echo "$OUT" | jq -e --arg s "$1" '[.missing[]? | select(contains($s))] | length > 0' >/dev/null && echo yes || echo no; }

# --------------------------------------------------------------------------
# Test 1: Clean 👍 pass — primary fix for issue #723.
# Greptile posted a fresh issue comment with 👍 and no inline findings.
# merge-gate.sh must report met:true.
# --------------------------------------------------------------------------
echo "--- Test 1: clean 👍 pass ---"
COMMENT1="$(greptile_comment "$FRESH_TS" 1)"
run_gate "$PUSH_TS" "[$COMMENT1]" "[]"

check_eq "true"  "$(met)"           "clean pass: met == true"
check_eq "0"     "$(missing_count)" "clean pass: missing array empty"
check_eq "0"     "$RC"              "clean pass: exit code 0"

# --------------------------------------------------------------------------
# Test 2: P0-badged inline findings — gate must remain unmet.
# Greptile issue comment (👍) exists but P0 inline diff comments are present.
# --------------------------------------------------------------------------
echo "--- Test 2: P0 findings present ---"
COMMENT2="$(greptile_comment "$FRESH_TS" 1)"
INLINE_P0="$(greptile_p0_inline)"
run_gate "$PUSH_TS" "[$COMMENT2]" "[$INLINE_P0]"

check_eq "false" "$(met)"   "P0 findings: met == false"
check_eq "yes"   "$(missing_has "P0")" "P0 findings: missing contains P0 message"
check_eq "1"     "$RC"      "P0 findings: exit code 1"

# --------------------------------------------------------------------------
# Test 3: Stale zero-P0 review after a durable trigger is reusable.
# This is the primary regression for issue #1000.
# --------------------------------------------------------------------------
echo "--- Test 3: stale zero-P0 review round is reusable ---"
COMMENT3="$(greptile_comment "$STALE_TS" 1)"
TRIGGER3="$(greptile_trigger "2026-07-23T12:50:00Z")"
run_gate "$PUSH_TS" "[$TRIGGER3,$COMMENT3]" "[]"

check_eq "true"  "$(met)"           "stale zero-P0: met == true"
check_eq "0"     "$(missing_count)" "stale zero-P0: missing array empty"
check_eq "0"     "$RC"              "stale zero-P0: exit code 0"

# --------------------------------------------------------------------------
# Test 4: No Greptile review history remains a hard rejection.
# --------------------------------------------------------------------------
echo "--- Test 4: no review history ---"
run_gate "$PUSH_TS" "[]" "[]"

check_eq "false" "$(met)"  "no review: met == false"
check_eq "1"     "$RC"     "no review: exit code 1"
check_eq "yes" "$(missing_has "no Greptile review")" \
  "no review: missing says 'no Greptile review yet'"

# --------------------------------------------------------------------------
# Test 5: Prose "no P0" must NOT count as a P0 badge (regression for #729).
# A Greptile issue comment whose body contains the words "no P0" but no
# <img alt="P0"> badge must yield P0_COUNT=0 — the severity gate passes.
# Before the fix, grep -oE '\bP0\b' would match "P0" in "no P0" and wrongly
# inflate P0_COUNT, flipping the gate to "P0 present" on a P1/P2-only review.
# --------------------------------------------------------------------------
echo "--- Test 5: prose 'no P0' must not count as badge ---"
# A fresh Greptile issue comment with thumbsup=0 and prose "no P0".
# thumbsup=0 → G_COMMENT_CLEAN=false → Path B; P0 prose in G_BODY must not count.
COMMENT5="$(jq -cn \
  '{id:4001, user:{login:"greptile-apps[bot]"},
    body:"P1: minor nit — there are no P0 issues, this is purely a style concern.",
    created_at:"'"$FRESH_TS"'",
    reactions:{url:"",total_count:0,"+1":0,"-1":0}}')"
run_gate "$PUSH_TS" "[$COMMENT5]" "[]"

check_eq "true" "$(met)"           "prose no-P0: met == true (P0_COUNT=0)"
check_eq "0"    "$(missing_count)" "prose no-P0: no missing entries"
check_eq "0"    "$RC"              "prose no-P0: exit code 0"

# --------------------------------------------------------------------------
# Test 6: Formal <img alt="P0"> badge must be detected and fail the gate.
# An inline comment whose body contains <img alt="P0"> must yield P0_COUNT>=1,
# so the severity gate blocks merge until a clean re-review (regression for #729).
# --------------------------------------------------------------------------
echo "--- Test 6: formal P0 badge is detected ---"
P0_BADGE="$(jq -cn --arg sha "$HEAD_SHA" \
  '{id:5001, user:{login:"greptile-apps[bot]"},
    body:"<img alt=\"P0\" src=\"badge.svg\" /> Critical: null pointer dereference in handler.",
    created_at:"'"$FRESH_TS"'",
    commit_id:$sha, original_commit_id:$sha}')"
run_gate "$PUSH_TS" "[]" "[$P0_BADGE]"

check_eq "false" "$(met)"              "P0 badge: met == false"
check_eq "yes"   "$(missing_has "P0")" "P0 badge: missing contains P0 message"
check_eq "1"     "$RC"                 "P0 badge: exit code 1"

# --------------------------------------------------------------------------
# Test 7: In-place re-review — created_at pre-push, updated_at post-push.
# Greptile edits its summary comment in-place on re-review (observed on PR #734).
# The original created_at pre-dates the force-push; updated_at is post-push.
# merge-gate.sh must treat updated_at as sufficient freshness and report met:true.
# This is the primary regression test for issue #748.
# --------------------------------------------------------------------------
echo "--- Test 7: in-place re-review — created_at pre-push, updated_at post-push ---"
COMMENT7="$(greptile_comment "$STALE_TS" 1 "$FRESH_TS")"
run_gate "$PUSH_TS" "[$COMMENT7]" "[]"

check_eq "true"  "$(met)"           "in-place re-review: met == true"
check_eq "0"     "$(missing_count)" "in-place re-review: missing array empty"
check_eq "0"     "$RC"              "in-place re-review: exit code 0"

# --------------------------------------------------------------------------
# Test 8: Legacy stale zero-P0 history without a retained trigger is reusable.
# When the trigger marker is unavailable, the gate conservatively scans all
# Greptile history for P0 and may reuse it only when none exists.
# --------------------------------------------------------------------------
echo "--- Test 8: legacy stale zero-P0 history without trigger ---"
COMMENT8="$(greptile_comment "$STALE_TS" 1 "$STALE_TS")"
run_gate "$PUSH_TS" "[$COMMENT8]" "[]"

check_eq "true" "$(met)" "legacy stale zero-P0: met == true"
check_eq "0" "$RC" "legacy stale zero-P0: exit code 0"
check_eq "0" "$(missing_count)" "legacy stale zero-P0: missing array empty"

# --------------------------------------------------------------------------
# Test 9: P0 inline posted BEFORE in-place summary edit must still be caught.
# Reproduces the BugBot finding from PR #751: G_INLINE_BODIES was anchored to
# G_ANCHOR_TS (summary updated_at), which could be LATER than the inline's
# created_at, silently excluding the P0 from badge scanning.
#
# Timeline:
#   PUSH_TS (13:00) < FRESH_TS (13:05, inline created) < LATE_FRESH_TS (13:10, summary updated_at)
#
# G_INLINE_COUNT must count the inline (created_at > PUSH_TS ✓).
# G_INLINE_BODIES must include the inline (created_at > PUSH_TS ✓) — not gate
# on G_ANCHOR_TS=LATE_FRESH_TS, which would exclude it.
# P0_COUNT must be 1 → gate remains unmet.
# --------------------------------------------------------------------------
echo "--- Test 9: P0 inline created before in-place summary edit ---"
COMMENT9="$(greptile_comment "$STALE_TS" 0 "$LATE_FRESH_TS")"
INLINE_P0_EARLY="$(jq -cn --arg sha "$HEAD_SHA" \
  '{id:6001, user:{login:"greptile-apps[bot]"},
    body:"<img alt=\"P0\" src=\"badge.svg\" /> Critical: use-after-free in destructor.",
    created_at:"'"$FRESH_TS"'",
    commit_id:$sha, original_commit_id:$sha}')"
run_gate "$PUSH_TS" "[$COMMENT9]" "[$INLINE_P0_EARLY]"

check_eq "false" "$(met)"              "P0 inline pre-summary-edit: met == false"
check_eq "yes"   "$(missing_has "P0")" "P0 inline pre-summary-edit: missing contains P0 message"
check_eq "1"     "$RC"                 "P0 inline pre-summary-edit: exit code 1"

# --------------------------------------------------------------------------
# Test 10: A stale P0 in the latest completed round requires a fresh clean
# re-review even after its thread was fixed and resolved.
# --------------------------------------------------------------------------
echo "--- Test 10: stale P0 round requires re-review ---"
TRIGGER10="$(greptile_trigger "2026-07-23T12:50:00Z")"
COMMENT10="$(greptile_comment "$STALE_TS" 0)"
P0_STALE10="$(jq -cn --arg sha "$HEAD_SHA" \
  '{id:10001, user:{login:"greptile-apps[bot]"},
    body:"<img alt=\"P0\" src=\"badge.svg\" /> Critical prior finding.",
    created_at:"2026-07-23T12:57:00Z", commit_id:$sha, original_commit_id:$sha}')"
run_gate "$PUSH_TS" "[$TRIGGER10,$COMMENT10]" "[$P0_STALE10]"

check_eq "false" "$(met)" "stale P0: met == false"
check_eq "yes" "$(missing_has "prior Greptile review had P0")" \
  "stale P0: fresh clean re-review required"
check_eq "1" "$RC" "stale P0: exit code 1"

# --------------------------------------------------------------------------
# Test 11: An unanswered latest trigger cannot reuse an older clean round.
# --------------------------------------------------------------------------
echo "--- Test 11: latest trigger unanswered ---"
OLD_TRIGGER11="$(greptile_trigger "2026-07-23T12:45:00Z")"
OLD_COMMENT11="$(greptile_comment "2026-07-23T12:50:00Z" 1)"
NEW_TRIGGER11="$(jq -cn \
  '{id:9002, user:{login:"solouser"}, body:"@greptileai",
    created_at:"2026-07-23T12:58:00Z", updated_at:"2026-07-23T12:58:00Z"}')"
run_gate "$PUSH_TS" "[$OLD_TRIGGER11,$OLD_COMMENT11,$NEW_TRIGGER11]" "[]"

check_eq "false" "$(met)" "unanswered trigger: met == false"
check_eq "yes" "$(missing_has "no Greptile review")" \
  "unanswered trigger: older clean evidence is not reused"
check_eq "1" "$RC" "unanswered trigger: exit code 1"

# --------------------------------------------------------------------------
# Test 12: A later clean completed round supersedes an older P0 round.
# --------------------------------------------------------------------------
echo "--- Test 12: later clean round supersedes older P0 ---"
OLD_TRIGGER12="$(greptile_trigger "2026-07-23T12:30:00Z")"
OLD_P0_12="$(jq -cn --arg sha "$HEAD_SHA" \
  '{id:12001, user:{login:"greptile-apps[bot]"},
    body:"<img alt=\"P0\" src=\"badge.svg\" /> Old fixed finding.",
    created_at:"2026-07-23T12:35:00Z", commit_id:$sha, original_commit_id:$sha}')"
NEW_TRIGGER12="$(jq -cn \
  '{id:9003, user:{login:"solouser"}, body:"@greptileai",
    created_at:"2026-07-23T12:45:00Z", updated_at:"2026-07-23T12:45:00Z"}')"
NEW_COMMENT12="$(greptile_comment "$STALE_TS" 1)"
run_gate "$PUSH_TS" "[$OLD_TRIGGER12,$NEW_TRIGGER12,$NEW_COMMENT12]" "[$OLD_P0_12]"

check_eq "true" "$(met)" "later clean round: met == true"
check_eq "0" "$RC" "later clean round: exit code 0"

# --------------------------------------------------------------------------
# Test 13: Current-head unresolved threads remain a universal blocker.
# --------------------------------------------------------------------------
echo "--- Test 13: stale reuse does not bypass unresolved threads ---"
THREADS13="$(jq -cn \
  '{data:{repository:{pullRequest:{reviewThreads:{nodes:[
    {isResolved:false, comments:{nodes:[{author:{login:"greptile-apps[bot]"}}]}}
  ]}}}}}')"
run_gate "$PUSH_TS" "[$TRIGGER3,$COMMENT3]" "[]" "$THREADS13"

check_eq "false" "$(met)" "unresolved thread: met == false"
check_eq "yes" "$(missing_has "unresolved review thread")" \
  "unresolved thread: universal gate remains mandatory"
check_eq "1" "$RC" "unresolved thread: exit code 1"

# --------------------------------------------------------------------------
# Test 14: Current-head CI failures remain a universal blocker.
# --------------------------------------------------------------------------
echo "--- Test 14: stale reuse does not bypass failing CI ---"
CHECKS14="$(jq -cn \
  '{check_runs:[{id:14,name:"ci",status:"completed",conclusion:"failure",
    completed_at:"2026-07-23T13:01:00Z",check_suite:{id:14},app:{slug:"gha",id:1}}]}')"
run_gate "$PUSH_TS" "[$TRIGGER3,$COMMENT3]" "[]" \
  '{"data":{"repository":{"pullRequest":{"reviewThreads":{"nodes":[]}}}}}' "$CHECKS14"

check_eq "false" "$(met)" "failing CI: met == false"
check_eq "yes" "$(missing_has "CI has 1 failing")" \
  "failing CI: universal gate remains mandatory"
check_eq "1" "$RC" "failing CI: exit code 1"

echo "----------------------------------------"
echo "merge-gate-greptile-comment.test.sh: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
