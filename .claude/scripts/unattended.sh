#!/usr/bin/env bash
# unattended.sh — the operator-away switch and the questions recorded while he is away.
# catalog: scheduling-monitoring — Unattended mode: declare the operator away, record questions instead of opening menus, list them once on his return
#
# PURPOSE (issue #2283)
#   While the operator is away, an agent that opens a menu (AskUserQuestion)
#   or waits on him stalls the whole night. Unattended mode is one global flag
#   in ~/.claude/session-state.json (`.unattended`) — the operator is one
#   person, so a declaration made in one repo covers every session — plus one
#   append-only questions file per repo. Agents record a question here, take
#   the recommended option where it is reversible, park only the step that is
#   not, and keep working. The list comes back once: on the operator's next
#   message or when the declared window ends.
#   Contract and rationale: .claude/reference/unattended-mode.md.
#
# USAGE
#   unattended.sh on [--for <N>h|<N>m | --until-epoch <E> | --open-ended]   (default --for 12h)
#                                                --open-ended: no window end (until `off`); issue #2293
#   unattended.sh off [--cwd DIR | --repo KEY]   switch off, then print and mark the digest
#   unattended.sh status                         one line: `active until ...` or `inactive`
#   unattended.sh is-active                      exit 0 away handling applies, 1 not (no output). A window
#                                                that ran out stays active until the operator speaks
#                                                (presence.sh return) or `off`; an at-computer presence
#                                                window that ran out counts too (issue #2294)
#   unattended.sh window-ended                   exit 0 when a declared window has ended, else 1
#   unattended.sh record --question TEXT [--recommended TEXT] [--options 'A|B|C']
#                        [--did TEXT] [--session ID] [--source agent|hook] [--cwd DIR | --repo KEY]
#                                                prints the new id, U-<n>
#   unattended.sh update U-<n> --did TEXT [--cwd DIR | --repo KEY]
#   unattended.sh pending [--cwd DIR | --repo KEY]   count of questions not yet listed
#   unattended.sh digest [--mark] [--cwd DIR | --repo KEY]
#                                                the questions not yet listed, one per item;
#                                                --mark records them as listed
#   unattended.sh digest --all [--mark]          the same for EVERY repo's file, each block labelled
#                                                with its repo key (the operator is one person and may
#                                                come back in any thread; issue #2294)
#   unattended.sh settle --session ID --transcript PATH --ref REF [--force]
#                                                (hooks, issue #2294) pending-delivery records: drop the ones
#                                                whose list reached the model, print (and re-own) the ones that
#                                                did not; see DELIVERY below
#   unattended.sh undelivered --not-ref REF      count of undelivered records another emission still owns
#   unattended.sh --help
#
# STATE
#   Flag:       ~/.claude/session-state.json `.unattended` = {active, since_epoch, until_epoch}
#               (written only through session-state.sh; read directly with jq,
#               because hooks run on every prompt and session-state.sh takes ~1 s)
#   Questions:  ${UNATTENDED_DIR:-~/.claude/unattended}/<owner>__<repo>.jsonl, append-only:
#               {"type":"question","id":"U-1",...} | {"type":"update","id":"U-1","did":...}
#               | {"type":"listed","through":N}
#   The repo key comes from session-state.sh --repo-key run in --cwd (default: the
#   current directory), or --repo.
#
# DELIVERY (issue #2294, PR #2328 review)
#   A listing that marks questions `listed` must not lose them when the process dies between the mark
#   and the model seeing the list. When a hook sets UNATTENDED_DELIVERY_REF, UNATTENDED_DELIVERY_SESSION
#   and UNATTENDED_DELIVERY_TRANSCRIPT (the hook payload's session_id and transcript_path) and the
#   transcript path is given (the file may not exist yet), `digest --mark` writes one record per repo block to
#   ${UNATTENDED_DIR:-~/.claude/unattended}/pending/<id>.json (atomically: temp file, then rename)
#   BEFORE it appends the `listed` watermark. The record holds the rendered text, the emission's ref
#   and the session's transcript path. DELIVERED means: the ref text appears in that transcript, which
#   is where the harness records the context a hook injected, so the model had it. `settle` runs at the
#   top of the operator's prompt hook: a record whose ref is in its transcript is deleted; one that is
#   not is re-emitted when it belongs to the same session (its earlier hook was killed or its output
#   dropped), or to any session once it is 120 s old, or at once with --force (a takeover of a dead
#   return winner). A re-emitted record is re-owned by the new emission and settled the same way, so a
#   question can be shown twice but not zero times. A record never expires by age; after 5 emissions in
#   which the ref never reached the transcript it is dropped and noted in
#   ${UNATTENDED_DIR:-~/.claude/unattended}/delivery.log (the harness is evidently not recording hook
#   output there). Without a transcript path (none in the payload, or a bare CLI call such as `off` or
#   a thread's own `expire`) no record is written and `digest --mark` behaves as before: marked when
#   rendered. Claude Code puts transcript_path in every hook payload.
#
# EXIT CODES
#   0 ok; 1 is-active/window-ended false, or a write failed; 2 usage error.
#
# Bash 3.2 compatible (macOS /bin/bash).
set -uo pipefail

HERE=$(cd -P "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd) || HERE="."
SESSION_STATE_SH="${UNATTENDED_SESSION_STATE_SH:-$HERE/session-state.sh}"
STATE_FILE="${HOME}/.claude/session-state.json"
Q_DIR="${UNATTENDED_DIR:-${HOME}/.claude/unattended}"
PRESENCE_SH="${UNATTENDED_PRESENCE_SH:-$HERE/presence.sh}"
LIB_DIR="$HERE/lib"

JQ=$(command -v jq 2>/dev/null) || JQ=""
if [ -z "$JQ" ]; then
  for c in /opt/homebrew/bin/jq /usr/local/bin/jq /usr/bin/jq; do
    if [ -x "$c" ]; then JQ="$c"; break; fi
  done
fi

# session-state.sh needs jq on PATH too; append (never prepend) the resolved jq directory.
[ -z "$JQ" ] || case "$JQ" in /*) PATH="$PATH:$(dirname "$JQ")"; export PATH ;; esac

usage() { sed -n '2,/^# Bash 3.2/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }
die_usage() { printf 'unattended.sh: %s\n' "$1" >&2; exit 2; }
need_jq() { [ -n "$JQ" ] || { printf 'unattended.sh: jq not found\n' >&2; exit 1; }; }

now() { date +%s; }

# The `.unattended` object, or null.
read_flag() {
  if [ ! -f "$STATE_FILE" ] || [ -z "$JQ" ]; then printf 'null\n'; return 0; fi
  "$JQ" -c '.unattended // null' "$STATE_FILE" 2>/dev/null || printf 'null\n'
}

# Away handling applies (issue #2294) per lib/presence-decision.jq, the ONE decision presence.sh
# status|is-away|expire|return|probe read as well, so the two scripts cannot disagree (see its truth
# table). In short: the newer of the unattended flag and the presence declaration governs; when
# neither is clearly newer the answer is away; an away window that ran out stays away handling until
# the operator speaks (presence.sh return) or `off`; an at-computer window that ran out counts too.
# Here only the stored records are read, so this stays one cheap read.
is_active() {
  [ -f "$STATE_FILE" ] || return 1
  [ "$("$JQ" -L "$LIB_DIR" -r --argjson n "$(now)" 'include "presence-decision";
    (.presence | if type == "object" then . else {} end) as $p
    | (.unattended | if type == "object" then . else {} end) as $u
    | if decide($p; $u; $n).away then "yes" else "no" end' "$STATE_FILE" 2>/dev/null)" = yes ]
}

window_ended() {
  local f n
  f=$(read_flag); n=$(now)
  [ "$(printf '%s' "$f" | "$JQ" -r --argjson n "$n" '
    if type == "object" and (.until_epoch | type) == "number"
       and (.active == false or .until_epoch <= $n)
    then "yes" else "no" end' 2>/dev/null)" = yes ]
}

fmt_time() { date -r "$1" '+%a %H:%M %Z' 2>/dev/null || date -d "@$1" '+%a %H:%M %Z' 2>/dev/null || printf '%s' "$1"; }

# --- repo / file resolution -------------------------------------------------
REPO=""
CWD=""
repo_key() {
  if [ -n "$REPO" ]; then printf '%s\n' "$REPO"; return 0; fi
  local d="${CWD:-$PWD}" k=""
  if [ -d "$d" ] && [ -x "$SESSION_STATE_SH" ]; then
    k=$(cd "$d" 2>/dev/null && "$SESSION_STATE_SH" --repo-key 2>/dev/null) || k=""
  fi
  if [ -z "$k" ] || [ "$k" = "_unknown" ]; then
    # No origin: key on the checkout itself, so two such repos never share a file.
    local top
    top=$(cd "$d" 2>/dev/null && git rev-parse --show-toplevel 2>/dev/null) || top=""
    k="_local/$(printf '%s' "${top:-$d}" | tr '/' '_')"
  fi
  printf '%s\n' "$k"
}
q_file() {
  local k
  k=$(repo_key | tr 'A-Z' 'a-z' | sed 's#/#__#g; s#[^a-z0-9._-]#_#g')
  printf '%s/%s.jsonl\n' "$Q_DIR" "$k"
}

# mkdir lock around every write: id allocation, updates, the listed watermark.
LOCK=""
lock() {
  local i=0
  LOCK="$1.lock"
  while ! mkdir "$LOCK" 2>/dev/null; do
    i=$((i + 1))
    if [ "$i" -ge 50 ]; then
      # A lock older than 60 s was left by a killed writer.
      if [ -n "$(find "$LOCK" -maxdepth 0 -mmin +1 2>/dev/null)" ]; then rmdir "$LOCK" 2>/dev/null; i=0; continue; fi
      LOCK=""; return 1
    fi
    sleep 0.1
  done
}
unlock() { [ -n "$LOCK" ] && rmdir "$LOCK" 2>/dev/null; LOCK=""; }

append() { # FILE JSON — refuses an empty record (a failed jq)
  [ -n "$2" ] || return 1
  mkdir -p "$(dirname "$1")" 2>/dev/null || return 1
  printf '%s\n' "$2" >>"$1"
}

# The digest model: questions with their latest `did`, those after the last
# `listed` watermark.
pending_json() { # FILE
  [ -f "$1" ] || { printf '[]\n'; return 0; }
  "$JQ" -R -s -c '
    [split("\n")[] | select(length > 0) | (fromjson? // empty) | select(type == "object")] as $r
    | ([$r[] | select(.type == "listed") | .through | numbers] | max // 0) as $w
    | [$r[] | select(.type == "update")] as $u
    | [$r[] | select(.type == "question")
        | . as $q
        | ($q.id | ltrimstr("U-") | tonumber? // 0) as $n
        | select($n > $w)
        | .did = (([$u[] | select(.id == $q.id) | .did] | last) // .did)]' "$1" 2>/dev/null
}

# --- pending delivery (see DELIVERY above) -------------------------------------
PDIR="$Q_DIR/pending"
DELIVERY_GRACE=120
DELIVERY_MAX_EMITS=5

delivery_log() { # LINE — best effort
  mkdir -p "$Q_DIR" 2>/dev/null || return 0
  printf '%s %s\n' "$(now)" "$1" >>"$Q_DIR/delivery.log" 2>/dev/null || true
}

# Persist one rendered block. 0 staged; 2 not applicable (no ref or no transcript path: legacy
# behaviour); 1 the record could not be written (the caller must NOT mark the questions listed).
stage_record() { # LABEL TEXT
  local ref="${UNATTENDED_DELIVERY_REF:-}" tp="${UNATTENDED_DELIVERY_TRANSCRIPT:-}" name tmp
  [ -n "$ref" ] && [ -n "$tp" ] || return 2
  mkdir -p "$PDIR" 2>/dev/null || return 1
  name="$(now)-$$-$RANDOM"
  tmp="$PDIR/.$name.tmp"
  printf '%s' "$2" | "$JQ" -Rsc --arg ref "$ref" --arg sid "${UNATTENDED_DELIVERY_SESSION:-}" --arg tp "$tp" \
    --arg label "$1" --argjson at "$(now)" \
    '{ref: $ref, session: $sid, transcript: $tp, label: $label, text: ., staged_at: $at, stamped_at: $at, emits: 1}' >"$tmp" 2>/dev/null &&
    [ -s "$tmp" ] && mv "$tmp" "$PDIR/$name.json" || { rm -f "$tmp" 2>/dev/null; return 1; }
}

rewrite_record() { # FILE SESSION TRANSCRIPT REF
  local tmp
  tmp="$1.$$.tmp"
  "$JQ" -c --arg s "$2" --arg t "$3" --arg r "$4" --argjson n "$(now)" \
    '.session = $s | .transcript = $t | .ref = $r | .stamped_at = $n | .emits += 1' "$1" >"$tmp" 2>/dev/null &&
    [ -s "$tmp" ] && mv "$tmp" "$1" || { rm -f "$tmp" 2>/dev/null; return 1; }
}

cmd_settle() {
  local sid="" tp="" ref="" force=0 f fields rref rsid rtp rstamp remits n out="" txt owed
  while [ $# -gt 0 ]; do
    case "$1" in
      --session) sid="${2-}"; shift 2 || die_usage "--session needs a value" ;;
      --transcript) tp="${2-}"; shift 2 || die_usage "--transcript needs a value" ;;
      --ref) ref="${2-}"; shift 2 || die_usage "--ref needs a value" ;;
      --force) force=1; shift ;;
      *) die_usage "unknown argument to settle: $1" ;;
    esac
  done
  [ -n "$ref" ] || die_usage "settle needs --ref"
  [ -d "$PDIR" ] || return 0
  ls "$PDIR"/*.json >/dev/null 2>&1 || return 0
  lock "$PDIR/.settle" || { printf 'unattended.sh: pending records are locked\n' >&2; return 1; }
  n=$(now)
  for f in "$PDIR"/*.json; do
    [ -f "$f" ] || continue
    fields=$("$JQ" -r '[.ref // "", .session // "", .transcript // "", (.stamped_at // 0 | tostring), (.emits // 1 | tostring)] | join("\u001f")' "$f" 2>/dev/null) || fields=""
    if [ -z "$fields" ]; then rm -f "$f" 2>/dev/null; continue; fi   # unreadable: nothing recoverable
    IFS=$(printf '\037') read -r rref rsid rtp rstamp remits <<EOF
$fields
EOF
    # Delivered: the ref is in the owning session's transcript, so the model had the list.
    if [ -n "$rref" ] && [ -n "$rtp" ] && [ -r "$rtp" ] && grep -qF -- "$rref" "$rtp" 2>/dev/null; then
      rm -f "$f" 2>/dev/null; continue
    fi
    # Emitted as often as we ever will (an undelivered list never expires by age: a return after days
    # must still show it).
    case "$rstamp" in ''|*[!0-9]*) rstamp=0 ;; esac
    case "$remits" in ''|*[!0-9]*) remits=1 ;; esac
    if [ "$remits" -ge "$DELIVERY_MAX_EMITS" ]; then
      delivery_log "gave up on a pending list after $remits emissions (ref $rref)"
      rm -f "$f" 2>/dev/null; continue
    fi
    owed=0
    if [ "$force" -eq 1 ]; then owed=1
    elif [ -n "$sid" ] && [ "$rsid" = "$sid" ]; then owed=1
    elif [ $((n - rstamp)) -ge "$DELIVERY_GRACE" ]; then owed=1; fi
    [ "$owed" -eq 1 ] || continue
    txt=$("$JQ" -r '.text // ""' "$f" 2>/dev/null) || txt=""
    [ -n "$txt" ] || { rm -f "$f" 2>/dev/null; continue; }
    out="${out:+$out

}$txt"
    # Re-own it: this emission's ref is what the next settle looks for. If the rewrite fails the old
    # ref stays and a later settle shows the list again, which is the safe direction.
    rewrite_record "$f" "$sid" "$tp" "$ref" || true
  done
  unlock
  [ -z "$out" ] || printf '%s\n' "$out"
}

cmd_undelivered() {
  local ref="" f count=0 r
  while [ $# -gt 0 ]; do
    case "$1" in
      --not-ref) ref="${2-}"; shift 2 || die_usage "--not-ref needs a value" ;;
      *) die_usage "unknown argument to undelivered: $1" ;;
    esac
  done
  if [ -d "$PDIR" ]; then
    for f in "$PDIR"/*.json; do
      [ -f "$f" ] || continue
      r=$("$JQ" -r '.ref // ""' "$f" 2>/dev/null) || r=""
      [ "$r" = "$ref" ] || count=$((count + 1))
    done
  fi
  printf '%s\n' "$count"
}

# --- subcommands ------------------------------------------------------------
cmd_on() {
  local until="" dur="12h" n open=0 given=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --for) [ $# -ge 2 ] || die_usage "--for needs a value"; dur="$2"; given=$((given + 1)); shift 2 ;;
      --until-epoch) [ $# -ge 2 ] || die_usage "--until-epoch needs a value"; until="$2"; given=$((given + 1)); shift 2 ;;
      --open-ended) open=1; given=$((given + 1)); shift ;;
      *) die_usage "unknown argument to on: $1" ;;
    esac
  done
  [ "$open" -eq 0 ] || [ "$given" -le 1 ] || die_usage "--open-ended cannot be combined with --for or --until-epoch"
  n=$(now)
  if [ "$open" -eq 1 ]; then
    # No end: the flag stays on until `off`. A null until_epoch is "never ends" to
    # is_active/window_ended, so no window-end watch is printed.
    "$SESSION_STATE_SH" --set ".unattended.active=true" --set ".unattended.since_epoch=$n" \
      --set ".unattended.until_epoch=null" >/dev/null || { printf 'unattended.sh: state write failed\n' >&2; return 1; }
    printf 'unattended: on until you say otherwise\n'
    printf 'pre-leave check: list linked sessions and confirm none is waiting on the user; say so.\n'
    return 0
  fi
  if [ -z "$until" ]; then
    case "$dur" in
      *[!0-9]*[hm]|[hm]) die_usage "--for takes <N>h or <N>m" ;;
      *h) until=$(( n + 10#${dur%h} * 3600 )) ;;
      *m) until=$(( n + 10#${dur%m} * 60 )) ;;
      *) die_usage "--for takes <N>h or <N>m" ;;
    esac
  fi
  case "$until" in ''|*[!0-9]*) die_usage "bad window end: $until" ;; esac
  [ "$until" -gt "$n" ] || die_usage "the window end is in the past"
  "$SESSION_STATE_SH" --set ".unattended.active=true" --set ".unattended.since_epoch=$n" \
    --set ".unattended.until_epoch=$until" >/dev/null || { printf 'unattended.sh: state write failed\n' >&2; return 1; }
  printf 'unattended: on until %s (epoch %s)\n' "$(fmt_time "$until")" "$until"
  printf 'pre-leave check: list linked sessions and confirm none is waiting on the user; say so.\n'
  printf 'window-end watch (persistent Monitor): until [ "$(date +%%s)" -ge %s ]; do sleep 60; done; echo "presence window ended: run %s expire and follow what it prints"\n' "$until" "$(printf '%q' "$PRESENCE_SH")"
}

cmd_off() {
  "$SESSION_STATE_SH" --set ".unattended.active=false" >/dev/null || { printf 'unattended.sh: state write failed\n' >&2; return 1; }
  # An at-computer window that ran out is "away handling" too: end it with the flag. After the flag
  # write, so a newer unattended window that was live no longer shields the older lapsed one. Best
  # effort and silent; it acts only on a lapsed window and never touches one still running.
  local lapsed=0 pst=""
  if [ -x "$PRESENCE_SH" ]; then pst=$("$PRESENCE_SH" probe 2>/dev/null) || pst=""; fi
  case "$pst" in lapsed|lapsed-claimed) lapsed=1 ;; esac
  printf 'unattended: off\n'
  if [ "$lapsed" -eq 1 ]; then
    # That return is global and clears the lapsed window: list every repo's saved questions FIRST
    # (emitted and marked together, per file), and only then clear the window.
    cmd_digest --all --mark
    local rrc=0
    "$PRESENCE_SH" return --no-dialog >/dev/null 2>&1 || rrc=$?
    # A failed write (exit 11, e.g. a lock timeout) gets one retry, then a visible failure: menus stay
    # denied until the window is cleared, so `off` must not report success.
    if [ "$rrc" -eq 11 ]; then
      rrc=0; "$PRESENCE_SH" return --no-dialog >/dev/null 2>&1 || rrc=$?
    fi
    if [ "$rrc" -eq 11 ]; then
      printf 'unattended: off, but the expired at-computer window could not be cleared: menus may still be suppressed. Retry: %s return --no-dialog\n' "$PRESENCE_SH" >&2
      return 1
    fi
  else
    cmd_digest --mark
  fi
}

cmd_status() {
  local u
  if is_active; then
    # The governing window's own end is the deadline to show (an at-computer window that lapsed has
    # its presence end, not whatever the unattended flag last recorded).
    u=$("$JQ" -L "$LIB_DIR" -r --argjson n "$(now)" 'include "presence-decision";
      (.presence | if type == "object" then . else {} end) as $p
      | (.unattended | if type == "object" then . else {} end) as $u
      | decide($p; $u; $n) | (.until_epoch // empty)' "$STATE_FILE" 2>/dev/null)
    if [ -z "$u" ]; then printf 'active\n'
    elif [ "$u" -gt "$(now)" ]; then printf 'active until %s\n' "$(fmt_time "$u")"
    else printf 'active (window ended %s; until you send a message)\n' "$(fmt_time "$u")"; fi
  else
    printf 'inactive\n'
  fi
}

cmd_record() {
  local q="" rec="" opts="" did="" sid="" src="agent" f n id rc
  while [ $# -gt 0 ]; do
    case "$1" in
      --question) q="${2-}"; shift 2 || die_usage "--question needs a value" ;;
      --recommended) rec="${2-}"; shift 2 || die_usage "--recommended needs a value" ;;
      --options) opts="${2-}"; shift 2 || die_usage "--options needs a value" ;;
      --did) did="${2-}"; shift 2 || die_usage "--did needs a value" ;;
      --session) sid="${2-}"; shift 2 || die_usage "--session needs a value" ;;
      --source) src="${2-}"; shift 2 || die_usage "--source needs a value" ;;
      *) die_usage "unknown argument to record: $1" ;;
    esac
  done
  [ -n "$q" ] || die_usage "record needs --question"
  f=$(q_file)
  mkdir -p "$Q_DIR" 2>/dev/null || { printf 'unattended.sh: cannot create %s\n' "$Q_DIR" >&2; return 1; }
  lock "$f" || { printf 'unattended.sh: questions file is locked\n' >&2; return 1; }
  n=0
  [ -f "$f" ] && n=$(grep -c '"type":"question"' "$f" 2>/dev/null || true)
  case "$n" in ''|*[!0-9]*) n=0 ;; esac
  id="U-$((n + 1))"
  rc=0
  local json
  json=$("$JQ" -cn --arg id "$id" --arg q "$q" --arg r "$rec" --arg o "$opts" --arg d "$did" \
    --arg s "$sid" --arg src "$src" --argjson at "$(now)" '
    {type: "question", id: $id, at: $at, question: $q,
     options: ($o | if . == "" then [] else split("|") end),
     recommended: (if $r == "" then null else $r end),
     did: (if $d == "" then null else $d end),
     session: (if $s == "" then null else $s end), source: $src}') || rc=1
  # jq's exit status, not just its output: a killed jq can leave partial JSON.
  [ "$rc" -eq 0 ] && { append "$f" "$json" || rc=1; }
  unlock
  [ "$rc" -eq 0 ] || { printf 'unattended.sh: write failed\n' >&2; return 1; }
  printf '%s\n' "$id"
}

cmd_update() {
  local id="${1-}" did=""
  [ -n "$id" ] || die_usage "update needs an id"
  shift
  case "$id" in U-[0-9]*) ;; *) die_usage "bad id: $id" ;; esac
  while [ $# -gt 0 ]; do
    case "$1" in
      --did) did="${2-}"; shift 2 || die_usage "--did needs a value" ;;
      *) die_usage "unknown argument to update: $1" ;;
    esac
  done
  [ -n "$did" ] || die_usage "update needs --did"
  local f rc=0
  f=$(q_file)
  mkdir -p "$Q_DIR" 2>/dev/null || { printf 'unattended.sh: cannot create %s\n' "$Q_DIR" >&2; return 1; }
  lock "$f" || { printf 'unattended.sh: questions file is locked\n' >&2; return 1; }
  local json
  json=$("$JQ" -cn --arg id "$id" --arg d "$did" --argjson at "$(now)" \
    '{type: "update", id: $id, at: $at, did: $d}') || rc=1
  [ "$rc" -eq 0 ] && { append "$f" "$json" || rc=1; }
  unlock
  [ "$rc" -eq 0 ] || { printf 'unattended.sh: write failed\n' >&2; return 1; }
}

cmd_pending() {
  local p
  p=$(pending_json "$(q_file)") && [ -n "$p" ] ||
    { printf 'unattended.sh: cannot read the questions file\n' >&2; return 1; }
  printf '%s' "$p" | "$JQ" -r 'length'
}

# One repo's file: list the questions not yet listed (with --mark, record them as listed).
# LABEL, when non-empty, prefixes the header so a multi-repo list says whose questions they are.
digest_file() { # FILE MARK LABEL
  local f="$1" mark="$2" label="$3" p count last out
  [ -f "$f" ] || return 0
  # Hold the lock from read to watermark, so two sessions answering the same
  # prompt cannot both list the same questions.
  if [ "$mark" -eq 1 ]; then
    lock "$f" || { printf 'unattended.sh: questions file is locked\n' >&2; return 1; }
  fi
  # An unreadable file is an error, never "nothing to list".
  p=$(pending_json "$f") && [ -n "$p" ] ||
    { unlock; printf 'unattended.sh: cannot read the questions file\n' >&2; return 1; }
  count=$(printf '%s' "$p" | "$JQ" -r 'length')
  [ "${count:-0}" -gt 0 ] || { unlock; return 0; }
  out=$(printf '%s' "$p" | "$JQ" -r 'to_entries[] | .value as $q
    | "\(.key + 1). \($q.id): \($q.question)"
      + "\n   Recommended: \($q.recommended // "none given")"
      + (if ($q.options | length) > 0 then " (options: \($q.options | join(" | ")))" else "" end)
      + "\n   Meanwhile: \($q.did // "not recorded; see the thread")"') || out=""
  # Nothing is marked listed unless the list was rendered, persisted (when delivery can be verified)
  # and written.
  local text src=2
  text=$(printf '%sQuestions recorded while you were away (%s):\n%s' "${label:+[$label] }" "$count" "$out") || text=""
  if [ -z "$out" ] || [ -z "$text" ]; then
    unlock; printf 'unattended.sh: could not render the list\n' >&2; return 1
  fi
  if [ "$mark" -eq 1 ]; then
    stage_record "$label" "$text"; src=$?
    if [ "$src" -eq 1 ]; then
      unlock; printf 'unattended.sh: could not persist the list; nothing marked as listed\n' >&2; return 1
    fi
  fi
  if ! printf '%s\n' "$text"; then
    unlock; printf 'unattended.sh: could not render the list\n' >&2; return 1
  fi
  if [ "$mark" -eq 1 ]; then
    local json
    last=$(printf '%s' "$p" | "$JQ" -r '[.[].id | ltrimstr("U-") | tonumber? // 0] | max') &&
      json=$("$JQ" -cn --argjson t "$last" --argjson at "$(now)" '{type: "listed", through: $t, at: $at}') &&
      append "$f" "$json" ||
      { unlock; printf 'unattended.sh: could not mark the list as shown\n' >&2; return 1; }
    unlock
  fi
}

cmd_digest() {
  local mark=0 all=0 rc=0 f key
  while [ $# -gt 0 ]; do
    case "$1" in
      --mark) mark=1; shift ;;
      --all) all=1; shift ;;
      *) die_usage "unknown argument to digest: $1" ;;
    esac
  done
  if [ "$all" -eq 1 ]; then
    [ -d "$Q_DIR" ] || return 0
    for f in "$Q_DIR"/*.jsonl; do
      [ -f "$f" ] || continue
      key=$(basename "$f" .jsonl)
      key="${key/__//}"
      digest_file "$f" "$mark" "$key" || rc=1
    done
    return "$rc"
  fi
  digest_file "$(q_file)" "$mark" ""
}

# --- main ---------------------------------------------------------------------
[ $# -gt 0 ] || { usage; exit 2; }
sub="$1"; shift
case "$sub" in -h|--help|help) usage; exit 0 ;; esac
need_jq

# Global --cwd / --repo, accepted anywhere after the subcommand.
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
  on) cmd_on "$@" ;;
  off) cmd_off "$@" ;;
  status) cmd_status ;;
  is-active) is_active ;;
  window-ended) window_ended ;;
  record) cmd_record "$@" ;;
  update) cmd_update "$@" ;;
  pending) cmd_pending ;;
  digest) cmd_digest "$@" ;;
  settle) cmd_settle "$@" ;;
  undelivered) cmd_undelivered "$@" ;;
  *) die_usage "unknown subcommand: $sub" ;;
esac
