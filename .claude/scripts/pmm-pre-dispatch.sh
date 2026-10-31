#!/usr/bin/env bash
# pmm-pre-dispatch.sh — Deterministic PMM tick gate, run by Monitor before a chat event.
# catalog: pr-state-polling — Compare PMM monitoring state before model dispatch and emit only actionable events
#
# Usage:
#   pmm-pre-dispatch.sh --repo owner/name --author login --generation TOKEN \
#     [--base-cadence-min MIN] [--idle-pause-after TICKS] [--skill-args 'PMM_FLAGS']
#   pmm-pre-dispatch.sh --repo owner/name --author login --generation TOKEN --monitor-command
#   pmm-pre-dispatch.sh --ack EVENT_ID [--repo owner/name]
#   pmm-pre-dispatch.sh --repo owner/name --author login --generation TOKEN --fixture snapshot.json
#   pmm-pre-dispatch.sh --help
#
# A quiet successful collection emits no stdout. A meaningful transition emits
# one PMM slash invocation; its compact event packet is durable in session-state.
# An unreadable/stale state
# or collector error emits a diagnostic-triggered skill invocation, never an
# "unchanged" result. Pending event packets stay in session-state until --ack
# consumes their exact ID.
#
# Exit codes: 0 success/event, 2 usage, 4 unreadable state, 5 collection failure.
set -Eeuo pipefail
printf '%s\t%s\t%s\n' "$(date -u +%FT%TZ)" "$(basename "$0")" "${*//$'\n'/ }" 2>/dev/null >> "$HOME/.claude/script-usage.log" || true

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATE_HELPER="$SCRIPT_DIR/session-state.sh"
MERGE_GATE="$SCRIPT_DIR/merge-gate.sh"
PR_STATE="$SCRIPT_DIR/pr-state.sh"
CLASSIFIER="$SCRIPT_DIR/lib/pr-state-classify.jq"
REPO=""
AUTHOR=""
GENERATION=""
PRINT_COMMAND=false
ACK_ID=""
FIXTURE=""
SKILL_ARGS=""
SKILL_ARGS_SHELL=""
BASE_CADENCE_MIN=5
IDLE_PAUSE_AFTER=3

usage() { awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0"; }
fail() { echo "pmm-pre-dispatch.sh: $*" >&2; exit 2; }
emit_unpersisted_diagnostic() {
  printf 'pmm-pre-dispatch.sh: %s; no durable event was written; retry next tick.\n' "$1" >&2
  printf '/pr-monitor-and-manage --tick --monitor-generation %s --pre-dispatch-diagnostic%s\n' \
    "${GENERATION:-unknown}" "${SKILL_ARGS_SHELL:+ $SKILL_ARGS_SHELL}"
  exit 5
}
normalize_skill_args() {
  [[ "$SKILL_ARGS" != *$'\n'* && "$SKILL_ARGS" != *$'\r'* ]] || fail "skill args contain a line break"
  [[ -n "${SKILL_ARGS//[[:space:]]/}" ]] || return 0
  local -a tokens=()
  read -r -a tokens <<<"$SKILL_ARGS"
  local i=0 arg value quoted
  while (( i < ${#tokens[@]} )); do
    arg="${tokens[$i]}"
    case "$arg" in
      --auto-wake|--confirm-merges)
        printf -v quoted '%q' "$arg"
        SKILL_ARGS_SHELL+=" $quoted"
        ((i+=1))
        ;;
      --repo|--author|--cadence|--max-parallel|--idle-pause-after|--auto-wake-cadence)
        (( i + 1 < ${#tokens[@]} )) || fail "skill arg $arg is missing its value"
        value="${tokens[$((i+1))]}"
        case "$arg" in
          --repo) [[ "$value" == "$REPO" ]] || fail "forwarded repo differs from collector repo" ;;
          --author) [[ "$value" == "$AUTHOR" ]] || fail "forwarded author differs from collector author" ;;
          --cadence|--auto-wake-cadence) [[ "$value" =~ ^[1-9][0-9]{0,5}m$ ]] || fail "invalid forwarded cadence" ;;
          --max-parallel|--idle-pause-after) [[ "$value" =~ ^[1-9][0-9]*$ ]] || fail "invalid forwarded integer for $arg" ;;
        esac
        printf -v quoted '%q' "$arg"
        SKILL_ARGS_SHELL+=" $quoted"
        printf -v quoted '%q' "$value"
        SKILL_ARGS_SHELL+=" $quoted"
        ((i+=2))
        ;;
      *) fail "unsupported forwarded skill arg: $arg" ;;
    esac
  done
  SKILL_ARGS_SHELL="${SKILL_ARGS_SHELL# }"
}
while [[ $# -gt 0 ]]; do
  case "$1" in
    --help|-h) usage; exit 0 ;;
    --repo) REPO="${2:-}"; [[ -n "$REPO" ]] || fail "--repo requires owner/name"; shift 2 ;;
    --author) AUTHOR="${2:-}"; [[ -n "$AUTHOR" ]] || fail "--author requires a login"; shift 2 ;;
    --generation) GENERATION="${2:-}"; [[ -n "$GENERATION" ]] || fail "--generation requires a token"; shift 2 ;;
    --monitor-command) PRINT_COMMAND=true; shift ;;
    --ack) ACK_ID="${2:-}"; [[ -n "$ACK_ID" ]] || fail "--ack requires an event ID"; shift 2 ;;
    --fixture) FIXTURE="${2:-}"; [[ -n "$FIXTURE" ]] || fail "--fixture requires a JSON snapshot path"; shift 2 ;;
    --skill-args) SKILL_ARGS="${2:-}"; shift 2 ;;
    --base-cadence-min) BASE_CADENCE_MIN="${2:-}"; shift 2 ;;
    --idle-pause-after) IDLE_PAUSE_AFTER="${2:-}"; shift 2 ;;
    *) fail "unknown argument: $1" ;;
  esac
done

if [[ -z "$ACK_ID" ]]; then
  [[ "$REPO" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || fail "--repo must be owner/name"
  [[ "$AUTHOR" =~ ^[A-Za-z0-9_.-]+$ ]] || fail "--author must be a login"
  [[ "$GENERATION" =~ ^[A-Za-z0-9_.-]+$ && "$GENERATION" != --* ]] || fail "--generation must be a non-secret token"
  [[ "$BASE_CADENCE_MIN" =~ ^[1-9][0-9]{0,5}$ ]] || fail "--base-cadence-min must be a positive integer"
  [[ "$IDLE_PAUSE_AFTER" =~ ^[1-9][0-9]{0,5}$ ]] || fail "--idle-pause-after must be a positive integer"
  normalize_skill_args
fi
for dep in jq shasum; do command -v "$dep" >/dev/null 2>&1 || emit_unpersisted_diagnostic "required dependency $dep is unavailable"; done
[[ -x "$STATE_HELPER" ]] || emit_unpersisted_diagnostic "session-state.sh unavailable"

# Build the exact persistent command without relying on the arming shell's
# environment. Values are validated above and every literal is shell-quoted.
if [[ "$PRINT_COMMAND" == true ]]; then
  [[ -z "$ACK_ID" && -z "$FIXTURE" ]] || fail "--monitor-command cannot acknowledge or use fixtures"
  printf 'STATE_HELPER=%q\nGATE=%q\nREPO=%q\nAUTHOR=%q\nGENERATION=%q\nBASE=%q\nIDLE=%q\nFORWARD=%q\n' \
    "$STATE_HELPER" "$SCRIPT_DIR/pmm-pre-dispatch.sh" "$REPO" "$AUTHOR" "$GENERATION" "$BASE_CADENCE_MIN" "$IDLE_PAUSE_AFTER" "$SKILL_ARGS"
  cat <<'COMMAND'
while :; do
  cadence=$("$STATE_HELPER" --get '.pmm_cadence' 2>/dev/null) || cadence="${BASE}m"
  [[ "$cadence" =~ ^([1-9][0-9]{0,5})m$ ]] || cadence="${BASE}m"
  sleep "$(( ${cadence%m} * 60 ))" || exit 0
  "$GATE" --repo "$REPO" --author "$AUTHOR" --generation "$GENERATION" \
    --base-cadence-min "$BASE" --idle-pause-after "$IDLE" --skill-args "$FORWARD"
done
COMMAND
  exit 0
fi

read_state() {
  local rc=0
  STATE_JSON="$("$STATE_HELPER" --get-json '.pmm_pre_dispatch' 2>/dev/null)" || rc=$?
  if [[ $rc -eq 3 ]]; then STATE_EXPECT=null; STATE_JSON='{}'; return 0; fi
  [[ $rc -eq 0 ]] || return 1
  STATE_EXPECT="$STATE_JSON"
  if [[ "$STATE_JSON" == "null" ]]; then STATE_JSON='{}'; return 0; fi
  if [[ $rc -ne 0 ]] || ! jq -e 'type == "object"' >/dev/null 2>&1 <<<"$STATE_JSON"; then
    return 1
  fi
}
write_state() {
  local value="$1"
  shift
  # CAS only this gate's outbox/state: a concurrent ack/receipt cannot be lost.
  "$STATE_HELPER" --cas ".pmm_pre_dispatch=$value" --expect "$STATE_EXPECT" "$@" >/dev/null || return $?
  STATE_EXPECT="$value"; STATE_JSON="$value"
}
read_field() {
  local path="$1" value rc=0
  value="$("$STATE_HELPER" --get "$path" 2>/dev/null)" || rc=$?
  if [[ $rc -eq 3 ]]; then printf 'null'; return 0; fi
  [[ $rc -eq 0 ]] || return 1
  printf '%s' "$value"
}
emit_event() {
  local event="$1" id
  id=$(jq -er '.event_id | select(type == "string" and test("^[a-f0-9]{64}$"))' <<<"$event") || emit_unpersisted_diagnostic "invalid pending event ID"
  printf '/pr-monitor-and-manage --tick --monitor-generation %s --dispatch-event %s%s\n' \
    "$GENERATION" "$id" "${SKILL_ARGS_SHELL:+ $SKILL_ARGS_SHELL}"
}
event_id() { jq -cS . <<<"$1" | shasum -a 256 | awk '{print $1}'; }
queue_diagnostic() {
  trap - ERR
  local reason="$1" at event id next
  at="$(date -u +%Y-%m-%dT%H:%M:%SZ)" || emit_unpersisted_diagnostic "$reason; clock unavailable"
  event="$(jq -cn --arg repo "$REPO" --arg author "$AUTHOR" --arg generation "$GENERATION" \
    --arg detected "$at" --arg reason "$reason" --argjson sequence "$(jq -r "(.transitions // 0)+1" <<<"$STATE_JSON")" \
    '{repo:$repo,author:$author,generation:$generation,sequence:$sequence,detected_at:$detected,reason:$reason,
      reasons:["collector_error"],diagnostic:true,trigger:"pmm-diagnose",evidence:[]}')" || emit_unpersisted_diagnostic "$reason; diagnostic construction failed"
  id="$(event_id "$event")" || emit_unpersisted_diagnostic "$reason; diagnostic hashing failed"
  event="$(jq -c --arg id "$id" '. + {event_id:$id}' <<<"$event")" || emit_unpersisted_diagnostic "$reason; diagnostic ID failed"
  next="$(jq -c --argjson event "$event" --arg now "$at" \
    '.ticks=((.ticks // 0)+1) | .errors=((.errors // 0)+1) | .error_streak=((.error_streak // 0)+1) | .last_tick_at=$now | .dispatches=((.dispatches // 0)+1) | .transitions=((.transitions // 0)+1) | .last_error_at=$now | .last_event_at=$now | .pending_event=$event' <<<"$STATE_JSON")" || emit_unpersisted_diagnostic "$reason; diagnostic state invalid"
  write_state "$next" || emit_unpersisted_diagnostic "$reason; session-state write failed"
  emit_event "$event"
  exit 5
}
unexpected_error() {
  local rc="$1" line="$2"
  # A failed command substitution propagates to its parent. Never emit a wake
  # into a captured value or queue two diagnostics for one failure.
  [[ "$BASH_SUBSHELL" -eq 0 ]] || exit "$rc"
  trap - ERR
  [[ -z "$ACK_ID" ]] || { echo "pmm-pre-dispatch.sh: acknowledgement failed at line $line" >&2; exit 4; }
  queue_diagnostic "computation failed at line $line (exit $rc)"
}
trap 'unexpected_error "$?" "$LINENO"' ERR

if ! read_state; then
  if [[ -n "$ACK_ID" ]]; then
    echo "pmm-pre-dispatch.sh: cannot acknowledge with unreadable session state" >&2
    exit 4
  fi
  # A corrupted state file is never interpreted as an empty baseline. This
  # event has no ackable state so every Monitor tick retries for diagnosis.
  emit_unpersisted_diagnostic "session-state unreadable"
fi

if [[ -n "$ACK_ID" ]]; then
  pending="$(jq -c '.pending_event // null' <<<"$STATE_JSON")"
  [[ "$pending" != "null" ]] || exit 0
  [[ "$(jq -r '.event_id' <<<"$pending")" == "$ACK_ID" ]] || exit 0
  next="$(jq -c --arg id "$ACK_ID" '.pending_event as $event | .pending_event=null | .last_acknowledged_event_id=$id | .acknowledged_events=(((.acknowledged_events // []) + [{event_id:$id,generation:$event.generation}]) | .[-64:]) | .acknowledged_at=(now | todateiso8601)' <<<"$STATE_JSON")"
  write_state "$next" || { echo "pmm-pre-dispatch.sh: could not acknowledge event" >&2; exit 4; }
  exit 0
fi

# A stopped/old shell loop cannot alter the current generation's outbox.
# Fixtures intentionally operate without a published live Monitor identity.
if [[ -z "$FIXTURE" ]]; then
  recorded_generation=$(read_field '.pmm_monitor_generation') || emit_unpersisted_diagnostic "Monitor generation unreadable"
  active=$(read_field '.pmm_active') || emit_unpersisted_diagnostic "Monitor activity unreadable"
  stopped=$(read_field '.pmm.stop_requested') || emit_unpersisted_diagnostic "Monitor stop state unreadable"
  if [[ "$recorded_generation" == null || -z "$recorded_generation" || ( "$active" != true && "$active" != false ) || ( "$stopped" != true && "$stopped" != false && "$stopped" != null ) ]]; then
    emit_unpersisted_diagnostic "Monitor identity/activity is unknown"
  fi
  if [[ "$recorded_generation" != "$GENERATION" || "$active" != true || "$stopped" == true ]]; then exit 0; fi
fi
# Re-emit the outbox only for the same collector identity. A legitimate re-arm
# supersedes the prior generation but retains its packet as audit evidence.
pending="$(jq -c '.pending_event // null' <<<"$STATE_JSON")"
if [[ "$pending" != "null" ]]; then
  if ! jq -e 'type == "object" and (.event_id|type)=="string" and (.generation|type)=="string" and (.repo|type)=="string" and (.author|type)=="string"' >/dev/null <<<"$pending"; then
    emit_unpersisted_diagnostic "outbox is malformed; repair it before collection"
  fi
  if jq -e --arg repo "$REPO" --arg author "$AUTHOR" --arg generation "$GENERATION" '.repo==$repo and .author==$author and .generation==$generation' >/dev/null <<<"$pending"; then
    next=$(jq -c --arg now "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '.ticks=((.ticks // 0)+1) | .dispatches=((.dispatches // 0)+1) | .replays=((.replays // 0)+1) | .last_tick_at=$now' <<<"$STATE_JSON")
    write_state "$next" || emit_unpersisted_diagnostic "outbox replay state changed concurrently; retry next tick"
    emit_event "$pending"; exit 0
  fi
  if [[ "$(jq -r .generation <<<"$pending")" == "$GENERATION" ]]; then
    emit_unpersisted_diagnostic "outbox repo/author differs within the same Monitor generation"
  fi
  next=$(jq -c '.superseded_event=.pending_event | .pending_event=null' <<<"$STATE_JSON")
  write_state "$next" || emit_unpersisted_diagnostic "could not supersede old Monitor outbox"
fi

NOW="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
if [[ -n "$FIXTURE" ]]; then
  [[ -r "$FIXTURE" ]] || queue_diagnostic "snapshot fixture unreadable"
  CURRENT="$(cat "$FIXTURE")" || queue_diagnostic "snapshot fixture read failed"
else
  [[ -x "$MERGE_GATE" && -x "$PR_STATE" && -r "$CLASSIFIER" ]] || queue_diagnostic "required PMM state helpers unavailable"
  agents="$("$STATE_HELPER" --get-json '.active_agents // {}' 2>/dev/null)" || queue_diagnostic "active-agent state unreadable"
  locks="$("$STATE_HELPER" --get-json '.pmm_in_flight // {}' 2>/dev/null)" || queue_diagnostic "PMM lock state unreadable"
  holds="$("$STATE_HELPER" --get-json '.pmm_merge_holds // {}' 2>/dev/null)" || queue_diagnostic "PMM merge-hold state unreadable"
  orchestration="$(jq -cn --argjson agents "$agents" --argjson locks "$locks" --argjson holds "$holds" '{active_agents:$agents,pmm_in_flight:$locks,merge_holds:$holds}')" || queue_diagnostic "orchestration state malformed"
  pulls=""
  if ! pulls="$(gh pr list --repo "$REPO" --author "$AUTHOR" --state open --json number,url,headRefOid,title --limit 500)"; then
    queue_diagnostic "open PR discovery failed"
  fi
  if ! jq -e 'type == "array" and all(.[]; (.number|type)=="number" and .number>0 and (.headRefOid|type)=="string" and (.headRefOid|length)>0 and (.url|type)=="string") and ([.[].number]|unique|length)==length' >/dev/null <<<"$pulls"; then
    queue_diagnostic "open PR discovery returned malformed data"
  fi
  PRS='[]'; EVIDENCE='[]'; FINDINGS='[]'; ERROR=""
  numbers=$(jq -r '.[].number' <<<"$pulls" | sort -n -u) || queue_diagnostic "PR-number projection failed"
  for number in $numbers; do
    gate=""; gate_rc=0
    gate="$(cd "$PWD" && "$MERGE_GATE" "$number")" || gate_rc=$?
    if [[ $gate_rc -gt 1 ]] || ! jq -e 'type == "object" and (.head_sha|type)=="string" and (.met|type)=="boolean" and (.merge_state|type)=="string" and (.mergeable|type)=="string" and (.review_decision|type)=="string" and (.ci_status|type)=="object" and (.ci_status.failing|type)=="number" and (.unresolved_thread_count|type)=="number" and (.missing|type)=="array" and (.human_changes_requested|type)=="array" and (.authorship|type)=="string"' >/dev/null 2>&1 <<<"$gate"; then ERROR="merge-gate unavailable or malformed for PR #$number"; break; fi
    bundle_path=""; bundle_rc=0
    bundle_path="$("$PR_STATE" --pr "$number")" || bundle_rc=$?
    if [[ $bundle_rc -ne 0 || ! -r "$bundle_path" ]]; then ERROR="pr-state unavailable for PR #$number"; break; fi
    discovered_sha=$(jq -r --argjson n "$number" '.[] | select(.number==$n) | .headRefOid' <<<"$pulls")
    [[ "$(jq -r .head_sha <<<"$gate")" == "$discovered_sha" ]] || { ERROR="HEAD changed during collection for PR #$number"; break; }
    if ! jq -e --argjson n "$number" --arg owner "${REPO%/*}" --arg repo "${REPO#*/}" --arg sha "$(jq -r '.head_sha' <<<"$gate")" 'type == "object" and .pr.number==$n and (.pr.owner|ascii_downcase)==($owner|ascii_downcase) and (.pr.repo|ascii_downcase)==($repo|ascii_downcase) and .pr.head_sha==$sha and (.run_started_at|type)=="string" and (.comments.reviews|type)=="array" and (.comments.inline|type)=="array" and (.comments.conversation|type)=="array" and (.check_runs.all|type)=="array" and (.check_runs.passing_runs|type)=="array" and (.check_runs.failing_runs|type)=="array" and (.check_runs.in_progress_runs|type)=="array" and (.commit_statuses|type)=="array" and all((.comments.reviews[]?,.comments.inline[]?,.comments.conversation[]?); (.id|type)=="number" and (.user.login|type)=="string" and (.body==null or (.body|type)=="string")) and all(.comments.inline[],.comments.conversation[]; (.created_at|type)=="string") and all(.comments.reviews[]; (.submitted_at|type)=="string" or .state=="PENDING")'  >/dev/null 2>&1 "$bundle_path"; then
      ERROR="pr-state bundle malformed for PR #$number"; break
    fi
    if ! jq -e --argjson now "$(date -u +%s)" '(.run_started_at | strptime("%Y-%m-%dT%H:%M:%SZ") | mktime) as $at | $at <= ($now+60) and ($now-$at) <= 3600' "$bundle_path" >/dev/null 2>&1; then
      ERROR="pr-state bundle stale or has invalid time for PR #$number"; break
    fi
    evidence="$bundle_path"
    # Use the repo's canonical comment classifier. Hash finding ID + current body
    # so a new or edited actionable comment wakes even if the coarse gate digest
    # did not move. Acknowledgment-only comments do not produce wake events.
    classified="$(jq -n \
      --argjson reviews "$(jq -c '[.comments.reviews[]? | . + {__endpoint:"review"}]' "$bundle_path")" \
      --argjson inline "$(jq -c '[.comments.inline[]? | . + {__endpoint:"inline"}]' "$bundle_path")" \
      --argjson conversation "$(jq -c '[.comments.conversation[]? | . + {__endpoint:"conversation"}]' "$bundle_path")" \
      --arg since '' -f "$CLASSIFIER")" || { ERROR="comment classification failed for PR #$number"; break; }
    candidates=$(jq -c '(.reviews[] | . + {endpoint:"review"}),(.inline[] | . + {endpoint:"inline"}),(.conversation[] | . + {endpoint:"conversation"}) | select(.classification.class == "finding")' <<<"$classified")
    finding_keys='[]'
    while IFS= read -r candidate; do
      [[ -n "$candidate" ]] || continue
      body_hash=$(jq -j '.body' <<<"$candidate" | shasum -a 256 | awk '{print $1}')
      observed=$(jq -r --argjson item "$candidate" '.comments[(if $item.endpoint=="review" then "reviews" elif $item.endpoint=="inline" then "inline" else "conversation" end)][] | select(.id==$item.id) | .updated_at // .submitted_at // .created_at // empty' "$bundle_path")
      key=$(jq -c --arg hash "$body_hash" --arg observed "$observed" '{endpoint,id,url,observed_at:$observed,body_hash:$hash}' <<<"$candidate")
      finding_keys=$(jq -c --argjson key "$key" '. + [$key] | sort_by(.endpoint,.id)' <<<"$finding_keys")
    done <<< "$candidates"
    gate_projection="$(jq -cS '{head_sha,met,reviewer,path,missing:(.missing|sort),ci_status:(.ci_status|{total,passing,failing,in_progress,blocking:(.blocking // []|sort),incomplete:(.incomplete // []|sort)}),merge_state,mergeable,review_decision,stale_bot_changes_requested_count:(.stale_bot_changes_requested_count // 0),human_changes_requested:(.human_changes_requested|sort),unresolved_thread_count,authorship}' <<<"$gate")"
    row="$(jq -cn --argjson number "$number" --arg url "$(jq -r --argjson n "$number" '.[]|select(.number==$n)|.url' <<<"$pulls")" \
      --argjson gate "$gate_projection" --argjson findings "$finding_keys" \
      '{number:$number,url:$url,gate:$gate,findings:$findings}')"
    PRS="$(jq -c --argjson row "$row" '. + [$row]' <<<"$PRS")"
    EVIDENCE="$(jq -c --argjson n "$number" --arg path "$evidence" '. + [{pr:$n,path:$path}]' <<<"$EVIDENCE")"
    FINDINGS="$(jq -c --argjson n "$number" --argjson ids "$finding_keys" '. + [{pr:$n,items:$ids}]' <<<"$FINDINGS")"
  done
  if [[ -n "$ERROR" ]]; then
    queue_diagnostic "$ERROR"
  fi
  PRS="$(jq -cS 'sort_by(.number)' <<<"$PRS")"
  CURRENT="$(jq -cnS --arg repo "$REPO" --arg author "$AUTHOR" --arg now "$NOW" \
    --argjson prs "$PRS" --argjson evidence "$EVIDENCE" --argjson orchestration "$orchestration" \
    '{repo:$repo,author:$author,collected_at:$now,prs:$prs,evidence:$evidence,orchestration:$orchestration}')"
fi

if ! jq -e --arg repo "$REPO" --arg author "$AUTHOR" 'type == "object" and .repo==$repo and .author==$author and (.collected_at|type)=="string" and (.prs|type)=="array" and ([.prs[].number]|unique|length)==(.prs|length) and (.evidence|type)=="array" and (.orchestration|type)=="object" and (.orchestration.active_agents|type)=="object" and (.orchestration.pmm_in_flight|type)=="object" and (.orchestration.merge_holds|type)=="object" and all(.orchestration.active_agents[]; (.phase|type)=="string" and (.status|type)=="string") and all(.prs[]; (.number|type)=="number" and (.gate.head_sha|type)=="string" and (.gate.head_sha|length)>0 and (.gate.met|type)=="boolean" and (.gate.merge_state|type)=="string" and (.gate.review_decision|type)=="string" and (.gate.mergeable|type)=="string" and (.gate.authorship|type)=="string" and (.gate.ci_status.total|type)=="number" and (.gate.ci_status.passing|type)=="number" and (.gate.ci_status.in_progress|type)=="number" and (.gate.ci_status.failing|type)=="number" and (.gate.unresolved_thread_count|type)=="number" and (.findings|type)=="array")' >/dev/null 2>&1 <<<"$CURRENT"; then
  queue_diagnostic "collected snapshot is malformed"
fi

if ! jq -e --argjson now "$(date -u +%s)" '(.collected_at | strptime("%Y-%m-%dT%H:%M:%SZ") | mktime) as $at | $at <= ($now+60) and ($now-$at) <= 3600' <<<"$CURRENT" >/dev/null 2>&1; then
  queue_diagnostic "collected snapshot is stale or has invalid time"
fi

if jq -e 'any(.prs[]; .gate.authorship=="unknown" or .gate.merge_state=="UNKNOWN" or .gate.mergeable=="UNKNOWN")' >/dev/null <<<"$CURRENT"; then
  queue_diagnostic "gate ownership or merge state is unknown"
fi

# Event deltas include fleet membership, gate/HEAD/CI/blocker transitions,
# actionable finding additions, relevant agent state, and time deadlines.
previous="$(jq -c '.snapshot.data // null' <<<"$STATE_JSON")"
curr_digest="$(jq -cS '
  {repo,author,prs,
   agents:[(.orchestration.active_agents // {} | to_entries[]? | {id:.key,pr:.value.pr,phase:.value.phase,status:.value.status})] | sort_by(.id),
   locks:[(.orchestration.pmm_in_flight // {} | to_entries[]? | {pr:.key,status:.value.status,dispatched_at:.value.dispatched_at,head_sha:.value.head_sha})] | sort_by(.pr),
   holds:[(.orchestration.merge_holds // {} | to_entries[]? | {pr:.key,state:.value})] | sort_by(.pr)}
' <<<"$CURRENT" | shasum -a 256 | awk '{print $1}')" || queue_diagnostic "snapshot digest calculation failed"
PMM_STATE_TUPLE="$(jq -cS '[.prs[] | [.number,.gate.head_sha,.gate.merge_state,.gate.review_decision,.gate.ci_status.failing,.gate.unresolved_thread_count]]' <<<"$CURRENT")" || queue_diagnostic "PMM state digest tuple calculation failed"
PMM_STATE_DIGEST="$(printf '%s' "$PMM_STATE_TUPLE" | shasum -a 256 | awk '{print $1}')" || queue_diagnostic "PMM state digest hashing failed"
PMM_PREV_DIGEST="$(read_field '.pmm_digest')" || queue_diagnostic "PMM digest state unreadable"
PMM_PREV_STREAK="$(read_field '.pmm_digest_streak')" || queue_diagnostic "PMM digest streak unreadable"
PMM_PREV_IDLE="$(read_field '.pmm_idle_streak')" || queue_diagnostic "PMM idle streak unreadable"
PMM_PREV_CADENCE="$(read_field '.pmm_cadence')" || queue_diagnostic "PMM cadence state unreadable"
[[ "$PMM_PREV_CADENCE" == null || "$PMM_PREV_CADENCE" =~ ^[1-9][0-9]{0,5}m$ ]] || queue_diagnostic "persisted PMM cadence is invalid"
[[ "$PMM_PREV_STREAK" != null ]] || PMM_PREV_STREAK=0
[[ "$PMM_PREV_IDLE" != null ]] || PMM_PREV_IDLE=0
[[ "$PMM_PREV_STREAK" =~ ^[0-9]{1,8}$ && "$PMM_PREV_IDLE" =~ ^[0-9]{1,8}$ ]] || queue_diagnostic "persisted PMM counters are invalid"
PMM_PREV_STREAK=$((10#$PMM_PREV_STREAK)); PMM_PREV_IDLE=$((10#$PMM_PREV_IDLE))
PMM_WIDE_CADENCE_MIN=$((BASE_CADENCE_MIN * 3))
[[ "$PMM_WIDE_CADENCE_MIN" -ge 15 ]] || PMM_WIDE_CADENCE_MIN=15
if [[ "$PMM_PREV_DIGEST" == "$PMM_STATE_DIGEST" ]]; then
  PMM_NEXT_STREAK=$((PMM_PREV_STREAK + 1))
  PMM_SAME_DIGEST=true
else
  PMM_NEXT_STREAK=0
  PMM_SAME_DIGEST=false
fi
active_agents_count="$(jq -r '[.orchestration.active_agents // {} | to_entries[]? | select((.value.phase // "") == "A" and ((.value.status // "") != "complete") and ((.value.status // "") != "failed"))] | length' <<<"$CURRENT")"
active_locks_count="$(jq -r '[.orchestration.pmm_in_flight // {} | to_entries[]? | select((.value.status // "") == "active")] | length' <<<"$CURRENT")"
merge_holds_count="$(jq -r '[.orchestration.merge_holds // {} | to_entries[]? | select(.value != null and (.value.released // false) == false)] | length' <<<"$CURRENT")"
if [[ "$PMM_SAME_DIGEST" == true && "$active_agents_count" -eq 0 && "$active_locks_count" -eq 0 && "$merge_holds_count" -eq 0 ]]; then
  PMM_NEXT_IDLE=$((PMM_PREV_IDLE + 1))
else
  PMM_NEXT_IDLE=0
fi
PMM_NEXT_CADENCE_MIN="$BASE_CADENCE_MIN"
[[ "$PMM_NEXT_STREAK" -ge 3 ]] && PMM_NEXT_CADENCE_MIN="$PMM_WIDE_CADENCE_MIN"
prev_digest="$(jq -r '.snapshot.digest // empty' <<<"$STATE_JSON")"
now_epoch="$(date -u +%s)"
deadline_state="$(jq -c --argjson now "$now_epoch" --argjson marks "$(jq -c '.deadline_marks // []' <<<"$STATE_JSON")" '
  def iso_epoch($s): try ($s | strptime("%Y-%m-%dT%H:%M:%SZ") | mktime) catch null;
  [(.orchestration.active_agents // {} | to_entries[]?
     | .key as $id | .value as $a
     | select(($a.phase // "") == "A" and ((($a.status // "") == "complete")|not) and ((($a.status // "") == "failed")|not))
     | {key:("agent:"+$id+":"+($a.last_seen_at // $a.launched // "")),
        at:(iso_epoch($a.last_seen_at // $a.launched // "") as $ts | if $ts == null then null else $ts + (if ($id|startswith("pmm-fix-")) then 900 else 3600 end) end)}),
   (.orchestration.pmm_in_flight // {} | to_entries[]?
     | .key as $pr | .value as $l
     | select(($l.status // "") == "active")
     | {key:("lock:"+$pr+":"+($l.dispatched_at // "")),at:(iso_epoch($l.dispatched_at // "") as $ts | if $ts == null then null else $ts + 3600 end)})] as $candidates
  | {due:[$candidates[] | select((.at|type)=="number" and .at <= $now and (.key as $k | ($marks|index($k)) == null)) | .key],
     unknown:[$candidates[] | select(.at == null) | .key]}
' <<<"$CURRENT")" || queue_diagnostic "recovery deadline calculation failed"
deadline_due="$(jq -c '.due' <<<"$deadline_state")" || queue_diagnostic "recovery deadline due-state unreadable"
deadline_unknown="$(jq -c '.unknown' <<<"$deadline_state")" || queue_diagnostic "recovery deadline unknown-state unreadable"
snapshot_stale="false"
if [[ "$previous" != null ]]; then
  recorded_at="$(jq -r '.snapshot.recorded_at // empty' <<<"$STATE_JSON")"
  if [[ -z "$recorded_at" ]]; then snapshot_stale="true"
  else
    recorded_epoch="$(jq -nr --arg ts "$recorded_at" 'try ($ts | strptime("%Y-%m-%dT%H:%M:%SZ") | mktime) catch -1')"
    [[ "$recorded_epoch" -ge 0 ]] || snapshot_stale="true"
    if [[ "$recorded_epoch" -ge 0 && ( $((now_epoch-recorded_epoch)) -gt 3600 || "$recorded_epoch" -gt $((now_epoch+60)) ) ]]; then snapshot_stale="true"; fi
  fi
fi
delta="$(jq -cn --argjson old "$previous" --argjson new "$CURRENT" --argjson deadlines "$deadline_due" --argjson deadline_unknown "$deadline_unknown" '
  def rows($x): ($x.prs // [] | map({key:(.number|tostring),value:.}) | from_entries);
  def agent_states($x): [($x.orchestration.active_agents // {} | to_entries[]? | {id:.key,pr:.value.pr,phase:.value.phase,status:.value.status})] | sort_by(.id);
  def lock_states($x): [($x.orchestration.pmm_in_flight // {} | to_entries[]? | {pr:.key,status:.value.status,dispatched_at:.value.dispatched_at,head_sha:.value.head_sha})] | sort_by(.pr);
  def hold_states($x): [($x.orchestration.merge_holds // {} | to_entries[]? | {pr:.key,state:.value})] | sort_by(.pr);
  (rows($old)) as $a | (rows($new)) as $b
  | {added:([$b|keys[] | select($a[.] == null)]),
     added_prs:([$b|keys[] as $k | select($a[$k] == null) | {pr:($k|tonumber),head_sha:$b[$k].gate.head_sha,url:$b[$k].url}]),
     removed:([$a|keys[] | select($b[.] == null)]),
     removed_prs:([$a|keys[] as $k | select($b[$k] == null) | {pr:($k|tonumber),head_sha:$a[$k].gate.head_sha,url:$a[$k].url}]),
     changed:([$b|keys[] as $k | select($a[$k] != null and $a[$k].gate != $b[$k].gate)
       | {pr:($k|tonumber),before:($a[$k].gate|{head_sha,met,reviewer,path,missing,human_changes_requested,stale_bot_changes_requested_count,ci_status,merge_state,mergeable,review_decision,unresolved_thread_count,authorship}),
          after:($b[$k].gate|{head_sha,met,reviewer,path,missing,human_changes_requested,stale_bot_changes_requested_count,ci_status,merge_state,mergeable,review_decision,unresolved_thread_count,authorship})}]),
     new_findings:([$b|to_entries[] as $p | ($p.value.findings // [])[] as $f
       | select((($a[$p.key].findings // []) | index($f)) == null)
       | {pr:($p.key|tonumber),head_sha:$p.value.gate.head_sha,item:{endpoint:$f.endpoint,id:$f.id,url:$f.url,observed_at:$f.observed_at}}]),
     agent_changes:(agent_states($old) as $oa | agent_states($new) as $na | if $oa == $na then [] else [$oa,$na] end),
     lock_changes:(lock_states($old) as $ol | lock_states($new) as $nl | if $ol == $nl then [] else [$ol,$nl] end),
     hold_changes:(hold_states($old) as $oh | hold_states($new) as $nh | if $oh == $nh then [] else [$oh,$nh] end),
     deadlines:$deadlines,deadline_unknown:$deadline_unknown}
')" || queue_diagnostic "snapshot delta calculation failed"
identity_changed="$(jq -r --arg repo "$REPO" --arg author "$AUTHOR" --arg generation "$GENERATION" \
  '(.monitor_repo // "") != $repo or (.monitor_author // "") != $author or (.monitor_generation // "") != $generation' <<<"$STATE_JSON")"
reasons="$(jq -cn --argjson old "$previous" --argjson delta "$delta" --arg digest "$curr_digest" --arg prev "$prev_digest" \
  --arg pmm_digest "$PMM_STATE_DIGEST" --arg pmm_prev "$PMM_PREV_DIGEST" \
  --argjson same_digest "$PMM_SAME_DIGEST" --argjson streak "$PMM_NEXT_STREAK" \
  --argjson idle "$PMM_NEXT_IDLE" --argjson held "$merge_holds_count" --argjson idle_threshold "$IDLE_PAUSE_AFTER" \
  --argjson stale "$snapshot_stale" --argjson identity_changed "$identity_changed" '
  [if $old == null then "initial" else empty end]
  + [if ($old != null and $identity_changed) then "monitor_identity_changed" else empty end]
  + [if (($delta.added|length)>0 or ($delta.removed|length)>0) then "fleet" else empty end]
  + [if (($delta.changed|length)>0) then "head_gate_ci_or_blocker" else empty end]
  + [if (($delta.new_findings|length)>0) then "actionable_review_finding" else empty end]
  + [if (($delta.agent_changes|length)>0) then "agent_state" else empty end]
  + [if (($delta.lock_changes|length)>0) then "pmm_lock_state" else empty end]
  + [if (($delta.hold_changes|length)>0) then "merge_hold_state" else empty end]
  + [if $old != null and $held > 0 then "merge_hold_recheck" else empty end]
  + [if (($delta.deadlines|length)>0) then "deadline" else empty end]
  + [if (($delta.deadline_unknown|length)>0) then "deadline_state_unknown" else empty end]
  + [if $stale then "snapshot_stale" else empty end]
  + [if ($old != null and ($pmm_prev == "null" or $pmm_prev != $pmm_digest)) then "state_digest" else empty end]
  + [if $same_digest and ($streak >= 9) then "stable_freeze_due" else empty end]
  + [if $same_digest and ($idle >= $idle_threshold) then "idle_pause_due" else empty end]
')" || queue_diagnostic "wake reason calculation failed"
meaningful="$(jq -r 'length > 0' <<<"$reasons")" || queue_diagnostic "wake predicate evaluation failed"
base="$(jq -cn --arg repo "$REPO" --arg author "$AUTHOR" --arg generation "$GENERATION" --arg detected "$NOW" \
  --arg digest "$curr_digest" --argjson sequence "$(jq -r "(.transitions // 0)+1" <<<"$STATE_JSON")" --argjson reasons "$reasons" --argjson delta "$delta" \
  --argjson evidence "$(jq -c '.evidence' <<<"$CURRENT")" \
  '{repo:$repo,author:$author,generation:$generation,sequence:$sequence,detected_at:$detected,reasons:$reasons,delta:$delta,digest:$digest,evidence:$evidence,
    detection_latency_seconds:(if ($delta.new_findings|length)==0 then null else
      ([ $delta.new_findings[].item.observed_at | try (strptime("%Y-%m-%dT%H:%M:%SZ") | mktime) catch empty ] | if length==0 then null else ((($detected|strptime("%Y-%m-%dT%H:%M:%SZ")|mktime) - min) | if . < 0 then 0 else . end) end) end),
    trigger:(if ($reasons|index("actionable_review_finding")) then "pmm-classify-review-findings" else "pmm-classify" end)}')" || queue_diagnostic "event packet construction failed"
id="$(event_id "$base")" || queue_diagnostic "event ID calculation failed"
schedule_state_args() {
  local cadence_min="$1" expected="$2"
  printf '%s\0' --set ".pmm_cadence=\"${cadence_min}m\"" --set ".pmm_last_tick_at=\"$NOW\"" --set ".pmm_next_expected_tick_at=\"$expected\""
}
state_changed=false
[[ "$PMM_PREV_DIGEST" == "$PMM_STATE_DIGEST" ]] || state_changed=true
if [[ "$meaningful" == true ]]; then
  event="$(jq -c --arg id "$id" '. + {event_id:$id}' <<<"$base")"
  next="$(jq -c --argjson snap "$CURRENT" --arg digest "$curr_digest" --argjson event "$event" --arg now "$NOW" \
    --arg repo "$REPO" --arg author "$AUTHOR" --arg generation "$GENERATION" \
    '.snapshot={data:$snap,digest:$digest,recorded_at:$now} | .digest=$digest | .pending_event=$event | .monitor_repo=$repo | .monitor_author=$author | .monitor_generation=$generation | .deadline_marks=((.deadline_marks // []) + ($event.delta.deadlines // []) | unique) | .ticks=((.ticks // 0)+1) | .dispatches=((.dispatches // 0)+1) | .transitions=((.transitions // 0)+1) | .last_tick_at=$now | .last_event_at=$now' <<<"$STATE_JSON")"
  if [[ "$state_changed" == true ]]; then
    cadence_args=(--set '.pmm_digest_streak=0' --set '.pmm_idle_streak=0')
    cadence_min="$BASE_CADENCE_MIN"
  elif jq -e 'any(.[]; . == "stable_freeze_due" or . == "idle_pause_due")' >/dev/null <<<"$reasons"; then
    cadence_args=(--set ".pmm_digest_streak=$PMM_PREV_STREAK" --set ".pmm_idle_streak=$PMM_PREV_IDLE")
    cadence_min="$PMM_NEXT_CADENCE_MIN"
  else
    cadence_args=()
    cadence_min="$PMM_NEXT_CADENCE_MIN"
    if [[ "$PMM_PREV_CADENCE" =~ ^([1-9][0-9]{0,5})m$ ]]; then cadence_min="${BASH_REMATCH[1]}"; fi
  fi
  schedule_args=()
  expected_tick="$(date -u -d "+${cadence_min} minutes" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -v+"${cadence_min}"M +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)" || queue_diagnostic "could not calculate the next PMM tick"
  while IFS= read -r -d '' arg; do schedule_args+=("$arg"); done < <(schedule_state_args "$cadence_min" "$expected_tick")
  write_state_extra=()
  write_state_extra+=(${cadence_args[@]+"${cadence_args[@]}"})
  write_state_extra+=("${schedule_args[@]}")
  write_state "$next" "${write_state_extra[@]}" || queue_diagnostic "could not persist pending event"
  emit_event "$event"
else
  next="$(jq -c --argjson snap "$CURRENT" --arg digest "$curr_digest" --arg now "$NOW" \
    --arg repo "$REPO" --arg author "$AUTHOR" --arg generation "$GENERATION" \
    '.snapshot={data:$snap,digest:$digest,recorded_at:$now} | .digest=$digest | .monitor_repo=$repo | .monitor_author=$author | .monitor_generation=$generation | .ticks=((.ticks // 0)+1) | .last_tick_at=$now | .error_streak=0' <<<"$STATE_JSON")"
  schedule_args=()
  expected_tick="$(date -u -d "+${PMM_NEXT_CADENCE_MIN} minutes" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -v+"${PMM_NEXT_CADENCE_MIN}"M +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)" || queue_diagnostic "could not calculate the next PMM tick"
  while IFS= read -r -d '' arg; do schedule_args+=("$arg"); done < <(schedule_state_args "$PMM_NEXT_CADENCE_MIN" "$expected_tick")
  write_state "$next" --set ".pmm_digest=\"$PMM_STATE_DIGEST\"" --set ".pmm_digest_streak=$PMM_NEXT_STREAK" \
    --set ".pmm_idle_streak=$PMM_NEXT_IDLE" "${schedule_args[@]}" || queue_diagnostic "could not persist comparison state"
fi
