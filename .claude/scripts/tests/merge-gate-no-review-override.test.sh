#!/usr/bin/env bash
# merge-gate-no-review-override.test.sh — Offline tests for the merge gate's
# no-reviewer override (issue #1899).
# catalog: tests — Tests the no-review override in `merge-gate.sh` — window elapsed/running, hard stops, bot verdicts, pending reviewer checks, anchor failures, config, ledger rows
#
# Covers (Test Plan of Issue #1899 first):
#   - green CI, no bot review, HEAD anchor 11 min ago → met via the override,
#     and unreviewed-merge-ledger.sh writes a row for the merged PR
#   - same at 9 min → not met, with the window-running reason
#   - 11 min + a human CHANGES_REQUESTED on HEAD → blocked
#   - bot APPROVED on HEAD 3 min after the anchor → normal path, no ledger row
# Plus boundaries: bot CHANGES_REQUESTED on HEAD (never waived); a PENDING
#   reviewer check-run does not extend the window; failing build CI, an
#   unresolved thread, CONFLICTING all still block; an old committer date with
#   a recent check start is anchored to the check start; draft PR, unreadable
#   timeline and no check-run start time are ineligible; NO_REVIEW_OVERRIDE_MINUTES
#   off / invalid / custom; ci-only tier has nothing to waive.
#
# Built on tests/lib/merge-gate-test-fixtures.sh without editing it: its fake gh
# is kept as gh.base, and a wrapper answers the PR-metadata, timeline,
# pm-config, merge-confirmation and label calls, delegating everything else.
# Negative control: SUT=<origin/main checkout>/.claude/scripts/merge-gate.sh
# makes the override cases FAIL (there is no override on main).
# Run from repo root: bash .claude/scripts/tests/merge-gate-no-review-override.test.sh
# shellcheck source=tests/lib/merge-gate-test-fixtures.sh
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/merge-gate-test-fixtures.sh"
LEDGER_SUT="${LEDGER_SUT:-$REPO_ROOT/.claude/scripts/unreviewed-merge-ledger.sh}"

mv "$BIN/gh" "$BIN/gh.base"
cat > "$BIN/gh" <<'EOF'
#!/usr/bin/env bash
ARGS=" $* "
case "$ARGS" in
  *" api repos/solo/repo/pulls/1 "*)
    [[ "${FAKE_PULL_FAIL:-0}" == 1 ]] && { echo "gh: Server Error (HTTP 500)" >&2; exit 1; }
    jq -cn --arg c "${FAKE_CREATED_AT:-2026-07-21T09:58:00Z}" --argjson d "${FAKE_DRAFT:-false}" \
      '{number:1, created_at:$c, draft:$d, head:{ref:"feature", repo:{full_name:"solo/repo"}}}'
    exit 0 ;;
  *" repos/solo/repo/actions/runs?head_sha="*)
    if [[ -n "${FAKE_RUNS:-}" ]]; then printf '%s' "$FAKE_RUNS"; exit 0; fi
    jq -cn --arg t "${FAKE_PUSH_AT:-2026-07-21T09:58:00Z}" \
      '{total_count:1, workflow_runs:[{event:"pull_request", created_at:$t, head_branch:"feature",
         head_sha:"deadbeefcafedeadbeefcafedeadbeefcafedead", head_repository:{full_name:"solo/repo"}}]}'
    exit 0 ;;
  *" repos/solo/repo/issues/1/timeline"*)
    [[ "${FAKE_TIMELINE_FAIL:-0}" == 1 ]] && { echo "gh: Server Error (HTTP 502)" >&2; exit 1; }
    printf '%s' "${FAKE_TIMELINE:-[]}"; exit 0 ;;
  *" repos/solo/repo/contents/.claude/pm-config.md "*)
    [[ -z "${FAKE_PM_CONFIG:-}" ]] && { echo "gh: Not Found (HTTP 404)" >&2; exit 1; }
    jq -cn --arg c "$(printf '%s' "$FAKE_PM_CONFIG" | base64 | tr -d '\n')" \
      '{type:"file", encoding:"base64", content:$c}'
    exit 0 ;;
  *" pr view 1 --repo solo/repo --json labels,changedFiles "*)
    jq -cn --argjson files "${FAKE_PR_FILES_JSON:-[]}" '{labels: [], changedFiles: ($files | length)}'
    exit 0 ;;
  *" repos/solo/repo/pulls/1/files?per_page=100 "*)
    jq_arg() { local prev="" a; for a in "$@"; do [[ "$prev" == "--jq" ]] && { printf '%s' "$a"; return; }; prev="$a"; done; }
    jq -r "$(jq_arg "$@")" <<<"${FAKE_PR_FILES_JSON:-[]}"
    exit 0 ;;
  *" pr view 1 --repo solo/repo --json state,headRefOid,mergeCommit,mergedAt,title,url "*)
    jq -cn --arg s "${FAKE_MERGED_STATE:-MERGED}" --arg h "${FAKE_MERGED_HEAD:-deadbeefcafedeadbeefcafedeadbeefcafedead}" \
      '{state:$s, headRefOid:$h, mergeCommit:{oid:"feedface00000000000000000000000000000001"},
        mergedAt:"2026-11-06T06:00:00Z", title:"Fixture PR", url:"https://github.com/solo/repo/pull/1"}'
    exit 0 ;;
  *" label create "*) exit 0 ;;
  *" pr edit 1 --repo solo/repo --add-label merged-unreviewed "*)
    [[ "${FAKE_LABEL_FAIL:-0}" == 1 ]] && exit 1; exit 0 ;;
  *" pr view "*headRefOid*)
    if [[ -n "${FAKE_PR_OVERRIDE:-}" ]]; then printf '%s' "$FAKE_PR_OVERRIDE"; exit 0; fi ;;
  *graphql*)
    if [[ -n "${FAKE_THREADS:-}" ]]; then
      jq -cn --argjson nodes "$FAKE_THREADS" \
        '{data:{repository:{pullRequest:{reviewThreads:{pageInfo:{hasNextPage:false, endCursor:null}, nodes:$nodes}}}}}'
      exit 0
    fi ;;
esac
exec "$(dirname "$0")/gh.base" "$@"
EOF
chmod +x "$BIN/gh"

ago() { jq -rn --argjson s "$1" '(now - $s) | floor | todateiso8601'; }
# A check-run with a real started_at (the fixture's cr() has none).
run() { # id name conclusion started_secs_ago [app_slug] [status]
  jq -cn --argjson id "$1" --arg name "$2" --arg concl "$3" --arg st "$(ago "$4")" \
         --arg slug "${5:-gha}" --arg status "${6:-completed}" \
    '{id:$id, name:$name, status:$status,
      conclusion:(if $status == "completed" then $concl else null end),
      started_at:$st, completed_at:(if $status == "completed" then $st else null end),
      check_suite:{id:($id * 10)}, app:{slug:$slug, id:15368}}'
}

OUT="" RC=0
run_gate() { # $1 = check-runs bundle
  OUT=$(PATH="$BIN:$PATH" FAKE_CHECK_RUNS="$1" \
        FAKE_REVIEWS="${FAKE_REVIEWS:-[]}" FAKE_PR_COMMENTS="${FAKE_PR_COMMENTS:-[]}" \
        FAKE_ISSUE_COMMENTS="${FAKE_ISSUE_COMMENTS:-[]}" \
        "$SUT" 1 2>"$TMP/gate.err")
  RC=$?
}
j() { printf '%s' "$OUT" | jq -r "$1" 2>/dev/null; }
has_missing() { printf '%s' "$OUT" | jq -e --arg s "$1" '[.missing[]? | select(contains($s))] | length > 0' >/dev/null 2>&1 && echo yes || echo no; }
reset() { unset FAKE_REVIEWS FAKE_PR_COMMENTS FAKE_ISSUE_COMMENTS FAKE_PM_CONFIG FAKE_THREADS \
  FAKE_DRAFT FAKE_TIMELINE FAKE_TIMELINE_FAIL FAKE_PULL_FAIL FAKE_PR_OVERRIDE FAKE_PR_FILES_JSON \
  FAKE_MERGED_STATE FAKE_MERGED_HEAD FAKE_LABEL_FAIL FAKE_RUNS FAKE_PUSH_AT; }
LEDGER_FILE="$HOME/.claude/unreviewed-merges.json"
ledger_rows() { [[ -s "$LEDGER_FILE" ]] && jq '.entries | length' "$LEDGER_FILE" || echo 0; }
record() { printf '%s' "$OUT" | PATH="$BIN:$PATH" "$LEDGER_SUT" record --pr 1 --repo solo/repo --gate-json - 2>"$TMP/ledger.err"; }

GREEN_11="$(bundle "$(run 1 build success 660)")"
GREEN_9="$(bundle "$(run 1 build success 540)")"
NEED_APPROVAL="need 1 explicit CodeRabbit or CodeAnt APPROVED review"

echo "=== TP1: green CI, no bot review, HEAD 11 min ago -> met via override + ledger row ==="
reset; rm -f "$LEDGER_FILE"
run_gate "$GREEN_11"
check_eq "0"                  "$RC"                                   "TP1 exit 0"
check_eq "true"               "$(j .met)"                             "TP1 met"
check_eq "no-review-override" "$(j .path)"                            "TP1 path is no-review-override"
check_eq "true"               "$(j .no_review_override.applied)"      "TP1 override applied"
check_eq "600"                "$(j .no_review_override.window_seconds)" "TP1 default window is 10 min"
check_eq "false"              "$(j .primary_review_met)"              "TP1 primary_review_met stays false"
check_eq "yes"                "$(printf '%s' "$OUT" | jq -r '[.no_review_override.waived_reasons[] | select(contains("APPROVED review"))] | if length > 0 then "yes" else "no" end')" "TP1 the approval reason is recorded as waived"
check_eq "earliest_head_check_start" "$(j .no_review_override.anchor_source)" "TP1 anchored to the HEAD check-run start (old committer date)"
check_eq "coderabbitai[bot]"  "$(j '.no_review_override.missing_reviewers[0].reviewer')" "TP1 missing reviewers are named"
check_eq "no_head_signal"     "$(j '.no_review_override.missing_reviewers[0].reason')" "TP1 ... with a reason"
check_eq "recorded"           "$(record)"                             "TP1 ledger records the merge"
check_eq "1"                  "$(ledger_rows)"                        "TP1 ledger has one row"
check_eq "solo/repo#1@deadbee pending true" "$(jq -r '.entries[0] | "\(.repo)#\(.pr)@\(.head_sha[0:7]) \(.backfill_status) \(.label_applied)"' "$LEDGER_FILE")" "TP1 row fields"
check_eq "feedface00000000000000000000000000000001" "$(jq -r '.entries[0].merge_commit_sha' "$LEDGER_FILE")" "TP1 merge commit recorded"
check_eq "already-recorded"   "$(record)"                             "TP1 re-record is idempotent"
check_eq "1"                  "$(ledger_rows)"                        "TP1 still one row"
check_eq "1" "$(PATH="$BIN:$PATH" "$LEDGER_SUT" list --repo SOLO/Repo --pending | jq length)" "TP1 list --repo --pending finds it"
check_eq "updated" "$(PATH="$BIN:$PATH" "$LEDGER_SUT" backfill --pr 1 --repo solo/repo --sha "$HEAD_SHA" --status reviewed-clean)" "TP1 backfill status update"
check_eq "0" "$(PATH="$BIN:$PATH" "$LEDGER_SUT" list --pending | jq length)" "TP1 no longer pending after backfill"

echo "=== TP2: same at 9 min -> not met ==="
reset; rm -f "$LEDGER_FILE"
run_gate "$GREEN_9"
check_eq "1"     "$RC"                                  "TP2 exit 1"
check_eq "false" "$(j .met)"                            "TP2 not met"
check_eq "false" "$(j .no_review_override.applied)"     "TP2 not applied"
check_eq "yes"   "$(has_missing "override window not elapsed")" "TP2 window-running reason"
check_eq "yes"   "$(has_missing "$NEED_APPROVAL")"      "TP2 the normal reviewer reason still blocks"
record >/dev/null; check_eq "4" "$?" "TP2 ledger refuses an unmet gate"
check_eq "0"     "$(ledger_rows)"                       "TP2 no ledger row"

echo "=== TP3: 11 min + human CHANGES_REQUESTED on HEAD -> blocked ==="
reset
FAKE_REVIEWS="$(jq -cn --arg sha "$HEAD_SHA" --arg t "$(ago 300)" \
  '[{user:{login:"alice",type:"User"}, commit_id:$sha, state:"CHANGES_REQUESTED", body:"no", submitted_at:$t}]')"
FAKE_PR_OVERRIDE="$(jq -cn --arg h "$HEAD_SHA" '{number:1, state:"OPEN", headRefOid:$h, baseRefName:"main",
  mergeStateStatus:"BLOCKED", mergeable:"MERGEABLE", reviewDecision:"CHANGES_REQUESTED", author:{login:"solouser", type:"User"}}')"
export FAKE_PR_OVERRIDE
run_gate "$GREEN_11"
check_eq "false" "$(j .met)"                            "TP3 not met"
check_eq "yes"   "$(has_missing "human reviewer(s) requested changes")" "TP3 human block survives the override"
check_eq "no"    "$(has_missing "$NEED_APPROVAL")"      "TP3 only the reviewer-coverage reason was waived"

echo "=== TP4: bot APPROVED on HEAD at 3 min -> normal path, no ledger row ==="
reset; rm -f "$LEDGER_FILE"
FAKE_REVIEWS="$(jq -cn --arg sha "$HEAD_SHA" --arg t "$(ago 480)" \
  '[{user:{login:"coderabbitai[bot]",type:"Bot"}, commit_id:$sha, state:"APPROVED",
     body:"Actionable comments posted: 0. Reviewed 3 files; behaviour preserved.", submitted_at:$t}]')"
run_gate "$GREEN_11"
check_eq "true"  "$(j .met)"                            "TP4 met"
check_eq "cr"    "$(j .path)"                           "TP4 normal cr path"
check_eq "false" "$(j .no_review_override.applied)"     "TP4 override not applied"
check_eq "not_needed" "$(j .no_review_override.reason)" "TP4 reason: the normal path met, nothing to waive"
record >/dev/null; check_eq "4" "$?" "TP4 ledger refuses a normal-path merge"
check_eq "0"     "$(ledger_rows)"                       "TP4 no ledger row"

echo "=== bot CHANGES_REQUESTED on HEAD at 11 min -> blocked, never waived ==="
reset
FAKE_REVIEWS="$(jq -cn --arg sha "$HEAD_SHA" --arg t "$(ago 300)" \
  '[{user:{login:"codeant-ai[bot]",type:"Bot"}, commit_id:$sha, state:"CHANGES_REQUESTED", body:"Bug at line 3", submitted_at:$t}]')"
run_gate "$GREEN_11"
check_eq "false" "$(j .met)"                            "bot CR: not met"
check_eq "false" "$(j .no_review_override.applied)"     "bot CR: override not applied"

echo "=== bot inline comment on HEAD -> verdict ==="
reset
FAKE_PR_COMMENTS="$(jq -cn --arg sha "$HEAD_SHA" '[{id:9, user:{login:"cursor[bot]"}, commit_id:$sha, body:"bug"}]')"
run_gate "$GREEN_11"
check_eq "false" "$(j .no_review_override.applied)"     "inline bot comment on HEAD disables the override"

echo "=== pending reviewer check-run at 11 min -> met (does not extend the window) ==="
reset
run_gate "$(bundle "$(run 1 build success 660)" "$(run 2 CodeRabbit null 600 coderabbitai in_progress)")"
check_eq "true"  "$(j .met)"                            "pending reviewer check: met"
check_eq "CodeRabbit" "$(j '.no_review_override.excluded_reviewer_checks[0].name')" "pending reviewer check recorded as excluded"
check_eq "review_in_progress" "$(j '.no_review_override.missing_reviewers[] | select(.reviewer == "coderabbitai[bot]") | .reason')" "pending reviewer reason"

echo "=== completed reviewer check-run on HEAD -> verdict (normal path) ==="
reset
run_gate "$(bundle "$(run 1 build success 660)" "$(run 2 "Cursor Bugbot" neutral 600 cursor)")"
check_eq "false" "$(j .no_review_override.applied)"     "completed reviewer check disables the override"

echo "=== reviewer refusal (usage limit) + neutral check -> not a verdict ==="
reset
FAKE_ISSUE_COMMENTS="$(jq -cn --arg t "$(ago 500)" '[{id:5, user:{login:"cursor[bot]"}, created_at:$t, body:"Bugbot couldn'"'"'t run: usage limit reached"}]')"
run_gate "$(bundle "$(run 1 build success 660)" "$(run 2 "Cursor Bugbot" neutral 600 cursor)")"
check_eq "true"  "$(j .no_review_override.applied)"     "refused run is not a verdict"

echo "=== refusal older than the HEAD check-run never suppresses its verdict ==="
reset
FAKE_ISSUE_COMMENTS="$(jq -cn --arg t "$(ago 700)" '[{id:5, user:{login:"cursor[bot]"}, created_at:$t, body:"Bugbot couldn'"'"'t run: usage limit reached"}]')"
run_gate "$(bundle "$(run 1 build success 660)" "$(run 2 "Cursor Bugbot" neutral 600 cursor)")"
check_eq "false" "$(j .no_review_override.applied)"     "pre-push refusal does not discount a current-HEAD check verdict"

echo "=== hard stops at 11 min ==="
reset
run_gate "$(bundle "$(run 1 build failure 660)")"
check_eq "false" "$(j .met)"                            "failing build CI: not met"
check_eq "yes"   "$(has_missing "failing check-run")"   "failing build CI reason kept"
reset
run_gate "$(bundle "$(run 1 build success 660)" "$(run 2 tests null 600 gha in_progress)")"
check_eq "false" "$(j .met)"                            "incomplete build CI: not met"
reset
export FAKE_THREADS='[{"isResolved":false,"comments":{"nodes":[{"databaseId":1,"body":"x","author":{"login":"alice","__typename":"User"}}]}}]'
run_gate "$GREEN_11"
check_eq "false" "$(j .met)"                            "unresolved thread: not met"
check_eq "yes"   "$(has_missing "unresolved review thread")" "unresolved thread reason kept"
reset
FAKE_PR_OVERRIDE="$(jq -cn --arg h "$HEAD_SHA" '{number:1, state:"OPEN", headRefOid:$h, baseRefName:"main",
  mergeStateStatus:"DIRTY", mergeable:"CONFLICTING", reviewDecision:"", author:{login:"solouser", type:"User"}}')"
export FAKE_PR_OVERRIDE
run_gate "$GREEN_11"
check_eq "false" "$(j .met)"                            "CONFLICTING: not met"
check_eq "yes"   "$(has_missing "CONFLICTING")"         "CONFLICTING reason kept"

echo "=== anchor ==="
reset
FAKE_TIMELINE="$(jq -cn --arg t "$(ago 300)" '[{event:"head_ref_force_pushed", created_at:$t}]')"
export FAKE_TIMELINE
run_gate "$GREEN_11"
check_eq "false" "$(j .met)"                            "recent force-push event re-anchors the window"
check_eq "head_ref_force_pushed" "$(j .no_review_override.anchor_source)" "force-push anchor source"
reset; export FAKE_DRAFT=true
run_gate "$GREEN_11"
check_eq "draft_pr" "$(j .no_review_override.reason)"  "draft PR is ineligible"
check_eq "false" "$(j .met)"                            "draft PR: not met"
reset; export FAKE_TIMELINE_FAIL=1
run_gate "$GREEN_11"
check_eq "false" "$(j .met)"                            "unreadable timeline: not met"
check_eq "yes" "$(j '.no_review_override.reason | startswith("anchor_unavailable") | if . then "yes" else "no" end')" "unreadable timeline: anchor_unavailable"
reset
run_gate "$(bundle "$(cr 1 build success 100)")"
check_eq "false" "$(j .met)"                            "no check-run start time: not met"

echo "=== config ==="
policy() { printf '# PM Config\n\n## Review policy\n\n```ini\nNO_REVIEW_OVERRIDE_MINUTES=%s\n```\n' "$1"; }
reset; FAKE_PM_CONFIG="$(policy off)"; export FAKE_PM_CONFIG
run_gate "$GREEN_11"
check_eq "false" "$(j .met)"                            "off: not met"
check_eq "disabled" "$(j .no_review_override.reason)"  "off: disabled"
reset; FAKE_PM_CONFIG="$(policy soon)"; export FAKE_PM_CONFIG
run_gate "$GREEN_11"
check_eq "disabled" "$(j .no_review_override.reason)"  "invalid value: disabled"
reset; FAKE_PM_CONFIG="$(policy 30)"; export FAKE_PM_CONFIG
run_gate "$GREEN_11"
check_eq "1800" "$(j .no_review_override.window_seconds)" "custom 30 min window"
check_eq "false" "$(j .met)"                            "custom 30 min window not elapsed at 11 min"
reset
export FAKE_PM_CONFIG='# PM Config

## Review policy

| Tier | Gate | Paths | Labels |
|------|------|-------|--------|
| docs | ci-only | docs/** | |
'
export FAKE_PR_FILES_JSON='[{"filename":"docs/a.md"}]'
run_gate "$GREEN_11"
check_eq "true"  "$(j .met)"                            "ci-only tier: met"
check_eq "false" "$(j .no_review_override.applied)"     "ci-only tier: override not applied (nothing to waive)"

echo "=== ledger refusals ==="
reset; rm -f "$LEDGER_FILE"
run_gate "$GREEN_11"
FAKE_MERGED_STATE=OPEN; export FAKE_MERGED_STATE
record >/dev/null; check_eq "4" "$?" "ledger refuses an unmerged PR"
unset FAKE_MERGED_STATE; export FAKE_MERGED_HEAD=1111111111111111111111111111111111111111
record >/dev/null; check_eq "4" "$?" "ledger refuses a head mismatch"
unset FAKE_MERGED_HEAD; export FAKE_LABEL_FAIL=1
check_eq "recorded" "$(record)" "label failure still records"
check_eq "false" "$(jq -r '.entries[0].label_applied' "$LEDGER_FILE")" "label failure recorded as label_applied:false"

echo "=== anchor never predates the PR adopting HEAD (pull_request run) ==="
reset; export FAKE_PUSH_AT; FAKE_PUSH_AT="$(ago 300)"
run_gate "$GREEN_11"
check_eq "false" "$(j .no_review_override.applied)" "checks older than the push do not start the window"
check_eq "pr_head_adoption" "$(j .no_review_override.anchor_source)" "anchored to the PR adopting HEAD"
unset FAKE_PUSH_AT
reset; export FAKE_RUNS='{"total_count":1,"workflow_runs":[{"event":"push","created_at":"2026-07-21T09:58:00Z","head_branch":"other","head_sha":"deadbeefcafedeadbeefcafedeadbeefcafedead","head_repository":{"full_name":"solo/repo"}}]}'
run_gate "$GREEN_11"
check_eq "false" "$(j .no_review_override.applied)" "only another branch push run: override ineligible"
check_eq "anchor_unavailable: no pull_request workflow run for HEAD on feature" "$(j .no_review_override.reason)" "ineligible reason names the missing pull_request run"
unset FAKE_RUNS

echo "=== merge-site contracts: refresh the gate right before an override merge ==="
SKILLS_DIR="$SCRIPT_DIR/../../skills"
prose_has() { grep -qF "$2" "$1" && echo yes || echo no; }
check_eq "yes" "$(prose_has "$SKILLS_DIR/merge/SKILL.md" 'first **re-run `merge-gate.sh` into the gate JSON**')" \
  "/merge re-runs merge-gate.sh after AC verification before an override merge"
check_eq "yes" "$(prose_has "$SKILLS_DIR/wrap/SKILL.md" 'its refreshed `merge_state` still passes this same test')" \
  "/wrap re-checks the allowed merge state on the refreshed gate"

echo
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
