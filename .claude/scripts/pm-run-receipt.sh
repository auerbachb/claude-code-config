#!/usr/bin/env bash
# catalog: backlog-pm — Record and render the step receipt for a /pm invocation.
set -uo pipefail

usage() {
  cat <<'EOF'
Usage:
  pm-run-receipt.sh --start --mode cold|resume [--day] [--repo OWNER/REPO]
  pm-run-receipt.sh --mark STEP ran|skipped|failed [--why TEXT] [--run ID] [--repo OWNER/REPO]
  pm-run-receipt.sh --render [--run ID] [--repo OWNER/REPO]

--start prints a new run ID. --mark and --render take that ID or PM_RUN_ID.
Receipts are scoped to the repo and CLAUDE_SESSION_ID, or to the run ID when
the session ID is unavailable. Use non-secret reasons because session-state.sh
logs writes. A skipped or failed step needs a reason.
Exit codes: 0 success, 2 usage, 3 missing or superseded run, 4 unreadable state,
5 helper or write failure, 6 state contention.
EOF
}

die() {
  local status="$1"
  shift
  printf 'pm-run-receipt.sh: %s\n' "$*" >&2
  exit "$status"
}

case "${1:-}" in
  --help|-h) usage; exit 0 ;;
  --start|--mark|--render) action="$1"; shift ;;
  *) die 2 'choose --start, --mark or --render' ;;
esac

step="" outcome="" mode="" repo="" why="" day=false
run="${PM_RUN_ID:-}"
if [[ "$action" == --mark ]]; then
  [[ $# -ge 2 ]] || die 2 '--mark requires a step and outcome'
  step="$1"; outcome="$2"; shift 2
  case "$outcome" in
    ran|skipped|failed) ;;
    *) die 2 'outcome must be ran, skipped or failed' ;;
  esac
fi

while (( $# > 0 )); do
  case "$1" in
    --repo)
      [[ -n "${2:-}" ]] || die 2 '--repo requires a value'
      repo="$2"; shift 2 ;;
    --mode)
      [[ "$action" == --start && -n "${2:-}" ]] || die 2 '--mode is for --start'
      mode="$2"; shift 2 ;;
    --day)
      [[ "$action" == --start ]] || die 2 '--day is for --start'
      day=true; shift ;;
    --run)
      [[ "$action" != --start && -n "${2:-}" ]] || die 2 '--run is for --mark and --render'
      run="$2"; shift 2 ;;
    --why)
      [[ "$action" == --mark && -n "${2:-}" ]] || die 2 '--why is for --mark'
      why="$2"; shift 2 ;;
    *) die 2 "unknown argument: $1" ;;
  esac
done
if [[ "$action" == --start ]]; then
  [[ "$mode" == cold || "$mode" == resume ]] || die 2 'mode must be cold or resume'
else
  [[ "$run" =~ ^pm-[A-Za-z0-9-]{1,100}$ ]] || die 2 'supply the run ID with --run or PM_RUN_ID'
fi

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)" || die 5 'cannot resolve script directory'
state=""
for candidate in "$script_dir/session-state.sh" \
  "${HOME:+$HOME/.claude/skills-worktree/.claude/scripts/session-state.sh}" \
  "${HOME:+$HOME/.claude/scripts/session-state.sh}" ".claude/scripts/session-state.sh"; do
  if [[ -x "$candidate" ]]; then state="$candidate"; break; fi
done
[[ -n "$state" ]] || die 5 'cannot find session-state.sh'
command -v jq >/dev/null || die 5 'jq is unavailable'

repo=$("$state" ${repo:+--repo} ${repo:+"$repo"} --repo-key) || die 4 'cannot resolve the repository key'
[[ -n "$repo" ]] || die 4 'empty repository key'

if [[ "$action" == --start ]]; then
  started_at=$(date -u +%Y-%m-%dT%H:%M:%SZ) || die 5 'cannot read UTC time'
  run="pm-${started_at//[-:]/}-$$-$RANDOM"
fi
session="${CLAUDE_SESSION_ID:-$run}"
if [[ "$action" == --start && -z "${CLAUDE_SESSION_ID:-}" ]]; then
  printf 'pm-run-receipt.sh: CLAUDE_SESSION_ID missing; scoping receipt to the run ID\n' >&2
fi
[[ "$session" =~ ^[A-Za-z0-9_-]{1,120}$ ]] || die 2 'invalid session ID'
repo_json=$(jq -cn --arg v "$repo" '$v') || die 5 'cannot encode repository key'
session_json=$(jq -cn --arg v "$session" '$v') || die 5 'cannot encode session ID'
receipts_path=".repos[$repo_json].pm_receipts"
receipt_path="$receipts_path[$session_json]"

read_state() {
  local value status=0
  value=$("$state" --repo "$repo" --get-json "$1" 2>/dev/null) || status=$?
  case "$status" in
    0) printf '%s\n' "$value" ;;
    3) printf 'null\n' ;;
    *) return 4 ;;
  esac
}

start_receipt() {
  local record previous updated status attempt
  record=$(jq -cn --arg run "$run" --arg session "$session" --arg mode "$mode" \
    --argjson day "$day" --arg time "$started_at" '
    {run_id:$run, session:$session, mode:$mode, day:$day, started_at:$time,
     expected:["0","0a","0b",(if $mode == "cold" then "1B" else "1A" end),"1C","1D",
               (if $day then "2D" else "2" end),"3.1","3.2","3.4"], steps:{}}
  ') || die 5 'cannot build the receipt'

  for attempt in 1 2 3 4 5; do
    previous=$(read_state "$receipts_path") || die 4 'cannot read repository receipts'
    updated=$(jq -ce --arg session "$session" --argjson record "$record" '
      if . == null then {} elif type == "object" then . else error("invalid receipt map") end
      | del(.[$session]) | to_entries
      | sort_by(.value.started_at, .key) | .[-19:] | from_entries
      | .[$session] = $record
    ' <<<"$previous") || die 4 'cannot read repository receipts'
    status=0
    "$state" --repo "$repo" --cas "$receipts_path=$updated" --expect "$previous" >/dev/null || status=$?
    case "$status" in
      0) printf '%s\n' "$run"; return 0 ;;
      6) die 6 'receipt state is locked' ;;
      7) continue ;;
      *) die 5 'cannot write the receipt' ;;
    esac
  done
  die 6 'receipt state changed during every attempt'
}

if [[ "$action" == --start ]]; then start_receipt; exit 0; fi

receipt=$(read_state "$receipt_path") || die 4 'cannot read the receipt'
if ! jq -e --arg run "$run" --arg session "$session" '
    type == "object" and .run_id == $run and .session == $session
  ' <<<"$receipt" >/dev/null; then
  if [[ "$action" == --render ]]; then printf 'PM receipt unavailable for this run.\n'; fi
  die 3 'receipt is missing or superseded'
fi
if ! jq -e '
    (.mode | IN("cold", "resume")) and (.day | type == "boolean")
    and (.expected | type == "array" and length == 10 and (unique | length == 10)
      and all(.[]; IN("0", "0a", "0b", "1A", "1B", "1C", "1D", "2", "2D", "3.1", "3.2", "3.4")))
    and (.steps | type == "object" and all(.[];
      type == "object" and (.outcome | IN("ran", "skipped", "failed"))
      and (.why | type == "string" and length <= 120 and (test("[[:cntrl:]]") | not))))
  ' <<<"$receipt" >/dev/null; then
  die 4 'invalid receipt shape'
fi

if [[ "$action" == --render ]]; then
  jq -r --arg repo "$repo" '
    . as $receipt
    | (["PM receipt · \($repo) · \(.mode)\(if .day then " day" else "" end)"]
      + [.expected[] | . as $step | $receipt.steps[$step] as $mark
        | if $mark == null then "\($step) not recorded ⚠"
          elif $mark.why == "" then "\($step) \($mark.outcome)"
          else "\($step) \($mark.outcome) (\($mark.why))" end])[]
  ' <<<"$receipt" || die 4 'cannot render the receipt'
  exit 0
fi

jq -e --arg step "$step" '.expected | index($step) != null' <<<"$receipt" >/dev/null ||
  die 2 'step is outside this invocation mode'
mark=$(jq -cn --arg outcome "$outcome" --arg why "$why" '
  {outcome:$outcome, why:($why | gsub("[[:cntrl:][:space:]]+"; " ") | gsub("^ +| +$"; "") | .[0:120])}
') || die 5 'cannot encode the step outcome'
if [[ "$outcome" != ran ]] && ! jq -e '.why | length > 0' <<<"$mark" >/dev/null; then
  die 2 'a skipped or failed step needs --why'
fi
run_json=$(jq -cn --arg value "$run" '$value') || die 5 'cannot encode the run ID'
step_json=$(jq -cn --arg value "$step" '$value') || die 5 'cannot encode the step ID'
status=0
"$state" --repo "$repo" --cas "$receipt_path.run_id=$run_json" --expect "$run_json" \
  --set "$receipt_path.steps[$step_json]=$mark" >/dev/null || status=$?
case "$status" in
  0) ;;
  6) die 6 'receipt state is locked' ;;
  7) die 3 'receipt was superseded before the mark' ;;
  *) die 5 'cannot write the step outcome' ;;
esac
