#!/usr/bin/env bash
# back-report.sh — everything /back shows the returning operator, gathered in one call as one JSON object.
# catalog: scheduling-monitoring — /back's data in one JSON object: open questions and Desk Decisions, open human tasks, and a digest of GitHub, stoppage and pipeline activity since the away declaration; an unreadable source is named, never read as empty
#
# PURPOSE (issue #2541)
#   Coming back from away used to mean pasting the same "what happened, what do you need from me"
#   message into every thread. /back (.claude/skills/back/SKILL.md) asks it once. This script does
#   all of its reading; the skill only presents. It starts nothing and dispatches nothing, and the
#   report writes nothing; the one write is --save-recovered (below), which /back runs for tasks it
#   found handed to the operator in its own thread but never saved. A source it cannot read is listed in `.unreadable` with the reason and its section is
#   null, so the skill can say "unavailable" instead of showing an empty list as if nothing waited.
#
# USAGE
#   back-report.sh [--all] [--session ID] [--since EPOCH] [--now EPOCH] [--cwd DIR]
#     --all      every thread and repo it can read. Default: this thread, meaning this repo's items
#                that this session asked or that carry no session, and GitHub activity in this repo
#     --session  this thread's session id (default $CLAUDE_CODE_SESSION_ID, then $CLAUDE_SESSION_ID);
#                with none, thread scope keeps every item of this repo
#     --since    start of the absence. Default: the stored away declaration (.unattended.since_epoch,
#                written by every away arming); with none stored, the last 24 hours
#     --now      pinned clock (tests). Default: now
#     --cwd      the thread's checkout. Default: the current directory
#
#   back-report.sh --save-recovered FILE [--session ID] [--now EPOCH] [--cwd DIR]
#     FILE is a JSON array of {what, why}: tasks this thread handed to the operator that were never
#     saved. Each is saved with `owner-task.sh add --what W --why Y --source "recovered by /back from
#     this thread (session ID, YYYY-MM-DD)"`; the task contract has no recovered field, so the source
#     carries the marker. A task whose `what` (case and spacing ignored) is already on this repo's
#     list, open or done, or repeated earlier in FILE, is not saved again. Prints one JSON object
#     {saved: [{id, what, why, source}], duplicates: [{what, existing_id}],
#      not_saved: [{what, why, reason}]}. A task that could not be saved is always in not_saved with
#     the reason (no location, unreadable list, secret refused, checker or helper missing).
#
# OUTPUT (stdout, one JSON object)
#   scope            thread | all
#   repo, session    the thread's repo key and session id ("" when unknown)
#   now, since       epochs; since_source: declared | flag | default-24h
#   away_seconds     now - since; digest_level: short (< 2 h) | medium (< 12 h) | long
#   presence         presence.sh status --json, or null
#   questions        open unattended questions in scope, oldest first: {id, repo, question, options,
#                    recommended, did, session, at}; null when unreadable
#   decisions        open Desk Decisions in scope: {id, repo, question, options, default_option,
#                    session_id, created_at, context}; null when unreadable
#   other_threads_open  open questions and Decisions outside a thread scope (0 for --all)
#   tasks            open human tasks (owner-task.sh list --json, Issue #2538 contract); null when the
#                    helper is missing or failed: the list is unavailable, never empty
#   activity         {merged, opened, failed}: PRs merged and opened by you, and failed workflow runs,
#                    since `since` (runs created more than 3 days before it are not read); each null when
#                    unreadable, and a list that fills its page limit is named in `unreadable` as incomplete
#   stoppages        Desk stoppage entries since `since` (this session's in thread scope); null when unreadable
#   running          pipeline agents still recorded as running (this session's in thread scope)
#   handoffs         per-PR handoff files in scope: {repo, pr, phase_completed, head_sha}
#   local_sources    the sources read from this machine only (another machine's are not seen)
#   unreadable       [{source, reason}] for every source that could not be read
#
# HELPERS (resolved at run time; overrides for tests)
#   owner-task.sh    $BACK_REPORT_OWNER_TASK, else ~/.claude/skills-worktree/.claude/scripts/,
#                    ~/.claude/scripts/, ./.claude/scripts/ (first executable)
#   human-queue.sh   $BACK_REPORT_HQ, else ~/.claude/skills-worktree/desk/bin/, then <this repo>/desk/bin/
#   unattended.sh, presence.sh, session-state.sh   siblings of this script
#   gh               on PATH
#
# EXIT CODES
#   0 report printed (unreadable sources are inside it), or --save-recovered ran (failures are in its
#   not_saved); 1 jq not found; 2 usage error (including a FILE that is not a JSON array of {what, why}).
#
# Bash 3.2 compatible (macOS /bin/bash).
set -uo pipefail

HERE=$(cd -P "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd) || HERE="."
STATE_FILE="${HOME}/.claude/session-state.json"

usage() { sed -n '2,/^# Bash 3.2/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }
die_usage() { printf 'back-report.sh: %s\n' "$1" >&2; exit 2; }

JQ=$(command -v jq 2>/dev/null) || JQ=""
if [ -z "$JQ" ]; then
  for c in /opt/homebrew/bin/jq /usr/local/bin/jq /usr/bin/jq; do
    if [ -x "$c" ]; then JQ="$c"; break; fi
  done
fi
[ -z "$JQ" ] || case "$JQ" in /*) PATH="$PATH:$(dirname "$JQ")"; export PATH ;; esac

RECOVER="" ALL=0 SID="${CLAUDE_CODE_SESSION_ID:-${CLAUDE_SESSION_ID:-}}" SINCE="" NOW="" CWD="$PWD"
while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help|help) usage; exit 0 ;;
    --all) ALL=1; shift ;;
    --session) [ $# -ge 2 ] || die_usage "--session needs a value"; SID="$2"; shift 2 ;;
    --since) [ $# -ge 2 ] || die_usage "--since needs a value"; SINCE="$2"; shift 2 ;;
    --now) [ $# -ge 2 ] || die_usage "--now needs a value"; NOW="$2"; shift 2 ;;
    --cwd) [ $# -ge 2 ] || die_usage "--cwd needs a value"; CWD="$2"; shift 2 ;;
    --save-recovered) [ $# -ge 2 ] || die_usage "--save-recovered needs a file"; RECOVER="$2"; shift 2 ;;
    *) die_usage "unknown argument: $1" ;;
  esac
done
case "$SINCE" in *[!0-9]*) die_usage "--since takes an epoch" ;; esac
case "$NOW" in *[!0-9]*) die_usage "--now takes an epoch" ;; esac
# Base 10 explicitly: a leading zero would otherwise be read as octal.
[ -z "$SINCE" ] || SINCE=$(( 10#$SINCE ))
[ -z "$NOW" ] || NOW=$(( 10#$NOW ))
[ -d "$CWD" ] || die_usage "--cwd is not a directory: $CWD"
[ -n "$JQ" ] || { printf 'back-report.sh: jq not found\n' >&2; exit 1; }
case "$SID" in *[!A-Za-z0-9._-]*) SID="" ;; esac

[ -n "$NOW" ] || NOW=$(date +%s)
SCOPE=thread; [ "$ALL" -eq 0 ] || SCOPE=all

WORK=$(mktemp -d "${TMPDIR:-/tmp}/back-report.XXXXXX") || { printf 'back-report.sh: cannot create a temp dir\n' >&2; exit 1; }
trap 'rm -rf "$WORK"' EXIT
UNREAD="$WORK/unreadable.jsonl"; : >"$UNREAD"
unreadable() { # SOURCE REASON
  "$JQ" -cn --arg s "$1" --arg r "$2" '{source: $s, reason: $r}' >>"$UNREAD"
}
# Store a section: valid JSON of the expected type, or null with the source named as unreadable.
put() { # NAME SOURCE JSON TYPE(array|object)
  if [ -n "$3" ] && printf '%s' "$3" | "$JQ" -e --arg t "$4" 'type == $t' >/dev/null 2>&1; then
    printf '%s\n' "$3" >"$WORK/$1.json"
  else
    printf 'null\n' >"$WORK/$1.json"
    unreadable "$2" "the output was not a JSON $4"
  fi
}
null_section() { printf 'null\n' >"$WORK/$1.json"; }

iso() { # EPOCH -> ISO-8601 UTC
  date -u -r "$1" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date -u -d "@$1" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null
}

# --- owner-task.sh -------------------------------------------------------------
OT="${BACK_REPORT_OWNER_TASK:-}"
if [ -z "$OT" ]; then
  for c in "${HOME:+$HOME/.claude/skills-worktree/.claude/scripts/owner-task.sh}" \
           "${HOME:+$HOME/.claude/scripts/owner-task.sh}" ".claude/scripts/owner-task.sh"; do
    if [ -n "$c" ] && [ -x "$c" ]; then OT="$c"; break; fi
  done
fi
# Absolute before any cd, so the helper that was found is the one that runs.
case "$OT" in ''|/*) ;; *) OT="$PWD/$OT" ;; esac

# --- repo, absence -------------------------------------------------------------
REPO=""
if [ -x "$HERE/session-state.sh" ]; then
  REPO=$(cd "$CWD" 2>/dev/null && "$HERE/session-state.sh" --repo-key 2>/dev/null) || REPO=""
fi
[ "$REPO" != "_unknown" ] || REPO=""
# unattended.sh keys an origin-less checkout as _local/<toplevel with / as _>; match questions on that
# key too, or this thread's own questions there would never count as mine.
QREPO="$REPO"
if [ -z "$QREPO" ]; then
  qtop=$(cd "$CWD" 2>/dev/null && git rev-parse --show-toplevel 2>/dev/null) || qtop=""
  QREPO="_local/$(printf '%s' "${qtop:-$CWD}" | tr '/' '_')"
fi

# --- --save-recovered: the one write ----------------------------------------------------------
if [ -n "$RECOVER" ]; then
  [ -r "$RECOVER" ] || die_usage "--save-recovered: cannot read $RECOVER"
  # Slurped: exactly one top-level value, so two arrays back to back are refused, not half-read.
  "$JQ" -e -s 'length == 1 and (.[0] | type == "array" and all(.[]; type == "object"
             and (.what | type == "string") and (.what | test("\\S")) and (.why | type == "string")))' \
    "$RECOVER" >/dev/null 2>&1 \
    || die_usage "--save-recovered: FILE must be a JSON array of {what, why} with a non-empty what"
  RARGS=(); case "$REPO" in ''|_local/*) ;; *) RARGS=(--repo "$REPO") ;; esac
  DAY=$(date -u -r "$NOW" '+%Y-%m-%d' 2>/dev/null || date -u -d "@$NOW" '+%Y-%m-%d' 2>/dev/null)
  if [ -n "$SID" ]; then SRC="recovered by /back from this thread (session $SID, $DAY)"
  else SRC="recovered by /back from this thread ($DAY)"; fi
  OUT="$WORK/recovered.jsonl"; : >"$OUT"
  SEEN="$WORK/seen.txt"; : >"$SEEN"
  NORM='ascii_downcase | gsub("\\s+"; " ") | sub("^ "; "") | sub(" $"; "")'
  # Every task the list already holds, open or done: without it no duplicate check is possible, so
  # nothing is saved and each task is reported as not saved.
  EXIST="" LRC=0 WHY_NOT=""
  if [ -z "$OT" ] || [ ! -x "$OT" ]; then
    WHY_NOT="owner-task.sh not found (checked all three paths)"
  else
    EXIST=$(cd "$CWD" 2>/dev/null && "$OT" list --all --json ${RARGS[@]+"${RARGS[@]}"} 2>/dev/null) || LRC=$?
    if [ "$LRC" -ne 0 ] || ! printf '%s' "$EXIST" | "$JQ" -e 'type == "array"' >/dev/null 2>&1; then
      WHY_NOT="the task list could not be read to check for duplicates (owner-task.sh list exited $LRC)"
    fi
  fi
  n=$("$JQ" 'length' "$RECOVER") i=0
  while [ "$i" -lt "$n" ]; do
    W=$("$JQ" -r --argjson i "$i" '.[$i].what' "$RECOVER")
    Y=$("$JQ" -r --argjson i "$i" '.[$i].why' "$RECOVER")
    i=$((i + 1))
    if [ -n "$WHY_NOT" ]; then
      "$JQ" -cn --arg w "$W" --arg y "$Y" --arg r "$WHY_NOT" '{k: "not_saved", v: {what: $w, why: $y, reason: $r}}' >>"$OUT"
      continue
    fi
    KEY=$("$JQ" -rn --arg w "$W" "\$w | $NORM")
    DUP=$(printf '%s' "$EXIST" | "$JQ" -r --arg k "$KEY" "[.[] | select((.what | $NORM) == \$k) | .id][0] // empty")
    if [ -z "$DUP" ] && grep -qxF -- "$KEY" "$SEEN"; then DUP="earlier in this list"; fi
    if [ -n "$DUP" ]; then
      "$JQ" -cn --arg w "$W" --arg d "$DUP" '{k: "duplicates", v: {what: $w, existing_id: $d}}' >>"$OUT"
      continue
    fi
    printf '%s\n' "$KEY" >>"$SEEN"
    ARC=0
    ID=$(cd "$CWD" 2>/dev/null && "$OT" add --what "$W" --why "$Y" --source "$SRC" ${RARGS[@]+"${RARGS[@]}"} 2>/dev/null) || ARC=$?
    ID=$(printf '%s\n' "$ID" | tail -1)
    if [ "$ARC" -eq 0 ] && [ -n "$ID" ]; then
      "$JQ" -cn --arg i "$ID" --arg w "$W" --arg y "$Y" --arg s "$SRC" \
        '{k: "saved", v: {id: $i, what: $w, why: $y, source: $s}}' >>"$OUT"
      continue
    fi
    case "$ARC" in
      0) R="owner-task.sh add printed no task id" ;;
      3) R="no location for this repo's tasks: a public repo with no private bucket in the pointer file (owner-task.sh add exited 3)" ;;
      4) R="a task source could not be read (owner-task.sh add exited 4)" ;;
      5) R="refused as a possible secret (owner-task.sh add exited 5)" ;;
      7) R="the secret checker is missing, so the write was refused (owner-task.sh add exited 7)" ;;
      *) R="owner-task.sh add exited $ARC" ;;
    esac
    "$JQ" -cn --arg w "$W" --arg y "$Y" --arg r "$R" '{k: "not_saved", v: {what: $w, why: $y, reason: $r}}' >>"$OUT"
  done
  "$JQ" -s '{saved: [.[] | select(.k == "saved") | .v], duplicates: [.[] | select(.k == "duplicates") | .v],
             not_saved: [.[] | select(.k == "not_saved") | .v]}' "$OUT"
  exit 0
fi

SINCE_SOURCE=flag
if [ -z "$SINCE" ]; then
  SINCE=""
  if [ -f "$STATE_FILE" ] && ! SINCE=$("$JQ" -r '.unattended.since_epoch // empty | numbers' "$STATE_FILE" 2>/dev/null); then
    # A read failure is not "no declaration": name it, so the 24-hour fallback is not taken as the truth.
    SINCE=""
    unreadable "away declaration" "the session state could not be read; the last 24 hours were used"
  fi
  SINCE_SOURCE=declared
  if [ -z "$SINCE" ] || [ "$SINCE" -gt "$NOW" ]; then SINCE=$(( NOW - 86400 )); SINCE_SOURCE=default-24h; fi
fi
SINCE_ISO=$(iso "$SINCE")
AWAY=$(( NOW - SINCE )); [ "$AWAY" -ge 0 ] || AWAY=0
if [ "$AWAY" -lt 7200 ]; then LEVEL=short; elif [ "$AWAY" -lt 43200 ]; then LEVEL=medium; else LEVEL=long; fi

# --- presence --------------------------------------------------------------------
P=""
[ -x "$HERE/presence.sh" ] && P=$("$HERE/presence.sh" status --json 2>/dev/null)
if [ -n "$P" ]; then put presence presence "$P" object; else null_section presence; unreadable presence "presence.sh status failed"; fi

# --- questions and Decisions (scope filter in jq) --------------------------------------
# In thread scope an item belongs here when it is this repo's and this session asked it or no session
# was recorded; everything else open is counted in other_threads_open, so the skill can point at /back all.
SCOPE_JQ='def mine($repo; $sid; $s): ((.repo // "") | ascii_downcase) == ($repo | ascii_downcase)
  and ($sid == "" or ($s // "") == "" or $s == $sid);'

Q=""
if [ -x "$HERE/unattended.sh" ]; then
  Q=$(cd "$CWD" 2>/dev/null && "$HERE/unattended.sh" list --all --json 2>/dev/null) || Q=""
fi
if [ -n "$Q" ] && printf '%s' "$Q" | "$JQ" -e 'type == "array"' >/dev/null 2>&1; then
  printf '%s' "$Q" | "$JQ" -c --arg scope "$SCOPE" --arg repo "$QREPO" --arg sid "$SID" "$SCOPE_JQ"'
    [.[] | select(.status == "open")] as $open
    | {in: [$open[] | select($scope == "all" or mine($repo; $sid; .session))
             | {id, repo, question, options, recommended, did, session, at}] | sort_by(.at),
       total: ($open | length)}' >"$WORK/q.json" 2>/dev/null || {
    printf '{"in":null,"total":0}\n' >"$WORK/q.json"; unreadable "unattended questions" "the question records could not be read"; }
else
  printf '{"in":null,"total":0}\n' >"$WORK/q.json"
  unreadable "unattended questions" "unattended.sh list --all --json failed"
fi

HQ="${BACK_REPORT_HQ:-}"
if [ -z "$HQ" ]; then
  for c in "${HOME:+$HOME/.claude/skills-worktree/desk/bin/human-queue.sh}" "${HERE%/.claude/scripts}/desk/bin/human-queue.sh"; do
    if [ -n "$c" ] && [ -x "$c" ]; then HQ="$c"; break; fi
  done
fi
D="" drc=0
if [ -n "$HQ" ]; then
  D=$("$HQ" list --kind decision --status open --json 2>/dev/null) || drc=$?
else
  drc=127
fi
if [ "$drc" -eq 0 ] && printf '%s' "$D" | "$JQ" -e 'type == "array"' >/dev/null 2>&1; then
  printf '%s' "$D" | "$JQ" -c --arg scope "$SCOPE" --arg repo "$REPO" --arg sid "$SID" "$SCOPE_JQ"'
    {in: [.[] | select($scope == "all" or mine($repo; $sid; .session_id))
           | {id, repo, question, options, default_option, session_id, created_at, context}],
     total: length}' >"$WORK/d.json" 2>/dev/null || {
    printf '{"in":null,"total":0}\n' >"$WORK/d.json"; unreadable "Desk Decisions" "the Decision records could not be read"; }
else
  printf '{"in":null,"total":0}\n' >"$WORK/d.json"
  case "$drc" in
    127) unreadable "Desk Decisions" "human-queue.sh not found (checked the skills worktree and this repo's desk/bin)" ;;
    7) unreadable "Desk Decisions" "the desk database is unset or unreachable" ;;
    *) unreadable "Desk Decisions" "human-queue.sh list exited $drc" ;;
  esac
fi

# --- human tasks (Issue #2538 contract) ---------------------------------------------------
if [ -z "$OT" ] || [ ! -x "$OT" ]; then
  null_section tasks
  unreadable "human tasks" "owner-task.sh not found (checked all three paths)"
else
  trc=0
  if [ "$ALL" -eq 1 ]; then
    T=$(cd "$CWD" 2>/dev/null && "$OT" list --json --all-repos 2>/dev/null) || trc=$?
  else
    T=$(cd "$CWD" 2>/dev/null && "$OT" list --json 2>/dev/null) || trc=$?
  fi
  if [ "$trc" -ne 0 ]; then
    null_section tasks
    unreadable "human tasks" "owner-task.sh list exited $trc"
  else
    put tasks "human tasks" "$(printf '%s' "$T" | "$JQ" -c '[.[] | select(.state == "open")]' 2>/dev/null)" array
  fi
fi

# --- GitHub activity -------------------------------------------------------------------------
# Failed runs are listed from 3 days before `since` and cut on their last update, so a run that started
# shortly before he left and failed while he was away is included. A run created earlier still (one held
# days for an approval) is not listed: a deeper read is slow and runs into the page limit on busy repos.
RUNS_FROM=$(iso "$(( SINCE - 3 * 86400 ))")
RUNS_CUT='[.[] | select((.updatedAt // .createdAt // "") >= $since)]'
RUN_FIELDS=databaseId,name,displayTitle,url,headBranch,createdAt,updatedAt
GH_LIMIT=100
RUN_LIMIT=300   # failed runs span the absence plus 3 days, so they get a deeper read
# A result that fills its limit may have more: say so, rather than present it as complete.
note_full() { # SOURCE JSON [LIMIT]
  local n lim="${3:-$GH_LIMIT}"
  n=$(printf '%s' "$2" | "$JQ" -r 'if type == "array" then length else 0 end' 2>/dev/null) || n=0
  [ "${n:-0}" -lt "$lim" ] || unreadable "$1" "incomplete: only the first $lim results were read"
}
gh_section() { # NAME SOURCE CMD...
  local name="$1" src="$2" out rc=0
  shift 2
  out=$("$@" 2>/dev/null) || rc=$?
  if [ "$rc" -ne 0 ]; then null_section "$name"; unreadable "$src" "gh exited $rc"; return 1; fi
  note_full "$src" "$out" "${NOTE_LIMIT:-$GH_LIMIT}"
  put "$name" "$src" "$out" array
}
if ! command -v gh >/dev/null 2>&1; then
  null_section merged; null_section opened; null_section failed
  unreadable "GitHub" "gh not found on PATH"
elif [ "$ALL" -eq 1 ]; then
  gh_section merged "GitHub merged PRs" gh search prs --author @me --merged-at ">=$SINCE_ISO" \
    --json number,title,url,repository,closedAt --limit "$GH_LIMIT"
  gh_section opened "GitHub opened PRs" gh search prs --author @me --created ">=$SINCE_ISO" \
    --json number,title,url,repository,createdAt,state --limit "$GH_LIMIT"
  # Failed runs: this repo, the repos with PR activity, and the repos with open questions, Decisions or
  # tasks. At most RUNS_REPO_CAP; any beyond the cap are named as not checked.
  RUNS_REPO_CAP=15
  allrepos=$( { [ -z "$REPO" ] || printf '%s\n' "$REPO"
    cat "$WORK/merged.json" "$WORK/opened.json" 2>/dev/null |
      "$JQ" -r 'select(type == "array") | .[].repository.nameWithOwner // empty'
    "$JQ" -r '.in // [] | .[].repo // empty' "$WORK/q.json" "$WORK/d.json" 2>/dev/null
    "$JQ" -r 'select(type == "array") | .[].repo // empty' "$WORK/tasks.json" 2>/dev/null
  } | grep -E '^[^/[:space:]_][^/[:space:]]*/[^/[:space:]]+$' | awk '!seen[tolower($0)]++')
  repos=$(printf '%s\n' "$allrepos" | sed -n "1,${RUNS_REPO_CAP}p")
  skipped=$(printf '%s\n' "$allrepos" | sed -n "$(( RUNS_REPO_CAP + 1 )),\$p" | tr '\n' ' ')
  [ -z "${skipped// /}" ] || unreadable "GitHub failed runs" "not checked (over the ${RUNS_REPO_CAP}-repo cap): ${skipped% }"
  # null when no repo could be read (unknown), the runs read so far when only some failed.
  printf '[]\n' >"$WORK/failed.json"
  tried=0 readok=0
  for r in $repos; do
    tried=$((tried + 1)); out=""; rc=0
    out=$(gh run list --repo "$r" --status failure --created ">=$RUNS_FROM" \
      --json "$RUN_FIELDS" --limit "$RUN_LIMIT" 2>/dev/null) || rc=$?
    if [ "$rc" -ne 0 ] || ! printf '%s' "$out" | "$JQ" -e 'type == "array"' >/dev/null 2>&1; then
      unreadable "GitHub failed runs ($r)" "gh run list exited $rc"; continue
    fi
    note_full "GitHub failed runs ($r)" "$out" "$RUN_LIMIT"
    "$JQ" -c --arg r "$r" --arg since "$SINCE_ISO" --argjson add "$out" \
      '. + [$add | '"$RUNS_CUT"' | .[] | . + {repo: $r}]' "$WORK/failed.json" >"$WORK/f.tmp" &&
      mv "$WORK/f.tmp" "$WORK/failed.json" && readok=$((readok + 1))
  done
  if [ "$tried" -eq 0 ]; then
    null_section failed; unreadable "GitHub failed runs" "no repo was known to check"
  elif [ "$readok" -eq 0 ]; then
    null_section failed
  fi
elif [ -z "$REPO" ]; then
  null_section merged; null_section opened; null_section failed
  unreadable "GitHub" "this checkout has no GitHub origin"
else
  gh_section merged "GitHub merged PRs" gh pr list --repo "$REPO" --state merged \
    --search "author:@me merged:>=$SINCE_ISO" --json number,title,url,mergedAt --limit "$GH_LIMIT"
  gh_section opened "GitHub opened PRs" gh pr list --repo "$REPO" --state all \
    --search "author:@me created:>=$SINCE_ISO" --json number,title,url,createdAt,state --limit "$GH_LIMIT"
  if NOTE_LIMIT=$RUN_LIMIT gh_section failed "GitHub failed runs" gh run list --repo "$REPO" --status failure --created ">=$RUNS_FROM" \
      --json "$RUN_FIELDS" --limit "$RUN_LIMIT"; then
    put failed "GitHub failed runs" "$("$JQ" -c --arg since "$SINCE_ISO" "$RUNS_CUT" "$WORK/failed.json" 2>/dev/null)" array
  fi
fi

# --- stoppages (Desk database) ---------------------------------------------------------------------
if [ -z "$HQ" ]; then
  null_section stoppages
  unreadable "stoppages" "human-queue.sh not found (checked the skills worktree and this repo's desk/bin)"
else
  src=0
  # --from is a calendar day; one day earlier covers any time zone, and the exact cut is made below.
  from=$(date -u -r "$(( SINCE - 86400 ))" +%Y-%m-%d 2>/dev/null || date -u -d "@$(( SINCE - 86400 ))" +%Y-%m-%d 2>/dev/null)
  S=$("$HQ" stoppage list --from "$from" --json 2>/dev/null) || src=$?
  if [ "$src" -ne 0 ]; then
    null_section stoppages
    if [ "$src" -eq 7 ]; then unreadable "stoppages" "the desk database is unset or unreachable"
    else unreadable "stoppages" "human-queue.sh stoppage list exited $src"; fi
  else
    put stoppages "stoppages" "$(printf '%s' "$S" | "$JQ" -c --arg since "$SINCE_ISO" --arg scope "$SCOPE" --arg sid "$SID" '
      [.[] | select(.stopped_at >= $since) | select($scope == "all" or $sid == "" or .thread == $sid)]' 2>/dev/null)" array
  fi
fi

# --- running agents and handoffs (this machine) ---------------------------------------------------
if [ -f "$STATE_FILE" ]; then
  R=$("$JQ" -c --arg scope "$SCOPE" --arg sid "$SID" --arg repo "$REPO" '
    [(.active_agents // {}) | to_entries[] | .value | select(type == "object")
     | select((.status // "") | IN("completed","complete","failed","merged","done","exited","stopped","crashed","cancelled") | not)
     | select($scope == "all" or ($sid != "" and .session_id == $sid)
              or ($sid == "" and ((.owner_repo // $repo) | ascii_downcase) == ($repo | ascii_downcase)))
     | {id, task, issue, pr, phase, status, launched, session_id}]' "$STATE_FILE" 2>/dev/null) || R=""
  put running "running agents" "$R" array
else
  printf '[]\n' >"$WORK/running.json"
fi

HD="${HOME}/.claude/handoffs"
printf '[]\n' >"$WORK/handoffs.json"
if [ -d "$HD" ]; then
  if [ "$ALL" -eq 1 ]; then
    dirs=$(find "$HD" -mindepth 2 -maxdepth 2 -type d 2>/dev/null) || unreadable "handoffs" "the handoff directory could not be fully listed"
  elif [ -n "$REPO" ]; then dirs="$HD/$REPO"
  else dirs=""; fi
  while IFS= read -r d; do
    [ -n "$d" ] && [ -d "$d" ] || continue
    # An existing directory that cannot be listed is named, never shown as no handoffs.
    if [ ! -r "$d" ] || [ ! -x "$d" ]; then unreadable "handoffs ($d)" "the directory cannot be read"; continue; fi
    for f in "$d"/pr-*-handoff.json; do
      [ -f "$f" ] || continue
      r="${d#"$HD"/}"
      h=$("$JQ" -c --arg r "$r" '{repo: $r, pr: (.pr_number // .pr // null), phase_completed: (.phase_completed // null),
        head_sha: (.head_sha // null)}' "$f" 2>/dev/null) || h=""
      # Exactly one object: an empty or non-object file is named, never dropped silently.
      if [ -z "$h" ] || ! printf '%s' "$h" | "$JQ" -e 'type == "object"' >/dev/null 2>&1 || [ "$(printf '%s\n' "$h" | wc -l | tr -d ' ')" != 1 ]; then
        unreadable "handoff $f" "not one JSON record"; continue
      fi
      "$JQ" -c --argjson h "$h" '. + [$h]' "$WORK/handoffs.json" >"$WORK/h.tmp" && mv "$WORK/h.tmp" "$WORK/handoffs.json"
    done
  done <<DIRS
$dirs
DIRS
fi

# --- assemble -------------------------------------------------------------------------------------
"$JQ" -n -c \
  --arg scope "$SCOPE" --arg repo "$REPO" --arg sid "$SID" \
  --argjson now "$NOW" --argjson since "$SINCE" --arg since_source "$SINCE_SOURCE" \
  --argjson away "$AWAY" --arg level "$LEVEL" \
  --slurpfile presence "$WORK/presence.json" --slurpfile q "$WORK/q.json" --slurpfile d "$WORK/d.json" \
  --slurpfile tasks "$WORK/tasks.json" --slurpfile merged "$WORK/merged.json" \
  --slurpfile opened "$WORK/opened.json" --slurpfile failed "$WORK/failed.json" \
  --slurpfile stoppages "$WORK/stoppages.json" --slurpfile running "$WORK/running.json" \
  --slurpfile handoffs "$WORK/handoffs.json" --rawfile unread "$UNREAD" '
  {scope: $scope, repo: $repo, session: $sid, now: $now, since: $since, since_source: $since_source,
   away_seconds: $away, digest_level: $level, presence: $presence[0],
   questions: $q[0].in, decisions: $d[0].in,
   other_threads_open: (if $scope == "all" then 0
     else (($q[0].total - ($q[0].in // [] | length)) + ($d[0].total - ($d[0].in // [] | length))) end),
   tasks: $tasks[0],
   activity: {merged: $merged[0], opened: $opened[0], failed: $failed[0]},
   stoppages: $stoppages[0], running: $running[0], handoffs: $handoffs[0],
   local_sources: ["presence", "unattended questions", "running agents", "handoffs"],
   unreadable: [$unread | split("\n")[] | select(length > 0) | fromjson]}'
