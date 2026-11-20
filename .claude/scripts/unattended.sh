#!/usr/bin/env bash
# unattended.sh — the operator-away switch and the questions recorded while he is away.
# catalog: scheduling-monitoring — Unattended mode: declare the operator away, record questions instead of opening menus, list them until he answers or dismisses each
#
# PURPOSE (issue #2283, issue #2352)
#   While the operator is away, an agent that opens a menu (AskUserQuestion)
#   or waits on him stalls the whole night. Unattended mode is one global flag
#   in ~/.claude/session-state.json (`.unattended`) — the operator is one
#   person, so a declaration made in one repo covers every session — plus one
#   append-only questions file per repo. Agents record a question here, take
#   the recommended option where it is reversible, park only the step that is
#   not, and keep working. A saved question is listed on every return and
#   every digest until it is ANSWERED or DISMISSED: listing alone never hides
#   it, so no kill, crash or dropped hook output can lose one.
#   Contract and rationale: .claude/reference/unattended-mode.md.
#
# USAGE
#   unattended.sh on [--for <N>h|<N>m | --until-epoch <E> | --open-ended]   (default --for 12h)
#                                                --open-ended: no window end (until `off`); issue #2293
#   unattended.sh off [--cwd DIR | --repo KEY]   switch off, then print the digest (nothing is marked)
#   unattended.sh status                         one line: `active until ...` or `inactive`
#   unattended.sh is-active                      exit 0 away handling applies, 1 not (no output). A window
#                                                that ran out stays active until the operator speaks
#                                                (presence.sh return) or `off`; an at-computer presence
#                                                window that ran out counts too (issue #2294)
#   unattended.sh window-ended                   exit 0 when a declared window has ended, else 1
#   unattended.sh record --question TEXT --context TEXT [--recommended TEXT] [--options 'A|B|C']
#                        [--did TEXT] [--session ID] [--source agent|hook] [--cwd DIR | --repo KEY]
#                                                prints the new id, U-<n>. --context (issue #2592) is the
#                                                plain-language background a person who has forgotten the
#                                                thread needs to answer: what the PR/issue/change is, why
#                                                it matters, what each option means. Required for
#                                                --source agent (at least 8 words; exit 2 otherwise);
#                                                a hook-captured menu has none until the agent adds it
#                                                with `update`. Writing guide:
#                                                .claude/reference/unattended-mode.md §Writing a question
#   unattended.sh update U-<n> (--did TEXT | --context TEXT)... [--cwd DIR | --repo KEY]
#   unattended.sh answer U-<n> --answer TEXT [--by operator|thread] [--session ID] [--cwd DIR | --repo KEY]
#                                                the operator answered it (in chat or at his return): only
#                                                this, or `dismiss`, removes a question from the lists
#   unattended.sh dismiss U-<n> [U-<m> ...] [--reason TEXT] [--by operator|thread] [--session ID]
#                        [--cwd DIR | --repo KEY]    the operator dropped them without answering; several ids
#                                                in one act. Both commands validate every id first
#                                                (strict U-<digits>, exists, not already resolved) and
#                                                write nothing when any is bad (exit 1)
#   unattended.sh pending [--cwd DIR | --repo KEY]   count of UNRESOLVED questions (not answered, not dismissed)
#   unattended.sh digest [--cwd DIR | --repo KEY]    every unresolved question, one per item. A pure read:
#                                                it takes no lock and appends nothing. `--mark` is accepted
#                                                and does nothing (kept for callers that still pass it)
#   unattended.sh digest --all                   the same for EVERY repo's file, each block labelled with
#                                                its repo key (the operator is one person and may come
#                                                back in any thread; issue #2294)
#   unattended.sh digest --session ID --shown-file PATH       (hooks) questions this session already saw in
#                                                full during the current return are one summary line with
#                                                the count and every id; the ids rendered in full are
#                                                written to PATH, to be recorded AFTER the list was emitted
#   unattended.sh seen --session ID --from PATH  (hooks) record the ids PATH names as shown in full to ID
#   unattended.sh list [--all]                   EVERY recorded question regardless of what was shown, with
#                                                its status (open | answered | dismissed); --all spans repos
#   unattended.sh list [--all] --json            the same as ONE JSON array, each question with its `repo` key
#                                                ([] when none); an unreadable file exits 1, printing nothing
#   unattended.sh --help
#
# STATE
#   Flag:       ~/.claude/session-state.json `.unattended` = {active, since_epoch, until_epoch}
#               (written only through session-state.sh; read directly with jq,
#               because hooks run on every prompt and session-state.sh takes ~1 s)
#   Questions:  ${UNATTENDED_DIR:-~/.claude/unattended}/<owner>__<repo>.jsonl, append-only:
#               {"type":"question","id":"U-1",...} | {"type":"update","id":"U-1","did":...}
#               | {"type":"answered","id":"U-1","answer":...,"by":...}
#               | {"type":"dismissed","id":"U-1","reason":...,"by":...}
#               Old {"type":"listed","through":N} lines (written before issue #2352) are ignored.
#   Shown:      ${UNATTENDED_DIR:-~/.claude/unattended}/seen/<file key>/<session>.json = {key, ids}: the
#               return key (`.unattended.since_epoch`, "none" when absent; each away arming writes a new
#               one) and the ids this session was shown in full. Written by `seen` only, after a hook
#               emitted its list; it can only shorten a repeat, never hide a question. No valid session
#               id: no record, always the full list.
#   The repo key comes from session-state.sh --repo-key run in --cwd (default: the
#   current directory), or --repo.
#
# EXIT CODES
#   0 ok; 1 is-active/window-ended false, or a write failed or an id was refused; 2 usage error.
#
# Bash 3.2 compatible (macOS /bin/bash).
set -uo pipefail

HERE=$(cd -P "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd) || HERE="."
SESSION_STATE_SH="${UNATTENDED_SESSION_STATE_SH:-$HERE/session-state.sh}"
STATE_FILE="${HOME}/.claude/session-state.json"
Q_DIR="${UNATTENDED_DIR:-${HOME}/.claude/unattended}"
PRESENCE_SH="${UNATTENDED_PRESENCE_SH:-$HERE/presence.sh}"
LIB_DIR="$HERE/lib"
SELF="$HERE/$(basename "${BASH_SOURCE[0]}")"

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
# status|is-away|expire|return|probe read as well (see its truth table). It must also see the SAME
# inputs: presence.sh reconciles a closing window's end against /leave-by before deciding, so when
# presence.sh is available this asks `presence.sh is-away` (which does that) rather than evaluating
# the decision on unreconciled records. Fallback with no presence.sh: the decision alone. In short:
# the newer of the unattended flag and the presence declaration governs; when neither is clearly newer
# the answer is away; an away window that ran out stays away handling until the operator speaks
# (presence.sh return) or `off`; an at-computer window that ran out counts too.
decide_local() { # prints yes|no
  [ -f "$STATE_FILE" ] || { printf 'no\n'; return 0; }
  "$JQ" -L "$LIB_DIR" -r --argjson n "$(now)" 'include "presence-decision";
    (.presence | if type == "object" then . else {} end) as $p
    | (.unattended | if type == "object" then . else {} end) as $u
    | if decide($p; $u; $n).away then "yes" else "no" end' "$STATE_FILE" 2>/dev/null || printf 'no\n'
}
is_active() {
  [ -f "$STATE_FILE" ] || return 1
  if [ -x "$PRESENCE_SH" ]; then
    "$PRESENCE_SH" is-away >/dev/null 2>&1
  else
    [ "$(decide_local)" = yes ]
  fi
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

# mkdir lock around every write: id allocation, updates, answers and dismissals.
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


# The question model (issue #2352). Every question with its latest `did`, its status (open |
# answered | dismissed) and what resolved it. Old `listed` watermarks are ignored on purpose: a
# question is hidden only by an explicit `answered` or `dismissed` record. Invalid lines and
# question objects without a string id are skipped, so one malformed record hides no other.
all_json() { # FILE
  [ -f "$1" ] || { printf '[]\n'; return 0; }
  "$JQ" -R -s -c '
    [split("\n")[] | select(length > 0) | (fromjson? // empty) | select(type == "object")] as $r
    | [$r[] | select(.type == "update")] as $u
    | [$r[] | select(.type == "answered" or .type == "dismissed")] as $d
    | [$r[] | select(.type == "question" and (.id | type) == "string")
        | . as $q
        | ([$d[] | select(.id == $q.id)] | last) as $res
        | .did = (([$u[] | select(.id == $q.id and .did != null) | .did] | last) // .did)
        | .context = (([$u[] | select(.id == $q.id and .context != null) | .context] | last) // .context)
        | .status = (if $res == null then "open" elif $res.type == "answered" then "answered" else "dismissed" end)
        | .resolution = (if $res == null then null else ($res.answer // $res.reason // null) end)]' "$1" 2>/dev/null
}

# The questions nobody has answered or dismissed: what every digest and `pending` shows.
unresolved_json() { # FILE
  local a
  a=$(all_json "$1") && [ -n "$a" ] || return 1
  printf '%s' "$a" | "$JQ" -c '[.[] | select(.status == "open")]' 2>/dev/null
}

# --- what a session was already shown (see STATE above) ---------------------------------------------
# A session id is usable only when it is a plain token: it becomes a file name.
valid_sid() { # ID
  case "${1-}" in ''|*[!A-Za-z0-9._-]*) return 1 ;; esac
  [ "${#1}" -le 128 ]
}
# The return key: each away arming writes a new `.unattended.since_epoch`, so a new return lists in
# full again. "none" when it was never written.
return_key() {
  local k=""
  [ -f "$STATE_FILE" ] && k=$("$JQ" -r '(.unattended.since_epoch // "none") | tostring' "$STATE_FILE" 2>/dev/null) || true
  printf '%s\n' "${k:-none}"
}
seen_path() { printf '%s/seen/%s/%s.json\n' "$Q_DIR" "$1" "$2"; } # FILEKEY SID
# The ids this session was shown in full under return key KEY; [] on any doubt (a missing, unreadable
# or other-return record), which only means a full list.
seen_ids() { # FILEKEY SID KEY
  local p out
  p=$(seen_path "$1" "$2")
  [ -f "$p" ] || { printf '[]\n'; return 0; }
  out=$("$JQ" -c --arg k "$3" 'if type == "object" and .key == $k and (.ids | type) == "array"
    then [.ids[] | strings] else [] end' "$p" 2>/dev/null) && [ -n "$out" ] || out='[]'
  printf '%s\n' "$out"
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
    # (nothing is marked: listing never hides a question), and only then clear the window.
    cmd_digest --all
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
    cmd_digest
  fi
}

cmd_status() {
  local u
  if is_active; then
    # The governing window's own end is the deadline to show (an at-computer window that lapsed has
    # its presence end, not whatever the unattended flag last recorded).
    if [ -x "$PRESENCE_SH" ]; then
      u=$("$PRESENCE_SH" status --json 2>/dev/null | "$JQ" -r '.until_epoch // empty' 2>/dev/null) || u=""
    else
      u=$("$JQ" -L "$LIB_DIR" -r --argjson n "$(now)" 'include "presence-decision";
        (.presence | if type == "object" then . else {} end) as $p
        | (.unattended | if type == "object" then . else {} end) as $u
        | decide($p; $u; $n) | (.until_epoch // empty)' "$STATE_FILE" 2>/dev/null)
    fi
    if [ -z "$u" ]; then printf 'active\n'
    elif [ "$u" -gt "$(now)" ]; then printf 'active until %s\n' "$(fmt_time "$u")"
    else printf 'active (window ended %s; until you send a message)\n' "$(fmt_time "$u")"; fi
  else
    printf 'inactive\n'
  fi
}

# Background worth reading: at least 8 words once URLs and PR/issue/U- references are taken out (issue #2592).
context_ok() { # TEXT
  # Count whitespace-separated tokens that are words. URLs (`://`, `www.`) and anything holding
  # `#` (#N, owner/repo#N) are references. From every other token ASCII punctuation and digits are
  # removed; an empty remainder (`-`, `123`) or a bare reference label (pr/issue/pull/u/d, so `U-3`)
  # does not count. Non-ASCII bytes are kept, so words in any script count (`2FA`, `and/or` too).
  # The awk program is kept in a variable so none of its quoting sits inside the $( ).
  local n prog
  prog='BEGIN { punct = "[!-@[-" sprintf("%c", 96) "{-~]" }
    { for (i = 1; i <= NF; i++) {
        t = $i
        if (t ~ /:\/\// || t ~ /^www\./ || index(t, sprintf("%c", 35))) continue
        gsub(punct, "", t)
        if (t == "" || t ~ /^(pr|prs|issue|issues|pull|u|d)$/) continue
        n++ } }
    END { print n + 0 }'
  n=$(printf '%s' "$1" | LC_ALL=C tr '[:upper:]' '[:lower:]' | LC_ALL=C awk "$prog")
  [ "${n:-0}" -ge 8 ]
}

cmd_record() {
  local q="" ctx="" rec="" opts="" did="" sid="" src="agent" f n id rc
  while [ $# -gt 0 ]; do
    case "$1" in
      --question) q="${2-}"; shift 2 || die_usage "--question needs a value" ;;
      --recommended) rec="${2-}"; shift 2 || die_usage "--recommended needs a value" ;;
      --options) opts="${2-}"; shift 2 || die_usage "--options needs a value" ;;
      --did) did="${2-}"; shift 2 || die_usage "--did needs a value" ;;
      --context) ctx="${2-}"; shift 2 || die_usage "--context needs a value" ;;
      --session) sid="${2-}"; shift 2 || die_usage "--session needs a value" ;;
      --source) src="${2-}"; shift 2 || die_usage "--source needs a value" ;;
      *) die_usage "unknown argument to record: $1" ;;
    esac
  done
  [ -n "$q" ] || die_usage "record needs --question"
  # Issue #2592: an agent writes the background with the question; only a hook-captured menu may
  # arrive without it (the agent adds it with `update --context`).
  if [ "$src" != hook ]; then
    [ -n "$ctx" ] || die_usage "record needs --context: plain-language background for someone who has forgotten this thread (.claude/reference/unattended-mode.md §Writing a question)"
    context_ok "$ctx" || die_usage "--context is too thin: at least 8 words of plain background, not just an id or a ref"
  fi
  f=$(q_file)
  mkdir -p "$Q_DIR" 2>/dev/null || { printf 'unattended.sh: cannot create %s\n' "$Q_DIR" >&2; return 1; }
  lock "$f" || { printf 'unattended.sh: questions file is locked\n' >&2; return 1; }
  n=0
  [ -f "$f" ] && n=$(grep -c '"type":"question"' "$f" 2>/dev/null || true)
  case "$n" in ''|*[!0-9]*) n=0 ;; esac
  id="U-$((n + 1))"
  rc=0
  local json
  json=$("$JQ" -cn --arg id "$id" --arg q "$q" --arg c "$ctx" --arg r "$rec" --arg o "$opts" --arg d "$did" \
    --arg s "$sid" --arg src "$src" --argjson at "$(now)" '
    {type: "question", id: $id, at: $at, question: $q,
     context: (if $c == "" then null else $c end),
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
  local id="${1-}" did="" ctx=""
  [ -n "$id" ] || die_usage "update needs an id"
  shift
  case "$id" in U-[0-9]*) ;; *) die_usage "bad id: $id" ;; esac
  while [ $# -gt 0 ]; do
    case "$1" in
      --did) did="${2-}"; shift 2 || die_usage "--did needs a value" ;;
      --context) ctx="${2-}"; shift 2 || die_usage "--context needs a value" ;;
      *) die_usage "unknown argument to update: $1" ;;
    esac
  done
  [ -n "$did" ] || [ -n "$ctx" ] || die_usage "update needs --did or --context"
  [ -z "$ctx" ] || context_ok "$ctx" || die_usage "--context is too thin: at least 8 words of plain background, not just an id or a ref"
  local f rc=0
  f=$(q_file)
  mkdir -p "$Q_DIR" 2>/dev/null || { printf 'unattended.sh: cannot create %s\n' "$Q_DIR" >&2; return 1; }
  lock "$f" || { printf 'unattended.sh: questions file is locked\n' >&2; return 1; }
  local json
  json=$("$JQ" -cn --arg id "$id" --arg d "$did" --arg c "$ctx" --argjson at "$(now)" \
    '{type: "update", id: $id, at: $at}
     + (if $d == "" then {} else {did: $d} end) + (if $c == "" then {} else {context: $c} end)') || rc=1
  [ "$rc" -eq 0 ] && { append "$f" "$json" || rc=1; }
  unlock
  [ "$rc" -eq 0 ] || { printf 'unattended.sh: write failed\n' >&2; return 1; }
}

cmd_pending() {
  local p
  p=$(unresolved_json "$(q_file)") && [ -n "$p" ] ||
    { printf 'unattended.sh: cannot read the questions file\n' >&2; return 1; }
  printf '%s' "$p" | "$JQ" -r 'length'
}

# One repo's file: list its unresolved questions. A PURE READ: no lock, nothing appended, so a
# process that dies at any point loses nothing (issue #2352). LABEL, when non-empty, prefixes the
# header so a multi-repo list says whose questions they are. With a usable SID, the questions that
# session was already shown in full during this return become one summary line; SHOWN (a path, or
# empty) receives the ids rendered in full, for `seen` to record once the list was emitted.
digest_file() { # FILE LABEL SID SHOWN
  local f="$1" label="$2" sid="$3" shown="$4" p count fkey rkey seenj split nnew nold oldids out text sum rk noun
  [ -f "$f" ] || return 0
  # An unreadable file is an error, never "nothing to list".
  p=$(unresolved_json "$f") && [ -n "$p" ] ||
    { printf 'unattended.sh: cannot read the questions file\n' >&2; return 1; }
  count=$(printf '%s' "$p" | "$JQ" -r 'length')
  [ "${count:-0}" -gt 0 ] || return 0
  fkey=$(basename "$f" .jsonl)
  seenj='[]'; rkey=""
  if valid_sid "$sid"; then rkey=$(return_key); seenj=$(seen_ids "$fkey" "$sid" "$rkey"); else sid=""; fi
  split=$(printf '%s' "$p" | "$JQ" -c --argjson s "$seenj" '
    {new: [.[] | select(.id as $i | any($s[]; . == $i) | not)],
     old: [.[] | select(.id as $i | any($s[]; . == $i)) | .id]}') || split=""
  [ -n "$split" ] || { printf 'unattended.sh: could not render the list\n' >&2; return 1; }
  nnew=$(printf '%s' "$split" | "$JQ" -r '.new | length')
  nold=$(printf '%s' "$split" | "$JQ" -r '.old | length')
  text=""
  if [ "$nnew" -gt 0 ]; then
    out=$(printf '%s' "$split" | "$JQ" -r '.new | to_entries[] | .value as $q
      | "\(.key + 1). \($q.id): \($q.question)"
        + "\n   Context: \($q.context // "missing: recorded without background (issue #2592)")"
        + "\n   Recommended: \($q.recommended // "none given")"
        + (if ($q.options | length) > 0 then " (options: \($q.options | join(" | ")))" else "" end)
        + "\n   Meanwhile: \($q.did // "not recorded; see the thread")"') || out=""
    [ -n "$out" ] || { printf 'unattended.sh: could not render the list\n' >&2; return 1; }
    text=$(printf '%sQuestions recorded while you were away (%s):\n%s' "${label:+[$label] }" "$nnew" "$out")
  fi
  if [ "$nold" -gt 0 ]; then
    oldids=$(printf '%s' "$split" | "$JQ" -r '.old | join(", ")')
    rk="${label:-$(repo_key)}"
    if [ "$nold" -eq 1 ]; then noun="saved question"; else noun="saved questions"; fi
    sum=$(printf '%s%s %s still unanswered (%s), listed in full earlier this session; run %s digest --repo %s for the full text.' \
      "${label:+[$label] }" "$nold" "$noun" "$oldids" "$(printf '%q' "$SELF")" "$(printf '%q' "$rk")")
    text="${text:+$text

}$sum"
  fi
  printf '%s\n' "$text" || { printf 'unattended.sh: could not render the list\n' >&2; return 1; }
  # The ids shown in full, for `seen`. Best effort: a failure only means a repeat next time.
  if [ -n "$shown" ] && [ -n "$sid" ] && [ "$nnew" -gt 0 ]; then
    printf '%s' "$split" | "$JQ" -c --arg f "$fkey" --arg k "$rkey" '{file: $f, key: $k, ids: [.new[].id]}' >>"$shown" 2>/dev/null || true
  fi
  return 0
}

cmd_digest() {
  local all=0 rc=0 f key sid="" shown=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --mark) shift ;;   # deprecated no-op (issue #2352): listing never marks anything
      --all) all=1; shift ;;
      --session) [ $# -ge 2 ] || die_usage "--session needs a value"; sid="$2"; shift 2 ;;
      --shown-file) [ $# -ge 2 ] || die_usage "--shown-file needs a value"; shown="$2"; shift 2 ;;
      *) die_usage "unknown argument to digest: $1" ;;
    esac
  done
  [ -z "$shown" ] || : >"$shown" 2>/dev/null || shown=""
  if [ "$all" -eq 1 ]; then
    [ -d "$Q_DIR" ] || return 0
    for f in "$Q_DIR"/*.jsonl; do
      [ -f "$f" ] || continue
      key=$(basename "$f" .jsonl)
      key="${key/__//}"
      digest_file "$f" "$key" "$sid" "$shown" || rc=1
    done
    return "$rc"
  fi
  digest_file "$(q_file)" "" "$sid" "$shown"
}

# Record, after a hook emitted its list, which ids this session was shown in full.
cmd_seen() {
  local sid="" from="" line fk rk ids old dir tmp rc=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --session) [ $# -ge 2 ] || die_usage "--session needs a value"; sid="$2"; shift 2 ;;
      --from) [ $# -ge 2 ] || die_usage "--from needs a value"; from="$2"; shift 2 ;;
      *) die_usage "unknown argument to seen: $1" ;;
    esac
  done
  [ -n "$from" ] || die_usage "seen needs --from"
  valid_sid "$sid" || return 0   # no usable session id: nothing is recorded, every list stays full
  [ -f "$from" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    [ -n "$line" ] || continue
    fk=$(printf '%s' "$line" | "$JQ" -r '.file // ""' 2>/dev/null) || fk=""
    rk=$(printf '%s' "$line" | "$JQ" -r '(.key // "") | tostring' 2>/dev/null) || rk=""
    ids=$(printf '%s' "$line" | "$JQ" -c '[(.ids // [])[] | strings]' 2>/dev/null) || ids=""
    case "$fk" in ''|*[!a-z0-9._-]*) rc=1; continue ;; esac
    [ -n "$rk" ] && [ -n "$ids" ] || { rc=1; continue; }
    old=$(seen_ids "$fk" "$sid" "$rk")
    dir="$Q_DIR/seen/$fk"
    mkdir -p "$dir" 2>/dev/null || { rc=1; continue; }
    tmp="$dir/.$sid.$$.tmp"
    "$JQ" -cn --argjson a "$old" --argjson b "$ids" --arg k "$rk" '{key: $k, ids: (($a + $b) | unique)}' >"$tmp" 2>/dev/null &&
      [ -s "$tmp" ] && mv "$tmp" "$dir/$sid.json" || { rm -f "$tmp" 2>/dev/null; rc=1; }
  done <"$from"
  return "$rc"
}

# answer U-n --answer TEXT / dismiss U-n [U-m ...] [--reason TEXT]: the explicit act that removes a
# question from the lists. Every id is validated under the lock before anything is written.
cmd_resolve() { # KIND (answered|dismissed) ARGS...
  local kind="$1" text="" by="operator" sid="" id ids f a st json block="" seenids="" rc=0 n
  ids=()
  shift
  while [ $# -gt 0 ]; do
    case "$1" in
      --answer) [ "$kind" = answered ] || die_usage "unknown argument to dismiss: $1"; [ $# -ge 2 ] || die_usage "--answer needs a value"; text="$2"; shift 2 ;;
      --reason) [ "$kind" = dismissed ] || die_usage "unknown argument to answer: $1"; [ $# -ge 2 ] || die_usage "--reason needs a value"; text="$2"; shift 2 ;;
      --by) [ $# -ge 2 ] || die_usage "--by needs a value"; by="$2"; shift 2 ;;
      --session) [ $# -ge 2 ] || die_usage "--session needs a value"; sid="$2"; shift 2 ;;
      -*) die_usage "unknown argument: $1" ;;
      *) ids+=("$1"); shift ;;
    esac
  done
  case "$by" in operator|thread) ;; *) die_usage "--by takes operator or thread" ;; esac
  if [ "$kind" = answered ]; then
    [ "${#ids[@]}" -eq 1 ] || die_usage "answer takes exactly one id"
    [ -n "$text" ] || die_usage "answer needs --answer"
  else
    [ "${#ids[@]}" -ge 1 ] || die_usage "dismiss needs at least one id"
  fi
  for id in "${ids[@]}"; do
    case "$id" in U-*) n="${id#U-}" ;; *) die_usage "bad id: $id" ;; esac
    case "$n" in ''|*[!0-9]*) die_usage "bad id: $id" ;; esac
  done
  f=$(q_file)
  mkdir -p "$Q_DIR" 2>/dev/null || { printf 'unattended.sh: cannot create %s\n' "$Q_DIR" >&2; return 1; }
  lock "$f" || { printf 'unattended.sh: questions file is locked\n' >&2; return 1; }
  a=$(all_json "$f") && [ -n "$a" ] || { unlock; printf 'unattended.sh: cannot read the questions file\n' >&2; return 1; }
  for id in "${ids[@]}"; do
    case " $seenids " in *" $id "*) continue ;; esac   # the same id twice is one act
    seenids="$seenids $id"
    st=$(printf '%s' "$a" | "$JQ" -r --arg id "$id" '[.[] | select(.id == $id) | .status] | first // "unknown"') || st=""
    case "$st" in
      open) ;;
      unknown) unlock; printf 'unattended.sh: %s is not a recorded question; nothing written\n' "$id" >&2; return 1 ;;
      *) unlock; printf 'unattended.sh: %s is already %s; nothing written\n' "$id" "$st" >&2; return 1 ;;
    esac
    if [ "$kind" = answered ]; then
      json=$("$JQ" -cn --arg id "$id" --arg t "$text" --arg by "$by" --arg s "$sid" --argjson at "$(now)" \
        '{type: "answered", id: $id, at: $at, answer: $t, by: $by, session: (if $s == "" then null else $s end)}') || json=""
    else
      json=$("$JQ" -cn --arg id "$id" --arg t "$text" --arg by "$by" --arg s "$sid" --argjson at "$(now)" \
        '{type: "dismissed", id: $id, at: $at, reason: (if $t == "" then null else $t end), by: $by,
          session: (if $s == "" then null else $s end)}') || json=""
    fi
    [ -n "$json" ] || { unlock; printf 'unattended.sh: write failed\n' >&2; return 1; }
    block="${block:+$block
}$json"
  done
  append "$f" "$block" || rc=1
  unlock
  [ "$rc" -eq 0 ] || { printf 'unattended.sh: write failed\n' >&2; return 1; }
  for id in $seenids; do printf '%s %s\n' "$id" "$kind"; done
}

# Every recorded question with its status, whatever was shown or resolved.
list_file() { # FILE LABEL
  local f="$1" label="$2" a n
  [ -f "$f" ] || return 0
  a=$(all_json "$f") && [ -n "$a" ] || { printf 'unattended.sh: cannot read the questions file\n' >&2; return 1; }
  n=$(printf '%s' "$a" | "$JQ" -r 'length')
  [ "${n:-0}" -gt 0 ] || return 0
  printf '%s' "$a" | "$JQ" -r --arg label "$label" '
    (if $label == "" then "" else "[\($label)] " end) as $p
    | "\($p)Recorded questions (\(length)):",
      (.[] | "\(.id) [\(.status)]: \(.question)"
        + "\n   Context: \(.context // "missing: recorded without background (issue #2592)")"
        + "\n   Recommended: \(.recommended // "none given")"
        + (if (.options | length) > 0 then " (options: \(.options | join(" | ")))" else "" end)
        + "\n   Meanwhile: \(.did // "not recorded; see the thread")"
        + (if .status == "answered" then "\n   Answer: \(.resolution // "")"
           elif .status == "dismissed" then "\n   Dismissed: \(.resolution // "no reason given")" else "" end))'
}

# --json (issue #2541, /back): one array over the chosen files, each question labelled with its repo key.
list_json() { # ALL
  local f key a acc='[]'
  if [ "$1" -eq 1 ]; then
    [ -d "$Q_DIR" ] || { printf '[]\n'; return 0; }
    [ -r "$Q_DIR" ] && [ -x "$Q_DIR" ] || { printf 'unattended.sh: cannot read %s\n' "$Q_DIR" >&2; return 1; }
    for f in "$Q_DIR"/*.jsonl; do
      [ -f "$f" ] || continue
      key=$(basename "$f" .jsonl); key="${key/__//}"
      a=$(all_json "$f") && [ -n "$a" ] || { printf 'unattended.sh: cannot read %s\n' "$f" >&2; return 1; }
      acc=$(printf '%s\n%s' "$acc" "$a" | "$JQ" -cs --arg k "$key" '.[0] + [.[1][] | . + {repo: $k}]') || return 1
    done
  else
    f=$(q_file); key=$(repo_key)
    a=$(all_json "$f") && [ -n "$a" ] || { printf 'unattended.sh: cannot read the questions file\n' >&2; return 1; }
    acc=$(printf '%s' "$a" | "$JQ" -c --arg k "$key" '[.[] | . + {repo: $k}]') || return 1
  fi
  printf '%s\n' "$acc"
}

cmd_list() {
  local all=0 json=0 rc=0 f key
  while [ $# -gt 0 ]; do
    case "$1" in
      --all) all=1; shift ;;
      --json) json=1; shift ;;
      *) die_usage "unknown argument to list: $1" ;;
    esac
  done
  if [ "$json" -eq 1 ]; then list_json "$all"; return; fi
  if [ "$all" -eq 1 ]; then
    [ -d "$Q_DIR" ] || return 0
    for f in "$Q_DIR"/*.jsonl; do
      [ -f "$f" ] || continue
      key=$(basename "$f" .jsonl)
      key="${key/__//}"
      list_file "$f" "$key" || rc=1
    done
    return "$rc"
  fi
  list_file "$(q_file)" ""
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
    # A value-taking flag carries its value through verbatim, so text such as an answer that starts
    # with --repo or --cwd is not read as a global option.
    --answer|--reason|--question|--context|--recommended|--options|--did|--session|--source|--by|--for|--from|--shown-file|--until-epoch)
      args+=("$1"); shift
      if [ $# -gt 0 ]; then args+=("$1"); shift; fi ;;
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
  answer) cmd_resolve answered "$@" ;;
  dismiss) cmd_resolve dismissed "$@" ;;
  seen) cmd_seen "$@" ;;
  list) cmd_list "$@" ;;
  *) die_usage "unknown subcommand: $sub" ;;
esac
