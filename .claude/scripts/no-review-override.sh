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
#     success / failure / action_required / neutral — unless that bot posted a
#     capability-failure notice (usage limit, couldn't run, rate limit) after
#     the HEAD anchor, which is a refusal, not a review.
#   NOT verdicts (they never extend the window): pending reviewer check-runs,
#   "review in progress" / rate-limit / trigger-ack comments.
#
# HEAD ANCHOR (conservative push time — never earlier than the real push)
#   GitHub records no event for an ordinary push, and a committer date can be
#   days older than the push. The anchor is the LATEST of: the HEAD committer
#   date, the PR's created_at, the newest ready_for_review / reopened /
#   head_ref_force_pushed timeline event, and the EARLIEST started_at of the
#   raw HEAD check-runs (they start only after the push lands). A draft PR, an
#   unreadable PR or timeline, a malformed timestamp, or no HEAD check-run
#   timestamp makes the override INELIGIBLE (reason given) — the gate is then
#   exactly what it was before this helper existed. "Now" is the real clock;
#   there is deliberately no environment or flag override for it.
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
  def reviewer_bots: ["coderabbitai[bot]","codeant-ai[bot]","cursor[bot]","greptile-apps[bot]","graphite-app[bot]"];
  def reviewer_slugs: {"coderabbitai":"coderabbitai[bot]","coderabbit":"coderabbitai[bot]",
                       "codeant-ai":"codeant-ai[bot]","codeant":"codeant-ai[bot]",
                       "cursor":"cursor[bot]","cursor-com":"cursor[bot]",
                       "greptile-apps":"greptile-apps[bot]","greptile":"greptile-apps[bot]",
                       "graphite-app":"graphite-app[bot]","graphite":"graphite-app[bot]"};
  def ts: if type != "string" then null
          else (sub("\\.[0-9]+"; "") | sub("\\+00:00$"; "Z")) as $s
          | if ($s | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$"))
            then ($s | fromdateiso8601) else null end end;
  def failure_notice: test("usage limit|couldn.t run|could not run|rate limit|no PR Review subscription|review limit reached"; "i");
'

emit() { printf '%s\n' "$1"; exit 0; }

BASE=$(printf '%s' "$PAYLOAD" | jq -c '
  {enabled: (.window_seconds != null), window_seconds: .window_seconds,
   eligible: false, applied: false, reason: "", pending_reason: "",
   head_anchor_ts: null, anchor_source: null, elapsed_seconds: null, eligible_at: null,
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
  + [ (.issue_comments // [])[]?
      | select((.user.login // "") == "greptile-apps[bot]")
      | select((.body // "") | test("Last reviewed commit"; "i"))
      | select((.body // "") | contains($h) or contains($h[0:7]))
      | {reviewer: .user.login, kind: "greptile_summary"} ]
  + [ (.issue_comments // [])[]?
      | select((.user.login // "") == "codeant-ai[bot]")
      | (.body // "")
      | scan("<!--[[:space:]]*codeant-review-status:([\\s\\S]*?)-->")
      | (if type == "array" then (.[0] // "") else . end)
      | (fromjson? // empty)
      | (if type == "array" then .[] else empty end)
      | select(type == "object" and .done == true and (tostring | contains($h)))
      | {reviewer: "codeant-ai[bot]", kind: "codeant_run_record"} ]
  | unique')

# Capability-failure notices are read per bot so a refused run's neutral
# check-run is not mistaken for a review. A notice discounts a check-run only
# when posted at or after THAT run's started_at: a refusal from before the push
# (older than the HEAD run) can never suppress a current-HEAD check verdict.
PAYLOAD_WITH_INV=$(printf '%s' "$PAYLOAD" | jq -c --argjson inv "$INVENTORY" '. + {inv: $inv}')
DECISION=$(printf '%s' "$PAYLOAD_WITH_INV" | jq -c "$JQ_DEFS"'
  (.commit_ts | ts) as $cts
  | (reviewer_slugs) as $slugs
  | ([ (.issue_comments // [])[]?
       | select((.user.login // "") as $l | reviewer_bots | index($l))
       | select((.body // "") | failure_notice)
       | {login: .user.login, t: ((.created_at | ts) // 0)} ]) as $notices
  | ([ $notices[] | select(($cts == null) or (.t >= $cts)) | .login ] | unique) as $refused
  | ([ (.check_runs_raw // [])[]?
       | select((.app.slug // "") as $s | $slugs | has($s)) ]) as $rchecks
  | ([ $rchecks[]
       | select((.status // "") == "completed")
       | select((.conclusion // "") | IN("success","failure","action_required","neutral"))
       | ($slugs[.app.slug]) as $bot
       | ((.started_at | ts) // $cts // 0) as $run_t
       | select([ $notices[] | select(.login == $bot and .t >= $run_t) ] | length == 0)
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

ANCHOR=$(jq -cn "$JQ_DEFS"'
  input as $p | input as $pull | input as $tl
  | ([ $p.check_runs_raw[]? | .started_at ] | map(select(. != null))) as $starts
  | ($starts | map(ts)) as $start_ts
  | ([ $tl[]? | select((.event // "") | IN("ready_for_review","reopened","head_ref_force_pushed"))
       | {src: .event, raw: .created_at} ]) as $events
  | ([ {src: "commit_date", raw: $p.commit_ts}, {src: "pr_created_at", raw: $pull.created_at} ]
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

NOW=$(date -u +%s)
BLOCKERS=$(printf '%s' "$PAYLOAD" | jq -c '.review_blockers // []')
emit "$(printf '%s' "$OUT" | jq -c --argjson a "$ANCHOR" --argjson now "$NOW" --argjson rb "$BLOCKERS" '
  ($now - $a.t) as $el
  | .head_anchor_ts = ($a.t | todateiso8601) | .anchor_source = $a.src
  | .elapsed_seconds = $el | .eligible_at = (($a.t + .window_seconds) | todateiso8601)
  | .eligible = true
  | if $el >= .window_seconds then
      .applied = true | .reason = "window_elapsed" | .waived_reasons = $rb
    else
      .reason = "window_running"
      | .pending_reason = "no AI reviewer verdict on HEAD yet; no-review override window not elapsed (\(.window_seconds - $el)s remaining, eligible at \(.eligible_at)) — issue #1899"
    end')"
