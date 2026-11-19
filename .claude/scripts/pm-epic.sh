#!/usr/bin/env bash
# pm-epic.sh — Read the children of an epic the operator named with `/pm epic #N`, and close it when they are done.
# catalog: backlog-pm — `/pm epic #N` (issues #2545, #2546): parse the epic argument, read a named parent's same-repo children from its `## Increment chain` checklist, GitHub sub-issues and `#N` task-list items, keep the parent's `## Epic scope` coverage record (covered vs remaining items, wave by wave, at most five children a wave), decide when the next wave is due, and close the parent only once every child is closed and no scope remains
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
#   pm-epic.sh scope <owner/repo> <N>
#   pm-epic.sh scope-init <owner/repo> <N> <rows-file> [stop-reason]
#   pm-epic.sh wave-due <owner/repo> <N>
#   pm-epic.sh wave-open <owner/repo> <N> <K> <count>
#   pm-epic.sh record <owner/repo> <N> <S-id> <child>
#   pm-epic.sh stop <owner/repo> <N> <reason>
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
#                  A parent already closed is checked the same way, through the
#                  same final re-read: it prints `already-closed #N` only when
#                  every child reads CLOSED at that read and its scope record
#                  (if any) is complete, and a `discrepancy` line (exit 1)
#                  otherwise: open children, remaining scope items, coverage
#                  naming no verified child, or a change during the check.
#                  A covered row counts only when its child closed as
#                  completed (`state_reason`; null reads as completed): a
#                  covered child closed as not_planned or duplicate prints
#                  `discrepancy #N S<i> is covered by #c, closed as <reason>
#                  ...` (exit 1) on an open or closed parent, so the row is
#                  set back to `remaining` or re-covered. Other output: `closed #N (k children)` or
#                  `open #N (j of k children open)`. A parent whose
#                  `## Epic scope` still lists remaining items stays open:
#                  `open #N (every child closed; j scope items remain)`; an
#                  unreadable or malformed scope record never closes (exit 1).
#                  A parent body that changed between the scope read and the
#                  final child read prints `open #N (the parent changed during
#                  the check; re-check)` and is not closed.
#
# EPIC SCOPE — the coverage record on the parent (issue #2546)
#   An epic split in waves keeps one `## Epic scope` section in the parent
#   body, so a fresh thread can continue it from the parent alone:
#
#     ## Epic scope
#
#     <!-- pm-epic-scope v1 -->
#     (one sentence of prose)
#
#     Wave: 2 · planned 5 · after #12 · last #17
#                             (after: wave 1's tail, kept when wave 2 opened;
#                              last: the child filed last in wave 2)
#     Stopped: <reason>                     (only when filing stopped)
#
#     - S1 · covered by #13 · wave 1 · Hero and layout shell
#     - S6 · remaining · Contact form
#
#   Each row is one single-PR deliverable: `covered by #N · wave K` (wave 0 =
#   a child that existed before the first wave) or `remaining`. Rows are plain
#   bullets, never task-list items, so they are never read as children. The
#   section runs from its heading to the next `#`/`##` heading outside a fence
#   (or a trailing `_Captured via ..._` footer). The record is strict: the
#   heading or the marker alone makes it a record. Anything off-shape — a
#   heading with no marker, a marker (outside a fence) with no heading, no or
#   two `Wave:` lines, a list item in the section (bullet `-`/`*`/`+` or
#   ordered `1.`/`1)`) that is not a full row (bad item id, unknown status,
#   missing delimiter), a duplicate `S` id, a covered wave past the current
#   wave, a wave with filed children but no `last`, an `after` that is no
#   earlier wave's child, two sections — is malformed (exit 7). A `last`
#   whose row is no longer covered (a re-cut row set back to `remaining`) is
#   stale: on a wave with fewer covered children than planned it reads as
#   unset (the wave resumes and the next `record` names a new tail); on a
#   full wave it is malformed — correct `last` — so the next wave never opens
#   unchecked. Every caller fails closed on a malformed record. Edits are
#   line-level: prose and other sections are never rewritten. Every writing
#   verb (scope-init, wave-open, record, stop) re-reads the parent right
#   before its write and writes nothing when the body differs from the
#   snapshot it validated (exit 1 — re-run it) or the parent is no longer
#   open (exit 4), and re-reads after to verify; GitHub has no conditional edit, so two
#   writers at once can still race: the verify step catches an overwrite only
#   when it is already visible at that re-read, so a writer whose stale body
#   lands after another's verify can still drop that write. Run one writer per
#   parent (one /pm thread per epic); the dedup ladder and `record`'s refusal
#   of a second child per item bound what a race can cost.
#
#   scope          prints the record as JSON: {present, wave, planned, after, last,
#                  stopped, items:[{id,status,child,wave,text,line}],
#                  remaining:[ids], covered:[ids], children:[N...]}.
#                  Exit 5 (with {"present":false}) when there is none.
#   scope-init     writes a new record at Wave 0 from a file of `- S<n> · ...`
#                  rows (`remaining`, or `covered by #N · wave 0` for a child
#                  that already exists on the parent's complete child list),
#                  before `## Increment chain` when there is one. With a
#                  stop-reason the record is written already stopped, in the
#                  same write. Exit 8 when a record already exists: re-cut by
#                  editing the parent, never by re-initialising it. A damaged
#                  record (an orphan marker, say) is exit 7: it writes only
#                  where `scope` would say "no record".
#   wave-due       decides the next step from GitHub alone. One line:
#                    due <K> <S-ids>          file wave K from these items now
#                    resume <K> <S-ids> <j/P> wave K stopped part-way; file these
#                    wait <K> - #<tail>       wave K's last child is not in
#                                             review or merged yet
#                    covered <K> -            no remaining items: no more waves
#                    stopped <K> - <reason>   filing stopped (no clean seam)
#                  The last child of wave K is the one filed last (the
#                  `Wave:` line's `last #T`, written by `record`), never the
#                  highest number. It counts as done when CLOSED, or when a merged or open
#                  non-draft PR closes it. Wave 0 never waits. At most five
#                  items are offered, in record order. An unreadable read is
#                  exit 1, never `due`.
#   wave-open      marks wave K as opened with `count` (1-5) children planned,
#                  before the first child is filed. K must be the next wave,
#                  the current one complete, and its last-filed child still
#                  closed or in review (wave-due's own check, re-run now);
#                  repeating the same call is a no-op. Exit 8 otherwise.
#   record         records that <child> covers item <S-id> in the open wave
#                  and adds `- [ ] #<child>` to `## Increment chain` (creating
#                  it when absent; earlier boxes and later sections are kept)
#                  and sets the `Wave:` line's `last #<child>` in one body
#                  write, then verifies all three. Run it right after
#                  each child is filed. The same pair again is a no-op; a
#                  different child for a covered item, or a wave already at
#                  its planned count, is exit 8.
#   stop           records `Stopped: <reason>` (one line). wave-due then says
#                  `stopped` and wave-open refuses until a person removes it.
#
# EXIT CODES
#   0  success (children: the parent is open and has at least one child)
#   1  a GitHub read or the close failed
#   2  usage error
#   3  the issue does not exist (or is a pull request)
#   4  the issue is closed (children: the JSON is still printed)
#   5  the issue has no children (children: the JSON is still printed; a
#      parent with no body children whose sub-issues could not be read is
#      exit 1, never 5)
#   6  children: a listed child cannot be found (`missing` is non-empty; the
#      JSON is still printed) — the child list is incomplete, so a caller
#      must not bind or work it
#   7  the `## Epic scope` record is malformed (one-line reason on stderr)
#   8  a scope write was refused (record exists, wave not next, cap reached,
#      item covered by another child, filing stopped)

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
           state_reason: (.state_reason // null),
           body: (.body // ""), is_pr: (has("pull_request") and .pull_request != null)}' \
    <<< "$out" 2>/dev/null || return 1
}

# CommonMark fences: a marker counts only with 0-3 spaces of indent; a
# backtick opener has no backtick in its info string; a fence closes only on a
# marker of the same character, at least as long as the opener, with nothing
# but whitespace after it. Fence lines and fenced lines are skipped (`next`),
# so the rules after this fragment only ever see lines outside a fence.
fence_awk() {
  cat <<'AWK'
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
AWK
}
FENCE_AWK=$(fence_awk)

# body_children BODY N -> lines "number<TAB>source", body order, deduplicated by awk caller.
body_children() {
  local body="$1" self="$2"
  printf '%s\n' "$body" | tr -d '\r' | awk -v self="$self" "$FENCE_AWK"'
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

# children_json REPO N [BODY_FILE] -> the children JSON; with BODY_FILE, the
# parent body this read used is also written there (as load_body writes it).
children_json() {
  local repo="$1" n="$2" body_out="${3:-}" parent rc=0 raw sub_state="read" sub_lines="" child num
  parent=$(fetch_issue "$repo" "$n") || rc=$?
  if [[ "$rc" -eq 3 ]]; then die 3 "issue #$n does not exist in $repo"; fi
  [[ "$rc" -eq 0 ]] || die 1 "could not read issue #$n in $repo"
  if [[ -n "$body_out" ]]; then
    jq -j '.body' <<< "$parent" | tr -d '\r' > "$body_out" || die 1 "could not keep the body of #$n"
  fi
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
      '. + [{number: $c.number, title: $c.title, state: $c.state, state_reason: $c.state_reason, sources: $s}]' <<< "$children")
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
  if [[ "$(jq -r '.children | length' <<< "$json")" -eq 0 ]]; then
    # No body children and an unreadable sub-issues API is not "childless":
    # sub-issue-only children may exist, and exit 5 would cut a scope record
    # that files them again.
    if [[ "$(jq -r '.sub_issues' <<< "$json")" == unavailable ]]; then
      printf 'pm-epic.sh: #%s lists no children in its body and its sub-issues could not be read\n' "$n" >&2
      exit 1
    fi
    exit 5
  fi
  exit 0
}

# done_verdict JSON N -> prints the verdict line; returns 0 when every child is
# verified CLOSED on a complete child list and the parent is open (safe to
# close), 3 (silently) when the parent is already closed and that holds, 2 when children
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
    return 3
  fi
  if [[ "$open" -gt 0 ]]; then
    if [[ "$state" == CLOSED ]]; then
      printf 'discrepancy #%s closed with %s of %s children open\n' "$n" "$open" "$total"; return 1
    fi
    printf 'open #%s (%s of %s children open)\n' "$n" "$open" "$total"; return 2
  fi
  list_incomplete "$json" "$n" && return 1
  # Closed with every child closed: the caller prints `already-closed` only
  # after the scope record is verified complete too.
  if [[ "$state" == CLOSED ]]; then return 3; fi
  return 0
}

close_if_done() {
  local repo="$1" n="$2" json total names rc closed=false
  json=$(children_json "$repo" "$n") || exit $?
  rc=0; done_verdict "$json" "$n" || rc=$?
  case "$rc" in
    0) : ;;
    3) closed=true ;;
    2) exit 0 ;;
    *) exit "$rc" ;;
  esac
  # An epic split in waves is done only when its scope record has nothing
  # left to cut. Read it before the final child read, so no remote read sits
  # between the last child-state verdict and the close; unreadable never closes.
  local f scope src=0 left fbody fresh num
  f=$(mktemp) || die 1 'mktemp failed'
  scope=$(read_scope "$repo" "$n" "$f") || src=$?
  fbody=$(cat "$f")
  rm -f "$f"
  case "$src" in
    0|5) left=$(jq -r '.remaining // [] | length' <<< "$scope")
       if [[ "$left" -gt 0 ]]; then
         if [[ "$closed" == true ]]; then
           printf 'discrepancy #%s closed with %s scope items remaining\n' "$n" "$left"; exit 1
         fi
         printf 'open #%s (every child closed; %s scope items remain%s)\n' "$n" "$left" \
           "$(jq -r 'if .stopped then "; stopped: \(.stopped)" else "" end' <<< "$scope")"
         exit 0
       fi ;;
    7) die 1 "#$n has a malformed ## Epic scope record; not closing (scope malformed)" ;;
    *) die 1 "could not read the ## Epic scope record of #$n; not closing" ;;
  esac
  # A covered row must name an issue in the verified child list. A PR number
  # is exempt only as a checklist reference, never as scope coverage.
  for num in $(jq -r '(.children // [])[]' <<< "$scope"); do
    jq -e --argjson c "$num" 'any(.children[]; .number == $c)' <<< "$json" >/dev/null && continue
    if [[ "$closed" == true ]]; then
      printf 'discrepancy #%s closed but scope coverage #%s is not a verified child\n' "$n" "$num"; exit 1
    fi
    printf 'open #%s (scope coverage #%s is not a verified child; re-check)\n' "$n" "$num"
    exit 0
  done
  # Every terminal verdict (`closed`, `already-closed`) comes only after this
  # final child read and parent re-read: a child reopened or added since the
  # first read keeps an open parent open and makes a closed one a
  # discrepancy. GitHub offers no conditional close, so a tiny window between
  # this read and the close call remains.
  recheck() {  # recheck REASON -> open (exit 0) on an open parent, discrepancy (exit 1) on a closed one
    if [[ "$closed" == true ]]; then printf 'discrepancy #%s closed; %s\n' "$n" "$1"; exit 1; fi
    printf 'open #%s (%s)\n' "$n" "$1"; exit 0
  }
  f=$(mktemp) || die 1 'mktemp failed'
  json=$(children_json "$repo" "$n" "$f") || { rc=$?; rm -f "$f"; exit "$rc"; }
  fresh=$(cat "$f"); rm -f "$f"
  rc=0; done_verdict "$json" "$n" || rc=$?
  case "$rc" in
    0) [[ "$closed" == true ]] && recheck 'the parent was reopened during the check; re-check' ;;
    2) exit 0 ;;
    3) [[ "$closed" == true ]] || recheck 'the parent changed during the check; re-check' ;;
    *) exit "$rc" ;;
  esac
  # The parent body this re-read used must be the one the scope read judged:
  # a record written in between (scope-init, a new wave) may add remaining items.
  [[ "$fresh" == "$fbody" ]] || recheck 'the parent changed during the check; re-check'
  # Every child the scope read saw (recorded or listed in that body) must be in
  # this verified list. A number missing from it is a child added in between;
  # only a checklist reference GitHub says is a pull request is exempt.
  for num in $(jq -r '(.children // [])[]' <<< "$scope"); do
    jq -e --argjson c "$num" 'any(.children[]; .number == $c)' <<< "$json" >/dev/null && continue
    recheck "scope coverage #$num is not a verified child; re-check"
  done
  for num in $(body_children "$fbody" "$n" | cut -f1 | awk 'NF && !s[$0]++'); do
    jq -e --argjson c "$num" 'any(.children[]; .number == $c)' <<< "$json" >/dev/null && continue
    rc=0; load_body "$repo" "$num" /dev/null >/dev/null || rc=$?
    if [[ "$rc" -eq 3 ]] && fetch_issue "$repo" "$num" 2>/dev/null | jq -e '.is_pr' >/dev/null 2>&1; then continue; fi
    recheck "#$num appeared on the parent during the check; re-check"
  done
  # children_json read the parent before its sub-issue and child requests:
  # read the parent's state and body once more, after them. The scope verdict
  # holds only for the body it was taken from, so any change re-checks.
  local pstate want=OPEN
  [[ "$closed" == true ]] && want=CLOSED
  f=$(mktemp) || die 1 'mktemp failed'
  rc=0; pstate=$(load_body "$repo" "$n" "$f") || rc=$?
  fresh=$(cat "$f" 2>/dev/null); rm -f "$f"
  [[ "$rc" -eq 0 ]] || die 1 "could not re-read issue #$n in $repo; not closing"
  [[ "$pstate" == "$want" && "$fresh" == "$fbody" ]] || recheck 'the parent changed during the check; re-check'
  # Coverage honesty: a covered row counts only when its child was closed as
  # completed. A child closed as not planned or a duplicate delivered nothing,
  # so its row is not covered: name the row so it is set back to `remaining`
  # (the next wave then cuts it) or re-covered. A null reason (an issue closed
  # before GitHub recorded one) reads as completed.
  local bad
  bad=$(jq -r --argjson kids "$json" '
    [(.items // [])[] | select(.status == "covered") | . as $it |
     $kids.children[] | select(.number == $it.child and .state == "CLOSED" and
       ((.state_reason // "completed") | ascii_downcase) != "completed") |
     "\($it.id) is covered by #\($it.child), closed as \(.state_reason) (not completed); set \($it.id) back to remaining or re-cover it"]
    | first // ""' <<< "$scope" 2>/dev/null) || die 1 "could not check the coverage of #$n"
  if [[ -n "$bad" ]]; then printf 'discrepancy #%s %s\n' "$n" "$bad"; exit 1; fi
  if [[ "$closed" == true ]]; then printf 'already-closed #%s\n' "$n"; exit 0; fi
  total=$(jq -r '.children | length' <<< "$json")
  names=$(jq -r '[.children[].number | "#\(.)"] | join(", ")' <<< "$json")
  gh issue close "$n" --repo "$repo" \
    --comment "Closed by \`/pm epic #$n\`: every child is closed ($names)." >/dev/null 2>&1 ||
    die 1 "could not close #$n in $repo"
  printf 'closed #%s (%s children)\n' "$n" "$total"
}

# ---- epic scope: the coverage record (issue #2546) ---------------------------

SCOPE_MARK='<!-- pm-epic-scope v1 -->'
DOT='·'
WAVE_CAP=5
RE_ROW="^-[[:space:]]+(S[0-9]+)[[:space:]]+${DOT}[[:space:]]+(.*[^[:space:]])[[:space:]]*\$"
RE_REMAINING="^remaining[[:space:]]+${DOT}[[:space:]]+(.+)\$"
RE_COVERED="^covered by #([1-9][0-9]*)[[:space:]]+${DOT}[[:space:]]+wave[[:space:]]+([0-9]+)[[:space:]]+${DOT}[[:space:]]+(.+)\$"
RE_WAVE="^Wave:[[:space:]]*([0-9]+)([[:space:]]+${DOT}[[:space:]]+planned[[:space:]]+([0-9]+)([[:space:]]+${DOT}[[:space:]]+after[[:space:]]+#([1-9][0-9]*))?([[:space:]]+${DOT}[[:space:]]+last[[:space:]]+#([1-9][0-9]*))?)?[[:space:]]*\$"
RE_STOPPED="^Stopped:[[:space:]]*(.*[^[:space:]])[[:space:]]*\$"
RE_MARK='^[[:space:]]*<!--[[:space:]]*pm-epic-scope[[:space:]]+v1[[:space:]]*-->[[:space:]]*$'

malformed() { printf 'pm-epic.sh: #%s ## Epic scope is malformed: %s\n' "$1" "$2" >&2; }
refuse() { printf 'pm-epic.sh: #%s: %s\n' "$1" "$2" >&2; exit 8; }

# locate FILE -> "scope_start scope_end scope_count chain_start chain_end total footer"
# (line numbers, 0 when absent). A section ends before the next `#`/`##`
# heading outside a fence, or before a trailing `_Captured via ..._` footer.
locate() {
  awk '
    function shut(n) { if (in_s) { se = n; in_s = 0 } if (in_c) { ce = n; in_c = 0 } }
    /[^[:space:]]/ { lastnb = NR; lastline = $0 }
  '"$FENCE_AWK"'
    /^ ? ? ?##?[[:space:]]/ {
      shut(NR - 1)
      if ($0 ~ /^ ? ? ?##[[:space:]]+Epic scope[[:space:]]*$/) { sc++; if (sc == 1) { ss = NR; in_s = 1 } }
      else if ($0 ~ /^ ? ? ?##[[:space:]]+Increment chain[[:space:]]*$/) { cc++; if (cc == 1) { cs = NR; in_c = 1 } }
    }
    END {
      shut(NR)
      ft = (lastline ~ /^_Captured via /) ? lastnb : 0
      if (ft && ss && ss < ft && se >= ft) se = ft - 1
      if (ft && cs && cs < ft && ce >= ft) ce = ft - 1
      print ss + 0, se + 0, sc + 0, cs + 0, ce + 0, NR, ft, fence + 0
    }' "$1"
}

# outside_lines FILE FROM TO -> "NR<TAB>line" for every line in FROM..TO that
# is outside a fence (fence rules as everywhere else in this script).
outside_lines() {
  awk -v a="$2" -v b="$3" "$FENCE_AWK"'NR >= a && NR <= b { print NR "\t" $0 }' "$1"
}

# load_body REPO N FILE -> writes the body (CR-free) to FILE, prints the state.
# Returns fetch_issue's codes; a pull request is 3.
load_body() {
  local repo="$1" n="$2" out="$3" j rc=0
  j=$(fetch_issue "$repo" "$n") || rc=$?
  [[ "$rc" -eq 0 ]] || return "$rc"
  [[ "$(jq -r '.is_pr' <<< "$j")" == true ]] && return 3
  # -j: no newline of our own, so repeated writes never grow the body.
  jq -j '.body' <<< "$j" | tr -d '\r' > "$out" || return 1
  jq -r '.state' <<< "$j"
}

# scope_from_file FILE N -> JSON on stdout; 5 when there is no record, 7 malformed.
scope_from_file() {
  local f="$1" n="$2" loc ss se sc cs ce total ft fo
  # A failed scan is unreadable (1), never "no record" (5).
  loc=$(locate "$f") || return 1
  read -r ss se sc cs ce total ft fo <<< "$loc"
  [[ "${sc:-}" =~ ^[0-9]+$ ]] || return 1
  if [[ "$sc" -eq 0 ]]; then
    # A marker outside a fence with no `## Epic scope` heading is a damaged
    # record, never "no record": exit 5 is only for neither heading nor marker.
    local ml
    ml=$(outside_lines "$f" 1 "$total" | cut -f2-) || return 1
    while IFS= read -r line; do
      if [[ "$line" =~ $RE_MARK ]]; then
        malformed "$n" "a $SCOPE_MARK marker without its ## Epic scope heading"; return 7
      fi
    done <<< "$ml"
    jq -cn '{present: false}'; return 5
  fi
  [[ "$sc" -eq 1 ]] || { malformed "$n" "more than one section"; return 7; }
  local ln line marker=0 wave="" planned="" after="" last="" waveln=0 stopped="" stopln=0 rows="" seen=" "
  local id rest status child cwave text
  if [[ "$se" -gt "$ss" ]]; then
    local section
    section=$(outside_lines "$f" "$((ss + 1))" "$se") || return 1
    while IFS=$'\t' read -r ln line || [[ -n "$ln" ]]; do
      [[ -n "$ln" ]] || continue
      if [[ "$line" =~ $RE_MARK ]]; then marker=1; continue; fi
      if [[ "$line" =~ $RE_WAVE ]]; then
        [[ -z "$wave" ]] || { malformed "$n" "two Wave: lines"; return 7; }
        wave=$((10#${BASH_REMATCH[1]})); planned="${BASH_REMATCH[3]}"; after="${BASH_REMATCH[5]}"; last="${BASH_REMATCH[7]}"
        waveln="$ln"; continue
      fi
      if [[ "$line" =~ ^Wave: ]]; then malformed "$n" "unreadable line: $line"; return 7; fi
      if [[ "$line" =~ $RE_STOPPED ]]; then
        [[ -z "$stopped" ]] || { malformed "$n" "two Stopped: lines"; return 7; }
        stopped="${BASH_REMATCH[1]}"; stopln="$ln"; continue
      fi
      # A `Stopped:` line with no reason is not "unstopped": fail closed.
      if [[ "$line" =~ ^Stopped: ]]; then malformed "$n" "a Stopped: line needs a reason"; return 7; fi
      if [[ "$line" =~ $RE_ROW ]]; then
        id="${BASH_REMATCH[1]}"; rest="${BASH_REMATCH[2]}"
        if [[ "$rest" =~ $RE_REMAINING ]]; then
          status=remaining; child=""; cwave=""; text="${BASH_REMATCH[1]}"
        elif [[ "$rest" =~ $RE_COVERED ]]; then
          status=covered; child="${BASH_REMATCH[1]}"; cwave=$((10#${BASH_REMATCH[2]})); text="${BASH_REMATCH[3]}"
        else
          malformed "$n" "unreadable row: $line"; return 7
        fi
        [[ "$seen" != *" $id "* ]] || { malformed "$n" "duplicate item $id"; return 7; }
        seen="$seen$id "
        rows+="$id"$'\t'"$status"$'\t'"$child"$'\t'"$cwave"$'\t'"${text//$'\t'/ }"$'\t'"$ln"$'\n'
        continue
      fi
      # Anything that looks like an item but is off-shape is malformed, never
      # silently dropped (a dropped remaining item could let the parent close).
      # Every list item in the section must be a full row: a bad item id, an
      # unknown status or a missing delimiter fails closed. That covers bullet
      # (`-`, `*`, `+`) and ordered (`1.`, `1)`) list markers alike.
      if [[ "$line" =~ ^[[:space:]]*[-*+]([[:space:]]|$) || "$line" =~ ^[[:space:]]*[0-9]{1,9}[.\)]([[:space:]]|$) ||
            "$line" =~ ^[[:space:]]*S[0-9]+ ]]; then
        malformed "$n" "unreadable row: $line"; return 7
      fi
    done <<< "$section"
  fi
  [[ "$marker" -eq 1 ]] || { malformed "$n" "no $SCOPE_MARK marker"; return 7; }
  [[ -n "$wave" ]] || { malformed "$n" "no Wave: line"; return 7; }
  [[ "$wave" -eq 0 || -n "$planned" ]] || { malformed "$n" "Wave: $wave has no planned count"; return 7; }
  [[ -n "$rows" ]] || { malformed "$n" "no S<n> items"; return 7; }
  if [[ -n "$planned" ]] && { [[ "$((10#$planned))" -lt 1 || "$((10#$planned))" -gt "$WAVE_CAP" ]]; }; then
    malformed "$n" "planned must be 1-$WAVE_CAP"; return 7
  fi
  printf '%s' "$rows" | jq -Rnc --argjson wave "$wave" --arg planned "$planned" --arg after "$after" --arg last "$last" --arg stopped "$stopped" \
    --argjson ss "$ss" --argjson se "$se" --argjson waveln "$waveln" --argjson stopln "$stopln" \
    --argjson cs "$cs" --argjson ce "$ce" --argjson ft "$ft" --argjson total "$total" '
    [inputs | select(length > 0) | split("\t") |
      {id: .[0], status: .[1], child: (if .[2] == "" then null else (.[2] | tonumber) end),
       wave: (if .[3] == "" then null else (.[3] | tonumber) end), text: .[4], line: (.[5] | tonumber)}] as $items |
    {present: true, wave: $wave,
     planned: (if $planned == "" then null else ($planned | tonumber) end),
     after: (if $after == "" then null else ($after | tonumber) end),
     last: (if $last == "" then null else ($last | tonumber) end),
     stopped: (if $stopped == "" then null else $stopped end),
     items: $items,
     remaining: [$items[] | select(.status == "remaining") | .id],
     covered: [$items[] | select(.status == "covered") | .id],
     children: ([$items[] | select(.child != null) | .child] | unique),
     lines: {start: $ss, end: $se, wave: $waveln, stopped: $stopln,
             chain_start: $cs, chain_end: $ce, footer: $ft, total: $total}}
    | if any(.items[]; (.wave // 0) > $wave) then error("wave")
      elif .planned != null and ([.items[] | select(.status == "covered" and .wave == $wave)] | length) > .planned
        then error("overfilled")
      elif ([.items[] | select(.status == "covered" and .wave > 0) | .child] | length) !=
           ([.items[] | select(.status == "covered" and .wave > 0) | .child] | unique | length)
        then error("shared")
      # `after #A` is the tail of the previous wave, kept when a wave opens so
      # a fresh thread can still chain the head of this wave on it: it must be
      # a covered child of an earlier wave.
      elif .after != null and (. as $r | [.items[] | select(.status == "covered" and .wave < $wave and .child == $r.after)] | length) == 0
        then error("after")
      # The tail (`last #T`) is the child filed last in the current wave, the
      # one the next wave waits on. A `last` whose row is no longer covered
      # (the documented re-cut: a row set back to `remaining`) is stale: on a
      # wave that can resume (fewer covered than planned) it reads as unset and
      # the item is re-filed in this wave; on a full wave it is malformed
      # (correct `last`), so the next wave never opens unchecked. A wave with
      # filed children and no `last` at all is malformed.
      elif .last != null and (. as $r | [.items[] | select(.status == "covered" and .wave == $wave and .child == $r.last)] | length) == 0
        then (if .planned != null and ([.items[] | select(.status == "covered" and .wave == $wave)] | length) < .planned
              then .last = null else error("last") end)
      elif $wave > 0 and .last == null and any(.items[]; .status == "covered" and .wave == $wave)
        then error("nolast")
      else . end' 2>/dev/null || {
    malformed "$n" "a covered item names a wave past Wave: $wave, wave $wave holds more children than planned, one wave child covers two items, the Wave: line's after child is not an earlier wave's child, or wave $wave has covered items but its Wave: line names no valid last child (a full wave's last must name one of its children)"; return 7; }
}

# read_scope REPO N FILE -> the record JSON plus {epic, state}; the body is left
# in FILE. Exits: 0, 5 (no record; JSON still printed), 7, and load_body's 1/3.
read_scope() {
  local repo="$1" n="$2" f="$3" state json rc=0
  state=$(load_body "$repo" "$n" "$f") || return $?
  json=$(scope_from_file "$f" "$n") || rc=$?
  [[ "$rc" -eq 0 || "$rc" -eq 5 ]] || return "$rc"
  jq -c --arg s "$state" --argjson n "$n" '. + {epic: $n, state: $s}' <<< "$json" || return 1
  return "$rc"
}

# scope_or_die REPO N FILE -> the record JSON of an OPEN parent that has one;
# every other outcome exits with its own code and a one-line reason.
scope_or_die() {
  local json rc=0
  json=$(read_scope "$1" "$2" "$3") || rc=$?
  case "$rc" in
    0) : ;;
    5) refuse "$2" 'has no ## Epic scope record (run scope-init first)' ;;
    3) die 3 "issue #$2 does not exist in $1" ;;
    7) exit 7 ;;
    *) die 1 "could not read issue #$2 in $1" ;;
  esac
  [[ "$(jq -r .state <<< "$json")" == OPEN ]] || die 4 "issue #$2 is closed"
  printf '%s\n' "$json"
}

set_line() {  # set_line FILE LN TEXT
  local tmp; tmp=$(mktemp) || return 1
  T="$3" awk -v at="$2" 'NR == at {print ENVIRON["T"]; next} {print}' "$1" > "$tmp" && mv "$tmp" "$1"
}

insert_after() {  # insert_after FILE LN TEXT — TEXT may span lines; LN 0 is the top
  local tmp; tmp=$(mktemp) || return 1
  T="$3" awk -v at="$2" 'at == 0 && NR == 1 {print ENVIRON["T"]} {print} NR == at && at > 0 {print ENVIRON["T"]}
    END { if (NR == 0) print ENVIRON["T"] }' "$1" > "$tmp" && mv "$tmp" "$1"
}

line_blank() {  # line_blank FILE N -> 0 when line N is blank (or N is 0)
  [[ "$2" -eq 0 ]] && return 0
  awk -v n="$2" 'NR == n { exit ($0 ~ /[^[:space:]]/) }' "$1"
}

write_body() {  # write_body REPO N FILE
  gh issue edit "$2" --repo "$1" --body-file "$3" >/dev/null 2>&1 ||
    die 1 "could not write the body of #$2 in $1"
}

wave_line() {  # wave_line K [P [A [T]]] — A: the previous wave's tail; T: this wave's last-filed child
  local out="Wave: $1"
  if [[ -n "${2:-}" ]]; then
    out+=" $DOT planned $2"
    [[ -z "${3:-}" ]] || out+=" $DOT after #$3"
    [[ -z "${4:-}" ]] || out+=" $DOT last #$4"
  fi
  printf '%s' "$out"
}

# prewrite_check REPO N FILE SNAPSHOT -> re-reads the parent right before a
# write and aborts (exit 1, nothing written) when its body is no longer the
# snapshot the command validated; the caller re-runs from the new body. The
# window after this read is GitHub's: there is no conditional edit.
prewrite_check() {
  local rc=0 state
  state=$(load_body "$1" "$2" "$3.now") || rc=$?
  if [[ "$rc" -ne 0 ]]; then rm -f "$3.now"; die 1 "could not re-read issue #$2 in $1; nothing written"; fi
  # A parent closed since the read is never edited, even with an unchanged body.
  if [[ "$state" != OPEN ]]; then rm -f "$3.now"; die 4 "issue #$2 was closed since it was read; nothing written"; fi
  if [[ "$(cat "$3.now")" != "$4" ]]; then rm -f "$3.now"; die 1 "#$2 changed since it was read; nothing written (re-run it)"; fi
  rm -f "$3.now"
}

# tail_ready REPO JSON -> 0 when the current wave's last-filed child (`last`)
# is CLOSED or a merged or open non-draft PR closes it; 2 (printing the tail)
# while it is not; dies 1 on an unreadable read. Wave 0 or a wave with no
# filed child is ready.
tail_ready() {
  local repo="$1" json="$2" k tail tstate rc=0
  k=$(jq -r .wave <<< "$json"); tail=$(jq -r '.last // ""' <<< "$json")
  if [[ "$k" -eq 0 || -z "$tail" ]]; then return 0; fi
  tstate=$(load_body "$repo" "$tail" /dev/null) || rc=$?
  [[ "$rc" -eq 0 ]] || die 1 "could not read #$tail, the last child of wave $k"
  [[ "$tstate" == CLOSED ]] && return 0
  rc=0; in_review "$repo" "$tail" || rc=$?
  case "$rc" in
    0) return 0 ;;
    2) printf '%s\n' "$tail"; return 2 ;;
    *) die 1 "could not read the pull requests of #$tail, the last child of wave $k" ;;
  esac
}

scope_cmd() {
  local f json rc=0
  f=$(mktemp) || die 1 'mktemp failed'
  json=$(read_scope "$1" "$2" "$f") || rc=$?
  rm -f "$f"
  case "$rc" in
    0|5) printf '%s\n' "$json"
         [[ "$(jq -r .state <<< "$json")" == CLOSED ]] && exit 4
         exit "$rc" ;;
    3) die 3 "issue #$2 does not exist in $1" ;;
    7) exit 7 ;;
    *) die 1 "could not read issue #$2 in $1" ;;
  esac
}

scope_init() {
  local repo="$1" n="$2" rows_file="$3" stop_reason="${4:-}" state rc=0 line rows="" count=0 child id rest seen=" " covers=""
  [[ -r "$rows_file" ]] || die 2 "cannot read $rows_file"
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%$'\r'}"
    [[ -n "${line//[[:space:]]/}" ]] || continue
    [[ "$line" =~ $RE_ROW ]] || die 2 "not an item row: $line"
    id="${BASH_REMATCH[1]}"; rest="${BASH_REMATCH[2]}"
    [[ "$seen" != *" $id "* ]] || die 2 "duplicate item $id"
    seen="$seen$id "
    if [[ "$rest" =~ $RE_COVERED ]]; then
      child="${BASH_REMATCH[1]}"
      [[ "$((10#${BASH_REMATCH[2]}))" -eq 0 ]] || die 2 "a new record covers items at wave 0 only: $line"
      [[ "$child" -ne "$n" ]] || die 2 "the parent cannot cover its own item: $line"
      covers+=" $child"
    elif ! [[ "$rest" =~ $RE_REMAINING ]]; then
      die 2 "not an item row: $line"
    fi
    rows+="$line"$'\n'; count=$((count + 1))
  done < "$rows_file"
  [[ "$count" -gt 0 ]] || die 2 "no item rows in $rows_file"
  # Every record write needs a complete child read, even when every row is
  # `remaining` (an unread sub-issue may already deliver one), and the edit is
  # made to the body snapshot that read used. Wave-0 coverage must name a
  # child from that list.
  f=$(mktemp) || die 1 'mktemp failed'
  trap 'rm -f "$f" "$f.now"' EXIT
  local kids krc=0
  kids=$(children_json "$repo" "$n" "$f") || krc=$?
  [[ "$krc" -eq 0 ]] || exit "$krc"
  state=$(jq -r .state <<< "$kids")
  [[ "$state" == OPEN ]] || die 4 "issue #$n is closed"
  if list_incomplete "$kids" "$n"; then die 1 "the child list of #$n is incomplete; no scope record written"; fi
  for child in $covers; do
    jq -e --argjson c "$child" 'any(.children[]; .number == $c)' <<< "$kids" >/dev/null ||
      die 2 "#$child is not a child of #$n; a wave-0 row covers only an existing child"
  done
  local loc ss se sc cs ce total ft fo at block
  loc=$(locate "$f") || die 1 "could not scan the body of #$n"
  read -r ss se sc cs ce total ft fo <<< "$loc"
  [[ "$sc" -eq 0 ]] || refuse "$n" 'already has an ## Epic scope record; re-cut it by editing the parent'
  # Only a body with neither the heading nor an unfenced marker is "no record"
  # (exit 5): an orphan marker or damaged record is malformed, never re-initialised.
  local src=0
  scope_from_file "$f" "$n" >/dev/null || src=$?
  case "$src" in
    5) : ;;
    0) refuse "$n" 'already has an ## Epic scope record; re-cut it by editing the parent' ;;
    7) exit 7 ;;
    *) die 1 "could not scan the body of #$n" ;;
  esac
  [[ "$fo" -eq 0 ]] || refuse "$n" 'its body ends inside an unclosed code fence; close the fence first'
  block="## Epic scope"$'\n\n'"$SCOPE_MARK"$'\n'"Coverage record for \`/pm epic #$n\`: each item is one single-PR deliverable, covered by a child or still remaining. Later waves are cut from the remaining items only. To re-cut, edit an item's text or delete a remaining row, keeping each row's \`S<n> $DOT status $DOT\` prefix."$'\n\n'"$(wave_line 0)"${stop_reason:+$'\n'"Stopped: $stop_reason"}$'\n\n'"${rows%$'\n'}"
  # Above the increment chain (so Step 5.1's strip-to-end can never take it),
  # else above a trailing footer, else at the end.
  if [[ "$cs" -gt 0 ]]; then at=$((cs - 1)); block+=$'\n'
  elif [[ "$ft" -gt 0 ]]; then at=$((ft - 1)); block+=$'\n'
  else at="$total"; fi
  line_blank "$f" "$at" || block=$'\n'"$block"
  # Re-read right before writing: a body changed since the validated snapshot
  # is never overwritten.
  local snap; snap=$(cat "$f")
  insert_after "$f" "$at" "$block" || die 1 'could not edit the body'
  prewrite_check "$repo" "$n" "$f" "$snap"
  write_body "$repo" "$n" "$f"
  local json; rc=0
  json=$(read_scope "$repo" "$n" "$f") || rc=$?
  # Verify what was written, not just a row count: wave 0, unstopped, and
  # exactly the requested rows (as visible at this re-read).
  local got want
  got=$(jq -r '.items[].line' <<< "$json" 2>/dev/null | while read -r l; do sed -n "${l}p" "$f"; done)
  want=$(printf '%s' "$rows" | sed '/^$/d')
  [[ "$rc" -eq 0 && "$(jq -r '"\(.wave) \(.stopped // "")"' <<< "$json")" == "0 $stop_reason" && "$got" == "$want" ]] ||
    die 1 "wrote #$n but could not verify its ## Epic scope record (another writer?)"
  printf 'scope #%s: %s items, %s remaining\n' "$n" "$count" "$(jq -r '.remaining | length' <<< "$json")"
}

# in_review REPO M -> 0 when a merged or open non-draft PR closes #M, 2 when
# none does, 1 when the read fails.
in_review() {
  local repo="$1" m="$2" out q
  q="query(\$owner:String!,\$name:String!,\$n:Int!){repository(owner:\$owner,name:\$name){issue(number:\$n){closedByPullRequestsReferences(first:100,includeClosedPrs:true){pageInfo{hasNextPage} nodes{number state isDraft}}}}}"
  # -f (raw string) for owner/name: -F would send a numeric or `true`-like
  # repo name as a non-string and GraphQL would reject the String! variable.
  out=$(gh api graphql -f query="$q" -f owner="${repo%%/*}" -f name="${repo#*/}" -F n="$m" 2>/dev/null) || return 1
  jq -e '.data.repository.issue.closedByPullRequestsReferences.nodes | type == "array"' <<< "$out" >/dev/null 2>&1 || return 1
  jq -e 'any(.data.repository.issue.closedByPullRequestsReferences.nodes[];
           .state == "MERGED" or (.state == "OPEN" and .isDraft == false))' <<< "$out" >/dev/null 2>&1 && return 0
  # More than 100 linked PRs and none qualified so far: unread, never "wait".
  jq -e '.data.repository.issue.closedByPullRequestsReferences.pageInfo.hasNextPage == false' <<< "$out" >/dev/null 2>&1 || return 1
  return 2
}

wave_due() {
  local repo="$1" n="$2" json rc=0 k planned filed left take tail
  f=$(mktemp) || die 1 'mktemp failed'
  trap 'rm -f "$f"' EXIT
  json=$(read_scope "$repo" "$n" "$f") || rc=$?
  case "$rc" in
    0) : ;;
    5) echo "none 0 -"; exit 5 ;;
    3) die 3 "issue #$n does not exist in $repo" ;;
    7) exit 7 ;;
    *) die 1 "could not read issue #$n in $repo" ;;
  esac
  [[ "$(jq -r .state <<< "$json")" == OPEN ]] || die 4 "issue #$n is closed"
  k=$(jq -r .wave <<< "$json")
  if [[ "$(jq -r '.stopped // ""' <<< "$json")" != "" ]]; then
    printf 'stopped %s - %s\n' "$k" "$(jq -r .stopped <<< "$json")"; exit 0
  fi
  left=$(jq -r '.remaining | length' <<< "$json")
  if [[ "$left" -eq 0 ]]; then printf 'covered %s -\n' "$k"; exit 0; fi
  planned=$(jq -r '.planned // ""' <<< "$json")
  filed=$(jq -r --argjson k "$k" '[.items[] | select(.status == "covered" and .wave == $k)] | length' <<< "$json")
  if [[ "$k" -gt 0 && -n "$planned" && "$filed" -lt "$planned" ]]; then
    take=$((planned - filed))
    printf 'resume %s %s %s/%s\n' "$k" \
      "$(jq -r --argjson t "$take" '.remaining[:$t] | join(",")' <<< "$json")" "$filed" "$planned"
    exit 0
  fi
  take=$(jq -r --argjson c "$WAVE_CAP" '.remaining[:$c] | join(",")' <<< "$json")
  # The next wave waits on the wave's last-FILED child (the record's `last`),
  # never the highest number: a recovered child can have a lower one.
  rc=0; tail=$(tail_ready "$repo" "$json") || rc=$?
  case "$rc" in
    0) printf 'due %s %s\n' "$((k + 1))" "$take" ;;
    2) printf 'wait %s - #%s\n' "$k" "$tail" ;;
    *) exit "$rc" ;;
  esac
}

wave_open() {
  local repo="$1" n="$2" k="$3" cnt="$4" json w p filed left snap tail rc=0
  k=$((10#$k)); cnt=$((10#$cnt))
  f=$(mktemp) || die 1 'mktemp failed'
  trap 'rm -f "$f" "$f.now"' EXIT
  json=$(scope_or_die "$repo" "$n" "$f") || exit $?
  snap=$(cat "$f")
  [[ "$(jq -r '.stopped // ""' <<< "$json")" == "" ]] || refuse "$n" "filing is stopped: $(jq -r .stopped <<< "$json")"
  w=$(jq -r .wave <<< "$json"); p=$(jq -r '.planned // ""' <<< "$json")
  if [[ "$k" -eq "$w" && "$p" == "$cnt" ]]; then printf 'wave %s already open (%s planned)\n' "$k" "$cnt"; exit 0; fi
  [[ "$k" -eq $((w + 1)) ]] || refuse "$n" "wave $k is not the next wave (current: $w)"
  filed=$(jq -r --argjson k "$w" '[.items[] | select(.status == "covered" and .wave == $k)] | length' <<< "$json")
  if [[ "$w" -gt 0 && -n "$p" && "$filed" -lt "$p" ]]; then
    refuse "$n" "wave $w is not complete ($filed of $p filed)"
  fi
  [[ "$cnt" -le "$WAVE_CAP" ]] || refuse "$n" "a wave is at most $WAVE_CAP children (asked for $cnt)"
  left=$(jq -r '.remaining | length' <<< "$json")
  [[ "$cnt" -le "$left" ]] || refuse "$n" "only $left items remain (asked for $cnt)"
  # The same eligibility wave-due applied: the current wave's last-filed child
  # must still be closed or in review now (a PR can go back to draft).
  tail=$(tail_ready "$repo" "$json") || rc=$?
  case "$rc" in
    0) : ;;
    2) refuse "$n" "wave $w's last child #$tail is not in review or closed yet" ;;
    *) exit "$rc" ;;
  esac
  # Keep the previous wave's tail on the new Wave: line (`after #A`): this
  # wave's head chains on it, and a fresh thread resuming before the head is
  # filed must still find it in the record.
  set_line "$f" "$(jq -r .lines.wave <<< "$json")" "$(wave_line "$k" "$cnt" "$(jq -r '.last // ""' <<< "$json")")" ||
    die 1 'could not edit the body'
  prewrite_check "$repo" "$n" "$f" "$snap"
  write_body "$repo" "$n" "$f"
  json=$(scope_or_die "$repo" "$n" "$f") || die 1 "wrote #$n but could not verify wave $k"
  [[ "$(jq -r '"\(.wave) \(.planned)"' <<< "$json")" == "$k $cnt" ]] ||
    die 1 "wrote #$n but it does not show wave $k (another writer?)"
  printf 'opened wave %s on #%s (%s planned)\n' "$k" "$n" "$cnt"
}

# chain_has FILE CS CE CHILD -> 0 when the section holds a top-level `#CHILD` task item.
chain_has() {
  awk -v cs="$2" -v ce="$3" -v c="$4" "$FENCE_AWK"'NR >= cs && NR <= ce &&
    match($0, /^ ? ? ?[-*+][[:space:]]+\[[ xX]\][[:space:]]+#[0-9]+/) {
      item = substr($0, RSTART, RLENGTH); sub(/.*#/, "", item)
      if (substr($0, RSTART + RLENGTH, 1) !~ /[0-9A-Za-z_]/ && item + 0 == c + 0) { found = 1 }
    } END { exit !found }' "$1"
}

# chain_add FILE N CHILD -> adds `- [ ] #CHILD` to `## Increment chain`, keeping
# every earlier box and every later section; creates the section when absent.
chain_add() {
  local f="$1" n="$2" c="$3" loc ss se sc cs ce total ft fo last
  loc=$(locate "$f") || return 1
  read -r ss se sc cs ce total ft fo <<< "$loc"
  # Never add a link inside a fence the body leaves open.
  [[ "$fo" -eq 0 ]] || return 1
  if [[ "$cs" -gt 0 ]]; then
    chain_has "$f" "$cs" "$ce" "$c" && return 0
    last=$(awk -v cs="$cs" -v ce="$ce" "$FENCE_AWK"'NR > cs && NR <= ce && /^ ? ? ?[-*+][[:space:]]+\[[ xX]\][[:space:]]+#[0-9]+/ {l = NR} END {print l + 0}' "$f")
    if [[ "$last" -gt 0 ]]; then insert_after "$f" "$last" "- [ ] #$c"; return; fi
    last=$(awk -v cs="$cs" -v ce="$ce" 'NR >= cs && NR <= ce && /[^[:space:]]/ {l = NR} END {print l + 0}' "$f")
    insert_after "$f" "$last" $'\n'"- [ ] #$c"; return
  fi
  local block="## Increment chain"$'\n\n'"Epic waves for \`/pm epic #$n\`. This issue stays open while its \`## Epic scope\` lists remaining items, and closes when the last child merges."$'\n\n'"- [ ] #$c"
  local at="$total"
  if [[ "$ft" -gt 0 ]]; then at=$((ft - 1)); block+=$'\n'; fi
  line_blank "$f" "$at" || block=$'\n'"$block"
  insert_after "$f" "$at" "$block"
}

record_cmd() {
  local repo="$1" n="$2" id="$3" c="$4" json item status had w p filed rc=0 snap
  [[ "$c" -ne "$n" ]] || die 2 'a parent cannot be its own child'
  f=$(mktemp) || die 1 'mktemp failed'
  trap 'rm -f "$f" "$f.now"' EXIT
  json=$(scope_or_die "$repo" "$n" "$f") || exit $?
  snap=$(cat "$f")
  item=$(jq -c --arg id "$id" '.items[] | select(.id == $id)' <<< "$json")
  [[ -n "$item" ]] || refuse "$n" "has no item $id"
  status=$(jq -r .status <<< "$item"); had=$(jq -r '.child // ""' <<< "$item")
  w=$(jq -r .wave <<< "$json"); p=$(jq -r '.planned // ""' <<< "$json")
  if [[ "$status" == covered ]]; then
    [[ "$had" == "$c" ]] || refuse "$n" "$id is already covered by #$had"
  else
    [[ "$(jq -r '.stopped // ""' <<< "$json")" == "" ]] || refuse "$n" "filing is stopped: $(jq -r .stopped <<< "$json")"
    [[ "$w" -gt 0 && -n "$p" ]] || refuse "$n" 'no wave is open (run wave-open first)'
    filed=$(jq -r --argjson k "$w" '[.items[] | select(.status == "covered" and .wave == $k)] | length' <<< "$json")
    [[ "$filed" -lt "$p" ]] || refuse "$n" "wave $w already has its $p planned children"
    jq -e --argjson c "$c" '.children | index($c) == null' <<< "$json" >/dev/null ||
      refuse "$n" "#$c already covers another item"
    load_body "$repo" "$c" /dev/null >/dev/null || rc=$?
    [[ "$rc" -ne 3 ]] || die 3 "child #$c is not an issue in $repo"
    [[ "$rc" -eq 0 ]] || die 1 "could not read child #$c in $repo"
    set_line "$f" "$(jq -r .line <<< "$item")" \
      "- $id $DOT covered by #$c $DOT wave $w $DOT $(jq -r .text <<< "$item")" || die 1 'could not edit the body'
    # The child filed last is the wave's tail, persisted in the same write so
    # the next wave waits on filing order, never the highest number.
    set_line "$f" "$(jq -r .lines.wave <<< "$json")" "$(wave_line "$w" "$p" "$(jq -r '.after // ""' <<< "$json")" "$c")" ||
      die 1 'could not edit the body'
  fi
  local before; before=$(cksum < "$f")
  chain_add "$f" "$n" "$c" || die 1 'could not edit the body'
  if [[ "$status" == covered && "$(cksum < "$f")" == "$before" ]]; then
    printf 'already recorded #%s for %s\n' "$c" "$id"; exit 0
  fi
  prewrite_check "$repo" "$n" "$f" "$snap"
  write_body "$repo" "$n" "$f"
  json=$(scope_or_die "$repo" "$n" "$f") || die 1 "wrote #$n but could not verify $id"
  jq -e --arg id "$id" --argjson c "$c" 'any(.items[]; .id == $id and .child == $c)' <<< "$json" >/dev/null ||
    die 1 "wrote #$n but $id is not covered by #$c (another writer?)"
  if [[ "$status" != covered && "$(jq -r '.last // ""' <<< "$json")" != "$c" ]]; then
    die 1 "wrote #$n but its Wave: line does not name #$c as the last child (another writer?)"
  fi
  local loc ss se sc cs ce total ft fo
  loc=$(locate "$f") || die 1 "could not scan the body of #$n"
  read -r ss se sc cs ce total ft fo <<< "$loc"
  if [[ "$cs" -eq 0 ]] || ! chain_has "$f" "$cs" "$ce" "$c"; then
    die 1 "wrote #$n but its ## Increment chain does not list #$c (another writer?)"
  fi
  printf 'recorded #%s for %s (wave %s)\n' "$c" "$id" "$(jq -r '.items[] | select(.id == "'"$id"'") | .wave' <<< "$json")"
}

stop_cmd() {
  local repo="$1" n="$2" reason="$3" json ln snap
  f=$(mktemp) || die 1 'mktemp failed'
  trap 'rm -f "$f" "$f.now"' EXIT
  json=$(scope_or_die "$repo" "$n" "$f") || exit $?
  snap=$(cat "$f")
  if [[ "$(jq -r '.stopped // ""' <<< "$json")" == "$reason" ]]; then printf 'already stopped #%s\n' "$n"; exit 0; fi
  ln=$(jq -r .lines.stopped <<< "$json")
  if [[ "$ln" -gt 0 ]]; then set_line "$f" "$ln" "Stopped: $reason"
  else insert_after "$f" "$(jq -r .lines.wave <<< "$json")" "Stopped: $reason"; fi || die 1 'could not edit the body'
  prewrite_check "$repo" "$n" "$f" "$snap"
  write_body "$repo" "$n" "$f"
  json=$(scope_or_die "$repo" "$n" "$f") || die 1 "wrote #$n but could not verify the stop"
  [[ "$(jq -r '.stopped // ""' <<< "$json")" == "$reason" ]] || die 1 "wrote #$n but it does not show the stop"
  printf 'stopped filing on #%s: %s\n' "$n" "$reason"
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
  scope|scope-init|wave-due|wave-open|record|stop)
    verb="$1"
    case "$verb" in
      scope|wave-due) [[ $# -eq 3 ]] || die 2 "usage: pm-epic.sh $verb <owner/repo> <N>" ;;
      scope-init) [[ $# -eq 4 || $# -eq 5 ]] || die 2 'usage: pm-epic.sh scope-init <owner/repo> <N> <rows-file> [stop-reason]' ;;
      wave-open) [[ $# -eq 5 ]] || die 2 'usage: pm-epic.sh wave-open <owner/repo> <N> <K> <count>' ;;
      record) [[ $# -eq 5 ]] || die 2 'usage: pm-epic.sh record <owner/repo> <N> <S-id> <child>' ;;
      stop) [[ $# -eq 4 ]] || die 2 'usage: pm-epic.sh stop <owner/repo> <N> <reason>' ;;
    esac
    valid_repo "$2" || die 2 "not an owner/repo: $2"
    n=$(parse_arg "$3") || exit 2
    command -v jq >/dev/null 2>&1 || die 1 'jq is required'
    case "$verb" in
      scope) scope_cmd "$2" "$n" ;;
      scope-init)
        reason=$(printf '%s' "${5:-}" | tr '\r\n\t' '   ' | sed 's/^ *//; s/ *$//')
        [[ $# -eq 4 || -n "$reason" ]] || die 2 'an empty stop-reason'
        scope_init "$2" "$n" "$4" "$reason" ;;
      wave-due) wave_due "$2" "$n" ;;
      wave-open)
        [[ "$4" =~ ^[1-9][0-9]{0,3}$ ]] || die 2 "wave must be a positive number: $4"
        [[ "$5" =~ ^[1-9][0-9]{0,2}$ ]] || die 2 "count must be a positive number: $5"
        wave_open "$2" "$n" "$4" "$5" ;;
      record)
        [[ "$4" =~ ^S[0-9]+$ ]] || die 2 "not an item id: $4"
        child=$(parse_arg "$5") || exit 2
        record_cmd "$2" "$n" "$4" "$child" ;;
      stop)
        reason=$(printf '%s' "$4" | tr '\r\n\t' '   ' | sed 's/^ *//; s/ *$//')
        [[ -n "$reason" ]] || die 2 'stop needs a reason'
        stop_cmd "$2" "$n" "$reason" ;;
    esac ;;
  *) usage >&2; exit 2 ;;
esac
