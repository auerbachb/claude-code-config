#!/usr/bin/env bash
# merge-gate-thread-pagination.test.sh — Regression tests for issue #1634:
# merge-gate.sh must paginate the reviewThreads GraphQL query.
# catalog: tests — Tests that `merge-gate.sh` paginates `reviewThreads` (#1634) — an unresolved thread on page 2 blocks the gate, the cursor walk is observable, and the Greptile-scoped count sees the accumulated list, with end-to-end and filter-level negative controls proving the un-paginated view passes
#
# `reviewThreads(first: 100)` with no cursor silently truncates at the 100th
# thread, and the universal unresolved-thread gate (Step 1c) is PERMISSIVE when
# truncated: an unresolved thread on page two is invisible, so the gate reads
# clean on a PR that is not merge-ready.
#
# Tests:
#   1. Two-page fixture, the only unresolved thread on page 2 → gate blocked,
#      unresolved_thread_count == 1, exit code 1.
#   2. Sibling control: identical two-page fixture with page 2 fully resolved →
#      no unresolved-thread entry, count 0. Proves test 1's entry is thread-
#      driven, not an artifact of the fixture's other gaps.
#   3. Negative control (end-to-end): the SAME page-1 payload served as the only
#      page — exactly what the un-paginated query saw from the same server state
#      — passes the unresolved-thread gate. Proves test 1 is not vacuous.
#   4. Negative control (filter-level): page-1 JSON through merge-gate.sh's own
#      `select(.isResolved == false)` filter yields 0 unresolved threads.
#   5. The fetch actually walks the cursor: page 1 is requested with a GraphQL
#      null cursor, page 2 with the endCursor page 1 returned.
#   6. Greptile-scoped consumer: a greptile-authored unresolved thread on page 2
#      selects the "threads include P0" message, not the "threads are resolved"
#      one — so that consumer reads the accumulated list too.
#   7. Fail-closed guards: hasNextPage with no endCursor, a 200-OK body whose
#      nodes are missing, and runaway pagination each exit 4 rather than
#      silently truncating the thread list.
#
# Only `gh` is stubbed; merge-gate.sh, ci-status.sh, check-runs-dedup.sh and
# review-substance.sh are the real scripts run in place.
#
# Run from repo root: bash .claude/scripts/tests/merge-gate-thread-pagination.test.sh
set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
# Overridable so this suite can be pointed at another checkout's merge-gate.sh
# (issue #1485); the guard stops a mistyped path from reading as a real result.
SUT="${SUT:-$REPO_ROOT/.claude/scripts/merge-gate.sh}"
[[ -f "$SUT" && -x "$SUT" ]] || { echo "FAIL: SUT is not an executable file: $SUT" >&2; exit 1; }

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
PR_AUTHOR_LOGIN="solouser"
PUSH_TS="2026-07-23T13:00:00Z"
FRESH_TS="2026-07-23T13:05:00Z"
# The opaque cursor page 1 hands back; page 2 is only served when the fetch
# actually sends it back as `after`.
PAGE2_CURSOR="Y3Vyc29yOnYyOpHOAAGyNQ=="
# Where the stub records every graphql invocation, so the cursor walk is
# observable from the test rather than merely inferred from the verdict.
GRAPHQL_LOG="$TMP/graphql-calls.log"
: > "$GRAPHQL_LOG"

# --- Fixture builders (run in the test, not the stub, so the same JSON can be
# --- fed to both the SUT and the filter-level negative control). --------------

# 100 resolved threads — a full first page.
page1_nodes() {
  jq -cn '[range(0; 100) as $i
    | {isResolved: true,
       comments: {nodes: [{databaseId: (10000 + $i), author: {login: "coderabbitai[bot]"}}]}}]'
}

# Page 2: two resolved threads plus one whose resolution and author vary.
# $1 = isResolved for the third thread, $2 = its comment author login.
page2_nodes() { # resolved_bool author_login
  jq -cn --argjson res "$1" --arg author "$2" \
    '[range(0; 2) as $i
      | {isResolved: true,
         comments: {nodes: [{databaseId: (20000 + $i), author: {login: "coderabbitai[bot]"}}]}}]
     + [{isResolved: $res,
         comments: {nodes: [{databaseId: 29999, author: {login: $author}}]}}]'
}

# Wrap a node array in the GraphQL response shape merge-gate.sh reads.
threads_page() { # nodes_json has_next_bool end_cursor
  jq -cn --argjson nodes "$1" --argjson next "$2" --arg cur "$3" \
    '{data: {repository: {pullRequest: {reviewThreads:
      {pageInfo: {hasNextPage: $next, endCursor: (if $cur == "" then null else $cur end)},
       nodes: $nodes}}}}}'
}

PAGE1_NODES="$(page1_nodes)"
PAGE1_FULL="$(threads_page "$PAGE1_NODES" true "$PAGE2_CURSOR")"
# Same first page, but declaring itself the last one — the payload shape the
# un-paginated query received from identical server state.
PAGE1_ONLY="$(threads_page "$PAGE1_NODES" false "")"
PAGE2_UNRESOLVED="$(threads_page "$(page2_nodes false 'coderabbitai[bot]')" false "")"
PAGE2_RESOLVED="$(threads_page "$(page2_nodes true 'coderabbitai[bot]')" false "")"
PAGE2_UNRESOLVED_G="$(threads_page "$(page2_nodes false 'greptile-apps[bot]')" false "")"

# --- Fake gh: stubs the endpoints merge-gate.sh calls. ----------------------
BIN="$TMP/bin"; mkdir -p "$BIN"
cat > "$BIN/gh" <<'GHEOF'
#!/usr/bin/env bash
ARGS="$*"
case "$ARGS" in
  "repo view --json nameWithOwner --jq .nameWithOwner")
    echo "solo/repo"; exit 0 ;;
  "api user --jq .login")
    # Authorship guard (issue #733): viewer login matches the PR author below,
    # so authorship == "mine" and the merge is not blocked on that axis.
    echo "$PR_AUTHOR_LOGIN"; exit 0 ;;
  *"pr view "*headRefOid*)
    jq -cn \
      --arg sha "$HEAD_SHA" \
      --arg author "$PR_AUTHOR_LOGIN" \
      '{number:1, state:"OPEN", headRefOid:$sha, baseRefName:"main",
        mergeStateStatus:"CLEAN", mergeable:"MERGEABLE", reviewDecision:"APPROVED",
        author:{login:$author, type:"User"}}'
    exit 0 ;;
  *"git/commits/"*)
    jq -cn --arg d "$PUSH_TS" '{committer:{date:$d}}'
    exit 0 ;;
  *check-runs*)
    jq -cn '{check_runs:[{id:1,name:"ci",status:"completed",conclusion:"success",
      completed_at:"2026-07-23T13:01:00Z",check_suite:{id:1},app:{slug:"gha",id:1}}]}'
    exit 0 ;;
  *pulls/*/reviews*)
    printf '%s' "${FAKE_REVIEWS:-[]}"; exit 0 ;;
  *pulls/*/comments*)
    printf '%s' "${FAKE_PR_COMMENTS:-[]}"; exit 0 ;;
  *issues/*/comments*)
    printf '%s' "${FAKE_ISSUE_COMMENTS:-[]}"; exit 0 ;;
  *graphql*)
    # Cursor-aware: record the call, then serve page 1 until the caller sends
    # page 1's endCursor back as `after`. A caller that never paginates keeps
    # getting page 1 — exactly the pre-#1634 view of the same server state.
    # One line per call, holding only the `after` cursor: the query itself is
    # multi-line, so logging $ARGS whole would break the per-call count.
    echo "cursor=${ARGS##*cursor=}" >> "$GRAPHQL_LOG"
    if [[ "${FAKE_ALWAYS_NEXT:-0}" == "1" ]]; then
      # Never-ending pagination: every page claims another one follows. Drives
      # the runaway page-cap guard.
      jq -cn '{data:{repository:{pullRequest:{reviewThreads:
        {pageInfo:{hasNextPage:true, endCursor:"SPIN"}, nodes:[]}}}}}'
    elif [[ "$ARGS" == *"cursor=$PAGE2_CURSOR"* ]]; then
      printf '%s' "$FAKE_THREADS_PAGE2"
    else
      printf '%s' "$FAKE_THREADS_PAGE1"
    fi
    exit 0 ;;
  *"/branches/"*"/protection/required_status_checks"*)
    echo "gh: Not Found (HTTP 404)" >&2; exit 1 ;;
  *"/branches/"*)
    jq -cn '{name:"main", protected:false,
      protection:{required_status_checks:{contexts:[]}}}'
    exit 0 ;;
  *contents/*)
    echo "Not Found" >&2; exit 1 ;;
esac
echo "unexpected gh call: $ARGS" >&2
exit 1
GHEOF
chmod +x "$BIN/gh"

export HEAD_SHA PUSH_TS PR_AUTHOR_LOGIN PAGE2_CURSOR GRAPHQL_LOG

OUT=""
RC=0
run_gate() { # page1_payload page2_payload [reviewer] [issue_comments] [pr_comments]
  local page1="$1" page2="$2" reviewer="${3:-cr}"
  local issue_comments="${4:-[]}" pr_comments="${5:-[]}"
  : > "$GRAPHQL_LOG"
  OUT=$(PATH="$BIN:$PATH" \
        FAKE_THREADS_PAGE1="$page1" \
        FAKE_THREADS_PAGE2="$page2" \
        FAKE_ISSUE_COMMENTS="$issue_comments" \
        FAKE_PR_COMMENTS="$pr_comments" \
        "$SUT" 1 --reviewer "$reviewer" 2>/dev/null)
  RC=$?
}

met()             { echo "$OUT" | jq -r '.met'; }
unresolved()      { echo "$OUT" | jq -r '.unresolved_thread_count'; }
missing_has()     { echo "$OUT" | jq -e --arg s "$1" '[.missing[]? | select(contains($s))] | length > 0' >/dev/null && echo yes || echo no; }

# --------------------------------------------------------------------------
# Test 1: unresolved thread on page 2 blocks the gate.
# --------------------------------------------------------------------------
echo "--- Test 1: unresolved thread on page 2 blocks the gate ---"
run_gate "$PAGE1_FULL" "$PAGE2_UNRESOLVED"

check_eq "false" "$(met)"         "page-2 unresolved: met == false"
check_eq "1"     "$(unresolved)"  "page-2 unresolved: unresolved_thread_count == 1"
check_eq "yes"   "$(missing_has '1 unresolved review thread(s)')" \
  "page-2 unresolved: missing names the unresolved thread"
check_eq "1"     "$RC"            "page-2 unresolved: exit code 1"

# --------------------------------------------------------------------------
# Test 2: sibling control — same two pages, page 2 fully resolved.
# The unresolved-thread entry must disappear, proving it tracks the threads
# rather than the fixture's other gaps.
# --------------------------------------------------------------------------
echo "--- Test 2: page 2 fully resolved clears the thread gate ---"
run_gate "$PAGE1_FULL" "$PAGE2_RESOLVED"

check_eq "0"   "$(unresolved)" "page-2 resolved: unresolved_thread_count == 0"
check_eq "no"  "$(missing_has 'unresolved review thread')" \
  "page-2 resolved: no unresolved-thread entry in missing"

# --------------------------------------------------------------------------
# Test 3: NEGATIVE CONTROL (end-to-end). Serve the identical page-1 payload as
# the only page — the view the un-paginated `reviewThreads(first: 100)` query
# had of the same 103 threads. The unresolved-thread gate passes, so test 1's
# blocking verdict depends entirely on page-2 accumulation.
# --------------------------------------------------------------------------
echo "--- Test 3: negative control — page 1 alone passes the thread gate ---"
run_gate "$PAGE1_ONLY" "$PAGE2_UNRESOLVED"

check_eq "0"  "$(unresolved)" "negative control: unresolved_thread_count == 0"
check_eq "no" "$(missing_has 'unresolved review thread')" \
  "negative control: no unresolved-thread entry in missing"

# --------------------------------------------------------------------------
# Test 4: NEGATIVE CONTROL (filter level). merge-gate.sh's own unresolved
# filter, run against page 1 alone, counts zero.
# --------------------------------------------------------------------------
echo "--- Test 4: negative control — page-1 nodes through the gate's filter ---"
PAGE1_UNRESOLVED_COUNT=$(printf '%s' "$PAGE1_ONLY" | jq -r '
  [.data.repository.pullRequest.reviewThreads.nodes[]?
    | select(.isResolved == false)]
  | length')
check_eq "0" "$PAGE1_UNRESOLVED_COUNT" "negative control: page-1 filter counts 0 unresolved"

# The fixture is only meaningful if page 2 really does carry one.
PAGE2_UNRESOLVED_COUNT=$(printf '%s' "$PAGE2_UNRESOLVED" | jq -r '
  [.data.repository.pullRequest.reviewThreads.nodes[]?
    | select(.isResolved == false)]
  | length')
check_eq "1" "$PAGE2_UNRESOLVED_COUNT" "fixture sanity: page-2 filter counts 1 unresolved"
check_eq "100" "$(printf '%s' "$PAGE1_NODES" | jq -r 'length')" \
  "fixture sanity: page 1 fills the 100-thread bound"

# --------------------------------------------------------------------------
# Test 5: the cursor walk itself — page 1 requested with a GraphQL null cursor,
# page 2 with page 1's endCursor, and no further pages after hasNextPage:false.
# --------------------------------------------------------------------------
echo "--- Test 5: cursor walk ---"
run_gate "$PAGE1_FULL" "$PAGE2_UNRESOLVED"
CALLS=$(wc -l < "$GRAPHQL_LOG" | tr -d ' ')
check_eq "2" "$CALLS" "cursor walk: exactly two graphql requests"
FIRST_CALL=$(sed -n 1p "$GRAPHQL_LOG")
SECOND_CALL=$(sed -n 2p "$GRAPHQL_LOG")
case "$FIRST_CALL" in
  *"cursor=null"*) ok "cursor walk: first page requested with a null cursor" ;;
  *) bad "cursor walk: first page cursor (got: $FIRST_CALL)" ;;
esac
case "$SECOND_CALL" in
  *"cursor=$PAGE2_CURSOR"*) ok "cursor walk: second page requested with page 1's endCursor" ;;
  *) bad "cursor walk: second page cursor (got: $SECOND_CALL)" ;;
esac

# --------------------------------------------------------------------------
# Test 6: the Greptile-scoped consumer reads the accumulated list too.
# Greptile round with a P0 inline finding: the severity branch reports
# "threads include P0" only when it can SEE the unresolved greptile thread —
# which lives on page 2. Un-paginated, it would report the resolved-threads
# variant instead.
# --------------------------------------------------------------------------
echo "--- Test 6: Greptile-scoped unresolved count sees page 2 ---"
G_SUMMARY=$(jq -cn --arg ts "$FRESH_TS" \
  '{id:5001, user:{login:"greptile-apps[bot]"},
    body:"<h3>Greptile Summary</h3>\nFindings below.",
    created_at:$ts, updated_at:$ts,
    reactions:{url:"",total_count:1,"+1":1,"-1":0}}')
G_P0_INLINE=$(jq -cn --arg ts "$FRESH_TS" --arg sha "$HEAD_SHA" \
  '{id:5002, user:{login:"greptile-apps[bot]"},
    body:"<img alt=\"P0\" src=\"badge.svg\" /> Critical issue found.",
    created_at:$ts, commit_id:$sha, original_commit_id:$sha}')

run_gate "$PAGE1_FULL" "$PAGE2_UNRESOLVED_G" greptile "[$G_SUMMARY]" "[$G_P0_INLINE]"
check_eq "yes" "$(missing_has 'Greptile threads include P0 finding(s)')" \
  "greptile: unresolved greptile thread on page 2 selects the P0-threads message"
check_eq "no" "$(missing_has 'latest Greptile review had P0 findings')" \
  "greptile: the resolved-threads variant is not selected"

# Same Greptile fixture, page 1 alone (the un-paginated view): the scoped count
# is 0, so the OTHER message is selected — the control for test 6.
run_gate "$PAGE1_ONLY" "$PAGE2_UNRESOLVED_G" greptile "[$G_SUMMARY]" "[$G_P0_INLINE]"
check_eq "no" "$(missing_has 'Greptile threads include P0 finding(s)')" \
  "greptile control: page 1 alone cannot see the greptile thread"
check_eq "yes" "$(missing_has 'latest Greptile review had P0 findings')" \
  "greptile control: page 1 alone selects the resolved-threads variant"

# --------------------------------------------------------------------------
# Test 7: fail-closed guards. Every malformed pagination shape must exit 4 with
# a "gh api failed" reason rather than silently truncating the thread list — a
# permissive fallback here is the same bug in a different costume.
# --------------------------------------------------------------------------
echo "--- Test 7: fail-closed guards ---"

# 7a. hasNextPage:true with no endCursor — the walk cannot continue.
BROKEN_CURSOR="$(threads_page "$PAGE1_NODES" true "")"
run_gate "$BROKEN_CURSOR" "$PAGE2_UNRESOLVED"
check_eq "4"   "$RC" "no endCursor: exit code 4"
check_eq "yes" "$(missing_has 'hasNextPage without endCursor')" \
  "no endCursor: missing names the pagination failure"

# 7b. A 200-OK body whose nodes are missing entirely (a partial GraphQL result)
# must not fold in as zero threads.
NODES_MISSING="$(jq -cn '{data:{repository:{pullRequest:{reviewThreads:
  {pageInfo:{hasNextPage:false, endCursor:null}}}}}}')"
run_gate "$NODES_MISSING" "$PAGE2_UNRESOLVED"
check_eq "4"   "$RC" "missing nodes: exit code 4"
check_eq "yes" "$(missing_has 'GraphQL-reviewThreads page parse')" \
  "missing nodes: missing names the parse failure"

# 7d. A present-but-non-boolean hasNextPage is fatal — a string "false" must
# never quietly end the walk. Absence stays legitimate (test 3's single-page
# fixture and every other merge-gate stub in this repo omit pageInfo entirely),
# so only a wrong-typed VALUE fails.
BAD_HAS_NEXT="$(jq -cn --argjson nodes "$PAGE1_NODES" \
  '{data:{repository:{pullRequest:{reviewThreads:
    {pageInfo:{hasNextPage:"false", endCursor:null}, nodes:$nodes}}}}}')"
run_gate "$BAD_HAS_NEXT" "$PAGE2_UNRESOLVED"
check_eq "4"   "$RC" "non-boolean hasNextPage: exit code 4"
check_eq "yes" "$(missing_has 'GraphQL-reviewThreads pageInfo parse')" \
  "non-boolean hasNextPage: missing names the pageInfo failure"

# Absent pageInfo remains a valid single-page response (no die_api) — the
# control that keeps 7d from over-tightening the shape check.
NO_PAGEINFO="$(jq -cn --argjson nodes "$PAGE1_NODES" \
  '{data:{repository:{pullRequest:{reviewThreads:{nodes:$nodes}}}}}')"
run_gate "$NO_PAGEINFO" "$PAGE2_UNRESOLVED"
check_eq "1" "$RC" "absent pageInfo: still a normal single-page verdict (exit 1)"
check_eq "0" "$(unresolved)" "absent pageInfo: page 1 accumulated, 0 unresolved"

# 7c. Runaway pagination stops at the page cap instead of spinning forever.
echo "--- Test 7c: runaway pagination (walks to the 200-page cap) ---"
: > "$GRAPHQL_LOG"
OUT=$(PATH="$BIN:$PATH" FAKE_ALWAYS_NEXT=1 \
      FAKE_THREADS_PAGE1="$PAGE1_FULL" FAKE_THREADS_PAGE2="$PAGE2_UNRESOLVED" \
      FAKE_ISSUE_COMMENTS="[]" FAKE_PR_COMMENTS="[]" \
      "$SUT" 1 --reviewer cr 2>/dev/null)
RC=$?
check_eq "4"   "$RC" "runaway pagination: exit code 4"
check_eq "yes" "$(missing_has 'exceeded 200 pages')" \
  "runaway pagination: missing names the page cap"
check_eq "200" "$(wc -l < "$GRAPHQL_LOG" | tr -d ' ')" \
  "runaway pagination: stopped after exactly 200 requests"

echo
echo "Passed: $PASS  Failed: $FAIL"
[[ $FAIL -eq 0 ]]
