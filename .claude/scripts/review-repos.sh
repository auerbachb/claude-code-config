#!/usr/bin/env bash
# review-repos.sh — Print the repos we run AI review in, one owner/name per line.
# catalog: review-escalation — Resolve the registered AI-review repos (`REVIEW_REPOS`, then the account config's `## Review repos` list, then `ac-gate.yml` discovery) for `/review-stack-audit`'s multi-repo roll-up
#
# PURPOSE
#   The AI review vendors bill one account across every repo they review, so a
#   per-repo measurement can never show what a reviewer is really drawing down
#   (issue #1747). This script is the one answer to "which repos are those?",
#   so `measure.sh --all-repos` can measure all of them in one run (#1808).
#
#   It never returns a partial list. Every source is read in full before
#   anything is printed, and any failure exits 1 with empty stdout: a roll-up
#   that silently dropped a repo would understate every tool's account-level
#   draw, which is the number the roll-up exists to report.
#
# USAGE
#   review-repos.sh [--fixture <path> | --no-discovery]
#   review-repos.sh --help | -h
#
# RESOLUTION ORDER
#   The first source that yields a repo wins; sources never merge.
#     1. REVIEW_REPOS env — owner/name entries separated by commas and/or
#        whitespace. Set but blank counts as unset.
#     2. The explicit list in the account config's `## Review repos` section,
#        read with `pm-config-get.sh --file <config>`, where <config> is
#        CLAUDE_ACCOUNT_CONFIG or, by default, ~/.claude/account-config.md.
#        EVERY Markdown bullet in the section is a list entry, and its first
#        token (backticks stripped) must be owner/name — a bullet that is not
#        fails the whole list, so a typo such as `- acme-sales-kit` can never
#        be skipped quietly. Notes belong in plain lines or HTML comments;
#        comments are stripped first, so a bullet inside one is a note.
#     3. Discovery — every non-archived repo owned by `owner` whose default
#        branch carries .github/workflows/<discovery_marker>. Both keys come
#        from `key = value` lines in the same section; defaults are the
#        authenticated gh user and ac-gate.yml. One paginated GraphQL query,
#        so a missing marker reads as null rather than as an ambiguous 404.
#   The explicit list is the record; discovery is a convenience. A repo we
#   review without running the harness in it still draws down the account caps
#   and is invisible to discovery, so it belongs in the list.
#
# FLAGS
#   --fixture <path>  Read discovery's GraphQL response (one or more
#                     `{"data":{"repositoryOwner":...}}` pages) from a file
#                     instead of calling gh. Only step 3 reads it, so steps 1
#                     and 2 still win when they resolve. Same jq filter as the
#                     live path, so tests exercise the real one. With no
#                     configured owner, the owner filter is skipped.
#   --no-discovery    Stop after steps 1 and 2: if neither resolves, exit 1
#                     without calling gh. For offline callers — measure.sh
#                     passes it under its own --fixture, so a fixture run can
#                     never reach the network through --all-repos.
#
# OUTPUT
#   One owner/name per line on stdout, in source order, de-duplicated
#   case-insensitively (first spelling kept). Diagnostics go to stderr.
#
# EXIT STATUS
#   0  At least one repo printed.
#   1  Nothing resolved, a source failed (discovery error, unreadable config,
#      missing helper), or an entry is not owner/name. Nothing is printed.
#   2  Usage error.
#
# EXAMPLES
#   review-repos.sh
#   REVIEW_REPOS=auerbachb/claude-code-config,auerbachb/sales-kit review-repos.sh
#   CLAUDE_ACCOUNT_CONFIG=/tmp/account-config.md review-repos.sh

set -uo pipefail
printf '%s\t%s\t%s\n' "$(date -u +%FT%TZ)" "$(basename "$0")" "${*//$'\n'/ }" 2>/dev/null >> "$HOME/.claude/script-usage.log" || true

print_help() {
  awk 'NR == 1 { next } /^# catalog:/ { next } /^#/ { sub(/^# ?/, ""); print; n = 1; next } { exit } END { exit(n ? 0 : 1) }' "$0" ||
    { printf '%s: --help header extraction produced no output\n' "$0" >&2; exit 70; }
}

usage_error() {
  echo "review-repos.sh: $1" >&2
  echo "Run with --help for usage." >&2
  exit 2
}

die() {
  echo "review-repos.sh: $1" >&2
  exit 1
}

FIXTURE=""
NO_DISCOVERY=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help) print_help; exit 0 ;;
    --fixture)
      [[ $# -ge 2 && -n "$2" ]] || usage_error "--fixture requires a value"
      FIXTURE="$2"; shift 2 ;;
    --fixture=*)
      FIXTURE="${1#--fixture=}"; [[ -n "$FIXTURE" ]] || usage_error "--fixture value cannot be empty"; shift ;;
    --no-discovery) NO_DISCOVERY=1; shift ;;
    --) shift; break ;;
    -*) usage_error "unknown flag: $1" ;;
    *)  usage_error "unexpected positional argument: $1" ;;
  esac
done
[[ $# -eq 0 ]] || usage_error "unexpected positional argument: $1"
[[ -n "$FIXTURE" && "$NO_DISCOVERY" -eq 1 ]] && usage_error "--fixture feeds discovery; it cannot be combined with --no-discovery"

# owner/name. The owner is a login: it starts alphanumeric and never holds a
# `.` (ordinary logins are [A-Za-z0-9-]; Enterprise Managed User logins add
# `_`). The name may hold `_` and `.` and may even start with `.` (`.github`),
# but is never exactly `.` or `..` — every entry ends up in a
# `gh api repos/<owner>/<name>/...` path, where a dot segment would address
# some other endpoint. Beyond that the check stays permissive, because a
# rejection is never a quiet skip: emit_validated fails the whole source
# (exit 1), so an over-strict pattern would block every --all-repos run.
REPO_RE='^[A-Za-z0-9][A-Za-z0-9_-]*/[A-Za-z0-9_.-]+$'
# A workflow file name, never a path: it is spliced into a git object
# expression, so a `/` or `..` here would read some other file.
MARKER_RE='^[A-Za-z0-9_][A-Za-z0-9_.-]*$'
OWNER_RE='^[A-Za-z0-9][A-Za-z0-9_-]*$'

# emit_validated <source-label> — read candidate entries on stdin, one per line,
# and print the de-duplicated list. Any malformed entry fails the WHOLE source:
# printing the valid remainder would be exactly the partial list this script
# promises never to return.
emit_validated() {
  local label="$1" entry list=""
  while IFS= read -r entry || [[ -n "$entry" ]]; do
    [[ -n "$entry" ]] || continue
    [[ "$entry" =~ $REPO_RE && "${entry#*/}" != "." && "${entry#*/}" != ".." ]] \
      || die "$label entry is not owner/name: '$entry'"
    list+="$entry"$'\n'
  done
  [[ -n "$list" ]] || return 1
  printf '%s' "$list" | awk '!seen[tolower($0)]++'
}

# resolve_helper <name> — this checkout's sibling first (version-consistent with
# the caller), then the published locations per portable-skill-resolution.md.
resolve_helper() {
  local name="$1" here c
  here="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)" || here=""
  for c in \
    ${here:+"$here/$name"} \
    "$HOME/.claude/skills-worktree/.claude/scripts/$name" \
    "$HOME/.claude/scripts/$name" \
    ".claude/scripts/$name"; do
    if [[ -x "$c" ]]; then echo "$c"; return 0; fi
  done
  return 1
}

# --- 1. REVIEW_REPOS env --------------------------------------------------------
if [[ -n "${REVIEW_REPOS:-}" ]]; then
  env_list="$(printf '%s\n' "$REVIEW_REPOS" | tr ',' '\n' | tr -s ' \t' '\n\n')"
  if out="$(printf '%s\n' "$env_list" | emit_validated "REVIEW_REPOS")"; then
    printf '%s\n' "$out"
    exit 0
  fi
  # emit_validated fails for two reasons: a malformed entry (it has already
  # said so on stderr) or no entries at all. Only the second falls through —
  # a value that is blank after splitting (", ,") counts as unset.
  if grep -q '[^[:space:]]' <<<"$env_list"; then
    exit 1
  fi
fi

# --- 2. The account config's explicit list ---------------------------------------
CONFIG="${CLAUDE_ACCOUNT_CONFIG:-$HOME/.claude/account-config.md}"
OWNER=""
MARKER=""
if [[ -e "$CONFIG" || -L "$CONFIG" ]]; then
  # Present but unreadable is a broken record, not an absent one: falling
  # through to discovery would silently replace the list a human wrote.
  [[ -f "$CONFIG" && -r "$CONFIG" ]] || die "account config is not a readable file: $CONFIG"
  PM_CONFIG_GET="$(resolve_helper pm-config-get.sh)" \
    || die "pm-config-get.sh not found (checked this checkout and all three published paths) — cannot read $CONFIG"
  section="$("$PM_CONFIG_GET" --file "$CONFIG" --section "Review repos")"
  rc=$?
  case "$rc" in
    0) ;;
    1) section="" ;;                 # no such section, or empty: discovery
    *) die "pm-config-get.sh failed reading $CONFIG (rc=$rc)" ;;
  esac

  if [[ -n "$section" ]]; then
    # One pass, tagged lines: `repo <v>`, `owner <v>`, `marker <v>`.
    parsed="$(printf '%s\n' "$section" | awk '
      # HTML comments are notes, never entries: strip them first, including
      # ones spanning lines, so a bullet or key=value line inside a comment is
      # invisible here just as it is in the rendered Markdown (same stripping
      # as review-tier.sh).
      {
        line = $0; out = ""
        while (1) {
          if (comment) {
            i = index(line, "-->")
            if (i == 0) { line = ""; break }
            line = substr(line, i + 3); comment = 0
          } else {
            i = index(line, "<!--")
            if (i == 0) { out = out line; break }
            out = out substr(line, 1, i - 1); line = substr(line, i + 4); comment = 1
          }
        }
        $0 = out
      }
      /^[[:space:]]*[-*+][[:space:]]+/ {
        line = $0
        sub(/^[[:space:]]*[-*+][[:space:]]+/, "", line)
        split(line, f, /[[:space:]]+/)
        tok = f[1]
        gsub(/`/, "", tok)
        # Every bullet is an entry: emit it even when it is not owner/name,
        # so emit_validated refuses the list instead of this parser dropping
        # the bad line.
        print "repo\t" tok
        next
      }
      /^[[:space:]]*owner[[:space:]]*=/ {
        v = $0; sub(/^[^=]*=[[:space:]]*/, "", v); sub(/[[:space:]]+$/, "", v)
        print "owner\t" v; next
      }
      /^[[:space:]]*discovery_marker[[:space:]]*=/ {
        v = $0; sub(/^[^=]*=[[:space:]]*/, "", v); sub(/[[:space:]]+$/, "", v)
        print "marker\t" v; next
      }
    ')" || die "could not parse the Review repos section of $CONFIG"
    OWNER="$(printf '%s\n' "$parsed" | awk -F'\t' '$1 == "owner" { v = $2 } END { print v }')"
    MARKER="$(printf '%s\n' "$parsed" | awk -F'\t' '$1 == "marker" { v = $2 } END { print v }')"
    config_list="$(printf '%s\n' "$parsed" | awk -F'\t' '$1 == "repo" { print $2 }')"
    if [[ -n "$config_list" ]]; then
      out="$(printf '%s\n' "$config_list" | emit_validated "account config ($CONFIG)")" || exit 1
      printf '%s\n' "$out"
      exit 0
    fi
  fi
fi

# --- 3. Discovery ---------------------------------------------------------------
[[ "$NO_DISCOVERY" -eq 0 ]] \
  || die "no repos registered (REVIEW_REPOS unset, no list in $CONFIG) and --no-discovery forbids discovery"
MARKER="${MARKER:-ac-gate.yml}"
[[ "$MARKER" =~ $MARKER_RE ]] || die "discovery_marker must be a workflow file name, got '$MARKER'"
command -v jq >/dev/null 2>&1 || die "jq not found — discovery unavailable"

if [[ -n "$FIXTURE" ]]; then
  [[ -r "$FIXTURE" ]] || die "fixture not readable: $FIXTURE"
  raw="$(cat "$FIXTURE")" || die "fixture not readable: $FIXTURE"
else
  command -v gh >/dev/null 2>&1 || die "gh not found — discovery unavailable (or set REVIEW_REPOS)"
  if [[ -z "$OWNER" ]]; then
    OWNER="$(gh api user --jq .login 2>/dev/null)" || die "discovery has no owner: set 'owner = <login>' in $CONFIG"
  fi
  [[ -n "$OWNER" ]] || die "discovery has no owner: set 'owner = <login>' in $CONFIG"
fi
[[ -z "$OWNER" || "$OWNER" =~ $OWNER_RE ]] || die "owner must be a GitHub login, got '$OWNER'"

if [[ -z "$FIXTURE" ]]; then
  # ownerAffiliations is NOT relied on: the RepositoryOwner interface's
  # `repositories` returns collaborator repos for a user too, so the owner
  # filter below is applied client-side regardless.
  QUERY='query($owner: String!, $expr: String!, $endCursor: String) {
  repositoryOwner(login: $owner) {
    repositories(first: 100, after: $endCursor, orderBy: {field: NAME, direction: ASC}) {
      pageInfo { hasNextPage endCursor }
      nodes { nameWithOwner isArchived object(expression: $expr) { id } }
    }
  }
}'
  # stderr goes to a file, not into $raw: a gh warning on a SUCCESSFUL call
  # would otherwise be parsed as part of the JSON stream.
  ERRF="$(mktemp)" || die "mktemp failed"
  if ! raw="$(gh api graphql --paginate -f owner="$OWNER" -f expr="HEAD:.github/workflows/$MARKER" -f query="$QUERY" 2>"$ERRF")"; then
    msg="$(head -c 400 "$ERRF" 2>/dev/null)"; rm -f "$ERRF"
    die "discovery query failed for owner '$OWNER': $msg"
  fi
  rm -f "$ERRF"
fi

# Each page is filtered on its own (gh --paginate concatenates them). A page
# with no repositoryOwner — unknown owner, or a GraphQL error envelope — is a
# failed discovery, never an empty one. So is a page carrying `errors` beside
# its `data`: GraphQL returns partial data that way, and its nodes may be
# missing repos. `gh api graphql` normally exits non-zero on such a page, but
# this check does not rely on that, and it is the only guard on --fixture.
ERRF="$(mktemp)" || die "mktemp failed"
if ! discovered="$(printf '%s' "$raw" | jq -r --arg owner "$OWNER" '
  if (type != "object") or ((.data.repositoryOwner? // null) == null)
  then error("response has no repositoryOwner (unknown owner or GraphQL error)")
  elif ((.errors // []) | length) > 0
  then error("response carries GraphQL errors beside its data (partial result)")
  else .data.repositoryOwner.repositories.nodes[]
    | select((.isArchived // false) | not)
    | select(.object != null)
    | .nameWithOwner
    | select($owner == "" or ((ascii_downcase) | startswith(($owner | ascii_downcase) + "/")))
  end
' 2>"$ERRF")"; then
  msg="$(head -c 400 "$ERRF" 2>/dev/null)"; rm -f "$ERRF"
  die "discovery response unusable: $msg"
fi
rm -f "$ERRF"

out="$(printf '%s\n' "$discovered" | emit_validated "discovery")" \
  || die "discovery found no non-archived repo under '${OWNER:-<any owner>}' carrying .github/workflows/$MARKER"
printf '%s\n' "$out"
exit 0
