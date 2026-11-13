#!/usr/bin/env bash
# phone-push-wait.sh — one phone push when a parked step waits on the operator too long.
# catalog: scheduling-monitoring — Phone push for a parked step: arm a delay, push once if still unanswered, record a miss
#
# PURPOSE (issue #2291)
#   A thread that parks a step on the operator's answer (a Decision captured by
#   the human queue, or any step waiting on him) can sit blocked for hours while
#   his phone stays quiet. This script keeps the record and the timer; the
#   *push itself* is the PushNotification model tool, which a shell cannot call.
#   So the parked thread arms a persistent Monitor on `watch`; after the delay,
#   if the question is still unanswered, `watch` prints ONE line that wakes the
#   thread, and the thread calls PushNotification with that text, then records
#   `sent` (or `missed` when the push could not be delivered).
#   An open AskUserQuestion menu is NOT covered here: the stopped turn cannot
#   act, and the Claude app's own "Push when actions required" setting covers
#   it (`doctor` checks the toggles). Contract and what was ruled out:
#   .claude/reference/phone-push-wait.md.
#
# USAGE
#   phone-push-wait.sh arm KEY --thread NAME --question TEXT [--delay SECONDS]
#       Record the wait. KEY is the question's id (D-43). Prints the Monitor
#       command to start and the two follow-up steps. A key can be armed once:
#       one push per question. Delay: --delay, else PHONE_PUSH_DELAY_SEC, else 300; at most 1500
#       (the Monitor that watches it expires after about 30 minutes).
#   phone-push-wait.sh watch KEY
#       The Monitor command. Sleeps until the delay passes. Prints nothing when
#       the question was answered first; otherwise prints one `phone-push KEY due`
#       line (with the push text) exactly once, then exits.
#   phone-push-wait.sh answer KEY      the operator answered: cancel the push
#   phone-push-wait.sh sent KEY        PushNotification delivered
#   phone-push-wait.sh missed KEY --reason TEXT
#                                      the push could not be delivered (for example
#                                      Remote Control not connected): record the miss
#   phone-push-wait.sh text KEY        print the push text
#   phone-push-wait.sh status [KEY]    one line per record (all records with no KEY)
#   phone-push-wait.sh doctor          check the Claude app's phone-push settings
#   phone-push-wait.sh --help
#
# PUSH TEXT
#   One line, at most 190 characters: `[<thread>] waiting on you: <question>`.
#   Links, email addresses, absolute paths and long token-like strings are
#   replaced, and non-ASCII is dropped. Pass a one-line summary as --question,
#   never transcript text or secrets.
#
# STATE
#   ${PHONE_PUSH_DIR:-~/.claude/phone-push}/<KEY>.json: {key, thread, text, status,
#   armed_epoch, delay_sec, due_epoch, updated_epoch, reason}. status: waiting |
#   answered | due | sent | missed. Never inside a worktree.
#
# EXIT CODES
#   0 ok; 1 a state read/write failed (nothing is claimed as armed or sent);
#   2 usage error; 3 conflict (key already armed, or unknown key).
#
# Bash 3.2 compatible (macOS /bin/bash).
set -uo pipefail

DIR="${PHONE_PUSH_DIR:-${HOME:-}/.claude/phone-push}"
DEFAULT_DELAY=300
MAX_DELAY=1500
MAX_TEXT=190
SELF_DIR=$(cd -P "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd) || SELF_DIR=""
SELF="${SELF_DIR}/$(basename "${BASH_SOURCE[0]}")"
SELF_Q=$(printf '%q' "$SELF")   # shell-safe form for every command we print

usage() { sed -n '2,/^# Bash 3.2/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }
die() { printf 'phone-push-wait: %s\n' "$2" >&2; exit "$1"; }

command -v jq >/dev/null 2>&1 || die 1 "jq is required"
[ -n "${HOME:-}" ] || [ -n "${PHONE_PUSH_DIR:-}" ] || die 1 "HOME is unset"

valid_key() { case "$1" in ''|*[!A-Za-z0-9._-]*) return 1 ;; esac; [ "${#1}" -le 64 ]; }
valid_int() { case "$1" in ''|*[!0-9]*) return 1 ;; esac; [ "${#1}" -le 12 ]; }
now() { date +%s; }

ensure_dir() { mkdir -p "$DIR" 2>/dev/null && chmod 700 "$DIR" 2>/dev/null && [ -w "$DIR" ]; }
rec() { printf '%s/%s.json' "$DIR" "$1"; }

# Serialize read-modify-write per state dir (mkdir is atomic). The lock records
# its owner's pid; a lock whose owner is gone (killed mid-update) is reclaimed
# so a crash cannot wedge every later update.
LOCK_HELD=0
lock() {
  local i=0 owner current
  while ! mkdir "$DIR/.lock" 2>/dev/null; do
    i=$((i + 1))
    owner=$(cat "$DIR/.lock/pid" 2>/dev/null || true)
    # A lock with no pid yet may be a new owner between mkdir and its pid write,
    # so it is only treated as stale after a longer wait (5 s).
    if { [ -n "$owner" ] && [ "$i" -gt 20 ] && ! kill -0 "$owner" 2>/dev/null; } \
       || { [ -z "$owner" ] && [ "$i" -gt 50 ]; }; then
      # Owner gone (or never recorded one). Reclaimers serialize on a short-lived
      # guard, re-read the pid under it, and remove the lock only if it is still
      # the one judged stale. A possibly-live lock is never moved, so there is
      # nothing to restore and no way to nest one lock inside another.
      if mkdir "$DIR/.lock.reclaim" 2>/dev/null; then
        current=$(cat "$DIR/.lock/pid" 2>/dev/null || true)
        if [ "$current" = "$owner" ]; then
          if [ -n "$owner" ]; then
            kill -0 "$owner" 2>/dev/null || { rm -f "$DIR/.lock/pid"; rmdir "$DIR/.lock" 2>/dev/null || true; }
          else
            rmdir "$DIR/.lock" 2>/dev/null || true
          fi
        fi
        rmdir "$DIR/.lock.reclaim" 2>/dev/null || true
      else
        sleep 0.1
      fi
      continue
    fi
    [ "$i" -gt 100 ] && return 1
    sleep 0.1
  done
  printf '%s' "$$" >"$DIR/.lock/pid" 2>/dev/null || { rmdir "$DIR/.lock" 2>/dev/null; return 1; }
  LOCK_HELD=1
  trap 'unlock; exit 1' INT TERM HUP
}
unlock() {
  [ "$LOCK_HELD" = 1 ] || return 0
  rm -f "$DIR/.lock/pid" 2>/dev/null
  rmdir "$DIR/.lock" 2>/dev/null || true
  LOCK_HELD=0
  trap - INT TERM HUP
}

# sanitize TEXT -> one printable-ASCII line with links, emails, paths and
# token-like strings replaced.
sanitize() {
  printf '%s' "$1" | LC_ALL=C tr -c '[:print:]' ' ' | LC_ALL=C tr -cd '[:print:]' |
    LC_ALL=C tr '(`"\047[<{' '      ' |
    sed -E \
      -e 's#[A-Za-z][A-Za-z0-9+.-]*://[^ ]*#[link]#g' \
      -e 's#[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+#[email]#g' \
      -e 's#(^| )(~|\.{1,2})?/[^ ]*#\1[path]#g' \
      -e 's#[A-Za-z0-9_+=-]{32,}#[redacted]#g' \
      -e 's#(sk|ghp|gho|ghu|ghs|ghr|xox[a-z])[-_][A-Za-z0-9_-]{8,}#[redacted]#g' \
      -e 's# +# #g' -e 's#^ ##' -e 's# $##'
}

build_text() { # THREAD QUESTION
  local t q line
  t=$(sanitize "$1"); t=$(printf '%s' "$t" | cut -c1-40)
  q=$(sanitize "$2")
  [ -n "$t" ] || t="thread"
  if [ -n "$q" ]; then line="[$t] waiting on you: $q"; else line="[$t] waiting on you for a decision"; fi
  printf '%s' "$line" | cut -c1-"$MAX_TEXT"
}

field() { jq -r --arg f "$2" '.[$f] // "" | tostring' "$(rec "$1")" 2>/dev/null; }

# set_status KEY FROM TO [REASON]: move FROM -> TO under the lock. Exit 0 moved,
# 3 not in FROM (prints the current status), 1 failed.
set_status() {
  local key=$1 from=$2 to=$3 reason=${4:-} f cur tmp
  f=$(rec "$key")
  [ -f "$f" ] || return 3
  lock || return 1
  cur=$(field "$key" status)
  if [ "$cur" != "$from" ]; then unlock; printf '%s\n' "$cur"; return 3; fi
  tmp=$(mktemp "$DIR/.tmp.XXXXXX") || { unlock; return 1; }
  if jq --arg s "$to" --arg r "$reason" --argjson n "$(now)" \
       '.status=$s | .updated_epoch=$n | (if $r != "" then .reason=$r else . end)' "$f" >"$tmp" 2>/dev/null \
     && mv "$tmp" "$f"; then unlock; return 0; fi
  rm -f "$tmp"; unlock; return 1
}

cmd_arm() {
  local key=${1:-} thread="" question="" delay=${PHONE_PUSH_DELAY_SEC:-$DEFAULT_DELAY} text tmp f
  shift || true
  valid_key "$key" || die 2 "arm needs a KEY of letters, digits . _ - (up to 64)"
  while [ $# -gt 0 ]; do
    case "$1" in
      --thread|--question|--delay)
        [ $# -ge 2 ] || die 2 "$1 needs a value"
        case "$1" in --thread) thread=$2 ;; --question) question=$2 ;; *) delay=$2 ;; esac
        shift 2 ;;
      *) die 2 "unknown argument: $1" ;;
    esac
  done
  valid_int "$delay" && [ "$delay" -ge 1 ] && [ "$delay" -le "$MAX_DELAY" ] || die 2 "delay must be 1 to $MAX_DELAY seconds (the Monitor that watches it expires after about 30 minutes)"
  ensure_dir || die 1 "cannot create $DIR; nothing armed"
  text=$(build_text "$thread" "$question")
  f=$(rec "$key")
  tmp=$(mktemp "$DIR/.tmp.XXXXXX") || die 1 "cannot write state; nothing armed"
  if ! jq -n --arg k "$key" --arg th "$(sanitize "$thread")" --arg tx "$text" \
       --argjson d "$delay" --argjson n "$(now)" \
       '{key:$k, thread:$th, text:$tx, status:"waiting", armed_epoch:$n, delay_sec:$d,
         due_epoch:($n+$d), updated_epoch:$n, reason:""}' >"$tmp" 2>/dev/null; then
    rm -f "$tmp"; die 1 "cannot write state; nothing armed"
  fi
  # ln fails when the record exists: one push per question, atomically.
  if ! ln "$tmp" "$f" 2>/dev/null; then
    rm -f "$tmp"
    die 3 "$key is already armed (status $(field "$key" status)); one push per question, nothing re-armed"
  fi
  rm -f "$tmp"
  printf 'phone push armed for %s: one push if it is still unanswered after %ss.\n' "$key" "$delay"
  printf '1. Start a persistent Monitor with this command: %s watch %s\n' "$SELF_Q" "$key"
  printf '2. When the answer arrives, run: %s answer %s\n' "$SELF_Q" "$key"
  printf '3. When the Monitor prints "phone-push %s due", call PushNotification with the text it gives, then run: %s sent %s  (or: %s missed %s --reason "<why>")\n' "$key" "$SELF_Q" "$key" "$SELF_Q" "$key"
}

cmd_watch() {
  local key=${1:-} f due st rc
  valid_key "$key" || die 2 "watch needs a KEY"
  f=$(rec "$key")
  [ -f "$f" ] || die 3 "unknown key $key"
  due=$(field "$key" due_epoch)
  valid_int "$due" || die 1 "state for $key is unreadable"
  while :; do
    st=$(field "$key" status)
    [ "$st" = "waiting" ] || exit 0
    if [ "$(now)" -ge "$due" ]; then
      set_status "$key" waiting due >/dev/null; rc=$?
      if [ "$rc" -eq 0 ]; then
        printf 'phone-push %s due: call PushNotification with exactly this text, then record it with %s sent %s (or missed %s --reason "<why>"): %s\n' \
          "$key" "$SELF_Q" "$key" "$key" "$(field "$key" text)"
        exit 0
      fi
      [ "$rc" -eq 3 ] && exit 0
      die 1 "could not claim the push for $key; sending nothing"
    fi
    sleep 5
  done
}

cmd_answer() {
  local key=${1:-} st rc
  valid_key "$key" || die 2 "answer needs a KEY"
  [ -f "$(rec "$key")" ] || die 3 "unknown key $key"
  st=$(set_status "$key" waiting answered); rc=$?
  case "$rc" in
    0) printf 'phone push for %s cancelled: answered.\n' "$key" ;;
    3) printf 'phone push for %s: already %s.\n' "$key" "$st" ;;
    *) die 1 "could not record the answer for $key" ;;
  esac
}

cmd_outcome() { # sent|missed KEY [--reason TEXT]
  local to=$1 key=${2:-} reason="" st rc
  valid_key "$key" || die 2 "$to needs a KEY"
  shift 2 || true
  while [ $# -gt 0 ]; do
    case "$1" in
      --reason) [ $# -ge 2 ] || die 2 "--reason needs a value"; reason=$2; shift 2 ;;
      *) die 2 "unknown argument: $1" ;;
    esac
  done
  [ "$to" = "missed" ] && [ -z "$reason" ] && die 2 "missed needs --reason"
  [ -f "$(rec "$key")" ] || die 3 "unknown key $key"
  reason=$(sanitize "$reason")
  st=$(set_status "$key" due "$to" "$reason"); rc=$?
  case "$rc" in
    0) printf 'phone push for %s recorded: %s.\n' "$key" "$to" ;;
    3) die 3 "$key is $st, not due; nothing recorded" ;;
    *) die 1 "could not record $to for $key" ;;
  esac
}

cmd_text() {
  valid_key "${1:-}" || die 2 "text needs a KEY"
  [ -f "$(rec "$1")" ] || die 3 "unknown key $1"
  field "$1" text
}

cmd_status() {
  local f
  if [ -n "${1:-}" ]; then
    valid_key "$1" || die 2 "bad KEY"
    [ -f "$(rec "$1")" ] || die 3 "unknown key $1"
    f=$(rec "$1")
    jq -r '"\(.key) \(.status) delay=\(.delay_sec)s \(.reason)"' "$f"
    return 0
  fi
  [ -d "$DIR" ] || return 0
  for f in "$DIR"/*.json; do
    [ -f "$f" ] || continue
    jq -r '"\(.key) \(.status) delay=\(.delay_sec)s \(.reason)"' "$f" 2>/dev/null || printf '%s unreadable\n' "$f"
  done
}

cmd_doctor() {
  local s="${PHONE_PUSH_SETTINGS:-${HOME:-}/.claude/settings.json}" k v rc=0
  [ -f "$s" ] || { echo "doctor: $s not found; cannot check the phone-push settings"; return 1; }
  for k in inputNeededNotifEnabled agentPushNotifEnabled; do
    v=$(jq -r --arg k "$k" '.[$k] | if . == null then "unset" else tostring end' "$s" 2>/dev/null) || v="unreadable"
    printf '%s: %s\n' "$k" "$v"
    [ "$v" = "true" ] || rc=1
  done
  [ "$rc" -eq 0 ] && echo "doctor: both toggles on (open menus push natively; Remote Control must also be connected)" \
    || echo "doctor: turn the unset or false toggle on in /config (\"Push when actions required\" covers an open menu)"
  return "$rc"
}

sub=${1:-}
[ $# -gt 0 ] && shift
case "$sub" in
  arm) cmd_arm "$@" ;;
  watch) cmd_watch "$@" ;;
  answer) cmd_answer "$@" ;;
  sent) cmd_outcome sent "$@" ;;
  missed) cmd_outcome missed "$@" ;;
  text) cmd_text "$@" ;;
  status) cmd_status "$@" ;;
  doctor) cmd_doctor ;;
  -h|--help|help) usage ;;
  *) usage >&2; exit 2 ;;
esac
