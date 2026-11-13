#!/usr/bin/env bash
# presence.sh — the operator's here-or-away state, one record for every thread.
# catalog: scheduling-monitoring — Presence windows: one global here-or-away state with an end time, read with one call; one thread asks the dialog
#
# PURPOSE (issues #2293 and #2294, increments 1 and 2 of 4)
#   Agents otherwise guess whether the operator is at the computer. This stores
#   the declared answer once, globally (the operator is one person), and
#   arbitrates which single thread asks the dialog that collects it. A window
#   that runs out ends QUIETLY: `expire` (called lazily by the hooks, or by a
#   thread's own watch) makes threads record questions and take reversible
#   defaults, once for all threads; the operator's next message ends that
#   (`return`). Nothing here runs on a timer and nothing opens a question by
#   itself. The pre-leave pass, the long-away check-in and work planning are
#   later increments (issues #2295, #2296).
#   Contract and rationale: .claude/reference/presence-windows.md.
#
# USAGE
#   presence.sh status [--json]     one call: state, end, time left. State is here | away | unset.
#   presence.sh is-away             exit 0 when away (an active unattended window counts), else 1
#   presence.sh set here|away|closing --by operator-message|operator-dialog
#                  [--for <N>m|<N>h | --until-epoch <E> | --rest-of-day | --open-ended]
#                  [--generation <token>]
#      --by operator-dialog: the operator's own dialog pick; needs the --generation token `ask`
#      printed, and is refused (exit 10) when that token is not the live claim
#       here     at the computer until the end (here + --open-ended: until told otherwise)
#       away     away, machine still running: arms unattended mode for the same window
#       closing  laptop closes at the deadline an armed /leave-by holds; no duration flag, and
#                refuses (exit 3) when none is armed — run /leave-by first
#       --rest-of-day  here: until local midnight; away: until 08:00 local (overnight)
#       --generation   the token `ask` printed; released after the write
#   presence.sh ask                 claim the one dialog; see exit codes
#   presence.sh release --generation <token> [--dismissed]
#                                   give the claim back; --dismissed (no answer) pauses `ask` for an hour
#   presence.sh expire              a window ran out? Claim it once for all threads and print what to do.
#                                   Exit 0 this caller won and printed the notice; 1 no window has run out;
#                                   10 it ran out but another thread holds the claim (or the write was refused,
#                                   which the next evaluation retries); 11 the claim could not be written
#   presence.sh return [--no-dialog]  the operator spoke after a window ran out: end away handling, record a
#                                   pending dialog. Exit 0 returned, 1 nothing to return from, 10 lost the race
#   presence.sh relist              a return winner stopped listing (the dialog is still "listing" after two
#                                   minutes): take over the return and list. Exit 0 taken, 10 another took it, 1 none stale
#   presence.sh dialog-claim        claim the pending post-return dialog once, globally. Exit 0 claimed, else 1
#   presence.sh dialog-ready [--now]  the return's winner finished listing: open the dialog for the next message,
#                                   or with --now claim it for this turn (nothing was saved). Exit 0 done, else 1
#   presence.sh probe               one read, one word for a hook: lapsed | lapsed-claimed | returning | dialog | none
#   presence.sh push-result sent|missed --generation <epoch>   record whether the expiry push was delivered
#   Global flags: --repo <owner/name> | --cwd DIR resolve which repo's /leave-by deadline `closing` reads.
#
# STATE  ~/.claude/session-state.json `.presence` = {state, until_epoch|null, declared_epoch,
#        machine_on, declared_by, dismissed_until, reservation, closing_repo, expiry_claim, return,
#        returned_epoch}. Written only through session-state.sh;
#        read directly with jq (hooks may read it on every prompt). An active `.unattended` window reads as
#        away when it is the newer declaration, so the existing unattended switch needs no second step.
#
# EXIT CODES
#   0 ok / ask granted (prints the token); 1 is-away false, or a write failed; 2 usage error;
#   3 closing with no armed leave deadline; 10 another thread holds the dialog, or a set used a stale token (read `status`);
#   12 a live declaration exists, or a window ran out and the operator has not spoken since (printed; do not ask);
#   13 the dialog was dismissed in the last hour;
#   20 the claim could not be verified (do not ask).
#
# Bash 3.2 compatible (macOS /bin/bash).
set -uo pipefail

HERE=$(cd -P "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd) || HERE="."
SESSION_STATE_SH="${PRESENCE_SESSION_STATE_SH:-$HERE/session-state.sh}"
RESERVE_SH="${PRESENCE_RESERVE_SH:-$HERE/prompt-reservation.sh}"
UNATTENDED_SH="${PRESENCE_UNATTENDED_SH:-$HERE/unattended.sh}"
SELF_Q=$(printf '%q' "$HERE/presence.sh")
STATE_FILE="${HOME}/.claude/session-state.json"
DISMISS_SECONDS=3600

JQ=$(command -v jq 2>/dev/null) || JQ=""
if [ -z "$JQ" ]; then
  for c in /opt/homebrew/bin/jq /usr/local/bin/jq /usr/bin/jq; do
    if [ -x "$c" ]; then JQ="$c"; break; fi
  done
fi

# Child scripts (prompt-reservation.sh, session-state.sh) need jq on PATH; the fallback
# locations above may not be on it, so append the resolved jq directory (never prepend: it must not shadow the caller tools) for children.
[ -z "$JQ" ] || case "$JQ" in /*) PATH="$PATH:$(dirname "$JQ")"; export PATH ;; esac

usage() { sed -n '2,/^# Bash 3.2/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }
die_usage() { printf 'presence.sh: %s\n' "$1" >&2; exit 2; }
now() { date +%s; }
fmt_time() { date -r "$1" '+%a %H:%M %Z' 2>/dev/null || date -d "@$1" '+%a %H:%M %Z' 2>/dev/null || printf '%s' "$1"; }

# --- reading ----------------------------------------------------------------
# One jq definition of a LAPSED window, shared by every reader, so status, expire and return can
# never disagree: a declared window whose end passed and that the operator has not answered with a
# message since (return clears it). Open-ended windows never lapse. kind is the window's own kind:
# here (at the computer) or away. source says which record carries it: presence, or a plain
# `unattended.sh on --for` window that has no presence record (or an older one). On a tie of the
# two declaration times unattended wins, as in effective_json (`set away` writes both with one time).
# An away window counts only while its unattended flag is still on: turning it off by hand ends it.
LAPSE_DEF='
def isnum: type == "number";
def lapse($p; $u; $now):
  ($p.state // "") as $ps | ($p.declared_epoch // 0) as $pt | ($u.since_epoch // 0) as $ut
  | if ($u.active == true) and ($u.until_epoch | isnum) and $u.until_epoch <= $now and $ut >= $pt
    then {kind: "away", generation: $ut, until: $u.until_epoch, source: "unattended"}
    elif ($ps == "here" or ($ps == "away" and $u.active == true))
         and ($p.until_epoch | isnum) and $p.until_epoch <= $now
         and (($u.active == true and $ut >= $pt) | not)
    then {kind: $ps, generation: $pt, until: $p.until_epoch, source: "presence"}
    else null end;
'

# The effective state as one JSON object. Never fails: an unreadable file is "unset".
effective_json() {
  local n
  n=$(now)
  if [ ! -f "$STATE_FILE" ]; then
    printf '{"state":"unset","source":"none","until_epoch":null,"declared_epoch":null,"machine_on":true,"expired":false,"lapsed":false,"remaining_seconds":null,"now_epoch":%s}\n' "$n"
    return 0
  fi
  "$JQ" -c --argjson now "$n" "$LAPSE_DEF"'
    (.presence | if type == "object" then . else {} end) as $p
    | (.unattended | if type == "object" then . else {} end) as $u
    | lapse($p; $u; $now) as $lp
    | ($p.state // "") as $ps
    | (($u.active == true) and (($u.until_epoch | isnum | not) or $u.until_epoch > $now)) as $ua
    | ($ps == "here" or $ps == "away") as $pv
    | ($p.declared_epoch // 0) as $pt
    | ($u.since_epoch // 0) as $ut
    | (if $ua and (($pv | not) or $ut >= $pt) then
         {state: "away", source: "unattended",
          until_epoch: (if ($u.until_epoch | isnum) then $u.until_epoch else null end),
          declared_epoch: ($u.since_epoch // null), machine_on: true}
       elif ($lp != null and $lp.source == "unattended") then
         {state: "away", source: "unattended", until_epoch: $lp.until,
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
           lapsed: ($lp != null),
           remaining_seconds: (if (.until_epoch | isnum) then ([.until_epoch - $now, 0] | max) else null end),
           now_epoch: $now}' "$STATE_FILE" 2>/dev/null ||
    printf '{"state":"unset","source":"none","until_epoch":null,"declared_epoch":null,"machine_on":true,"expired":false,"lapsed":false,"remaining_seconds":null,"now_epoch":%s}\n' "$n"
}

status_line() { # JSON
  local f state source until expired left machine lapsed out
  f=$(printf '%s' "$1" | "$JQ" -r '[.state, .source, (.until_epoch // ""), (.expired | tostring),
    ((.remaining_seconds // 0) / 60 | floor | tostring), (.machine_on | tostring), (.lapsed | tostring)] | join("|")') || f=""
  IFS='|' read -r state source until expired left machine lapsed <<EOF
$f
EOF
  if [ "$state" = unset ] || [ -z "$state" ]; then printf 'unset (no presence declared)\n'; return 0; fi
  out="$state"
  [ "$machine" = false ] && out="$out (laptop closes at the end)"
  if [ -z "$until" ]; then
    out="$out, until you say otherwise"
  elif [ "$lapsed" = true ]; then
    # The window ran out and the operator has not spoken since: threads handle questions as in away mode.
    out="$out, ended $(fmt_time "$until"); threads record questions and take reversible defaults until you send a message"
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
  reconcile_closing
  j=$(effective_json)
  if [ "$json" -eq 1 ]; then printf '%s\n' "$j"; else status_line "$j"; fi
}

# Away, or a window that ran out unanswered (threads handle questions as in away mode).
cmd_is_away() {
  reconcile_closing
  [ "$(effective_json | "$JQ" -r 'if (.state == "away" and (.expired | not)) or .lapsed then "yes" else "no" end')" = yes ]
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
leave_deadline() { # prints "<repo key> <armed /leave-by deadline epoch>", or returns 1
  local k="$REPO" d="${CWD:-$PWD}" v
  if [ -n "$k" ]; then
    # State keys are lowercase; an explicit --repo Acme/Widgets must find acme/widgets.
    k=$("$SESSION_STATE_SH" --repo "$k" --repo-key 2>/dev/null) || k=""
  elif [ -d "$d" ]; then
    k=$(cd "$d" 2>/dev/null && "$SESSION_STATE_SH" --repo-key 2>/dev/null) || k=""
  fi
  [ -n "$k" ] && [ "$k" != "_unknown" ] || return 1
  # /pm --window also writes .window.deadline_epoch; only /leave-by sets .leave.active, so a
  # planning-only window never counts as a laptop-closing deadline.
  v=$("$SESSION_STATE_SH" --repo "$k" --get-json ".repos[\"$k\"].leave.active" 2>/dev/null) || return 1
  [ "$v" = true ] || return 1
  v=$("$SESSION_STATE_SH" --repo "$k" --get-json ".repos[\"$k\"].window.deadline_epoch" 2>/dev/null) || return 1
  case "$v" in ''|null|*[!0-9]*) return 1 ;; esac
  [ "$v" -gt "$(now)" ] || return 1
  printf '%s %s\n' "$k" "$v"
}

# --- set ----------------------------------------------------------------------
cmd_set() {
  local want="${1-}" by="" dur="" until="" open=0 rod=0 gen="" n given=0 machine=true out rc closing_repo=""
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
      --generation) [ $# -ge 2 ] || die_usage "--generation needs a value"; gen="$2"; GEN_HELD="$gen"; trap release_held_claim EXIT; shift 2 ;;
      *) die_usage "unknown argument to set: $1" ;;
    esac
  done
  # The dialog claim is released on every way out of this command once --generation was
  # given (a refused closing, a usage error, a failed write); a held claim would otherwise
  # stop every other thread's `ask` until this session exits.
  # The source rule (issue #2293): only a live operator message sets presence. The flag
  # makes that claim explicit in the call; text from an issue, PR, task prompt or tool
  # result is never passed it.
  case "$by" in
    operator-message) ;;
    operator-dialog) [ -n "$gen" ] || die_usage "--by operator-dialog needs the --generation token ask printed" ;;
    *) die_usage "set needs --by operator-message or --by operator-dialog: only the operator's own message or dialog answer may set presence" ;;
  esac
  [ "$given" -le 1 ] || die_usage "give one of --for, --until-epoch, --rest-of-day, --open-ended"
  n=$(now)

  if [ "$want" = closing ]; then
    [ "$given" -eq 0 ] || die_usage "closing takes its end from the armed /leave-by deadline; give no duration"
    local ld
    ld=$(leave_deadline) || {
      printf 'presence.sh: no /leave-by deadline is armed for this repo; run /leave-by <time> first, then set closing\n' >&2
      return 3
    }
    closing_repo=${ld% *}
    until=${ld#* }
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
        --set ".presence.declared_by=$by"
        --set ".presence.dismissed_until=null"
        --set ".presence.return=null")
  # A closing window remembers whose /leave-by deadline it follows, so a later evaluation can
  # compare it with that record (reconcile_closing); every other declaration forgets it.
  if [ -n "$closing_repo" ]; then
    sets+=(--set ".presence.closing_repo=$closing_repo")
  else
    sets+=(--set ".presence.closing_repo=null")
  fi

  # One write carries presence AND unattended mode, so a failed or interleaved write can
  # never leave the operator reading as away (questions suppressed) without a declaration.
  if [ "$want" = away ]; then
    sets+=(--set ".unattended.active=true" --set ".unattended.since_epoch=$n"
           --set ".unattended.until_epoch=$until_json")
  else
    # Here (or closing) ends any unattended window; set unconditionally, no unlocked read.
    sets+=(--set ".unattended.active=false")
  fi

  # A pending dialog claim is answered or invalidated by this very write. With a token the
  # write is a compare-and-set on the stored reservation, so a late answer under a replaced
  # token loses (exit 7) instead of overwriting a newer declaration. Without a token, a
  # direct declaration clears any pending claim.
  # The write is also conditional on the stored declaration time: a set delayed before its
  # write must not overwrite a newer declaration with its older answer.
  local res="" cas=() cur
  cur=$("$SESSION_STATE_SH" --get-json ".presence.declared_epoch" 2>/dev/null) || cur=null
  case "$cur" in ''|*[!0-9]*) cur=null ;; esac
  if [ "$cur" != null ] && [ "$cur" -gt "$n" ]; then
    printf 'presence.sh: a newer declaration is already stored; nothing written, read presence.sh status\n' >&2
    return 10
  fi
  if [ -n "$gen" ]; then
    rc=0
    "$RESERVE_SH" verify --kind presence --generation "$gen" >/dev/null 2>&1 || rc=$?
    case "$rc" in
      0) ;;
      10) printf 'presence.sh: the dialog claim is no longer yours; nothing written, read presence.sh status\n' >&2; return 10 ;;
      *) printf 'presence.sh: cannot verify the dialog claim; nothing written\n' >&2; return 20 ;;
    esac
    res=$("$SESSION_STATE_SH" --get-json ".presence.reservation" 2>/dev/null) || res=""
    if [ -z "$res" ] || [ "$(printf '%s' "$res" | "$JQ" -r '.generation // ""' 2>/dev/null)" != "$gen" ]; then
      printf 'presence.sh: the dialog claim is no longer yours; nothing written, read presence.sh status\n' >&2
      return 10
    fi
    cas=(--cas ".presence.reservation=null" --expect "$res" --expect-at ".presence.declared_epoch" "$cur")
  else
    cas=(--cas ".presence.declared_epoch=$n" --expect "$cur")
    sets+=(--set ".presence.reservation=null")
  fi

  rc=0
  "$SESSION_STATE_SH" "${cas[@]}" "${sets[@]}" >/dev/null || rc=$?
  case "$rc" in
    0) ;;
    7) printf 'presence.sh: the dialog claim or the stored declaration changed while answering; nothing written, read presence.sh status\n' >&2; return 10 ;;
    *) printf 'presence.sh: state write failed\n' >&2; return 1 ;;
  esac
  GEN_HELD=""   # the write cleared the reservation; nothing left to release
  if [ "$want" = away ]; then
    if [ -z "$until" ]; then
      printf 'unattended: on until you say otherwise\n'
    else
      printf 'unattended: on until %s (epoch %s)\n' "$(fmt_time "$until")" "$until"
    fi
    printf 'pre-leave check: list linked sessions and confirm none is waiting on the user; say so.\n'
  fi
  if [ -n "$until" ] && [ "$want" != closing ]; then
    print_expiry_watch "$until"
  fi
  cmd_status
  if [ "$want" = closing ]; then
    printf 'closing: the /leave-by wind-down owns the stop at that time; nothing else is armed here.\n'
  fi
}

# The watch that wakes THIS thread at the deadline so it can run `expire` (a hook cannot call a model
# tool, and nothing runs between turns). A Monitor can be gone before a long deadline (the desktop
# app ends one after about 30 minutes); the hooks evaluate expiry too, so a lost watch only delays it.
print_expiry_watch() { # EPOCH
  printf 'window-end watch (persistent Monitor): until [ "$(date +%%s)" -ge %s ]; do sleep 60; done; echo "presence window ended: run %s expire and follow what it prints"\n' "$1" "$SELF_Q"
}

GEN_HELD=""
# Give a dialog claim back; a failed release leaves the global slot held for the life of this
# session, so say so (the caller's exit status is unchanged).
release_claim_visible() {
  local rc=0
  "$RESERVE_SH" release --kind presence --generation "$1" >/dev/null 2>&1 || rc=$?
  case "$rc" in 0|10) ;; *) printf 'presence.sh: dialog claim not released (rc=%s); other threads cannot ask until it is: run presence.sh release --generation %s\n' "$rc" "$1" >&2 ;; esac
}
release_held_claim() {
  [ -z "$GEN_HELD" ] || release_claim_visible "$GEN_HELD"
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
  # A window that ran out with no message since: threads are in away handling, and no question is
  # opened on a timer. The dialog is asked after the operator's next message (return), not before.
  if [ "$(printf '%s' "$j" | "$JQ" -r '.lapsed')" = true ]; then
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
    release_claim_visible "$out"
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
    # The cooldown and the reservation clear are ONE compare-and-set on the stored reservation,
    # so a declaration that cleared it first makes this dismissal lose instead of blocking `ask`
    # for an hour after that declaration expires.
    local res
    "$RESERVE_SH" verify --kind presence --generation "$gen" >/dev/null 2>&1 || rc=$?
    case "$rc" in
      0) ;;
      10) return 0 ;;   # not the live holder: nothing to dismiss
      *) printf 'presence.sh: cannot verify the dialog claim; dismissal not stored\n' >&2; return 20 ;;
    esac
    rc=0
    res=$("$SESSION_STATE_SH" --get-json ".presence.reservation" 2>/dev/null) || res=""
    [ -n "$res" ] && [ "$(printf '%s' "$res" | "$JQ" -r '.generation // ""' 2>/dev/null)" = "$gen" ] || return 0
    "$SESSION_STATE_SH" --cas ".presence.reservation=null" --expect "$res" \
      --set ".presence.dismissed_until=$(( $(now) + DISMISS_SECONDS ))" >/dev/null || rc=$?
    case "$rc" in
      0|7) return 0 ;;
      *) printf 'presence.sh: state write failed\n' >&2; return 1 ;;
    esac
  fi
  "$RESERVE_SH" release --kind presence --generation "$gen" >/dev/null 2>&1 || rc=$?
  case "$rc" in 0|10) return 0 ;; *) printf 'presence.sh: claim not released (rc=%s)\n' "$rc" >&2; return 1 ;; esac
}

# --- expiry, return ----------------------------------------------------------
jf() { printf '%s' "$1" | "$JQ" -c "$2" 2>/dev/null; }          # JSON field
jr() { printf '%s' "$1" | "$JQ" -r "$2" 2>/dev/null; }          # raw field

# Everything one evaluation needs, from ONE read of the state file: the lapsed window (or null),
# whether it was already claimed, the values the claim must still find unchanged, and a closing
# window whose end no longer matches its /leave-by record.
eval_json() {
  if [ ! -f "$STATE_FILE" ]; then printf '{"lapse":null,"rec":null}\n'; return 0; fi
  "$JQ" -c --argjson now "$(now)" "$LAPSE_DEF"'
    (.presence | if type == "object" then . else {} end) as $p
    | (.unattended | if type == "object" then . else {} end) as $u
    | . as $root
    | lapse($p; $u; $now) as $lp
    | (if $p.state == "here" and $p.machine_on == false and ($p.until_epoch | isnum)
          and (($p.closing_repo // "") | type == "string" and length > 0) then
         ($root.repos[$p.closing_repo].leave // {}) as $lv
         | ($root.repos[$p.closing_repo].window.deadline_epoch // null) as $dl
         | (if ($lv | has("active")) then $lv.active else null end) as $la
         | if $lv.active == true and ($dl | isnum) then
             (if $dl != $p.until_epoch then {action: "set", new_until: $dl, old_until: $p.until_epoch, repo: $p.closing_repo, leave_active: $la} else null end)
           elif $p.until_epoch > $now then {action: "clear", old_until: $p.until_epoch, repo: $p.closing_repo, leave_active: $la, deadline: $dl}
           else null end
       else null end) as $rec
    | {lapse: $lp,
       claimed: (($lp != null) and ($p.expiry_claim | type == "object") and ($p.expiry_claim.generation == $lp.generation)),
       claim: ($p.expiry_claim // null), ps: ($p.state // null), pt: ($p.declared_epoch // null),
       ut: ($u.since_epoch // null), ua: (if ($u | has("active")) then $u.active else null end), rec: $rec,
       dlg: ($p.return.dialog? // null), dlg_gen: ($p.return.generation? // null)}' "$STATE_FILE" 2>/dev/null ||
    printf '{"lapse":null,"rec":null}\n'
}

# The state file is large (megabytes) and a read costs tens of milliseconds, so one command reads it
# once and shares the result; a write that changes it drops the cache.
EVAL=""
get_eval() { [ -n "$EVAL" ] || EVAL=$(eval_json); }

# A stored closing window follows the /leave-by record it was set from. Compare them on every
# evaluation and correct the window when the leave time moved, clear it when the leave time was
# cancelled while the window was still live. A deadline that already passed with the record gone
# is left alone: the laptop is closing, and the expiry handling stands.
reconcile_closing() {
  local e rec act nu ou pt
  [ -f "$STATE_FILE" ] || return 0
  get_eval; e="$EVAL"
  rec=$(jf "$e" '.rec')
  [ -n "$rec" ] && [ "$rec" != null ] || return 0
  EVAL=""   # about to write: the next read must see the corrected record
  act=$(jr "$rec" '.action'); ou=$(jf "$rec" '.old_until'); pt=$(jf "$e" '.pt')
  # Each write also guards the leave record it was decided from, so a /leave-by change that lands
  # between the read and the write makes this correction lose (the next evaluation redoes it).
  local ck la
  ck=$(jr "$rec" '.repo'); la=$(jf "$rec" '.leave_active')
  case "$act" in
    set)
      nu=$(jf "$rec" '.new_until')
      "$SESSION_STATE_SH" --cas ".presence.until_epoch=$nu" --expect "$ou" \
        --expect-at ".presence.declared_epoch" "$pt" --expect-at ".presence.state" '"here"' \
        --expect-at ".repos[\"$ck\"].leave.active" "$la" \
        --expect-at ".repos[\"$ck\"].window.deadline_epoch" "$nu" >/dev/null 2>&1 || true ;;
    clear)
      "$SESSION_STATE_SH" --cas ".presence.state=null" --expect '"here"' \
        --expect-at ".presence.declared_epoch" "$pt" --expect-at ".presence.until_epoch" "$ou" \
        --expect-at ".repos[\"$ck\"].leave.active" "$la" \
        --expect-at ".repos[\"$ck\"].window.deadline_epoch" "$(jf "$rec" '.deadline')" \
        --set ".presence.until_epoch=null" --set ".presence.machine_on=true" \
        --set ".presence.closing_repo=null" >/dev/null 2>&1 || true ;;
  esac
}

# Which stored end a lapse was judged by, so a claim can refuse when that end moved meanwhile.
deadline_path() { # LAPSE JSON
  if [ "$(jr "$1" '.source')" = unattended ]; then printf '.unattended.until_epoch\n'; else printf '.presence.until_epoch\n'; fi
}

# The text of the single phone push. ASCII, no links, short: it is typed into a model tool call.
PUSH_TEXT='Presence window ended: threads now save questions and work on defaults until you message.'

# A window ran out. Exactly one caller, across every thread and hook, wins the claim and prints what
# to do; everyone else prints nothing. The claim is one compare-and-set on the window's generation
# (its declaration time), refused if the window was re-declared, ended or answered in the meantime.
# Deliberately before delivery: a crash after the claim loses the notice rather than duplicating it.
cmd_expire() {
  [ $# -eq 0 ] || die_usage "expire takes no arguments"
  local e lp kind gen until n claim newclaim rc=0
  reconcile_closing
  get_eval; e="$EVAL"
  lp=$(jf "$e" '.lapse')
  [ -n "$lp" ] && [ "$lp" != null ] || return 1
  [ "$(jr "$e" '.claimed')" != true ] || return 10
  kind=$(jr "$lp" '.kind'); gen=$(jf "$lp" '.generation'); until=$(jf "$lp" '.until')
  n=$(now)
  newclaim=$("$JQ" -cn --argjson g "$gen" --argjson n "$n" --arg k "$kind" '{generation: $g, epoch: $n, kind: $k, push: null}') || return 11
  claim=$(jf "$e" '.claim')
  "$SESSION_STATE_SH" --cas ".presence.expiry_claim=$newclaim" --expect "$claim" \
    --expect-at ".presence.declared_epoch" "$(jf "$e" '.pt')" \
    --expect-at ".unattended.since_epoch" "$(jf "$e" '.ut')" \
    --expect-at ".unattended.active" "$(jf "$e" '.ua')" \
    --expect-at ".presence.state" "$(jf "$e" '.ps')" \
    --expect-at "$(deadline_path "$lp")" "$until" >/dev/null 2>&1 || rc=$?
  # Lost the claim (7): another thread printed the notice. Any other failure: nothing was printed,
  # so the next evaluation still sees an unclaimed lapse and tries again. Never a second notice.
  case "$rc" in
    0) : ;;
    7) return 10 ;;
    *) return 11 ;;
  esac
  if [ "$kind" = here ]; then
    printf 'presence: your at-computer window ended %s. Threads now record questions and take reversible defaults, and park steps that are not reversible, until you send a message; no menu opens before that.\n' "$(fmt_time "$until")"
    printf 'Print the line above once, then (once only) call the PushNotification tool with exactly this text: %s\n' "$PUSH_TEXT"
    printf 'Afterwards run: %s push-result sent|missed --generation %s   (missed when the push could not be delivered; never retry it)\n' "$SELF_Q" "$gen"
  else
    # Keep what was listed even when one repo's file could not be read: those questions are marked.
    local list="" lrc=0
    if [ -x "$UNATTENDED_SH" ]; then list=$("$UNATTENDED_SH" digest --all --mark 2>/dev/null) || lrc=$?; fi
    printf 'presence: your away window ended %s. Threads stay in away handling (questions recorded, reversible defaults, no menu) until you send a message. No push is sent.\n' "$(fmt_time "$until")"
    if [ -n "$list" ]; then
      printf 'Show the operator this list once, without opening a menu:\n%s\n' "$list"
    else
      printf 'No saved questions yet.\n'
    fi
    [ "$lrc" -eq 0 ] || printf 'Some repo question files could not be read: run %s digest --all --mark again.\n' "$(printf '%q' "$UNATTENDED_SH")"
  fi
  return 0
}

# The operator spoke after a window ran out: away handling ends, and the presence dialog is owed.
# One compare-and-set per window generation, so only one session handles each return. Acts only on
# a LAPSED window: a message inside a window the operator declared and that is still running
# changes nothing (he may be writing from his phone while away).
cmd_return() {
  local nodialog=0 e lp n ret rc=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --no-dialog) nodialog=1; shift ;;
      *) die_usage "unknown argument to return: $1" ;;
    esac
  done
  [ -f "$STATE_FILE" ] || return 1
  reconcile_closing
  get_eval; e="$EVAL"
  lp=$(jf "$e" '.lapse')
  [ -n "$lp" ] && [ "$lp" != null ] || return 1
  n=$(now)
  # dialog starts as "listing": the winner is still listing the saved questions, and no other
  # hook may ask the dialog until it says so (dialog-ready).
  if [ "$nodialog" -eq 1 ]; then ret=null; else ret="{\"generation\":$n,\"dialog\":\"listing\"}"; fi
  "$SESSION_STATE_SH" --cas ".presence.state=null" --expect "$(jf "$e" '.ps')" \
    --expect-at ".presence.declared_epoch" "$(jf "$e" '.pt')" \
    --expect-at ".unattended.since_epoch" "$(jf "$e" '.ut')" \
    --expect-at ".unattended.active" "$(jf "$e" '.ua')" \
    --expect-at "$(deadline_path "$lp")" "$(jf "$lp" '.until')" \
    --set ".presence.until_epoch=null" --set ".presence.machine_on=true" --set ".presence.closing_repo=null" \
    --set ".presence.returned_epoch=$n" --set ".presence.return=$ret" \
    --set ".unattended.active=false" >/dev/null 2>&1 || rc=$?
  case "$rc" in
    0) return 0 ;;
    7) return 10 ;;
    *) return 1 ;;
  esac
}

# What a hook should do about presence, from one read: lapsed (a window ran out, nobody has claimed
# its notice: run `expire`), lapsed-claimed (it ran out and the notice went out: the operator's next
# message runs `return`), dialog (a return left the dialog pending: `dialog-claim`), or none.
cmd_probe() {
  local e lp
  [ -f "$STATE_FILE" ] || { printf 'none\n'; return 0; }
  reconcile_closing
  get_eval; e="$EVAL"
  lp=$(jf "$e" '.lapse')
  if [ -n "$lp" ] && [ "$lp" != null ]; then
    if [ "$(jr "$e" '.claimed')" = true ]; then printf 'lapsed-claimed\n'; else printf 'lapsed\n'; fi
  elif [ "$(jr "$e" '.dlg')" = pending ]; then
    printf 'dialog\n'
  elif [ "$(jr "$e" '.dlg')" = listing ]; then
    # A return just happened and its winner is still listing: nobody else lists or asks yet. After
    # two minutes the winner is presumed dead: listing-stale, which any hook may take over (relist).
    if [ $(( $(now) - $(jr "$e" '.dlg_gen // 0') )) -lt 120 ]; then printf 'returning\n'; else printf 'listing-stale\n'; fi
  else
    printf 'none\n'
  fi
}

# A return winner that stopped listing (dialog still "listing" after two minutes) must not strand the
# saved questions of the other repos. Take the return over: one compare-and-set on the stale
# generation, so exactly one hook lists in its place. The caller then lists every repo as a return does.
cmd_relist() {
  local e g n rc=0
  [ -f "$STATE_FILE" ] || return 1
  reconcile_closing
  get_eval; e="$EVAL"
  [ "$(jr "$e" '.dlg')" = listing ] || return 1
  [ $(( $(now) - $(jr "$e" '.dlg_gen // 0') )) -ge 120 ] || return 1
  g=$(jf "$e" '.dlg_gen'); n=$(now)
  "$SESSION_STATE_SH" --cas ".presence.return.generation=$n" --expect "$g" \
    --expect-at ".presence.return.dialog" '"listing"' >/dev/null 2>&1 || rc=$?
  case "$rc" in
    0) return 0 ;;
    7) return 10 ;;
    *) return 1 ;;
  esac
}

# The return's winner has finished listing the saved questions: open the dialog for the next
# message (pending), or, with --now (nothing was saved), claim it for this very turn (asked; exit 0).
cmd_dialog_ready() {
  local now_flag=0 g target rc=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --now) now_flag=1; shift ;;
      *) die_usage "unknown argument to dialog-ready: $1" ;;
    esac
  done
  [ -f "$STATE_FILE" ] || return 1
  [ "$("$JQ" -r '.presence.return.dialog // ""' "$STATE_FILE" 2>/dev/null)" = listing ] || return 1
  g=$("$JQ" -c '.presence.return.generation // null' "$STATE_FILE" 2>/dev/null) || return 1
  target=pending; [ "$now_flag" -eq 0 ] || target=asked
  "$SESSION_STATE_SH" --cas ".presence.return.dialog=$target" --expect listing \
    --expect-at ".presence.return.generation" "$g" >/dev/null 2>&1 || rc=$?
  [ "$rc" -eq 0 ]
}

# After a return the dialog is asked once, in total, after the saved questions: this claim moves the
# pending dialog to asked exactly once across every session. The caller then runs `ask` as usual.
cmd_dialog_claim() {
  local g rc=0
  [ -f "$STATE_FILE" ] || return 1
  [ "$("$JQ" -r '.presence.return.dialog // ""' "$STATE_FILE" 2>/dev/null)" = pending ] || return 1
  g=$("$JQ" -c '.presence.return.generation // null' "$STATE_FILE" 2>/dev/null) || return 1
  "$SESSION_STATE_SH" --cas ".presence.return.dialog=asked" --expect pending \
    --expect-at ".presence.return.generation" "$g" >/dev/null 2>&1 || rc=$?
  [ "$rc" -eq 0 ]
}

# Record whether the expiry push reached the phone (the model tool's result; never verified here).
cmd_push_result() {
  local res="${1-}" gen=""
  case "$res" in sent|missed) shift ;; *) die_usage "push-result takes sent or missed" ;; esac
  while [ $# -gt 0 ]; do
    case "$1" in
      --generation) [ $# -ge 2 ] || die_usage "--generation needs a value"; gen="$2"; shift 2 ;;
      *) die_usage "unknown argument to push-result: $1" ;;
    esac
  done
  case "$gen" in ''|*[!0-9]*) die_usage "push-result needs --generation <epoch>" ;; esac
  "$SESSION_STATE_SH" --cas ".presence.expiry_claim.push=$res" --expect null \
    --expect-at ".presence.expiry_claim.generation" "$gen" >/dev/null 2>&1 || true
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
  expire) cmd_expire "$@" ;;
  return) cmd_return "$@" ;;
  relist) cmd_relist "$@" ;;
  dialog-claim) cmd_dialog_claim ;;
  dialog-ready) cmd_dialog_ready "$@" ;;
  push-result) cmd_push_result "$@" ;;
  probe) cmd_probe ;;
  *) die_usage "unknown subcommand: $sub" ;;
esac
