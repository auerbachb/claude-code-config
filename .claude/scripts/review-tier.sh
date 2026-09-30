#!/usr/bin/env bash
# review-tier.sh — Resolve a PR's review tier from the repo's pm-config `## Review policy`.
# catalog: merge-gate-sequencing — Resolve a PR's review tier (ci-only / ci+codeant-one-round / full / legacy) from pm-config
#
# PURPOSE
#   A repo may declare review tiers in its own .claude/pm-config.md (issue
#   #1724). This script is the ONE place that reads that declaration and says
#   which gate a PR falls under, so the merge gate, the BugBot triggers and
#   the CI workflow never parse the policy themselves and cannot drift apart.
#   Format and resolution rules: .claude/reference/review-policy.md.
#
# USAGE
#   review-tier.sh <pr_number> [--repo <owner/name>] [--config <path>] [--json]
#   review-tier.sh --files-from <file|-> [--labels <csv>] [--config <path>] [--json]
#   review-tier.sh --help | -h
#
#   <pr_number>        Resolve for this PR: its changed files (renames count
#                      both old and new path) and labels come from GitHub, and
#                      the policy is read from the PR's BASE branch, so a PR
#                      can never re-tier itself by editing pm-config.md.
#   --repo <o/n>       Repository for PR mode (default: gh's current repo).
#   --config <path>    Read the policy from this file instead (a base-branch
#                      checkout in CI, or a fixture in tests). Deliberately a
#                      flag only, never an environment variable: a gate that
#                      enforces review must not be re-pointable at a looser
#                      policy by ambient state. The merge gate never passes it.
#   --files-from <f>   Offline mode: newline-separated repo-relative paths
#                      ("-" = stdin). No gh call is made. Without --config the
#                      policy is read from the current checkout's pm-config.md.
#   --labels <csv>     Offline mode: comma-separated PR labels.
#   --json             Emit the structured result (below) instead of the gate.
#
# POLICY FORMAT (the `## Review policy` section of .claude/pm-config.md)
#   The first markdown table in the section, columns matched by header name
#   (case-insensitive; order free; unknown columns ignored):
#     | Tier | Gate | Paths | Labels |
#     |------|------|-------|--------|
#     | core | full | src/ledger/**, migrations/** | tier:core |
#     | leaf | ci+codeant-one-round | src/adapters/** | |
#     | docs | ci-only | docs/**, *.md | tier:docs |
#     | default | full | | |
#   Gate    one of ci-only, ci+codeant-one-round, full. Required.
#   Paths   comma-separated shell globs against the repo-relative path; `*`
#           also crosses `/`; `**/` also matches zero directories; a trailing
#           `/` means "everything under". Brace lists are refused.
#   Labels  comma-separated PR labels (case-insensitive).
#   A row named `default` classifies files no path matches; without one they
#   are `full`. Edge pipes are optional (GFM); the table runs to the first
#   blank line or heading, and any later `|` line makes the policy invalid.
#   Tables inside ``` fences or <!-- --> comments are ignored.
#
# RESOLUTION (strictest wins: full > ci+codeant-one-round > ci-only)
#   Candidates = the tiers every changed file matches, plus every tier whose
#   label is on the PR, plus `default` when some file matched no path and no
#   tier label is present. A label therefore classifies what the paths leave
#   open, and can never lower a file a path already matched. The PR gets the
#   strictest candidate gate; `tier` names the first table row carrying it.
#   A PR with no files and no tier label gets `default`. When GitHub returns
#   fewer files than the PR changed (its 3000-file listing cap), `full` is
#   added: unseen files are never assumed light.
#
# OUTPUT
#   plain: the gate — legacy | ci-only | ci+codeant-one-round | full
#   --json: one line —
#     {"policy":"absent|present|invalid","gate":"...","tier":"<name>"|null,
#      "source":"<where the policy came from>","error":"<why invalid>"|null,
#      "matches":[{"tier","gate","via":"path|label|default|truncated",
#                  "count":N,"examples":[up to 5 items]}]}
#   policy "absent"  — no section, or a section with no table → gate legacy:
#                      every consumer keeps today's behaviour.
#   policy "invalid" — unknown gate, missing Tier/Gate column, no header
#                      separator, no data rows, empty or duplicate tier name,
#                      a brace glob, a `|` line after the table, or a
#                      near-miss heading (`## Review Policy`)
#                      → gate full (today's gate) plus one stderr warning.
#                      Fail-closed: a typo can never loosen review.
#
# EXIT STATUS
#   0  Resolved (absent and invalid policies included).
#   2  Usage error.
#   3  PR not found.
#   4  gh / local failure: files, labels, changedFiles, or a policy source
#      that exists but cannot be read (non-file API object, unreadable or
#      directory --config, offline mode outside a git checkout). Nothing is
#      printed on stdout, so a consumer fails closed. Only a source that does
#      not exist reads as "absent".

set -uo pipefail
printf '%s\t%s\t%s\n' "$(date -u +%FT%TZ)" "$(basename "$0")" "${*//$'\n'/ }" 2>/dev/null >> "$HOME/.claude/script-usage.log" || true

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_PATH="$SCRIPT_DIR/$(basename "${BASH_SOURCE[0]}")"
SECTION="Review policy"

usage() {
  sed -n '/^# PURPOSE$/,/^$/{/^$/d;p;}' "$SCRIPT_PATH" | sed 's/^# \{0,1\}//'
}
warn() { printf 'review-tier.sh: %s\n' "$1" >&2; }
die_usage() { warn "$1"; printf 'Run with --help for usage.\n' >&2; exit 2; }
die_read() { warn "$1"; exit 4; }

PR_NUMBER=""
REPO=""
CONFIG=""
FILES_FROM=""
LABELS_CSV=""
LABELS_SET=0
JSON=0

need_value() { [[ $# -ge 2 && -n "${2:-}" ]] || die_usage "$1 requires a value"; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --json) JSON=1; shift ;;
    --repo) need_value "$@"; REPO="$2"; shift 2 ;;
    --repo=*) REPO="${1#--repo=}"; [[ -n "$REPO" ]] || die_usage "--repo requires a value"; shift ;;
    --config) need_value "$@"; CONFIG="$2"; shift 2 ;;
    --config=*) CONFIG="${1#--config=}"; [[ -n "$CONFIG" ]] || die_usage "--config requires a value"; shift ;;
    --files-from) need_value "$@"; FILES_FROM="$2"; shift 2 ;;
    --files-from=*) FILES_FROM="${1#--files-from=}"; [[ -n "$FILES_FROM" ]] || die_usage "--files-from requires a value"; shift ;;
    --labels) [[ $# -ge 2 ]] || die_usage "--labels requires a value"; LABELS_CSV="$2"; LABELS_SET=1; shift 2 ;;
    --labels=*) LABELS_CSV="${1#--labels=}"; LABELS_SET=1; shift ;;
    -*) die_usage "unknown flag: $1" ;;
    *)
      [[ -z "$PR_NUMBER" ]] || die_usage "unexpected argument: $1"
      PR_NUMBER="${1#\#}"
      shift
      ;;
  esac
done

if [[ -n "$PR_NUMBER" && -n "$FILES_FROM" ]]; then
  die_usage "pass a PR number OR --files-from, not both"
fi
if [[ -z "$PR_NUMBER" && -z "$FILES_FROM" ]]; then
  die_usage "a PR number or --files-from is required"
fi
if [[ -n "$PR_NUMBER" && ! "$PR_NUMBER" =~ ^[1-9][0-9]*$ ]]; then
  die_usage "PR number must be a positive integer (got: $PR_NUMBER)"
fi
if [[ -n "$PR_NUMBER" && $LABELS_SET -eq 1 ]]; then
  die_usage "--labels is offline-mode only; PR mode reads the PR's labels"
fi
if [[ -n "$REPO" && ! "$REPO" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]]; then
  die_usage "--repo must look like owner/name (got: $REPO)"
fi

command -v jq >/dev/null 2>&1 || die_read "jq not found on PATH"
GETTER="$SCRIPT_DIR/pm-config-get.sh"
[[ -x "$GETTER" ]] || die_read "pm-config-get.sh not found beside this script ($GETTER)"

TMP_DIR="$(mktemp -d)" || die_read "mktemp failed"
trap 'rm -rf "$TMP_DIR"' EXIT

lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }
trim() {
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}
# Strip markdown decoration a human writes around a cell value: backticks and
# surrounding whitespace. `docs/**` and docs/** mean the same glob.
clean_cell() {
  local s="$1"
  s="${s//\`/}"
  trim "$s"
}

# ------------------------------------------------------------ PR facts ------

FILES_FILE="$TMP_DIR/files"
LABELS_FILE="$TMP_DIR/labels"
: > "$FILES_FILE"
: > "$LABELS_FILE"
TRUNCATED=0
BASE_REF=""

if [[ -n "$PR_NUMBER" ]]; then
  command -v gh >/dev/null 2>&1 || die_read "gh not found on PATH"
  if [[ -z "$REPO" ]]; then
    REPO="$(gh repo view --json nameWithOwner --jq '.nameWithOwner' 2>/dev/null)" || REPO=""
    [[ -n "$REPO" ]] || die_read "gh repo view failed — not in a git repo, or no remote"
  fi

  PR_ERR="$TMP_DIR/pr.err"
  if ! PR_JSON="$(gh pr view "$PR_NUMBER" --repo "$REPO" --json baseRefName,labels,changedFiles 2>"$PR_ERR")"; then
    if grep -qiE 'could not resolve to a pullrequest|not found|no pull requests found' "$PR_ERR" 2>/dev/null; then
      warn "PR #$PR_NUMBER not found in $REPO"
      exit 3
    fi
    die_read "gh pr view #$PR_NUMBER failed: $(head -1 "$PR_ERR" 2>/dev/null)"
  fi
  BASE_REF="$(printf '%s' "$PR_JSON" | jq -r '.baseRefName // ""')" || die_read "could not parse gh pr view output"
  CHANGED="$(printf '%s' "$PR_JSON" | jq -r '.changedFiles // ""')" || die_read "could not parse gh pr view output"
  # Without a count there is no way to tell a complete listing from a
  # truncated one, and "assume complete" is the direction that loosens.
  [[ "$CHANGED" =~ ^[0-9]+$ ]] || die_read "gh pr view returned no usable changedFiles (got: '$CHANGED')"
  printf '%s' "$PR_JSON" | jq -r '.labels[]?.name' > "$LABELS_FILE" || die_read "could not parse PR labels"

  # Paginated past GitHub's 100-per-page default. Each entry is tagged: F for
  # the file itself, P for a rename's previous path. Both are classified —
  # moving a file out of a core directory still touches that directory — but
  # only F lines are counted against changedFiles, so a rename can never pad
  # the count and hide a truncated listing.
  if ! gh api "repos/$REPO/pulls/$PR_NUMBER/files?per_page=100" --paginate \
      --jq '.[] | "F\t\(.filename)", (.previous_filename // empty | "P\t\(.)")' \
      > "$TMP_DIR/files.tagged" 2>"$TMP_DIR/files.err"; then
    die_read "could not list PR #$PR_NUMBER files: $(head -1 "$TMP_DIR/files.err" 2>/dev/null)"
  fi
  cut -f2- "$TMP_DIR/files.tagged" > "$FILES_FILE" || die_read "could not read the PR file listing"
  LISTED="$(awk -F'\t' '$1 == "F" { n++ } END { print n + 0 }' "$TMP_DIR/files.tagged")"
  # An undershoot is GitHub's file-listing cap: the files it hid are
  # unclassified, so they are never assumed light.
  if (( LISTED < CHANGED )); then
    TRUNCATED=1
  fi
else
  if [[ "$FILES_FROM" == "-" ]]; then
    cat > "$FILES_FILE" || die_read "could not read file list from stdin"
  else
    [[ -r "$FILES_FROM" ]] || die_read "--files-from file not readable: $FILES_FROM"
    cat "$FILES_FROM" > "$FILES_FILE" || die_read "could not read $FILES_FROM"
  fi
  if [[ -n "$LABELS_CSV" ]]; then
    printf '%s\n' "$LABELS_CSV" | tr ',' '\n' > "$LABELS_FILE"
  fi
fi

# ----------------------------------------------------------- the policy -----

# Whatever the source, the policy lands in POLICY_COPY with CRs stripped, so
# a CRLF checkout parses exactly like the LF blob CI reads. Only a source that
# does not EXIST is "absent"; one that exists but cannot be read is a read
# failure (exit 4), never a silent "no policy".
POLICY_COPY="$TMP_DIR/pm-config.md"
HAVE_POLICY=0
SOURCE=""
if [[ -n "$CONFIG" ]]; then
  SOURCE="file:$CONFIG"
  if [[ -L "$CONFIG" && ! -e "$CONFIG" ]]; then
    # A dangling symlink is a path someone pointed somewhere on purpose; its
    # target going missing is a read failure, not "no policy declared".
    die_read "--config is a dangling symlink: $CONFIG"
  elif [[ ! -e "$CONFIG" ]]; then
    # Almost always a typo; say so rather than reading it silently as absent.
    warn "--config file not found: $CONFIG — treating the policy as absent"
  elif [[ -d "$CONFIG" ]]; then
    die_read "--config is a directory, not a file: $CONFIG"
  elif ! { tr -d '\r' < "$CONFIG" > "$POLICY_COPY"; } 2>/dev/null; then
    die_read "--config file not readable: $CONFIG"
  else
    HAVE_POLICY=1
  fi
elif [[ -n "$PR_NUMBER" ]]; then
  SOURCE="base:${BASE_REF:-default-branch}"
  CONTENT_ERR="$TMP_DIR/content.err"
  if [[ -n "$BASE_REF" ]]; then
    CONTENT_JSON="$(gh api --method GET "repos/$REPO/contents/.claude/pm-config.md" -f ref="$BASE_REF" 2>"$CONTENT_ERR")" || CONTENT_JSON=""
  else
    CONTENT_JSON="$(gh api --method GET "repos/$REPO/contents/.claude/pm-config.md" 2>"$CONTENT_ERR")" || CONTENT_JSON=""
  fi
  if [[ -z "$CONTENT_JSON" ]]; then
    # 404 = the base branch carries no pm-config.md: the normal "no policy"
    # case. Anything else is a read failure and must not read as "absent".
    grep -q 'HTTP 404' "$CONTENT_ERR" 2>/dev/null \
      || die_read "could not read .claude/pm-config.md at ${BASE_REF:-the default branch}: $(head -1 "$CONTENT_ERR" 2>/dev/null)"
  else
    # Only a base64 file object carries the config. A symlink, a submodule,
    # or an over-size blob (`encoding: none`) answers 200 with no usable
    # content; defaulting that to "" would read as "no policy".
    printf '%s' "$CONTENT_JSON" | jq -e 'type == "object" and .type == "file" and .encoding == "base64" and (.content | type) == "string"' >/dev/null 2>&1 \
      || die_read ".claude/pm-config.md at ${BASE_REF:-the default branch} is not a readable base64 file object"
    printf '%s' "$CONTENT_JSON" | jq -r '.content' | base64 --decode 2>/dev/null | tr -d '\r' > "$POLICY_COPY" \
      || die_read "could not decode .claude/pm-config.md from ${BASE_REF:-the default branch}"
    HAVE_POLICY=1
  fi
else
  TOP="$(git rev-parse --show-toplevel 2>/dev/null)" \
    || die_read "not in a git checkout (git rev-parse failed) — pass --config"
  [[ -n "$TOP" ]] || die_read "git rev-parse returned no toplevel — pass --config"
  SOURCE="file:$TOP/.claude/pm-config.md"
  if [[ -e "$TOP/.claude/pm-config.md" ]]; then
    { tr -d '\r' < "$TOP/.claude/pm-config.md" > "$POLICY_COPY"; } 2>/dev/null \
      || die_read "could not read $TOP/.claude/pm-config.md"
    HAVE_POLICY=1
  fi
fi

SECTION_BODY=""
if [[ $HAVE_POLICY -eq 1 && -s "$POLICY_COPY" ]]; then
  rc=0
  SECTION_BODY="$("$GETTER" --section "$SECTION" --file "$POLICY_COPY" 2>/dev/null)" || rc=$?
  case $rc in
    0) ;;
    1) SECTION_BODY="" ;;
    *) die_read "pm-config-get.sh failed (rc $rc) reading ## $SECTION" ;;
  esac
fi

emit() {
  # emit <policy> <gate> <tier-or-empty> <error-or-empty> <matches-json>
  if [[ $JSON -eq 1 ]]; then
    jq -cn --arg policy "$1" --arg gate "$2" --arg tier "$3" --arg source "$SOURCE" \
      --arg error "$4" --argjson matches "$5" \
      '{policy: $policy, gate: $gate,
        tier: (if $tier == "" then null else $tier end),
        source: $source,
        error: (if $error == "" then null else $error end),
        matches: $matches}'
  else
    printf '%s\n' "$2"
  fi
}

if [[ -z "$SECTION_BODY" ]]; then
  # A heading that is almost `## Review policy` (other case, extra spaces)
  # is a policy someone meant to declare; reading it as absent would ignore
  # it without a word. Checked only when the exact section was not found.
  NEAR=""
  if [[ $HAVE_POLICY -eq 1 ]]; then
    NEAR="$(awk '{ l = tolower($0) } l ~ /^##[ \t]+review[ \t]+policy[ \t]*$/ && $0 !~ /^## Review policy[ \t]*$/ { print; exit }' "$POLICY_COPY")"
  fi
  if [[ -n "$NEAR" ]]; then
    warn "## $SECTION is invalid (heading '$NEAR' must read exactly '## $SECTION') — resolving to the full gate"
    emit invalid full "" "heading '$NEAR' must read exactly '## $SECTION'" '[]'
    exit 0
  fi
  emit absent legacy "" "" '[]'
  exit 0
fi

# Parse the FIRST markdown table outside code fences and HTML comments.
# Emits one of:  NOTABLE | ERROR<US>reason | ROW<US>tier<US>gate<US>paths<US>labels
# <US> is the ASCII unit separator (\037): a NON-whitespace IFS, so an empty
# cell stays an empty field instead of collapsing into its neighbour the way
# consecutive tabs do.
parse_table() {
  awk '
    function trim(s) { sub(/^[ \t]+/, "", s); sub(/[ \t]+$/, "", s); return s }
    function split_cells(line, cells,    n, i) {
      line = trim(line)
      sub(/^\|/, "", line); sub(/\|$/, "", line)
      n = split(line, cells, "|")
      for (i = 1; i <= n; i++) { cells[i] = trim(cells[i]); gsub(/\t/, " ", cells[i]) }
      return n
    }
    BEGIN { fence = 0; comment = 0; state = 0; row = 0; US = "\037" }
    {
      line = $0
      if (comment) {
        if (index(line, "-->") == 0) next
        line = substr(line, index(line, "-->") + 3); comment = 0
      }
      # A fence closes only on a run of the SAME character at least as long
      # as its opener, with nothing after it (CommonMark). Toggling on any
      # ``` line would let an inner ``` close a ```` fence and turn the
      # example table after it into the live policy.
      if (fence) {
        s = line; sub(/^[ \t]*/, "", s)
        n = 0
        while (substr(s, n + 1, 1) == fch) n++
        if (n >= flen && substr(s, n + 1) ~ /^[ \t]*$/) fence = 0
        next
      }
      if (match(line, /^[ \t]*(```+|~~~+)/)) {
        s = substr(line, RSTART, RLENGTH); sub(/^[ \t]*/, "", s)
        fch = substr(s, 1, 1); flen = length(s); fence = 1
        if (state == 1) state = 2
        next
      }
      while (index(line, "<!--") > 0) {
        pre = substr(line, 1, index(line, "<!--") - 1)
        rest = substr(line, index(line, "<!--") + 4)
        if (index(rest, "-->") > 0) { line = pre substr(rest, index(rest, "-->") + 3) }
        else { line = pre; comment = 1; break }
      }
      # GFM makes the edge pipes optional, so a row is any line carrying a
      # `|` — `core | full | src/**` renders as a row on GitHub and must parse
      # as one here. The table runs from its first pipe line to the first
      # blank line or heading.
      has_pipe = (index(line, "|") > 0)
      if (state == 2) {
        # A pipe line after the table ended — a second table, or rows cut off
        # by a blank line or a comment — is ambiguous. Refuse it rather than
        # silently ignoring rows the author meant to declare.
        if (has_pipe && bad == "") bad = "a line containing | follows the policy table; keep every tier in one contiguous table"
        next
      }
      if (state == 1 && (line ~ /^[ \t]*$/ || line ~ /^[ \t]*#/)) { state = 2; next }
      if (state == 0 && !has_pipe) next
      state = 1; row++
      if (row == 1) {
        nh = split_cells(line, hdr)
        for (i = 1; i <= nh; i++) {
          h = tolower(hdr[i]); gsub(/[`*_]/, "", h); h = trim(h)
          col[h] = i
        }
        next
      }
      if (row == 2) {
        if (line !~ /-/ || line !~ /^[ \t|:-]+$/) { bad = "table has no header separator row"; state = 2 }
        next
      }
      nc = split_cells(line, c)
      t = ("tier"   in col) ? c[col["tier"]]   : ""
      g = ("gate"   in col) ? c[col["gate"]]   : ""
      p = ("paths"  in col) ? c[col["paths"]]  : ""
      l = ("labels" in col) ? c[col["labels"]] : ""
      rows[++nr] = t US g US p US l
    }
    END {
      if (row == 0) { print "NOTABLE"; exit }
      if (bad != "") { print "ERROR" US bad; exit }
      if (!("tier" in col) || !("gate" in col)) { print "ERROR" US "table must have Tier and Gate columns"; exit }
      if (nr == 0) { print "ERROR" US "table declares no tiers"; exit }
      for (i = 1; i <= nr; i++) print "ROW" US rows[i]
    }
  '
}

gate_rank() {
  case "$1" in
    ci-only) echo 1 ;;
    ci+codeant-one-round) echo 2 ;;
    full) echo 3 ;;
    *) echo 0 ;;
  esac
}

invalid() {
  warn "## $SECTION is invalid ($1) — resolving to the full gate"
  emit invalid full "" "$1" '[]'
  exit 0
}

PARSED="$(printf '%s\n' "$SECTION_BODY" | parse_table)" || die_read "could not parse ## $SECTION"
case "$PARSED" in
  NOTABLE)
    warn "## $SECTION has no table — treating the policy as absent"
    emit absent legacy "" "" '[]'
    exit 0
    ;;
  ERROR*)
    invalid "$(printf '%s\n' "$PARSED" | cut -d $'\037' -f2-)"
    ;;
esac

TIER_NAMES=()
TIER_GATES=()
TIER_PATHS=()
TIER_LABELS=()
DEFAULT_IDX=-1
SEEN_NAMES=$'\n'

while IFS=$'\037' read -r tag t g p l; do
  [[ "$tag" == "ROW" ]] || continue
  name="$(clean_cell "$t")"
  [[ -n "$name" ]] || invalid "a row has an empty Tier name"
  lname="$(lower "$name")"
  case "$SEEN_NAMES" in
    *$'\n'"$lname"$'\n'*) invalid "duplicate tier name '$name'" ;;
  esac
  SEEN_NAMES="$SEEN_NAMES$lname"$'\n'
  gate="$(lower "$(clean_cell "$g")")"
  [[ "$(gate_rank "$gate")" != "0" ]] || invalid "tier '$name' has unknown gate '$(clean_cell "$g")'"

  globs=""
  if [[ -n "$p" ]]; then
    while IFS= read -r glob; do
      glob="$(clean_cell "$glob")"
      [[ -z "$glob" || "$glob" == "-" ]] && continue
      # Paths is split on commas, so a brace list `src/{a,b}/**` would arrive
      # as two dead halves that match nothing — and the files it meant fall
      # through to a lighter default. Refuse it instead.
      case "$glob" in
        *'{'*|*'}'*) invalid "tier '$name' path '$glob' uses braces — list each path separately" ;;
      esac
      while [[ "$glob" == ./* ]]; do glob="${glob#./}"; done
      while [[ "$glob" == /* ]]; do glob="${glob#/}"; done
      [[ "$glob" == */ ]] && glob="${glob}*"
      [[ -n "$glob" ]] && globs="$globs$glob"$'\n'
    done < <(printf '%s\n' "$p" | tr ',' '\n')
  fi
  labels=""
  if [[ -n "$l" ]]; then
    while IFS= read -r lab; do
      lab="$(lower "$(clean_cell "$lab")")"
      [[ -z "$lab" || "$lab" == "-" ]] && continue
      labels="$labels$lab"$'\n'
    done < <(printf '%s\n' "$l" | tr ',' '\n')
  fi

  TIER_NAMES+=("$name")
  TIER_GATES+=("$gate")
  TIER_PATHS+=("$globs")
  TIER_LABELS+=("$labels")
  [[ "$lname" == "default" ]] && DEFAULT_IDX=$(( ${#TIER_NAMES[@]} - 1 ))
done <<<"$PARSED"

N_TIERS=${#TIER_NAMES[@]}
(( N_TIERS > 0 )) || invalid "table declares no tiers"

# ------------------------------------------------------------- classify -----

MATCH_TSV="$TMP_DIR/matches.tsv"
: > "$MATCH_TSV"
CAND=()
for (( i = 0; i < N_TIERS; i++ )); do CAND+=(0); done
UNMATCHED=0
LABEL_HIT=0
IMPLICIT_DEFAULT=0

# glob_matches <file> <glob> — the documented Paths semantics. An unquoted
# case pattern is a glob match in which `*` also crosses `/`. `**/` also
# matches zero directories, the way CODEOWNERS and .gitignore read it, so
# `**/migrations/**` covers a root-level migrations/ and `a/**/b` covers a/b.
glob_matches() {
  local f="$1" g="$2"
  case "$f" in
    $g) return 0 ;;
  esac
  if [[ "$g" == '**/'* ]] && glob_matches "$f" "${g#\*\*/}"; then
    return 0
  fi
  # Collapse the FIRST `/**/` to `/` by splitting around it (bash 3.2 keeps a
  # literal backslash in a ${var/pat/rep} replacement, so no substitution).
  if [[ "$g" == *'/**/'* ]] && glob_matches "$f" "${g%%/\*\*/*}/${g#*/\*\*/}"; then
    return 0
  fi
  return 1
}

record() { printf '%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" >> "$MATCH_TSV"; }

# Labels first: whether any tier label is present decides whether unmatched
# files fall back to `default`.
while IFS= read -r lab; do
  lab="$(lower "$(trim "$lab")")"
  [[ -n "$lab" ]] || continue
  for (( i = 0; i < N_TIERS; i++ )); do
    # Whole-line match against the tier's newline-joined label list, so
    # `docs` never matches a tier labelled `tier:docs`.
    case $'\n'"${TIER_LABELS[$i]}" in
      *$'\n'"$lab"$'\n'*)
        CAND[i]=1; LABEL_HIT=1
        record "${TIER_NAMES[$i]}" "${TIER_GATES[$i]}" label "$lab"
        ;;
    esac
  done
done < <(awk 1 "$LABELS_FILE")

while IFS= read -r file; do
  # Inline trim: a $(trim) subshell per file is thousands of forks on a
  # large PR.
  file="${file#"${file%%[![:space:]]*}"}"
  file="${file%"${file##*[![:space:]]}"}"
  [[ -n "$file" ]] || continue
  file="${file#./}"
  hit=0
  for (( i = 0; i < N_TIERS; i++ )); do
    [[ -n "${TIER_PATHS[$i]}" ]] || continue
    while IFS= read -r glob; do
      [[ -n "$glob" ]] || continue
      if glob_matches "$file" "$glob"; then
        CAND[i]=1; hit=1
        record "${TIER_NAMES[$i]}" "${TIER_GATES[$i]}" path "$file"
        break
      fi
    done <<<"${TIER_PATHS[$i]}"
  done
  if [[ $hit -eq 0 ]]; then
    UNMATCHED=$((UNMATCHED + 1))
    printf '%s\n' "$file" >> "$TMP_DIR/unmatched"
  fi
done < <(awk 1 "$FILES_FILE")

apply_default() {
  # apply_default <via> <item>
  if (( DEFAULT_IDX >= 0 )); then
    CAND[DEFAULT_IDX]=1
    record "${TIER_NAMES[$DEFAULT_IDX]}" "${TIER_GATES[$DEFAULT_IDX]}" "$1" "$2"
  else
    IMPLICIT_DEFAULT=1
    record default full "$1" "$2"
  fi
}

if (( UNMATCHED > 0 && LABEL_HIT == 0 )); then
  while IFS= read -r file; do apply_default default "$file"; done < "$TMP_DIR/unmatched"
fi

ANY=0
for (( i = 0; i < N_TIERS; i++ )); do [[ "${CAND[$i]}" == "1" ]] && ANY=1; done
if (( ANY == 0 && IMPLICIT_DEFAULT == 0 )); then
  apply_default default "(no changed files)"
fi

FORCE_FULL=0
if (( TRUNCATED == 1 )); then
  FORCE_FULL=1
  record "(truncated)" full truncated "GitHub listed fewer files than the PR changed"
fi

BEST=0
BEST_TIER=""
for (( i = 0; i < N_TIERS; i++ )); do
  [[ "${CAND[$i]}" == "1" ]] || continue
  r="$(gate_rank "${TIER_GATES[$i]}")"
  if (( r > BEST )); then BEST=$r; BEST_TIER="${TIER_NAMES[$i]}"; fi
done
if (( IMPLICIT_DEFAULT == 1 && BEST < 3 )); then BEST=3; BEST_TIER="default"; fi
if (( FORCE_FULL == 1 && BEST < 3 )); then BEST=3; BEST_TIER="(truncated)"; fi

case $BEST in
  1) GATE="ci-only" ;;
  2) GATE="ci+codeant-one-round" ;;
  *) GATE="full" ;;
esac

MATCHES="$(jq -R -s -c '
  split("\n") | map(select(length > 0) | split("\t")
    | {tier: .[0], gate: .[1], via: .[2], item: .[3]})
  | group_by([.tier, .via])
  | map({tier: .[0].tier, gate: .[0].gate, via: .[0].via,
         count: length, examples: (map(.item) | .[0:5])})
' < "$MATCH_TSV")" || die_read "could not build the match summary"

emit present "$GATE" "$BEST_TIER" "" "$MATCHES"
