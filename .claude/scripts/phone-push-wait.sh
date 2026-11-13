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
#   ${PHONE_PUSH_DIR:-~/.claude/phone-push}/<KEY>.json is the immutable record
#   {key, thread, text, armed_epoch, delay_sec, due_epoch}. The status is derived
#   from two marker files, each created atomically once (no lock, no pid file):
#   <KEY>.claim (answered | due) and <KEY>.outcome (sent | missed). status:
#   waiting | answered | due | sent | missed. Never inside a worktree.
#   A push that stays `due` for PHONE_PUSH_GRACE_SEC (default 180) with no `sent`
#   or `missed` lost its wake: the next watch/status/doctor/arm records it as
#   `missed` (reason "wake lost"), once. Nothing is ever re-pushed.
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

# State is never rewritten and no lock exists. The record <KEY>.json is immutable.
# Each transition is one atomic create of a complete marker file (ln fails when it
# exists), so exactly one process wins and a loser just reports the current state:
#   <KEY>.claim    first line `answered` or `due`  (waiting -> answered | due)
#   <KEY>.outcome  first line `sent` or `missed`   (due -> sent | missed)
# A process killed at any point leaves either nothing or a complete marker, never
# a half state, so no later command can wedge. Line 2 is the epoch, line 3 the reason.
GRACE=${PHONE_PUSH_GRACE_SEC:-180}
valid_int "$GRACE" || GRACE=180
claim_f() { printf '%s/%s.claim' "$DIR" "$1"; }
outcome_f() { printf '%s/%s.outcome' "$DIR" "$1"; }
line() { sed -n "${1}p" "$2" 2>/dev/null; } # line N FILE

# put_once FILE STATUS [REASON]: exit 0 won, 3 lost (FILE exists), 1 failed.
put_once() {
  local dest=$1 st=$2 r=${3:-} tmp
  tmp=$(mktemp "$DIR/.tmp.XXXXXX") || return 1
  if ! printf '%s\n%s\n%s\n' "$st" "$(now)" "$r" >"$tmp" 2>/dev/null; then rm -f "$tmp"; return 1; fi
  if ln "$tmp" "$dest" 2>/dev/null; then rm -f "$tmp"; return 0; fi
  rm -f "$tmp"
  [ -f "$dest" ] && return 3
  return 1
}

# status_of KEY: waiting | answered | due | sent | missed
status_of() {
  local c o
  c=$(line 1 "$(claim_f "$1")")
  case "$c" in
    answered) echo answered ;;
    due) o=$(line 1 "$(outcome_f "$1")"); echo "${o:-due}" ;;
    *) echo waiting ;;
  esac
}

# settle KEY: a push that has sat `due` past the grace period with neither `sent`
# nor `missed` lost its wake. Record it as missed, once (no push is retried).
settle() {
  local key=$1 ce rc
  [ "$(status_of "$key")" = "due" ] || return 0
  ce=$(line 2 "$(claim_f "$key")")
  valid_int "$ce" || return 0
  [ "$(now)" -ge $((ce + GRACE)) ] || return 0
  put_once "$(outcome_f "$key")" missed "wake lost: no sent or missed recorded within ${GRACE}s of the push becoming due"; rc=$?
  [ "$rc" -eq 0 ] && printf 'phone-push %s missed: wake lost (no push was recorded within %ss of becoming due)\n' "$key" "$GRACE" >&2
  return 0
}
settle_all() {
  local f k
  [ -d "$DIR" ] || return 0
  for f in "$DIR"/*.claim; do
    [ -f "$f" ] || continue
    k=$(basename "$f" .claim); valid_key "$k" && settle "$k"
  done
  return 0
}

# sanitize TEXT -> one printable-ASCII line with links, emails, paths and
# token-like strings replaced.
sanitize() {
  printf '%s' "$1" | LC_ALL=C tr -c '[:print:]' ' ' | LC_ALL=C tr -cd '[:print:]' |
    LC_ALL=C tr '(`"\047[<{' '      ' |
    sed -E \
      -e 's#[A-Za-z][A-Za-z0-9+.-]*://[^ ]*#[link]#g' \
      -e 's#[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+#[email]#g' \
      -e 's#(^|[^A-Za-z0-9_])(~|\.{1,2})?/[^ ]*#\1[path]#g' \
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

# set_status KEY FROM TO [REASON]: one atomic marker create. Exit 0 moved, 3 lost
# or not in FROM (prints the current status), 1 failed.
set_status() {
  local key=$1 to=$3 reason=${4:-} rc
  [ -f "$(rec "$key")" ] || return 3
  case "$to" in
    answered|due) put_once "$(claim_f "$key")" "$to" "$reason"; rc=$? ;;
    *) if [ "$(line 1 "$(claim_f "$key")")" = "due" ]; then
         put_once "$(outcome_f "$key")" "$to" "$reason"; rc=$?
       else rc=3; fi ;;
  esac
  [ "$rc" -eq 3 ] && { status_of "$key"; return 3; }
  return "$rc"
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
  settle_all
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
    settle "$key"
    st=$(status_of "$key")
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

status_line() { # FILE
  local f=$1 k st r
  k=$(jq -r '.key // empty' "$f" 2>/dev/null) && valid_key "$k" || { printf '%s unreadable\n' "$f"; return; }
  st=$(status_of "$k")
  r=$(line 3 "$(outcome_f "$k")"); [ -n "$r" ] || r=$(line 3 "$(claim_f "$k")")
  printf '%s %s delay=%ss %s\n' "$k" "$st" "$(field "$k" delay_sec)" "$r"
}

cmd_status() {
  local f
  settle_all
  if [ -n "${1:-}" ]; then
    valid_key "$1" || die 2 "bad KEY"
    [ -f "$(rec "$1")" ] || die 3 "unknown key $1"
    status_line "$(rec "$1")"
    return 0
  fi
  [ -d "$DIR" ] || return 0
  for f in "$DIR"/*.json; do
    [ -f "$f" ] || continue
    status_line "$f"
  done
}

cmd_doctor() {
  local s="${PHONE_PUSH_SETTINGS:-${CLAUDE_CONFIG_DIR:-${HOME:-}/.claude}/settings.json}" k v rc=0 f lost
  settle_all
  for f in "$DIR"/*.outcome; do
    [ -f "$f" ] || continue
    case "$(line 3 "$f")" in "wake lost"*) lost=$(basename "$f" .outcome)
      printf 'doctor: %s was recorded missed: wake lost (the push never reached the phone)\n' "$lost"; rc=1 ;; esac
  done
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
