#!/usr/bin/env bash
# pm-human-tasks.sh — Save /pm's operator-only items to the human-task list and count the open ones, as compact lines.
# catalog: backlog-pm — `/pm` human tasks (issue #2563): save each operator-only item /pm surfaces through `owner-task.sh add`, skipping one already on the list for the same what and source (done ones included), and count the repo's open tasks from `owner-task.sh list --json`, reporting an unreadable list as unreadable, never as zero
#
# PURPOSE
#   /pm is a premium-model parent (.claude/reference/lean-orchestrator.md): it
#   must not read the task list itself. This script does the reading, the
#   duplicate check and the save, and prints a few KEY=value lines the parent
#   acts on. Storage, reasons and exit codes belong to owner-task.sh
#   (.claude/reference/owner-tasks.md); nothing here writes to GitHub except
#   through `owner-task.sh add`.
#
# USAGE
#   pm-human-tasks.sh count [--repo OWNER/NAME]
#   pm-human-tasks.sh save --source REF (--what TEXT --why "REASON: free text"
#                          | --owner-action LINE) [--repo OWNER/NAME]
#   pm-human-tasks.sh --help | -h
#
# VERBS
#   count  Open human tasks for the repo, from `owner-task.sh list --json`.
#            HUMAN_TASKS=<N>            exit 0
#            HUMAN_TASKS=unreadable     exit 4 (list exited non-zero or
#                                       printed something that is not an array)
#            HUMAN_TASKS=unavailable    exit 7 (owner-task.sh not found)
#          then LINE=<the report line /pm prints as is>.
#
#   save   One operator-only item. --owner-action takes a sub-agent's
#          `OWNER_ACTION: <reason>: <what> — <free text>` line (the
#          `OWNER_ACTION=` form exit-report-extract.sh forwards works too) and
#          splits it into --what and --why.
#            RESULT=saved ID=<ht-…>     exit 0
#            RESULT=skipped ID=<ht-…>   exit 0 (same what and source already
#                                       on the list, open or done)
#            RESULT=not_saved EXIT=<n>  exit n (owner-task.sh's code; 4 when
#                                       the duplicate check could not read the
#                                       list, 7 when owner-task.sh is missing,
#                                       2 when an --owner-action line names no
#                                       reason: nothing written, none guessed;
#                                       5 when any field looks like a secret,
#                                       here or in owner-task.sh: the LINE then
#                                       names the field, never the text)
#          Task text appears in a LINE only after every field passed the
#          desk/bin/lib/secrets.sh screen; without that library it is withheld.
#          then LINE=<the receipt or not-saved line /pm prints as is>.
#          An add that exits 1 (ambiguous write) is followed by one more list:
#          when the task is now there it is reported as saved, never re-added;
#          when that list fails too it prints RESULT=unconfirmed EXIT=1
#          (exit 1), never not_saved, since the task may exist.
#
# ENVIRONMENT
#   OWNER_TASK_SH  path to owner-task.sh (tests). Otherwise the first
#                  executable of ~/.claude/skills-worktree/.claude/scripts/,
#                  ~/.claude/scripts/, .claude/scripts/, then this script's
#                  own directory.
#
# EXIT CODES
#   0 counted / saved / skipped; 2 usage; otherwise the code above.
#
# Bash 3.2 compatible. Requires jq.

set -euo pipefail

usage() { sed -n '2,/^# Bash 3.2/p' "$0" | sed 's/^# \{0,1\}//'; }

die_usage() { printf 'pm-human-tasks: %s\n' "$*" >&2; exit 2; }

command -v jq >/dev/null 2>&1 || { printf 'pm-human-tasks: jq is required\n' >&2; exit 1; }

resolve_owner_task() {
  local cand self_dir
  if [ -n "${OWNER_TASK_SH:-}" ]; then
    [ -x "$OWNER_TASK_SH" ] && { printf '%s\n' "$OWNER_TASK_SH"; return 0; }
    return 1
  fi
  self_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  for cand in "${HOME:+$HOME/.claude/skills-worktree/.claude/scripts/owner-task.sh}" \
              "${HOME:+$HOME/.claude/scripts/owner-task.sh}" \
              ".claude/scripts/owner-task.sh" \
              "$self_dir/owner-task.sh"; do
    [ -n "$cand" ] && [ -x "$cand" ] && { printf '%s\n' "$cand"; return 0; }
  done
  return 1
}

# One line, no control characters, bounded: the parent prints it verbatim.
one_line() { printf '%s' "$1" | tr '\r\n\t' '   ' | cut -c1-300; }

# list_all OT REPO_ARGS... -> the full list (open and done) as one JSON array.
list_all() {
  local ot="$1" out
  shift
  out="$("$ot" list --all --json "$@" 2>/dev/null)" || return 4
  printf '%s' "$out" | jq -e 'type == "array"' >/dev/null 2>&1 || return 4
  printf '%s' "$out"
}

# find_same LIST WHAT SOURCE -> id of a task with the same what and source.
find_same() {
  printf '%s' "$1" | jq -r --arg w "$2" --arg s "$3" '
    def norm: gsub("^\\s+|\\s+$"; "") | gsub("\\s+"; " ");
    [.[] | select(((.what // "") | norm) == ($w | norm)
                  and ((.source // "") | norm) == ($s | norm))][0].id // empty'
}

cmd_count() {
  local repo="" ot out n rc where
  while [ $# -gt 0 ]; do
    case "$1" in
      --repo) [ $# -ge 2 ] || die_usage "--repo needs a value"; repo="$2"; shift 2 ;;
      *) die_usage "count: unknown argument $(arg_name "$1")" ;;
    esac
  done
  where="${repo:-this repo}"
  if ! ot="$(resolve_owner_task)"; then
    printf 'HUMAN_TASKS=unavailable\n'
    printf 'LINE=Human tasks: count unknown (owner-task.sh not found)\n'
    return 7
  fi
  rc=0
  out="$("$ot" list --json ${repo:+--repo "$repo"} 2>/dev/null)" || rc=$?
  if [ "$rc" -ne 0 ] || ! n="$(printf '%s' "$out" | jq -e 'if type == "array" then length else error("not an array") end' 2>/dev/null)"; then
    [ "$rc" -ne 0 ] || rc=4
    printf 'HUMAN_TASKS=unreadable\n'
    printf 'LINE=Human tasks: list unreadable for %s (owner-task.sh exit %s) — count unknown, not zero\n' "$where" "$rc"
    return 4
  fi
  printf 'HUMAN_TASKS=%s\n' "$n"
  printf 'LINE=Human tasks: %s open for %s\n' "$n" "$where"
}

# Name an unknown argument only when it is a flag: a stray value may be task
# text, and task text is never echoed before it is screened.
arg_name() { case "$1" in -*) printf "'%s'" "$(one_line "$1" | cut -c1-40)" ;; *) printf '(a value)' ;; esac; }

# ---- secret screen --------------------------------------------------------------
# The same checker owner-task.sh uses (desk/bin/lib/secrets.sh). Task text is
# printed in a LINE only after every field passed it: a refused or unscreened
# value never reaches /pm's report, chat or logs.
SECRETS_STATE=""  # "" not tried, ok, missing
load_secret_checker() {
  [ -n "$SECRETS_STATE" ] && { [ "$SECRETS_STATE" = ok ]; return; }
  local self dir cand
  self="${BASH_SOURCE[0]}"
  while [ -L "$self" ]; do
    dir="$(cd "$(dirname "$self")" && pwd)"
    self="$(readlink "$self")"
    case "$self" in /*) ;; *) self="$dir/$self" ;; esac
  done
  dir="$(cd "$(dirname "$self")" && pwd)"
  for cand in "${PM_HT_SECRETS_LIB:-}" "$dir/../../desk/bin/lib/secrets.sh" \
              "${HOME:+$HOME/.claude/skills-worktree/desk/bin/lib/secrets.sh}"; do
    if [ -n "$cand" ] && [ -r "$cand" ]; then
      # shellcheck source=/dev/null
      . "$cand"
      SECRETS_STATE=ok
      return 0
    fi
  done
  SECRETS_STATE=missing
  return 1
}

# looks_secret VALUE -> 0 when VALUE looks like a credential.
looks_secret() { ( hq__secret_class "$1" ) >/dev/null 2>&1; }

SHOW_TEXT=0  # 1 once what/why/source passed the screen
WITHHELD="not screened for secrets"
shown() { if [ "$SHOW_TEXT" -eq 1 ]; then one_line "$1"; else printf '(task text withheld: %s)' "$WITHHELD"; fi; }

not_saved() { # CODE WHAT REASON
  printf 'RESULT=not_saved EXIT=%s\n' "$1"
  printf 'LINE=not saved to the human-task list: %s — %s\n' "$(shown "$2")" "$(one_line "$3")"
  return "$1"
}

cmd_save() {
  local repo="" what="" why="" source="" action="" ot list id rc reason err errf rest
  while [ $# -gt 0 ]; do
    case "$1" in
      --what) [ $# -ge 2 ] || die_usage "--what needs a value"; what="$2"; shift 2 ;;
      --why) [ $# -ge 2 ] || die_usage "--why needs a value"; why="$2"; shift 2 ;;
      --source) [ $# -ge 2 ] || die_usage "--source needs a value"; source="$2"; shift 2 ;;
      --owner-action) [ $# -ge 2 ] || die_usage "--owner-action needs a value"; action="$2"; shift 2 ;;
      --repo) [ $# -ge 2 ] || die_usage "--repo needs a value"; repo="$2"; shift 2 ;;
      *) die_usage "save: unknown argument $(arg_name "$1")" ;;
    esac
  done
  [ -z "$action" ] || [ -z "$what$why" ] || die_usage "save: --owner-action replaces --what and --why"
  # Screen every field before any of it can be printed or sent anywhere.
  if load_secret_checker; then
    local field
    for field in owner-action what why source; do
      case "$field" in
        owner-action) rest="$action" ;; what) rest="$what" ;; why) rest="$why" ;; source) rest="$source" ;;
      esac
      if [ -n "$rest" ] && looks_secret "$rest"; then
        WITHHELD="refused as a secret"
        not_saved 5 "" "secret refused: --$field looks like a credential; nothing written (name the variable or account, never its value)"
        return $?
      fi
    done
    SHOW_TEXT=1
  fi
  rest=""
  if [ -n "$action" ]; then
    action="$(printf '%s' "$action" | sed -E 's/^[[:space:]]*OWNER_ACTION[:=][[:space:]]*//')"
    reason="$(printf '%s' "$action" | sed -nE 's/^([a-z-]+):[[:space:]]*.*$/\1/p')"
    if [ -z "$reason" ]; then
      # No reason to save it under: report it unsaved, never guess one.
      what="$(one_line "$action")"
      not_saved 2 "${what:-(empty OWNER_ACTION line)}" "the OWNER_ACTION line names no why-human reason ('<reason>: <what> — <free text>'); nothing written"
      return $?
    fi
    rest="$(printf '%s' "$action" | sed -E 's/^[a-z-]+:[[:space:]]*//')"
    case "$rest" in
      *' — '*) what="${rest%% — *}"; why="$reason: ${rest#* — }" ;;
      *) what="$rest"; why="$reason: reported by a sub-agent without detail" ;;
    esac
  fi
  [ -n "$(one_line "$what" | tr -d ' ')" ] || die_usage "save: --what (or --owner-action) is required"
  [ -n "$source" ] || die_usage "save: --source is required (the PR or issue that raised it)"

  if ! ot="$(resolve_owner_task)"; then
    not_saved 7 "$what" "owner-task.sh not found"; return $?
  fi
  if ! list="$(list_all "$ot" ${repo:+--repo "$repo"})"; then
    not_saved 4 "$what" "the list could not be read to check for a duplicate (owner-task.sh list exit non-zero)"; return $?
  fi
  id="$(find_same "$list" "$what" "$source")"
  if [ -n "$id" ]; then
    printf 'RESULT=skipped ID=%s\n' "$id"
    printf 'LINE=human task %s already on the list: %s\n' "$id" "$(one_line "$what")"
    return 0
  fi

  rc=0
  errf="$(mktemp "${TMPDIR:-/tmp}/pm-human-tasks.XXXXXX")" || { not_saved 1 "$what" "no temporary file for owner-task.sh's error"; return $?; }
  id="$("$ot" add --what "$what" --why "$why" --source "$source" ${repo:+--repo "$repo"} 2>"$errf")" || rc=$?
  err="$(head -c 600 "$errf" 2>/dev/null || true)"
  rm -f "$errf"
  if [ "$rc" -eq 0 ] && [ -n "$id" ]; then
    printf 'RESULT=saved ID=%s\n' "$id"
    printf 'LINE=human task %s saved: %s (%s)\n' "$id" "$(one_line "$what")" "${why%%:*}"
    return 0
  fi
  [ "$rc" -ne 0 ] || rc=1
  if [ "$rc" -eq 1 ]; then
    if ! list="$(list_all "$ot" ${repo:+--repo "$repo"})"; then
      printf 'RESULT=unconfirmed EXIT=1\n'
      printf 'LINE=human task may have been saved, not confirmed: %s — owner-task.sh add exit 1 and the list could not be re-read; check owner-task.sh list before saving it again\n' "$(one_line "$what")"
      return 1
    fi
    id="$(find_same "$list" "$what" "$source")"
    if [ -n "$id" ]; then
      printf 'RESULT=saved ID=%s\n' "$id"
      printf 'LINE=human task %s saved: %s (%s)\n' "$id" "$(one_line "$what")" "${why%%:*}"
      return 0
    fi
  fi
  if [ "$rc" -eq 5 ]; then
    # owner-task.sh's own checker refused it: never echo the text or its error.
    SHOW_TEXT=0; WITHHELD="refused as a secret"
    not_saved 5 "" "secret refused by owner-task.sh; nothing written (name the variable or account, never its value)"
    return $?
  fi
  err="$(one_line "${err#owner-task: }")"
  not_saved "$rc" "$what" "${err:-owner-task.sh add failed} (owner-task.sh exit $rc)"
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
  count) shift; cmd_count "$@" ;;
  save) shift; cmd_save "$@" ;;
  '') usage >&2; exit 2 ;;
  *) die_usage "unknown verb '$1' (count | save)" ;;
esac
