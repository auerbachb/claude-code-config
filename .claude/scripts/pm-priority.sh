#!/usr/bin/env bash
# pm-priority.sh — The operator's backlog order for /pm: record it, show it, overlay it.
# catalog: backlog-pm — Operator backlog priority for `/pm` (`<main-root>/.claude/pm-priority.json`) — `/desk` records `top`/`bump`/`park`/`drop`, `/pm` overlays it on its ranking with `apply`
#
# PURPOSE
#   The one reader and writer of a repo's operator-priority file (issue #1767).
#   `/desk` records the operator's intent with the write verbs; `/pm` reads it
#   back with `apply`, which puts the operator's order ahead of its own OKR-aware
#   ranking and removes parked issues. The overlay never re-scores anything, so
#   dropping an issue from the file restores its ranked position by
#   construction. The file is optional: absent means no override.
#
# FILE
#   <main-root>/.claude/pm-priority.json — per repo, next to pm-config.md, at the
#   MAIN checkout's root (repo-root.sh), so every linked worktree of one repo
#   reads the same file. It is runtime state, never committed: a tracked copy
#   would dirty main on every write.
#     {"version": 1,
#      "order":  [12, 4],                       operator order, issue numbers
#      "parked": {"7": {"until": "2026-10-09",  YYYY-MM-DD, America/New_York
#                       "parked_at": "<ISO 8601 UTC>"}},
#      "updated_at": "<ISO 8601 UTC>"}
#   Read rules: absent is no override; anything that is not this shape (bad
#   JSON, wrong types, an issue listed twice, an issue both ordered and parked)
#   is UNREADABLE and is never overwritten. Unknown top-level fields survive a
#   write. A parked issue is excluded while today (America/New_York) is earlier
#   than its `until` date and returns ON that date; expired entries are ignored
#   on read and pruned on the next write.
#
# USAGE
#   pm-priority.sh [GLOBAL FLAGS] top N [N ...]
#   pm-priority.sh [GLOBAL FLAGS] bump N
#   pm-priority.sh [GLOBAL FLAGS] park N --until DATE
#   pm-priority.sh [GLOBAL FLAGS] drop N
#   pm-priority.sh [GLOBAL FLAGS] show [--json]
#   pm-priority.sh [GLOBAL FLAGS] apply [--json]  < ranked issue numbers
#   pm-priority.sh --help | -h
#
#   N is an issue number, with or without a leading `#`.
#
# VERBS
#   top N...  Replace the operator order with these issues, in this order
#             (duplicates dropped), and unpark them.
#   bump N    Move N to the head of the order (inserting it if absent); unpark it.
#   park N    Take N out of the order and park it until DATE (required
#             --until). DATE is `tomorrow`, `+N` / `+Nd` (days from today), a
#             weekday name (`mon`…`sunday`: its next occurrence after today), or
#             YYYY-MM-DD. It must be later than today.
#   drop N    Remove N from the order and from the parked set. Dropping an
#             issue that is in neither changes nothing.
#   show      Print the active order and the active parks (--json: one object
#             with file, repo, present, today, order, parked, updated_at).
#   apply     Read the eligible ranked issue numbers on stdin, one per line,
#             best first (blank lines ignored). Print them overlaid: the
#             operator-ordered ones first, in operator order, then the rest in
#             input order; parked ones removed. Text: one line per issue,
#             `<N><TAB>override<TAB><k>` or `<N><TAB>ranked<TAB>-`, where k is
#             the row's place among the override rows. --json adds `parked`
#             (every active park, with `in_input`) and `not_eligible` (ordered
#             issues absent from stdin — reported, never added).
#
#   Each write verb prints one line naming the change, then the `show` text.
#
# GLOBAL FLAGS
#   --dir PATH          A checkout (or linked worktree) of the target repo.
#                       Default: the current directory.
#   --repo OWNER/NAME   Target this repo. Its checkout is --dir when given
#                       (verified against its origin), else the current
#                       directory when its origin matches, else the repo's
#                       `root_repo` recorded in session state when that path
#                       still exists and its origin matches.
#   --today YYYY-MM-DD  Use this as today instead of the America/New_York
#                       calendar date (tests).
#
# EXIT STATUS
#   0  Success, including an absent file (no override).
#   2  Usage error: unknown verb or flag, bad issue number, bad or past date,
#      malformed stdin for apply.
#   3  Target unresolved: not inside a git checkout, no local checkout of
#      --repo found, or --dir's origin is another repo.
#   4  The priority file is unreadable (see FILE); it was not modified.
#   5  Write failure (directory, temp file, or rename).
#   6  Lock timeout, or the lock was broken mid-write (state-lock.sh); the
#      file is unchanged — retry.
#
# EXAMPLES
#   pm-priority.sh top 42 38
#   pm-priority.sh --repo auerbachb/sales-kit park 12 --until friday
#   printf '%s\n' 55 42 61 38 | pm-priority.sh apply --json
#
# DEPENDENCIES
#   jq, git, date (GNU or BSD); siblings repo-root.sh, state-lock.sh, and
#   (for --repo) session-state.sh.

set -uo pipefail
printf '%s\t%s\t%s\n' "$(date -u +%FT%TZ)" "$(basename "$0")" "${*//$'\n'/ }" 2>/dev/null >> "$HOME/.claude/script-usage.log" || true

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ME="pm-priority.sh"
ET_TZ="America/New_York"

print_help() {
  sed -n '/^# PURPOSE$/,/^$/{/^$/d;p;}' "$0" | sed 's/^# \{0,1\}//'
}

die() { local code="$1"; shift; echo "$ME: $*" >&2; exit "$code"; }
usage_err() { die 2 "$* (run with --help)"; }

# ---------------------------------------------------------------- dates (ET)

# is_ymd DATE — a real calendar date in YYYY-MM-DD form (round-trips through date).
is_ymd() {
  local d="$1" out=""
  [[ "$d" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || return 1
  out=$(TZ="$ET_TZ" date -d "$d" '+%Y-%m-%d' 2>/dev/null) \
    || out=$(TZ="$ET_TZ" date -jf '%Y-%m-%d' "$d" '+%Y-%m-%d' 2>/dev/null) \
    || out=""
  [[ "$out" == "$d" ]]
}

# date_add DATE DAYS — DATE plus DAYS calendar days (same GNU/BSD pair as workday.sh).
date_add() {
  local out=""
  out=$(TZ="$ET_TZ" date -d "$1 + $2 days" '+%Y-%m-%d' 2>/dev/null) \
    || out=$(TZ="$ET_TZ" date -jf '%Y-%m-%d' -v+"$2"d "$1" '+%Y-%m-%d' 2>/dev/null) \
    || out=""
  [[ "$out" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || return 1
  printf '%s' "$out"
}

# weekday_num DATE — 1 (Monday) … 7 (Sunday).
weekday_num() {
  local out=""
  out=$(TZ="$ET_TZ" date -d "$1" '+%u' 2>/dev/null) \
    || out=$(TZ="$ET_TZ" date -jf '%Y-%m-%d' "$1" '+%u' 2>/dev/null) \
    || out=""
  [[ "$out" =~ ^[1-7]$ ]] || return 1
  printf '%s' "$out"
}

# resolve_until SPEC — the park date for SPEC, relative to $TODAY.
resolve_until() {
  local spec target delta lower
  lower=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')
  case "$lower" in
    tomorrow) date_add "$TODAY" 1; return ;;
    mon|monday) target=1 ;;
    tue|tues|tuesday) target=2 ;;
    wed|wednesday) target=3 ;;
    thu|thur|thurs|thursday) target=4 ;;
    fri|friday) target=5 ;;
    sat|saturday) target=6 ;;
    sun|sunday) target=7 ;;
    *)
      if [[ "$lower" =~ ^\+([0-9]{1,4})d?$ ]]; then
        spec=$((10#${BASH_REMATCH[1]}))
        (( spec >= 1 )) || return 1
        date_add "$TODAY" "$spec"
        return
      fi
      is_ymd "$lower" || return 1
      printf '%s' "$lower"
      return
      ;;
  esac
  local today_n
  today_n=$(weekday_num "$TODAY") || return 1
  delta=$(( (target - today_n + 7) % 7 ))
  (( delta == 0 )) && delta=7
  date_add "$TODAY" "$delta"
}

# ------------------------------------------------------------- repo target

# key_from_url URL — lowercase owner/name, the same derivation session-state.sh uses.
key_from_url() {
  local url="${1%.git}" name owner_path owner
  url="${url%/}"
  url="${url##*://}"
  url="${url##*@}"
  url="${url/:/\/}"
  name="${url##*/}"
  owner_path="${url%/*}"
  owner="${owner_path##*/}"
  [[ -n "$owner" && -n "$name" && "$owner_path" != "$url" ]] || return 1
  printf '%s/%s' "$owner" "$name" | tr '[:upper:]' '[:lower:]'
}

origin_key_of() {
  local url=""
  [[ -d "$1" ]] || return 1
  url=$(git -C "$1" remote get-url origin 2>/dev/null) || return 1
  key_from_url "$url"
}

# resolve_target — sets ROOT, FILE (and REPO_KEY when known) from the globals.
resolve_target() {
  local dir="${OPT_DIR:-}" key="" have="" recorded=""
  if [[ -n "$OPT_REPO" ]]; then
    [[ "$OPT_REPO" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]] \
      || usage_err "--repo must look like owner/name (got: $OPT_REPO)"
    key=$(printf '%s' "${OPT_REPO%.git}" | tr '[:upper:]' '[:lower:]')
    if [[ -n "$dir" ]]; then
      [[ -d "$dir" ]] || die 3 "--dir is not a directory: $dir"
      have=$(origin_key_of "$dir") || have=""
      [[ "$have" == "$key" ]] || die 3 "--dir $dir is a checkout of ${have:-no GitHub repo}, not $key"
    elif have=$(origin_key_of "$PWD") && [[ "$have" == "$key" ]]; then
      dir="$PWD"
    else
      if [[ -x "$SCRIPT_DIR/session-state.sh" ]]; then
        recorded=$("$SCRIPT_DIR/session-state.sh" --repo "$key" --get .root_repo 2>/dev/null) || recorded=""
      fi
      if [[ -n "$recorded" && "$recorded" != "null" && -d "$recorded" ]] \
         && have=$(origin_key_of "$recorded") && [[ "$have" == "$key" ]]; then
        dir="$recorded"
      else
        die 3 "no local checkout of $key found (checked the current directory and session state's root_repo); pass --dir <checkout>"
      fi
    fi
    REPO_KEY="$key"
  fi
  dir="${dir:-$PWD}"
  [[ -d "$dir" ]] || die 3 "not a directory: $dir"
  [[ -x "$SCRIPT_DIR/repo-root.sh" ]] || die 3 "repo-root.sh not found next to $ME — cannot resolve the main checkout"
  local root rc=0
  root=$("$SCRIPT_DIR/repo-root.sh" "$dir" 2>/dev/null) || rc=$?
  if [[ $rc -ne 0 || -z "$root" || ! -d "$root" ]]; then
    die 3 "not inside a git checkout (repo-root.sh exit $rc): $dir"
  fi
  ROOT="$root"
  FILE="$ROOT/.claude/pm-priority.json"
  if [[ -z "$REPO_KEY" ]]; then
    REPO_KEY=$(origin_key_of "$ROOT") || REPO_KEY=""
  fi
}

# ------------------------------------------------------------------ the file

# The shape check. Prints "" for a readable document, else the first problem.
JQ_PROBLEM='
def ints: (.order // []);
if type != "object" then "not a JSON object"
elif has("version") and .version != 1 then "unsupported version \(.version | tojson)"
elif (ints | type) != "array" then "order is not an array"
elif any(ints | .[]; (type != "number") or . < 1 or . != floor) then "order holds something that is not an issue number"
elif (ints | length) != (ints | unique | length) then "order lists an issue twice"
elif ((.parked // {}) | type) != "object" then "parked is not an object"
elif any((.parked // {}) | to_entries[];
         (.key | test("^[1-9][0-9]*$") | not)
         or ((.value | type) != "object")
         or ((.value.until | type) != "string")
         or (.value.until | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}$") | not))
  then "a parked entry is not {\"<issue>\": {\"until\": \"YYYY-MM-DD\"}}"
elif ([ints | .[] | tostring] - ((.parked // {}) | keys) | length) != (ints | length)
  then "an issue is both ordered and parked"
else "" end'

# load_doc — sets DOC (the file's JSON, or {} when absent) and PRESENT (0/1).
# Exits 4 on an unreadable file.
load_doc() {
  PRESENT=0
  DOC='{}'
  [[ -e "$FILE" ]] || return 0
  PRESENT=1
  local raw problem rc=0
  raw=$(cat "$FILE" 2>/dev/null) || die 4 "priority file unreadable: cannot read $FILE"
  problem=$(printf '%s' "$raw" | jq -r "$JQ_PROBLEM" 2>/dev/null) || rc=$?
  if [[ $rc -ne 0 ]]; then
    die 4 "priority file unreadable: $FILE is not valid JSON"
  fi
  [[ -z "$problem" ]] || die 4 "priority file unreadable: $FILE — $problem"
  DOC="$raw"
}

# The active view of DOC for $today: order, and parks still in force.
JQ_VIEW='
{ order: (.order // []),
  parked: [ (.parked // {}) | to_entries[] | select(.value.until > $today)
            | {issue: (.key | tonumber), until: .value.until} ] | sort_by(.issue),
  updated_at: (.updated_at // null) }'

render_show_text() { # $1 = view JSON
  local where="$ROOT"
  [[ -n "${REPO_KEY:-}" ]] && where="$REPO_KEY ($ROOT)"
  printf '%s' "$1" | jq -r --arg where "$where" --arg today "$TODAY" '
    "Operator priority — \($where), as of \($today):",
    "  Order:  " + (if (.order | length) == 0 then "none"
                    else (.order | map("#\(.)") | join(", ")) end),
    "  Parked: " + (if (.parked | length) == 0 then "none"
                    else (.parked | map("#\(.issue) until \(.until)") | join(", ")) end)'
}

# ----------------------------------------------------------------- arguments

OPT_DIR=""
OPT_REPO=""
OPT_TODAY=""
REPO_KEY=""

for a in "$@"; do
  case "$a" in -h|--help) print_help; exit 0 ;; esac
done

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dir)   [[ $# -ge 2 && -n "${2-}" ]] || usage_err "--dir requires a path";        OPT_DIR="$2"; shift 2 ;;
    --repo)  [[ $# -ge 2 && -n "${2-}" ]] || usage_err "--repo requires owner/name";    OPT_REPO="$2"; shift 2 ;;
    --today) [[ $# -ge 2 && -n "${2-}" ]] || usage_err "--today requires YYYY-MM-DD";   OPT_TODAY="$2"; shift 2 ;;
    --*)     usage_err "unknown flag: $1" ;;
    *)       break ;;
  esac
done

[[ $# -ge 1 ]] || usage_err "a verb is required: top, bump, park, drop, show, or apply"
VERB="$1"; shift

command -v jq >/dev/null 2>&1 || die 5 "jq is required"

if [[ -n "$OPT_TODAY" ]]; then
  is_ymd "$OPT_TODAY" || usage_err "--today must be a real YYYY-MM-DD date (got: $OPT_TODAY)"
  TODAY="$OPT_TODAY"
else
  TODAY=$(TZ="$ET_TZ" date '+%Y-%m-%d')
fi

# issue_num TOKEN — the issue number in N or #N, else a usage error.
issue_num() {
  local t="${1#\#}"
  [[ "$t" =~ ^[1-9][0-9]{0,8}$ ]] || usage_err "not an issue number: $1"
  printf '%s' "$t"
}

JSON_OUT=0
NUMS=()
UNTIL_SPEC=""
case "$VERB" in
  top)
    [[ $# -ge 1 ]] || usage_err "top needs at least one issue"
    for a in "$@"; do n=$(issue_num "$a") || exit 2; NUMS+=("$n"); done
    ;;
  bump|drop)
    [[ $# -eq 1 ]] || usage_err "$VERB takes exactly one issue"
    n=$(issue_num "$1") || exit 2
    NUMS+=("$n")
    ;;
  park)
    [[ $# -ge 1 ]] || usage_err "park needs an issue and --until DATE"
    n=$(issue_num "$1") || exit 2
    NUMS+=("$n")
    shift
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --until) [[ $# -ge 2 && -n "${2-}" ]] || usage_err "--until requires a date"; UNTIL_SPEC="$2"; shift 2 ;;
        *) usage_err "unexpected argument to park: $1" ;;
      esac
    done
    [[ -n "$UNTIL_SPEC" ]] || usage_err "park needs --until DATE"
    ;;
  show|apply)
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --json) JSON_OUT=1; shift ;;
        *) usage_err "unexpected argument to $VERB: $1" ;;
      esac
    done
    ;;
  *) usage_err "unknown verb: $VERB" ;;
esac

# ------------------------------------------------------------------- reads

if [[ "$VERB" == "apply" ]]; then
  # Parse stdin before touching the file, so a malformed list is a usage error
  # whatever the file's state.
  INPUT=()
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line//[[:space:]]/}"
    [[ -n "$line" ]] || continue
    n=$(issue_num "$line") || exit 2
    INPUT+=("$n")
  done
fi

resolve_target
load_doc

VIEW=$(printf '%s' "$DOC" | jq -c --arg today "$TODAY" "$JQ_VIEW") || die 4 "priority file unreadable: $FILE"

if [[ "$VERB" == "show" ]]; then
  if [[ "$JSON_OUT" -eq 1 ]]; then
    printf '%s' "$VIEW" | jq -c --arg file "$FILE" --arg repo "${REPO_KEY:-}" --arg today "$TODAY" \
      --argjson present "$PRESENT" \
      '{file: $file, repo: (if $repo == "" then null else $repo end), present: ($present == 1),
        today: $today, order, parked, updated_at}'
  else
    render_show_text "$VIEW"
  fi
  exit 0
fi

if [[ "$VERB" == "apply" ]]; then
  IN_JSON=$(printf '%s\n' ${INPUT[@]+"${INPUT[@]}"} | jq -cs '[.[] | numbers]') || die 2 "could not read the ranked list"
  RESULT=$(printf '%s' "$VIEW" | jq -c --argjson in "$IN_JSON" --arg today "$TODAY" --argjson present "$PRESENT" '
    def has_num($n): any(.[]; . == $n);
    (reduce $in[] as $x ([]; if has_num($x) then . else . + [$x] end)) as $input
    | ([.parked[].issue]) as $pk
    | ($input | map(. as $n | select($pk | has_num($n) | not))) as $elig
    | (.order | map(. as $n | select($elig | has_num($n)))) as $ov
    | ($elig | map(. as $n | select($ov | has_num($n) | not))) as $rest
    | { today: $today, present: ($present == 1),
        order: ([ $ov | to_entries[] | {issue: .value, source: "override", position: (.key + 1)} ]
                + [ $rest[] | {issue: ., source: "ranked", position: null} ]),
        parked: [ .parked[] | . + {in_input: (.issue as $n | $input | has_num($n))} ],
        not_eligible: [ .order | to_entries[] | select(.value as $n | $input | has_num($n) | not)
                        | {issue: .value, position: (.key + 1)} ] }') \
    || die 4 "could not overlay the priority file: $FILE"
  if [[ "$JSON_OUT" -eq 1 ]]; then
    printf '%s\n' "$RESULT"
  else
    printf '%s' "$RESULT" | jq -r '.order[] | "\(.issue)\t\(.source)\t\(.position // "-")"'
  fi
  exit 0
fi

# ------------------------------------------------------------------ writes

UNTIL=""
if [[ "$VERB" == "park" ]]; then
  UNTIL=$(resolve_until "$UNTIL_SPEC") || usage_err "not a park date: $UNTIL_SPEC (use tomorrow, +Nd, a weekday, or YYYY-MM-DD)"
  [[ "$UNTIL" > "$TODAY" ]] || usage_err "the park date must be later than today ($TODAY): $UNTIL"
fi

NUMS_JSON=$(printf '%s\n' ${NUMS[@]+"${NUMS[@]}"} | jq -cs '.') || die 2 "could not read the issue list"
NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)

[[ -f "$SCRIPT_DIR/state-lock.sh" ]] || die 5 "state-lock.sh not found next to $ME"
# shellcheck source=state-lock.sh
source "$SCRIPT_DIR/state-lock.sh"

mkdir -p "$ROOT/.claude" 2>/dev/null || die 5 "cannot create $ROOT/.claude"
state_lock_acquire "$FILE" || die "$STATE_LOCK_EXIT_TIMEOUT" "timed out waiting for the lock on $FILE (unchanged, retry)"

# Re-read under the lock: the pre-lock read only resolved the target.
load_doc
OLD_VIEW=$(printf '%s' "$DOC" | jq -c --arg today "$TODAY" "$JQ_VIEW") || { state_lock_release; die 4 "priority file unreadable: $FILE"; }

NEW=$(printf '%s' "$DOC" | jq -c --arg verb "$VERB" --argjson nums "$NUMS_JSON" \
      --arg until "$UNTIL" --arg today "$TODAY" --arg now "$NOW" '
  def has_num($n): any(.[]; . == $n);
  def without($ns): map(. as $x | select($ns | has_num($x) | not));
  (reduce $nums[] as $x ([]; if has_num($x) then . else . + [$x] end)) as $ns
  | .order = (.order // [])
  | .parked = ((.parked // {}) | with_entries(select(.value.until > $today)))
  | if $verb == "top" then
      .order = $ns | .parked |= with_entries(select(.key | tonumber as $k | $ns | has_num($k) | not))
    elif $verb == "bump" then
      .order = ($ns + (.order | without($ns))) | del(.parked[$ns[0] | tostring])
    elif $verb == "park" then
      .order = (.order | without($ns)) | .parked[$ns[0] | tostring] = {until: $until, parked_at: $now}
    else
      .order = (.order | without($ns)) | del(.parked[$ns[0] | tostring])
    end
  | ({version: 1} + .) | .version = 1 | .updated_at = $now') \
  || { state_lock_release; die 5 "could not apply $VERB to $FILE"; }

VIEW=$(printf '%s' "$NEW" | jq -c --arg today "$TODAY" "$JQ_VIEW") || { state_lock_release; die 5 "could not read back the new state"; }

# Nothing to keep and nothing on disk: do not create a file to say so.
if [[ "$PRESENT" -eq 0 ]] && printf '%s' "$NEW" | jq -e '(.order | length) == 0 and (.parked | length) == 0' >/dev/null 2>&1; then
  state_lock_release
else
  TMP_FILE=$(mktemp "$FILE.XXXXXX") || { state_lock_release; die 5 "cannot create a temp file next to $FILE"; }
  if ! printf '%s\n' "$NEW" | jq '.' > "$TMP_FILE"; then
    rm -f "$TMP_FILE"
    state_lock_release
    die 5 "cannot write $TMP_FILE"
  fi
  commit_rc=0
  state_lock_commit "$TMP_FILE" "$FILE" || commit_rc=$?
  state_lock_release
  [[ $commit_rc -eq 0 ]] || exit "$commit_rc"
fi

N1="${NUMS[0]}"
case "$VERB" in
  top)  echo "Order set: $(printf '%s\n' ${NUMS[@]+"${NUMS[@]}"} | awk '!seen[$0]++ {printf "%s#%s", (n++ ? ", " : ""), $0}')" ;;
  bump)
    if printf '%s' "$OLD_VIEW" | jq -e --argjson n "$N1" '.order | any(.[]; . == $n)' >/dev/null 2>&1; then
      echo "#$N1 moved to the head of the order"
    else
      echo "#$N1 added at the head of the order"
    fi
    ;;
  park) echo "#$N1 parked until $UNTIL" ;;
  drop)
    if printf '%s' "$OLD_VIEW" | jq -e --argjson n "$N1" '(.order | any(.[]; . == $n)) or (.parked | any(.[]; .issue == $n))' >/dev/null 2>&1; then
      echo "#$N1 dropped from the override"
    else
      echo "#$N1 was not in the override; nothing changed"
    fi
    ;;
esac
render_show_text "$VIEW"
exit 0
