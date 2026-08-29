#!/usr/bin/env bash
# backlog-staleness.sh — shared backlog staleness/closure detection (issue #598).
#
# PURPOSE:
#   Reproduces /pm-clean's Step 4-7 detection rules — solved-by-merged-PR,
#   inactive, superseded, potential-duplicate — as a single deterministic,
#   testable script. Both /pm (Backlog health block) and /pm-clean (Cleanup
#   Recommendations) call this script so their results can never diverge.
#
# USAGE:
#   backlog-staleness.sh [--days N] [--json]
#   backlog-staleness.sh --help
#
#   --days N   Inactivity threshold in days. Default 30. Non-numeric or
#              non-positive values fall back to 30 with a stderr warning —
#              same semantics as /pm-clean's $ARGUMENTS validation.
#   --json     Emit a JSON array on stdout. Default emits one
#              tab-separated line per flag: "number\tcategory\trationale".
#
# OUTPUT:
#   One record per (issue, category) match — an issue can appear more than
#   once under different categories (e.g. both inactive AND superseded).
#   JSON record shape (fields beyond these four vary by category):
#     {"number": N, "title": "...", "category":
#      "solved-by-pr"|"inactive"|"superseded"|"potential-duplicate",
#      "rationale": "..."}
#   Zero flags is a valid result (prints "[]" / no lines) — not an error.
#
# EXIT CODES:
#   0  OK — ran to completion (including the zero-flags case)
#   2  Usage error (unknown flag, --days requires a value)
#   3  gh CLI error (not installed, not authenticated, network/API failure)
#
# EXAMPLES:
#   .claude/scripts/backlog-staleness.sh --json
#   .claude/scripts/backlog-staleness.sh --days 45 --json \
#     | jq '[.[] | select(.category=="inactive")]'
#
# DEPENDENCIES:
#   - gh CLI (authenticated), git, jq, bash 3.2+ (macOS-compatible)

set -uo pipefail
printf '%s\t%s\t%s\n' "$(date -u +%FT%TZ)" "$(basename "$0")" "${*//$'\n'/ }" 2>/dev/null >> "$HOME/.claude/script-usage.log" || true

print_help() {
  sed -n '2,45p' "$0" | sed 's/^# \{0,1\}//'
}

err() {
  printf 'backlog-staleness.sh: %s\n' "$1" >&2
}

to_epoch() {
  # Portable ISO-8601 UTC (e.g. 2026-07-21T17:13:05Z) -> epoch seconds.
  # Tries GNU date, then BSD/macOS date. Returns non-zero (no stdout) if both
  # fail -- callers MUST check the exit code, never assume a numeric result
  # (a silently fabricated epoch previously corrupted TTL/age math -- #634).
  local iso="$1"
  date -u -d "$iso" +%s 2>/dev/null && return 0
  date -u -j -f "%Y-%m-%dT%H:%M:%SZ" "$iso" +%s 2>/dev/null && return 0
  return 1
}

DAYS=30
EMIT_JSON=0

while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help)
      print_help
      exit 0
      ;;
    --days)
      if [ $# -lt 2 ] || [ -z "${2-}" ]; then
        err "--days requires a value"
        exit 2
      fi
      DAYS="$2"
      shift 2
      ;;
    --days=*)
      DAYS="${1#--days=}"
      shift
      ;;
    --json)
      EMIT_JSON=1
      shift
      ;;
    *)
      err "unknown flag: $1"
      err "Run with --help for usage."
      exit 2
      ;;
  esac
done

# Validate --days the same way /pm-clean validates $ARGUMENTS: non-numeric or
# non-positive falls back to 30 with a warning, rather than a hard failure.
case "$DAYS" in
  ''|*[!0-9]*)
    err "Invalid --days value '$DAYS', defaulting to 30 days"
    DAYS=30
    ;;
  *)
    if [ "$DAYS" -le 0 ]; then
      err "Threshold must be positive, defaulting to 30 days"
      DAYS=30
    fi
    ;;
esac

command -v gh >/dev/null 2>&1 || { err "gh CLI not found"; exit 3; }
command -v jq >/dev/null 2>&1 || { err "jq not found"; exit 3; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

TMP="$(mktemp -d)"
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

# ---------------------------------------------------------------------------
# Fetch the three GitHub state snapshots /pm-clean's Steps 1-3 depend on.
# ---------------------------------------------------------------------------

if ! OPEN_ISSUES=$(gh issue list --state open --limit 500 \
    --json number,title,labels,assignees,createdAt,updatedAt,body 2>"$TMP/open.err"); then
  err "gh issue list (open) failed: $(cat "$TMP/open.err")"
  exit 3
fi
if [ "$(printf '%s' "$OPEN_ISSUES" | jq 'length')" -eq 500 ]; then
  err "Open issue count hit the 500-item fetch cap — results may be incomplete."
fi

if ! MERGED_PRS=$(gh pr list --state merged --limit 200 \
    --json number,title,body,mergedAt,headRefName 2>"$TMP/merged.err"); then
  err "gh pr list (merged) failed: $(cat "$TMP/merged.err")"
  exit 3
fi

if ! OPEN_PRS=$(gh pr list --state open --limit 200 \
    --json number,title,body 2>"$TMP/openpr.err"); then
  err "gh pr list (open) failed: $(cat "$TMP/openpr.err")"
  exit 3
fi

# `gh issue list --json` does not expose `stateReason` on this gh CLI version
# (older releases lack the field entirely), so closed issues are fetched via
# the REST API directly, which does return `state_reason`. The issues
# endpoint also returns PRs — filter those out via the `pull_request` key.
if ! RAW_CLOSED=$(
  gh api "repos/{owner}/{repo}/issues?state=closed&per_page=100&page=1" 2>"$TMP/closed.err" \
    && gh api "repos/{owner}/{repo}/issues?state=closed&per_page=100&page=2" 2>>"$TMP/closed.err"
); then
  err "gh api (closed issues) failed: $(cat "$TMP/closed.err")"
  exit 3
fi
if [ "$(printf '%s' "$RAW_CLOSED" | jq -s '[.[][]] | length')" -eq 200 ]; then
  err "Closed issue count hit the 200-item fetch cap — duplicate detection may be incomplete."
fi
CLOSED_ISSUES=$(printf '%s' "$RAW_CLOSED" | jq -s '[.[][] | select(has("pull_request") | not)
  | {number, title, body, closedAt: .closed_at, stateReason: .state_reason}]')

printf '%s' "$OPEN_ISSUES" > "$TMP/open.json"
printf '%s' "$MERGED_PRS" > "$TMP/merged.json"
printf '%s' "$OPEN_PRS" > "$TMP/openprs.json"
printf '%s' "$CLOSED_ISSUES" > "$TMP/closed.json"

: > "$TMP/flags.jsonl"

# Word-list constants for title/keyword normalization (Steps 4 and 7).
STOPWORDS_JSON='["a","an","the","and","or","but","in","on","at","to","for","of","with","by","is","are","was","were","be","been","this","that","these","those","it","its","as","from","into","onto","over","under","when","while","then","than","if","so","not","no","do","does","did","has","have","had","will","would","should","could","can","may","might","must","shall","also","about","after","before","between","during","without","within"]'
GENERIC_VERBS_JSON='["add","adds","added","adding","fix","fixes","fixed","fixing","update","updates","updated","updating","change","changes","changed","changing","remove","removes","removed","removing"]'
SKIP_LABELS_JSON='["pinned","do-not-close","long-term","epic"]'

JQ_SIGWORDS_DEF='
def sigwords:
  (. // "")
  | ascii_downcase
  | gsub("[^a-z0-9 ]"; " ")
  | split(" ")
  | map(select(length >= 4))
  | map(select(. as $w | (($stop + $verbs) | index($w)) | not))
  | unique;
'

# ---------------------------------------------------------------------------
# Step 4: solved-by-merged-PR
# ---------------------------------------------------------------------------

# Strong signal: closing keywords in the PR body referencing an open issue.
if ! jq -nc --argjson stop "$STOPWORDS_JSON" --argjson verbs "$GENERIC_VERBS_JSON" "
$JQ_SIGWORDS_DEF
(\$open[0]) as \$open_issues |
(\$merged[0])[] as \$pr |
( [\$pr.body // \"\" | scan(\"(?i)(?:close[sd]?|fix(?:e[sd])?|resolve[sd]?)[[:space:]]+#([0-9]+)\")]
  | map(.[0] // .) | map(tonumber) | unique
) as \$closed_nums |
\$closed_nums[] as \$n |
(\$open_issues[] | select(.number == \$n)) as \$issue |
{number: \$issue.number, title: \$issue.title, category: \"solved-by-pr\",
 rationale: (\"PR #\" + (\$pr.number|tostring) + \" (\\\"\" + \$pr.title + \"\\\") merged on \" + (\$pr.mergedAt // \"\" | .[0:10]) + \" references a closing keyword for #\" + (\$n|tostring) + \" but the issue remains open.\"),
 pr: \$pr.number, merged_at: \$pr.mergedAt}
" --slurpfile open "$TMP/open.json" --slurpfile merged "$TMP/merged.json" \
  >> "$TMP/flags.jsonl" 2>"$TMP/step4a.err"; then
  err "solved-by-pr (closing-keyword) detection failed, continuing with partial results: $(cat "$TMP/step4a.err")"
fi

# Weak signal: branch name carries the issue number AND title/body share 2+
# significant keywords with the open issue (avoids coincidental numbering).
if ! jq -nc --argjson stop "$STOPWORDS_JSON" --argjson verbs "$GENERIC_VERBS_JSON" "
$JQ_SIGWORDS_DEF
(\$open[0]) as \$open_issues |
(\$merged[0])[] as \$pr |
(\$pr.headRefName // \"\" | scan(\"^(?:issue-)?([0-9]+)-\")) as \$m |
(\$m[0] // \$m) as \$branch_num_s |
select(\$branch_num_s != null) |
(\$branch_num_s | tonumber) as \$branch_num |
(\$open_issues[] | select(.number == \$branch_num)) as \$issue |
((\$pr.title // \"\") + \" \" + (\$pr.body // \"\") | sigwords) as \$pr_words |
(\$issue.title | sigwords) as \$issue_words |
([\$pr_words[] | select(. as \$w | \$issue_words | index(\$w))]) as \$shared |
select((\$shared | length) >= 2) |
{number: \$issue.number, title: \$issue.title, category: \"solved-by-pr\",
 rationale: (\"PR #\" + (\$pr.number|tostring) + \" branch '\" + \$pr.headRefName + \"' references #\" + (\$branch_num|tostring) + \" and shares keywords (\" + (\$shared | join(\", \")) + \") — verify it closes the issue.\"),
 pr: \$pr.number, merged_at: \$pr.mergedAt}
" --slurpfile open "$TMP/open.json" --slurpfile merged "$TMP/merged.json" \
  >> "$TMP/flags.jsonl" 2>"$TMP/step4b.err"; then
  err "solved-by-pr (branch-name) detection failed, continuing with partial results: $(cat "$TMP/step4b.err")"
fi

# ---------------------------------------------------------------------------
# Step 5: inactive (updatedAt threshold + comment/PR-ref/commit-ref triple check)
# ---------------------------------------------------------------------------

if ! WINDOW_OUTPUT=$(bash "$SCRIPT_DIR/gh-window.sh" --days "$DAYS"); then
  err "gh-window.sh failed to compute the --days $DAYS window"
  exit 3
fi
IFS=$'\t' read -r SINCE_DATE SINCE_ISO <<< "$WINDOW_OUTPUT"

# Compare on the date portion only (not full ISO instants): gh-window.sh's ISO
# form carries an ET UTC offset (e.g. -04:00) while GitHub's timestamps are
# always "Z"-suffixed UTC — naive lexicographic comparison of the two mixes
# offset formats and can misorder timestamps near a boundary (e.g. the string
# "...T03:59:59Z" sorts >= "...T00:00:00-04:00" even though it is earlier).
# Date-only comparison sidesteps this and matches the day-granularity already
# used elsewhere here via GitHub's own `closed:>=DATE` search qualifier.

# Candidates: open, not label-skipped, updatedAt older than the threshold.
# Sorted oldest-first; only the 50 oldest get the full per-issue verification
# (comment/PR-ref/commit-ref), matching /pm-clean's performance cap.
CANDIDATES_JSON=$(jq -c --argjson skip "$SKIP_LABELS_JSON" --arg since "$SINCE_DATE" '
  [.[] | select((.updatedAt[0:10]) < $since)
        | select((.labels // []) | map(.name | ascii_downcase) | any(. as $l | $skip | index($l)) | not)]
  | sort_by(.updatedAt)
' "$TMP/open.json")

CANDIDATE_COUNT=$(printf '%s' "$CANDIDATES_JSON" | jq 'length')
CHECK_LIMIT=50
if [ "$CANDIDATE_COUNT" -gt "$CHECK_LIMIT" ]; then
  SKIPPED=$((CANDIDATE_COUNT - CHECK_LIMIT))
  err "$SKIPPED additional inactive candidates not fully checked — narrow --days to review them"
fi

printf '%s' "$CANDIDATES_JSON" | jq -c ".[0:$CHECK_LIMIT][]" | while IFS= read -r issue; do
  NUM=$(printf '%s' "$issue" | jq -r '.number')
  TITLE=$(printf '%s' "$issue" | jq -r '.title')
  UPDATED=$(printf '%s' "$issue" | jq -r '.updatedAt')

  # `gh api --paginate --jq` applies the jq filter PER PAGE (each page is a
  # separate JSON array — gh's own docs), not to the concatenated result, and
  # `--slurp` is not supported together with `--jq` on this gh CLI version.
  # Pipe the raw paginated stream through our own `jq -s` instead so `sort |
  # last` sees every comment, not just the last page's.
  LAST_COMMENT=$(gh api --paginate "repos/{owner}/{repo}/issues/$NUM/comments?per_page=100" 2>/dev/null \
    | jq -rs '[.[][] | .created_at] | sort | last' 2>/dev/null)
  [ "$LAST_COMMENT" = "null" ] && LAST_COMMENT=""

  HAS_RECENT_COMMENT=0
  LAST_COMMENT_DATE="${LAST_COMMENT:0:10}"
  if [ -n "$LAST_COMMENT" ] && [[ "$LAST_COMMENT_DATE" > "$SINCE_DATE" || "$LAST_COMMENT_DATE" == "$SINCE_DATE" ]]; then
    HAS_RECENT_COMMENT=1
  fi

  HAS_PR_REF=$(jq -r --arg n "$NUM" '
    any(.[]; ((.title // "") + " " + (.body // "")) | test("(?i)(#" + $n + "\\b|close[sd]?\\s+#" + $n + "\\b|fix(e[sd])?\\s+#" + $n + "\\b|resolve[sd]?\\s+#" + $n + "\\b)"))
  ' "$TMP/openprs.json")

  HAS_COMMIT_REF=0
  if git log --since="$SINCE_DATE" --oneline --grep="#$NUM" 2>/dev/null | grep -q .; then
    HAS_COMMIT_REF=1
  fi

  if [ "$HAS_RECENT_COMMENT" -eq 0 ] && [ "$HAS_PR_REF" = "false" ] && [ "$HAS_COMMIT_REF" -eq 0 ]; then
    LAST_ACTIVITY="${LAST_COMMENT:-$UPDATED}"
    if UPDATED_EPOCH=$(to_epoch "$UPDATED"); then
      AGE_DAYS=$(( ( $(date -u +%s) - UPDATED_EPOCH ) / 86400 ))
      jq -cn --arg num "$NUM" --arg title "$TITLE" --arg last "$LAST_ACTIVITY" --arg age "$AGE_DAYS" '
        {number: ($num|tonumber), title: $title, category: "inactive",
         rationale: ("No activity for " + $age + " days (last updated: " + $last + "). No recent comments, PR references, or commit references."),
         last_activity: $last, age_days: ($age|tonumber)}
      ' >> "$TMP/flags.jsonl"
    else
      err "issue #$NUM: unparseable updatedAt '$UPDATED' — skipping inactive flag (treating as still-active to avoid premature cleanup)"
    fi
  fi
done

# ---------------------------------------------------------------------------
# Step 6: superseded (file/keyword references overtaken by recent commits)
# ---------------------------------------------------------------------------

GENERIC_FILE_TERMS='utils|helper|handler|index'

jq -r --argjson skip "$SKIP_LABELS_JSON" '
  .[] | select((.labels // []) | map(.name | ascii_downcase) | any(. as $l | $skip | index($l)) | not)
  | [.number, .title, .createdAt, (.body // "")] | @tsv
' "$TMP/open.json" | while IFS=$'\t' read -r NUM TITLE CREATED BODY; do
  CREATED_DATE="${CREATED%%T*}"

  # File-path references, excluding generic filenames.
  FILE_PATHS=()
  while IFS= read -r line; do
    [ -n "$line" ] && FILE_PATHS+=("$line")
  done < <(printf '%s' "$BODY" | grep -oE '[a-zA-Z0-9_/.-]+\.[a-z]{2,4}' | sort -u | grep -viE "^(${GENERIC_FILE_TERMS})\.[a-z]{2,4}\$" || true)

  MAX_FILE_COMMITS=0
  BEST_PATH=""
  FILE_MATCH=0
  for path in "${FILE_PATHS[@]:-}"; do
    [ -z "$path" ] && continue
    [ -f "$path" ] || continue
    N=$(git log --since="$CREATED_DATE" --oneline -- "$path" 2>/dev/null | wc -l | tr -d ' ')
    if [ "$N" -ge 3 ]; then
      FILE_MATCH=1
    fi
    if [ "$N" -gt "$MAX_FILE_COMMITS" ]; then
      MAX_FILE_COMMITS="$N"
      BEST_PATH="$path"
    fi
  done

  # Capitalized identifiers in backticks (likely function/component names).
  KEYWORDS=()
  while IFS= read -r line; do
    [ -n "$line" ] && KEYWORDS+=("$line")
  done < <(printf '%s' "$BODY" | grep -oE '`[A-Z][A-Za-z0-9_]*`' | tr -d '`' | sort -u || true)

  KEYWORD_MATCH=0
  BEST_KEYWORD=""
  for kw in "${KEYWORDS[@]:-}"; do
    [ -z "$kw" ] && continue
    N=$(git log --since="$CREATED_DATE" --oneline --grep="$kw" -i 2>/dev/null | wc -l | tr -d ' ')
    if [ "$N" -ge 3 ]; then
      KEYWORD_MATCH=1
      BEST_KEYWORD="$kw"
    fi
  done

  STRONG=0
  if [ "$FILE_MATCH" -eq 1 ] && [ "$KEYWORD_MATCH" -eq 1 ]; then
    STRONG=1
  elif [ "$MAX_FILE_COMMITS" -ge 5 ]; then
    STRONG=1
  fi

  if [ "$STRONG" -eq 1 ]; then
    jq -cn --arg num "$NUM" --arg title "$TITLE" --arg path "$BEST_PATH" --arg commits "$MAX_FILE_COMMITS" --arg kw "$BEST_KEYWORD" '
      {number: ($num|tonumber), title: $title, category: "superseded",
       rationale: ("Files referenced in this issue (`" + $path + "`) have been modified in " + $commits + " commits since the issue was created. The described behavior may already be addressed."),
       path: $path, commits: ($commits|tonumber), keyword: $kw}
    ' >> "$TMP/flags.jsonl"
  fi
done

# ---------------------------------------------------------------------------
# Step 7: potential-duplicate (title similarity vs. resolved closed issues)
# ---------------------------------------------------------------------------

if ! jq -nc --argjson stop "$STOPWORDS_JSON" --argjson verbs "$GENERIC_VERBS_JSON" --argjson skip "$SKIP_LABELS_JSON" "
$JQ_SIGWORDS_DEF
(\$closed[0] | map(select(.stateReason == \"completed\"))) as \$resolved |
(\$open[0][] | select((.labels // []) | map(.name | ascii_downcase) | any(. as \$l | \$skip | index(\$l)) | not)
             | select((.body // \"\") | test(\"(?i)(follow-up to|related to)\\\\s+#[0-9]+\") | not)) as \$issue |
(\$issue.title | sigwords) as \$iwords |
\$resolved[] as \$c |
(\$c.title | sigwords) as \$cwords |
([\$iwords[] | select(. as \$w | \$cwords | index(\$w))]) as \$shared |
select((\$shared | length) >= 3) |
{number: \$issue.number, title: \$issue.title, category: \"potential-duplicate\",
 rationale: (\"Similar to closed #\" + (\$c.number|tostring) + \" (\\\"\" + \$c.title + \"\\\", closed \" + (\$c.closedAt // \"\" | .[0:10]) + \"). Shared keywords: \" + (\$shared | join(\", \")) + \".\"),
 closed_issue: \$c.number, closed_title: \$c.title, closed_at: \$c.closedAt, keywords: \$shared}
" --slurpfile open "$TMP/open.json" --slurpfile closed "$TMP/closed.json" \
  >> "$TMP/flags.jsonl" 2>"$TMP/step7.err"; then
  err "potential-duplicate detection failed, continuing with partial results: $(cat "$TMP/step7.err")"
fi

# ---------------------------------------------------------------------------
# Emit
# ---------------------------------------------------------------------------

if [ "$EMIT_JSON" -eq 1 ]; then
  jq -c -s '.' "$TMP/flags.jsonl"
else
  jq -r '[.number, .category, .rationale] | @tsv' "$TMP/flags.jsonl"
fi

exit 0
