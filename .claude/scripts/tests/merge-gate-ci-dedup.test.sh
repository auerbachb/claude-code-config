#!/usr/bin/env bash
# merge-gate-ci-dedup.test.sh — Offline integration tests proving merge-gate.sh
# stops blocking on superseded check-runs (issue #675).
#
# merge-gate.sh does not classify CI itself; it delegates to ci-status.sh via
# --check-runs-stdin. These tests assert the deduped verdict actually reaches the
# gate's emitted JSON and its `missing` list — and, via the negative controls, that
# a genuinely failing check still blocks.
#
# Also covers the gate's OTHER reader of the raw check-run list: the CodeAnt
# supplemental gate, which scans for a *successful* CodeAnt check-run. Undeduped,
# a stale success would satisfy it while a newer CodeAnt failure sat right beside
# it — a false clean in the merge-permitting direction.
#
# Only `gh` is stubbed; merge-gate.sh, ci-status.sh and check-runs-dedup.sh are the
# real scripts, run in place so they resolve each other as siblings.
#
# Run from repo root: bash .claude/scripts/tests/merge-gate-ci-dedup.test.sh
set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
SUT="$REPO_ROOT/.claude/scripts/merge-gate.sh"

TMP="$(mktemp -d)"
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

# Sandbox HOME: no session-state.json, so reviewer resolution stays deterministic.
export HOME="$TMP/home"; mkdir -p "$HOME/.claude"

PASS=0
FAIL=0
ok()  { echo "PASS: $1"; PASS=$((PASS + 1)); }
bad() { echo "FAIL: $1" >&2; FAIL=$((FAIL + 1)); }

check_eq() { # expected actual label
  if [[ "$1" == "$2" ]]; then ok "$3"; else bad "$3 (expected: $1, got: $2)"; fi
}

HEAD_SHA="deadbeefcafedeadbeefcafedeadbeefcafedead"

# --- Fake gh: only the endpoints merge-gate.sh actually calls. ---------------
BIN="$TMP/bin"; mkdir -p "$BIN"
cat > "$BIN/gh" <<EOF
#!/usr/bin/env bash
ARGS="\$*"
case "\$ARGS" in
  "repo view --json nameWithOwner --jq .nameWithOwner")
    echo "solo/repo"; exit 0 ;;
  "api user --jq .login")
    # Authorship guard (issue #733): viewer login; matches the PR author below
    # so authorship == "mine" and the merge is not blocked.
    echo "solouser"; exit 0 ;;
  *"pr view "*headRefOid*)
    jq -cn '{number:1, state:"OPEN", headRefOid:"$HEAD_SHA", baseRefName:"main",
             mergeStateStatus:"CLEAN", mergeable:"MERGEABLE", reviewDecision:"APPROVED",
             author:{login:"solouser", type:"User"}}'
    exit 0 ;;
  *check-runs*)
    printf '%s' "\$FAKE_CHECK_RUNS"; exit 0 ;;
  *pulls/*/reviews*)
    printf '%s' "\${FAKE_REVIEWS:-[]}"; exit 0 ;;
  *pulls/*/comments*)
    printf '%s' "\${FAKE_PR_COMMENTS:-[]}"; exit 0 ;;
  *issues/*/comments*)
    printf '%s' "\${FAKE_ISSUE_COMMENTS:-[]}"; exit 0 ;;
  *graphql*)
    jq -cn '{data:{repository:{pullRequest:{reviewThreads:{nodes:[]}}}}}'; exit 0 ;;
  *"git/commits/"*)
    # Return a HEAD committer date earlier than all check-run completed_at values
    # (which are derived from check-run id as "2026-07-21T10:00:0{id}Z"). This
    # lets the stale-approval guard (issue #836) treat every check-run as fresh
    # — the important variable for CI-dedup tests is suite ordering, not freshness.
    jq -cn '{committer:{date:"2026-07-21T09:59:00Z"}}'; exit 0 ;;
  *contents/*)
    # No CODEOWNERS file — merge-gate.sh tolerates the 404.
    echo "Not Found" >&2; exit 1 ;;
esac
echo "unexpected gh call: \$ARGS" >&2
exit 1
EOF
chmod +x "$BIN/gh"

OUT=""
RC=0
run_gate() { # $1 = check-runs JSON
  OUT=$(PATH="$BIN:$PATH" FAKE_CHECK_RUNS="$1" \
        FAKE_REVIEWS="${FAKE_REVIEWS:-[]}" \
        "$SUT" 1 --reviewer cr 2>/dev/null)
  RC=$?
}
run_gate_bugbot() { # $1 = check-runs JSON; FAKE_REVIEWS/FAKE_PR_COMMENTS/FAKE_ISSUE_COMMENTS from env
  OUT=$(PATH="$BIN:$PATH" FAKE_CHECK_RUNS="$1" \
        FAKE_REVIEWS="${FAKE_REVIEWS:-[]}" \
        FAKE_PR_COMMENTS="${FAKE_PR_COMMENTS:-[]}" \
        FAKE_ISSUE_COMMENTS="${FAKE_ISSUE_COMMENTS:-[]}" \
        "$SUT" 1 --reviewer bugbot 2>/dev/null)
  RC=$?
}

# Is there a "CI has N failing check-run(s)" entry in `missing`?
has_ci_failing_entry() { echo "$OUT" | jq -e '[.missing[]? | select(startswith("CI has") and contains("failing"))] | length > 0' >/dev/null && echo yes || echo no; }
has_ci_incomplete_entry() { echo "$OUT" | jq -e '[.missing[]? | select(startswith("CI has") and contains("incomplete"))] | length > 0' >/dev/null && echo yes || echo no; }
has_codeant_no_clean_entry() { echo "$OUT" | jq -e '[.missing[]? | select(contains("no successful CodeAnt check-run"))] | length > 0' >/dev/null && echo yes || echo no; }
# BugBot-specific missing-entry helpers.
has_bugbot_no_review_entry() { echo "$OUT" | jq -e '[.missing[]? | select(startswith("no BugBot review on HEAD"))] | length > 0' >/dev/null && echo yes || echo no; }
has_bugbot_findings_entry() { echo "$OUT" | jq -e '[.missing[]? | select(startswith("latest BugBot review on HEAD has findings"))] | length > 0' >/dev/null && echo yes || echo no; }
has_bugbot_ts_unavail_entry() { echo "$OUT" | jq -e '[.missing[]? | select(contains("completed_at/started_at unavailable"))] | length > 0' >/dev/null && echo yes || echo no; }
# Publisher-scoping block on the silent-pass check-run (issue #962).
has_bugbot_app_mismatch_entry() { echo "$OUT" | jq -e '[.missing[]? | select(contains("was not published by the Cursor app"))] | length > 0' >/dev/null && echo yes || echo no; }

# `completed_at` matters here in a way it does not for ci-status.sh: the CodeAnt
# supplemental gate reads it to find CodeAnt's latest clean signal, and a run
# without one reads as "no successful check". Ids ascend with suite recency in
# these fixtures, so deriving the timestamp from the id keeps them ordered.
cr() { # id name conclusion suite_id [app_slug] [status]
  jq -cn --argjson id "$1" --arg name "$2" --arg concl "$3" --argjson suite "$4" \
         --arg slug "${5:-gha}" --arg status "${6:-completed}" \
    '{id:$id, name:$name, status:$status,
      conclusion:(if $concl == "null" then null else $concl end),
      completed_at:(if $status == "completed" then "2026-07-21T10:00:0\($id)Z" else null end),
      check_suite:{id:$suite}, app:{slug:$slug, id:1}}'
}
bundle() { printf '{"check_runs":[%s]}' "$(IFS=,; echo "$*")"; }

# --------------------------------------------------------------------------
# 1. The reported bug: superseded failure must not block the gate.
# --------------------------------------------------------------------------
run_gate "$(bundle "$(cr 1 test failure 100)" "$(cr 2 test success 200)")"
check_eq 0 "$(echo "$OUT" | jq -r '.ci_status.failing')" "superseded failure: ci_status.failing == 0"
check_eq 1 "$(echo "$OUT" | jq -r '.ci_status.total')" "superseded failure: only the newest suite's run counted"
check_eq "no" "$(has_ci_failing_entry)" "superseded failure: no 'CI has N failing check-run(s)' entry in missing"

# --------------------------------------------------------------------------
# 2. Negative control — a genuinely failing newest run must still block.
#    Without this, test 1 could pass simply because the gate never emits the entry.
# --------------------------------------------------------------------------
run_gate "$(bundle "$(cr 1 test success 100)" "$(cr 2 test failure 200)")"
check_eq 1 "$(echo "$OUT" | jq -r '.ci_status.failing')" "live failure: ci_status.failing == 1"
check_eq "yes" "$(has_ci_failing_entry)" "live failure: 'CI has N failing check-run(s)' entry present"
check_eq "false" "$(echo "$OUT" | jq -r '.met')" "live failure: gate not met"

# --------------------------------------------------------------------------
# 3. Newest run of a check still running, older run failed -> incomplete, not failing.
# --------------------------------------------------------------------------
run_gate "$(bundle "$(cr 1 test failure 100)" "$(cr 2 test null 200 gha in_progress)")"
check_eq 0 "$(echo "$OUT" | jq -r '.ci_status.failing')" "newest in progress: failing == 0"
check_eq "no" "$(has_ci_failing_entry)" "newest in progress: no failing entry"
check_eq "yes" "$(has_ci_incomplete_entry)" "newest in progress: reported as incomplete instead"

# --------------------------------------------------------------------------
# 4. Matrix legs — a failing leg in the newest suite still blocks.
# --------------------------------------------------------------------------
run_gate "$(bundle "$(cr 1 test failure 100)" "$(cr 2 test success 200)" "$(cr 3 test failure 200)")"
check_eq 1 "$(echo "$OUT" | jq -r '.ci_status.failing')" "matrix legs: failing leg still counted"
check_eq "yes" "$(has_ci_failing_entry)" "matrix legs: failing entry present (not masked by its sibling)"

# --------------------------------------------------------------------------
# 5. CodeAnt supplemental gate reads the same deduped view.
#    Stale CodeAnt success + newer CodeAnt failure on one SHA: the superseded
#    success must NOT count as CodeAnt's clean signal.
# --------------------------------------------------------------------------
run_gate "$(bundle "$(cr 1 "CodeAnt AI" success 100 codeant-ai)" "$(cr 2 "CodeAnt AI" failure 200 codeant-ai)")"
check_eq "yes" "$(has_codeant_no_clean_entry)" \
  "CodeAnt: a superseded successful check-run no longer satisfies the CodeAnt gate"

# Negative control — when the newest CodeAnt run IS successful, the gate is satisfied.
run_gate "$(bundle "$(cr 1 "CodeAnt AI" failure 100 codeant-ai)" "$(cr 2 "CodeAnt AI" success 200 codeant-ai)")"
check_eq "no" "$(has_codeant_no_clean_entry)" \
  "CodeAnt: a current successful check-run still satisfies the CodeAnt gate"
check_eq 0 "$(echo "$OUT" | jq -r '.ci_status.failing')" \
  "CodeAnt: the superseded CodeAnt failure does not block CI either"

# --------------------------------------------------------------------------
# 6. Zero check-runs still reads as incomplete, never as clean.
# --------------------------------------------------------------------------
run_gate '{"check_runs":[]}'
check_eq 0 "$(echo "$OUT" | jq -r '.ci_status.total')" "empty check-run list: total 0"
check_eq "yes" "$(has_ci_incomplete_entry)" "empty check-run list: still reported incomplete"
check_eq "false" "$(echo "$OUT" | jq -r '.met')" "empty check-run list: gate not met"

# --------------------------------------------------------------------------
# 7. BugBot silent-pass (issue #844): completed/success check-run published by
#    the Cursor app, no review object, no cursor[bot] comments → gate met
#    (met:true).
#    NOTE: this test FAILS against pre-fix code because the old bugbot) case
#    only accepted review objects, so "no BugBot review on HEAD" was always
#    added when no review object existed, leaving the gate permanently blocked.
#    The explicit `cursor` slug (issue #962) is what a genuine BugBot run
#    carries; it is the parity pin for the publisher scoping — this scenario must
#    keep reading met:true exactly as it did before that change.
# --------------------------------------------------------------------------
FAKE_REVIEWS='[]'
FAKE_PR_COMMENTS='[]'
FAKE_ISSUE_COMMENTS='[]'
run_gate_bugbot "$(bundle "$(cr 1 "Cursor Bugbot" success 100 cursor)")"
check_eq "true" "$(echo "$OUT" | jq -r '.met')"  "BugBot silent-pass: gate met with success check-run (issue #844)"
check_eq "no"   "$(has_bugbot_no_review_entry)"  "BugBot silent-pass: no 'no BugBot review' in missing"

# --------------------------------------------------------------------------
# 8. Negative: success check-run + failure-phrase issue comment → gate NOT met.
#    BugBot spend-limit failure can produce a success check-run AND a comment
#    containing a failure phrase; the failure-phrase scan must block the gate.
# --------------------------------------------------------------------------
FAKE_REVIEWS='[]'
FAKE_PR_COMMENTS='[]'
FAKE_ISSUE_COMMENTS="$(jq -cn '[{user:{login:"cursor[bot]"},body:"I could not run this review — usage limit reached"}]')"
run_gate_bugbot "$(bundle "$(cr 1 "Cursor Bugbot" success 100 cursor)")"
check_eq "false" "$(echo "$OUT" | jq -r '.met')" "BugBot failure comment: gate blocked despite success check-run"
check_eq "yes"   "$(has_bugbot_no_review_entry)" "BugBot failure comment: 'no BugBot review' entry in missing"

# --------------------------------------------------------------------------
# 9. Negative: neutral check-run + inline cursor[bot] PR comment → gate NOT met.
#    conclusion:neutral means BugBot posted findings; the success-check path is
#    not taken (only conclusion:success qualifies), so there is still no valid
#    review signal and "no BugBot review on HEAD" is added to missing.
# --------------------------------------------------------------------------
FAKE_REVIEWS='[]'
FAKE_PR_COMMENTS="$(jq -cn --arg sha "$HEAD_SHA" \
  '[{user:{login:"cursor[bot]"},body:"Found an issue on line 42",commit_id:$sha,original_commit_id:$sha}]')"
FAKE_ISSUE_COMMENTS='[]'
run_gate_bugbot "$(bundle "$(cr 1 "Cursor Bugbot" neutral 100)")"
check_eq "false" "$(echo "$OUT" | jq -r '.met')" "BugBot neutral check-run: gate blocked (conclusion:neutral does not satisfy)"
check_eq "yes"   "$(has_bugbot_no_review_entry)" "BugBot neutral check-run: 'no BugBot review' entry in missing"

# --------------------------------------------------------------------------
# 10. Negative: CHANGES_REQUESTED cursor[bot] review object on HEAD → NOT met.
#     When a review object exists, the review-object path applies; a
#     CHANGES_REQUESTED state adds the findings entry to missing.
# --------------------------------------------------------------------------
FAKE_REVIEWS="$(jq -cn --arg sha "$HEAD_SHA" \
  '[{user:{login:"cursor[bot]"},state:"CHANGES_REQUESTED",commit_id:$sha,submitted_at:"2026-07-21T10:01:00Z"}]')"
FAKE_PR_COMMENTS='[]'
FAKE_ISSUE_COMMENTS='[]'
run_gate_bugbot "$(bundle "$(cr 1 "Cursor Bugbot" neutral 100)")"
check_eq "false" "$(echo "$OUT" | jq -r '.met')" "BugBot CHANGES_REQUESTED: gate blocked"
check_eq "yes"   "$(has_bugbot_findings_entry)"  "BugBot CHANGES_REQUESTED: findings entry in missing"

# --------------------------------------------------------------------------
# (m) Stale failure-phrase comment (pre-HEAD created_at) must NOT block.
#     The freshness filter on BB_HAS_FAILURE_COMMENT only counts comments
#     posted AFTER the HEAD commit. HEAD committer date is 2026-07-21T09:59:00Z
#     (set by the fake gh git/commits endpoint); a comment with created_at
#     2026-07-21T09:00:00Z is stale and must be ignored.
# --------------------------------------------------------------------------
FAKE_REVIEWS='[]'
FAKE_PR_COMMENTS='[]'
FAKE_ISSUE_COMMENTS="$(jq -cn '[{user:{login:"cursor[bot]"},body:"I could not run this review — usage limit reached",created_at:"2026-07-21T09:00:00Z"}]')"
run_gate_bugbot "$(bundle "$(cr 1 "Cursor Bugbot" success 100 cursor)")"
check_eq "true" "$(echo "$OUT" | jq -r '.met')"           "BugBot stale failure comment: gate met (comment predates HEAD commit)"
check_eq "no"   "$(has_bugbot_no_review_entry)"            "BugBot stale failure comment: no 'no BugBot review' entry"

# --------------------------------------------------------------------------
# (n) Success check-run with empty completed_at/started_at must fail-closed.
#     When LAST_COMMIT_TS is known but neither timestamp field is set,
#     freshness cannot be verified — gate must block (mirrors CodeAnt gate).
# --------------------------------------------------------------------------
BB_NO_TS_RUN="$(jq -cn '{id:1, name:"Cursor Bugbot", status:"completed",
  conclusion:"success", completed_at:null, started_at:null,
  check_suite:{id:100}, app:{slug:"cursor",id:1}}')"
FAKE_REVIEWS='[]'
FAKE_PR_COMMENTS='[]'
FAKE_ISSUE_COMMENTS='[]'
run_gate_bugbot "$(bundle "$BB_NO_TS_RUN")"
check_eq "false" "$(echo "$OUT" | jq -r '.met')"          "BugBot empty check timestamp: gate blocked (cannot verify freshness)"
check_eq "yes"   "$(has_bugbot_ts_unavail_entry)"          "BugBot empty check timestamp: 'completed_at/started_at unavailable' in missing"

# --------------------------------------------------------------------------
# (o) Foreign-app same-name success run must NOT satisfy the silent pass
#     (issue #962). Any GitHub App may publish a check-run under any name, so
#     `Cursor Bugbot` names a check, not a publisher. Everything else here is
#     byte-identical to scenario 7 — the ONLY difference is the app slug — so
#     this pair isolates the publisher requirement from every other condition.
#     Fails closed: unlike escalate-review.sh's routing fallback (issue #956),
#     an unverifiable publisher here would satisfy the merge gate outright.
# --------------------------------------------------------------------------
FAKE_REVIEWS='[]'
FAKE_PR_COMMENTS='[]'
FAKE_ISSUE_COMMENTS='[]'
run_gate_bugbot "$(bundle "$(cr 1 "Cursor Bugbot" success 100 not-cursor)")"
check_eq "false" "$(echo "$OUT" | jq -r '.met')"            "BugBot foreign-app check-run: gate blocked (publisher is not the Cursor app)"
check_eq "yes"   "$(has_bugbot_app_mismatch_entry)"         "BugBot foreign-app check-run: publisher entry in missing"
check_eq "no"    "$(has_bugbot_no_review_entry)"            "BugBot foreign-app check-run: publisher reason replaces the generic 'no BugBot review' entry"

# --------------------------------------------------------------------------
# (p) Same-name success run with NO app identity at all must also fail closed
#     (issue #962). An absent/empty `app` block is unattributable, which is not
#     the same as trusted — the slug compare treats missing exactly like foreign.
#     Timestamps are valid here so freshness cannot be what blocks it; the
#     publisher check is deliberately evaluated ahead of the freshness checks.
# --------------------------------------------------------------------------
BB_NO_APP_RUN="$(jq -cn '{id:1, name:"Cursor Bugbot", status:"completed",
  conclusion:"success", completed_at:"2026-07-21T10:00:01Z",
  started_at:"2026-07-21T10:00:01Z", check_suite:{id:100}}')"
FAKE_REVIEWS='[]'
FAKE_PR_COMMENTS='[]'
FAKE_ISSUE_COMMENTS='[]'
run_gate_bugbot "$(bundle "$BB_NO_APP_RUN")"
check_eq "false" "$(echo "$OUT" | jq -r '.met')"            "BugBot missing-app check-run: gate blocked (publisher unverifiable)"
check_eq "yes"   "$(has_bugbot_app_mismatch_entry)"         "BugBot missing-app check-run: publisher entry in missing"
check_eq "no"    "$(has_bugbot_ts_unavail_entry)"           "BugBot missing-app check-run: blocked on publisher, not freshness"

# --------------------------------------------------------------------------
# (q) The review-object path (bugbot.md shape 1) is untouched by issue #962.
#     A clean cursor[bot] review object on HEAD satisfies the gate even with a
#     foreign-app same-name check-run sitting beside it — shape 1 keys on
#     `.user.login == "cursor[bot]"`, which is already an identity match, and
#     the check-run block is not evaluated at all once a review object exists.
#     Same payload, same verdict as before the publisher scoping.
# --------------------------------------------------------------------------
FAKE_REVIEWS="$(jq -cn --arg sha "$HEAD_SHA" \
  '[{user:{login:"cursor[bot]"},state:"APPROVED",commit_id:$sha,submitted_at:"2026-07-21T10:01:00Z"}]')"
FAKE_PR_COMMENTS='[]'
FAKE_ISSUE_COMMENTS='[]'
run_gate_bugbot "$(bundle "$(cr 1 "Cursor Bugbot" success 100 not-cursor)")"
check_eq "true" "$(echo "$OUT" | jq -r '.met')"             "BugBot review object: gate met via shape 1 despite a foreign-app check-run"
check_eq "no"   "$(has_bugbot_app_mismatch_entry)"          "BugBot review object: publisher entry not added (check-run path not evaluated)"
check_eq "no"   "$(has_bugbot_findings_entry)"              "BugBot review object: clean APPROVED adds no findings entry"

# Reset BugBot-specific env vars so they don't bleed into a re-run.
unset FAKE_REVIEWS FAKE_PR_COMMENTS FAKE_ISSUE_COMMENTS

echo "----------------------------------------"
echo "merge-gate-ci-dedup.test.sh: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
