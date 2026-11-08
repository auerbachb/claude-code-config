#!/usr/bin/env bash
# catalog: backlog-pm — Retires a bound park snapshot without adopting a replacement
# Exit 0: retired; 7: observed ownership changed/retired; 8: identity unreadable;
# 5: same owner could not be retired; other write errors retain their status.
# One metadata refresh is allowed only for the original durable generation and
# identical park fields. Legacy identities never gain authority from a reread.
set -uo pipefail
repo=""; snapshot=""; state_helper=""; have_snapshot=0; reset_hits=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo|--snapshot|--state-helper)
      [[ $# -ge 2 ]] || exit 2
      case "$1" in
        --repo) repo="$2" ;; --snapshot) snapshot="$2"; have_snapshot=1 ;;
        --state-helper) state_helper="$2" ;;
      esac
      shift 2 ;;
    --reset-hits) reset_hits=1; shift ;;
    --help|-h)
      echo 'Usage: park-retire.sh --repo OWNER/REPO|_unknown --snapshot JSON --state-helper PATH [--reset-hits]'
      exit 0 ;;
    *) exit 2 ;;
  esac
done
[[ ( "$repo" == _unknown || "$repo" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ) && "$have_snapshot" -eq 1 ]] || exit 2
command -v jq >/dev/null 2>&1 && [[ -x "$state_helper" ]] || exit 4
valid_snapshot() {
  jq -e '(. == null or type == "object") and
    (.park_generation == null or
     ((.park_generation | type) == "string" and (.park_generation | length) > 0 and .park_generation != "null"))' >/dev/null 2>&1
}
printf '%s' "$snapshot" | valid_snapshot || exit 8
path=".repos[\"$repo\"].day"
sets=()
for field in limit_resume_task_id limit_resume_generation limit_probe_fires_remaining \
             limit_cause limit_kind park_claim_token park_generation parked_until; do
  sets+=(--set "$path.$field=null")
done
[[ "$reset_hits" -eq 0 ]] || sets+=(--set "$path.consecutive_limit_hits=0")
expected="$snapshot"
for attempt in original metadata_refresh; do
  write_rc=0
  "$state_helper" --repo "$repo" --cas "$path=$expected" --expect "$expected" \
    ${sets[@]+"${sets[@]}"} >/dev/null 2>&1 || write_rc=$?
  if [[ "$write_rc" -eq 6 ]]; then
    write_rc=0
    "$state_helper" --repo "$repo" --cas "$path=$expected" --expect "$expected" \
      ${sets[@]+"${sets[@]}"} >/dev/null 2>&1 || write_rc=$?
  fi
  [[ "$write_rc" -eq 7 ]] || exit "$write_rc"
  read_rc=0; current=""
  current=$("$state_helper" --repo "$repo" --get-json "$path" 2>/dev/null) || read_rc=$?
  if [[ "$read_rc" -eq 6 ]]; then
    read_rc=0
    current=$("$state_helper" --repo "$repo" --get-json "$path" 2>/dev/null) || read_rc=$?
  fi
  [[ "$read_rc" -ne 3 ]] || exit 7
  [[ "$read_rc" -eq 0 ]] || exit 8
  printf '%s' "$current" | valid_snapshot || exit 8
  classification=$(printf '%s' "$current" | jq -r --argjson previous "$snapshot" '
    def park: {park_generation, park_claim_token, limit_cause, parked_until,
               limit_kind, limit_probe_fires_remaining, limit_resume_task_id, limit_resume_generation,
               consecutive_limit_hits};
    def same_owner:
      if $previous.park_generation != null then .park_generation == $previous.park_generation
      elif .park_generation != null then false
      elif $previous.park_claim_token != null then .park_claim_token == $previous.park_claim_token
      elif $previous.limit_cause != null then .limit_cause == $previous.limit_cause
      else .parked_until == $previous.parked_until end;
    if (same_owner | not) then "superseded"
    elif $previous.park_generation != null and (park == ($previous | park)) then "metadata"
    else "same_owner" end' 2>/dev/null) || exit 8
  case "$classification" in
    superseded) exit 7 ;;
    metadata)
      [[ "$attempt" == original ]] || exit 5
      # Authority stays pinned to snapshot's generation AND complete park tuple.
      # Only unrelated metadata is refreshed, then compared again atomically.
      expected="$current" ;;
    *) exit 5 ;;
  esac
done
exit 5
