# shellcheck shell=bash
# desk/bin/lib/owner-tasks.sh — reads the operator's open human tasks for the
# desk (issue #2542). Sourced, never executed.
#
# The tasks live on GitHub, one list per repo, kept by owner-task.sh (issue
# #2538; .claude/reference/owner-tasks.md). The desk only reads them: it runs
# `owner-task.sh list --all-repos --json` and stores nothing, so there is no
# second copy of the data.
#
# hq_owner_tasks_read JSON_VAR REASON_VAR
#   On success returns 0 and puts, into JSON_VAR, a JSON array of the OPEN
#   tasks, each {id, repo, what, why, source, created_at, state, done_at,
#   proof}, ordered by repo, then oldest first; REASON_VAR is empty.
#   On failure returns 1 with JSON_VAR empty and one line in REASON_VAR. A
#   missing script, a non-zero exit, or output that is not a JSON array of
#   task objects is a failure, never "no tasks".
#
# owner-task.sh is resolved at run time, first executable of:
#   $HOME/.claude/skills-worktree/.claude/scripts/owner-task.sh
#   $HOME/.claude/scripts/owner-task.sh
#   .claude/scripts/owner-task.sh            (relative to the current directory)
# The two installed paths are skipped when HOME is unset or empty.

# hq_owner_tasks_script VAR — the resolved owner-task.sh path into VAR, or
# returns 1 with VAR empty.
hq_owner_tasks_script() {
  local hq__c
  printf -v "$1" '%s' ""
  for hq__c in "${HOME:+$HOME/.claude/skills-worktree/.claude/scripts/owner-task.sh}" \
               "${HOME:+$HOME/.claude/scripts/owner-task.sh}" \
               ".claude/scripts/owner-task.sh"; do
    if [ -n "$hq__c" ] && [ -f "$hq__c" ] && [ -x "$hq__c" ]; then
      printf -v "$1" '%s' "$hq__c"
      return 0
    fi
  done
  return 1
}

hq_owner_tasks_read() {
  local hq__json_var="$1" hq__reason_var="$2" hq__script hq__out hq__errf hq__rc hq__err
  printf -v "$hq__json_var" '%s' ""
  printf -v "$hq__reason_var" '%s' ""
  if ! command -v jq >/dev/null 2>&1; then
    printf -v "$hq__reason_var" '%s' "jq is not installed"
    return 1
  fi
  if ! hq_owner_tasks_script hq__script; then
    printf -v "$hq__reason_var" '%s' "owner-task.sh not found (checked ~/.claude/skills-worktree/.claude/scripts, ~/.claude/scripts, .claude/scripts)"
    return 1
  fi
  hq_mktemp hq__errf
  hq__rc=0
  hq__out=$("$hq__script" list --all-repos --json 2>"$hq__errf" </dev/null) || hq__rc=$?
  if [ "$hq__rc" -ne 0 ]; then
    # owner-task.sh's own one line, without its prefix, when it gave one.
    hq__err=$(sed -n '1{s/^owner-task: //;p;}' "$hq__errf" | tr -d '\r' | cut -c1-200)
    printf -v "$hq__reason_var" '%s' "owner-task.sh list exited $hq__rc${hq__err:+: $hq__err}"
    return 1
  fi
  # Exactly one JSON array whose every element is an object with a string id,
  # repo, and what; keep the open ones, ordered by repo, then oldest first.
  if ! hq__out=$(printf '%s' "$hq__out" | jq -ce -s '
        if length == 1 and (.[0] | type) == "array"
           and all(.[0][]; type == "object" and (.id | type) == "string"
                   and (.repo | type) == "string" and (.what | type) == "string")
        then .[0] | map(select(.state == "open")) | sort_by(.repo, (.created_at // ""), .id)
        else error("not a task list") end' 2>/dev/null); then
    printf -v "$hq__reason_var" '%s' "owner-task.sh list printed something that is not a task list"
    return 1
  fi
  printf -v "$hq__json_var" '%s' "$hq__out"
  return 0
}

# hq_owner_tasks_summary OBJ_VAR TEXT_VAR — the open-task count for the
# check-in (`checkin get --tasks`). Always returns 0: a list that cannot be
# read is reported, never fatal, so Decisions and Reviews still show.
#   OBJ_VAR   {"readable": true, "open": N, "reason": null}
#             or {"readable": false, "open": null, "reason": "..."}
#   TEXT_VAR  `2 open tasks` / `1 open task` / `0 open tasks`
#             or `task list could not be read`
hq_owner_tasks_summary() {
  local hq__obj_var="$1" hq__text_var="$2" hq__tasks hq__reason hq__n
  if hq_owner_tasks_read hq__tasks hq__reason; then
    hq__n=$(printf '%s' "$hq__tasks" | jq 'length')
    printf -v "$hq__obj_var" '{"readable":true,"open":%s,"reason":null}' "$hq__n"
    if [ "$hq__n" = 1 ]; then
      printf -v "$hq__text_var" '%s' "1 open task"
    else
      printf -v "$hq__text_var" '%s open tasks' "$hq__n"
    fi
  else
    if command -v jq >/dev/null 2>&1; then
      printf -v "$hq__obj_var" '%s' "$(jq -cn --arg r "$hq__reason" '{readable: false, open: null, reason: $r}')"
    else
      printf -v "$hq__obj_var" '%s' '{"readable":false,"open":null,"reason":"jq is not installed"}'
    fi
    printf -v "$hq__text_var" '%s' "task list could not be read"
  fi
  return 0
}
