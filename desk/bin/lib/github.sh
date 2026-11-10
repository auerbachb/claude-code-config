# shellcheck shell=bash
# desk/bin/lib/github.sh — GitHub access for the Reviews tools: `sync-reviews`
# and pr-summary-material.sh (issue #1756). Sourced after lib/common.sh; never
# executed. Bash 3.2 compatible.
#
# Every GitHub read goes through the `gh` CLI, found here, so tests can point
# HUMAN_QUEUE_GH at a stub that serves fixtures and the suites run offline.
#
# PUBLIC FUNCTIONS
#   hq_gh_find            sets HQ_GH: HUMAN_QUEUE_GH when set (it must be an
#                         executable file), else /opt/homebrew/bin/gh, else gh
#                         on PATH; returns 1 when there is none
#   hq_jq_find            sets HQ_JQ: jq on PATH, else /opt/homebrew/bin/jq,
#                         else /usr/bin/jq; returns 1 when there is none
#   hq_jq ARGS...         runs that jq (needs hq_jq_find)
#   hq_gh OUT ERR ARGS... runs `gh ARGS` with stdout in the file OUT and stderr
#                         in the file ERR, under a deadline of
#                         HUMAN_QUEUE_GH_TIMEOUT seconds (default 60). Returns
#                         gh's status, or 124 when the deadline killed it
#   hq_gh_first_error ERR prints the first non-blank line of the file ERR (one
#                         line, for a one-line diagnostic)
#
# The gh child never inherits HUMAN_QUEUE_DATABASE_URL, never prompts, and
# never colors its output. stdin is /dev/null, so nothing can wait on input.

HQ_GH=""
HQ_JQ=""
HQ_GH_TIMEOUT_DEFAULT=60

hq_gh_find() {
  local p
  if [ -n "${HUMAN_QUEUE_GH:-}" ]; then
    if [ -x "$HUMAN_QUEUE_GH" ] && [ ! -d "$HUMAN_QUEUE_GH" ]; then
      HQ_GH="$HUMAN_QUEUE_GH"
      return 0
    fi
    return 1
  fi
  if [ -x /opt/homebrew/bin/gh ]; then
    HQ_GH=/opt/homebrew/bin/gh
    return 0
  fi
  if p=$(command -v gh 2>/dev/null) && [ -n "$p" ]; then
    HQ_GH="$p"
    return 0
  fi
  return 1
}

hq_jq_find() {
  local p
  if p=$(command -v jq 2>/dev/null) && [ -n "$p" ]; then
    HQ_JQ="$p"
    return 0
  fi
  for p in /opt/homebrew/bin/jq /usr/bin/jq; do
    if [ -x "$p" ]; then
      HQ_JQ="$p"
      return 0
    fi
  done
  return 1
}

hq_jq() {
  if [ -z "$HQ_JQ" ]; then
    hq_die_error "hq_jq: no jq (call hq_jq_find first)"
  fi
  "$HQ_JQ" "$@"
}

# hq__gh_timeout — the deadline in whole seconds; a value that is not a
# positive integer falls back to the default rather than disabling it.
hq__gh_timeout() {
  local t="${HUMAN_QUEUE_GH_TIMEOUT:-$HQ_GH_TIMEOUT_DEFAULT}"
  case "$t" in
    ''|*[!0-9]*|0) t="$HQ_GH_TIMEOUT_DEFAULT" ;;
  esac
  printf '%s\n' "$t"
}

# The watchdog polls once a second rather than sleeping the whole deadline, so
# killing it when gh finishes leaves at most a one-second `sleep` behind. It
# writes the timeout marker before the kill, which is how a deadline kill is
# told apart from gh exiting 143 on its own.
hq_gh() {
  local hq__out="$1" hq__err="$2" hq__pid hq__wd hq__rc=0 hq__limit hq__mark
  shift 2
  if [ -z "$HQ_GH" ]; then
    hq_die_error "hq_gh: no gh (call hq_gh_find first)"
  fi
  hq__limit=$(hq__gh_timeout)
  hq_mktemp hq__mark
  (
    unset HUMAN_QUEUE_DATABASE_URL
    export GH_PROMPT_DISABLED=1 GH_NO_UPDATE_NOTIFIER=1 NO_COLOR=1 GH_PAGER=cat
    exec "$HQ_GH" "$@"
  ) </dev/null >"$hq__out" 2>"$hq__err" &
  hq__pid=$!
  (
    unset HUMAN_QUEUE_DATABASE_URL
    i=0
    while [ "$i" -lt "$hq__limit" ]; do
      sleep 1
      kill -0 "$hq__pid" 2>/dev/null || exit 0
      i=$((i + 1))
    done
    printf 'timeout\n' >"$hq__mark"
    kill -TERM "$hq__pid" 2>/dev/null
  ) </dev/null >/dev/null 2>&1 &
  hq__wd=$!
  # 2>/dev/null: a job the deadline killed would otherwise make bash print a
  # "Terminated" notice, breaking the one-line stderr contract.
  wait "$hq__pid" 2>/dev/null || hq__rc=$?
  kill -TERM "$hq__wd" 2>/dev/null || true
  wait "$hq__wd" 2>/dev/null || true
  if [ -s "$hq__mark" ]; then
    return 124
  fi
  return "$hq__rc"
}

hq_gh_first_error() {
  local line
  line=$(grep -m1 -v '^[[:space:]]*$' "$1" 2>/dev/null || true)
  printf '%s\n' "${line:-no error output}"
}
