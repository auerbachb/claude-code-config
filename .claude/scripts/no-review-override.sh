#!/usr/bin/env bash
# no-review-override.sh — decide the merge gate's no-reviewer override (issue #1899).
# catalog: merge-gate-sequencing — Decide whether the merge gate may waive missing AI-review coverage after the no-review window
#
# PURPOSE
#   Owner policy (Issue #1899): when NO AI reviewer has produced a verdict on
#   the PR's current HEAD within the window (default 10 min), the merge gate is
#   met anyway, provided every other hard stop passes. This helper decides ONLY
#   the reviewer-coverage half. merge-gate.sh calls it with the reviewer-coverage
#   reasons it collected, and keeps every other reason (CI, required contexts,
#   threads, human CHANGES_REQUESTED, merge state, authorship, tier resolution)
#   blocking exactly as before. It never triggers, invites, or pays for a review.
#
# USAGE
#   no-review-override.sh < payload.json      # one JSON object on stdin
#   no-review-override.sh --help
#
#   Payload (built by merge-gate.sh):
#     {owner, repo, pr, head_sha, commit_ts, window_seconds (int|null),
#      tier_gate, review_blockers: [..], reviews: [..], pr_comments: [..],
#      issue_comments: [..], check_runs_raw: [..] (UNdeduped HEAD runs),
#      hollow: [login..]}
#
# OUTPUT (stdout, one JSON line; exit 0 whenever a decision was made)
#   {enabled, window_seconds, eligible, applied, reason,
#    pending_reason, head_anchor_ts, anchor_source, elapsed_seconds,
#    eligible_at, verdicts_on_head: [{reviewer, kind}],
#    missing_reviewers: [{reviewer, reason}], waived_reasons: [..],
#    excluded_reviewer_checks: [{name, app, status}]}
#   `applied` true = the caller drops `review_blockers` from missing[] and
#   re-reads CI without the non-completed reviewer checks. `pending_reason`
#   is set while the window is still running — the caller adds it to missing[].
#   Exit 2 = usage error, 4 = unusable payload. The caller treats any non-zero
#   exit or unparseable output as "not applied" (fail closed: nothing waived).
#
# WHAT COUNTS AS A VERDICT ON HEAD (any one disables the override, so the
# normal reviewer path decides — an adverse bot verdict is never waived):
#   - a non-PENDING review by a reviewer bot with commit_id == HEAD, except an
#     APPROVED that is hollow (merge-gate's review-substance verdict) or whose
#     submitted_at predates the HEAD commit (force-push retarget). Discounting
#     an approval only removes a positive signal; CHANGES_REQUESTED and
#     COMMENTED reviews on HEAD always count.
#   - an inline comment by a reviewer bot anchored to HEAD
#   - a Greptile summary naming HEAD as its last reviewed commit
#   - a `done` row of CodeAnt's run record that names HEAD
#   - a COMPLETED reviewer-app check-run (exact app slug) with conclusion
#     success / failure / action_required / neutral — unless the run is a
#     refusal, not a review (issue #1939): its own output.title matches the
#     capability-failure classifier (usage limit, couldn't run, rate limit,
#     review limit reached), or that bot's capability-failure notice was last
#     written at or after the run's started_at — or up to NOTICE_SKEW_SECONDS
#     (60) before it when the notice names HEAD. A notice naming another commit
#     never counts. Either way the bot is reported as capability_failure.
#     A notice's time is the later of created_at and updated_at — CodeRabbit
#     posts "Review limit reached" a second BEFORE its neutral run starts and
#     rewrites that same comment in place on later pushes.
#   NOT verdicts (they never extend the window): pending reviewer check-runs,
#   "review in progress" / rate-limit / trigger-ack comments.
#
# HEAD ANCHOR (conservative push time — never earlier than the real push)
#   GitHub records no event for an ordinary push, and a committer date can be
#   days older than the push. The anchor is the LATEST of: the HEAD committer
#   date, the PR's created_at, the newest ready_for_review / reopened /
#   head_ref_force_pushed timeline event, the earliest pull_request-event
#   workflow run for HEAD on the PR's head ref (required — check-runs can
#   predate the PR adopting a SHA), and the EARLIEST started_at of the raw
#   HEAD check-runs. A draft PR, an unreadable PR, timeline or run list, no
#   such pull_request run, a malformed
#   timestamp, or no HEAD check-run
#   timestamp makes the override INELIGIBLE (reason given) — the gate is then
#   exactly what it was before this helper existed. "Now" is the real clock;
#   there is deliberately no environment or flag override for it.
#
# REVIEW-REQUEST ANCHOR (issue #2194): when the PR author has requested a review
# on HEAD (a whole line `@codeant-ai review` / `@coderabbitai [full ]review`
# posted at or after the push anchor above), the window runs from the FIRST such
# request instead (anchor_source "review_request", request_ts set). Later requests
# never move it. Fail closed on an unreadable comment list, an unknown author, or
# a malformed request timestamp.
#
# Mechanism and rationale: .claude/reference/no-review-override.md

set -uo pipefail

print_usage() { sed -n '2,/^set -uo/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'; }

case "${1:-}" in
  -h|--help) print_usage; exit 0 ;;
  "") ;;
  *) echo "no-review-override.sh: unknown argument: $1 (payload is read from stdin)" >&2; exit 2 ;;
esac

PAYLOAD="$(cat)"
if [[ -z "$PAYLOAD" ]] || ! printf '%s' "$PAYLOAD" | jq -e 'type == "object" and (.head_sha | type == "string" and length > 0)' >/dev/null 2>&1; then
  echo "no-review-override.sh: payload is not a JSON object with a head_sha" >&2
  exit 4
fi

# Shared jq helpers. `ts` normalizes the two ISO shapes GitHub emits (`Z`,
# `+00:00`, optional fractional seconds) to epoch seconds; anything else is
# null, which the anchor step treats as malformed.
JQ_DEFS='
  def reviewer_bots: ["coderabbitai[bot]","codeant-ai[bot]","cursor[bot]","greptile-apps[bot]"];
  def reviewer_slugs: {"coderabbitai":"coderabbitai[bot]","coderabbit":"coderabbitai[bot]",
                       "codeant-ai":"codeant-ai[bot]","codeant":"codeant-ai[bot]",
                       "cursor":"cursor[bot]","cursor-com":"cursor[bot]",
                       "greptile-apps":"greptile-apps[bot]","greptile":"greptile-apps[bot]"};
  def active_check_runs: (.check_runs_raw // [])[]?
    | select(((.app.slug // "") as $slug
      | if $slug == "" then (.name // "") | IN("Graphite / AI Reviews", "Graphite / mergeability_check")
        else $slug | IN("graphite-app", "graphite") end) | not);
  def ts: if type != "string" then null
          else (sub("\\.[0-9]+"; "") | sub("\\+00:00$"; "Z")) as $s
          | if ($s | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$"))
            then ($s | fromdateiso8601) else null end end;
  def failure_notice: test("usage limit|couldn.t run|could not run|rate limit|no PR Review subscription|review limit reached"; "i");
  def issue_comment_verdicts($h):
    [ .[]?
        | select((.user.login // "") == "greptile-apps[bot]")
        | select((.body // "") | test("Last reviewed commit"; "i"))
        | select((.body // "") | contains($h) or contains($h[0:7]))
        | {reviewer: .user.login, kind: "greptile_summary"} ]
    + [ .[]?
        | select((.user.login // "") == "codeant-ai[bot]")
        | (.body // "")
        | scan("<!--[[:space:]]*codeant-review-status:([\\s\\S]*?)-->")
        | (if type == "array" then (.[0] // "") else . end)
        | (fromjson? // empty)
        | (if type == "array" then .[] else empty end)
        | select(type == "object" and .done == true and (tostring | contains($h)))
        | {reviewer: "codeant-ai[bot]", kind: "codeant_run_record"} ];
'

emit() { printf '%s\n' "$1"; exit 0; }

BASE=$(printf '%s' "$PAYLOAD" | jq -c '
  {enabled: (.window_seconds != null), window_seconds: .window_seconds,
   eligible: false, applied: false, reason: "", pending_reason: "",
   head_anchor_ts: null, anchor_source: null, request_ts: null, push_anchor_ts: null,
   elapsed_seconds: null, eligible_at: null,
   verdicts_on_head: [], missing_reviewers: [], waived_reasons: [], excluded_reviewer_checks: []}')

# 1. Disabled, nothing to waive, or a tier that requires no reviewer.
if [[ "$(printf '%s' "$PAYLOAD" | jq -r '.window_seconds == null')" == true ]]; then
  emit "$(printf '%s' "$BASE" | jq -c '.reason = "disabled"')"
fi
if [[ "$(printf '%s' "$PAYLOAD" | jq -r '(.review_blockers // []) | length == 0')" == true ]]; then
  emit "$(printf '%s' "$BASE" | jq -c '.reason = "not_needed"')"
fi
if [[ "$(printf '%s' "$PAYLOAD" | jq -r '.tier_gate == "ci-only"')" == true ]]; then
  emit "$(printf '%s' "$BASE" | jq -c '.reason = "tier_requires_no_review"')"
fi

# 2. Verdict inventory — no API calls; everything comes from the payload.
INVENTORY=$(printf '%s' "$PAYLOAD" | jq -c "$JQ_DEFS"'
  .head_sha as $h | (.commit_ts | ts) as $cts | (.hollow // []) as $hollow
  | (reviewer_bots) as $bots
  | [ (.reviews // [])[]?
      | select((.user.login // "") as $l | $bots | index($l))
      | select((.commit_id // "") == $h and (.state // "") != "PENDING" and (.state // "") != "DISMISSED")
      | select(
          (.state != "APPROVED")
          or ( ((.user.login) as $l | $hollow | index($l) | not)
               and (($cts == null) or (((.submitted_at | ts) // 0) >= $cts)) ))
      | {reviewer: .user.login, kind: ("review_" + (.state | ascii_downcase))} ]
  + [ (.pr_comments // [])[]?
      | select((.user.login // "") as $l | $bots | index($l))
      | select((.commit_id // "") == $h or (.original_commit_id // "") == $h)
      | {reviewer: .user.login, kind: "inline_comment"} ]
  + ((.issue_comments // []) | issue_comment_verdicts($h))
  | unique')

# Capability-failure notices are read per bot so a refused run's neutral
# check-run is not mistaken for a review (issue #1939). A notice's time is the
# later of created_at and updated_at: the body is the comment's CURRENT text,
# last written at updated_at (CodeRabbit rewrites its summary comment in place).
# A notice discounts a check-run only when written no more than
# NOTICE_SKEW_SECONDS before THAT run's started_at — CodeRabbit posts "Review
# limit reached" about a second before its neutral run starts — so a refusal
# from before the push (older than the HEAD run by more than the skew) can never
# suppress a current-HEAD check verdict. A notice that names its commit
# (CodeRabbit embeds `"headCommitId":"<sha>"`) discounts only a run on that
# commit, so another HEAD's refusal inside the skew cannot suppress this one;
# the skew itself applies only to a notice that names HEAD — an unnamed notice
# must be written strictly after the run's started_at second — `ts` drops
# fractional seconds, so a notice from earlier in that same second would
# otherwise compare equal and discount the run. A
# run whose own output.title matches the same classifier is a refusal
# regardless of comments; a missing title does not stop an in-window notice
# from discounting it. A missing/malformed started_at leaves the run a verdict
# unless its own title is a refusal — no notice can discount it, since the
# commit date is never a stand-in run start. There is deliberately no upper
# bound on the notice time: BugBot posts its refusal after its run completes.
NOTICE_SKEW_SECONDS=60
PAYLOAD_WITH_INV=$(printf '%s' "$PAYLOAD" | jq -c --argjson inv "$INVENTORY" '. + {inv: $inv}')
DECISION=$(printf '%s' "$PAYLOAD_WITH_INV" | jq -c --argjson skew "$NOTICE_SKEW_SECONDS" "$JQ_DEFS"'
  (.commit_ts | ts) as $cts | .head_sha as $h
  | (reviewer_slugs) as $slugs
  | ([ (.issue_comments // [])[]?
       | select((.user.login // "") as $l | reviewer_bots | index($l))
       | select((.body // "") | failure_notice)
       | ([(.body // "") | scan("\"headCommitId\"[[:space:]]*:[[:space:]]*\"([0-9a-fA-F]{40})\"") | .[0] | ascii_downcase]) as $named
       | {login: .user.login,
          names_head: (($named | index($h | ascii_downcase)) != null),
          for_head: (($named | length) == 0 or ($named | index($h | ascii_downcase)) != null),
          t: ([(.created_at | ts), (.updated_at | ts)] | map(select(. != null)) | max // 0)} ]) as $notices
  | ([ active_check_runs
       | select((.app.slug // "") as $s | $slugs | has($s)) ]) as $rchecks
  | ([ $rchecks[]
       | select((.status // "") == "completed")
       | select((.output.title // "") | if type == "string" then failure_notice else false end)
       | $slugs[.app.slug] ] | unique) as $titled_refusals
  | ([ $notices[] | select(.for_head and (($cts == null) or (.t >= $cts))) | .login ] + $titled_refusals | unique) as $refused
  | ([ $rchecks[]
       | select((.status // "") == "completed")
       | select((.conclusion // "") | IN("success","failure","action_required","neutral"))
       | ($slugs[.app.slug]) as $bot
       | (.started_at | ts) as $run_t
       | select(((.output.title // "") | if type == "string" then failure_notice else false end) | not)
       | select($run_t == null
                or ([ $notices[] | select(.login == $bot
                         and ((.for_head and .t > $run_t) or (.names_head and .t >= ($run_t - $skew)))) ] | length == 0))
       | {reviewer: $bot, kind: ("check_" + .conclusion)} ]) as $check_verdicts
  | ((.inv + $check_verdicts) | unique) as $verdicts
  | ([ $rchecks[] | select((.status // "") != "completed")
       | {name: (.name // ""), app: .app.slug, status: (.status // "")} ] | unique) as $pending
  | {verdicts: $verdicts, pending_checks: $pending,
     missing: [ reviewer_bots[] as $b
                | select(([$verdicts[] | select(.reviewer == $b)] | length) == 0)
                | {reviewer: $b,
                   reason: (if ([$pending[] | select($slugs[.app] == $b)] | length) > 0 then "review_in_progress"
                            elif ($refused | index($b)) then "capability_failure"
                            elif ([(.reviews // [])[]? | select(.user.login == $b and .state == "APPROVED")] | length) > 0 then "discounted_approval"
                            else "no_head_signal" end)} ]}')
if [[ -z "$DECISION" ]]; then
  echo "no-review-override.sh: verdict inventory failed to evaluate" >&2
  exit 4
fi

OUT=$(printf '%s' "$BASE" | jq -c --argjson d "$DECISION" \
  '.verdicts_on_head = $d.verdicts | .missing_reviewers = $d.missing | .excluded_reviewer_checks = $d.pending_checks')
if [[ "$(printf '%s' "$DECISION" | jq -r '.verdicts | length > 0')" == true ]]; then
  emit "$(printf '%s' "$OUT" | jq -c '.reason = "verdict_on_head"')"
fi

ineligible() { emit "$(printf '%s' "$OUT" | jq -c --arg r "$1" '.reason = $r')"; }

# 3. HEAD anchor. Only now do we spend API calls — and only reads.
OWNER=$(printf '%s' "$PAYLOAD" | jq -r '.owner // ""')
REPO=$(printf '%s' "$PAYLOAD" | jq -r '.repo // ""')
PR=$(printf '%s' "$PAYLOAD" | jq -r '.pr // ""')
[[ -n "$OWNER" && -n "$REPO" && "$PR" =~ ^[0-9]+$ ]] || ineligible "anchor_unavailable: payload lacks owner/repo/pr"

PULL_JSON=$(gh api "repos/$OWNER/$REPO/pulls/$PR" 2>/dev/null) || PULL_JSON=""
if [[ -z "$PULL_JSON" ]] || ! printf '%s' "$PULL_JSON" | jq -e 'type == "object" and has("created_at")' >/dev/null 2>&1; then
  ineligible "anchor_unavailable: PR metadata unreadable"
fi
if [[ "$(printf '%s' "$PULL_JSON" | jq -r '.draft == true')" == true ]]; then
  ineligible "draft_pr"
fi
TIMELINE_RAW=$(gh api --paginate "repos/$OWNER/$REPO/issues/$PR/timeline?per_page=100" 2>/dev/null) || TIMELINE_RAW=""
TIMELINE_JSON=$(printf '%s' "$TIMELINE_RAW" | jq -cs 'if length > 0 and all(.[]; type == "array") then add else error("bad") end' 2>/dev/null) || TIMELINE_JSON=""
[[ -n "$TIMELINE_JSON" ]] || ineligible "anchor_unavailable: PR timeline unreadable"

# When this PR adopted HEAD. Check-runs on a SHA can predate the PR adopting
# it (an ordinary push of a SHA already built on another branch records no
# timeline event), so the EARLIEST pull_request-event workflow run for HEAD on
# this PR's own head repo/ref is required — those runs are created only once
# the PR points at HEAD. None (no pull_request workflow, unreadable runs) →
# ineligible: the anchor is never earlier than the PR's own adoption of HEAD.
HEAD_REPO=$(printf '%s' "$PULL_JSON" | jq -r '.head.repo.full_name // ""')
HEAD_REF=$(printf '%s' "$PULL_JSON" | jq -r '.head.ref // ""')
[[ -n "$HEAD_REPO" && -n "$HEAD_REF" ]] || ineligible "anchor_unavailable: PR head repo/ref unreadable"
HEAD_SHA_P=$(printf '%s' "$PAYLOAD" | jq -r .head_sha)
RUNS_RAW=$(gh api --paginate "repos/$OWNER/$REPO/actions/runs?head_sha=$HEAD_SHA_P&per_page=100" 2>/dev/null) || RUNS_RAW=""
PUSH_AT=$(printf '%s' "$RUNS_RAW" | jq -rs --arg ref "$HEAD_REF" --arg hr "$HEAD_REPO" --arg h "$HEAD_SHA_P" '
  if length > 0 and all(.[]; type == "object" and (.workflow_runs | type == "array")) then map(.workflow_runs[]) else error("bad") end
  | [ .[] | select((.event // "") | IN("pull_request","pull_request_target"))
          | select(.head_sha == $h and .head_branch == $ref
                   and ((.head_repository.full_name // "") | ascii_downcase) == ($hr | ascii_downcase))
          | .created_at ]
  | min // ""' 2>/dev/null) || PUSH_AT=""
[[ -n "$PUSH_AT" ]] || ineligible "anchor_unavailable: no pull_request workflow run for HEAD on $HEAD_REF"

ANCHOR=$(jq -cn --arg push "$PUSH_AT" "$JQ_DEFS"'
  input as $p | input as $pull | input as $tl
  | ([ $p | active_check_runs | .started_at ] | map(select(. != null))) as $starts
  | ($starts | map(ts)) as $start_ts
  | ([ $tl[]? | select((.event // "") | IN("ready_for_review","reopened","head_ref_force_pushed"))
       | {src: .event, raw: .created_at} ]) as $events
  | ([ {src: "commit_date", raw: $p.commit_ts}, {src: "pr_created_at", raw: $pull.created_at},
       {src: "pr_head_adoption", raw: $push} ]
     + $events) as $cands
  | if ($starts | length) == 0 then {error: "anchor_unavailable: no HEAD check-run start time"}
    elif ($start_ts | any(. == null)) then {error: "anchor_malformed: check-run started_at"}
    elif ($cands | any((.raw | ts) == null)) then {error: "anchor_malformed: \([$cands[] | select((.raw | ts) == null) | .src] | join(","))"}
    else ($cands | map({src, t: (.raw | ts)}) + [{src: "earliest_head_check_start", t: ($start_ts | min)}])
         | max_by(.t) | {t, src}
    end' <<<"$PAYLOAD
$PULL_JSON
$TIMELINE_JSON" 2>/dev/null) || ANCHOR=""
[[ -n "$ANCHOR" ]] || ineligible "anchor_malformed: could not evaluate"
ANCHOR_ERR=$(printf '%s' "$ANCHOR" | jq -r '.error // ""')
[[ -z "$ANCHOR_ERR" ]] || ineligible "$ANCHOR_ERR"

# 4. Review-request stage (issue #2194). The wait runs from the first review
# request on HEAD, not from the push. A request is a comment BY THE PR AUTHOR
# that is a whole line `@codeant-ai review` or `@coderabbitai [full ]review`
# (`full` is CodeRabbit's spelling only; `@codeant-ai full review` is no request)
# (the harness's own trigger scripts post as the author too). It counts only
# when posted at or after the push anchor above, so a request made on an older
# HEAD never anchors this one. The FIRST such request wins: a later request
# never restarts or extends the window. A comment counts at its latest edit
# (max of created_at and updated_at), so an edit that adds a trigger line can
# only start the window later, never earlier. No qualifying request → the push anchor
# is used unchanged. Fail closed: an unreadable comment list, an unknown author,
# or a malformed timestamp on a matching request leaves the override off.
PR_AUTHOR=$(printf '%s' "$PULL_JSON" | jq -er '.user.login | select(type == "string" and test("[^[:space:]]"))' 2>/dev/null) \
  || ineligible "anchor_unavailable: PR author unreadable"
PUSH_T=$(printf '%s' "$ANCHOR" | jq -c '.t')
# Read after the slower HEAD-anchor calls. Preserve the gate's initial verdict
# inventory and check fresh comments separately for a late exact-HEAD verdict.
REQUEST_PAGES=$(gh api --paginate "repos/$OWNER/$REPO/issues/$PR/comments?per_page=100" 2>/dev/null) \
  || ineligible "anchor_unavailable: comment list unreadable"
REQUEST_COMMENTS=$(printf '%s' "$REQUEST_PAGES" | jq -ces '
  if length > 0 and all(.[]; type == "array") then add
  else error("expected comment pages") end
  | if all(.[]; type == "object" and
               (.user.login | type == "string" and test("[^[:space:]]")) and
               (.body | type == "string")) then .
    else error("unreadable comment") end' 2>/dev/null) \
  || ineligible "anchor_unavailable: comment list unreadable"
LATE_VERDICTS=$(printf '%s' "$REQUEST_COMMENTS" | jq -ce --arg h "$HEAD_SHA_P" "$JQ_DEFS"'
  issue_comment_verdicts($h) | unique' 2>/dev/null) \
  || ineligible "anchor_unavailable: fresh review verdicts unreadable"
if [[ "$LATE_VERDICTS" != '[]' ]]; then
  emit "$(printf '%s' "$OUT" | jq -c --argjson verdicts "$LATE_VERDICTS" '
    .reason = "verdict_on_head" | .verdicts_on_head = $verdicts')"
fi
REQUEST=$(printf '%s' "$REQUEST_COMMENTS" | jq -c --arg author "$PR_AUTHOR" --argjson base "$PUSH_T" "$JQ_DEFS"'
  [ .[]
    | select((.user.login // "") == $author)
    | select((.body // "") | split("\n") | any(test("^[ \t]*(@codeant-ai[ \t]+review|@coderabbitai[ \t]+(full[ \t]+)?review)[ \t]*\r?$"; "i")))
    | {raw: (.created_at // null),
       t: ([(.created_at | ts), ((.updated_at // .created_at) | ts)]
           | if any(. == null) then null else max end)} ] as $all
  | if any($all[]; .t == null) then {error: "anchor_malformed: review request created_at"}
    else {request: ([$all[] | select(.t >= $base)] | sort_by(.t) | first)}
    end' 2>/dev/null) || REQUEST=""
[[ -n "$REQUEST" ]] || ineligible "anchor_malformed: could not evaluate review requests"
REQUEST_ERR=$(printf '%s' "$REQUEST" | jq -r '.error // ""')
[[ -z "$REQUEST_ERR" ]] || ineligible "$REQUEST_ERR"
REQUEST_T=$(printf '%s' "$REQUEST" | jq -c '.request.t // null')

NOW=$(date -u +%s)
BLOCKERS=$(printf '%s' "$PAYLOAD" | jq -c '.review_blockers // []')
emit "$(printf '%s' "$OUT" | jq -c --argjson a "$ANCHOR" --argjson rt "$REQUEST_T" --argjson now "$NOW" --argjson rb "$BLOCKERS" '
  (if $rt != null then {t: $rt, src: "review_request"} else {t: $a.t, src: $a.src} end) as $h
  | ($now - $h.t) as $el
  | .head_anchor_ts = ($h.t | todateiso8601) | .anchor_source = $h.src
  | .request_ts = (if $rt != null then ($rt | todateiso8601) else null end)
  | .push_anchor_ts = ($a.t | todateiso8601)
  | .elapsed_seconds = $el | .eligible_at = (($h.t + .window_seconds) | todateiso8601)
  | .eligible = true
  | if $el >= .window_seconds then
      .applied = true | .reason = "window_elapsed" | .waived_reasons = $rb
    else
      .reason = "window_running"
      | .pending_reason = "no AI reviewer verdict on HEAD yet; no-review override window not elapsed (\(.window_seconds - $el)s remaining, eligible at \(.eligible_at)) — issue #1899"
    end')"
