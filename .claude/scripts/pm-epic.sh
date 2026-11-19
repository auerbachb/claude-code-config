#!/usr/bin/env bash
# pm-epic.sh — Read the children of an epic the operator named with `/pm epic #N`, and close it when they are done.
# catalog: backlog-pm — `/pm epic #N` (issue #2545): parse the epic argument, read a named parent's same-repo children from its `## Increment chain` checklist, GitHub sub-issues and `#N` task-list items, and close the parent once every child is verified closed
#
# PURPOSE
#   `/pm epic #N` scopes a /pm thread to one parent's children. Only the
#   operator naming the issue makes it an epic: this script never looks at a
#   title, label or keyword, and is only ever called with the number the
#   operator typed. It answers two questions /pm needs:
#     - which issues are this parent's children, and which are still open
#     - are they all closed yet (and, if so, close the parent)
#
# CHILDREN — read from the parent itself, same repository only
#   1. Every task-list line in the parent's body whose item is an issue
#      reference: `- [ ] #12`, `* [x] #12 title`. This covers the
#      `## Increment chain` checklist /subagent Step 5.1 writes (source
#      `increment-chain`) and any other task list (source `task-list`).
#      `owner/repo#12` never matches: other-repo children are out of scope.
#   2. GitHub sub-issues (`repos/<repo>/issues/<N>/sub_issues`), same-repo
#      only. Not every token can read them: a failed read is reported as
#      `"sub_issues": "unavailable"` and the checklist and task list stand.
#   Lines inside fenced code blocks (``` or ~~~) are examples, never children.
#   Only a top-level task-list item counts: 0-3 spaces of indent, no leading
#   tab. Anything indented 4+ (indented code, content nested in a list item,
#   a fence inside a list item) is never a child — a deliberately conservative
#   rule instead of a CommonMark emulator. Nested sub-task children are out of
#   scope for this increment.
#   The parent itself, pull requests and missing numbers are never children
#   (missing ones are listed under `missing`).
#
# USAGE
#   pm-epic.sh parse-arg TOKEN
#   pm-epic.sh children <owner/repo> <N>
#   pm-epic.sh close-if-done <owner/repo> <N>
#   pm-epic.sh --help | -h
#
# VERBS
#   parse-arg      TOKEN is the word after `epic`: `#123` or `123`. Prints the
#                  number. Exit 2 (one-line error on stderr) for anything else,
#                  an empty token included.
#   children       prints one JSON object:
#                    {"repo", "epic", "title", "state": "OPEN"|"CLOSED",
#                     "sub_issues": "read"|"unavailable",
#                     "children": [{"number","title","state","sources":[...]}],
#                     "open": [N...], "closed": [N...], "missing": [N...]}
#                  children are in first-seen order (checklist/task list in
#                  body order, then sub-issues).
#   close-if-done  re-reads the children from GitHub (never a cached list)
#                  and, when there is at least one child and every child is
#                  CLOSED, re-reads them once more immediately before the
#                  close call and closes the parent with a comment naming them.
#                  It never closes on a partial child list: when the
#                  sub-issues read failed, or a listed child cannot be found
#                  (`missing`), it exits 1 and leaves the parent open.
#                  A parent already closed is checked the same way: it prints
#                  `already-closed #N` only when every child reads CLOSED, and
#                  `discrepancy #N closed with j of k children open` (exit 1)
#                  otherwise. Other output: `closed #N (k children)` or
#                  `open #N (j of k children open)`.
#
# EXIT CODES
#   0  success (children: the parent is open and has at least one child)
#   1  a GitHub read or the close failed
#   2  usage error
#   3  the issue does not exist (or is a pull request)
#   4  the issue is closed (children: the JSON is still printed)
#   5  the issue has no children (children: the JSON is still printed)
#   6  children: a listed child cannot be found (`missing` is non-empty; the
#      JSON is still printed) — the child list is incomplete, so a caller
#      must not bind or work it

set -uo pipefail

usage() { sed -n '2,/^set -uo/{/^set -uo/d;s/^# \{0,1\}//;p;}' "$0"; }

die() { printf 'pm-epic.sh: %s\n' "$2" >&2; exit "$1"; }

parse_arg() {
  local token="${1:-}"
  if [[ "$token" =~ ^#?([1-9][0-9]{0,8})$ ]]; then
    printf '%s\n' "${BASH_REMATCH[1]}"
    return 0
  fi
  if [[ -z "$token" ]]; then
    die 2 '/pm epic needs an issue number, e.g. /pm epic #123'
  fi
  die 2 "/pm epic needs an issue number, e.g. /pm epic #123 (got '$token')"
}

valid_repo() { [[ "$1" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]]; }

# fetch_issue REPO N -> JSON {number,title,state,body,is_pr} on stdout.
# Returns 3 when GitHub says it does not exist, 1 on any other failure.
fetch_issue() {
  local repo="$1" n="$2" out err rc=0
  err=$(mktemp) || return 1
  out=$(gh api "repos/$repo/issues/$n" 2>"$err") || rc=$?
  if [[ "$rc" -ne 0 ]]; then
    if grep -qiE 'HTTP 404|Not Found' "$err"; then rm -f "$err"; return 3; fi
    rm -f "$err"; return 1
  fi
  rm -f "$err"
  jq -ce '{number, title: (.title // ""), state: ((.state // "") | ascii_upcase),
           body: (.body // ""), is_pr: (has("pull_request") and .pull_request != null)}' \
    <<< "$out" 2>/dev/null || return 1
}

# body_children BODY N -> lines "number<TAB>source", body order, deduplicated by awk caller.
body_children() {
  local body="$1" self="$2"
  printf '%s\n' "$body" | tr -d '\r' | awk -v self="$self" '
    # CommonMark fences: a marker counts only with 0-3 spaces of indent; a
    # backtick opener has no backtick in its info string; a fence closes only on a
    # marker of the same character, at least as long as the opener, with
    # nothing but whitespace after it.
    match($0, /^ ? ? ?(```+|~~~+)/) {
      run = substr($0, RSTART, RLENGTH)
      sub(/^ */, "", run)
      ch = substr(run, 1, 1)
      tail = substr($0, RSTART + RLENGTH)
      if (!fence) {
        # A backtick in the info string of a backtick opener: no fence opens.
        if (!(ch == "`" && index(tail, "`"))) { fence = 1; fch = ch; flen = length(run); next }
      } else {
        if (ch == fch && length(run) >= flen && tail ~ /^[[:space:]]*$/) fence = 0
        next
      }
    }
    fence { next }
    /^##[[:space:]]/ { chain = ($0 ~ /^##[[:space:]]+Increment chain[[:space:]]*$/) }
    {
      # Top-level items only: 0-3 spaces, no tab. 4+ is indented code or
      # content nested in a list item (where a fence may hide an example).
      if (match($0, /^ ? ? ?[-*+][[:space:]]+\[[ xX]\][[:space:]]+#[0-9]+/)) {
        item = substr($0, RSTART, RLENGTH)
        sub(/.*#/, "", item)
        rest = substr($0, RSTART + RLENGTH, 1)
        if (rest ~ /[0-9A-Za-z_]/) next
        if (item + 0 == self + 0 || item + 0 <= 0) next
        print (item + 0) "\t" (chain ? "increment-chain" : "task-list")
      }
    }'
}

# sub_issue_children REPO N -> lines "number<TAB>sub-issue"; returns 1 when unreadable.
sub_issue_children() {
  local repo="$1" n="$2" out
  out=$(gh api --paginate "repos/$repo/issues/$n/sub_issues?per_page=100" 2>/dev/null) || return 1
  jq -rs --arg repo "$repo" --argjson self "$n" '
    [.[] | if type == "array" then .[] else empty end] |
    .[] | select(type == "object") |
    select(((.repository_url // "") | ascii_downcase | endswith("/repos/" + ($repo | ascii_downcase)))) |
    select(.number != $self) | "\(.number)\tsub-issue"
  ' <<< "$out" 2>/dev/null || return 1
}

children_json() {
  local repo="$1" n="$2" parent rc=0 raw sub_state="read" sub_lines="" child num
  parent=$(fetch_issue "$repo" "$n") || rc=$?
  if [[ "$rc" -eq 3 ]]; then die 3 "issue #$n does not exist in $repo"; fi
  [[ "$rc" -eq 0 ]] || die 1 "could not read issue #$n in $repo"
  if [[ "$(jq -r '.is_pr' <<< "$parent")" == true ]]; then
    die 3 "#$n in $repo is a pull request, not an issue"
  fi

  raw=$(body_children "$(jq -r '.body' <<< "$parent")" "$n")
  if sub_lines=$(sub_issue_children "$repo" "$n"); then sub_state="read"; else sub_state="unavailable"; sub_lines=""; fi
  raw=$(printf '%s\n%s\n' "$raw" "$sub_lines" | sed '/^$/d')

  local children='[]' missing='[]' seen=" "
  # Group sources per number, keeping first-seen order.
  local order=() srcs
  while IFS=$'\t' read -r num _; do
    [[ -n "$num" ]] || continue
    if [[ "$seen" != *" $num "* ]]; then order+=("$num"); seen="$seen$num "; fi
  done <<< "$raw"

  for num in ${order[@]+"${order[@]}"}; do
    srcs=$(printf '%s\n' "$raw" | awk -F'\t' -v n="$num" '$1 == n {print $2}' | awk '!s[$0]++' |
      jq -Rsc 'split("\n") | map(select(length > 0))')
    rc=0
    child=$(fetch_issue "$repo" "$num") || rc=$?
    if [[ "$rc" -eq 3 ]]; then missing=$(jq -c --argjson n "$num" '. + [$n]' <<< "$missing"); continue; fi
    [[ "$rc" -eq 0 ]] || die 1 "could not read child #$num in $repo"
    if [[ "$(jq -r '.is_pr' <<< "$child")" == true ]]; then continue; fi
    children=$(jq -c --argjson c "$child" --argjson s "$srcs" \
      '. + [{number: $c.number, title: $c.title, state: $c.state, sources: $s}]' <<< "$children")
  done

  jq -cn --arg repo "$repo" --argjson p "$parent" --arg sub "$sub_state" \
    --argjson children "$children" --argjson missing "$missing" '
    {repo: $repo, epic: $p.number, title: $p.title, state: $p.state, sub_issues: $sub,
     children: $children,
     open: [$children[] | select(.state != "CLOSED") | .number],
     closed: [$children[] | select(.state == "CLOSED") | .number],
     missing: $missing}'
}

children_cmd() {
  local repo="$1" n="$2" json
  json=$(children_json "$repo" "$n") || exit $?
  printf '%s\n' "$json"
  if [[ "$(jq -r '.state' <<< "$json")" == CLOSED ]]; then exit 4; fi
  if [[ "$(jq -r '.missing | length' <<< "$json")" -gt 0 ]]; then
    printf 'pm-epic.sh: #%s lists children GitHub cannot find (%s)\n' "$n" \
      "$(jq -r '[.missing[] | "#\(.)"] | join(", ")' <<< "$json")" >&2
    exit 6
  fi
  if [[ "$(jq -r '.children | length' <<< "$json")" -eq 0 ]]; then exit 5; fi
  exit 0
}

# done_verdict JSON N -> prints the verdict line; returns 0 when every child is
# verified CLOSED on a complete child list and the parent is open (safe to
# close), 3 when the parent is already closed and that holds, 2 when children
# are still open on an open parent, 5 childless, 1 otherwise (a discrepancy or
# a partial child list).
list_incomplete() {  # list_incomplete JSON N -> 0 (with a stderr line) when the child list is partial
  if [[ "$(jq -r '.sub_issues' <<< "$1")" != read ]]; then
    printf 'pm-epic.sh: sub-issues of #%s unreadable; not closing on a partial child list\n' "$2" >&2; return 0
  fi
  if [[ "$(jq -r '.missing | length' <<< "$1")" -gt 0 ]]; then
    printf 'pm-epic.sh: #%s lists children GitHub cannot find (%s); not closing\n' "$2" \
      "$(jq -r '[.missing[] | "#\(.)"] | join(", ")' <<< "$1")" >&2; return 0
  fi
  return 1
}

done_verdict() {
  local json="$1" n="$2" total open state
  total=$(jq -r '.children | length' <<< "$json")
  open=$(jq -r '.open | length' <<< "$json")
  state=$(jq -r '.state' <<< "$json")
  if [[ "$total" -eq 0 ]]; then
    if [[ "$state" != CLOSED ]]; then printf 'open #%s (no children)\n' "$n"; return 5; fi
    # A closed parent is "done" only on a complete child list.
    list_incomplete "$json" "$n" && return 1
    printf 'already-closed #%s\n' "$n"; return 3
  fi
  if [[ "$open" -gt 0 ]]; then
    if [[ "$state" == CLOSED ]]; then
      printf 'discrepancy #%s closed with %s of %s children open\n' "$n" "$open" "$total"; return 1
    fi
    printf 'open #%s (%s of %s children open)\n' "$n" "$open" "$total"; return 2
  fi
  list_incomplete "$json" "$n" && return 1
  if [[ "$state" == CLOSED ]]; then printf 'already-closed #%s\n' "$n"; return 3; fi
  return 0
}

close_if_done() {
  local repo="$1" n="$2" json total names rc
  json=$(children_json "$repo" "$n") || exit $?
  rc=0; done_verdict "$json" "$n" || rc=$?
  case "$rc" in
    0) : ;;
    2|3) exit 0 ;;
    *) exit "$rc" ;;
  esac
  # Re-read once more right before closing: a child reopened or added since
  # the first read keeps the parent open. GitHub offers no conditional close,
  # so a tiny window between this read and the close call remains.
  json=$(children_json "$repo" "$n") || exit $?
  rc=0; done_verdict "$json" "$n" || rc=$?
  case "$rc" in
    0) : ;;
    2|3) exit 0 ;;
    *) exit "$rc" ;;
  esac
  total=$(jq -r '.children | length' <<< "$json")
  names=$(jq -r '[.children[].number | "#\(.)"] | join(", ")' <<< "$json")
  gh issue close "$n" --repo "$repo" \
    --comment "Closed by \`/pm epic #$n\`: every child is closed ($names)." >/dev/null 2>&1 ||
    die 1 "could not close #$n in $repo"
  printf 'closed #%s (%s children)\n' "$n" "$total"
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
  parse-arg)
    [[ $# -le 2 ]] || die 2 'usage: pm-epic.sh parse-arg TOKEN'
    parse_arg "${2:-}" ;;
  children|close-if-done)
    [[ $# -eq 3 ]] || die 2 "usage: pm-epic.sh $1 <owner/repo> <N>"
    valid_repo "$2" || die 2 "not an owner/repo: $2"
    n=$(parse_arg "$3") || exit 2
    command -v jq >/dev/null 2>&1 || die 1 'jq is required'
    if [[ "$1" == children ]]; then children_cmd "$2" "$n"; else close_if_done "$2" "$n"; fi ;;
  *) usage >&2; exit 2 ;;
esac
