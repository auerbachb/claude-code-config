#!/usr/bin/env bash
# review-availability.sh — account-wide free-reviewer availability and the skip of an AI review request (issue #2256).
# catalog: review-escalation — Record when CodeRabbit and CodeAnt are next available from their own limit notices (account-wide), and skip a review request when no free reviewer can answer inside the no-review window
#
# PURPOSE
#   CodeRabbit's allowance is per developer account, not per repo or PR. When one PR
#   has been told "next review available in N minutes", a later PR whose CI goes
#   green still used to post a request and then wait the whole no-review window
#   for a reply that cannot come in time. This helper keeps ONE record per free
#   reviewer in session-state (`.review_availability`, account-level, written only
#   from a parsed notice time) and answers two questions:
#     decide     — may the request on this HEAD be skipped? Only when EVERY free
#                  reviewer has a current record whose next-available time, plus its
#                  expected response time, is later than now + the window. Anything
#                  else (no record, a past or unreadable record) requests as today.
#     check-skip — does a skip recorded for this HEAD still stand? no-review-override.sh
#                  applies the override at once only while the same answer holds.
#   The notice wording is parsed by lib/cr-retry-window.jq (shared with
#   escalate-review.sh). Rules: .claude/reference/review-request-timing.md §Availability.
#
# USAGE
#   review-availability.sh record [--repo <owner/name>] --pr <N> < issue-comments.json
#   review-availability.sh decide [--repo <owner/name>] --window-s <s> [--now <epoch>]
#   review-availability.sh choose [--repo <owner/name>] --window-s <s> [--now <epoch>] [--no-coderabbit]
#   review-availability.sh record-request [--repo <owner/name>] --pr <N> --head <sha> --reviewer <coderabbit|codeant> --reason <text> [--detail <json>] [--now <epoch>]
#   review-availability.sh mark-skip [--repo <owner/name>] --pr <N> --head <sha> --reason <text>
#   review-availability.sh check-skip --repo <owner/name> --pr <N> --head <sha> --window-s <s> [--now <epoch>]
#   review-availability.sh observe [--repo <owner/name>] < reviews.json
#   review-availability.sh --help
#   observe     — clears a reviewer's record once a completed, non-notice review by that bot
#                 is newer than the record's read time (the account is answering again).
#
# SETTINGS (expected response time from a request to a free reviewer's review, minutes)
#   REVIEW_EXPECTED_RESPONSE_CODEANT_MIN     default 4   (2026-11-11 baseline median)
#   REVIEW_EXPECTED_RESPONSE_CODERABBIT_MIN  default 5   (2026-11-11 baseline median)
#   Each must be an integer 1-120; anything else falls back to its default.
#
# OUTPUT (stdout, one JSON line)
#   record:     {written: [..], kept: [..]} — reviewers whose record was written / kept.
#   decide:     {skip, reason, until_epoch, until_iso, window_seconds, now, expected_s, reviewers}
#               reason: "no_reviewer_available_until <ISO>" when skip, else "request".
#   check-skip: {applies, reason, head_match}
#
# EXIT STATUS
#   0 answer printed (decide/check-skip: an unreadable state reads as skip=false).
#   2 usage. 4 unusable input (malformed comments JSON). 5 state read or write failed.
#   Callers treat any non-zero exit as "no skip": fail toward asking.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$SCRIPT_DIR/lib"
STATE="$SCRIPT_DIR/session-state.sh"
CR_WINDOW_CAP_SECONDS=3600

print_usage() { sed -n '2,/^set -uo/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'; }
die() { printf 'review-availability.sh: %s\n' "$2" >&2; exit "$1"; }

# expected_seconds <env value> <default minutes> -> seconds (integer 1-120 minutes, else the default).
expected_seconds() {
  local v="$1" d="$2"
  case "$v" in
    ''|*[!0-9]*) v="$d" ;;
  esac
  if (( 10#$v < 1 || 10#$v > 120 )); then v="$d"; fi
  echo $(( 10#$v * 60 ))
}

# state_get <jq path> [--repo r] -> JSON on stdout; non-zero when unreadable.
state_get() {
  local path="$1" repo="$2" out rc=0
  if [[ -n "$repo" ]]; then
    out="$("$STATE" --repo "$repo" --get-json "$path" 2>/dev/null)" || rc=$?
  else
    out="$("$STATE" --raw-path --get-json "$path" 2>/dev/null)" || rc=$?
  fi
  # Exit 3 = no state file yet: nothing is recorded, which reads as an absent slot.
  if (( rc == 3 )); then out="null"; rc=0; fi
  (( rc == 0 )) || return 1
  [[ -n "$out" ]] || out="null"
  printf '%s' "$out" | jq . >/dev/null 2>&1 || return 1  # parse check only: a stored null is a valid answer
  printf '%s' "$out"
}

valid_repo() { [[ "$1" =~ ^[^/[:space:]]+/[^/[:space:]]+$ ]]; }

cmd_record() {
  local repo="" pr="" comments now now_iso items item key usable new unr old keep attempt outcome rc
  local written="" kept="" cleared=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --repo) [[ $# -ge 2 ]] || die 2 "--repo needs a value"; repo="$2"; shift 2 ;;
      --pr) [[ $# -ge 2 ]] || die 2 "--pr needs a value"; pr="$2"; shift 2 ;;
      *) die 2 "record: unknown argument: $1" ;;
    esac
  done
  [[ -z "$repo" ]] || valid_repo "$repo" || die 2 "--repo must be owner/name"
  [[ "$pr" =~ ^[0-9]+$ ]] || die 2 "--pr must be a PR number"
  comments="$(cat)"
  printf '%s' "$comments" | jq -e 'type == "array" and all(.[]; type == "object")' >/dev/null 2>&1 \
    || die 4 "issue comments are not a JSON array of objects — nothing recorded"
  now="$(date +%s)"
  now_iso="$(jq -rn --argjson n "$now" '$n | todateiso8601')"
  # One item per reviewer whose NEWEST notice is present. A usable newest notice carries
  # its record; an unusable one (no readable window, or over the cap) carries only its
  # time, so its slot is cleared unless a newer notice already holds it (fail toward asking).
  items="$(printf '%s' "$comments" | jq -c -L "$LIB_DIR" \
    --arg repo "${repo:-unknown}" --argjson pr "$pr" --arg now_iso "$now_iso" --argjson cap "$CR_WINDOW_CAP_SECONDS" '
    include "cr-retry-window";
    def reviewers: [
      {key: "coderabbit", login: "coderabbitai[bot]", notice: "review limit reached|<!--[^>]*rate[- ]?limited by coderabbit\\.ai"},
      {key: "codeant", login: "codeant-ai[bot]", notice: "review limit reached|usage limit|rate limit"}
    ];
    def notice_epoch: [ (.created_at | cr_iso_epoch), (.updated_at | cr_iso_epoch) ] | map(select(. != null)) | max;
    [ reviewers[] as $r
      | ([ .[] | select((.user.login // "") == $r.login)
              | select((.body // "") | type == "string" and test($r.notice; "i"))
              | {t: notice_epoch, body: .body} | select(.t != null) ] | sort_by(.t) | last) as $n
      | select($n != null)
      | ($n.body | cr_retry_window_seconds) as $w
      | if ($w > 0 and $w <= $cap) then
          {key: $r.key, usable: true, value: {
            next_available_epoch: ($n.t + $w),
            next_available: (($n.t + $w) | todateiso8601),
            notice_epoch: $n.t,
            notice_at: ($n.t | todateiso8601),
            window_seconds: $w,
            notice_excerpt: ($n.body | cr_retry_capture | .s | .[0:200]),
            source_repo: $repo,
            source_pr: $pr,
            read_at: $now_iso}}
        else
          {key: $r.key, usable: false, notice_epoch: $n.t}
        end
    ]')" || die 4 "could not evaluate the notice parser"
  while IFS= read -r item; do
    [[ -n "$item" ]] || continue
    key="$(jq -r '.key' <<<"$item")"
    usable="$(jq -r '.usable' <<<"$item")"
    if [[ "$usable" == true ]]; then
      new="$(jq -c '.value' <<<"$item")"
      unr="null"
    else
      new="null"
      unr="$(jq -c '.notice_epoch' <<<"$item")"
    fi
    outcome=""
    for attempt in 1 2 3 4 5; do
      old="$(state_get ".review_availability.$key" "")" || die 5 "could not read the existing $key record — nothing written"
      # A newer statement already on file (another PR, same account) outranks this notice.
      # A tombstone left by observe (the reviewer answered after this notice) keeps a notice no
      # newer than the one it cleared from being written again on the next run.
      keep="$(jq -rn --argjson o "$old" --argjson n "$new" --argjson u "$unr" '
        if ($o | type) == "object" and (($o.cleared_notice_epoch | type) == "number")
           and (if $n == null then $u <= $o.cleared_notice_epoch
                else $n.notice_epoch <= $o.cleared_notice_epoch end) then "same"
        elif $n == null then
          (if ($o | type) != "object" then "same"
           elif (($o.notice_epoch | type) == "number") and ($o.notice_epoch > $u) then "newer"
           else "write" end)
        elif ($o | type) == "object" and (($o.notice_epoch | type) == "number") and $o.notice_epoch > $n.notice_epoch then "newer"
        elif ($o | type) == "object" and $o.notice_epoch == $n.notice_epoch and $o.next_available_epoch == $n.next_available_epoch then "same"
        else "write" end')"
      if [[ "$keep" != "write" ]]; then
        outcome="$keep"
        break
      fi
      # Compare-and-set under the state lock: a concurrent writer that won (exit 7) is re-read.
      rc=0
      "$STATE" --raw-path --cas ".review_availability.$key=$new" --expect "$old" >/dev/null 2>&1 || rc=$?
      if (( rc == 0 )); then
        outcome="wrote"
        break
      fi
      (( rc == 7 )) || die 5 "could not write the $key availability record"
    done
    case "$outcome" in
      wrote) if [[ "$new" == null ]]; then cleared="$cleared $key"; else written="$written $key"; fi ;;
      same|newer) kept="$kept $key" ;;
      *) die 5 "could not settle the $key availability record after retries — nothing written" ;;
    esac
  done <<<"$(jq -c '.[]' <<<"$items")"
  jq -cn --arg w "$written" --arg k "$kept" --arg c "$cleared" \
    '{written: ($w | split(" ") | map(select(length > 0))),
      kept: ($k | split(" ") | map(select(length > 0))),
      cleared: ($c | split(" ") | map(select(length > 0)))}'
}

# cr_cap_spent -> "1" when cr-review-hourly.sh --check reports CodeRabbit's hourly budget
# spent (exit 1), else "0". An unreadable or missing helper reads as not spent: the request
# path then stays as it was (fail toward asking, never a silent skip of CodeRabbit's cap).
cr_cap_spent() {
  local h="${SCRIPT_DIR}/cr-review-hourly.sh" rc=0
  [[ -x "$h" ]] || { echo 0; return 0; }
  "$h" --check >/dev/null 2>&1 || rc=$?
  if (( rc == 1 )); then echo 1; else echo 0; fi
}

# decide_json <repo or ""> <window seconds> <now epoch> [no-coderabbit 0|1]
# One evaluation shared by decide, check-skip and choose (issue #2257). Per free reviewer:
#   avail  = the later of its limit-notice return time (usable records only), the end of
#            the queue of requests recently sent to it (each takes its expected response
#            time; a limited reviewer's queue starts at its return time), and now;
#   answer = avail + its expected response time;
#   eligible = no usable limit notice keeps it out past the window, and CodeRabbit's hourly
#            budget is not spent; the queue and expected time only rank eligible reviewers
#            (cr-review-hourly.sh) and it is not excluded.
# Skip = no reviewer is eligible. Unusable records are not a limit (fail toward asking).
decide_json() {
  local repo="$1" win="$2" now="$3" nocr="${4:-0}" recs reqs ecr ecd capspent cr_why=""
  recs="$(state_get '.review_availability' "$repo")" \
    || { jq -cn '{skip: false, reviewer: "codeant", reason: "request", why: "state_unreadable",
                  choice_reason: "state_unreadable"}'; return 0; }
  reqs="$(state_get '.review_requests' "")" || reqs="[]"
  ecr="$(expected_seconds "${REVIEW_EXPECTED_RESPONSE_CODERABBIT_MIN:-}" 5)"
  ecd="$(expected_seconds "${REVIEW_EXPECTED_RESPONSE_CODEANT_MIN:-}" 4)"
  capspent="$(cr_cap_spent)"
  if [[ "$nocr" == 1 ]]; then cr_why="excluded"; elif [[ "$capspent" == 1 ]]; then cr_why="hourly_cap_spent"; fi
  jq -cn --argjson rec "$recs" --argjson reqs "$reqs" --argjson now "$now" --argjson win "$win" \
    --argjson ecr "$ecr" --argjson ecd "$ecd" --arg crwhy "$cr_why" '
    def usable($x): ($x | type) == "object" and (($x.next_available_epoch | type) == "number")
      and (($x.notice_epoch | type) == "number") and (($x.window_seconds | type) == "number")
      and ($x.window_seconds > 0);
    def expo($k): if $k == "coderabbit" then $ecr else $ecd end;
    def recent($k): [ (if ($reqs | type) == "array" then $reqs[] else empty end)
      | select((.reviewer // "") == $k)
      | select(((.at_epoch // 0) | type) == "number" and .at_epoch > ($now - 3600)) | .at_epoch ] | sort;
    # Requests to one reviewer run one after another: the next one can start once the last
    # has had its expected response time. A limited reviewer starts its queue at the limit
    # return, so requests logged before the notice drain only after it lifts.
    def queue_end($k; $start): reduce recent($k)[] as $t ($start; ([., $t] | max) + expo($k));
    def lane($k; $cap_why):
      ($rec | if type == "object" then .[$k] else null end) as $x
      | (if usable($x) then (if $x.next_available_epoch <= $now then "record_past" else "limited" end)
         else "no_record" end) as $state
      | (if $state == "limited" then $x.next_available_epoch else $now end) as $rec_avail
      | queue_end($k; (if $state == "limited" then $x.next_available_epoch else 0 end)) as $queue
      | ([$rec_avail, $queue, $now] | max) as $avail
      | ($avail + expo($k)) as $answer
      # Only a real limit notice (or the spent CodeRabbit hourly budget) makes a reviewer
      # ineligible. The queue of logged requests and the expected response time only rank
      # the eligible reviewers: they are estimates, and an estimate must never skip a review
      # (fail toward asking). Without this, several PRs going green together, or a window
      # shorter than the expected response time, would skip review with no limit at all.
      | (($state == "limited") and (($x.next_available_epoch + expo($k)) > ($now + $win))) as $limited_out
      | (($cap_why == "") and ($limited_out | not)) as $eligible
      | { blocked: ($eligible | not),
          next: (if $state == "limited" then $x.next_available_epoch else null end),
          avail: $avail, answer: $answer, recent: (recent($k) | length), eligible: $eligible,
          why: (if $cap_why != "" then $cap_why
                elif $limited_out then "limited"
                elif $state == "limited" then "answers_within_window"
                elif $answer > ($now + $win) then "busy_but_asked"
                else $state end) };
    lane("coderabbit"; $crwhy) as $a | lane("codeant"; "") as $b
    | [ (if $a.eligible then {r: "coderabbit", x: $a} else empty end),
        (if $b.eligible then {r: "codeant", x: $b} else empty end) ] as $c
    | if ($c | length) == 0 then
        # Only a limit notice gives a real return time; a cap-spent reviewer has none, so the
        # skip lifts at the earliest notice return, or in an hour when only the cap holds.
        ([ ($a, $b) | select(.next != null) | .next ] | min // ($now + 3600)) as $u
        | {skip: true, reviewer: null, reason: ("no_reviewer_available_until " + ($u | todateiso8601)),
           choice_reason: "no_free_reviewer_answers_in_window", until_epoch: $u,
           until_iso: ($u | todateiso8601)}
      else
        ($c | sort_by([.x.answer, .x.recent, (if .r == "codeant" then 0 else 1 end)])) as $s
        | $s[0] as $w
        | (if ($s | length) == 1 then "only_" + $w.r + "_can_answer"
           elif $s[1].x.answer != $w.x.answer then "earliest_answer"
           elif $s[1].x.recent != $w.x.recent then "tie_fewer_recent_requests"
           else "tie_order" end) as $why_pick
        | {skip: false, reviewer: $w.r, reason: "request", choice_reason: $why_pick}
      end
    | . + {window_seconds: $win, now: $now, expected_s: {coderabbit: $ecr, codeant: $ecd},
           reviewers: {coderabbit: $a, codeant: $b}}'
}

cmd_decide() {
  local repo="" win="" now=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --repo) [[ $# -ge 2 ]] || die 2 "--repo needs a value"; repo="$2"; shift 2 ;;
      --window-s) [[ $# -ge 2 ]] || die 2 "--window-s needs a value"; win="$2"; shift 2 ;;
      --now) [[ $# -ge 2 ]] || die 2 "--now needs a value"; now="$2"; shift 2 ;;
      *) die 2 "decide: unknown argument: $1" ;;
    esac
  done
  [[ -z "$repo" ]] || valid_repo "$repo" || die 2 "--repo must be owner/name"
  [[ "$win" =~ ^[0-9]+$ ]] && (( win > 0 )) || die 2 "--window-s must be a positive integer"
  [[ -n "$now" ]] || now="$(date +%s)"
  [[ "$now" =~ ^[0-9]+$ ]] || die 2 "--now must be an epoch"
  decide_json "$repo" "$win" "$now"
}

cmd_mark_skip() {
  local repo="" pr="" head="" reason="" rec now_iso
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --repo) [[ $# -ge 2 ]] || die 2 "--repo needs a value"; repo="$2"; shift 2 ;;
      --pr) [[ $# -ge 2 ]] || die 2 "--pr needs a value"; pr="$2"; shift 2 ;;
      --head) [[ $# -ge 2 ]] || die 2 "--head needs a value"; head="$2"; shift 2 ;;
      --reason) [[ $# -ge 2 ]] || die 2 "--reason needs a value"; reason="$2"; shift 2 ;;
      *) die 2 "mark-skip: unknown argument: $1" ;;
    esac
  done
  [[ -z "$repo" ]] || valid_repo "$repo" || die 2 "--repo must be owner/name"
  [[ "$pr" =~ ^[0-9]+$ ]] || die 2 "--pr must be a PR number"
  [[ -n "$head" && -n "$reason" ]] || die 2 "--head and --reason are required"
  now_iso="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  rec="$(jq -cn --arg h "$head" --arg r "$reason" --arg t "$now_iso" \
    '{head_sha: $h, reason: $r, recorded_at: $t}')"
  # Keyed by HEAD SHA (CodeAnt #4546742968): a late write for an older HEAD adds its own
  # entry and can never replace the current HEAD's skip.
  if [[ -n "$repo" ]]; then
    "$STATE" --repo "$repo" --set ".prs[\"$pr\"].review_request_skips[\"$head\"]=$rec" >/dev/null 2>&1 \
      || die 5 "could not record the request skip on PR $pr"
  else
    "$STATE" --set ".prs[\"$pr\"].review_request_skips[\"$head\"]=$rec" >/dev/null 2>&1 \
      || die 5 "could not record the request skip on PR $pr"
  fi
  jq -cn --arg h "$head" --arg r "$reason" '{recorded: true, head_sha: $h, reason: $r}'
}

cmd_check_skip() {
  local repo="" pr="" head="" win="" now="" dec skip_rec head_match="false" applies="false" reason=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --repo) [[ $# -ge 2 ]] || die 2 "--repo needs a value"; repo="$2"; shift 2 ;;
      --pr) [[ $# -ge 2 ]] || die 2 "--pr needs a value"; pr="$2"; shift 2 ;;
      --head) [[ $# -ge 2 ]] || die 2 "--head needs a value"; head="$2"; shift 2 ;;
      --window-s) [[ $# -ge 2 ]] || die 2 "--window-s needs a value"; win="$2"; shift 2 ;;
      --now) [[ $# -ge 2 ]] || die 2 "--now needs a value"; now="$2"; shift 2 ;;
      *) die 2 "check-skip: unknown argument: $1" ;;
    esac
  done
  valid_repo "$repo" || die 2 "--repo must be owner/name"
  [[ "$pr" =~ ^[0-9]+$ ]] || die 2 "--pr must be a PR number"
  [[ -n "$head" ]] || die 2 "--head is required"
  [[ "$win" =~ ^[0-9]+$ ]] && (( win > 0 )) || die 2 "--window-s must be a positive integer"
  [[ -n "$now" ]] || now="$(date +%s)"
  [[ "$now" =~ ^[0-9]+$ ]] || die 2 "--now must be an epoch"
  dec="$(decide_json "$repo" "$win" "$now")"
  reason="$(jq -r '.reason' <<<"$dec")"
  skip_rec="$(state_get ".prs[\"$pr\"].review_request_skips[\"$head\"]" "$repo")" \
    || { jq -cn '{applies: false, reason: "state_unreadable", head_match: false}'; return 0; }
  if [[ "$(jq -r --arg h "$head" '(type == "object") and (.head_sha == $h)' <<<"$skip_rec")" == true ]]; then
    head_match="true"
  fi
  if [[ "$head_match" == true && "$(jq -r '.skip' <<<"$dec")" == true ]]; then
    applies="true"
  fi
  jq -cn --argjson a "$applies" --argjson h "$head_match" --arg r "$reason" \
    '{applies: $a, reason: $r, head_match: $h}'
}

# cmd_observe --repo <owner/name> < reviews.json
# Clears a free reviewer's availability record when a completed review by that bot is
# newer than the record's read time and is not itself a limit notice (issue #2256).
# CodeRabbit's allowance is account-wide, so such a review shows it is answering again
# and the stale wait must not keep blocking a request or a green-HEAD override. Only a
# review object is evidence here: a notice edited in place is not (a known residual).
cmd_observe() {
  local repo="" reviews recs cleared="" key login notice rec read_epoch answered tomb
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --repo) [[ $# -ge 2 ]] || die 2 "--repo needs a value"; repo="$2"; shift 2 ;;
      *) die 2 "observe: unknown argument: $1" ;;
    esac
  done
  [[ -z "$repo" ]] || valid_repo "$repo" || die 2 "--repo must be owner/name"
  reviews="$(cat)"
  printf '%s' "$reviews" | jq -e 'type == "array" and all(.[]; type == "object")' >/dev/null 2>&1 \
    || die 4 "reviews are not a JSON array of objects — nothing cleared"
  recs="$(state_get '.review_availability' "$repo")" || die 5 "could not read the review availability records"
  if [[ "$(jq -r 'type' <<<"$recs")" != object ]]; then
    jq -cn '{cleared: []}'
    return 0
  fi
  for key in coderabbit codeant; do
    if [[ "$key" == coderabbit ]]; then
      login="coderabbitai[bot]"; notice="review limit reached|<!--[^>]*rate[- ]?limited by coderabbit\\.ai"
    else
      login="codeant-ai[bot]"; notice="review limit reached|usage limit|rate limit"
    fi
    outcome=""
    # Compare-and-set against the record this pass read: a newer notice written meanwhile
    # (exit 7) is re-read and re-judged, so the clear can never erase a newer record.
    for attempt in 1 2 3 4 5; do
      recs_now="$(state_get '.review_availability' "$repo")" || die 5 "could not re-read the review availability records"
      rec="$(jq -c --arg k "$key" 'if type == "object" then (.[$k] // null) else null end' <<<"$recs_now")"
      if [[ "$(jq -r 'type' <<<"$rec")" != object ]]; then outcome="none"; break; fi
      read_epoch="$(jq -r '(.read_at // "") | fromdateiso8601? // empty' <<<"$rec")"
      # An unreadable read time already reads as "no record" in decide: nothing to clear.
      if ! [[ "$read_epoch" =~ ^[0-9]+$ ]]; then outcome="unreadable"; break; fi
      answered="$(jq -r --arg l "$login" --argjson rd "$read_epoch" --arg n "$notice" '
        [ .[] | select((.user.login // "") == $l)
               | select((.submitted_at // "") | type == "string" and . != "")
               | select(((.submitted_at | fromdateiso8601?) // 0) > $rd)
               | select(((.state // "") == "APPROVED")
                        or (((.body // "") | type == "string") and ((.body // "") | test($n; "i") | not))) ]
        | length > 0' <<<"$reviews")" || die 4 "could not evaluate the review objects — nothing cleared"
      if [[ "$answered" != true ]]; then outcome="kept"; break; fi
      # Clear to a tombstone, not null: record re-reads every notice still in the PR on each
      # run, and a null slot would let it rewrite this already-answered notice with a fresh
      # read time, which observe could then never clear again.
      tomb="$(jq -c --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        '{cleared_notice_epoch: .notice_epoch, cleared_at: $at, next_available: null}' <<<"$rec")" \
        || die 4 "could not build the $key tombstone — nothing cleared"
      rc=0
      "$STATE" --raw-path --cas ".review_availability.$key=$tomb" --expect "$rec" >/dev/null 2>&1 || rc=$?
      if (( rc == 0 )); then outcome="cleared"; break; fi
      (( rc == 7 )) || die 5 "could not clear the $key availability record"
    done
    case "$outcome" in
      cleared) cleared="$cleared $key" ;;
      none|unreadable|kept) ;;
      *) die 5 "could not settle the $key availability record after retries — nothing cleared" ;;
    esac
  done
  jq -cn --arg c "$cleared" '{cleared: ($c | split(" ") | map(select(length > 0)))}'
}

# cmd_choose: which free reviewer to ask for this HEAD (issue #2257). Read-only: the
# decision uses decide_json, so a skip here is the same skip decide and check-skip report.
# Output: decide's JSON plus `reviewer` ("coderabbit" | "codeant" | null) and `choice_reason`.
cmd_choose() {
  local repo="" win="" now="" nocr=0 dec
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --repo) [[ $# -ge 2 ]] || die 2 "--repo needs a value"; repo="$2"; shift 2 ;;
      --window-s) [[ $# -ge 2 ]] || die 2 "--window-s needs a value"; win="$2"; shift 2 ;;
      --now) [[ $# -ge 2 ]] || die 2 "--now needs a value"; now="$2"; shift 2 ;;
      --no-coderabbit) nocr=1; shift ;;
      *) die 2 "choose: unknown argument: $1" ;;
    esac
  done
  [[ -z "$repo" ]] || valid_repo "$repo" || die 2 "--repo must be owner/name"
  [[ "$win" =~ ^[0-9]+$ ]] && (( win > 0 )) || die 2 "--window-s must be a positive integer"
  [[ -n "$now" ]] || now="$(date +%s)"
  [[ "$now" =~ ^[0-9]+$ ]] || die 2 "--now must be an epoch"
  dec="$(decide_json "$repo" "$win" "$now" "$nocr")"
  jq -c '. + {reviewer: (.reviewer // "codeant")} | if .skip then .reviewer = null else . end' <<<"$dec"
}

# cmd_record_request: log one request sent to a free reviewer (issue #2257). Appends to the
# account-wide `.review_requests` log (entries older than an hour are pruned) and records the
# choice on the PR under `review_request_choices[<head>]`. Called only after the post succeeded.
cmd_record_request() {
  local repo="" pr="" head="" reviewer="" reason="" detail="{}" now="" now_iso="" entry="" old="" new="" rec="" attempt rc=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --repo) [[ $# -ge 2 ]] || die 2 "--repo needs a value"; repo="$2"; shift 2 ;;
      --pr) [[ $# -ge 2 ]] || die 2 "--pr needs a value"; pr="$2"; shift 2 ;;
      --head) [[ $# -ge 2 ]] || die 2 "--head needs a value"; head="$2"; shift 2 ;;
      --reviewer) [[ $# -ge 2 ]] || die 2 "--reviewer needs a value"; reviewer="$2"; shift 2 ;;
      --reason) [[ $# -ge 2 ]] || die 2 "--reason needs a value"; reason="$2"; shift 2 ;;
      --detail) [[ $# -ge 2 ]] || die 2 "--detail needs a value"; detail="$2"; shift 2 ;;
      --now) [[ $# -ge 2 ]] || die 2 "--now needs a value"; now="$2"; shift 2 ;;
      *) die 2 "record-request: unknown argument: $1" ;;
    esac
  done
  [[ -z "$repo" ]] || valid_repo "$repo" || die 2 "--repo must be owner/name"
  [[ "$pr" =~ ^[0-9]+$ ]] || die 2 "--pr must be a PR number"
  [[ -n "$head" && -n "$reason" ]] || die 2 "--head and --reason are required"
  case "$reviewer" in coderabbit|codeant) ;; *) die 2 "--reviewer must be coderabbit or codeant" ;; esac
  printf '%s' "$detail" | jq -e 'type == "object"' >/dev/null 2>&1 || die 2 "--detail must be a JSON object"
  [[ -n "$now" ]] || now="$(date +%s)"
  [[ "$now" =~ ^[0-9]+$ ]] || die 2 "--now must be an epoch"
  now_iso="$(jq -rn --argjson n "$now" '$n | todateiso8601')"
  entry="$(jq -cn --arg r "$reviewer" --argjson at "$now" --arg iso "$now_iso" --argjson pr "$pr" \
    --arg h "$head" --arg why "$reason" \
    '{reviewer: $r, at_epoch: $at, at: $iso, pr: $pr, head_sha: $h, reason: $why}')"
  for attempt in 1 2 3 4 5; do
    old="$(state_get '.review_requests' "")" || die 5 "could not read the request log — nothing recorded"
    new="$(jq -c --argjson e "$entry" --argjson now "$now" '
      [ (if type == "array" then .[] else empty end)
        | select(((.at_epoch // 0) | type) == "number" and .at_epoch > ($now - 3600)) ] + [$e]' <<<"$old")" \
      || die 5 "could not build the request log — nothing recorded"
    rc=0
    "$STATE" --raw-path --cas ".review_requests=$new" --expect "$old" >/dev/null 2>&1 || rc=$?
    if (( rc == 0 )); then break; fi
    (( rc == 7 )) || die 5 "could not write the request log — nothing recorded"
    if (( attempt == 5 )); then die 5 "could not settle the request log after retries — nothing recorded"; fi
  done
  rec="$(jq -cn --arg r "$reviewer" --arg why "$reason" --arg t "$now_iso" --argjson d "$detail" \
    '{reviewer: $r, reason: $why, recorded_at: $t, detail: $d}')"
  if [[ -n "$repo" ]]; then
    "$STATE" --repo "$repo" --set ".prs[\"$pr\"].review_request_choices[\"$head\"]=$rec" >/dev/null 2>&1 \
      || die 5 "could not record the reviewer choice on PR $pr"
  else
    "$STATE" --set ".prs[\"$pr\"].review_request_choices[\"$head\"]=$rec" >/dev/null 2>&1 \
      || die 5 "could not record the reviewer choice on PR $pr"
  fi
  jq -cn --arg r "$reviewer" --arg h "$head" '{recorded: true, reviewer: $r, head_sha: $h}'
}

case "${1:-}" in
  -h|--help) print_usage; exit 0 ;;
  record) shift; cmd_record "$@" ;;
  decide) shift; cmd_decide "$@" ;;
  choose) shift; cmd_choose "$@" ;;
  record-request) shift; cmd_record_request "$@" ;;
  mark-skip) shift; cmd_mark_skip "$@" ;;
  check-skip) shift; cmd_check_skip "$@" ;;
  observe) shift; cmd_observe "$@" ;;
  "") die 2 "missing subcommand (record|decide|choose|record-request|mark-skip|check-skip|observe)" ;;
  *) die 2 "unknown subcommand: $1" ;;
esac
