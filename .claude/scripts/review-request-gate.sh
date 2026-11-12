#!/usr/bin/env bash
# review-request-gate.sh — May the agent ask for an AI review on this HEAD yet? (issue #2195)
# catalog: review-escalation — Decide whether the agent's review request for a PR HEAD may post now: after-ci waits for the named (or every non-reviewer) check to finish green, requests once per HEAD, never on failed checks; on-push keeps today's behaviour
#
# PURPOSE
#   Reviewers that start on push burn their allowance on commits whose CI then
#   fails. This is the one pure decision for WHEN the agent's request posts,
#   so maybe-trigger-ai-review.sh and its tests share one answer. It reads no
#   GitHub state itself: the caller passes the HEAD's check runs on stdin and
#   the HEAD commit time, and reads the setting from review-tier.sh --json.
#   Rules: .claude/reference/review-request-timing.md.
#
# USAGE
#   review-request-gate.sh --setting <after-ci|on-push|never> --head <sha>
#       [--checks <csv>] [--requested-head <sha>]
#       [--head-epoch <s>] [--now-epoch <s>] < check-runs.json
#   --setting         REVIEW_REQUEST from review-tier.sh --json (after-ci default).
#   --checks          REVIEW_REQUEST_CHECKS csv; empty = every non-reviewer check.
#   --requested-head  The HEAD a request already posted for (session state).
#   --head-epoch      Committer time of the HEAD commit, epoch seconds. Starts
#                     the grace clock for checks that never report. Omitted =
#                     unknown age: a check that never reports keeps waiting.
#   --now-epoch       Test seam; default is the current time.
#   stdin             GET repos/{o}/{r}/commits/<sha>/check-runs JSON ({check_runs: [...]}).
#
# OUTPUT (one JSON line)
#   {"decision":"request|wait|none","reason":"...","ignored_checks":[...]}
#   request  post the request now (exactly once for this HEAD)
#   wait     checks still running or not yet reported; ask again next tick
#   none     never request on this HEAD (failed check, already requested, setting never)
#
# RULES (after-ci)
#   1. Reviewer checks (CodeRabbit, CodeAnt, BugBot/Cursor, Greptile, Graphite,
#      by app slug or name) never count as CI.
#   2. A blocking conclusion (failure, timed_out, cancelled, action_required,
#      startup_failure, stale) on a counted check → none, whatever else runs.
#   3. Named checks: each name's newest run decides. A name with no run yet is
#      `pending` until the grace (900 s, from `--head-epoch`: the later of the commit time and the first poll that saw the HEAD) has passed;
#      after that it is ignored and listed in ignored_checks, so a check that
#      never reports cannot hold the request forever. Unnamed checks are not
#      consulted once names are given: that is the point of the list.
#   4. No names: every non-reviewer run must be completed and non-blocking. No
#      runs at all → wait until the grace passes, then request (a repo with no CI).
#   5. Requested already on this HEAD → none. A new push is a new HEAD and eligible again.
#   6. on-push → request immediately (today's behaviour; no CI gate, no dedupe here).
#
# EXIT STATUS
#   0  decision printed.  2  usage.  4  unreadable check-run JSON or no jq.

set -uo pipefail

GRACE_S=900
usage_err() { printf 'review-request-gate.sh: %s\n' "$1" >&2; exit 2; }

SETTING="" HEAD="" CHECKS="" REQ_HEAD="" HEAD_EPOCH="" NOW_EPOCH=""
while [[ $# -gt 0 ]]; do
  [[ "$1" == "-h" || "$1" == "--help" || $# -ge 2 ]] || usage_err "$1 needs a value"
  case "$1" in
    --setting) SETTING="${2-}"; shift 2 ;;
    --head) HEAD="${2-}"; shift 2 ;;
    --checks) CHECKS="${2-}"; shift 2 ;;
    --requested-head) REQ_HEAD="${2-}"; shift 2 ;;
    --head-epoch) HEAD_EPOCH="${2-}"; shift 2 ;;
    --now-epoch) NOW_EPOCH="${2-}"; shift 2 ;;
    -h|--help) sed -n '/^# PURPOSE$/,/^#$/p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) usage_err "unknown argument: $1" ;;
  esac
done

case "$SETTING" in
  after-ci|on-push|never) ;;
  *) usage_err "--setting must be after-ci, on-push or never" ;;
esac
[[ -n "$HEAD" ]] || usage_err "--head is required"
command -v jq >/dev/null 2>&1 || { echo "review-request-gate.sh: requires jq" >&2; exit 4; }
[[ -n "$NOW_EPOCH" ]] || NOW_EPOCH="$(date +%s)"
[[ "$NOW_EPOCH" =~ ^[0-9]+$ ]] || usage_err "--now-epoch must be an integer"
[[ -z "$HEAD_EPOCH" || "$HEAD_EPOCH" =~ ^[0-9]+$ ]] || usage_err "--head-epoch must be an integer"

emit() { jq -cn --arg d "$1" --arg r "$2" --argjson i "${3:-[]}" '{decision: $d, reason: $r, ignored_checks: $i}'; }

if [[ "$SETTING" == "never" ]]; then emit none setting_never; exit 0; fi
if [[ "$SETTING" == "on-push" ]]; then emit request on_push; exit 0; fi
if [[ -n "$REQ_HEAD" && "$REQ_HEAD" == "$HEAD" ]]; then emit none already_requested; exit 0; fi

# Names, trimmed; empty entries dropped.
NAMES_JSON="$(printf '%s\n' "$CHECKS" | jq -Rc 'split(",") | map(gsub("^[[:space:]]+|[[:space:]]+$"; "")) | map(select(length > 0))')" \
  || { echo "review-request-gate.sh: could not parse --checks" >&2; exit 4; }

RUNS_IN="$(cat)"
if ! jq -e '(type == "array") or ((.check_runs? // null) | type == "array")' <<<"$RUNS_IN" >/dev/null 2>&1; then
  echo "review-request-gate.sh: check-run input is not a check-run array or {check_runs: [...]}" >&2
  exit 4
fi

RESULT="$(jq -c \
  --argjson names "$NAMES_JSON" --argjson now "$NOW_EPOCH" \
  --argjson head "${HEAD_EPOCH:-null}" --argjson grace "$GRACE_S" '
  # The reviewer rule of ci-status.sh: by app slug, or by exact name when the
  # publisher is absent. Exact names, never a substring (cursor-pagination is CI).
  def reviewer:
    (.app.slug // "") as $slug
    | if $slug == "" then ((.name // "") | IN("CodeRabbit", "CodeAnt", "Cursor Bugbot", "Greptile", "Graphite / AI Reviews"))
      else ($slug | IN("codeant-ai", "codeant", "cursor", "cursor-com", "coderabbitai", "coderabbit", "greptile-apps", "greptile", "graphite-app", "graphite"))
      end;
  def state:
    if (.status // "") != "completed" or (.conclusion // null) == null then "pending"
    elif (.conclusion | IN("failure", "timed_out", "cancelled", "action_required", "startup_failure", "stale")) then "blocking"
    else "ok" end;
  def newest($runs; $n): [ $runs[] | select(.name == $n) ] | sort_by(.id // 0) | last;
  def past_grace: if $head == null then false else (($now - $head) > $grace) end;
  ((if type == "array" then . else .check_runs end)) | map(select(reviewer | not)) as $ci
  | if ($names | length) == 0 then
      ([ $ci[] | state ]) as $st
      | if any($st[]; . == "blocking") then {decision: "none", reason: "ci_failed"}
        elif any($st[]; . == "pending") then {decision: "wait", reason: "ci_pending"}
        elif ($st | length) == 0 then
          (if past_grace then {decision: "request", reason: "no_checks"} else {decision: "wait", reason: "no_checks_yet"} end)
        else {decision: "request", reason: "ci_green"} end
    else
      [ $names[] as $n | newest($ci; $n) as $r
        | if $r == null then (if past_grace then {n: $n, s: "ignored"} else {n: $n, s: "pending"} end)
          else {n: $n, s: ($r | state)} end ] as $per
      | [ $per[] | select(.s == "blocking") | .n ] as $bad
      | [ $per[] | select(.s == "pending") | .n ] as $wait
      | [ $per[] | select(.s == "ignored") | .n ] as $ign
      | if ($bad | length) > 0 then {decision: "none", reason: "ci_failed", ignored: $ign}
        elif ($wait | length) > 0 then {decision: "wait", reason: "named_checks_pending", ignored: $ign}
        elif ($ign | length) == ($names | length) then {decision: "request", reason: "named_checks_not_reporting", ignored: $ign}
        else {decision: "request", reason: "named_checks_green", ignored: $ign} end
    end
  | {decision: .decision, reason: .reason, ignored_checks: (.ignored // [])}
' <<<"$RUNS_IN")" || { echo "review-request-gate.sh: jq evaluation failed" >&2; exit 4; }

printf '%s\n' "$RESULT"
exit 0
