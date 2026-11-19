#!/usr/bin/env bash
# catalog: merge-gate-sequencing — Re-run one verified cancelled required Actions job per PR HEAD.
#
# Usage: rerun-cancelled-required-ci.sh <PR>
# Stdout is JSON. Exit 0 for an assessed outcome, 1 for an operational failure,
# 2 for bad usage. A requested rerun is not a passing check.
# Concurrent callers wait briefly for an in-progress request. An older claim
# with no recorded result requires verification and never permits a second POST.
set -uo pipefail

PR="${1:-}"
if [[ $# -ne 1 || ! "$PR" =~ ^[1-9][0-9]*$ ]]; then
  echo "Usage: rerun-cancelled-required-ci.sh <PR>" >&2
  exit 2
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATE_SH="$SCRIPT_DIR/session-state.sh"
# shellcheck source=./lib/repo-normalizer.sh
source "$SCRIPT_DIR/lib/repo-normalizer.sh" || exit 1

HEAD_SHA=""
JOB_ID=null
PENDING_SECONDS=120
report() {
  jq -cn --arg status "$1" --arg reason "$2" --arg head "$HEAD_SHA" --argjson job "$JOB_ID" \
    '{status:$status,reason:$reason,head_sha:$head,job_id:$job,
      wait_for_ci:($status == "requested"
        or ($status == "already_recorded" and ($reason | IN("requested", "request_pending"))))}'
}

report_prior() {
  local status now
  now=$(date -u +%s) || { report state_error "cannot verify retry claim age"; return 1; }
  status=$(jq -r --argjson job "$JOB_ID" --argjson now "$now" --argjson pending "$PENDING_SECONDS" '
    if .job_id != $job then "retry_exhausted"
    elif .status == "claimed" then
      (try (.claimed_at | fromdateiso8601) catch null) as $at
      | if $at != null and $at <= $now and ($now - $at) < $pending
        then "request_pending" else "claim_uncertain" end
    else .status // "unknown" end' <<<"$1") || {
    report state_error "recorded retry state is invalid"; return 1;
  }
  report already_recorded "$status"
}

RAW_REPO=$(gh repo view --json nameWithOwner --jq .nameWithOwner) || {
  report validation_failed "checkout repository could not be verified"; exit 1;
}
REPO=$(normalize_repo_key "$RAW_REPO")
if [[ ! "$REPO" =~ ^[a-z0-9][a-z0-9-]*/[a-z0-9._-]+$ ]]; then
  report validation_failed "checkout repository identity is invalid"; exit 1
fi

GATE_RC=0
GATE=$("$SCRIPT_DIR/merge-gate.sh" "$PR") || GATE_RC=$?
if [[ "$GATE_RC" -gt 1 ]] || ! jq -e --arg repo "$REPO" '
  (.owner_repo | ascii_downcase) == $repo
  and (.head_sha | test("^[a-f0-9]{40}$"))
  and (.required_contexts | type == "object")
' >/dev/null 2>&1 <<<"$GATE"; then
  report validation_failed "current merge gate could not be verified"; exit 1
fi
HEAD_SHA=$(jq -r '.head_sha' <<<"$GATE")
CANDIDATE=$(jq -c '.required_contexts.cancelled_retry // null' <<<"$GATE")
if [[ "$GATE_RC" -eq 0 || "$CANDIDATE" == null ]]; then
  report not_eligible "current gate does not identify a single cancelled required job"; exit 0
fi
if ! jq -e '(.id | type == "number" and . > 0 and floor == .)
               and (.name | type == "string" and length > 0)' >/dev/null 2>&1 <<<"$CANDIDATE"; then
  report validation_failed "current gate returned an invalid retry candidate"; exit 1
fi
JOB_ID=$(jq -r '.id' <<<"$CANDIDATE")
JOB_NAME=$(jq -r '.name' <<<"$CANDIDATE")
SLOT=".prs[\"$PR\"].required_ci_reruns[\"$HEAD_SHA\"]"

# Missing state is normal on the first run. Any other read error is a stop.
READ_RC=0
PRIOR=$("$STATE_SH" --repo "$REPO" --get-json "$SLOT") || READ_RC=$?
case "$READ_RC" in
  0) ;;
  3) PRIOR=null ;;
  *) report state_error "retry state is unreadable"; exit 1 ;;
esac
if [[ "$PRIOR" != null ]]; then
  report_prior "$PRIOR"; exit $?
fi

# GitHub exposes check_run_url on the Actions job. The URL is matched as data
# and never used as a request destination.
JOB=$(gh api "repos/$REPO/actions/jobs/$JOB_ID") || {
  report validation_failed "the exact Actions job could not be fetched"; exit 1;
}
if ! jq -e --arg repo "$REPO" --arg sha "$HEAD_SHA" --arg name "$JOB_NAME" --argjson id "$JOB_ID" '
  .id == $id and .name == $name and .head_sha == $sha
  and .status == "completed" and .conclusion == "cancelled"
  and ((.check_run_url // "") | ascii_downcase
       | endswith("/repos/" + $repo + "/check-runs/" + ($id | tostring)))
' >/dev/null 2>&1 <<<"$JOB"; then
  report validation_failed "the Actions job does not match the cancelled required check"; exit 1
fi

CLAIM=$(jq -cn --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --argjson job "$JOB_ID" \
  '{status:"claimed",job_id:$job,claimed_at:$at}') || exit 1
CLAIM_RC=0
"$STATE_SH" --repo "$REPO" --cas "$SLOT=$CLAIM" --expect null >/dev/null || CLAIM_RC=$?
if [[ "$CLAIM_RC" -eq 7 ]]; then
  PRIOR=$("$STATE_SH" --repo "$REPO" --get-json "$SLOT") || {
    report state_error "winning retry state is unreadable"; exit 1;
  }
  report_prior "$PRIOR"; exit $?
elif [[ "$CLAIM_RC" -ne 0 ]]; then
  report state_error "retry claim could not be recorded"; exit 1
fi

# Keep the claim after any outcome. A crash between request and receipt cannot
# safely tell a later caller whether GitHub accepted the request.
CURRENT=$(gh pr view "$PR" --repo "$REPO" --json state,headRefOid,isDraft) || CURRENT=""
RESULT=superseded
REASON="PR state, draft status or HEAD changed before the rerun"
if jq -e --arg head "$HEAD_SHA" '.state == "OPEN" and .isDraft == false and .headRefOid == $head' >/dev/null 2>&1 <<<"$CURRENT"; then
  if gh api --method POST "repos/$REPO/actions/jobs/$JOB_ID/rerun" >/dev/null; then
    RESULT=requested
    REASON="rerun requested for the exact cancelled job"
  else
    RESULT=request_failed
    REASON="GitHub did not confirm the rerun request"
  fi
fi
DONE=$(jq -c --arg status "$RESULT" --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  '.status=$status | .finished_at=$at' <<<"$CLAIM") || exit 1
if ! "$STATE_SH" --repo "$REPO" --cas "$SLOT=$DONE" --expect "$CLAIM" >/dev/null; then
  report state_error "$REASON; the outcome could not be recorded"; exit 1
fi
report "$RESULT" "$REASON"
[[ "$RESULT" != request_failed ]]
