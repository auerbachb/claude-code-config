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
#   unattended.sh on [--for <N>h|<N>m | --until-epoch <E>]   (default --for 12h)
#   unattended.sh off [--cwd DIR | --repo KEY]   switch off, then print and mark the digest
#   unattended.sh status                         one line: `active until ...` or `inactive`
#   unattended.sh is-active                      exit 0 active, 1 not (no output)
#   unattended.sh window-ended                   exit 0 when a declared window has ended, else 1
#   unattended.sh record --question TEXT [--recommended TEXT] [--options 'A|B|C']
#                        [--did TEXT] [--session ID] [--source agent|hook] [--cwd DIR | --repo KEY]
#                                                prints the new id, U-<n>
#   unattended.sh update U-<n> --did TEXT [--cwd DIR | --repo KEY]
#   unattended.sh pending [--cwd DIR | --repo KEY]   count of questions not yet listed
#   unattended.sh digest [--mark] [--cwd DIR | --repo KEY]
#                                                the questions not yet listed, one per item;
#                                                --mark records them as listed
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
# EXIT CODES
#   0 ok; 1 is-active/window-ended false, or a write failed; 2 usage error.
#
# Bash 3.2 compatible (macOS /bin/bash).
set -uo pipefail

HERE=$(cd -P "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd) || HERE="."
SESSION_STATE_SH="${UNATTENDED_SESSION_STATE_SH:-$HERE/session-state.sh}"
STATE_FILE="${HOME}/.claude/session-state.json"
Q_DIR="${UNATTENDED_DIR:-${HOME}/.claude/unattended}"

JQ=$(command -v jq 2>/dev/null) || JQ=""
if [ -z "$JQ" ]; then
  for c in /opt/homebrew/bin/jq /usr/local/bin/jq /usr/bin/jq; do
    if [ -x "$c" ]; then JQ="$c"; break; fi
  done
fi

usage() { sed -n '2,46p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }
die_usage() { printf 'unattended.sh: %s\n' "$1" >&2; exit 2; }
need_jq() { [ -n "$JQ" ] || { printf 'unattended.sh: jq not found\n' >&2; exit 1; }; }

now() { date +%s; }

# The `.unattended` object, or null.
read_flag() {
  if [ ! -f "$STATE_FILE" ] || [ -z "$JQ" ]; then printf 'null\n'; return 0; fi
  "$JQ" -c '.unattended // null' "$STATE_FILE" 2>/dev/null || printf 'null\n'
}

is_active() {
  local f n
  f=$(read_flag); n=$(now)
  [ "$(printf '%s' "$f" | "$JQ" -r --argjson n "$n" '
    if type == "object" and .active == true
       and ((.until_epoch | type) != "number" or .until_epoch > $n)
    then "yes" else "no" end' 2>/dev/null)" = yes ]
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

# --- subcommands ------------------------------------------------------------
cmd_on() {
  local until="" dur="12h" n
  while [ $# -gt 0 ]; do
    case "$1" in
      --for) [ $# -ge 2 ] || die_usage "--for needs a value"; dur="$2"; shift 2 ;;
      --until-epoch) [ $# -ge 2 ] || die_usage "--until-epoch needs a value"; until="$2"; shift 2 ;;
      *) die_usage "unknown argument to on: $1" ;;
    esac
  done
  n=$(now)
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
  printf 'window-end watch (persistent Monitor): until [ "$(date +%%s)" -ge %s ]; do sleep 60; done; echo "unattended window ended: run unattended.sh digest --mark and list the questions"\n' "$until"
}

cmd_off() {
  "$SESSION_STATE_SH" --set ".unattended.active=false" >/dev/null || { printf 'unattended.sh: state write failed\n' >&2; return 1; }
  printf 'unattended: off\n'
  cmd_digest --mark
}

cmd_status() {
  local f u
  if is_active; then
    f=$(read_flag); u=$(printf '%s' "$f" | "$JQ" -r '.until_epoch // empty')
    if [ -n "$u" ]; then printf 'active until %s\n' "$(fmt_time "$u")"; else printf 'active\n'; fi
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

cmd_digest() {
  local mark=0 f p count last
  while [ $# -gt 0 ]; do
    case "$1" in
      --mark) mark=1; shift ;;
      *) die_usage "unknown argument to digest: $1" ;;
    esac
  done
  f=$(q_file)
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
  local out
  out=$(printf '%s' "$p" | "$JQ" -r 'to_entries[] | .value as $q
    | "\(.key + 1). \($q.id): \($q.question)"
      + "\n   Recommended: \($q.recommended // "none given")"
      + (if ($q.options | length) > 0 then " (options: \($q.options | join(" | ")))" else "" end)
      + "\n   Meanwhile: \($q.did // "not recorded; see the thread")"') || out=""
  # Nothing is marked listed unless the list was rendered and written.
  if [ -z "$out" ] || ! printf 'Questions recorded while you were away (%s):\n%s\n' "$count" "$out"; then
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
  *) die_usage "unknown subcommand: $sub" ;;
esac
