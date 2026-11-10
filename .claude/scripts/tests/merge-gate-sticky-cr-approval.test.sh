#!/usr/bin/env bash
# merge-gate-sticky-cr-approval.test.sh — Regression tests for issue #865:
# a fresh CR-path APPROVED on the current HEAD SHA satisfies the merge gate
# even when reviewer == bugbot (sticky). The sticky pointer is NOT changed.
# catalog: tests — Tests that a fresh CR-path approval on current HEAD satisfies the gate even when the sticky reviewer is BugBot
#
# All freshness (#836), retraction (#893), and substance (#875/#876) guards
# apply on the bypass path — same code paths as the cr) branch, not a copy.
#
# Acceptance criteria:
#   (A) --reviewer bugbot + fresh CA APPROVED on HEAD → met=true, no BugBot complaint
#   (B) --reviewer bugbot + fresh CR APPROVED on HEAD → met=true, no BugBot complaint
#   (C) --reviewer bugbot + CA APPROVED on wrong commit_id → bypass absent, met=false
#   (D) --reviewer bugbot + CA APPROVED stale (submitted_at < HEAD commit) → met=false
#   (E) --reviewer bugbot + CA APPROVED retracted by fresh CHANGES_REQUESTED → met=false
#
# Only `gh` is stubbed; merge-gate.sh, ci-status.sh, check-runs-dedup.sh,
# review-substance.sh, and session-state.sh are the real scripts.
#
# Run from repo root: bash .claude/scripts/tests/merge-gate-sticky-cr-approval.test.sh
set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
# Overridable so this suite can be pointed at another checkout's merge-gate.sh
# (issue #1485); the guard stops a mistyped path from reading as a real result.
SUT="${SUT:-$REPO_ROOT/.claude/scripts/merge-gate.sh}"
[[ -f "$SUT" && -x "$SUT" ]] || { echo "FAIL: SUT is not an executable file: $SUT" >&2; exit 1; }

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
OTHER_SHA="1122334455667788990011223344556677889900"
COMMIT_TS="2026-07-30T19:30:00Z"
FRESH_TS="2026-07-30T19:35:00Z"
STALE_TS="2026-07-30T19:21:00Z"
RETRACT_TS="2026-07-30T19:40:00Z"   # after FRESH_TS and COMMIT_TS — fresh retraction

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
    jq -cn --arg d "$FAKE_COMMIT_TS" '{committer:{date:$d}}'
    exit 0 ;;
  *check-runs*)
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
  *"/branches/"*"/protection/required_status_checks"*)
    # Branch-protection required contexts (issue #1361). Default is a 404, which
    # combined with the unprotected branch object below resolves to "no required
    # status checks" — so every pre-#1361 expectation in this file is unchanged.
    # FAKE_REQUIRED_STATUS_CHECKS supplies the endpoint payload;
    # FAKE_BRANCH_PROTECTED=true marks the base branch protected.
    if [[ -n "${FAKE_REQUIRED_STATUS_CHECKS:-}" ]]; then
      printf '%s' "${FAKE_REQUIRED_STATUS_CHECKS}"; exit 0
    fi
    echo "gh: Not Found (HTTP 404)" >&2; exit 1 ;;
  *"/branches/"*)
    if [[ -n "${FAKE_BRANCH_JSON:-}" ]]; then
      printf '%s' "${FAKE_BRANCH_JSON}"; exit 0
    fi
    jq -cn --arg p "${FAKE_BRANCH_PROTECTED:-false}" \
      '{name:"main", protected:($p == "true"),
        protection:{required_status_checks:{contexts:[]}}}'
    exit 0 ;;
  *contents/*)
    echo "Not Found" >&2; exit 1 ;;
esac
echo "unexpected gh call: $ARGS" >&2; exit 1
GHEOF
chmod +x "$BIN/gh"
export HEAD_SHA

# Substantive body (issue #875): a real review leaves a footprint so that
# review-substance.sh returns counts_as_coverage=true. Same body used by
# the stale-approval test suite to confirm substance-check co-operation.
APPROVAL_BODY="Actionable comments posted: 0. Reviewed the changed files; no issues found."

# Build a CodeAnt (codeant-ai[bot]) APPROVED review on HEAD with given submitted_at.
ca_approved() { # submitted_at
  jq -cn --arg sha "$HEAD_SHA" --arg ts "$1" --arg b "$APPROVAL_BODY" \
    '[{user:{login:"codeant-ai[bot]",type:"Bot"},
       commit_id:$sha, state:"APPROVED", body:$b, submitted_at:$ts}]'
}

# Build a CodeRabbit (coderabbitai[bot]) APPROVED review on HEAD.
cr_approved() { # submitted_at
  jq -cn --arg sha "$HEAD_SHA" --arg ts "$1" --arg b "$APPROVAL_BODY" \
    '[{user:{login:"coderabbitai[bot]",type:"Bot"},
       commit_id:$sha, state:"APPROVED", body:$b, submitted_at:$ts}]'
}

# Build a CodeAnt APPROVED on the wrong SHA (not HEAD_SHA).
ca_wrong_sha() { # submitted_at
  jq -cn --arg sha "$OTHER_SHA" --arg ts "$1" --arg b "$APPROVAL_BODY" \
    '[{user:{login:"codeant-ai[bot]",type:"Bot"},
       commit_id:$sha, state:"APPROVED", body:$b, submitted_at:$ts}]'
}

# Build CA APPROVED + CA CHANGES_REQUESTED on the same HEAD SHA (retraction).
ca_retracted() { # approved_ts retract_ts
  jq -cn --arg sha "$HEAD_SHA" --arg ats "$1" --arg rts "$2" --arg b "$APPROVAL_BODY" \
    '[{user:{login:"codeant-ai[bot]",type:"Bot"},
       commit_id:$sha, state:"APPROVED", body:$b, submitted_at:$ats},
      {user:{login:"codeant-ai[bot]",type:"Bot"},
       commit_id:$sha, state:"CHANGES_REQUESTED", body:"", submitted_at:$rts}]'
}

OUT=""; RC=0
run_gate() {
  # $1=reviewer (bugbot), $2=FAKE_COMMIT_TS, $3=FAKE_REVIEWS
  OUT=$(PATH="$BIN:$PATH" \
        FAKE_COMMIT_TS="$2" \
        FAKE_REVIEWS="$3" \
        FAKE_PR_COMMENTS="[]" \
        FAKE_ISSUE_COMMENTS="[]" \
        "$SUT" 1 --reviewer "$1" 2>/dev/null)
  RC=$?
}

met()           { echo "$OUT" | jq -r '.met'; }
missing_count() { echo "$OUT" | jq -r '.missing | length'; }
missing_has()   { echo "$OUT" | jq -e --arg s "$1" \
                    '[.missing[]? | select(contains($s))] | length > 0' \
                  >/dev/null && echo yes || echo no; }

NO_BUGBOT_MSG="no BugBot review on HEAD"

# -------------------------------------------------------------------------
# (A) Sticky bugbot + fresh CA APPROVED on HEAD → bypass fires, gate met
# -------------------------------------------------------------------------
echo "--- (A) sticky bugbot + fresh CA APPROVED (bypass fires) ---"
run_gate bugbot "$COMMIT_TS" "$(ca_approved "$FRESH_TS")"
check_eq "true"  "$(met)"                          "(A) ca bypass: met == true"
check_eq "0"     "$(missing_count)"                "(A) ca bypass: no missing entries"
check_eq "0"     "$RC"                             "(A) ca bypass: exit 0"
check_eq "no"    "$(missing_has "$NO_BUGBOT_MSG")" "(A) ca bypass: BugBot complaint absent"

# -------------------------------------------------------------------------
# (B) Sticky bugbot + fresh CR APPROVED on HEAD → bypass fires, gate met
# -------------------------------------------------------------------------
echo "--- (B) sticky bugbot + fresh CR APPROVED (bypass fires) ---"
run_gate bugbot "$COMMIT_TS" "$(cr_approved "$FRESH_TS")"
check_eq "true"  "$(met)"                          "(B) cr bypass: met == true"
check_eq "0"     "$(missing_count)"                "(B) cr bypass: no missing entries"
check_eq "0"     "$RC"                             "(B) cr bypass: exit 0"
check_eq "no"    "$(missing_has "$NO_BUGBOT_MSG")" "(B) cr bypass: BugBot complaint absent"

# -------------------------------------------------------------------------
# (C) Sticky bugbot + CA APPROVED on wrong commit_id → no bypass, gate unmet
# -------------------------------------------------------------------------
echo "--- (C) sticky bugbot + CA APPROVED on wrong SHA (no bypass) ---"
run_gate bugbot "$COMMIT_TS" "$(ca_wrong_sha "$FRESH_TS")"
check_eq "false" "$(met)"                          "(C) wrong sha: met == false"
check_eq "yes"   "$(missing_has "$NO_BUGBOT_MSG")" "(C) wrong sha: BugBot still needed"
check_eq "1"     "$RC"                             "(C) wrong sha: exit 1"

# -------------------------------------------------------------------------
# (D) Sticky bugbot + stale CA APPROVED (submitted_at < HEAD commit) → no bypass
# -------------------------------------------------------------------------
echo "--- (D) sticky bugbot + stale CA APPROVED (predates HEAD commit) ---"
run_gate bugbot "$COMMIT_TS" "$(ca_approved "$STALE_TS")"
check_eq "false" "$(met)"                          "(D) stale ca: met == false"
check_eq "yes"   "$(missing_has "$NO_BUGBOT_MSG")" "(D) stale ca: BugBot still needed"
check_eq "1"     "$RC"                             "(D) stale ca: exit 1"

# -------------------------------------------------------------------------
# (E) Sticky bugbot + CA APPROVED retracted by fresh CHANGES_REQUESTED → no bypass
# -------------------------------------------------------------------------
echo "--- (E) sticky bugbot + CA APPROVED retracted (newer CHANGES_REQUESTED) ---"
run_gate bugbot "$COMMIT_TS" "$(ca_retracted "$FRESH_TS" "$RETRACT_TS")"
check_eq "false" "$(met)"                          "(E) retracted: met == false"
check_eq "yes"   "$(missing_has "$NO_BUGBOT_MSG")" "(E) retracted: BugBot still needed"
check_eq "1"     "$RC"                             "(E) retracted: exit 1"

# -------------------------------------------------------------------------
echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]] && exit 0 || exit 1
