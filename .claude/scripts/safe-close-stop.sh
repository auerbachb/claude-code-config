#!/usr/bin/env bash
# safe-close-stop.sh — Shell-side steps of /safe-close's "stop what is running" increment (issue #2261).
# catalog: session-state-locking — Plans, parks, and verifies /safe-close's stop step from the read-only inventory's JSON; reuses /pause's resume record and registry, and never reads a stop's exit status as proof

# PURPOSE
#   /safe-close (#2260) reports what a thread still has running. This script
#   holds the parts of stopping it that a shell can do and check; the parts
#   only the harness can do (TaskStop on a subagent, Monitor or background
#   shell, listing the runtime's tasks) stay in the skill. It never signals a
#   process and never calls TaskStop. It consumes safe-close-inventory.sh's
#   JSON instead of detecting running work a second way, and it stops at
#   "nothing owned by this thread is still running": it removes no worktree,
#   branch, claim, handoff or session-state bookkeeping (that is #2262).
#
# USAGE
#   safe-close-stop.sh plan  --inventory FILE|-
#   safe-close-stop.sh owner --task-id ID [--repo owner/name]
#   safe-close-stop.sh park  --session ID --repo owner/name --decisions FILE
#   safe-close-stop.sh clear-ceiling --session ID [--repo owner/name]
#   safe-close-stop.sh verify --session ID [--repo owner/name] [--worktree P]
#                      [--scratchpad D]
#                      (--runtime-live-file FILE | --runtime-unreadable)
#                      [--stopped-id ID]... [--confirmed-gone ID]... [--pid N]...
#   safe-close-stop.sh --help | -h
#
# MODES
#   plan   Read an inventory JSON (safe-close-inventory.sh --json) and print the
#          stop plan: stop_items[] (registered tasks, subagent records, the
#          ceiling's work markers), each with whether it may have unlanded work
#          (unlanded: yes | possible | no), the choices it is offered (finish,
#          park, drop; "wrap" too when its PR passes the merge gate), and
#          default "park". Items the inventory marked unknown go to
#          unknown_items[] and are never stopped. Items another thread owns are
#          absent: the inventory excludes them and only items[] is read.
#          nothing_to_stop is true when there is nothing to ask about.
#   owner  Say whether a task id is a named watcher (babysit, pmm, day,
#          day_limit_wake, leave_winddown) so the owning stop command is used.
#          Prints {"owner":...,"ref":...}; "none" when no watcher record names it.
#          Exit 3 when session-state could not be read (owner unknown).
#   park   Write the same resumable record /pause writes —
#          .repos[<repo>].pauses[<session>] plus a pause-*.md marker — from a
#          decisions file {parked:[], background_tasks_stopped:[],
#          monitors_stopped:[]}, so /go-on can resume it from another thread.
#          An unresumed record already under this session is extended, never
#          replaced. Does not close any launch gate. Fails closed: exit 5 and
#          no success line when the marker or the state write failed.
#   clear-ceiling
#          Clear this session's bgwork-ceiling markers, only when the registry
#          lists no live task of any kind for the session (the markers stand for
#          every subagent, shell and Monitor, so all of them must be gone) and
#          the status then shows no background work. Exit 1 otherwise.
#   verify Re-run the inventory and report what is STILL running. A stop
#          command's exit status is never evidence: the caller must supply the
#          runtime's own task list (--runtime-live-file: a JSON array or one id
#          per line) or say it could not (--runtime-unreadable, which makes
#          every stopped id unverified). An id passed with --stopped-id that the
#          runtime still lists is still running, whatever the registry says.
#          --confirmed-gone marks a subagent record whose runtime id the
#          harness showed absent. --pid checks an exact pid the caller spawned.
#          First output line is the verdict.
#
# EXIT CODES
#   0  ok (verify: nothing owned by this thread is still running)
#   1  verify: something is still running or unverified; clear-ceiling refused
#   2  usage error / invalid input
#   3  a read this mode depends on failed (fails closed)
#   5  a write failed (park)
#
# Bash 3.2 compatible (macOS); passes under bash 5.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; n = 1; next } { exit } END { exit(n ? 0 : 1) }' "$0" ||
    { printf '%s: --help header extraction produced no output\n' "$0" >&2; exit 70; }
}
die() { local rc="$1"; shift; printf 'safe-close-stop.sh: %s\n' "$*" >&2; exit "$rc"; }

command -v jq >/dev/null 2>&1 || die 3 "jq not found"

resolve_script() {
  local name="$1" candidate
  for candidate in \
    "$SCRIPT_DIR/$name" \
    "${HOME:+$HOME/.claude/skills-worktree/.claude/scripts/$name}" \
    "${HOME:+$HOME/.claude/scripts/$name}"; do
    if [[ -n "$candidate" && -x "$candidate" ]]; then printf '%s' "$candidate"; return 0; fi
  done
  return 1
}

[[ $# -ge 1 ]] || { usage; exit 2; }
MODE="$1"; shift
case "$MODE" in
  --help|-h) usage; exit 0 ;;
  plan|owner|park|clear-ceiling|verify) ;;
  *) die 2 "unknown mode: $MODE" ;;
esac

INVENTORY="" TASK_ID="" SESSION="" REPO="" DECISIONS="" WT="" SCRATCH=""
RUNTIME_FILE="" RUNTIME_UNREADABLE=0
STOPPED_IDS='[]' GONE_IDS='[]' PIDS=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --runtime-unreadable) RUNTIME_UNREADABLE=1; shift ;;
    --inventory|--task-id|--session|--repo|--decisions|--worktree|--scratchpad|--runtime-live-file|--stopped-id|--confirmed-gone|--pid)
      [[ $# -ge 2 && -n "$2" ]] || die 2 "$1 requires a value"
      case "$1" in
        --inventory) INVENTORY="$2" ;;
        --task-id) TASK_ID="$2" ;;
        --session) SESSION="$2" ;;
        --repo) REPO="$2" ;;
        --decisions) DECISIONS="$2" ;;
        --worktree) WT="$2" ;;
        --scratchpad) SCRATCH="$2" ;;
        --runtime-live-file) RUNTIME_FILE="$2" ;;
        --stopped-id) STOPPED_IDS="$(jq -c --arg v "$2" '. + [$v]' <<<"$STOPPED_IDS")" || die 2 "bad --stopped-id" ;;
        --confirmed-gone) GONE_IDS="$(jq -c --arg v "$2" '. + [$v]' <<<"$GONE_IDS")" || die 2 "bad --confirmed-gone" ;;
        --pid)
          [[ "$2" =~ ^[0-9]+$ ]] || die 2 "--pid must be a number, got: $2"
          PIDS="$PIDS $2" ;;
      esac
      shift 2 ;;
    *) die 2 "unknown argument: $1" ;;
  esac
done
if [[ -n "$REPO" ]] && ! [[ "$REPO" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]]; then
  die 2 "--repo must be owner/name, got: $REPO"
fi
REPO="$(printf '%s' "$REPO" | tr '[:upper:]' '[:lower:]')"

SESSION_STATE_SH="$(resolve_script session-state.sh)" || SESSION_STATE_SH=""
REGISTRY_SH="$(resolve_script background-task-registry.sh)" || REGISTRY_SH=""
CEILING_SH="$(resolve_script bgwork-ceiling.sh)" || CEILING_SH=""

# ---------------------------------------------------------------- plan
do_plan() {
  local inv
  [[ -n "$INVENTORY" ]] || die 2 "plan requires --inventory FILE|-"
  if [[ "$INVENTORY" == "-" ]]; then inv="$(cat)"; else inv="$(cat "$INVENTORY" 2>/dev/null)" || die 3 "cannot read $INVENTORY"; fi
  jq -e 'type == "object" and (.items | type == "array")' >/dev/null 2>&1 <<<"$inv" || die 2 "input is not an inventory JSON (no items[])"
  # Registered recovery paths may be spelled through a symlink (/tmp vs /private/tmp);
  # the inventory's worktree paths are physical, so compare physical to physical.
  local canon='{}' rp real
  while IFS= read -r rp; do
    [[ -n "$rp" && -d "$rp" ]] || continue
    real="$(cd "$rp" 2>/dev/null && pwd -P)" || continue
    canon="$(jq -c --arg k "$rp" --arg v "$real" '. + {($k): $v}' <<<"$canon")" || die 3 "could not canonicalise $rp"
  done < <(jq -r '.items[] | .ref.recovery_path // empty' <<<"$inv")
  jq --argjson canon "$canon" '
    (.items) as $items
    | ([ $items[] | select(.category == "worktrees" and .consequence == "lost") | .ref.path ] | unique) as $lostwt
    | ([ $items[] | select(.category == "open_prs" and ((.ref.gate // "") == "merge gate met")) | .ref.number ]) as $ready
    | ([ $items[] | select(.category == "background_tasks" and .consequence == "keeps_running" and .ref.kind == "background_task")
         | (.ref.task_id | tostring) ]) as $regids
    | def offers($pr): ["finish", "park", "drop"] + (if $pr != null and ($ready | index($pr)) != null then ["wrap"] else [] end);
      def entry($e): $e + {choice_required: ($e.unlanded != "no"), offers: offers($e.pr), default: "park"};
    ( [ $items[]
        | select(.category == "background_tasks" and .consequence == "keeps_running" and .ref.kind == "background_task")
        | .ref as $r
        | entry({id: .id, source: "registry", kind: ($r.type // "task"), task_id: ($r.task_id | tostring),
                 summary: .summary, worktree: ($r.recovery_path // null), output_file: ($r.output_file // null), pr: null,
                 unlanded: (if ($r.type == "agent" or $r.type == "workflow") then "possible"
                            elif $r.recovery_path == null then "no"
                            elif ($lostwt | index($canon[$r.recovery_path] // $r.recovery_path)) != null then "yes"
                            else "possible" end)}) ]
      + [ $items[]
          | select(.category == "subagents" and .consequence == "keeps_running" and .ref.kind == "state_record"
                   and (((.ref.key | tostring) as $k | $regids | index($k)) == null))
          | entry({id: .id, source: "state_record", kind: "agent", task_id: (.ref.key | tostring),
                   summary: .summary, worktree: null, output_file: null, pr: (.ref.pr // null), unlanded: "possible"}) ]
      + [ $items[]
          | select(.category == "ceiling" and .consequence == "keeps_running")
          | entry({id: .id, source: "ceiling", kind: "ceiling", task_id: null, summary: .summary,
                   worktree: null, output_file: null, pr: null, unlanded: "no"}) ]
      # Harness-only findings the skill adds (Step 2): shells, Monitors, wake-ups, subagents
      # nothing registered. Skipped when the registry already names the same runtime id.
      + [ $items[]
          | select(.category == "harness_tasks" and .consequence == "keeps_running" and .ref.task_id != null
                   and (((.ref.task_id | tostring) as $k | $regids | index($k)) == null))
          | .ref as $r
          | entry({id: .id, source: "harness", kind: ($r.type // "task"), task_id: ($r.task_id | tostring),
                   summary: .summary, worktree: ($r.recovery_path // null), output_file: null, pr: ($r.pr // null),
                   unlanded: (if ($r.type == "agent" or $r.type == "workflow") then "possible" else "no" end)}) ]
      # A session this thread started is a separate conversation: its own question, never
      # a park/drop choice and never part of a group stop. Default is to leave it alone.
      + [ $items[]
          | select(.category == "linked_sessions" and .consequence == "keeps_running")
          | {id: .id, source: "linked_session", kind: "session",
             task_id: ((.ref.session_id // .ref.task_id // null) | if . == null then null else tostring end),
             summary: .summary, worktree: null, output_file: null, pr: null, unlanded: "no",
             choice_required: true, offers: ["keep", "stop"], default: "keep"} ]
    ) as $stop
    | { schema_version: 1,
        nothing_to_stop: ($stop | length == 0),
        menu_required: ($stop | length > 0),
        stop_items: $stop,
        unknown_items: [ $items[] | select(.consequence == "unknown") | {id, category, summary} ],
        excluded_count: ((.excluded // []) | length) }
  ' <<<"$inv" || die 3 "could not build the plan"
}

# ---------------------------------------------------------------- owner
do_owner() {
  [[ -n "$TASK_ID" ]] || die 2 "owner requires --task-id"
  [[ -n "$SESSION_STATE_SH" ]] || die 3 "session-state.sh not found; owner unknown"
  local rf="" prs out rc pmm1 pmm2 day1 day2 lv
  [[ -n "$REPO" ]] && rf="--repo $REPO"
  # shellcheck disable=SC2086
  prs="$("$SESSION_STATE_SH" $rf --get-json '.prs' 2>/dev/null)"; rc=$?
  if (( rc != 0 && rc != 3 )); then die 3 "could not read .prs (exit $rc); owner unknown"; fi
  if (( rc == 0 )); then
    out="$(jq -c --arg t "$TASK_ID" '
      if type != "object" then empty else
      [to_entries[] | select((.value | type) == "object" and ((.value.babysit.monitor_task_id // null) | tostring) == $t) | .key] | first // empty end' <<<"$prs" 2>/dev/null)" \
      || die 3 ".prs has an unexpected shape; owner unknown"
    if [[ -n "$out" ]]; then jq -nc --argjson r "$out" '{owner:"babysit",ref:$r}'; return 0; fi
  fi
  _get() { # <path> -> value; exit 3 aborts as unknown
    local v rc2
    # shellcheck disable=SC2086
    v="$("$SESSION_STATE_SH" $rf --get "$1" 2>/dev/null)"; rc2=$?
    if (( rc2 == 3 )); then printf 'null'; return 0; fi
    (( rc2 == 0 )) || die 3 "could not read $1 (exit $rc2); owner unknown"
    printf '%s' "${v:-null}"
  }
  pmm1="$(_get '.pmm_monitor_task_id')"; pmm2="$(_get '.pmm.auto_wake_monitor_task_id')"
  if [[ "$pmm1" == "$TASK_ID" || "$pmm2" == "$TASK_ID" ]]; then jq -nc '{owner:"pmm",ref:null}'; return 0; fi
  if [[ -n "$REPO" ]]; then
    day1="$(_get ".repos[\"$REPO\"].day.monitor_task_id")"
    day2="$(_get ".repos[\"$REPO\"].day.limit_resume_task_id")"
    lv="$(_get ".repos[\"$REPO\"].leave.winddown_task_id")"
    if [[ "$day1" == "$TASK_ID" ]]; then jq -nc '{owner:"day",ref:null}'; return 0; fi
    if [[ "$day2" == "$TASK_ID" ]]; then jq -nc '{owner:"day_limit_wake",ref:null}'; return 0; fi
    if [[ "$lv" == "$TASK_ID" ]]; then jq -nc '{owner:"leave_winddown",ref:null}'; return 0; fi
  fi
  jq -nc '{owner:"none",ref:null}'
}

# ---------------------------------------------------------------- park
do_park() {
  [[ -n "$SESSION" && -n "$REPO" && -n "$DECISIONS" ]] || die 2 "park requires --session, --repo and --decisions"
  [[ -n "$SESSION_STATE_SH" ]] || die 5 "session-state.sh not found; nothing was written"
  local dec sid stamp now key_safe owner name outdir tmp marker tag existing rc json merged
  dec="$(cat "$DECISIONS" 2>/dev/null)" || die 2 "cannot read $DECISIONS"
  jq -e '
    type == "object"
    and ((.parked // []) | type == "array")
    and ((.background_tasks_stopped // []) | type == "array")
    and ((.monitors_stopped // []) | type == "array")
    and (((.parked // []) | all(.[]; type == "object"
          and ((.kind // "") | type == "string" and length > 0)
          and ((.stopped_at // "") | type == "string" and length > 0)
          and ((.next_move // "") | type == "string" and length > 0)
          and ((.boundary // "") | type == "string" and length > 0))))
    and (((.background_tasks_stopped // []) + (.monitors_stopped // [])) | all(.[]; type == "object" and ((.task_id // "") | tostring | length > 0)))
    and (((.parked // []) | length) + ((.background_tasks_stopped // []) | length) + ((.monitors_stopped // []) | length) > 0)
  ' >/dev/null 2>&1 <<<"$dec" || die 2 "decisions file is invalid: each parked entry needs kind, stopped_at, next_move, boundary; stopped task entries need task_id; at least one entry is required"
  sid="${SESSION//[^[:alnum:]_.-]/_}"
  stamp="$(date -u +%Y%m%dT%H%M%SZ)"; now="$(date -u +%FT%TZ)"
  owner="${REPO%%/*}"; name="${REPO#*/}"
  key_safe="${#owner}-${owner}-${#name}-${name}"
  outdir="$HOME/.claude/handoffs"
  mkdir -p "$outdir" || die 5 "mkdir -p $outdir failed; nothing was written"
  tmp="$(mktemp "$outdir/.pause-marker.XXXXXX")" || die 5 "mktemp failed; nothing was written"
  tag="${tmp##*.pause-marker.}"
  marker="$outdir/pause-${stamp}-${key_safe}-${sid}-${tag}.md"
  {
    printf 'Repository: `%s`\n\n' "$REPO"
    printf '# Parked by /safe-close — %s\n\n' "$now"
    printf 'Session: %s\n\nParked units (resume with /go-on):\n' "$SESSION"
    jq -r '(.parked // [])[] | "- \(.kind) \(.ref // "") \(.branch // "") — \(.stopped_at) · next: \(.next_move) · boundary: \(.boundary)"' <<<"$dec"
    printf '\nStopped background tasks (re-armed on resume):\n'
    jq -r '(.background_tasks_stopped // [])[] | "- \(.type // "task") \(.task_id) \(.name // "")"' <<<"$dec"
    printf '\nStopped monitors:\n'
    jq -r '(.monitors_stopped // [])[] | "- \(.owner // "monitor") \(.task_id)"' <<<"$dec"
  } >"$tmp" || { rm -f "$tmp"; die 5 "could not write the marker; nothing was recorded"; }
  mv "$tmp" "$marker" || { rm -f "$tmp"; die 5 "could not publish the marker; nothing was recorded"; }
  chmod 644 "$marker" 2>/dev/null

  # Read, extend, write back under a compare-and-set: a concurrent writer to the same record
  # makes the CAS lose (exit 7) and the read-extend is redone, never clobbered.
  local attempt=0 wrote=0
  while (( attempt < 4 )); do
  attempt=$((attempt + 1))
  existing="$("$SESSION_STATE_SH" --get-json ".repos[\"$REPO\"].pauses[\"$sid\"]" 2>/dev/null)"; rc=$?
  if (( rc != 0 && rc != 3 )); then die 3 "could not read the existing pause record (exit $rc); not overwriting it blind (marker: $marker)"; fi
  [[ $rc -eq 3 || -z "$existing" ]] && existing="null"
  jq -e 'type == "null" or type == "object"' >/dev/null 2>&1 <<<"$existing" || die 3 "the existing pause record is damaged; not overwriting it (marker: $marker)"
  existing="$(jq -c . <<<"$existing")" || die 3 "could not normalise the existing pause record"
  json="$(jq -nc --argjson dec "$dec" --argjson ex "$existing" --arg sid "$sid" --arg now "$now" --arg marker "$marker" '
    def u($a; $b): (($a // []) + ($b // [])) | unique_by(tojson);
    (if $ex != null and ($ex.active != false) then $ex else null end) as $keep
    | { active: true, session_id: $sid, paused_at: ($keep.paused_at // $now), window_minutes: 0, window_expired: false,
        source: "safe-close",
        landed: ($keep.landed // []),
        parked: u($keep.parked; $dec.parked),
        monitors_stopped: u($keep.monitors_stopped; $dec.monitors_stopped),
        background_tasks_stopped: u($keep.background_tasks_stopped; $dec.background_tasks_stopped),
        refill_paused: ($keep.refill_paused // false), marker_path: $marker, resumed_at: null }')" || die 5 "could not build the pause record (marker: $marker)"
  "$SESSION_STATE_SH" --cas ".repos[\"$REPO\"].pauses[\"$sid\"]=$json" --expect "$existing" >/dev/null 2>&1; rc=$?
  if (( rc == 0 )); then wrote=1; break; fi
  (( rc == 7 )) || die 5 "session-state write failed (exit $rc); the marker at $marker is the only record"
  done
  (( wrote == 1 )) || die 5 "the pause record kept changing under us; the marker at $marker is the only record"
  jq -nc --arg m "$marker" --arg s "$sid" --arg r "$REPO" '{parked:true, marker_path:$m, state_path:(".repos[\"" + $r + "\"].pauses[\"" + $s + "\"]")}'
}

# ---------------------------------------------------------------- clear-ceiling
do_clear_ceiling() {
  [[ -n "$SESSION" ]] || die 2 "clear-ceiling requires --session"
  [[ -n "$REGISTRY_SH" ]] || die 3 "background-task-registry.sh not found; cannot confirm the owning Monitor is gone"
  [[ -n "$CEILING_SH" ]] || die 3 "bgwork-ceiling.sh not found"
  local live st rf=""
  [[ -n "$REPO" ]] && rf="--repo $REPO"
  # shellcheck disable=SC2086
  live="$("$REGISTRY_SH" $rf --list --session "$SESSION" --live 2>/dev/null)" && jq -e 'type == "array"' >/dev/null 2>&1 <<<"$live" \
    || die 3 "could not read the registry; not clearing the ceiling"
  if jq -e 'length > 0' >/dev/null <<<"$live"; then
    echo "safe-close-stop.sh: $(jq -r 'length' <<<"$live") task(s) are still live in the registry; the ceiling stays" >&2
    exit 1
  fi
  "$CEILING_SH" --clear --session "$SESSION" >/dev/null 2>&1 || die 3 "bgwork-ceiling.sh --clear failed"
  st="$("$CEILING_SH" --status --session "$SESSION" 2>/dev/null)" && jq -e '.background_work != null' >/dev/null 2>&1 <<<"$st" \
    || die 3 "could not re-read the ceiling after clearing"
  if [[ "$(jq -r '.background_work | length' <<<"$st")" != 0 ]]; then
    echo "safe-close-stop.sh: ceiling markers survived the clear" >&2
    exit 1
  fi
  echo '{"ceiling_cleared":true}'
}

# ---------------------------------------------------------------- verify
pid_alive() { # <pid>: alive unless absent or a zombie
  local s
  s="$(ps -p "$1" -o stat= 2>/dev/null)" || return 1
  s="${s//[[:space:]]/}"
  [[ -n "$s" && "$s" != Z* ]]
}
do_verify() {
  [[ -n "$SESSION" ]] || die 2 "verify requires --session"
  if [[ -z "$RUNTIME_FILE" && "$RUNTIME_UNREADABLE" == 0 ]]; then
    die 2 "verify needs the runtime's own task list (--runtime-live-file) or --runtime-unreadable; a stop's exit status is not evidence"
  fi
  local inv_sh inv rc live='[]' args pid alive='[]' result
  inv_sh="$(resolve_script safe-close-inventory.sh)" || die 3 "safe-close-inventory.sh not found; cannot re-check"
  if [[ -n "$RUNTIME_FILE" ]]; then
    live="$(cat "$RUNTIME_FILE" 2>/dev/null)" || die 3 "cannot read $RUNTIME_FILE"
    if ! jq -e 'type == "array"' >/dev/null 2>&1 <<<"$live"; then
      # An empty or blank file is a truncated read, not "no tasks": an empty list must be a JSON [].
      [[ -n "${live//[[:space:]]/}" ]] || die 3 "$RUNTIME_FILE is empty; write an empty task list as [] so a failed read is not taken for one"
      live="$(printf '%s\n' "$live" | jq -R -s -c 'split("\n") | map(select(length > 0))')" || die 3 "cannot parse $RUNTIME_FILE"
    fi
    live="$(jq -c 'map(tostring)' <<<"$live")" || die 3 "cannot parse $RUNTIME_FILE"
  fi
  args=(--session "$SESSION" --json)
  [[ -n "$REPO" ]] && args+=(--repo "$REPO")
  [[ -n "$WT" ]] && args+=(--worktree "$WT")
  [[ -n "$SCRATCH" ]] && args+=(--scratchpad "$SCRATCH")
  inv="$("$inv_sh" "${args[@]}" 2>/dev/null)"; rc=$?
  # 0 = safe, 1 = not yet (both print the JSON); anything else is a failed inventory.
  if (( rc > 1 )) || ! jq -e '.items | type == "array"' >/dev/null 2>&1 <<<"$inv"; then
    die 3 "the re-check inventory failed (exit $rc); cannot say nothing is running"
  fi
  for pid in $PIDS; do
    if pid_alive "$pid"; then alive="$(jq -c --arg p "$pid" '. + [$p]' <<<"$alive")"; fi
  done
  # Every runtime id this session registered, whatever its recorded status, is checked against
  # the runtime list too — not only the ids the caller remembered to name with --stopped-id.
  local regall='[]' rf=""
  [[ -n "$REGISTRY_SH" ]] || die 3 "background-task-registry.sh not found; cannot cross-check the runtime list"
  [[ -n "$REPO" ]] && rf="--repo $REPO"
  # shellcheck disable=SC2086
  regall="$("$REGISTRY_SH" $rf --list --session "$SESSION" 2>/dev/null)" && jq -e 'type == "array"' >/dev/null 2>&1 <<<"$regall" \
    || die 3 "could not read this session's registry records; cannot cross-check the runtime list"
  local regstop
  regstop="$(jq -c '[.[] | select(.status == "stopped" or .status == "stopping" or .status == "stop_failed") | .task_id | tostring]' <<<"$regall")" \
    || die 3 "could not parse the registry records"
  regall="$(jq -c '[.[] | .task_id | tostring]' <<<"$regall")" || die 3 "could not parse the registry records"
  result="$(jq -c --argjson live "$live" --argjson stopped "$STOPPED_IDS" --argjson gone "$GONE_IDS" --argjson regall "$regall" --argjson regstop "$regstop" \
      --argjson pids "$alive" --argjson unreadable "$RUNTIME_UNREADABLE" '
    def is_gone:
      .category == "subagents" and $unreadable == 0
      and ((.ref.key | tostring) as $k | (($gone | index($k)) != null) and (($live | index($k)) == null));
    .items as $items
    | ([ $items[]
         | select(.consequence == "keeps_running" and (.category == "background_tasks" or .category == "subagents" or .category == "ceiling"))
         | select(is_gone | not)
         | {id, what: .summary, why: "still recorded as running after the stop"} ]
       + [ ($stopped + $regall | unique)[] as $s | select($unreadable == 0 and (($live | index($s)) != null))
           | {id: $s, what: ("runtime still lists " + $s), why: "the stop did not take effect"} ]
       + [ $pids[] | {id: ("pid:" + .), what: ("process " + . + " is alive"), why: "the process survived"} ]) as $running
    | ([ $items[] | select(.consequence == "unknown") | {id, what: .summary, why: "could not be verified"} ]
       + (if $unreadable == 1 then [ ($stopped + $regstop | unique)[] | {id: ., what: ("runtime task list unreadable; " + . + " not confirmed gone"), why: "no runtime evidence"} ] else [] end)) as $unverified
    | { nothing_running: (($running | length) == 0 and ($unverified | length) == 0),
        still_running: $running, unverified: $unverified,
        left_for_cleanup: ([ $items[] | select(.consequence != "harmless" and .consequence != "unknown"
                              and (.consequence != "keeps_running" or (.category | IN("background_tasks","subagents","ceiling") | not))) ] | length) }
  ' <<<"$inv")" || die 3 "could not evaluate the re-check"
  if jq -e '.nothing_running' >/dev/null <<<"$result"; then
    echo "Nothing owned by this thread is still running."
    jq -r 'if .left_for_cleanup > 0 then "\(.left_for_cleanup) other item(s) (worktrees, branches, claims, bookkeeping) are left for cleanup." else empty end' <<<"$result"
    exit 0
  fi
  jq -r '"Not yet — \((.still_running | length) + (.unverified | length)) item(s) not confirmed stopped."' <<<"$result"
  jq -r '.still_running[] | "  [still running] \(.id): \(.what) — \(.why)"' <<<"$result"
  jq -r '.unverified[] | "  [unverified] \(.id): \(.what) — \(.why); not stopped"' <<<"$result"
  exit 1
}

case "$MODE" in
  plan) do_plan ;;
  owner) do_owner ;;
  park) do_park ;;
  clear-ceiling) do_clear_ceiling ;;
  verify) do_verify ;;
esac
