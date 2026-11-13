#!/usr/bin/env bash
# presence.sh — the operator's here-or-away state, one record for every thread.
# catalog: scheduling-monitoring — Presence windows: one global here-or-away state with an end time, read with one call; one thread asks the dialog
#
# PURPOSE (issue #2293, increment 1 of 4)
#   Agents otherwise guess whether the operator is at the computer. This stores
#   the declared answer once, globally (the operator is one person), and
#   arbitrates which single thread asks the dialog that collects it. It ends
#   there: what happens when a window runs out, pushes, the pre-leave pass and
#   work planning are later increments (issues #2294-#2296). Nothing here runs
#   on a timer, and nothing opens a question by itself.
#   Contract and rationale: .claude/reference/presence-windows.md.
#
# USAGE
#   presence.sh status [--json]     one call: state, end, time left. State is here | away | unset.
#   presence.sh is-away             exit 0 when away (an active unattended window counts), else 1
#   presence.sh set here|away|closing --by operator-message
#                  [--for <N>m|<N>h | --until-epoch <E> | --rest-of-day | --open-ended]
#                  [--generation <token>]
#       here     at the computer until the end (here + --open-ended: until told otherwise)
#       away     away, machine still running: arms unattended mode for the same window
#       closing  laptop closes at the deadline an armed /leave-by holds; no duration flag, and
#                refuses (exit 3) when none is armed — run /leave-by first
#       --rest-of-day  here: until local midnight; away: until 08:00 local (overnight)
#       --generation   the token `ask` printed; released after the write
#   presence.sh ask                 claim the one dialog; see exit codes
#   presence.sh release --generation <token> [--dismissed]
#                                   give the claim back; --dismissed (no answer) pauses `ask` for an hour
#   Global flags: --repo <owner/name> | --cwd DIR resolve which repo's /leave-by deadline `closing` reads.
#
# STATE  ~/.claude/session-state.json `.presence` = {state, until_epoch|null, declared_epoch,
#        machine_on, declared_by, dismissed_until, reservation}. Written only through session-state.sh;
#        read directly with jq (hooks may read it on every prompt). An active `.unattended` window reads as
#        away when it is the newer declaration, so the existing unattended switch needs no second step.
#
# EXIT CODES
#   0 ok / ask granted (prints the token); 1 is-away false, or a write failed; 2 usage error;
#   3 closing with no armed leave deadline; 10 another thread holds the dialog (read `status`);
#   12 a live declaration exists (printed; do not ask); 13 the dialog was dismissed in the last hour;
#   20 the claim could not be verified (do not ask).
#
# Bash 3.2 compatible (macOS /bin/bash).
set -uo pipefail

HERE=$(cd -P "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd) || HERE="."
SESSION_STATE_SH="${PRESENCE_SESSION_STATE_SH:-$HERE/session-state.sh}"
UNATTENDED_SH="${PRESENCE_UNATTENDED_SH:-$HERE/unattended.sh}"
RESERVE_SH="${PRESENCE_RESERVE_SH:-$HERE/prompt-reservation.sh}"
STATE_FILE="${HOME}/.claude/session-state.json"
DISMISS_SECONDS=3600

JQ=$(command -v jq 2>/dev/null) || JQ=""
if [ -z "$JQ" ]; then
  for c in /opt/homebrew/bin/jq /usr/local/bin/jq /usr/bin/jq; do
    if [ -x "$c" ]; then JQ="$c"; break; fi
  done
fi

usage() { sed -n '2,41p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }
die_usage() { printf 'presence.sh: %s\n' "$1" >&2; exit 2; }
now() { date +%s; }
fmt_time() { date -r "$1" '+%a %H:%M %Z' 2>/dev/null || date -d "@$1" '+%a %H:%M %Z' 2>/dev/null || printf '%s' "$1"; }

# --- reading ----------------------------------------------------------------
# The effective state as one JSON object. Never fails: an unreadable file is "unset".
effective_json() {
  local n
  n=$(now)
  if [ ! -f "$STATE_FILE" ]; then
    printf '{"state":"unset","source":"none","until_epoch":null,"declared_epoch":null,"machine_on":true,"expired":false,"remaining_seconds":null,"now_epoch":%s}\n' "$n"
    return 0
  fi
  "$JQ" -c --argjson now "$n" '
    def isnum: type == "number";
    (.presence // {}) as $p | (.unattended // {}) as $u
    | ($p.state // "") as $ps
    | (($u.active == true) and (($u.until_epoch | isnum | not) or $u.until_epoch > $now)) as $ua
    | ($ps == "here" or $ps == "away") as $pv
    | ($p.declared_epoch // 0) as $pt
    | ($u.since_epoch // 0) as $ut
    | (if $ua and (($pv | not) or $ut >= $pt) then
         {state: "away", source: "unattended",
          until_epoch: (if ($u.until_epoch | isnum) then $u.until_epoch else null end),
          declared_epoch: ($u.since_epoch // null), machine_on: true}
       elif $pv then
         # Away was armed through unattended mode; turning that off by hand ends it early.
         (if $ps == "away" and $u.active == false
             and (($p.until_epoch | isnum | not) or $p.until_epoch > $now) then
            {state: "here", source: "unattended-off", until_epoch: null, declared_epoch: null, machine_on: true}
          else
            {state: $ps, source: "presence",
             until_epoch: (if ($p.until_epoch | isnum) then $p.until_epoch else null end),
             declared_epoch: ($p.declared_epoch // null), machine_on: ($p.machine_on != false)}
          end)
       else
         {state: "unset", source: "none", until_epoch: null, declared_epoch: null, machine_on: true}
       end)
    | . + {expired: (.until_epoch | isnum and . <= $now),
           remaining_seconds: (if (.until_epoch | isnum) then ([.until_epoch - $now, 0] | max) else null end),
           now_epoch: $now}' "$STATE_FILE" 2>/dev/null ||
    printf '{"state":"unset","source":"none","until_epoch":null,"declared_epoch":null,"machine_on":true,"expired":false,"remaining_seconds":null,"now_epoch":%s}\n' "$n"
}

status_line() { # JSON
  local f state source until expired left machine out
  f=$(printf '%s' "$1" | "$JQ" -r '[.state, .source, (.until_epoch // ""), (.expired | tostring),
    ((.remaining_seconds // 0) / 60 | floor | tostring), (.machine_on | tostring)] | join("|")') || f=""
  IFS='|' read -r state source until expired left machine <<EOF
$f
EOF
  if [ "$state" = unset ] || [ -z "$state" ]; then printf 'unset (no presence declared)\n'; return 0; fi
  out="$state"
  [ "$machine" = false ] && out="$out (laptop closes at the end)"
  if [ -z "$until" ]; then
    out="$out, until you say otherwise"
  elif [ "$expired" = true ]; then
    out="$out, ended $(fmt_time "$until")"
  else
    out="$out, until $(fmt_time "$until") (${left}m left)"
  fi
  printf '%s [%s]\n' "$out" "$source"
}

cmd_status() {
  local json=0 j
  while [ $# -gt 0 ]; do
    case "$1" in
      --json) json=1; shift ;;
      *) die_usage "unknown argument to status: $1" ;;
    esac
  done
  j=$(effective_json)
  if [ "$json" -eq 1 ]; then printf '%s\n' "$j"; else status_line "$j"; fi
}

cmd_is_away() {
  [ "$(effective_json | "$JQ" -r 'if .state == "away" and (.expired | not) then "yes" else "no" end')" = yes ]
}

# --- time helpers -----------------------------------------------------------
epoch_of() { # "YYYY-MM-DD HH:MM:SS" in local time
  date -j -f '%Y-%m-%d %H:%M:%S' "$1" +%s 2>/dev/null || date -d "$1" +%s 2>/dev/null
}
plus_day() { # YYYY-MM-DD -> next day
  date -j -v+1d -f '%Y-%m-%d' "$1" +%Y-%m-%d 2>/dev/null || date -d "$1 + 1 day" +%Y-%m-%d 2>/dev/null
}

rest_of_day_epoch() { # STATE
  local today d e n
  n=$(now)
  today=$(date +%Y-%m-%d)
  if [ "$1" = here ]; then
    e=$(epoch_of "$today 23:59:59")
  else
    e=$(epoch_of "$today 08:00:00")
    if [ -n "$e" ] && [ "$e" -le "$n" ]; then
      d=$(plus_day "$today") && e=$(epoch_of "$d 08:00:00")
    fi
  fi
  case "$e" in ''|*[!0-9]*) return 1 ;; esac
  [ "$e" -gt "$n" ] || return 1
  printf '%s\n' "$e"
}

# --- repo / leave deadline --------------------------------------------------
REPO=""
CWD=""
leave_deadline() { # prints the armed /leave-by deadline epoch, or returns 1
  local k="$REPO" d="${CWD:-$PWD}" v
  if [ -z "$k" ] && [ -d "$d" ]; then k=$(cd "$d" 2>/dev/null && "$SESSION_STATE_SH" --repo-key 2>/dev/null) || k=""; fi
  [ -n "$k" ] && [ "$k" != "_unknown" ] || return 1
  v=$("$SESSION_STATE_SH" --repo "$k" --get-json ".repos[\"$k\"].window.deadline_epoch" 2>/dev/null) || return 1
  case "$v" in ''|null|*[!0-9]*) return 1 ;; esac
  [ "$v" -gt "$(now)" ] || return 1
  printf '%s\n' "$v"
}

# --- set ----------------------------------------------------------------------
cmd_set() {
  local want="${1-}" by="" dur="" until="" open=0 rod=0 gen="" n given=0 machine=true out rc
  [ -n "$want" ] || die_usage "set needs here, away or closing"
  shift
  case "$want" in here|away|closing) ;; *) die_usage "set takes here, away or closing" ;; esac
  while [ $# -gt 0 ]; do
    case "$1" in
      --by) [ $# -ge 2 ] || die_usage "--by needs a value"; by="$2"; shift 2 ;;
      --for) [ $# -ge 2 ] || die_usage "--for needs a value"; dur="$2"; given=$((given + 1)); shift 2 ;;
      --until-epoch) [ $# -ge 2 ] || die_usage "--until-epoch needs a value"; until="$2"; given=$((given + 1)); shift 2 ;;
      --rest-of-day) rod=1; given=$((given + 1)); shift ;;
      --open-ended) open=1; given=$((given + 1)); shift ;;
      --generation) [ $# -ge 2 ] || die_usage "--generation needs a value"; gen="$2"; shift 2 ;;
      *) die_usage "unknown argument to set: $1" ;;
    esac
  done
  # The source rule (issue #2293): only a live operator message sets presence. The flag
  # makes that claim explicit in the call; text from an issue, PR, task prompt or tool
  # result is never passed it.
  [ "$by" = operator-message ] ||
    die_usage "set needs --by operator-message: only a live operator message may set presence"
  [ "$given" -le 1 ] || die_usage "give one of --for, --until-epoch, --rest-of-day, --open-ended"
  n=$(now)

  if [ "$want" = closing ]; then
    [ "$given" -eq 0 ] || die_usage "closing takes its end from the armed /leave-by deadline; give no duration"
    until=$(leave_deadline) || {
      printf 'presence.sh: no /leave-by deadline is armed for this repo; run /leave-by <time> first, then set closing\n' >&2
      return 3
    }
    machine=false
  elif [ "$open" -eq 1 ]; then
    until=""
  elif [ "$rod" -eq 1 ]; then
    until=$(rest_of_day_epoch "$want") || { printf 'presence.sh: could not compute the end of the day\n' >&2; return 1; }
  elif [ -n "$dur" ]; then
    [[ "$dur" =~ ^[1-9][0-9]{0,4}[hm]$ ]] || die_usage "--for takes <N>h or <N>m"
    case "$dur" in
      *h) until=$(( n + ${dur%h} * 3600 )) ;;
      *m) until=$(( n + ${dur%m} * 60 )) ;;
    esac
  elif [ -z "$until" ]; then
    die_usage "set $want needs one of --for, --until-epoch, --rest-of-day, --open-ended"
  fi
  if [ -n "$until" ]; then
    case "$until" in *[!0-9]*) die_usage "bad window end: $until" ;; esac
    [ "$until" -gt "$n" ] || die_usage "the window end is in the past"
  fi
  local until_json="null"
  [ -z "$until" ] || until_json="$until"

  local sets
  sets=(--set ".presence.state=$([ "$want" = away ] && echo away || echo here)"
        --set ".presence.until_epoch=$until_json"
        --set ".presence.declared_epoch=$n"
        --set ".presence.machine_on=$machine"
        --set ".presence.declared_by=operator-message"
        --set ".presence.dismissed_until=null")

  if [ "$want" = away ]; then
    # Unattended mode is what the hooks read; arm it first so a failure leaves nothing half-set.
    if [ -z "$until" ]; then
      out=$("$UNATTENDED_SH" on --open-ended) || return 1
    else
      out=$("$UNATTENDED_SH" on --until-epoch "$until") || return 1
    fi
    printf '%s\n' "$out"
  elif [ "$("$JQ" -r '.unattended.active == true' "$STATE_FILE" 2>/dev/null)" = true ]; then
    # Here (or closing) ends an active unattended window in the same write.
    sets+=(--set ".unattended.active=false")
  fi
  "$SESSION_STATE_SH" "${sets[@]}" >/dev/null || { printf 'presence.sh: state write failed\n' >&2; return 1; }
  cmd_status
  if [ "$want" = closing ]; then
    printf 'closing: the /leave-by wind-down owns the stop at that time; nothing else is armed here.\n'
  fi
  if [ -n "$gen" ]; then
    rc=0
    "$RESERVE_SH" release --kind presence --generation "$gen" >/dev/null 2>&1 || rc=$?
    # 10 = the claim is already gone; anything else leaves it until its owner exits, which
    # only costs a later `ask` the 12 (declared) answer it would get anyway.
    case "$rc" in 0|10) ;; *) printf 'presence.sh: dialog claim not released (rc=%s); harmless, the answer is stored\n' "$rc" >&2 ;; esac
  fi
}

# --- ask / release ------------------------------------------------------------
# 0 = free to ask; 12 = a live declaration exists (printed); 13 = dismissed in the last hour (printed).
ask_blocker() {
  local j state expired dis n
  n=$(now)
  j=$(effective_json)
  state=$(printf '%s' "$j" | "$JQ" -r '.state')
  expired=$(printf '%s' "$j" | "$JQ" -r '.expired')
  if [ "$state" != unset ] && [ "$expired" != true ]; then
    status_line "$j"
    return 12
  fi
  dis=$("$JQ" -r '.presence.dismissed_until // 0 | if type == "number" then . else 0 end' "$STATE_FILE" 2>/dev/null) || dis=0
  if [ "${dis:-0}" -gt "$n" ]; then
    printf 'presence dialog dismissed recently; not asking again until %s\n' "$(fmt_time "$dis")"
    return 13
  fi
  return 0
}

cmd_ask() {
  local out rc brc
  brc=0; ask_blocker || brc=$?
  [ "$brc" -eq 0 ] || return "$brc"
  rc=0
  out=$("$RESERVE_SH" claim --kind presence 2>/dev/null) || rc=$?
  case "$rc" in
    0) ;;
    10) printf 'another thread is asking the presence question; do not open it, read presence.sh status later\n'; return 10 ;;
    *) printf 'presence.sh: cannot verify the dialog claim; not asking\n' >&2; return 20 ;;
  esac
  # An answer or a dismissal can land between the check above and the claim (the previous
  # asker released first). Re-check holding the claim, and hand it back if asking is now moot.
  brc=0; ask_blocker || brc=$?
  if [ "$brc" -ne 0 ]; then
    "$RESERVE_SH" release --kind presence --generation "$out" >/dev/null 2>&1 || true
    return "$brc"
  fi
  printf '%s\n' "$out"
}

cmd_release() {
  local gen="" dismissed=0 rc=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --generation) [ $# -ge 2 ] || die_usage "--generation needs a value"; gen="$2"; shift 2 ;;
      --dismissed) dismissed=1; shift ;;
      *) die_usage "unknown argument to release: $1" ;;
    esac
  done
  [ -n "$gen" ] || die_usage "release needs --generation"
  if [ "$dismissed" -eq 1 ]; then
    # Only the current holder's dismissal counts: a stale token must not start a cooldown.
    # Written before the release so a failure here never leaves the claim gone with no pause.
    "$RESERVE_SH" verify --kind presence --generation "$gen" >/dev/null 2>&1 || return 0
    "$SESSION_STATE_SH" --set ".presence.dismissed_until=$(( $(now) + DISMISS_SECONDS ))" >/dev/null ||
      { printf 'presence.sh: state write failed\n' >&2; return 1; }
  fi
  "$RESERVE_SH" release --kind presence --generation "$gen" >/dev/null 2>&1 || rc=$?
  case "$rc" in 0|10) return 0 ;; *) printf 'presence.sh: claim not released (rc=%s)\n' "$rc" >&2; return 1 ;; esac
}

# --- main -----------------------------------------------------------------------
[ $# -gt 0 ] || { usage; exit 2; }
sub="$1"; shift
case "$sub" in -h|--help|help) usage; exit 0 ;; esac
[ -n "$JQ" ] || { printf 'presence.sh: jq not found\n' >&2; exit 1; }

args=()
while [ $# -gt 0 ]; do
  case "$1" in
    --cwd) [ $# -ge 2 ] || die_usage "--cwd needs a value"; CWD="$2"; shift 2 ;;
    --repo) [ $# -ge 2 ] || die_usage "--repo needs a value"; REPO="$2"; shift 2 ;;
    *) args+=("$1"); shift ;;
  esac
done
set -- ${args[@]+"${args[@]}"}

case "$sub" in
  status) cmd_status "$@" ;;
  is-away) cmd_is_away ;;
  set) cmd_set "$@" ;;
  ask) cmd_ask ;;
  release) cmd_release "$@" ;;
  *) die_usage "unknown subcommand: $sub" ;;
esac
