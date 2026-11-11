#!/usr/bin/env bash
# catalog: backlog-pm — Read or compare-and-set one PM dispatcher's unclaimed standing refill queue
#
# read REPO SESSION prints the ordered plan record, or JSON null if absent.
# save REPO SESSION LIMIT takes {"expect":<prior record or null>,"issues":[...]}
# on stdin. An empty issues array retires the plan with a new generation.
# Both operations return the current record. A plan never claims or launches an issue.
# Exit 2: usage, 5: unreadable/invalid state, 7: stale plan or lost CAS.
set -euo pipefail

usage() {
  printf '%s\n' 'Usage: pm-standing-queue.sh read REPO SESSION | save REPO SESSION LIMIT'
}
if [[ "${1:-}" == --help || "${1:-}" == -h ]]; then usage; exit 0; fi
fail() {
  printf 'pm-standing-queue: %s\n' "$2" >&2
  exit "$1"
}
verb="${1:-}"
repo="${2:-}"
session="${3:-}"
limit="${4:-}"
case "$verb:$#" in
  read:3) ;;
  save:4) [[ "$limit" =~ ^[1-9][0-9]{0,6}$ ]] || { usage >&2; exit 2; } ;;
  *) usage >&2; exit 2 ;;
esac
[[ "$repo" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || { usage >&2; exit 2; }
[[ "$session" =~ ^[A-Za-z0-9_.:-]+$ && "$session" != default && "$session" != null ]] || { usage >&2; exit 2; }

scripts="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
state="$scripts/session-state.sh"
repo=$("$state" --repo "$repo" --repo-key) || fail 5 'cannot verify repo identity'
[[ "$repo" =~ ^[a-z0-9_.-]+/[a-z0-9_.-]+$ ]] || fail 5 'invalid repo identity'
path=".repos[\"$repo\"].pm_standing_queues"
rc=0
plans=$("$state" --repo "$repo" --get-json "$path" 2>/dev/null) || rc=$?
case "$rc" in
  0) ;;
  3) plans=null ;;
  *) fail 5 'queue state is unreadable' ;;
esac

record=$(jq -ce -L "$scripts/lib" --arg session "$session" '
  include "pm-standing-queue";
  if . == null then null
  elif type != "object" then error("invalid queue map")
  else .[$session] | if . == null or pm_queue_record then . else error("invalid plan") end
  end' <<<"$plans" 2>/dev/null) || {
  # jq -e returns 1 for a known absent record.
  [[ "$record" == null ]] || fail 5 'queue state is malformed'
}
if [[ "$verb" == read ]]; then
  printf '%s\n' "$record"
  exit 0
fi

request=$(jq -cse -L "$scripts/lib" --argjson limit "$limit" '
  include "pm-standing-queue";
  if length == 1 and (.[0] | type == "object" and has("expect") and has("issues")
    and (.expect | . == null or pm_queue_record)
    and (.issues | pm_issue_numbers and length <= $limit and . == pm_unique_order))
  then .[0] else error("invalid queue update") end' 2>/dev/null) || fail 2 'invalid queue update'
jq -e --argjson record "$record" '.expect == $record' <<<"$request" >/dev/null ||
  fail 7 'standing queue changed; re-read it before the next evaluation'
issues=$(jq -c '.issues' <<<"$request")
if jq -e --argjson issues "$issues" '($issues | length) > 0 and . != null and .issues == $issues' <<<"$record" >/dev/null; then
  printf '%s\n' "$record"
  exit 0
fi

# Every retirement advances the generation. A delayed writer cannot publish
# from a snapshot taken before retirement, including an already-empty plan.
epoch=$(date +%s) || fail 5 'could not generate a queue update identity'
next=$(jq -cn --arg generation "$epoch:$$:$RANDOM:$RANDOM" --argjson issues "$issues" \
  '{generation:$generation,issues:$issues}')
updated=$(jq -c --arg session "$session" --argjson next "$next"   '(. // {}) | .[$session]=$next' <<<"$plans")
rc=0
"$state" --repo "$repo" --cas "$path=$updated" --expect "$plans" >/dev/null || rc=$?
case "$rc" in
  0) printf '%s\n' "$next" ;;
  7) fail 7 'standing queue changed during publication; previous plan retained' ;;
  *) fail 5 'could not persist the standing queue' ;;
esac
