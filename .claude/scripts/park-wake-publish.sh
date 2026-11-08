#!/usr/bin/env bash
# catalog: backlog-pm — Publishes a wake identity only onto its completed, unoccupied park
# A caller arms first, then invokes this helper and stops only its own new
# Monitor on any nonzero exit. No Monitor tools or cleanup writes run here.
# Exit 0: published; 7: retired/replaced/already occupied; 5: failed or unknown;
# 2: usage; 4: missing helper/dependency. CAS loss writes nothing; other
# failures can be unverified and must never promise an automatic resume.
# --task-encoding preserves the two existing caller encodings: string for
# preemptive wakes; JSON-or-string (session-state's rule) for reactive wakes.
set -euo pipefail

repo=""; cause=""; task=""; generation=""; encoding=string; state_helper=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo|--cause|--task-id|--generation|--task-encoding|--state-helper)
      [[ $# -ge 2 ]] || exit 2
      case "$1" in
        --repo) repo="$2" ;; --cause) cause="$2" ;;
        --task-id) task="$2" ;; --generation) generation="$2" ;;
        --task-encoding) encoding="$2" ;; --state-helper) state_helper="$2" ;;
      esac
      shift 2 ;;
    --help|-h)
      echo 'Usage: park-wake-publish.sh --repo OWNER/REPO|_unknown --cause reactive|preemptive --task-id ID --generation GEN --state-helper PATH [--task-encoding string|json-or-string]'
      exit 0 ;;
    *) exit 2 ;;
  esac
done
[[ ( "$repo" == _unknown || "$repo" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ) && -n "$task" && -n "$generation" ]] || exit 2
[[ "$cause" == reactive || "$cause" == preemptive ]] || exit 2
[[ "$encoding" == string || "$encoding" == json-or-string ]] || exit 2
command -v jq >/dev/null 2>&1 && [[ -x "$state_helper" ]] || exit 4
# Use the state writer's canonical scope key, including its case normalization.
repo=$("$state_helper" --repo "$repo" --repo-key) || exit 5
[[ "$repo" == _unknown || "$repo" =~ ^[a-z0-9_.-]+/[a-z0-9_.-]+$ ]] || exit 5

day_path=".repos[\"$repo\"].day"
day=""; read_rc=0
day=$("$state_helper" --repo "$repo" --get-json "$day_path") || read_rc=$?
[[ $read_rc -ne 3 ]] || exit 7
[[ $read_rc -eq 0 ]] || exit 5

# Unknown fields are retained. Only the fields needed to identify a completed
# park and an unoccupied identity pair authorize publication.
classify() {
  jq -r --arg cause "$cause" '
    def id: (type == "string" and length > 0) or
      (type == "number" and . >= 0 and floor == .);
    def bound:
      type == "string" and
      test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$") and
      (try ((fromdateiso8601 | todateiso8601) == .) catch false);
    if . == null then "lost"
    elif type != "object" then "failed"
    elif (.limit_cause != null and .limit_cause != "reactive" and .limit_cause != "preemptive")
      or (.park_claim_token != null and
          ((.park_claim_token | type) != "string" or (.park_claim_token | length) == 0)) then "failed"
    elif .limit_resume_task_id == null and .limit_resume_generation == null then
      if .limit_cause != $cause or .park_claim_token != null then "lost"
      elif .limit_kind == "weekly" or .limit_probe_fires_remaining == 0
           or .limit_probe_fires_remaining == -1 then "lost"
      elif .limit_kind != "rolling_window" then "failed"
      elif .limit_probe_fires_remaining != null and
           ((.limit_probe_fires_remaining | type) != "number" or
            (.limit_probe_fires_remaining | floor) != .limit_probe_fires_remaining or
            .limit_probe_fires_remaining < 0 or .limit_probe_fires_remaining > 9007199254740991) then "failed"
      elif $cause == "reactive" and .limit_probe_fires_remaining != null then "failed"
      elif (.parked_until | bound) then "ready" else "failed" end
    elif (.limit_resume_task_id | id) and
         (.limit_resume_generation | type == "string" and length > 0) then "lost"
    else "failed" end'
}
classification=$(printf '%s' "$day" | classify) || exit 5
case "$classification" in ready) ;; lost) exit 7 ;; *) exit 5 ;; esac

task_json=$(jq -cn --arg value "$task" --arg encoding "$encoding" '
  if $encoding == "string" then $value else ($value | try fromjson catch $value) end') || exit 5
if ! printf '%s' "$task_json" | jq -e '
  (type == "string" and length > 0) or
  (type == "number" and . >= 0 and floor == .)' >/dev/null; then exit 5; fi
generation_json=$(jq -cn --arg gen "$generation" '$gen') || exit 5

# One whole-object CAS retains the park check AND the empty-wake check. A
# cause-only self-CAS would allow two publishers to overwrite each other.
write_rc=0
"$state_helper" --repo "$repo" --cas "$day_path=$day" --expect "$day" \
  --set "$day_path.limit_resume_task_id=$task_json" \
  --set "$day_path.limit_resume_generation=$generation_json" >/dev/null || write_rc=$?
[[ $write_rc -ne 0 ]] || exit 0
[[ $write_rc -eq 7 ]] || exit 5

# A metadata-only revision can lose the full-object compare while the same
# park still lacks a wake. Report failure, rather than a silent lost outcome.
current=""; read_rc=0
current=$("$state_helper" --repo "$repo" --get-json "$day_path") || read_rc=$?
[[ $read_rc -ne 3 ]] || exit 7
[[ $read_rc -eq 0 ]] || exit 5
classification=$(printf '%s' "$current" | classify) || exit 5
case "$classification" in
  failed) exit 5 ;; lost) exit 7 ;; ready) ;; *) exit 5 ;;
esac
if printf '%s' "$current" | jq -e --argjson previous "$day" '
  def identity: {parked_until, limit_kind, limit_cause,
                 park_claim_token, limit_probe_fires_remaining};
  identity == ($previous | identity)' >/dev/null; then
  exit 5
fi
exit 7
