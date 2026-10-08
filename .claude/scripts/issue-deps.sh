#!/usr/bin/env bash
# issue-deps.sh — The canonical reading of issue dependency markers: edges and transitive dependents.
# catalog: backlog-pm — Parse issue dependency markers (`Depends on #N`, `blocked by`, `unblocks`, …) from bodies and comments — the one reading `/pm` 1B.3, `/wave` 5.1, and the desk's derived impact share; `edges` and transitive `dependents`
#
# PURPOSE
#   The one parser of the dependency markers `/pm` Step 1B.3 lists, so `/pm`,
#   `/wave` (Step 5.1, which reuses what 1B.3 collected), and the human queue's
#   derived impact (`human-queue.sh impact`, issue #1760) read an issue's
#   dependencies the same way. It reads issue bodies AND comments, matches
#   every marker case-insensitively (`/issue-maker` writes `- Depends on #N`),
#   and turns them into blocker -> blocked edges.
#
# MARKERS (exact parity with /pm 1B.3)
#   Blocked direction — the issue carrying the marker is blocked by #N:
#     blocked by #N, depends on #N, prerequisite for #N, after #N
#   Unblocking direction — the issue carrying the marker blocks #N:
#     unblocks #N, enables #N, required by #N, before #N
#   Words may be separated by any whitespace; between the marker and `#N` any
#   run of spaces, colons, asterisks, or underscores is allowed, so
#   `**Depends on:** #12` reads like `depends on #12`. One `#N` per marker:
#   `depends on #12 and #13` reads #12 only, as 1B.3 does. A cross-repo
#   `owner/repo#N` never matches (the marker must be followed by `#`), and an
#   issue naming itself is ignored. Edges are deduplicated.
#   Known quirk, kept for parity: 1B.3 files `prerequisite for #N` under the
#   blocked direction although the phrase reads the other way, and has no bare
#   `blocks #N`. Changing either would change /pm's and /wave's behavior, so
#   it belongs to its own issue.
#
# USAGE
#   issue-deps.sh edges (<owner/repo> | --input FILE)
#   issue-deps.sh dependents (<owner/repo> | --input FILE) ISSUE [ISSUE ...]
#   issue-deps.sh parse < issues.json
#   issue-deps.sh --help | -h
#
#   <owner/repo>  read the repo's OPEN issues with
#                 `gh issue list --repo <owner/repo> --state open --limit 500
#                  --json number,body,comments` (one call; 500 is /pm's cap).
#                 gh stops at the limit without saying so, so a read that
#                 returns 500 issues may be cut off: it fails (exit 1) rather
#                 than undercount dependents
#   --input FILE  read that same JSON from FILE (`-` for stdin) instead: an
#                 array of {number, body, comments: [{body}], state?}. An
#                 entry whose `state` is present and not OPEN is dropped, so
#                 the set is always the open issues.
#   ISSUE         an issue number, with or without a leading `#`
#
# MODES
#   parse       stdin is the issue JSON; prints the edges array alone.
#   edges       prints {"repo", "open_issues", "edges": [{"blocker", "blocked"}]}
#               (repo is null with --input). Edges sorted by blocker, blocked.
#   dependents  prints {"repo", "open_issues", "issues": [{"issue", "direct",
#               "transitive", "count", "cycle"}]}, one entry per ISSUE in the
#               order given. `direct`: open issues blocked by ISSUE itself;
#               `transitive`: every open issue reachable along blocker ->
#               blocked edges (breadth first, each counted once, so a diamond
#               is not double-counted); `count`: the length of `transitive`;
#               `cycle`: true when the walk comes back to ISSUE. Only open
#               issues are dependents, and the walk only passes through open
#               issues: a closed one blocks nothing any more.
#
# EXIT STATUS
#   0  printed
#   1  the issue read failed (`gh` missing or failing, a <owner/repo> read
#      that reached the 500-issue limit, unreadable --input, or JSON that is
#      not an array of issues). Nothing is printed on stdout: a failed or
#      possibly cut-off read never reads as "no dependents"
#   2  usage error
#
# ENVIRONMENT
#   ISSUE_DEPS_GH  the gh binary (default: gh on PATH)
#
# EXAMPLES
#   issue-deps.sh dependents auerbachb/claude-code-config 1758
#   gh issue view 42 --json number,body,comments | jq -s . | issue-deps.sh parse
#   issue-deps.sh edges --input open-issues.json
#
# DEPENDENCIES
#   jq 1.6+, and gh (authenticated) for the <owner/repo> form.

set -uo pipefail
printf '%s\t%s\t%s\n' "$(date -u +%FT%TZ)" "$(basename "$0")" "${*//$'\n'/ }" 2>/dev/null >> "${HOME:-/tmp}/.claude/script-usage.log" || true

ME="issue-deps.sh"
ISSUE_LIMIT=500

print_help() {
  sed -n '/^# PURPOSE$/,/^$/{/^$/d;p;}' "$0" | sed 's/^# \{0,1\}//'
}

die() { local code="$1"; shift; printf '%s: %s\n' "$ME" "$*" >&2; exit "$code"; }
usage_err() { die 2 "$* (run with --help)"; }

# The canonical program. `edges_of` reads an issue array; the regexes are the
# marker set above, and the one place it is spelled. Case-insensitivity is the
# inline `(?i)` and scan has one argument: jq 1.6 has no scan/2 (scan(re; flags)
# arrived in 1.7), and this script promises 1.6.
JQ_LIB='
def blocked_re: "(?i)\\b(?:blocked\\s+by|depends\\s+on|prerequisite\\s+for|after)[\\s:*_]+#([0-9]+)\\b";
def unblocking_re: "(?i)\\b(?:unblocks|enables|required\\s+by|before)[\\s:*_]+#([0-9]+)\\b";
def open_only: map(select(type == "object" and (.number | type) == "number"
                          and ((.state // "OPEN") | ascii_upcase) == "OPEN"));
def texts: (.body // ""), ((.comments // [])[] | .body // "") | select(type == "string");
def edges_of:
  [ .[] | .number as $a
    | ( texts | scan(blocked_re) | {blocker: (.[0] | tonumber), blocked: $a} ),
      ( texts | scan(unblocking_re) | {blocker: $a, blocked: (.[0] | tonumber)} ) ]
  | map(select(.blocker != .blocked)) | unique_by([.blocker, .blocked]);
def adjacency($edges):
  reduce $edges[] as $e ({}; .[$e.blocker | tostring] += [$e.blocked]);
def dependents_of($adj; $open; $n):
  {queue: [$n], seen: {}, cycle: false}
  | until((.queue | length) == 0;
      .queue[0] as $cur
      | .queue |= .[1:]
      | reduce (($adj[$cur | tostring] // [])[] | select($open[tostring] == true)) as $d (.;
          if $d == $n then .cycle = true
          elif .seen[$d | tostring] then .
          else .seen[$d | tostring] = true | .queue += [$d] end))
  | { issue: $n,
      direct: ([ ($adj[$n | tostring] // [])[] | select($open[tostring] == true and . != $n) ] | unique),
      transitive: ([ .seen | keys[] | tonumber ] | sort),
      count: (.seen | length),
      cycle };
'

# read_issues REPO_OR_EMPTY INPUT_OR_EMPTY OUTFILE — the open issues as JSON.
read_issues() {
  local repo="$1" input="$2" out="$3" gh_bin
  if [[ -n "$input" ]]; then
    if [[ "$input" == "-" ]]; then
      cat > "$out" || die 1 "cannot read stdin"
    else
      [[ -r "$input" && -f "$input" ]] || die 1 "cannot read --input $input"
      cat "$input" > "$out" || die 1 "cannot read --input $input"
    fi
  else
    gh_bin="${ISSUE_DEPS_GH:-gh}"
    command -v "$gh_bin" >/dev/null 2>&1 || die 1 "gh not found — cannot read the issues of $repo"
    GH_PROMPT_DISABLED=1 GH_NO_UPDATE_NOTIFIER=1 NO_COLOR=1 GH_PAGER=cat \
      "$gh_bin" issue list --repo "$repo" --state open --limit "$ISSUE_LIMIT" --json number,body,comments \
      > "$out" 2>/dev/null </dev/null \
      || die 1 "gh issue list failed for $repo — dependents unknown (not zero)"
  fi
  jq -e 'type == "array"' "$out" >/dev/null 2>&1 || die 1 "the issue JSON is not an array of issues"
  # gh stops at --limit silently: a full page may be a cut-off list, and a
  # cut-off list undercounts dependents. --input is the caller's own set.
  if [[ -z "$input" ]]; then
    local n
    n=$(jq 'length' "$out" 2>/dev/null) || n=""
    [[ "$n" =~ ^[0-9]+$ ]] || die 1 "cannot count the issues read for $repo"
    (( n < ISSUE_LIMIT )) \
      || die 1 "gh issue list returned $n open issues for $repo, its $ISSUE_LIMIT-issue limit — the list may be cut off, so dependents are unknown (not zero)"
  fi
}

check_repo() {
  [[ "$1" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]] || usage_err "expected <owner/repo>, got '$1'"
}

command -v jq >/dev/null 2>&1 || die 1 "jq not found"

case "${1:-}" in
  -h|--help) print_help; exit 0 ;;
  '') usage_err "missing mode (edges, dependents, or parse)" ;;
esac

mode="$1"
shift
repo=""
input=""
issues=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help) print_help; exit 0 ;;
    --input)
      [[ $# -ge 2 ]] || usage_err "--input needs a file"
      [[ -z "$input" ]] || usage_err "--input given more than once"
      input="$2"
      shift 2
      ;;
    -*) usage_err "unknown flag $1" ;;
    *)
      if [[ "$mode" != "parse" && -z "$repo" && -z "$input" && "${#issues[@]}" -eq 0 && "$1" == */* ]]; then
        check_repo "$1"
        repo="$1"
      else
        n="${1#\#}"
        [[ "$n" =~ ^[1-9][0-9]{0,9}$ ]] || usage_err "not an issue number: '$1'"
        issues+=("$n")
      fi
      shift
      ;;
  esac
done

TMP_JSON=$(mktemp "${TMPDIR:-/tmp}/issue-deps.XXXXXX") || die 1 "cannot create a temp file"
trap 'rm -f "$TMP_JSON"' EXIT

case "$mode" in
  parse)
    [[ -z "$repo" && -z "$input" && "${#issues[@]}" -eq 0 ]] || usage_err "parse takes no arguments (the issue JSON is stdin)"
    read_issues "" "-" "$TMP_JSON"
    jq -c "$JQ_LIB"' open_only | edges_of' "$TMP_JSON" || die 1 "cannot parse the issue JSON"
    ;;
  edges|dependents)
    if [[ -n "$repo" && -n "$input" ]]; then usage_err "give <owner/repo> or --input, not both"; fi
    if [[ -z "$repo" && -z "$input" ]]; then usage_err "$mode needs <owner/repo> or --input FILE"; fi
    if [[ "$mode" == "edges" && "${#issues[@]}" -gt 0 ]]; then usage_err "edges takes no issue numbers"; fi
    if [[ "$mode" == "dependents" && "${#issues[@]}" -eq 0 ]]; then usage_err "dependents needs at least one issue number"; fi
    read_issues "$repo" "$input" "$TMP_JSON"
    ISSUES_JSON=$(printf '%s\n' ${issues[@]+"${issues[@]}"} | jq -s -c 'map(select(. != null))') \
      || die 1 "cannot build the issue list"
    jq -c --arg repo "$repo" --arg mode "$mode" --argjson want "$ISSUES_JSON" "$JQ_LIB"'
      open_only
      | . as $all
      | edges_of as $edges
      | (reduce $all[] as $i ({}; .[$i.number | tostring] = true)) as $open
      | {repo: (if $repo == "" then null else $repo end), open_issues: ($all | length)}
      + if $mode == "edges" then {edges: ($edges | sort_by([.blocker, .blocked]))}
        else (adjacency($edges)) as $adj
             | {issues: [ $want[] | dependents_of($adj; $open; .) ]}
        end' "$TMP_JSON" || die 1 "cannot parse the issue JSON"
    ;;
  *) usage_err "unknown mode '$mode'" ;;
esac
