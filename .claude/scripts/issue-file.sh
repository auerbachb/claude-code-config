#!/usr/bin/env bash
# File ONE GitHub issue through the shared one-shot entry (issue #1766).
# catalog: backlog-pm — Validate a seven-section issue body and file it with checked labels: the one create path for /issue-maker and the desk's idea: intent
#
# Usage: issue-file.sh --repo <owner/name> --title <title> --body-file <path>
#                      [--label <name>]... [--json] [--dry-run]
#        issue-file.sh --template
#        issue-file.sh --help
#
# The mechanical half of filing an issue, shared by /issue-maker (Step 5) and
# the desk's `idea:` / `file:` intent (desk/skill/ideas.md), so the two can
# never diverge. The judgment half (reflection, duplicate search, drafting)
# lives in .claude/skills/issue-maker/references/one-shot-filing.md.
#
# What it checks BEFORE any gh call (exit 3, nothing sent):
#   - the title is one line of 1 to 70 characters (counted as characters, not
#     bytes, so an em dash is one);
#   - the body has the seven sections as `## ` headings, in this order:
#     Background, Problem, Proposed solution, Acceptance Criteria, Test Plan,
#     Notes / Open questions, Estimate (other sections may sit between or
#     after them);
#   - the body's last non-blank line is exactly `_Captured via /issue-maker._`,
#     the footer the desk's Reviews sync (desk/bin/cmd/sync-reviews.sh) finds
#     captured issues by.
#
# Labels:
#   - `blocked`, `on-hold`, `wontfix`, and `duplicate` are dropped: /pm skips
#     issues that carry them, so a fresh idea filed with one would never reach
#     the backlog ranking.
#   - the rest are kept only when the repo has them (matched ignoring case,
#     applied in the repo's own spelling); each dropped label is named on
#     stderr and in --json. When the label list cannot be read, the issue is
#     filed without labels and that is said, rather than failing the filing.
#
# Creation: `gh issue create --repo <owner/name> --body-file ...` — --repo on
# every gh call, and never --assignee (/pm skips assigned issues too). The URL
# gh prints must name an issue in <owner/name>.
#
# Options:
#   --repo <owner/name>  target repository (required)
#   --title <text>       issue title (required)
#   --body-file <path>   the body, as written (required; `-` reads stdin)
#   --label <name>       a label to apply; repeat for more
#   --json               print one JSON object instead of the bare URL
#   --dry-run            validate and check labels, but create nothing
#   --template           print the seven-section skeleton (with the footer)
#                        and exit; it passes this script's own checks once
#                        its placeholders are filled in
#
# Output (stdout):
#   default  the new issue's URL, alone on one line (with --dry-run:
#            `dry run: would file "<title>" in <owner/name> (labels: ...)`)
#   --json   {"repo", "number", "url", "title", "labels", "dropped_labels",
#             "dry_run"}; labels are the applied names, dropped_labels is
#             [{label, reason}]; number and url are null on --dry-run
#
# Environment:
#   ISSUE_FILE_GH   gh binary override (tests point it at a stub)
#
# Exit codes:
#   0  filed (or, with --dry-run, would be filed)
#   2  usage error (missing or unknown option, malformed --repo, unreadable
#      body file)
#   3  the title or body failed a check above; nothing was sent to GitHub
#   4  gh/jq missing, or gh failed to create the issue (no URL is printed);
#      also when gh succeeded but printed no URL for an issue in <owner/name>.
#      A failed create may still have landed: check that repo's newest
#      issues before filing again (stderr says so)

set -euo pipefail
printf '%s\t%s\t%s\n' "$(date -u +%FT%TZ)" "$(basename "$0")" "${*//$'\n'/ }" 2>/dev/null >> "$HOME/.claude/script-usage.log" || true

FOOTER='_Captured via /issue-maker._'
# The canonical seven sections, in order (/issue-maker Step 5).
SECTIONS='Background
Problem
Proposed solution
Acceptance Criteria
Test Plan
Notes / Open questions
Estimate'
# Labels /pm Step 1B.4 (6) excludes from ranking.
EXCLUDED_LABELS='blocked on-hold wontfix duplicate'
TITLE_MAX=70

usage() {
  sed -n '3,68p' "$0" | sed 's/^# \{0,1\}//'
}

die_usage() {
  echo "issue-file.sh: $1" >&2
  exit 2
}

template() {
  cat <<'EOF'
## Background

<functional, conversational context: what happens today, who it affects>

## Problem

<what is wrong or missing, framed by impact>

## Proposed solution

<what behavior the change enables, in outcome voice>

## Acceptance Criteria

- [ ] <implementer-facing, precise>

## Test Plan

- [ ] <concrete scenarios>

## Notes / Open questions

- <tradeoffs, decisions to make>

## Estimate

Est: <lo>–<hi> min · plan on <bound>

_Captured via /issue-maker._
EOF
}

if [ "$#" -eq 0 ]; then
  usage >&2
  exit 2
fi

REPO=""
TITLE=""
TITLE_SET=0
BODY_FILE=""
JSON=0
DRY_RUN=0
LABELS=()

need_value() {
  # need_value <flag> <remaining-arg-count>
  if [ "$2" -lt 2 ]; then
    die_usage "option '$1' requires a value"
  fi
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --repo)      need_value "$1" "$#"; REPO="$2"; shift 2 ;;
    --title)     need_value "$1" "$#"; TITLE="$2"; TITLE_SET=1; shift 2 ;;
    --body-file) need_value "$1" "$#"; BODY_FILE="$2"; shift 2 ;;
    --label)     need_value "$1" "$#"; LABELS[${#LABELS[@]}]="$2"; shift 2 ;;
    --json)      JSON=1; shift ;;
    --dry-run)   DRY_RUN=1; shift ;;
    --template)  template; exit 0 ;;
    -h|--help)   usage; exit 0 ;;
    *) die_usage "unknown option '$1' (run issue-file.sh --help)" ;;
  esac
done

[ -n "$REPO" ] || die_usage "--repo <owner/name> is required"
[ "$TITLE_SET" -eq 1 ] || die_usage "--title is required"
[ -n "$BODY_FILE" ] || die_usage "--body-file is required"
REPO_RE='^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$'
if ! [[ $REPO =~ $REPO_RE ]] || [ "${#REPO}" -gt 140 ]; then
  die_usage "--repo must be owner/name"
fi

# --- tools -------------------------------------------------------------------
find_bin() {
  # find_bin <name> <override> — prints the first usable binary, or nothing.
  local name="$1" override="$2" c
  if [ -n "$override" ]; then
    if [ -x "$override" ]; then printf '%s\n' "$override"; fi
    return 0
  fi
  if command -v "$name" >/dev/null 2>&1; then command -v "$name"; return 0; fi
  for c in "/opt/homebrew/bin/$name" "/usr/local/bin/$name" "/usr/bin/$name"; do
    if [ -x "$c" ]; then printf '%s\n' "$c"; return 0; fi
  done
}
JQ=$(find_bin jq "")
[ -n "$JQ" ] || { echo "issue-file.sh: jq not found" >&2; exit 4; }

WORK=$(mktemp -d "${TMPDIR:-/tmp}/issue-file.XXXXXX")
trap 'rm -rf "$WORK"' EXIT

# --- the body ----------------------------------------------------------------
BODY="$WORK/body.md"
if [ "$BODY_FILE" = "-" ]; then
  cat > "$BODY"
elif [ -f "$BODY_FILE" ] && [ -r "$BODY_FILE" ]; then
  cat "$BODY_FILE" > "$BODY"
else
  die_usage "--body-file '$BODY_FILE' is not a readable file"
fi

# --- checks (exit 3, nothing sent) -------------------------------------------
PROBLEMS=""
problem() { PROBLEMS="$PROBLEMS$1"$'\n'; }

case "$TITLE" in
  *$'\n'*|*$'\r'*) problem "the title must be one line" ;;
  *[[:cntrl:]]*) problem "the title holds a control character" ;;
esac
TITLE_TRIMMED=$(printf '%s' "$TITLE" | "$JQ" -Rrs 'gsub("^[[:space:]]+|[[:space:]]+$"; "")')
# jq counts characters (code points) whatever the locale, so an em dash is one.
TITLE_LEN=$(printf '%s' "$TITLE_TRIMMED" | "$JQ" -Rs 'length')
if [ -z "$TITLE_TRIMMED" ]; then
  problem "the title is blank"
elif [ "$TITLE_LEN" -gt "$TITLE_MAX" ]; then
  problem "the title is $TITLE_LEN characters; the limit is $TITLE_MAX (trim it and say so)"
fi

# Section order: the line number of each heading's first occurrence must rise.
SECTION_REPORT=$(printf '%s\n' "$SECTIONS" | awk -v body="$BODY" '
  BEGIN {
    n = 0
    while ((getline line < body) > 0) {
      n++
      sub(/\r$/, "", line)
      if (line ~ /^## /) {
        h = substr(line, 4); sub(/[ \t]+$/, "", h)
        if (!(h in first)) first[h] = n
      }
    }
  }
  {
    want = $0
    if (!(want in first)) { print "missing section: ## " want; next }
    if (first[want] <= last) { print "section out of order: ## " want; }
    last = first[want]
  }')
if [ -n "$SECTION_REPORT" ]; then
  while IFS= read -r line; do
    [ -n "$line" ] && problem "$line"
  done <<EOF
$SECTION_REPORT
EOF
fi

LAST_LINE=$(awk '{ sub(/\r$/, ""); if ($0 ~ /[^[:space:]]/) last = $0 } END { print last }' "$BODY")
LAST_LINE=$(printf '%s' "$LAST_LINE" | "$JQ" -Rrs 'gsub("^[[:space:]]+|[[:space:]]+$"; "")')
if [ "$LAST_LINE" != "$FOOTER" ]; then
  problem "the body's last line must be exactly $FOOTER"
fi

if [ -n "$PROBLEMS" ]; then
  printf '%s' "$PROBLEMS" | sed 's/^/issue-file.sh: /' >&2
  echo "issue-file.sh: nothing was sent to GitHub" >&2
  exit 3
fi
TITLE="$TITLE_TRIMMED"

# --- gh ----------------------------------------------------------------------
GH=$(find_bin gh "${ISSUE_FILE_GH:-}")
[ -n "$GH" ] || { echo "issue-file.sh: gh not found${ISSUE_FILE_GH:+ (ISSUE_FILE_GH is not executable)}" >&2; exit 4; }

lower() { printf '%s' "$1" | LC_ALL=C tr '[:upper:]' '[:lower:]'; }

# Labels: excluded first, then the repo's own list. DROPPED is one
# `label<US>reason` line per drop; APPLY holds the repo's spelling.
US=$'\x1f'
DROPPED=""
APPLY=()
WANT=()
for l in ${LABELS[@]+"${LABELS[@]}"}; do
  case "$l" in
    *[![:space:]]*) ;;
    *) continue ;;
  esac
  ll=$(lower "$l")
  dup=0
  for w in ${WANT[@]+"${WANT[@]}"}; do
    if [ "$(lower "$w")" = "$ll" ]; then dup=1; break; fi
  done
  [ "$dup" -eq 0 ] || continue
  excluded=0
  for x in $EXCLUDED_LABELS; do
    if [ "$ll" = "$x" ]; then excluded=1; break; fi
  done
  if [ "$excluded" -eq 1 ]; then
    DROPPED="$DROPPED$l${US}hides the issue from /pm"$'\n'
    continue
  fi
  WANT[${#WANT[@]}]="$l"
done

if [ "${#WANT[@]}" -gt 0 ]; then
  LABEL_ERR="$WORK/labels.err"
  if REPO_LABELS=$("$GH" label list --repo "$REPO" --json name --limit 1000 2>"$LABEL_ERR") \
     && REPO_NAMES=$(printf '%s' "$REPO_LABELS" | "$JQ" -r 'if type == "array" then .[].name else error("not an array") end' 2>/dev/null); then
    for l in "${WANT[@]}"; do
      ll=$(lower "$l")
      match=""
      while IFS= read -r name; do
        [ -n "$name" ] || continue
        if [ "$(lower "$name")" = "$ll" ]; then match="$name"; break; fi
      done <<EOF
$REPO_NAMES
EOF
      if [ -n "$match" ]; then
        APPLY[${#APPLY[@]}]="$match"
      else
        DROPPED="$DROPPED$l${US}not a label in $REPO"$'\n'
      fi
    done
  else
    for l in "${WANT[@]}"; do
      DROPPED="$DROPPED$l${US}the repo's labels could not be read"$'\n'
    done
  fi
fi

if [ -n "$DROPPED" ]; then
  while IFS="$US" read -r l reason; do
    [ -n "$l" ] || continue
    echo "issue-file.sh: label '$l' dropped: $reason" >&2
  done <<EOF
$DROPPED
EOF
fi

APPLIED_JSON=$(printf '%s\n' ${APPLY[@]+"${APPLY[@]}"} | "$JQ" -R . | "$JQ" -sc 'map(select(length > 0))')
DROPPED_JSON=$(printf '%s' "$DROPPED" | "$JQ" -Rsc --arg us "$US" \
  'split("\n") | map(select(length > 0) | split($us) | {label: .[0], reason: .[1]})')

emit() {
  # emit NUMBER URL — both empty on a dry run.
  if [ "$JSON" -eq 1 ]; then
    "$JQ" -nc --arg repo "$REPO" --arg number "$1" --arg url "$2" --arg title "$TITLE" \
      --argjson labels "$APPLIED_JSON" --argjson dropped "$DROPPED_JSON" --argjson dry "$DRY_RUN" \
      '{repo: $repo,
        number: (if $number == "" then null else ($number | tonumber) end),
        url: (if $url == "" then null else $url end),
        title: $title, labels: $labels, dropped_labels: $dropped, dry_run: ($dry == 1)}'
  elif [ -n "$2" ]; then
    printf '%s\n' "$2"
  else
    printf 'dry run: would file "%s" in %s (labels: %s)\n' "$TITLE" "$REPO" \
      "$(printf '%s' "$APPLIED_JSON" | "$JQ" -r 'if length == 0 then "none" else join(", ") end')"
  fi
}

if [ "$DRY_RUN" -eq 1 ]; then
  emit "" ""
  exit 0
fi

LABEL_ARGS=()
for l in ${APPLY[@]+"${APPLY[@]}"}; do
  LABEL_ARGS[${#LABEL_ARGS[@]}]="--label"
  LABEL_ARGS[${#LABEL_ARGS[@]}]="$l"
done

CREATE_ERR="$WORK/create.err"
rc=0
OUT=$("$GH" issue create --repo "$REPO" --title="$TITLE" --body-file="$BODY" \
  ${LABEL_ARGS[@]+"${LABEL_ARGS[@]}"} 2>"$CREATE_ERR") || rc=$?
if [ "$rc" -ne 0 ]; then
  first=$(grep -m1 '[^[:space:]]' "$CREATE_ERR" 2>/dev/null || true)
  echo "issue-file.sh: gh issue create failed (exit $rc)${first:+: $first}" >&2
  # A create can land on GitHub and still fail locally (a dropped connection
  # after the write), so a blind retry could file the idea twice.
  echo "issue-file.sh: check $REPO's newest issues before filing again" >&2
  exit 4
fi

URL=$(printf '%s\n' "$OUT" | awk 'NF { last = $0 } END { gsub(/^[ \t]+|[ \t]+$/, "", last); print last }')
NUMBER=""
URL_RE='^https://[^/[:space:]]+/([^/[:space:]]+/[^/[:space:]]+)/issues/([1-9][0-9]*)$'
if [[ $URL =~ $URL_RE ]] && [ "$(lower "${BASH_REMATCH[1]}")" = "$(lower "$REPO")" ]; then
  NUMBER="${BASH_REMATCH[2]}"
fi
if [ -z "$NUMBER" ]; then
  echo "issue-file.sh: gh reported success but printed no issue URL in $REPO; check $REPO's newest issues before filing again" >&2
  exit 4
fi

emit "$NUMBER" "$URL"
