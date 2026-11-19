#!/usr/bin/env bash
# owner-task.sh — One list per repo of what only the operator can do (issue #2538).
# catalog: backlog-pm — Keep one GitHub-stored list per repo of human tasks (add, list, done with proof, where), redirecting public repos to a private bucket
#
# Threads regularly hand the operator work only a person can do — fill in a
# .env, sign in to an account, accept an agreement. This script keeps those
# requests in ONE place per repo, on GitHub, so they follow him across threads,
# machines and coding apps, and so a later agent can see why each needed a
# person. Format, lookup order, pointer file and the done-with-proof rule:
# .claude/reference/owner-tasks.md.
#
# Storage: one open tracker issue per repo labelled `human-tasks`, one COMMENT
# per task (a comment POST is atomic, so concurrent adds never lose a task; a
# checklist in the body would be a read-modify-write race). A public repo never
# holds task text: its tasks go to a per-source-repo tracker in the private
# bucket repo the local pointer file names.
#
# Bash 3.2 compatible (macOS /bin/bash). Requires gh and jq.

set -euo pipefail

LABEL="human-tasks"
TRACKER_TITLE="Human tasks"
POINTER_FILE="${OWNER_TASK_POINTER_FILE:-${HOME:-}/.claude/owner-tasks-pointer.json}"

EXIT_OK=0
EXIT_ERROR=1
EXIT_USAGE=2
EXIT_NO_LOCATION=3
EXIT_UNREADABLE=4
EXIT_SECRET=5
EXIT_NO_PROOF=6
EXIT_NO_CHECKER=7

usage() {
  cat <<EOF
Usage:
  owner-task.sh add --what TEXT --why TEXT --source REF [--repo OWNER/NAME]
  owner-task.sh list [--all] [--json] [--repo OWNER/NAME | --all-repos]
  owner-task.sh done ID (--proof TEXT | --by operator) [--repo OWNER/NAME]
  owner-task.sh where [--repo OWNER/NAME]
  owner-task.sh --help

Keeps one list per repo of tasks only the operator can do, stored on GitHub:
one open tracker issue labelled '$LABEL' per repo, one comment per task.

  add     Record a task; prints its stable id (ht-xxxxxxxx). Creates the
          tracker issue on first use. --source names the thread, PR or issue
          that raised it.
  list    Open tasks for the repo (--all includes done; --all-repos covers
          every repo with a tracker or a pointer entry). --json prints one
          array of {id, repo, what, why, source, created_at, state, done_at,
          proof}; empty is [].
  done    Mark a task done. --proof names the check that shows it is done and
          is required unless --by operator.
  where   Print which location holds this repo's tasks and why.

Lookup order: the repo's own tracker issue, then the local pointer file
($POINTER_FILE). A public (or internal) repo is never written to: add writes
to the private bucket the pointer names, or refuses when there is none.
Pointer format: {"default_bucket": "owner/private", "repos": {"owner/public": "owner/private"}}

--repo defaults to the current checkout's GitHub repo.
Task text (what, why, source, proof) is refused before any write when it looks
like a secret (desk/bin/lib/secrets.sh hq_refuse_secret).

Exit codes:
  0  ok (list with nothing to show prints [] under --json)
  1  other failure: task id not found, a write failed
  2  usage error
  3  no usable location: public repo with no pointer entry, or a bucket that
     is not private; nothing written
  4  a source could not be read (repo, tracker, comments, search, pointer
     file); nothing printed on stdout
  5  secret refused; nothing written
  6  done refused: no --proof and not --by operator; nothing changed
  7  secret checker (desk/bin/lib/secrets.sh) not found; write refused

Reference: .claude/reference/owner-tasks.md
EOF
}

die() { # CODE MESSAGE
  local code="$1"; shift
  printf 'owner-task: %s\n' "$*" >&2
  exit "$code"
}

command -v jq >/dev/null 2>&1 || die "$EXIT_ERROR" "jq is required"

# ---- secret check -------------------------------------------------------------
# Resolve the script's real directory through symlinks (~/.claude/scripts may
# link into a worktree) so the desk library is found next to it.
resolve_self_dir() {
  local self="${BASH_SOURCE[0]}" dir
  while [ -L "$self" ]; do
    dir="$(cd "$(dirname "$self")" && pwd)"
    self="$(readlink "$self")"
    case "$self" in /*) ;; *) self="$dir/$self" ;; esac
  done
  cd "$(dirname "$self")" && pwd
}

SECRETS_LOADED=0
load_secret_checker() {
  [ "$SECRETS_LOADED" -eq 1 ] && return 0
  local dir cand
  dir="$(resolve_self_dir)"
  for cand in "$dir/../../desk/bin/lib/secrets.sh" \
              "${HOME:+$HOME/.claude/skills-worktree/desk/bin/lib/secrets.sh}"; do
    [ -n "$cand" ] || continue
    if [ -r "$cand" ]; then
      # shellcheck source=/dev/null
      . "$cand"
      # Our own one-line message and exit code, replacing desk's prefix.
      hq_die_secret() { die "$EXIT_SECRET" "$*"; }
      SECRETS_LOADED=1
      return 0
    fi
  done
  die "$EXIT_NO_CHECKER" "secret checker desk/bin/lib/secrets.sh not found (checked next to this script and ~/.claude/skills-worktree/desk); refusing to write task text unchecked"
}

check_text() { # FIELD VALUE
  load_secret_checker
  hq_refuse_secret "$1" "$2"
}

# ---- small helpers ------------------------------------------------------------
now_utc() { date -u +%Y-%m-%dT%H:%M:%SZ; }

new_task_id() {
  local hex
  hex="$(od -An -N4 -tx1 /dev/urandom | tr -d ' \n')"
  [ "${#hex}" -eq 8 ] || die "$EXIT_ERROR" "could not generate a task id"
  printf 'ht-%s\n' "$hex"
}

valid_repo() { [[ $1 =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]]; }

# GitHub repo names are case-insensitive, so every repo identity is stored and
# compared lowercase (the same convention as session-state's repo keys).
lower() { printf '%s\n' "$1" | tr '[:upper:]' '[:lower:]'; }

current_repo() {
  local r
  if ! r="$(gh repo view --json nameWithOwner --jq .nameWithOwner 2>/dev/null)" || [ -z "$r" ]; then
    die "$EXIT_UNREADABLE" "could not determine the current repo; pass --repo OWNER/NAME"
  fi
  lower "$r"
}

# repo_visibility REPO -> private|public|internal ; exit 4 when unreadable.
repo_visibility() {
  local v
  if ! v="$(gh api "repos/$1" --jq '.visibility // (if .private then "private" else "public" end)' 2>/dev/null)" || [ -z "$v" ]; then
    die "$EXIT_UNREADABLE" "could not read repo $1"
  fi
  printf '%s\n' "$v" | tr '[:upper:]' '[:lower:]'
}

# pointer_read -> pointer JSON ({} when the file is absent); exit 4 when it
# exists but is not a JSON object.
pointer_read() {
  if [ ! -e "$POINTER_FILE" ]; then
    echo '{}'
    return 0
  fi
  local j
  # Slurp so an empty file (no JSON value at all) is refused, not read as {}.
  # Repo names are lowercased here, so every pointer lookup is case-insensitive.
  if ! j="$(jq -cs '
        if length == 1 and (.[0] | type) == "object" then .[0] else error("not one object") end
        | if (has("default_bucket") and (.default_bucket | type) != "string" and .default_bucket != null)
             or (has("repos") and (.repos | type) != "object" and .repos != null)
             or ((.repos // {}) | type == "object" and ([.[] | type] | any(. != "string")))
          then error("unexpected shape") else . end
        | if (.default_bucket | type) == "string" then .default_bucket |= ascii_downcase else . end
        | if (.repos | type) == "object"
          then .repos |= with_entries(.key |= ascii_downcase
                                      | .value |= (if type == "string" then ascii_downcase else . end))
          else . end' \
        "$POINTER_FILE" 2>/dev/null)" || [ -z "$j" ]; then
    die "$EXIT_UNREADABLE" "pointer file $POINTER_FILE is not a readable JSON object"
  fi
  printf '%s\n' "$j"
}

# pointer_bucket REPO -> bucket repo for REPO, or empty.
pointer_bucket() {
  local p
  p="$(pointer_read)" || exit $?
  printf '%s' "$p" | jq -r --arg r "$1" '(.repos[$r] // .default_bucket // "") | strings'
}

# ---- location resolution (the seam) -------------------------------------------
# resolve_write_location REPO sets LOC_REPO (where the tracker lives), LOC_KIND
# (repo|bucket) and LOC_WHY. Candidates are tried in order; a later location
# (e.g. the Desk database) slots in as one more candidate here.
LOC_REPO=""; LOC_KIND=""; LOC_WHY=""
resolve_write_location() {
  local repo="$1" vis bucket bvis
  vis="$(repo_visibility "$repo")" || exit $?
  # 1. The repo itself, when only its collaborators can read it.
  if [ "$vis" = "private" ]; then
    LOC_REPO="$repo"; LOC_KIND="repo"
    LOC_WHY="$repo is private, so its tasks live in the repo itself"
    return 0
  fi
  # 2. The local pointer file's private bucket.
  bucket="$(pointer_bucket "$repo")" || exit $?
  if [ -z "$bucket" ]; then
    die "$EXIT_NO_LOCATION" "$repo is $vis and no private bucket is set; add {\"repos\": {\"$repo\": \"<owner>/<private-repo>\"}} to $POINTER_FILE (see .claude/reference/owner-tasks.md); nothing written"
  fi
  valid_repo "$bucket" || die "$EXIT_NO_LOCATION" "pointer file names an invalid bucket '$bucket'; nothing written"
  bvis="$(repo_visibility "$bucket")" || exit $?
  if [ "$bvis" != "private" ]; then
    die "$EXIT_NO_LOCATION" "bucket $bucket is $bvis, not private; refusing to write task text there"
  fi
  LOC_REPO="$bucket"; LOC_KIND="bucket"
  LOC_WHY="$repo is $vis, so its tasks live in the private bucket $bucket named by $POINTER_FILE"
}

# read_locations REPO -> repos to read, one per line, in lookup order.
read_locations() {
  local repo="$1" bucket
  bucket="$(pointer_bucket "$repo")" || exit $?
  printf '%s\n' "$repo"
  if [ -n "$bucket" ] && [ "$bucket" != "$repo" ]; then
    printf '%s\n' "$bucket"
  fi
}

# ---- trackers -----------------------------------------------------------------
# open_labelled_issues HOST -> one JSON array of every open `human-tasks`
# issue in HOST, all pages. Exit 4 when unreadable.
open_labelled_issues() {
  local host="$1" raw arr
  if ! raw="$(gh api --paginate "repos/$host/issues?labels=$LABEL&state=open&per_page=100" \
        --jq '.[]' 2>/dev/null)"; then
    die "$EXIT_UNREADABLE" "could not read issues of $host"
  fi
  arr="$(printf '%s\n' "$raw" | jq -cs '.' 2>/dev/null)" \
    || die "$EXIT_UNREADABLE" "could not parse issues of $host"
  printf '%s\n' "$arr"
}

# trackers_in HOST SOURCE -> JSON array of open tracker issue numbers in HOST
# for SOURCE, ascending. Exit 4 when HOST's issues cannot be read.
trackers_in() {
  local host="$1" source="$2" raw
  raw="$(open_labelled_issues "$host")" || exit $?
  printf '%s' "$raw" | jq -c --arg host "$host" --arg src "$source" --arg title "$TRACKER_TITLE" '
    [ .[]
      | select(.pull_request == null)
      | . as $i
      # [...][0]: a body with no marker yields null (capture emits nothing on
      # no match), so a title-only tracker reaches the fallback below.
      | ([(.body // "") | try (capture("<!-- owner-task-tracker: (?<j>\\{[^}]*\\}) -->").j | fromjson | .repo | ascii_downcase) catch null][0]) as $marked
      | select(($marked == $src) or ($marked == null and $host == $src and $i.title == $title))
      | .number ] | sort' 2>/dev/null \
    || die "$EXIT_UNREADABLE" "could not parse issues of $host"
}

tracker_body() { # SOURCE KIND
  local marker
  marker="$(jq -cn --arg r "$1" '{repo: $r}')" || exit $?
  cat <<EOF
Human tasks for \`$1\`: work only the operator can do (a \`.env\` value, a sign-in, an agreement, a live test on his own profiles).

One comment per task, written by \`.claude/scripts/owner-task.sh\`. Mark one done with \`owner-task.sh done <id> --proof "<check>"\`, or \`--by operator\`. Format: \`.claude/reference/owner-tasks.md\`.

<!-- owner-task-tracker: $marker -->
EOF
}

# ensure_tracker HOST SOURCE -> canonical tracker number (creating on first use).
ensure_tracker() {
  local host="$1" source="$2" nums title body made created labelled canon
  nums="$(trackers_in "$host" "$source")" || exit $?
  if [ "$(printf '%s' "$nums" | jq 'length')" -gt 0 ]; then
    printf '%s' "$nums" | jq -r '.[0]'
    return 0
  fi
  title="$TRACKER_TITLE"
  [ "$host" = "$source" ] || title="$TRACKER_TITLE: $source"
  body="$(tracker_body "$source")" || exit $?
  # Best effort: the label may already exist (422), which is fine.
  gh api -X POST "repos/$host/labels" -f name="$LABEL" -f color=fbca04 \
    -f description="Tasks only the operator can do (owner-task.sh)" >/dev/null 2>&1 || true
  if ! made="$(gh api -X POST "repos/$host/issues" -f title="$title" -f body="$body" \
        -f "labels[]=$LABEL" \
        --jq '"\(.number) \([.labels[]?.name] | index("'"$LABEL"'") != null)"' 2>/dev/null)" \
     || [ -z "$made" ]; then
    die "$EXIT_ERROR" "could not create the tracker issue in $host; nothing written"
  fi
  created="${made%% *}"
  labelled="${made##* }"
  # GitHub silently drops labels a caller without push access asks for; an
  # unlabelled tracker would hold tasks no lookup can find.
  if [ "$labelled" != "true" ]; then
    die "$EXIT_ERROR" "created $host#$created but GitHub did not apply the '$LABEL' label (push access needed); add the label to it, or close it, and retry; nothing written"
  fi
  # Two first-use adds can race and both create. Every racer converges on the
  # lowest number (it existed before any later one was created); a racer whose
  # own tracker lost closes it.
  nums="$(trackers_in "$host" "$source")" || exit $?
  canon="$(printf '%s' "$nums" | jq -r '.[0] // empty')"
  [ -n "$canon" ] || canon="$created"
  if [ "$canon" != "$created" ]; then
    gh api -X PATCH "repos/$host/issues/$created" -f state=closed -f state_reason=not_planned \
      >/dev/null 2>&1 || true
  fi
  printf '%s\n' "$canon"
}

# tasks_from HOST SOURCE -> task records (with comment_id/host), one compact
# JSON object per line, for SOURCE in HOST's trackers. Records travel on
# stdin/stdout, never as jq arguments, so a long list cannot hit the OS
# per-argument limit. Exit 4 on any read failure.
tasks_from() {
  local host="$1" source="$2" nums n
  nums="$(trackers_in "$host" "$source")" || exit $?
  for n in $(printf '%s' "$nums" | jq -r '.[]'); do
    tasks_in_tracker "$host" "$n" || exit $?
  done
}

# tasks_in_tracker HOST NUMBER -> the task records in one tracker issue, one
# per line. Exit 4 on a read failure.
tasks_in_tracker() {
  local host="$1" n="$2" raw out
  if ! raw="$(gh api --paginate "repos/$host/issues/$n/comments?per_page=100" --jq '.[]' 2>/dev/null)"; then
    die "$EXIT_UNREADABLE" "could not read comments of $host#$n"
  fi
  out="$(printf '%s\n' "$raw" | jq -c --arg host "$host" '
      . as $c
      | ((.body // "") | try (capture("<!-- owner-task: (?<j>[^\n]*) -->").j | fromjson) catch null) as $t
      | select($t != null and ($t | type) == "object" and ($t.id | type) == "string")
      | $t + {comment_id: $c.id, host: $host}' 2>/dev/null)" \
    || die "$EXIT_UNREADABLE" "could not parse comments of $host#$n"
  [ -z "$out" ] || printf '%s\n' "$out"
}

# render_comment TASK_JSON -> comment body (hidden marker + readable text).
render_comment() {
  local t="$1" marker
  # The marker is one line; "-->" inside a value would end the HTML comment.
  marker="$(printf '%s' "$t" | jq -c '{v: 1, id, repo, what, why, source, created_at, state, done_at, proof}' | sed 's/-->/--\\u003e/g')" || exit $?
  printf '%s' "$t" | jq -r --arg marker "$marker" '
    "<!-- owner-task: \($marker) -->\n"
    + "**Human task `\(.id)`** — " + (if .state == "done" then "done \(.done_at)" else "open" end) + "\n\n"
    + "**What:** \(.what)\n\n"
    + "**Why a person:** \(.why)\n\n"
    + "**Source:** \(.source)\n\n"
    + "**Created:** \(.created_at)"
    + (if .state == "done" then "\n\n**Done:** \(.done_at) — \(.proof)" else "" end)'
}

# ---- subcommands --------------------------------------------------------------
cmd_add() {
  local repo="" what="" why="" source="" tracker id t body
  while [ $# -gt 0 ]; do
    case "$1" in
      --what) [ $# -ge 2 ] || die "$EXIT_USAGE" "--what needs a value"; what="$2"; shift 2 ;;
      --why) [ $# -ge 2 ] || die "$EXIT_USAGE" "--why needs a value"; why="$2"; shift 2 ;;
      --source) [ $# -ge 2 ] || die "$EXIT_USAGE" "--source needs a value"; source="$2"; shift 2 ;;
      --repo) [ $# -ge 2 ] || die "$EXIT_USAGE" "--repo needs a value"; repo="$2"; shift 2 ;;
      *) die "$EXIT_USAGE" "add: unknown argument '$1'" ;;
    esac
  done
  [ -n "$what" ] || die "$EXIT_USAGE" "add: --what is required"
  [ -n "$why" ] || die "$EXIT_USAGE" "add: --why is required (why does this need a person?)"
  [ -n "$source" ] || die "$EXIT_USAGE" "add: --source is required (the thread, PR or issue that raised it)"
  # Secret check before any network call: a hit writes nothing.
  check_text what "$what"
  check_text why "$why"
  check_text source "$source"
  [ -n "$repo" ] || { repo="$(current_repo)" || exit $?; }
  valid_repo "$repo" || die "$EXIT_USAGE" "invalid --repo '$repo'"; repo="$(lower "$repo")"

  resolve_write_location "$repo"
  tracker="$(ensure_tracker "$LOC_REPO" "$repo")" || exit $?
  id="$(new_task_id)" || exit $?
  t="$(jq -cn --arg id "$id" --arg repo "$repo" --arg what "$what" --arg why "$why" \
        --arg source "$source" --arg at "$(now_utc)" \
        '{id: $id, repo: $repo, what: $what, why: $why, source: $source,
          created_at: $at, state: "open", done_at: null, proof: null}')"
  body="$(render_comment "$t")" || exit $?
  if ! gh api -X POST "repos/$LOC_REPO/issues/$tracker/comments" -f body="$body" >/dev/null 2>&1; then
    die "$EXIT_ERROR" "could not write the task to $LOC_REPO#$tracker"
  fi
  printf '%s\n' "$id"
}

cmd_where() {
  local repo="" n nums
  while [ $# -gt 0 ]; do
    case "$1" in
      --repo) [ $# -ge 2 ] || die "$EXIT_USAGE" "--repo needs a value"; repo="$2"; shift 2 ;;
      *) die "$EXIT_USAGE" "where: unknown argument '$1'" ;;
    esac
  done
  [ -n "$repo" ] || { repo="$(current_repo)" || exit $?; }
  valid_repo "$repo" || die "$EXIT_USAGE" "invalid --repo '$repo'"; repo="$(lower "$repo")"
  resolve_write_location "$repo"
  nums="$(trackers_in "$LOC_REPO" "$repo")" || exit $?
  n="$(printf '%s' "$nums" | jq -r '.[0] // empty')"
  if [ -n "$n" ]; then
    printf '%s#%s (%s) — %s\n' "$LOC_REPO" "$n" "$LOC_KIND" "$LOC_WHY"
  else
    printf '%s (%s, tracker not created yet) — %s\n' "$LOC_REPO" "$LOC_KIND" "$LOC_WHY"
  fi
}

# all_hosts -> every repo that may hold a tracker, one per line: repos where
# the operator opened a `human-tasks` issue (search) plus every pointer bucket
# (the search index can lag a just-created tracker). Exit 4 when unreadable.
all_hosts() {
  local raw pointer searched buckets
  # A page GitHub cut short (incomplete_results) would silently drop hosts, so
  # it counts as unreadable.
  # involves:@me, not author:@me: a tracker someone else opened still counts
  # once the operator has added a task (a comment) to it.
  if ! raw="$(gh api --paginate -X GET search/issues -f q="label:$LABEL is:issue is:open involves:@me" \
        -f per_page=100 \
        --jq 'if .incomplete_results then "!incomplete" else (.items[] | .repository_url) end' 2>/dev/null)"; then
    die "$EXIT_UNREADABLE" "could not search for $LABEL trackers"
  fi
  case "$raw" in
    *'!incomplete'*) die "$EXIT_UNREADABLE" "the $LABEL tracker search returned incomplete results" ;;
  esac
  searched="$(printf '%s\n' "$raw" | sed 's|^.*/repos/||' | tr '[:upper:]' '[:lower:]')" \
    || die "$EXIT_UNREADABLE" "could not parse the tracker search"
  pointer="$(pointer_read)" || exit $?
  buckets="$(printf '%s' "$pointer" | jq -r '[.default_bucket // empty, ((.repos // {}) | .[])] | .[] | strings' 2>/dev/null)" \
    || die "$EXIT_UNREADABLE" "pointer file $POINTER_FILE has an unexpected shape"
  printf '%s\n%s\n' "$searched" "$buckets" | awk 'NF' | sort -u
}

# all_trackers_in HOST -> issue numbers of every open tracker in HOST, whatever
# source repo it is for, one per line (one issue listing per host). Each task
# record carries its own repo, so the source need not be known here.
all_trackers_in() {
  local host="$1" raw nums
  raw="$(open_labelled_issues "$host")" || exit $?
  nums="$(printf '%s' "$raw" | jq -r --arg title "$TRACKER_TITLE" '
    .[] | select(.pull_request == null)
    | select(((.body // "") | test("<!-- owner-task-tracker: ")) or .title == $title)
    | .number' 2>/dev/null)" || die "$EXIT_UNREADABLE" "could not parse issues of $host"
  printf '%s\n' "$nums" | awk 'NF' | sort -n
}

cmd_list() {
  local repo="" all=0 json=0 every=0 tasks="" host n t hosts nums locs
  while [ $# -gt 0 ]; do
    case "$1" in
      --all) all=1; shift ;;
      --json) json=1; shift ;;
      --all-repos) every=1; shift ;;
      --repo) [ $# -ge 2 ] || die "$EXIT_USAGE" "--repo needs a value"; repo="$2"; shift 2 ;;
      *) die "$EXIT_USAGE" "list: unknown argument '$1'" ;;
    esac
  done
  if [ "$every" -eq 1 ] && [ -n "$repo" ]; then
    die "$EXIT_USAGE" "list: --repo and --all-repos are exclusive"
  fi

  if [ "$every" -eq 1 ]; then
    # Every tracker found: one issue listing per host, then each tracker's
    # comments once; each task record names its own source repo.
    hosts="$(all_hosts)" || exit $?
    for host in $hosts; do
      valid_repo "$host" || die "$EXIT_UNREADABLE" "pointer file names an invalid bucket '$host'"
      nums="$(all_trackers_in "$host")" || exit $?
      for n in $nums; do
        t="$(tasks_in_tracker "$host" "$n")" || exit $?
        tasks="$tasks$t"$'\n'
      done
    done
  else
    [ -n "$repo" ] || { repo="$(current_repo)" || exit $?; }
    valid_repo "$repo" || die "$EXIT_USAGE" "invalid --repo '$repo'"; repo="$(lower "$repo")"
    locs="$(read_locations "$repo")" || exit $?
    for host in $locs; do
      valid_repo "$host" || die "$EXIT_UNREADABLE" "pointer file names an invalid bucket '$host'"
      t="$(tasks_from "$host" "$repo")" || exit $?
      tasks="$tasks$t"$'\n'
    done
  fi

  # Dedupe by id (a task is read once even if two trackers carry it), keep the
  # pinned shape only, oldest first. Records arrive on stdin, one per line.
  tasks="$(printf '%s' "$tasks" | jq -cs --argjson all "$all" '
    group_by(.id) | map(.[0])
    | map(select($all == 1 or .state == "open"))
    | map({id, repo, what, why, source, created_at, state,
           done_at: (.done_at // null), proof: (.proof // null)})
    | sort_by(.created_at, .id)')"

  if [ "$json" -eq 1 ]; then
    printf '%s\n' "$tasks"
    return 0
  fi
  if [ "$(printf '%s' "$tasks" | jq 'length')" -eq 0 ]; then
    echo "No human tasks."
    return 0
  fi
  printf '%s' "$tasks" | jq -r '.[]
    | "\(.id)  [\(.state)]  \(.created_at[0:10])  \(.repo)\n    what:   \(.what)\n    why:    \(.why)\n    source: \(.source)"
      + (if .state == "done" then "\n    done:   \(.done_at) — \(.proof)" else "" end)'
}

cmd_done() {
  local id="" proof="" by="agent" repo="" host tasks match cid t body now locs hvis
  while [ $# -gt 0 ]; do
    case "$1" in
      --proof) [ $# -ge 2 ] || die "$EXIT_USAGE" "--proof needs a value"; proof="$2"; shift 2 ;;
      --by) [ $# -ge 2 ] || die "$EXIT_USAGE" "--by needs a value"; by="$2"; shift 2 ;;
      --repo) [ $# -ge 2 ] || die "$EXIT_USAGE" "--repo needs a value"; repo="$2"; shift 2 ;;
      -*) die "$EXIT_USAGE" "done: unknown argument '$1'" ;;
      *) [ -z "$id" ] || die "$EXIT_USAGE" "done: one task id only"; id="$1"; shift ;;
    esac
  done
  [ -n "$id" ] || die "$EXIT_USAGE" "done: a task id is required"
  [[ $id =~ ^ht-[0-9a-f]{8}$ ]] || die "$EXIT_USAGE" "done: '$id' is not a task id (ht-xxxxxxxx)"
  case "$by" in agent|operator) ;; *) die "$EXIT_USAGE" "--by must be agent or operator" ;; esac
  if [ -z "$proof" ] && [ "$by" != "operator" ]; then
    die "$EXIT_NO_PROOF" "done $id refused: an agent must pass --proof naming the check it ran (or the operator passes --by operator); nothing changed"
  fi
  # Every write needs the checker, even an operator completion with no proof.
  load_secret_checker
  [ -z "$proof" ] || check_text proof "$proof"
  [ -n "$repo" ] || { repo="$(current_repo)" || exit $?; }
  valid_repo "$repo" || die "$EXIT_USAGE" "invalid --repo '$repo'"; repo="$(lower "$repo")"

  match=""
  locs="$(read_locations "$repo")" || exit $?
  for host in $locs; do
    valid_repo "$host" || die "$EXIT_UNREADABLE" "pointer file names an invalid bucket '$host'"
    tasks="$(tasks_from "$host" "$repo")" || exit $?
    match="$(printf '%s\n' "$tasks" | jq -cs --arg id "$id" 'map(select(.id == $id)) | .[0] // empty')"
    [ -n "$match" ] && break
  done
  [ -n "$match" ] || die "$EXIT_ERROR" "task $id not found for $repo"

  if [ "$(printf '%s' "$match" | jq -r .state)" = "done" ]; then
    printf '%s already done\n' "$id"
    return 0
  fi
  [ -n "$proof" ] || proof="marked done by the operator"
  now="$(now_utc)"
  t="$(printf '%s' "$match" | jq -c --arg at "$now" --arg proof "$proof" \
        '.state = "done" | .done_at = $at | .proof = $proof')"
  cid="$(printf '%s' "$match" | jq -r .comment_id)"
  host="$(printf '%s' "$match" | jq -r .host)"
  # Never write task text (the proof included) to a repo anyone can read, even
  # one whose tracker predates it turning public.
  hvis="$(repo_visibility "$host")" || exit $?
  if [ "$hvis" != "private" ]; then
    die "$EXIT_NO_LOCATION" "task $id lives in $host, which is $hvis; refusing to write task text there (move it to a private bucket); nothing changed"
  fi
  body="$(render_comment "$t")" || exit $?
  if ! gh api -X PATCH "repos/$host/issues/comments/$cid" -f body="$body" >/dev/null 2>&1; then
    die "$EXIT_ERROR" "could not update task $id in $host"
  fi
  printf '%s done\n' "$id"
}

main() {
  [ $# -gt 0 ] || { usage >&2; exit "$EXIT_USAGE"; }
  local sub="$1"; shift
  case "$sub" in
    -h|--help|help) usage; exit "$EXIT_OK" ;;
    add) cmd_add "$@" ;;
    list) cmd_list "$@" ;;
    done) cmd_done "$@" ;;
    where) cmd_where "$@" ;;
    *) usage >&2; exit "$EXIT_USAGE" ;;
  esac
}

main "$@"
