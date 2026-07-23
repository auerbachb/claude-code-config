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

# --- Fake gh: stubs the endpoints merge-gate.sh calls. ----------------------
BIN="$TMP/bin"; mkdir -p "$BIN"
cat > "$BIN/gh" <<'GHEOF'
#!/usr/bin/env bash
ARGS="$*"
case "$ARGS" in
  "repo view --json nameWithOwner --jq .nameWithOwner")
    echo "solo/repo"; exit 0 ;;
  *"pr view "*headRefOid*)
    jq -cn \
      --arg sha  "$HEAD_SHA" \
      '{number:1, state:"OPEN", headRefOid:$sha, baseRefName:"main",
        mergeStateStatus:"CLEAN", mergeable:"MERGEABLE", reviewDecision:"APPROVED"}'
    exit 0 ;;
  *"git/commits/"*)
    # Return FAKE_COMMIT_TS as the committer date — used for Greptile freshness.
    jq -cn --arg d "$FAKE_COMMIT_TS" '{committer:{date:$d}}'
    exit 0 ;;
  *check-runs*)
    # Single passing check so CI gate is met.
    jq -cn '{check_runs:[{id:1,name:"ci",status:"completed",conclusion:"success",
               completed_at:"2026-07-23T13:01:00Z",
               check_suite:{id:1},app:{slug:"gha",id:1}}]}'
    exit 0 ;;
  *pulls/*/reviews*)
    # Greptile never posts formal reviews; return empty.
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

# Export HEAD_SHA so the heredoc-embedded gh stub can see it.
export HEAD_SHA
export PUSH_TS

# Helper: build a Greptile issue comment JSON object.
greptile_comment() { # created_at thumbsup_count
  local ts="$1" up="$2"
  jq -cn --arg ts "$ts" --argjson up "$up" \
    '{id:1001, user:{login:"greptile-apps[bot]"},
      body:"<h3>Greptile Summary</h3>\nClean review.",
      created_at:$ts,
      reactions:{url:"",total_count:$up,"+1":$up,"-1":0}}'
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
  # $1 = FAKE_COMMIT_TS, $2 = FAKE_ISSUE_COMMENTS, $3 = FAKE_PR_COMMENTS (optional)
  local commit_ts="$1" issue_comments="$2" pr_comments="${3:-[]}"
  OUT=$(PATH="$BIN:$PATH" \
        FAKE_COMMIT_TS="$commit_ts" \
        FAKE_ISSUE_COMMENTS="$issue_comments" \
        FAKE_PR_COMMENTS="$pr_comments" \
        FAKE_REVIEWS="[]" \
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
# Test 3: Stale 👍 — comment created BEFORE the last push must not count.
# Gate should report not met (no fresh Greptile review).
# --------------------------------------------------------------------------
echo "--- Test 3: stale 👍 before push ---"
COMMENT3="$(greptile_comment "$STALE_TS" 1)"
run_gate "$PUSH_TS" "[$COMMENT3]" "[]"

check_eq "false" "$(met)"  "stale comment: met == false"
check_eq "1"     "$RC"     "stale comment: exit code 1"
# The stale comment exists but zero fresh comments + no inline findings:
# missing should say "no Greptile review yet".
check_eq "yes" "$(missing_has "no Greptile review")" \
  "stale comment: missing says 'no Greptile review yet'"

# --------------------------------------------------------------------------
# Test 4: Stale inline comments only — no fresh review on the new HEAD.
# Prior push left greptile-apps[bot] inline comments (now resolved as stale).
# No fresh issue comment and no formal review exist for the new HEAD.
# Without the freshness gate on G_INLINE_COUNT the "no review yet" guard would
# not fire (G_INLINE_COUNT > 0) and Path B would pass on an empty review body.
# Gate MUST report "no Greptile review yet" — not met.
# --------------------------------------------------------------------------
echo "--- Test 4: stale inline comments only (no fresh review) ---"

# Build a stale inline comment (created before the push timestamp).
greptile_stale_inline() {
  jq -cn --arg ts "$STALE_TS" \
    '{id:3001, user:{login:"greptile-apps[bot]"},
      body:"P1 — minor nit from prior review round.",
      created_at:$ts,
      commit_id:"aabbccddeeff0011223344556677889900aabbcc",
      original_commit_id:"aabbccddeeff0011223344556677889900aabbcc"}'
}

STALE_INLINE="$(greptile_stale_inline)"
run_gate "$PUSH_TS" "[]" "[$STALE_INLINE]"

check_eq "false" "$(met)"  "stale inline only: met == false"
check_eq "1"     "$RC"     "stale inline only: exit code 1"
# G_INLINE_COUNT freshness gate must exclude the stale comment, so the "no review
# yet" guard fires and reports exactly this missing entry.
check_eq "yes" "$(missing_has "no Greptile review")" \
  "stale inline only: missing says 'no Greptile review yet'"

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

echo "----------------------------------------"
echo "merge-gate-greptile-comment.test.sh: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
