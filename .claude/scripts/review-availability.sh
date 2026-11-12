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
#   review-availability.sh mark-skip [--repo <owner/name>] --pr <N> --head <sha> --reason <text>
#   review-availability.sh check-skip --repo <owner/name> --pr <N> --head <sha> --window-s <s> [--now <epoch>]
#   review-availability.sh --help
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
  local repo="" pr="" comments now now_iso recs key new old keep
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
  # The newest notice per reviewer decides; an unparseable newest notice writes nothing (never an older one's time).
  recs="$(printf '%s' "$comments" | jq -c -L "$LIB_DIR" \
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
      | select($w > 0 and $w <= $cap)
      | {key: $r.key, value: {
          next_available_epoch: ($n.t + $w),
          next_available: (($n.t + $w) | todateiso8601),
          notice_epoch: $n.t,
          notice_at: ($n.t | todateiso8601),
          window_seconds: $w,
          notice_excerpt: ($n.body | cr_retry_capture | .s | .[0:200]),
          source_repo: $repo,
          source_pr: $pr,
          read_at: $now_iso}}
    ] | from_entries')" || die 4 "could not evaluate the notice parser"
  local written="" kept=""
  while IFS= read -r key; do
    [[ -n "$key" ]] || continue
    new="$(jq -c --arg k "$key" '.[$k]' <<<"$recs")"
    old="$(state_get ".review_availability.$key" "")" || die 5 "could not read the existing $key record — nothing written"
    # A newer statement already on file (another PR, same account) outranks this older notice.
    keep="$(jq -rn --argjson o "$old" --argjson n "$new" '
      if ($o | type) == "object" and (($o.notice_epoch | type) == "number") and $o.notice_epoch > $n.notice_epoch then "newer"
      elif ($o | type) == "object" and $o.notice_epoch == $n.notice_epoch and $o.next_available_epoch == $n.next_available_epoch then "same"
      else "write" end')"
    if [[ "$keep" == "write" ]]; then
      "$STATE" --raw-path --set ".review_availability.$key=$new" >/dev/null 2>&1 \
        || die 5 "could not write the $key availability record"
      written="$written $key"
    else
      kept="$kept $key"
    fi
  done <<<"$(jq -r 'keys[]' <<<"$recs")"
  jq -cn --arg w "$written" --arg k "$kept" '{written: ($w | split(" ") | map(select(length > 0))),
                                             kept: ($k | split(" ") | map(select(length > 0)))}'
}

# decide_json <repo or ""> <window seconds> <now epoch>
decide_json() {
  local repo="$1" win="$2" now="$3" recs ecr ecd
  recs="$(state_get '.review_availability' "$repo")" \
    || { jq -cn '{skip: false, reason: "request", why: "state_unreadable"}'; return 0; }
  ecr="$(expected_seconds "${REVIEW_EXPECTED_RESPONSE_CODERABBIT_MIN:-}" 5)"
  ecd="$(expected_seconds "${REVIEW_EXPECTED_RESPONSE_CODEANT_MIN:-}" 4)"
  jq -cn --argjson rec "$recs" --argjson now "$now" --argjson win "$win" \
    --argjson ecr "$ecr" --argjson ecd "$ecd" '
    # blocked: a usable record says this reviewer cannot answer inside the window.
    # Anything unusable is NOT blocked (fail toward asking).
    def lim($key; $exp):
      ($rec | if type == "object" then .[$key] else null end) as $x
      | if ($x | type) != "object" or (($x.next_available_epoch | type) != "number") then {blocked: false, why: "no_record"}
        elif $x.next_available_epoch <= $now then {blocked: false, why: "record_past"}
        elif ($x.next_available_epoch + $exp) > ($now + $win) then {blocked: true, next: $x.next_available_epoch, why: "limited"}
        else {blocked: false, why: "answers_within_window"} end;
    lim("coderabbit"; $ecr) as $a | lim("codeant"; $ecd) as $b
    | if $a.blocked and $b.blocked then
        ([$a.next, $b.next] | min) as $u
        | {skip: true, reason: ("no_reviewer_available_until " + ($u | todateiso8601)), until_epoch: $u,
           until_iso: ($u | todateiso8601)}
      else {skip: false, reason: "request"} end
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
  if [[ -n "$repo" ]]; then
    "$STATE" --repo "$repo" --set ".prs[\"$pr\"].review_request_skip=$rec" >/dev/null 2>&1 \
      || die 5 "could not record the request skip on PR $pr"
  else
    "$STATE" --set ".prs[\"$pr\"].review_request_skip=$rec" >/dev/null 2>&1 \
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
  skip_rec="$(state_get ".prs[\"$pr\"].review_request_skip" "$repo")" \
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

case "${1:-}" in
  -h|--help) print_usage; exit 0 ;;
  record) shift; cmd_record "$@" ;;
  decide) shift; cmd_decide "$@" ;;
  mark-skip) shift; cmd_mark_skip "$@" ;;
  check-skip) shift; cmd_check_skip "$@" ;;
  "") die 2 "missing subcommand (record|decide|mark-skip|check-skip)" ;;
  *) die 2 "unknown subcommand: $1" ;;
esac
