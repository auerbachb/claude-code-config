#!/usr/bin/env bash
# merge-gate-stale-approval.test.sh — Regression tests for issue #836:
# merge-gate.sh must reject approvals whose submitted_at predates the HEAD
# commit's committer date (GitHub force-push commit_id retargeting).
#
# Scenario: after a squash-rebase + force-push, GitHub retargets existing
# review commit_ids to the new HEAD SHA but does NOT update submitted_at.
# An approval submitted before the push therefore shows commit_id == HEAD
# with submitted_at < HEAD committer date — a false-positive "valid approval".
#
# Acceptance criteria covered:
#   (a) Approval submitted AFTER HEAD commit → met (normal case unchanged)
#   (b) CR approval submitted BEFORE HEAD, matching commit_id → not met,
#       missing says "predates the HEAD commit (force-push retargeting)"
#   (c) CA approval submitted BEFORE HEAD, matching commit_id → not met,
#       same missing reason
#   (d) BugBot review submitted BEFORE HEAD, matching commit_id → not met,
#       same missing reason
#   (e) Empty LAST_COMMIT_TS (API failure) → fail-closed, gate NOT met, distinct reason
#   (f) Equal timestamps (submitted_at == committer date) → accepted (met)
#
# Only `gh` is stubbed; merge-gate.sh, ci-status.sh, check-runs-dedup.sh,
# and session-state.sh are the real scripts.
#
# Run from repo root: bash .claude/scripts/tests/merge-gate-stale-approval.test.sh
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

HEAD_SHA="aabbccddeeff0011223344556677889900aabbcc"
# Committer date for the HEAD commit (i.e., when the force-push landed).
COMMIT_TS="2026-07-30T19:30:00Z"
# Approval submitted AFTER the push — normal, valid.
FRESH_TS="2026-07-30T19:35:00Z"
# Approval submitted BEFORE the push — stale via retargeting.
STALE_TS="2026-07-30T19:21:54Z"
# Approval submitted at exactly the same second as the commit — boundary, accepted.
EQUAL_TS="$COMMIT_TS"

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
    jq -cn \
      --arg sha  "$HEAD_SHA" \
      '{number:1, state:"OPEN", headRefOid:$sha, baseRefName:"main",
        mergeStateStatus:"CLEAN", mergeable:"MERGEABLE", reviewDecision:"APPROVED",
        author:{login:"solouser", type:"User"}}'
    exit 0 ;;
  *"git/commits/"*)
    # Return FAKE_COMMIT_TS as the HEAD committer date.
    if [ -n "${FAKE_COMMIT_TS_FAIL:-}" ]; then
      echo "gh: network error" >&2; exit 1
    fi
    jq -cn --arg d "$FAKE_COMMIT_TS" '{committer:{date:$d}}'
    exit 0 ;;
  *check-runs*)
    if [[ -n "${FAKE_CHECK_RUNS:-}" ]]; then
      printf '%s' "$FAKE_CHECK_RUNS"; exit 0
    fi
    jq -cn '{check_runs:[{id:1,name:"ci",status:"completed",conclusion:"success",
               completed_at:"2026-07-30T19:32:00Z",
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
export HEAD_SHA

# Build a CR (coderabbitai) APPROVED review with configurable submitted_at.
cr_approved() { # submitted_at
  jq -cn --arg sha "$HEAD_SHA" --arg ts "$1" \
    '[{user:{login:"coderabbitai[bot]",type:"Bot"},
       commit_id:$sha, state:"APPROVED", submitted_at:$ts}]'
}
# Build a CodeAnt (codeant-ai) APPROVED review.
ca_approved() { # submitted_at
  jq -cn --arg sha "$HEAD_SHA" --arg ts "$1" \
    '[{user:{login:"codeant-ai[bot]",type:"Bot"},
       commit_id:$sha, state:"APPROVED", submitted_at:$ts}]'
}
# Build a BugBot (cursor) review with configurable state and submitted_at.
bb_review() { # submitted_at state
  jq -cn --arg sha "$HEAD_SHA" --arg ts "$1" --arg st "$2" \
    '[{user:{login:"cursor[bot]",type:"Bot"},
       commit_id:$sha, state:$st, submitted_at:$ts}]'
}

OUT=""; RC=0
run_gate() {
  # $1 = reviewer (cr|bugbot), $2 = FAKE_COMMIT_TS, $3 = FAKE_REVIEWS
  local reviewer="$1" commit_ts="$2" reviews="$3"
  local fail_ts="${FAKE_COMMIT_TS_FAIL:-}"
  OUT=$(PATH="$BIN:$PATH" \
        FAKE_COMMIT_TS="$commit_ts" \
        FAKE_COMMIT_TS_FAIL="$fail_ts" \
        FAKE_REVIEWS="$reviews" \
        FAKE_PR_COMMENTS="[]" \
        FAKE_ISSUE_COMMENTS="[]" \
        "$SUT" 1 --reviewer "$reviewer" 2>/dev/null)
  RC=$?
}

met()           { echo "$OUT" | jq -r '.met'; }
missing_count() { echo "$OUT" | jq -r '.missing | length'; }
missing_has()   { echo "$OUT" | jq -e --arg s "$1" \
                    '[.missing[]? | select(contains($s))] | length > 0' \
                  >/dev/null && echo yes || echo no; }

RETARGET_MSG="predates the HEAD commit (force-push retargeting)"

# -------------------------------------------------------------------------
# (a) CR approval AFTER HEAD commit — normal case, must be met
# -------------------------------------------------------------------------
echo "--- (a) CR approval after HEAD commit (normal, must be met) ---"
run_gate cr "$COMMIT_TS" "$(cr_approved "$FRESH_TS")"
check_eq "true"  "$(met)"           "(a) cr fresh approval: met == true"
check_eq "0"     "$(missing_count)" "(a) cr fresh approval: no missing entries"
check_eq "0"     "$RC"              "(a) cr fresh approval: exit 0"

# -------------------------------------------------------------------------
# (b) CR approval BEFORE HEAD commit (force-push retargeting) — must NOT met
# -------------------------------------------------------------------------
echo "--- (b) CR approval before HEAD (stale retargeting) ---"
run_gate cr "$COMMIT_TS" "$(cr_approved "$STALE_TS")"
check_eq "false" "$(met)"   "(b) cr stale approval: met == false"
check_eq "yes"   "$(missing_has "$RETARGET_MSG")" \
                             "(b) cr stale approval: missing has retarget reason"
check_eq "1"     "$RC"      "(b) cr stale approval: exit 1"

# -------------------------------------------------------------------------
# (c) CA approval BEFORE HEAD commit — must NOT met
# -------------------------------------------------------------------------
echo "--- (c) CA approval before HEAD (stale retargeting) ---"
run_gate cr "$COMMIT_TS" "$(ca_approved "$STALE_TS")"
check_eq "false" "$(met)"   "(c) ca stale approval: met == false"
check_eq "yes"   "$(missing_has "$RETARGET_MSG")" \
                             "(c) ca stale approval: missing has retarget reason"
check_eq "1"     "$RC"      "(c) ca stale approval: exit 1"

# -------------------------------------------------------------------------
# (d) BugBot review BEFORE HEAD commit — must NOT met
# -------------------------------------------------------------------------
echo "--- (d) BugBot review before HEAD (stale retargeting) ---"
run_gate bugbot "$COMMIT_TS" "$(bb_review "$STALE_TS" "APPROVED")"
check_eq "false" "$(met)"   "(d) bugbot stale: met == false"
check_eq "yes"   "$(missing_has "$RETARGET_MSG")" \
                             "(d) bugbot stale: missing has retarget reason"
check_eq "1"     "$RC"      "(d) bugbot stale: exit 1"

# -------------------------------------------------------------------------
# (e) Empty LAST_COMMIT_TS (API failure) — fail-closed: gate NOT met,
#     distinct "cannot verify freshness" reason (not the retargeting message)
# -------------------------------------------------------------------------
FRESHNESS_MSG="cannot verify approval freshness"
echo "--- (e) LAST_COMMIT_TS empty (fail-closed) ---"
FAKE_COMMIT_TS_FAIL=1
run_gate cr "" "$(cr_approved "$STALE_TS")"
unset FAKE_COMMIT_TS_FAIL
check_eq "false" "$(met)"   "(e) fail-closed when ts empty: met == false"
check_eq "yes"   "$(missing_has "$FRESHNESS_MSG")" \
                             "(e) fail-closed: missing has freshness reason"
check_eq "no"    "$(missing_has "$RETARGET_MSG")" \
                             "(e) fail-closed: no retarget message (distinct from stale)"
check_eq "1"     "$RC"      "(e) fail-closed: exit 1"

# -------------------------------------------------------------------------
# (f) submitted_at EQUAL to committer date — boundary, must be accepted (met)
# -------------------------------------------------------------------------
echo "--- (f) submitted_at == committer date (boundary, must be accepted) ---"
run_gate cr "$COMMIT_TS" "$(cr_approved "$EQUAL_TS")"
check_eq "true"  "$(met)"           "(f) equal ts: met == true"
check_eq "0"     "$(missing_count)" "(f) equal ts: no missing entries"
check_eq "0"     "$RC"              "(f) equal ts: exit 0"

# -------------------------------------------------------------------------
# (g) BugBot review AFTER HEAD commit — normal case, must be met
# -------------------------------------------------------------------------
echo "--- (g) BugBot review after HEAD commit (normal, must be met) ---"
run_gate bugbot "$COMMIT_TS" "$(bb_review "$FRESH_TS" "APPROVED")"
check_eq "true"  "$(met)"   "(g) bugbot fresh: met == true"
check_eq "no"    "$(missing_has "$RETARGET_MSG")" \
                             "(g) bugbot fresh: no retarget message"
check_eq "0"     "$RC"      "(g) bugbot fresh: exit 0"

# -------------------------------------------------------------------------
# (h) CR has a fresh APPROVED + CA has approval with empty submitted_at.
#     PRIMARY_REVIEW_MET=true (CR satisfies it), so the primary block is
#     skipped. The supplemental CodeAnt gate must still block because
#     CA_APPROVAL_SUBMITTED_AT_MISSING=true — the approval's timestamp is
#     absent and freshness cannot be verified (fail-closed, issue #836).
# -------------------------------------------------------------------------
echo "--- (h) CR fresh + CA approval missing submitted_at (supplemental freshness) ---"
CA_SUBMITTED_AT_MSG="cannot verify CodeAnt approval freshness"
BOTH_REVIEWS=$(jq -cn --arg sha "$HEAD_SHA" --arg cr_ts "$FRESH_TS" \
  '[{user:{login:"coderabbitai[bot]",type:"Bot"},
     commit_id:$sha, state:"APPROVED", submitted_at:$cr_ts},
    {user:{login:"codeant-ai[bot]",type:"Bot"},
     commit_id:$sha, state:"APPROVED", submitted_at:""}]')
run_gate cr "$COMMIT_TS" "$BOTH_REVIEWS"
check_eq "false" "$(met)"   "(h) cr fresh + ca no-ts: met == false"
check_eq "yes"   "$(missing_has "$CA_SUBMITTED_AT_MSG")" \
                             "(h) cr fresh + ca no-ts: missing has CA freshness reason"
check_eq "1"     "$RC"      "(h) cr fresh + ca no-ts: exit 1"

# -------------------------------------------------------------------------
# (i) Stale CodeAnt check-run (completed_at < COMMIT_TS) — must NOT met.
#     The message must say "predates the HEAD commit" (stale), not "no
#     successful CodeAnt check-run" (absent). CODEANT_PARTICIPATED is true
#     because the CodeAnt check-run is present in check-runs.
# -------------------------------------------------------------------------
echo "--- (i) stale CodeAnt check-run (force-push retargeting) ---"
STALE_CA_CHECK=$(jq -cn \
  --arg ca_ts "$STALE_TS" \
  '{check_runs:[
      {id:1,name:"ci",status:"completed",conclusion:"success",
       completed_at:"2026-07-30T19:32:00Z",check_suite:{id:1},app:{slug:"gha",id:1}},
      {id:2,name:"CodeAnt AI",status:"completed",conclusion:"success",
       completed_at:$ca_ts,check_suite:{id:2},app:{slug:"codeant",id:2}}
    ]}')
STALE_CHECK_MSG="predates the HEAD commit (force-push retargeting)"
OUT=$(PATH="$BIN:$PATH" \
      FAKE_COMMIT_TS="$COMMIT_TS" \
      FAKE_COMMIT_TS_FAIL="" \
      FAKE_REVIEWS="[]" \
      FAKE_PR_COMMENTS="[]" \
      FAKE_ISSUE_COMMENTS="[]" \
      FAKE_CHECK_RUNS="$STALE_CA_CHECK" \
      "$SUT" 1 --reviewer cr 2>/dev/null)
RC=$?
check_eq "false" "$(met)"                             "(i) stale ca check: met == false"
check_eq "yes"   "$(missing_has "$STALE_CHECK_MSG")"  "(i) stale ca check: missing has retarget reason"
check_eq "1"     "$RC"                                "(i) stale ca check: exit 1"

# -------------------------------------------------------------------------
# Summary
# -------------------------------------------------------------------------
echo "----------------------------------------"
echo "merge-gate-stale-approval.test.sh: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
