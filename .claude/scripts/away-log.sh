#!/usr/bin/env bash
# away-log.sh — what a thread would have said in chat while the operator was away, kept on disk for /back.
# catalog: scheduling-monitoring — Away log: while the operator is away a thread writes nothing to chat and appends each would-be message here; /back reads it
#
# PURPOSE (issue #2594)
#   While the operator is away (/afk, /pm --away, /presence) he reads none of the chat, so every
#   message a thread writes then is wasted output that also clogs the thread he comes back to.
#   Threads write nothing to chat while away and append each message they would have written here
#   instead; /back (back-report.sh) reads it back. Contract: .claude/reference/away-log.md.
#
# USAGE
#   away-log.sh append --kind KIND --text TEXT [--session ID] [--cwd DIR] [--now EPOCH]
#     KIND   blocker | decision | owner-task | merged | stopped | summary | note
#     TEXT   one line, at most 2000 bytes (newlines are folded to spaces); checked by desk/bin/lib/secrets.sh and
#            refused (exit 5) when it looks like a secret. Name a variable, never its value.
#     Prints the stored entry as one JSON line.
#   away-log.sh read [--since EPOCH] [--all] [--session ID] [--cwd DIR] [--json]
#     Entries at or after --since (default 0), oldest first. Default scope: this repo, and this
#     session when one is known; --all: every repo and session. Prints a JSON array (with or
#     without --json; the flag is accepted for symmetry with the other helpers).
#   away-log.sh path [--session ID] [--cwd DIR]
#     The file `append` writes for this repo and session.
#
#   --session  default $CLAUDE_CODE_SESSION_ID, then $CLAUDE_SESSION_ID, then "nosession"
#   --cwd      the thread's checkout (default: current directory); picks the repo key
#
# STORAGE
#   $AWAY_LOG_DIR (default ~/.claude/away-log)/<owner>__<repo>/<session>.jsonl, one object per
#   line: {at, at_iso, repo, session, kind, text}. Append-only; a line (text capped at 2000
#   bytes) is written with one printf in append mode, so concurrent appends do not interleave.
#
# EXIT CODES
#   0 ok; 1 jq not found or a write/read failed; 2 usage error; 5 text refused as a possible
#   secret; 7 secret checker (desk/bin/lib/secrets.sh) not found, write refused.
#
# Bash 3.2 compatible (macOS /bin/bash).
set -uo pipefail

KINDS="blocker decision owner-task merged stopped summary note"
EXIT_SECRET=5
EXIT_NO_CHECKER=7
MAX_BYTES=2000

usage() { sed -n '2,/^# Bash 3.2/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }
die() { local rc="$1"; shift; printf 'away-log.sh: %s\n' "$*" >&2; exit "$rc"; }

JQ=$(command -v jq 2>/dev/null) || JQ=""
if [ -z "$JQ" ]; then
  for c in /opt/homebrew/bin/jq /usr/local/bin/jq /usr/bin/jq; do
    if [ -x "$c" ]; then JQ="$c"; break; fi
  done
fi

resolve_self_dir() {
  local self="${BASH_SOURCE[0]}" dir
  while [ -L "$self" ]; do
    dir="$(cd "$(dirname "$self")" && pwd)"
    self="$(readlink "$self")"
    case "$self" in /*) ;; *) self="$dir/$self" ;; esac
  done
  cd "$(dirname "$self")" && pwd
}
HERE=$(resolve_self_dir) || HERE="."

[ $# -ge 1 ] || { usage >&2; exit 2; }
CMD="$1"; shift
case "$CMD" in -h|--help|help) usage; exit 0 ;; append|read|path) ;; *) die 2 "unknown command: $CMD" ;; esac

KIND="" TEXT="" HAVE_TEXT=0 SINCE=0 ALL=0 NOW=""
SID="${CLAUDE_CODE_SESSION_ID:-${CLAUDE_SESSION_ID:-}}" CWD="$PWD"
while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --kind) [ $# -ge 2 ] || die 2 "--kind needs a value"; KIND="$2"; shift 2 ;;
    --text) [ $# -ge 2 ] || die 2 "--text needs a value"; TEXT="$2"; HAVE_TEXT=1; shift 2 ;;
    --since) [ $# -ge 2 ] || die 2 "--since needs a value"; SINCE="$2"; shift 2 ;;
    --session) [ $# -ge 2 ] || die 2 "--session needs a value"; SID="$2"; shift 2 ;;
    --cwd) [ $# -ge 2 ] || die 2 "--cwd needs a value"; CWD="$2"; shift 2 ;;
    --now) [ $# -ge 2 ] || die 2 "--now needs a value"; NOW="$2"; shift 2 ;;
    --all) ALL=1; shift ;;
    --json) shift ;;
    *) die 2 "unknown argument: $1" ;;
  esac
done
case "$SINCE" in ''|*[!0-9]*) die 2 "--since takes an epoch" ;; esac
case "$NOW" in *[!0-9]*) die 2 "--now takes an epoch" ;; esac
[ -d "$CWD" ] || die 2 "--cwd is not a directory: $CWD"
[ -n "$JQ" ] || die 1 "jq not found"
case "$SID" in *[!A-Za-z0-9._-]*) SID="" ;; esac
SID_KEY="${SID:-nosession}"

ROOT="${AWAY_LOG_DIR:-${HOME:-}/.claude/away-log}"
[ -n "$ROOT" ] && [ "$ROOT" != "/.claude/away-log" ] || die 1 "no log directory (HOME unset and AWAY_LOG_DIR empty)"

# Repo key: session-state.sh's key when it resolves, else the checkout's toplevel.
REPO=""
if [ -x "$HERE/session-state.sh" ]; then
  REPO=$(cd "$CWD" 2>/dev/null && "$HERE/session-state.sh" --repo-key 2>/dev/null) || REPO=""
fi
if [ -z "$REPO" ] || [ "$REPO" = "_unknown" ]; then
  top=$(cd "$CWD" 2>/dev/null && git rev-parse --show-toplevel 2>/dev/null) || top=""
  REPO="_local/$(printf '%s' "${top:-$CWD}" | tr '/' '_')"
fi
REPO_DIR="$ROOT/$(printf '%s' "$REPO" | sed 's#/#__#g')"
FILE="$REPO_DIR/$SID_KEY.jsonl"

case "$CMD" in
  path)
    printf '%s\n' "$FILE"
    ;;
  append)
    [ -n "$KIND" ] || die 2 "append needs --kind"
    [ "$HAVE_TEXT" -eq 1 ] || die 2 "append needs --text"
    ok=0; for k in $KINDS; do [ "$k" = "$KIND" ] && ok=1; done
    [ "$ok" -eq 1 ] || die 2 "--kind must be one of: $KINDS"
    RAW="$TEXT"
    TEXT=$(printf '%s' "$TEXT" | tr '\r\n\t' '   ' | sed 's/  */ /g; s/^ //; s/ $//')
    [ -n "$TEXT" ] || die 2 "--text is empty"
    # Bounded so one printf append stays a single small write in append mode, which concurrent
    # writers do not interleave in practice, and the log stays one line per message.
    [ "$(printf '%s' "$TEXT" | LC_ALL=C wc -c | tr -d ' ')" -le "$MAX_BYTES" ] || die 2 "--text is over $MAX_BYTES bytes; log one line, link the detail"
    LIB=""
    for cand in "$HERE/../../desk/bin/lib/secrets.sh" \
                "${HOME:+$HOME/.claude/skills-worktree/desk/bin/lib/secrets.sh}"; do
      if [ -n "$cand" ] && [ -r "$cand" ]; then LIB="$cand"; break; fi
    done
    [ -n "$LIB" ] || die "$EXIT_NO_CHECKER" "secret checker desk/bin/lib/secrets.sh not found; refusing to write unchecked text"
    # shellcheck source=/dev/null
    . "$LIB"
    hq_die_secret() { die "$EXIT_SECRET" "$*"; }
    # Raw and folded: a key split across lines is checked whole as well as joined.
    hq_refuse_secret text "$RAW"
    hq_refuse_secret text "$TEXT"
    [ -n "$NOW" ] || NOW=$(date +%s)
    AT_ISO=$(date -u -r "$NOW" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date -u -d "@$NOW" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null)
    LINE=$("$JQ" -cn --argjson at "$NOW" --arg iso "$AT_ISO" --arg repo "$REPO" --arg s "$SID_KEY" \
      --arg k "$KIND" --arg t "$TEXT" '{at: $at, at_iso: $iso, repo: $repo, session: $s, kind: $k, text: $t}') \
      || die 1 "could not build the entry"
    mkdir -p "$REPO_DIR" 2>/dev/null || die 1 "cannot create $REPO_DIR"
    printf '%s\n' "$LINE" >>"$FILE" || die 1 "cannot append to $FILE"
    printf '%s\n' "$LINE"
    ;;
  read)
    if [ ! -e "$ROOT" ]; then printf '[]\n'; exit 0; fi
    # An existing directory we cannot traverse is unreadable, never "no entries".
    for d in "$ROOT" "$REPO_DIR"; do
      if [ -e "$d" ] && { [ ! -d "$d" ] || [ ! -r "$d" ] || [ ! -x "$d" ]; }; then die 1 "cannot read $d"; fi
    done
    if [ "$ALL" -eq 1 ]; then
      FILES=$(find "$ROOT" -mindepth 2 -maxdepth 2 -type f -name '*.jsonl' 2>/dev/null) || die 1 "cannot list $ROOT"
    elif [ -n "$SID" ]; then
      FILES=""; [ -f "$FILE" ] && FILES="$FILE"
    else
      FILES=""; [ -d "$REPO_DIR" ] && { FILES=$(find "$REPO_DIR" -mindepth 1 -maxdepth 1 -type f -name '*.jsonl' 2>/dev/null) || die 1 "cannot list $REPO_DIR"; }
    fi
    if [ -z "$FILES" ]; then printf '[]\n'; exit 0; fi
    # One bad line never hides the rest: lines that are not JSON objects are skipped.
    OUT=$(printf '%s\n' "$FILES" | while IFS= read -r f; do
            [ -r "$f" ] || { printf 'away-log.sh: cannot read %s\n' "$f" >&2; exit 1; }
            cat "$f"
          done | "$JQ" -R -s -c --argjson since "$SINCE" '
            [split("\n")[] | select(length > 0) | (try fromjson catch null)
             | select(type == "object" and (.at | type) == "number" and .at >= $since)]
            | sort_by(.at)') || die 1 "could not read the away log"
    printf '%s\n' "$OUT"
    ;;
esac
exit 0
