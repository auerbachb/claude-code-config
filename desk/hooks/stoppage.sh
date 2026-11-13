#!/usr/bin/env bash
# desk/hooks/stoppage.sh — the stoppage log hook (issue #2292): on Stop, writes
# one short entry to the desk's private database when a turn ends with nothing
# running, nothing armed to wake it, and the assigned work not finished; on
# UserPromptSubmit, closes that entry with the idle time.
#
# Registered as .claude/hooks/stoppage-log.sh, a symlink to this file
# (global-settings.json: Stop and UserPromptSubmit). The contract is
# desk/docs/stoppages.md. In short:
#
# STOP — an entry is written only when ALL of these hold; any doubt means no
# entry (a missed entry is cheaper than a false one, and `/go-on` still records
# a session found dead):
#   1. the working directory is on a branch named issue-N-* (assigned work);
#   2. no planned stop: no active /pause or /end gate for the session or the
#      repo, and no declared leave time at or before now (its pause point);
#   3. nothing running: the background-work ledger and the task registry for
#      the session are empty and no recorded subagent works the issue;
#   4. nothing armed: no silence-ceiling watch (it only exists while work runs);
#   5. work not finished: uncommitted changes, unpushed commits, or a recorded
#      pipeline for the repo whose head is this checkout's HEAD.
# The cause is inferred from what the hook can see and is `unknown` otherwise:
# token_exhaustion / usage_limit from the recorded handoff reason,
# waiting_on_operator when the final message ends in a question,
# waiting_on_review when the recorded pipeline is in review.
# Evidence is a fixed-vocabulary line plus the branch name, never message text.
#
# An open marker (~/.claude/desk-stoppages/open/<session>) stops a second entry
# for the same stretch and tells UserPromptSubmit there is an idle time to add.
# The normal path of UserPromptSubmit is one file test.
#
# Fails open: no jq, bad JSON, an unreachable database, any error — nothing is
# printed and the exit status is 0. The database being down never blocks or
# fails a turn: the entry is kept locally by `stoppage record` and sent later.
#
# Test seams: HUMAN_QUEUE_CLI (the CLI), STOPPAGE_SCRIPTS_DIR (the helper
# scripts: execution-pause.sh, bgwork-ceiling.sh, background-task-registry.sh,
# session-state.sh), HUMAN_QUEUE_STOPPAGE_DIR (the keep directory).
#
# Bash 3.2 compatible (macOS /bin/bash).
set -u

stp_payload=$(cat 2>/dev/null) || exit 0
command -v jq >/dev/null 2>&1 || exit 0

stp_get() { printf '%s' "$stp_payload" | jq -r "$1 // empty" 2>/dev/null; }

stp_event=$(stp_get '.hook_event_name')
stp_sid_raw=$(stp_get '.session_id')
[ -n "$stp_sid_raw" ] || stp_sid_raw="${CLAUDE_SESSION_ID:-}"
stp_sid="${stp_sid_raw//[^A-Za-z0-9_.:-]/_}"
[ -n "$stp_sid" ] || exit 0
[ "${#stp_sid}" -le 200 ] || exit 0

if [ -n "${HUMAN_QUEUE_STOPPAGE_DIR:-}" ]; then
  stp_dir="${HUMAN_QUEUE_STOPPAGE_DIR%/}"
elif [ -n "${HOME:-}" ]; then
  stp_dir="$HOME/.claude/desk-stoppages"
else
  exit 0
fi
stp_marker="$stp_dir/open/$stp_sid"

# Resolve this file's real directory through any chain of symlinks (readlink -f
# is missing from older macOS), and keep the unresolved one for the scripts.
stp_self="${BASH_SOURCE[0]}"
stp_hooks_dir=$(cd "$(dirname "$stp_self")" 2>/dev/null && pwd) || exit 0
while [ -L "$stp_self" ]; do
  stp_ld=$(cd -P "$(dirname "$stp_self")" 2>/dev/null && pwd) || exit 0
  stp_self=$(readlink "$stp_self") || exit 0
  case "$stp_self" in
    /*) ;;
    *) stp_self="$stp_ld/$stp_self" ;;
  esac
done
stp_here=$(cd -P "$(dirname "$stp_self")" 2>/dev/null && pwd) || exit 0
stp_cli="${HUMAN_QUEUE_CLI:-$stp_here/../bin/human-queue.sh}"
[ -f "$stp_cli" ] || exit 0

# ---- UserPromptSubmit: the work resumed -------------------------------------
if [ "$stp_event" = "UserPromptSubmit" ]; then
  [ -f "$stp_marker" ] || exit 0
  # The marker stays when the command fails outright, so a later prompt retries;
  # a database that is down is not a failure (the operation is kept locally).
  if bash "$stp_cli" stoppage resume --thread "$stp_sid" >/dev/null 2>&1; then
    rm -f "$stp_marker" 2>/dev/null || true
  fi
  exit 0
fi

[ "$stp_event" = "Stop" ] || exit 0

# ---- Stop -------------------------------------------------------------------
# A stop another hook continued is not an idle stretch: close the entry the
# turn's first Stop opened (it is a few seconds old), and record nothing new.
if [ "$(stp_get '.stop_hook_active')" = "true" ]; then
  if [ -f "$stp_marker" ] && bash "$stp_cli" stoppage resume --thread "$stp_sid" >/dev/null 2>&1; then
    rm -f "$stp_marker" 2>/dev/null || true
  fi
  exit 0
fi
[ -f "$stp_marker" ] && exit 0

stp_cwd=$(stp_get '.cwd')
[ -n "$stp_cwd" ] || stp_cwd="$PWD"
[ -d "$stp_cwd" ] || exit 0

# 1. Assigned work: a branch named issue-N-*.
stp_branch=$(git -C "$stp_cwd" symbolic-ref --short -q HEAD 2>/dev/null) || exit 0
case "$stp_branch" in
  issue-[1-9]*-*) ;;
  *) exit 0 ;;
esac
stp_issue="${stp_branch#issue-}"
stp_issue="${stp_issue%%-*}"
case "$stp_issue" in
  ''|*[!0-9]*) exit 0 ;;
esac
[ "${#stp_issue}" -le 9 ] || exit 0

stp_scripts="${STOPPAGE_SCRIPTS_DIR:-}"
if [ -z "$stp_scripts" ]; then
  for stp_c in "${stp_hooks_dir%/hooks}/scripts" \
               "${HOME:+$HOME/.claude/skills-worktree/.claude/scripts}" \
               "${HOME:+$HOME/.claude/scripts}"; do
    if [ -n "$stp_c" ] && [ -x "$stp_c/bgwork-ceiling.sh" ]; then stp_scripts="$stp_c"; break; fi
  done
fi
# Without the ledger scripts "nothing is running" cannot be shown: no entry.
[ -n "$stp_scripts" ] || exit 0
for stp_c in bgwork-ceiling.sh execution-pause.sh session-state.sh; do
  [ -x "$stp_scripts/$stp_c" ] || exit 0
done

# The repo, from origin's owner/name only (a URL's credentials are never kept).
stp_repo="unknown"
stp_url=$(git -C "$stp_cwd" remote get-url origin 2>/dev/null) || stp_url=""
stp_re='([A-Za-z0-9_.-]+)/([A-Za-z0-9_.-]+)$'
stp_url="${stp_url%.git}"
if [[ $stp_url =~ $stp_re ]]; then stp_repo="${BASH_REMATCH[1]}/${BASH_REMATCH[2]}"; fi
stp_repo_lc=$(printf '%s' "$stp_repo" | tr '[:upper:]' '[:lower:]')

# 2. Planned stop. A gate that cannot be read is not "no gate".
for stp_k in "${CLAUDE_CODE_SESSION_ID:-}" "${CLAUDE_SESSION_ID:-}" "$stp_sid"; do
  [ -n "$stp_k" ] || continue
  stp_k="${stp_k//[^A-Za-z0-9_.:-]/_}"
  stp_gate=$("$stp_scripts/execution-pause.sh" --status --session "$stp_k" 2>/dev/null) || exit 0
  case "$stp_gate" in
    inactive) ;;
    *) exit 0 ;;
  esac
done

stp_repo_state="{}"
stp_all_agents="{}"
stp_rc=0
stp_out=$("$stp_scripts/session-state.sh" --get-json ".repos[\"$stp_repo_lc\"]" 2>/dev/null) || stp_rc=$?
case "$stp_rc" in
  0) [ "$stp_out" = "null" ] || stp_repo_state="$stp_out" ;;
  3) ;;
  *) exit 0 ;;
esac
stp_rc=0
stp_out=$("$stp_scripts/session-state.sh" --get-json ".active_agents" 2>/dev/null) || stp_rc=$?
case "$stp_rc" in
  0) [ "$stp_out" = "null" ] || stp_all_agents="$stp_out" ;;
  3) ;;
  *) exit 0 ;;
esac

stp_now=$(date +%s) || exit 0
stp_planned=$(printf '%s' "$stp_repo_state" | jq -r --argjson now "$stp_now" '
  ((.execution_pauses // {}) | to_entries
     | any(.value.active == true and ((.value.cleared_at // null) == null))) as $gate
  | ((.window.deadline_epoch // null) as $d
     | ((.leave.lead_minutes // 0) | if type == "number" then . else 0 end) as $lead
     | ($d != null and ($d | type) == "number" and $now >= ($d - $lead * 60))) as $leave
  | if $gate or $leave then "planned" else "none" end' 2>/dev/null) || exit 0
[ "$stp_planned" = "none" ] || exit 0

# 3. Nothing running, 4. nothing armed.
stp_bg=$("$stp_scripts/bgwork-ceiling.sh" --status --session "$stp_sid_raw" 2>/dev/null) || exit 0
stp_busy=$(printf '%s' "$stp_bg" | jq -r 'if ((.background_work // []) | length) > 0 or .armed == true then "busy" else "idle" end' 2>/dev/null) || exit 0
[ "$stp_busy" = "idle" ] || exit 0
if [ -x "$stp_scripts/background-task-registry.sh" ]; then
  stp_live=$("$stp_scripts/background-task-registry.sh" --list --live 2>/dev/null) || exit 0
  stp_n=$(printf '%s' "$stp_live" | jq -r --arg s "$stp_sid_raw" '[.[]? | select(.session_id == $s and (.stale != true))] | length' 2>/dev/null) || exit 0
  [ "$stp_n" = "0" ] || exit 0
fi
stp_agents=$(printf '%s' "$stp_all_agents" | jq -r --argjson n "$stp_issue" \
  '[to_entries[]? | select((.value.issue // 0) == $n and ((.value.status // "running") == "running"))] | length' 2>/dev/null) || exit 0
[ "$stp_agents" = "0" ] || exit 0

# 5. Work not finished.
stp_head=$(git -C "$stp_cwd" rev-parse HEAD 2>/dev/null) || exit 0
stp_signals=""
if [ -n "$(git -C "$stp_cwd" status --porcelain --untracked-files=normal 2>/dev/null)" ]; then
  stp_signals="uncommitted changes"
fi
stp_ahead=$(git -C "$stp_cwd" rev-list --count '@{upstream}..HEAD' 2>/dev/null) || stp_ahead=""
if [ -z "$stp_ahead" ]; then
  # No upstream yet (never pushed): commits past the default branch are unpublished.
  for stp_base in origin/main origin/master; do
    if git -C "$stp_cwd" rev-parse --verify -q "$stp_base" >/dev/null 2>&1; then
      stp_ahead=$(git -C "$stp_cwd" rev-list --count "$stp_base..HEAD" 2>/dev/null) || stp_ahead=""
      break
    fi
  done
fi
if [ -n "$stp_ahead" ] && [ "$stp_ahead" != "0" ]; then
  stp_signals="${stp_signals:+$stp_signals, }unpushed commits"
fi
stp_pr=$(printf '%s' "$stp_repo_state" | jq -c --arg h "$stp_head" '
  [(.prs // {}) | to_entries[]?
   | select((.value.head_sha // "") as $s | $s != "" and ($h | startswith($s)))
   | {pr: .key, phase: (.value.phase // ""), reason: (.value.handoff_reason // ""), reviewer: (.value.reviewer // "")}]
  | first // null' 2>/dev/null) || stp_pr="null"
stp_pr_no=""
stp_cause="unknown"
if [ -n "$stp_pr" ] && [ "$stp_pr" != "null" ]; then
  stp_pr_no=$(printf '%s' "$stp_pr" | jq -r '.pr' 2>/dev/null)
  stp_signals="${stp_signals:+$stp_signals, }recorded pipeline for PR $stp_pr_no"
  case "$(printf '%s' "$stp_pr" | jq -r '.reason' 2>/dev/null)" in
    token_exhaustion) stp_cause="token_exhaustion" ;;
    usage_limit_park) stp_cause="usage_limit" ;;
    *)
      case "$(printf '%s' "$stp_pr" | jq -r '.phase' 2>/dev/null)" in
        B) stp_cause="waiting_on_review" ;;
      esac
      ;;
  esac
fi
[ -n "$stp_signals" ] || exit 0

# The operator is the one being waited on when the final message ends in a
# question or carries a queue receipt; only the last line's shape is read, and
# none of it is stored.
if [ "$stp_cause" = "unknown" ]; then
  stp_last=$(stp_get '.last_assistant_message' | awk 'NF { l = $0 } END { print l }')
  stp_q='\?[[:space:]*_~]*$'
  if [[ $stp_last =~ $stp_q ]] || [[ $stp_last == *"sent to human queue"* ]] \
     || [[ $stp_last == *"recorded for the operator"* ]]; then
    stp_cause="waiting_on_operator"
  fi
fi

stp_safe_branch="${stp_branch//[^A-Za-z0-9._\/-]/_}"
stp_evidence="turn ended, nothing running or armed; branch ${stp_safe_branch:0:70}; $stp_signals"
stp_evidence="${stp_evidence:0:200}"

stp_args=(stoppage record --thread "$stp_sid" --repo "$stp_repo" --cause "$stp_cause" \
          --evidence "$stp_evidence" --source hook)
if [ -n "$stp_pr_no" ]; then
  stp_args+=(--ref "pr#$stp_pr_no")
else
  stp_args+=(--ref "issue#$stp_issue")
fi

if bash "$stp_cli" "${stp_args[@]}" >/dev/null 2>&1; then
  ( umask 077; mkdir -p "$stp_dir/open" && : >"$stp_marker" ) 2>/dev/null || true
fi
exit 0
