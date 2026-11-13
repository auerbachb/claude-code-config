#!/usr/bin/env bash
# stoppage-note.sh — the orchestration steps' one call into the stoppage log
# (issue #2292): they know two facts the Stop hook cannot see, and say them here.
# catalog: utilities — Records the stoppage causes only an orchestrator knows (`out_of_work`, `blocked_by_error`) in the desk's private database (`desk/bin/stoppage-note.sh`)
#
# USAGE
#   stoppage-note.sh refill  --picked N [--reason TEXT] [--repo OWNER/NAME]
#   stoppage-note.sh blocked --phase A|B|C (--pr N | --issue N) --reason TEXT [--repo OWNER/NAME]
#
# refill   /subagent Step 8 item 4 and /pm's refill call this once per refill
#          evaluation. N is how many pipelines the evaluation launched.
#            N > 0  work is running again: an entry left open for this session is
#                   closed with its idle time (`stoppage resume`).
#            N = 0  and TEXT starts with `nothing eligible`: the slot stays empty
#                   because there is nothing left to launch, so one `out_of_work`
#                   entry is written. Any other idle reason (chained, paused,
#                   budget, horizon, priority, deadline) is a held or planned
#                   state, not running out of work: nothing is written. Nothing is
#                   written either while a recorded subagent still works one of
#                   this repo's pipelines (the thread is not stopped), during a
#                   /pause or /end gate, or at a declared leave time's pause point.
# blocked  a pipeline ended blocked on an error with no recovery under way (a
#          Phase B `blocked_self_review`, a Phase C `blocked`): one
#          `blocked_by_error` entry naming the phase and a one-line reason, also
#          while other pipelines run, but not during a /pause or /end gate or at
#          a leave time's pause point (that result is the wind-down).
#
# One entry per stretch: an open marker for the session (the Stop hook's own,
# ~/.claude/desk-stoppages/open/<session>) means an entry already stands, so
# neither command writes a second; the thread's next prompt, or a `refill` that
# launched work, closes it. The entry carries the fields the log always carries
# (thread, repo, ref, cause, one evidence line of a fixed vocabulary plus the
# caller's short reason, source `manual`); no transcript text.
#
# Fails open and silent: no jq, no session id, an unreachable database, any
# error - nothing is printed and the exit status is 0 (a usage error exits 2).
# An unreachable database keeps the entry locally, like every stoppage write.
# The connection string is never read here: all database access goes through
# desk-cli.sh and `human-queue.sh stoppage`.
#
# ENVIRONMENT
#   CLAUDE_SESSION_ID          the thread (the entry's `thread`)
#   HUMAN_QUEUE_CLI            run this program instead of desk-cli.sh (tests)
#   HUMAN_QUEUE_STOPPAGE_DIR   where markers and kept entries live
#   STOPPAGE_SCRIPTS_DIR       where session-state.sh and execution-pause.sh are
#
# Bash 3.2 compatible (macOS /bin/bash).
set -u

sn_usage() {
  printf '%s\n' 'usage: stoppage-note.sh refill --picked N [--reason TEXT] [--repo OWNER/NAME]' >&2
  printf '%s\n' '       stoppage-note.sh blocked --phase A|B|C (--pr N | --issue N) --reason TEXT [--repo OWNER/NAME]' >&2
  exit 2
}

sn_mode="${1:-}"
case "$sn_mode" in
  refill|blocked) shift ;;
  --help|-h) sed -n '2,38p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
  *) sn_usage ;;
esac

sn_picked=""; sn_reason=""; sn_repo=""; sn_phase=""; sn_pr=""; sn_issue=""
while [ "$#" -gt 0 ]; do
  [ "$#" -ge 2 ] || sn_usage
  case "$1" in
    --picked) sn_picked="$2" ;;
    --reason) sn_reason="$2" ;;
    --repo) sn_repo="$2" ;;
    --phase) sn_phase="$2" ;;
    --pr) sn_pr="$2" ;;
    --issue) sn_issue="$2" ;;
    *) sn_usage ;;
  esac
  shift 2
done
case "$sn_mode" in
  refill)
    case "$sn_picked" in ''|*[!0-9]*) sn_usage ;; esac
    ;;
  blocked)
    case "$sn_phase" in A|B|C) ;; *) sn_usage ;; esac
    [ -n "$sn_reason" ] || sn_usage
    if [ -n "$sn_pr" ]; then
      case "$sn_pr" in *[!0-9]*) sn_usage ;; esac
    else
      case "$sn_issue" in ''|*[!0-9]*) sn_usage ;; esac
    fi
    ;;
esac

command -v jq >/dev/null 2>&1 || exit 0

sn_sid="${CLAUDE_SESSION_ID:-}"
[ -n "$sn_sid" ] || exit 0
sn_sid="${sn_sid//[^A-Za-z0-9_.:-]/_}"
[ "${#sn_sid}" -le 200 ] || exit 0

if [ -n "${HUMAN_QUEUE_STOPPAGE_DIR:-}" ]; then
  sn_dir="${HUMAN_QUEUE_STOPPAGE_DIR%/}"
elif [ -n "${HOME:-}" ]; then
  sn_dir="$HOME/.claude/desk-stoppages"
else
  exit 0
fi
sn_marker="$sn_dir/open/$sn_sid"

# This file's real directory, through any chain of symlinks.
sn_self="${BASH_SOURCE[0]}"
while [ -L "$sn_self" ]; do
  sn_ld=$(cd -P "$(dirname "$sn_self")" 2>/dev/null && pwd) || exit 0
  sn_self=$(readlink "$sn_self") || exit 0
  case "$sn_self" in
    /*) ;;
    *) sn_self="$sn_ld/$sn_self" ;;
  esac
done
sn_here=$(cd -P "$(dirname "$sn_self")" 2>/dev/null && pwd) || exit 0
sn_cli="${HUMAN_QUEUE_CLI:-$sn_here/desk-cli.sh}"
[ -f "$sn_cli" ] || exit 0

# The repo, from origin's owner/name only (a URL's credentials are never kept).
if [ -z "$sn_repo" ]; then
  sn_repo="unknown"
  sn_url=$(git remote get-url origin 2>/dev/null) || sn_url=""
  sn_re='([A-Za-z0-9_.-]+)/([A-Za-z0-9_.-]+)$'
  sn_url="${sn_url%.git}"
  if [[ $sn_url =~ $sn_re ]]; then sn_repo="${BASH_REMATCH[1]}/${BASH_REMATCH[2]}"; fi
fi
sn_re='^[A-Za-z0-9_.-]{1,100}/[A-Za-z0-9_.-]{1,100}$'
[[ $sn_repo =~ $sn_re ]] || sn_repo="unknown"

# ---- refill that launched work: the thread is running again -----------------
if [ "$sn_mode" = "refill" ] && [ "$sn_picked" != "0" ]; then
  [ -f "$sn_marker" ] || exit 0
  if bash "$sn_cli" stoppage resume --thread "$sn_sid" >/dev/null 2>&1; then
    rm -f "$sn_marker" 2>/dev/null || true
  fi
  exit 0
fi

# One entry per stretch.
[ -f "$sn_marker" ] && exit 0

# A one-line reason in the entry's own vocabulary: no control characters, no
# quotes, a bounded length. The CLI also refuses anything shaped like a secret.
sn_clean() {
  local v="${1//[^A-Za-z0-9 ._:()#\/,=>-]/ }"
  v=$(printf '%s' "$v" | tr -s ' ' | sed 's/^ //; s/ $//')
  printf '%s' "${v:0:$2}"
}

sn_cause=""; sn_evidence=""; sn_ref=""

if [ "$sn_mode" = "refill" ]; then
  case "$sn_reason" in
    "nothing eligible"*) ;;
    *) exit 0 ;;
  esac
fi
sn_scripts="${STOPPAGE_SCRIPTS_DIR:-}"
if [ -z "$sn_scripts" ]; then
  for sn_c in "${HOME:+$HOME/.claude/skills-worktree/.claude/scripts}" \
              "${HOME:+$HOME/.claude/scripts}" \
              "$sn_here/../../.claude/scripts"; do
    if [ -n "$sn_c" ] && [ -x "$sn_c/session-state.sh" ]; then sn_scripts="$sn_c"; break; fi
  done
fi
# Without the state helpers "this is not a planned stop" cannot be shown: no entry.
[ -n "$sn_scripts" ] || exit 0
for sn_c in session-state.sh execution-pause.sh; do
  [ -x "$sn_scripts/$sn_c" ] || exit 0
done
# A planned stop is not a stoppage; an unreadable gate is not "no gate". A phase
# result that arrives after /pause or /end is the wind-down, not an error.
sn_gate=$("$sn_scripts/execution-pause.sh" --status --session "$sn_sid" 2>/dev/null) || exit 0
[ "$sn_gate" = "inactive" ] || exit 0

sn_lc=$(printf '%s' "$sn_repo" | tr '[:upper:]' '[:lower:]')
sn_state="{}"; sn_rc=0
sn_out=$("$sn_scripts/session-state.sh" --get-json ".repos[\"$sn_lc\"]" 2>/dev/null) || sn_rc=$?
case "$sn_rc" in
  0) [ "$sn_out" = "null" ] || sn_state="$sn_out" ;;
  3) ;;
  *) exit 0 ;;
esac
sn_agents="{}"
if [ "$sn_mode" = "refill" ]; then
  sn_rc=0
  # The repo-scoped session view: the global active_agents map keys no repo on a
  # spawn record, so a same-numbered issue's agent in another repo would hide
  # this repo's idle slot.
  sn_out=$("$sn_scripts/session-state.sh" --repo "$sn_lc" --session-view 2>/dev/null) || sn_rc=$?
  case "$sn_rc" in
    0) sn_agents=$(printf '%s' "$sn_out" | jq -c '.active_agents // {}' 2>/dev/null) || exit 0 ;;
    3) ;;
    *) exit 0 ;;
  esac
  [ -n "$sn_agents" ] || sn_agents="{}"
fi
sn_now=$(date +%s) || exit 0
# The repo's pipelines (issue-keyed, this repo only) and this session's round
# name the issues this thread works. Not at a leave time's pause point; and an
# empty slot is a stoppage only when none of those issues still has a running
# or just-spawned subagent (a blocked pipeline is logged either way).
sn_busy=$(jq -rn --argjson st "$sn_state" --argjson ag "$sn_agents" --argjson now "$sn_now" \
    --arg sid "$sn_sid" --arg mode "$sn_mode" '
  ((($st.pipelines // {}) | keys)
    + ((($st.rounds // {})[$sid] // {}) | (.members // []) | map(tostring))) as $mine
  | (($st.window.deadline_epoch // null) as $d
     | (($st.leave.lead_minutes // 0) | if type == "number" then . else 0 end) as $lead
     | ($d != null and ($d | type) == "number" and $now >= ($d - $lead * 60))) as $leave
  | ([$ag | to_entries[]?
      | select(((.value.issue // 0) | tostring) as $i | ($mine | index($i)) != null
               and ((.value.status // "running") | . == "running" or . == "spawned"))] | length) as $running
  | if $leave or ($mode == "refill" and $running > 0) then "busy" else "idle" end' 2>/dev/null) || exit 0
[ "$sn_busy" = "idle" ] || exit 0

if [ "$sn_mode" = "blocked" ]; then
  sn_cause="blocked_by_error"
  sn_evidence="phase $sn_phase blocked: $(sn_clean "$sn_reason" 150)"
  if [ -n "$sn_pr" ]; then sn_ref="pr#$sn_pr"; else sn_ref="issue#$sn_issue"; fi
else
  sn_cause="out_of_work"
  sn_evidence="slot idle: $(sn_clean "$sn_reason" 170)"
  sn_first=$(printf '%s' "$sn_state" | jq -r --arg sid "$sn_sid" \
    '((.rounds // {})[$sid] // {}) | (.members // [])[0] // empty | tostring' 2>/dev/null) || sn_first=""
  case "$sn_first" in
    ''|*[!0-9]*) ;;
    *) [ "${#sn_first}" -le 9 ] && sn_ref="issue#$sn_first" ;;
  esac
fi

sn_evidence="${sn_evidence:0:200}"
sn_at=$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null) || exit 0
sn_args=(stoppage record --thread "$sn_sid" --repo "$sn_repo" --cause "$sn_cause" \
         --evidence "$sn_evidence" --source manual --at "$sn_at")
[ -n "$sn_ref" ] && sn_args+=(--ref "$sn_ref")

if bash "$sn_cli" "${sn_args[@]}" >/dev/null 2>&1; then
  ( umask 077; mkdir -p "$sn_dir/open" && printf '%s\n' "$sn_at" >"$sn_marker" ) 2>/dev/null || true
fi
exit 0
