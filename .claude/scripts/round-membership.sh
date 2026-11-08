#!/usr/bin/env bash
# catalog: scheduling-monitoring — Reads a session's ordered round or an observer union without replacing another dispatch
# Usage: round-membership.sh --repo OWNER/REPO --session ID [--state-helper PATH]
# Output: {members: [issue strings] | null, scope: own|observer|legacy|none}.
# Read-only state access; null tombstones shadow attributed legacy singletons.
# Exit 0: typed result (including known absence); 2: usage; 4: missing dependency;
# 5: unreadable/malformed state. Unknown state is never an invented empty round.
set -euo pipefail
repo=""; session=""; state_helper="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/session-state.sh"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo|--session|--state-helper)
      [[ $# -ge 2 ]] || exit 2
      case "$1" in --repo) repo="$2" ;; --session) session="$2" ;; --state-helper) state_helper="$2" ;; esac
      shift 2 ;;
    --help|-h) echo 'Usage: round-membership.sh --repo OWNER/REPO --session ID [--state-helper PATH]'; exit 0 ;;
    *) exit 2 ;;
  esac
done
[[ "$repo" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || exit 2
# A freshness default is not a dispatch identity or an observer opt-in.
[[ "$session" =~ ^[A-Za-z0-9_.:-]+$ && "$session" != default && "$session" != null ]] || exit 2
command -v jq >/dev/null 2>&1 && [[ -x "$state_helper" ]] || exit 4
repo=$("$state_helper" --repo "$repo" --repo-key) || exit 5
[[ "$repo" =~ ^[a-z0-9_.-]+/[a-z0-9_.-]+$ ]] || exit 5
snapshot=""; read_rc=0
snapshot=$("$state_helper" --repo "$repo" --get-json ".repos[\"$repo\"]") || read_rc=$?
if [[ "$read_rc" -eq 3 ]]; then echo '{"members":null,"scope":"none"}'; exit 0; fi
[[ "$read_rc" -eq 0 ]] || { echo 'round-membership.sh: round state unreadable' >&2; exit 5; }
result=""
if ! result=$(printf '%s' "$snapshot" | jq -ce --arg session "$session" '
  def record:
    type == "object" and (.members | type == "array") and
    (.members | all(.[]; type == "string" and test("^[1-9][0-9]*$"))) and
    (.dispatched_at | type == "string" and test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$") and (try ((fromdateiso8601 | todateiso8601) == .) catch false));
  def unique_ordered:
    reduce .[] as $issue ([]; if index($issue) == null then . + [$issue] else . end);
  if . == null then {members:null,scope:"none"}
  elif type != "object" then error("invalid repo record")
  else (if .rounds == null then {} else .rounds end) as $rounds | .round as $legacy |
    if ($rounds | type) != "object" then error("invalid round map")
    elif ($rounds | to_entries | all(.[]; .value == null or
      ((.value | record) and .value.session == .key))) | not then error("invalid session round")
    elif $legacy != null and (($legacy | record) | not) then error("invalid legacy round")
    elif $legacy != null and $legacy.session != null and ($legacy.session | type) != "string" then error("invalid legacy owner")
    elif $session != "" and $rounds[$session] != null then
      {members:$rounds[$session].members,scope:"own"}
    else
      ($rounds | to_entries | sort_by(.key) | map(select(.value != null) | .value.members)) as $active |
      (if $legacy != null and ($legacy.session == null or ($rounds | has($legacy.session) | not))
       then [$legacy.members] else [] end) as $old |
      if ($active | length) > 0 then {members:(($active + $old | add) | unique_ordered),scope:"observer"}
      elif ($old | length) > 0 then {members:$legacy.members,scope:"legacy"}
      else {members:null,scope:"none"} end
    end
  end' 2>/dev/null); then
  echo 'round-membership.sh: round state malformed; membership unavailable' >&2
  exit 5
fi
printf '%s\n' "$result"
