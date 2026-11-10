#!/usr/bin/env bash
# pr-summary-material.sh — prints the raw material for summarizing one merged
# PR or filed issue at the depth the operator asked for (issue #1756). The desk
# writes the summary from it; this script only reads GitHub. Design:
# desk/DESIGN.md 2.5 and 2.7; contract: desk/README.md "Reviews".
# catalog: utilities — Human-queue Reviews material (`desk/bin/pr-summary-material.sh`): prints a PR's or issue's raw material for a level 1, 2, or 3 summary (title, labels, closing issue; body, commits, files, tests; the bounded diff, narrowed by --path); read-only
#
# USAGE
#   pr-summary-material.sh OWNER/REPO N --level 1|2|3 [--path FILE]
#   pr-summary-material.sh --help
#
#   N is the PR or issue number, or a Review's key: pr-N or issue-N (which
#   must then be that kind).
#
# LEVELS (a PR)
#   1  ## Title, ## Labels, ## Closes (each closing issue as OWNER/REPO#N —
#      title, or "none")
#   2  level 1, plus ## Size, ## Body (capped), ## Commits (subjects),
#      ## Files changed (path +added -deleted), ## Tests touched (the changed
#      files that are tests), ## Links
#   3  ## Diff: the PR's diff, capped by lines and bytes; --path FILE keeps
#      only FILE's section (matched on the diff header, the ---/+++ lines,
#      or a rename)
# LEVELS (an issue)
#   1  ## Title, ## Labels, ## Body (excerpt)
#   2  ## Title, ## Labels, ## Body (capped), ## Links
#   3  ## Body: the full body
#
# OUTPUT
#   A header line (`PR OWNER/REPO#N · merged ...` or `Issue OWNER/REPO#N ·
#   open · filed ...`), then the `## Section` blocks above. A section cut
#   short by a cap ends with a `[truncated: ...]` line; a list GitHub returned
#   only in part (more than 20 labels, 10 closing issues, or 100 commits or
#   files) says how many are missing, and Tests touched says how many files
#   it could not check. GitHub's text is untrusted: a CRLF prints as LF, and
#   every other control character but tab and newline prints as "?".
#   Nothing is stored or cached: level 2 is cached by the desk as text with
#   `human-queue.sh summary set`, and level 3 is never stored.
#
# ENVIRONMENT
#   HUMAN_QUEUE_GH            gh binary override (tests point it at a stub)
#   HUMAN_QUEUE_GH_TIMEOUT    seconds each GitHub call may take (default 60)
#   HQ_MATERIAL_EXCERPT_CHARS level 1 issue body excerpt (default 600)
#   HQ_MATERIAL_BODY_CHARS    level 2 body cap (default 6000)
#   HQ_MATERIAL_DIFF_LINES    level 3 diff cap in lines (default 2000)
#   HQ_MATERIAL_DIFF_BYTES    level 3 diff cap in bytes (default 200000)
#
# EXIT CODES
#   0  ok
#   1  GitHub failed: gh or jq missing, not authenticated, timed out, or a
#      diff GitHub will not render (too large: narrow with --path does not
#      help, read the files one by one on github.com)
#   3  no PR or issue with that number, a pr-N/issue-N key of the other
#      kind, or --path names no file in the diff
#   4  usage: missing or malformed arguments, --path below level 3 or on an
#      issue, a cap that is not a positive whole number
#
# Bash 3.2 compatible (macOS /bin/bash).
set -euo pipefail

hq__self="${BASH_SOURCE[0]}"
while [ -L "$hq__self" ]; do
  hq__link_dir=$(cd -P "$(dirname "$hq__self")" && pwd)
  hq__self=$(readlink "$hq__self")
  case "$hq__self" in
    /*) ;;
    *) hq__self="$hq__link_dir/$hq__self" ;;
  esac
done
HQ_BIN_DIR=$(cd -P "$(dirname "$hq__self")" && pwd)
unset hq__self hq__link_dir

# shellcheck source=lib/common.sh
. "$HQ_BIN_DIR/lib/common.sh"
# shellcheck source=lib/github.sh
. "$HQ_BIN_DIR/lib/github.sh"

HQ_EXIT_NOT_FOUND=3

usage() {
  sed -n '/^# USAGE/,/^# Bash 3.2/p' "$HQ_BIN_DIR/pr-summary-material.sh" \
    | sed -e '$d' -e 's/^# \{0,1\}//'
}

die_usage() { hq_die_validation "pr-summary-material: $*"; }
die_gh() { hq_die_error "pr-summary-material: $*"; }
die_not_found() { hq_die "$HQ_EXIT_NOT_FOUND" "pr-summary-material: $*"; }

# cap NAME DEFAULT — a positive whole number from the environment, or DEFAULT.
cap() {
  local name="$1" v
  v="${!name:-$2}"
  case "$v" in
    ''|*[!0-9]*|0*) die_usage "$1 must be a positive whole number" ;;
  esac
  if [ "${#v}" -gt 9 ]; then die_usage "$1 is too large"; fi
  printf '%s\n' "$v"
}

# The one GraphQL query: the type (PR or issue) and everything levels 1 and 2
# need, in one round trip. Closing issues come with their titles.
graphql_query() {
  cat <<'GQL'
query($owner: String!, $name: String!, $number: Int!) {
  repository(owner: $owner, name: $name) {
    nameWithOwner
    issueOrPullRequest(number: $number) {
      __typename
      ... on PullRequest {
        number title url state body mergedAt closedAt createdAt
        additions deletions changedFiles
        labels(first: 20) { totalCount nodes { name } }
        closingIssuesReferences(first: 10) { totalCount nodes { number title url repository { nameWithOwner } } }
        commits(first: 100) { totalCount nodes { commit { messageHeadline } } }
        files(first: 100) { totalCount nodes { path additions deletions } }
      }
      ... on Issue {
        number title url state body createdAt closedAt
        labels(first: 20) { totalCount nodes { name } }
      }
    }
  }
}
GQL
}

# The renderer for levels 1 and 2 (and the header line for every level).
render_jq() {
  cat <<'JQ'
def when($t): if $t == null then "" else ($t[0:16] | sub("T"; " ")) + " UTC" end;
def section($name; $body): "## " + $name + "\n" + $body;
def lines($xs): if ($xs | length) == 0 then "none" else ($xs | join("\n")) end;
def capped($s; $n):
  if ($s | length) > $n
  then $s[0:$n] + "\n[truncated: " + ($n | tostring) + " of " + ($s | length | tostring) + " characters shown]"
  else $s end;
def body: (.body // "") | if test("\\S") then . else "(empty)" end;
def more($shown; $total; $what):
  if $total > $shown then ["… and " + (($total - $shown) | tostring) + " more " + $what + " not listed"] else [] end;
def labels: [.labels.nodes[]?.name] as $n
  | lines((if ($n | length) == 0 then [] else [$n | join(", ")] end)
          + more(($n | length); (.labels.totalCount // 0); "labels"));
# GitHub text is untrusted: CRLF becomes LF, and every other control
# character but tab and newline (C0, DEL, C1) prints as "?", so nothing can
# drive the terminal that shows the material.
def safe: gsub("\r\n"; "\n")
  | explode
  | map(if (. < 32 and . != 9 and . != 10) or (. >= 127 and . < 160) then 63 else . end)
  | implode;
def tests: test("(^|/)(tests?|spec|specs|__tests__)/|\\.test\\.|_test\\.|\\.spec\\.|(^|/)test_[^/]*$");

.data.repository as $r
| $r.issueOrPullRequest as $x
| ($r.nameWithOwner + "#" + ($x.number | tostring)) as $ref
| if $x.__typename == "PullRequest" then
    ([ "PR " + $ref + " · "
       + (if $x.mergedAt != null then "merged " + when($x.mergedAt)
          else ($x.state | ascii_downcase) + ", opened " + when($x.createdAt) end) ]
     + if $level == 3 then [] else
       [ section("Title"; $x.title),
         section("Labels"; $x | labels),
         section("Closes"; lines([$x.closingIssuesReferences.nodes[]?
                                  | .repository.nameWithOwner + "#" + (.number | tostring) + " — " + .title]
                                 + more(($x.closingIssuesReferences.nodes | length);
                                        ($x.closingIssuesReferences.totalCount // 0); "closing issues"))) ]
       + if $level == 1 then [] else
         [ section("Size"; (($x.changedFiles // 0) | tostring) + " files · +"
                           + (($x.additions // 0) | tostring) + " -" + (($x.deletions // 0) | tostring)
                           + " · " + (($x.commits.totalCount // 0) | tostring) + " commits"),
           section("Body"; capped($x | body; $body_chars)),
           section("Commits (" + (($x.commits.totalCount // 0) | tostring) + ")";
                   lines([$x.commits.nodes[]? | "- " + .commit.messageHeadline]
                         + more(($x.commits.nodes | length); ($x.commits.totalCount // 0); "commits"))),
           section("Files changed (" + (($x.changedFiles // 0) | tostring) + ")";
                   lines([$x.files.nodes[]? | "- " + .path + " +" + (.additions | tostring) + " -" + (.deletions | tostring)]
                         + more(($x.files.nodes | length); ($x.changedFiles // 0); "files"))),
           section("Tests touched"; lines([$x.files.nodes[]? | .path | select(tests) | "- " + .]
                                          + (($x.files.nodes | length) as $seen
                                             | (($x.changedFiles // 0) - $seen) as $rest
                                             | if $rest > 0
                                               then ["… " + ($rest | tostring) + " more files not checked (GitHub lists the first "
                                                     + ($seen | tostring) + ")"]
                                               else [] end))),
           section("Links"; lines(["- PR: " + $x.url]
                                  + [$x.closingIssuesReferences.nodes[]? | "- Closes: " + .url]
                                  + more(($x.closingIssuesReferences.nodes | length);
                                         ($x.closingIssuesReferences.totalCount // 0); "closing issues"))) ]
         end
       end)
    | join("\n") | safe
  else
    ([ "Issue " + $ref + " · " + ($x.state | ascii_downcase) + " · filed " + when($x.createdAt) ]
     + if $level == 3 then [ section("Body"; $x | body) ]
       else
         [ section("Title"; $x.title), section("Labels"; $x | labels) ]
         + if $level == 1 then [ section("Body (excerpt)"; capped($x | body; $excerpt_chars)) ]
           else [ section("Body"; capped($x | body; $body_chars)), section("Links"; "- Issue: " + $x.url) ]
           end
       end)
    | join("\n") | safe
  end
JQ
}

# keep_path FILE — awk: keeps only the diff sections that name FILE (on the
# `diff --git` header, or before the first hunk on a ---/+++ or rename line).
# The path comes from the environment, never from awk's -v (which would
# interpret backslashes). Exit 3 when no section matched.
keep_path_awk() {
  cat <<'AWK'
function flush() {
  if (insec && hit) { printf "%s", buf; found = 1 }
  buf = ""; insec = 0; hit = 0; hdr = 0
}
BEGIN { p = ENVIRON["HQ_MATERIAL_PATH"]; found = 0 }
/^diff --git / {
  flush()
  insec = 1; hdr = 1; buf = $0 "\n"
  hit = ($0 == "diff --git a/" p " b/" p)
  next
}
insec && hdr && /^@@/ { hdr = 0 }
insec && hdr && ($0 == "--- a/" p || $0 == "+++ b/" p || $0 == "rename from " p || $0 == "rename to " p) { hit = 1 }
insec { buf = buf $0 "\n" }
END { flush(); exit(found ? 0 : 3) }
AWK
}

# The cap on lines and bytes, then one truncation line saying what was cut.
cap_awk() {
  cat <<'AWK'
BEGIN { maxl = ENVIRON["HQ_L"] + 0; maxb = ENVIRON["HQ_B"] + 0; n = 0; b = 0; total = 0; cut = 0 }
{
  total++
  sub(/\r$/, "")
  gsub(/[\001-\010\013-\037\177]/, "?")
  gsub(/\302[\200-\237]/, "?")
  if (!cut && n < maxl && b + length($0) + 1 <= maxb) { print; n++; b += length($0) + 1 }
  else { cut = 1 }
}
END {
  if (total == 0) print "(empty diff)"
  if (cut) printf "[truncated: %d of %d lines shown (caps: %d lines, %d bytes); narrow with --path]\n", n, total, maxl, maxb
}
AWK
}

main() {
  local repo="" raw_n="" level="" path="" have_path=0 want="" n owner name
  local excerpt_chars body_chars diff_lines diff_bytes
  local out err rc=0 typ diff filtered nf
  local repo_re='^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$' num_re='^[1-9][0-9]{0,9}$'

  while [ "$#" -gt 0 ]; do
    case "$1" in
      -h|--help)
        usage
        exit 0
        ;;
      --level)
        if [ -n "$level" ]; then die_usage "--level given more than once"; fi
        if [ "$#" -lt 2 ]; then die_usage "--level needs a value: 1, 2, or 3"; fi
        level="$2"
        shift 2
        ;;
      --path)
        if [ "$have_path" -eq 1 ]; then die_usage "--path given more than once"; fi
        if [ "$#" -lt 2 ]; then die_usage "--path needs a file path"; fi
        have_path=1
        path="$2"
        shift 2
        ;;
      -*) die_usage "unknown option (run pr-summary-material.sh --help)" ;;
      *)
        if [ -z "$repo" ]; then repo="$1"
        elif [ -z "$raw_n" ]; then raw_n="$1"
        else die_usage "takes OWNER/REPO and one number (run pr-summary-material.sh --help)"
        fi
        shift
        ;;
    esac
  done

  if [ -z "$repo" ] || [ -z "$raw_n" ]; then
    die_usage "missing OWNER/REPO or number (run pr-summary-material.sh --help)"
  fi
  if [ "${#repo}" -gt 200 ] || ! [[ $repo =~ $repo_re ]]; then
    die_usage "the repository must be OWNER/REPO"
  fi
  case "$raw_n" in
    pr-*) want=PullRequest; n="${raw_n#pr-}" ;;
    issue-*) want=Issue; n="${raw_n#issue-}" ;;
    *) n="$raw_n" ;;
  esac
  if ! [[ $n =~ $num_re ]]; then
    die_usage "the number must be a positive whole number, pr-N, or issue-N"
  fi
  case "$level" in
    1|2|3) ;;
    '') die_usage "missing --level 1|2|3" ;;
    *) die_usage "--level must be 1, 2, or 3" ;;
  esac
  if [ "$have_path" -eq 1 ]; then
    if [ "$level" != 3 ]; then
      die_usage "--path narrows the level 3 diff; give --level 3"
    fi
    case "$path" in
      *[![:space:]]*) ;;
      *) die_usage "--path is empty" ;;
    esac
    case "$path" in
      *[[:cntrl:]]*) die_usage "--path contains a control character" ;;
    esac
  fi
  excerpt_chars=$(cap HQ_MATERIAL_EXCERPT_CHARS 600)
  body_chars=$(cap HQ_MATERIAL_BODY_CHARS 6000)
  diff_lines=$(cap HQ_MATERIAL_DIFF_LINES 2000)
  diff_bytes=$(cap HQ_MATERIAL_DIFF_BYTES 200000)
  # PR and issue numbers are GraphQL Ints (32-bit signed): GitHub has none
  # above this, and the query would fail on the variable rather than say so.
  if [ "$n" -gt 2147483647 ]; then
    die_not_found "no PR or issue $repo#$n"
  fi
  owner="${repo%%/*}"
  name="${repo#*/}"

  hq_gh_find || die_gh "gh not found (HUMAN_QUEUE_GH, /opt/homebrew/bin/gh, or PATH)"
  hq_jq_find || die_gh "jq not found (PATH, /opt/homebrew/bin/jq, or /usr/bin/jq)"
  hq_mktemp out
  hq_mktemp err
  hq_gh "$out" "$err" api graphql -f query="$(graphql_query)" \
    -f owner="$owner" -f name="$name" -F number="$n" || rc=$?
  if [ "$rc" -eq 124 ]; then
    die_gh "GitHub did not answer within $(hq__gh_timeout)s"
  fi
  # A missing repository or number is a GraphQL NOT_FOUND error: gh exits
  # non-zero but still prints the response, which says so. An empty or
  # unreadable answer is not "not found": it falls through to the failure.
  nf=$(hq_jq -r 'if any(.errors[]?; .type == "NOT_FOUND")
                       or (.data != null and .data.repository.issueOrPullRequest == null)
                     then "yes" else "no" end' "$out" 2>/dev/null || true)
  if [ "$nf" = yes ]; then
    die_not_found "no PR or issue $repo#$n"
  fi
  if [ "$rc" -ne 0 ]; then
    die_gh "GitHub failed: $(hq_gh_first_error "$err")"
  fi
  typ=$(hq_jq -r '.data.repository.issueOrPullRequest.__typename // ""' "$out" 2>/dev/null || true)
  case "$typ" in
    PullRequest|Issue) ;;
    *) die_gh "GitHub returned an unexpected answer for $repo#$n" ;;
  esac
  if [ -n "$want" ] && [ "$want" != "$typ" ]; then
    if [ "$typ" = Issue ]; then
      die_not_found "$repo#$n is an issue, not a PR (use issue-$n)"
    fi
    die_not_found "$repo#$n is a PR, not an issue (use pr-$n)"
  fi
  if [ "$have_path" -eq 1 ] && [ "$typ" = Issue ]; then
    die_usage "--path narrows a PR's diff; $repo#$n is an issue"
  fi

  rc=0
  hq_jq -r --argjson level "$level" --argjson body_chars "$body_chars" \
    --argjson excerpt_chars "$excerpt_chars" "$(render_jq)" "$out" 2>"$err" || rc=$?
  if [ "$rc" -ne 0 ]; then
    die_gh "could not read GitHub's answer: $(hq_gh_first_error "$err")"
  fi
  if [ "$level" != 3 ] || [ "$typ" = Issue ]; then
    return 0
  fi

  # Level 3 of a PR: the whole diff into a file first (never piped into a
  # reader that may stop early), then narrowed, then capped. GitHub bounds
  # the file: it refuses to render a diff past its own size limits (exit 1).
  hq_mktemp diff
  rc=0
  hq_gh "$diff" "$err" pr diff "$n" --repo "$repo" --color never || rc=$?
  if [ "$rc" -eq 124 ]; then
    die_gh "GitHub did not return the diff within $(hq__gh_timeout)s"
  fi
  if [ "$rc" -ne 0 ]; then
    die_gh "GitHub did not return the diff: $(hq_gh_first_error "$err")"
  fi
  if [ "$have_path" -eq 1 ]; then
    hq_mktemp filtered
    rc=0
    HQ_MATERIAL_PATH="$path" LC_ALL=C awk "$(keep_path_awk)" "$diff" >"$filtered" || rc=$?
    if [ "$rc" -eq 3 ]; then
      die_not_found "no file '$path' in the diff of $repo#$n"
    fi
    if [ "$rc" -ne 0 ]; then
      die_gh "could not narrow the diff (awk exited $rc)"
    fi
    diff="$filtered"
    printf '## Diff: %s\n' "$path"
  else
    printf '## Diff\n'
  fi
  HQ_L="$diff_lines" HQ_B="$diff_bytes" LC_ALL=C awk "$(cap_awk)" "$diff"
}

main "$@"
