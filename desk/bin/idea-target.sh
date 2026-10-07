#!/usr/bin/env bash
# idea-target.sh — where an idea typed at the desk is filed (issue #1766).
# catalog: utilities — Human-queue idea target (`desk/bin/idea-target.sh`): reads a desk `idea:` / `file:` / `repo:` message on stdin and resolves the repo the idea is filed in: named in the text, else the desk session's default, else a suggestion to ask about once
#
# USAGE
#   idea-target.sh --session SID <<'DESK_IDEA'
#   <the operator's whole message>
#   DESK_IDEA
#
#   The message is read on stdin, so quotes, $(...), and backticks in it are
#   never seen by a shell. It starts with `idea:`, `file:`, or `repo:` (any
#   case).
#
# WHAT IT DECIDES
#   idea: / file: TEXT
#     1. The text's first word, when it is OWNER/NAME or a
#        https://github.com/OWNER/NAME link, is checked as a repository:
#        `gh repo view` must find it with issues enabled and you able to
#        write to it (ADMIN, MAINTAIN, WRITE, or TRIAGE). It then is the repo,
#        in GitHub's own spelling, and leaves the text. A word that fails
#        the check (`desk/skill` is a path, not a repo) stays in the text,
#        with a note.
#     2. Otherwise this desk session's default: the store's state key
#        idea_repo:<SID>, read through desk-cli.sh.
#     3. Otherwise none: exit 3, with `suggest` set to the current
#        directory's repository when it passes the same check. The desk then
#        asks once, in plain text, for `repo: OWNER/NAME`.
#   repo: OWNER/NAME (or a GitHub link)
#     Checks it the same way and saves it as this session's default
#     (`state set idea_repo:<SID>`). A store that cannot be reached leaves it
#     unsaved (`saved: false`, with a note); the repo is still returned, so
#     the idea waiting for it can be filed.
#
# OUTPUT (stdout): one JSON object
#   {"verb": "idea"|"repo", "text": "...", "repo": "OWNER/NAME"|null,
#    "source": "text"|"default"|"reply"|null, "saved": true|false,
#    "suggest": "OWNER/NAME"|null, "notes": ["..."]}
#   text is the idea with the repository word removed ("" for repo:).
#
# ENVIRONMENT
#   HUMAN_QUEUE_GH   gh binary override (tests)
#   HUMAN_QUEUE_CLI  passed through to desk-cli.sh (tests)
#
# EXIT CODES
#   0  a repo was found (idea) or checked (repo:)
#   3  an idea with no repo yet: ask for one; nothing else is wrong
#   4  usage: no --session, a message without idea:/file:/repo:, an idea
#      with no text, or `repo:` naming nothing usable (the JSON names why)
#   1  gh or jq is missing
#
# Bash 3.2 compatible (macOS /bin/bash).
set -u

it_self="${BASH_SOURCE[0]}"
while [ -L "$it_self" ]; do
  it_dir=$(cd -P "$(dirname "$it_self")" && pwd) || exit 1
  it_self=$(readlink "$it_self") || exit 1
  case "$it_self" in
    /*) ;;
    *) it_self="$it_dir/$it_self" ;;
  esac
done
HQ_BIN_DIR=$(cd -P "$(dirname "$it_self")" && pwd) || exit 1
# shellcheck source=lib/common.sh
. "$HQ_BIN_DIR/lib/common.sh"
# shellcheck source=lib/github.sh
. "$HQ_BIN_DIR/lib/github.sh"

it_usage() {
  sed -n '3,51p' "$it_self" | sed 's/^# \{0,1\}//'
}

SID=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    -h|--help) it_usage; exit 0 ;;
    --session)
      if [ "$#" -lt 2 ]; then
        printf 'idea-target: --session needs a value\n' >&2
        exit 4
      fi
      SID="$2"
      shift 2
      ;;
    *)
      printf 'idea-target: unknown argument (run idea-target.sh --help)\n' >&2
      exit 4
      ;;
  esac
done
SID_RE='^[A-Za-z0-9_.:-]{1,150}$'
if ! [[ $SID =~ $SID_RE ]]; then
  printf 'idea-target: --session SID is required (letters, digits, and _ . : -)\n' >&2
  exit 4
fi

hq_jq_find || { printf 'idea-target: jq not found\n' >&2; exit 1; }
hq_gh_find || { printf 'idea-target: gh not found (HUMAN_QUEUE_GH, /opt/homebrew/bin/gh, or PATH)\n' >&2; exit 1; }

MSG=$(cat)
VERB=""
TEXT=""
NOTES=""
note() { NOTES="$NOTES$1"$'\n'; }

# The prefix, any case, after leading blank space.
LEAD="${MSG#"${MSG%%[![:space:]]*}"}"
PREFIX=$(printf '%s' "${LEAD:0:5}" | LC_ALL=C tr '[:upper:]' '[:lower:]')
case "$PREFIX" in
  idea:|file:) VERB=idea ;;
  repo:) VERB=repo ;;
esac
TEXT="${LEAD:5}"
TEXT="${TEXT#"${TEXT%%[![:space:]]*}"}"
TEXT="${TEXT%"${TEXT##*[![:space:]]}"}"

emit() {
  # emit REPO SOURCE SAVED SUGGEST
  printf '%s' "$NOTES" | hq_jq -R -s -c \
    --arg verb "$VERB" --arg text "$TEXT" --arg repo "$1" --arg source "$2" \
    --argjson saved "$3" --arg suggest "$4" \
    '{verb: $verb, text: $text,
      repo: (if $repo == "" then null else $repo end),
      source: (if $source == "" then null else $source end),
      saved: $saved,
      suggest: (if $suggest == "" then null else $suggest end),
      notes: (split("\n") | map(select(length > 0)))}'
}

if [ -z "$VERB" ]; then
  note "the message does not start with idea:, file:, or repo:"
  emit "" "" false ""
  exit 4
fi

# repo_word WORD — prints OWNER/NAME when WORD has that shape or is a GitHub
# link to a repository; prints nothing otherwise.
repo_word() {
  local w="$1" re_repo='^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$'
  local re_url='^https?://(www\.)?github\.com/([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+)/?$'
  w="${w%[:,;]}"
  w="${w%.git}"
  if [[ $w =~ $re_url ]]; then
    printf '%s\n' "${BASH_REMATCH[2]%.git}"
  elif [[ $w =~ $re_repo ]] && [ "${#w}" -le 140 ]; then
    printf '%s\n' "$w"
  fi
}

# check_repo [OWNER/NAME] — sets CHECKED to GitHub's spelling of the
# repository when it has issues enabled and you can write to it; with no
# argument, the current directory's repository. Returns 1 otherwise, with
# CHECKED empty and CHECK_WHY the reason. Called directly, never in $(...):
# its temp files and CHECK_WHY must outlive it.
CHECKED=""
CHECK_WHY=""
check_repo() {
  local out err rc=0 verdict
  CHECKED=""
  CHECK_WHY=""
  hq_mktemp out
  hq_mktemp err
  hq_gh "$out" "$err" repo view ${1:+"$1"} --json nameWithOwner,hasIssuesEnabled,viewerPermission || rc=$?
  if [ "$rc" -ne 0 ]; then
    if [ "$rc" -eq 124 ]; then CHECK_WHY="gh repo view timed out"; else CHECK_WHY="gh repo view found no such repository"; fi
    return 1
  fi
  verdict=$(hq_jq -r '
    if (.nameWithOwner // "") == "" then "!no repository"
    elif .hasIssuesEnabled != true then "!issues are turned off there"
    elif ((.viewerPermission // "") | IN("ADMIN", "MAINTAIN", "WRITE", "TRIAGE")) | not
      then "!you cannot file issues there (permission \(.viewerPermission // "none"))"
    else .nameWithOwner end' "$out" 2>/dev/null) || verdict="!gh repo view printed something unreadable"
  case "$verdict" in
    '!'*) CHECK_WHY="${verdict#!}"; return 1 ;;
    '') CHECK_WHY="gh repo view printed nothing"; return 1 ;;
  esac
  CHECKED="$verdict"
}

CLI="$HQ_BIN_DIR/desk-cli.sh"

if [ "$VERB" = repo ]; then
  word="${TEXT%%[[:space:]]*}"
  cand=$(repo_word "$word")
  if [ -z "$cand" ] || [ "$word" != "$TEXT" ]; then
    note "repo: takes one OWNER/NAME or a GitHub link"
    TEXT=""
    emit "" "" false ""
    exit 4
  fi
  if ! check_repo "$cand"; then
    note "$cand: $CHECK_WHY"
    TEXT=""
    emit "" "" false ""
    exit 4
  fi
  repo="$CHECKED"
  TEXT=""
  saved=false
  rc=0
  "$CLI" state set "idea_repo:$SID" "$repo" >/dev/null 2>&1 || rc=$?
  if [ "$rc" -eq 0 ]; then
    saved=true
  elif [ "$rc" -eq 7 ]; then
    note "the store is unreachable, so the default was not saved; the desk will ask again next time"
  else
    note "the default was not saved (state set exit $rc)"
  fi
  emit "$repo" reply "$saved" ""
  exit 0
fi

# --- idea: / file: --------------------------------------------------------------
if [ -z "$TEXT" ]; then
  note "the idea has no text"
  emit "" "" false ""
  exit 4
fi

first="${TEXT%%[[:space:]]*}"
cand=$(repo_word "$first")
if [ -n "$cand" ]; then
  if check_repo "$cand"; then
    repo="$CHECKED"
    rest="${TEXT#"$first"}"
    rest="${rest#"${rest%%[![:space:]]*}"}"
    if [ -z "$rest" ]; then
      note "the idea has no text after the repository"
      TEXT=""
      emit "$repo" text false ""
      exit 4
    fi
    TEXT="$rest"
    emit "$repo" text false ""
    exit 0
  fi
  note "$first was read as part of the idea, not as a repository ($CHECK_WHY)"
fi

rc=0
default=$("$CLI" state get "idea_repo:$SID" 2>/dev/null) || rc=$?
if [ "$rc" -eq 0 ] && [ -n "$default" ]; then
  emit "$default" default false ""
  exit 0
fi
if [ "$rc" -eq 7 ]; then
  note "the store is unreachable, so this session's default repo could not be read"
elif [ "$rc" -ne 0 ] && [ "$rc" -ne 4 ]; then
  note "this session's default repo could not be read (state get exit $rc)"
fi

suggest=""
if check_repo; then
  suggest="$CHECKED"
fi
emit "" "" false "$suggest"
exit 3
