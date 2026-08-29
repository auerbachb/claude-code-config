#!/usr/bin/env bash
# estimate-log.sh — Record and report guess-vs-actual durations for merged PRs.
#
# PURPOSE
#   Append one JSON row per merged PR to ~/.claude/estimate-log.jsonl (never
#   a repo-committed file at merge time). Three mutually-exclusive modes:
#
#   --append <PR_NUMBER>
#       Fetch PR metadata, resolve the linked issue, parse tier+estimate from
#       the issue body, compute the actual wall-clock duration, and append one
#       row. Idempotent: silently skips if that PR is already in the log.
#       Always exits 0 — this mode is called from /wrap and must never block
#       or delay the merge.  A single WARN: line is printed on failure.
#
#   --backfill [--repo owner/repo] [--limit N]
#       Reconstruct rows for already-merged PRs. Uses the claude-claim comment
#       timestamp as the start time; falls back to PR createdAt with
#       start_source flagged. Idempotent: skips PRs already in the log.
#       Default: the current repo; default limit: 50.
#
#   --rollup [--output FILE]
#       Read the log; compute per-tier median and ~P90; render a reference doc.
#       Default output: .claude/reference/estimate-actuals.md (in cwd repo).
#
# LOG FILE: ~/.claude/estimate-log.jsonl  (one JSON object per line)
#
# ROW SCHEMA
#   {
#     "pr":           <number>,
#     "issue":        <number | null>,
#     "tier":         <"Light"|"Standard"|"Heavy"|null>,
#     "est_lo":       <number | null>,   # minutes, lower bound
#     "est_hi":       <number | null>,   # minutes, upper bound
#     "est_bound":    <number | null>,   # planning bound (equals est_hi)
#     "claim_ts":     <ISO-8601 UTC>,    # when work started
#     "merge_ts":     <ISO-8601 UTC>,    # when PR merged
#     "actual_min":   <number>,          # wall-clock minutes (float)
#     "start_source": <"claim_comment"|"pr_created">,
#     "repo":         <"owner/repo">,
#     "outlier":      <boolean>          # actual_min > est_bound * 3 (unattended flag)
#   }
#
# USAGE
#   estimate-log.sh --append <pr_number> [--repo owner/repo]
#   estimate-log.sh --backfill [--repo owner/repo] [--limit N]
#   estimate-log.sh --rollup [--output FILE] [--repo owner/repo]
#   estimate-log.sh --help | -h
#
# EXIT CODES
#   0   success (--append always exits 0)
#   1   no rows in log / no output produced (--rollup with empty log)
#   2   usage error
#   3   gh / GitHub API error (--backfill, --rollup only)
#   4   dependency missing (jq, gh)
#   5   file / lock error
#
# DEPENDENCIES
#   - gh (authenticated)
#   - jq >= 1.5
#
# EXAMPLES
#   estimate-log.sh --append 1299
#   estimate-log.sh --backfill --limit 30
#   estimate-log.sh --rollup --output /tmp/actuals.md
#   estimate-log.sh --backfill --repo auerbachb/claude-code-config --limit 100

set -euo pipefail
printf '%s\t%s\t%s\n' "$(date -u +%FT%TZ)" "$(basename "$0")" "${*//$'\n'/ }" \
  2>/dev/null >> "$HOME/.claude/script-usage.log" || true

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------
LOG_FILE="${ESTIMATE_LOG_FILE:-$HOME/.claude/estimate-log.jsonl}"
# Lock directory alongside the log file.
LOG_LOCK="${LOG_FILE}.lock"
LOCK_STALE_SECS=120

# Outlier threshold: flag if actual > planning_bound * OUTLIER_MULTIPLIER
OUTLIER_MULTIPLIER=3

# ---------------------------------------------------------------------------
# Helper: print usage
# ---------------------------------------------------------------------------
print_usage() {
  # Print lines between # USAGE and # EXIT CODES (exclusive), stripping the
  # leading "# " comment prefix. Avoid `head -n -1` (not portable on macOS
  # BSD head); instead drop the last line with awk.
  sed -n '/^# USAGE$/,/^# EXIT CODES$/p' "$0" \
    | sed 's/^# \{0,1\}//' \
    | awk 'NR > 1 { print prev } { prev = $0 }'
}

# ---------------------------------------------------------------------------
# Helper: die with usage hint
# ---------------------------------------------------------------------------
die_usage() {
  echo "estimate-log.sh: $1" >&2
  echo "Run with --help for usage." >&2
  exit 2
}

# ---------------------------------------------------------------------------
# Helper: die with error
# ---------------------------------------------------------------------------
die() {
  local code=$1; shift
  echo "estimate-log.sh: $*" >&2
  exit "$code"
}

# ---------------------------------------------------------------------------
# Helper: check dependencies
# ---------------------------------------------------------------------------
check_deps() {
  local missing=()
  command -v jq  >/dev/null 2>&1 || missing+=("jq")
  command -v gh  >/dev/null 2>&1 || missing+=("gh")
  if [[ ${#missing[@]} -gt 0 ]]; then
    die 4 "missing required tools: ${missing[*]}"
  fi
}

# ---------------------------------------------------------------------------
# Advisory file lock (mkdir-based, portable)
# Acquires LOG_LOCK directory; sets LOCK_TOKEN for release check.
# Returns 0 on success, 5 on timeout.
# ---------------------------------------------------------------------------
LOCK_TOKEN=""
acquire_lock() {
  local deadline=$(( $(date +%s) + LOCK_STALE_SECS ))
  LOCK_TOKEN="$$-$(date +%s%N 2>/dev/null || date +%s)-$RANDOM"
  while true; do
    if mkdir "$LOG_LOCK" 2>/dev/null; then
      printf '%s\n' "$LOCK_TOKEN" > "$LOG_LOCK/token" 2>/dev/null || true
      return 0
    fi
    # Stale lock check: only reap if the lock dir is old enough AND
    # the recorded token (if any) differs from ours — avoids clobbering
    # a live holder's lock on a re-entry path.
    # Get lock directory mtime as epoch seconds, portable across BSD and GNU.
    # stat -f %m is BSD (macOS); stat -c %Y is GNU (Linux).
    # Validate the result is numeric before arithmetic to guard against
    # GNU stat's -f flag returning a non-numeric mount-point string.
    local lock_time _t
    _t=$(stat -f %m "$LOG_LOCK" 2>/dev/null || true)
    if ! [[ "$_t" =~ ^[0-9]+$ ]]; then
      _t=$(stat -c %Y "$LOG_LOCK" 2>/dev/null || echo 0)
    fi
    [[ "$_t" =~ ^[0-9]+$ ]] && lock_time=$_t || lock_time=0
    local lock_age=$(( $(date +%s) - lock_time ))
    if [[ $lock_age -gt $LOCK_STALE_SECS ]]; then
      # Read the stored token before removing to avoid clobbering a newly
      # acquired lock from another writer. The window between reading the token
      # and removing the directory is a theoretical race; in practice the lock
      # is held for < 1 ms (append only), and LOCK_STALE_SECS=120 ensures
      # only truly dead/stale holders are reaped. A re-try loop means any
      # false-reap is self-correcting.
      local stored_token
      stored_token=$(cat "$LOG_LOCK/token" 2>/dev/null || echo "")
      # An empty token means the holder never recorded ownership (crash or
      # failed write); treat it as stale just like a differing token.
      if [[ "$stored_token" != "$LOCK_TOKEN" ]]; then
        rm -rf "$LOG_LOCK" 2>/dev/null || true
        continue
      fi
    fi
    if [[ $(date +%s) -gt $deadline ]]; then
      return 5
    fi
    sleep 0.1
  done
}

release_lock() {
  # Release if this process owns the lock (token match) or if no token was
  # ever recorded (crash between mkdir and token write): this process owns it.
  local stored_token
  stored_token=$(cat "$LOG_LOCK/token" 2>/dev/null || echo "")
  if [[ -z "$stored_token" || "$stored_token" == "$LOCK_TOKEN" ]]; then
    rm -rf "$LOG_LOCK" 2>/dev/null || true
  fi
}

# ---------------------------------------------------------------------------
# Resolve a helper script via the three-path candidate order
# ---------------------------------------------------------------------------
resolve_script() {
  local name="$1"
  local candidate
  for candidate in \
    "$HOME/.claude/skills-worktree/.claude/scripts/$name" \
    "$HOME/.claude/scripts/$name" \
    ".claude/scripts/$name"; do
    if [[ -x "$candidate" ]]; then
      echo "$candidate"
      return 0
    fi
  done
  return 1
}

# ---------------------------------------------------------------------------
# Detect the current repo (owner/repo) from git remote
# ---------------------------------------------------------------------------
detect_repo() {
  local remote
  remote=$(git remote get-url origin 2>/dev/null || true)
  # strip .git suffix and extract owner/repo from github URLs
  printf '%s' "$remote" \
    | sed 's|\.git$||' \
    | sed 's|.*github\.com[:/]||'
}

# ---------------------------------------------------------------------------
# Parse estimate from issue body.
# Looks for: Est: {lo}–{hi} min · plan on {bound}
# Outputs: lo hi bound tier  (space-separated; empty string when absent)
# ---------------------------------------------------------------------------
parse_estimate_from_body() {
  local body="$1"
  # Extract Est: line matching the documented format exactly.
  # Pattern: ^Est: {lo}–{hi} min · plan on {bound}$
  # The separator is en-dash (U+2013) or hyphen-minus; · is U+00B7 (middle dot).
  # Strategy: try grep -P (GNU PCRE) first; fall back to awk which handles
  # UTF-8 string matching portably without depending on any grep extension.
  local est_line
  est_line=$(printf '%s' "$body" \
    | grep -oP '^Est:\s+\d+[–-]\d+\s+min\s+·\s+plan\s+on\s+\d+$' \
    2>/dev/null | head -1 || true)
  if [[ -z "$est_line" ]]; then
    # Portable awk fallback: match the line directly using string functions.
    # Handles en-dash (multi-byte) and middle-dot via substring search.
    est_line=$(printf '%s' "$body" | awk '
      /^Est:/ && /min/ && /plan on/ {
        if (index($0, "–") > 0 || index($0, "-") > 0) {
          print
          exit
        }
      }
    ' | head -1 || true)
  fi
  if [[ -z "$est_line" ]]; then
    echo ""
    return
  fi
  # Extract lo, hi, bound using awk for portability
  local lo hi bound
  lo=$(printf '%s' "$est_line" | awk 'match($0, /[0-9]+/) { print substr($0, RSTART, RLENGTH); exit }')
  hi=$(printf '%s' "$est_line" | awk '{
    n = split($0, a, /[–\-]/);
    if (n >= 2) {
      match(a[2], /[0-9]+/);
      print substr(a[2], RSTART, RLENGTH);
    }
  }')
  bound=$(printf '%s' "$est_line" | awk 'match($0, /plan on ([0-9]+)/, m) { print m[1] }' 2>/dev/null \
    || printf '%s' "$est_line" | sed -E 's/.*plan on ([0-9]+)/\1/')

  # Validate: all numeric, lo < hi, bound == hi
  if ! [[ "$lo" =~ ^[0-9]+$ && "$hi" =~ ^[0-9]+$ && "$bound" =~ ^[0-9]+$ ]]; then
    echo ""
    return
  fi
  if [[ "$lo" -ge "$hi" || "$bound" -ne "$hi" ]]; then
    echo ""
    return
  fi

  # Infer tier from the standard table
  local tier="null"
  if [[ "$lo" -eq 15 && "$hi" -eq 30 ]]; then
    tier="Light"
  elif [[ "$lo" -eq 45 && "$hi" -eq 90 ]]; then
    tier="Standard"
  elif [[ "$lo" -eq 90 && "$hi" -eq 180 ]]; then
    tier="Heavy"
  fi

  printf '%s %s %s %s\n' "$lo" "$hi" "$bound" "$tier"
}

# ---------------------------------------------------------------------------
# Compute actual_min from two ISO-8601 UTC timestamps
# Returns float minutes (2 decimal places)
# ---------------------------------------------------------------------------
compute_actual_min() {
  local start_ts="$1"
  local end_ts="$2"
  local start_epoch end_epoch
  # macOS (BSD date) format: -j -f
  start_epoch=$(date -j -u -f '%Y-%m-%dT%H:%M:%SZ' "$start_ts" '+%s' 2>/dev/null \
    || date -d "$start_ts" '+%s' 2>/dev/null \
    || echo 0)
  end_epoch=$(date -j -u -f '%Y-%m-%dT%H:%M:%SZ' "$end_ts" '+%s' 2>/dev/null \
    || date -d "$end_ts" '+%s' 2>/dev/null \
    || echo 0)
  if [[ "$start_epoch" -eq 0 || "$end_epoch" -eq 0 ]]; then
    echo "0"
    return
  fi
  local diff=$(( end_epoch - start_epoch ))
  awk "BEGIN { printf \"%.2f\", $diff / 60 }"
}

# ---------------------------------------------------------------------------
# Fetch claim timestamp for an issue.
# Echoes: "TIMESTAMP source"  (source = claim_comment | pr_created)
# ---------------------------------------------------------------------------
fetch_claim_ts() {
  local issue_number="$1"
  local repo="$2"
  local pr_created_at="$3"
  local merge_ts="${4:-}"   # optional upper bound; empty = no bound

  if [[ -z "$issue_number" || "$issue_number" == "null" ]]; then
    printf '%s pr_created\n' "$pr_created_at"
    return
  fi

  # Fetch issue comments
  local comments_json
  comments_json=$(gh api "repos/$repo/issues/$issue_number/comments" \
    --paginate 2>/dev/null || echo "[]")

  local claim_ts
  # gh api --paginate emits one JSON array per page, concatenated on stdout.
  # jq -s (slurp) collects them into an outer array; .[] | .[] iterates all
  # comment objects across every page.  .[]? guards against an empty page.
  #
  # Design note: we pick the LATEST claim comment at or before the merge
  # timestamp.  Bounding by merge_ts prevents a post-merge re-claim (follow-up
  # work) from producing a negative actual duration.  If no bound is supplied
  # the filter is a no-op (empty string never satisfies <=).
  claim_ts=$(printf '%s' "$comments_json" \
    | jq -rs --arg merge_ts "$merge_ts" \
         '[ .[] | .[]? | select(.body != null and (.body | contains("<!-- claude-claim:")))
                       | select($merge_ts == "" or .created_at <= $merge_ts) ]
          | if length > 0 then (sort_by(.created_at) | last).created_at else "" end' \
    2>/dev/null || echo "")

  if [[ -n "$claim_ts" && "$claim_ts" != "null" && "$claim_ts" != "" ]]; then
    printf '%s claim_comment\n' "$claim_ts"
  else
    printf '%s pr_created\n' "$pr_created_at"
  fi
}

# ---------------------------------------------------------------------------
# Check if a PR is already in the log (matches both pr number AND repo)
# Usage: pr_in_log <pr_number> <repo>
# ---------------------------------------------------------------------------
pr_in_log() {
  local pr_num="$1"
  local repo="${2:-}"
  [[ -f "$LOG_FILE" ]] || return 1
  if [[ -n "$repo" ]]; then
    # Match rows with both the pr number and repo fields.
    # jq is the authoritative check; grep is a fast pre-filter.
    # -R + fromjson? tolerates malformed lines the same way mode_rollup does,
    # so a corrupt line never causes pr_in_log to false-report a miss and
    # insert a duplicate row.
    grep -q "\"pr\":${pr_num}[^0-9]" "$LOG_FILE" 2>/dev/null \
      && jq -e -R --argjson pr "$pr_num" --arg repo "$repo" \
           'fromjson? | select(.pr == $pr and .repo == $repo)' \
           "$LOG_FILE" >/dev/null 2>&1
  else
    # Legacy: pr number only (no repo filter)
    grep -q "\"pr\":${pr_num}[^0-9]" "$LOG_FILE" 2>/dev/null
  fi
}

# ---------------------------------------------------------------------------
# Append one row to the log (with lock + dedup)
# ---------------------------------------------------------------------------
append_row() {
  local row_json="$1"
  local pr_num repo_name
  pr_num=$(printf '%s' "$row_json" | jq -r '.pr')
  repo_name=$(printf '%s' "$row_json" | jq -r '.repo // ""')

  # Ensure log directory exists
  mkdir -p "$(dirname "$LOG_FILE")"

  # Fast dedup check before lock
  if pr_in_log "$pr_num" "$repo_name"; then
    return 0
  fi

  # Acquire lock
  if ! acquire_lock; then
    echo "estimate-log.sh: WARN: could not acquire log lock for PR #$pr_num" >&2
    return 5
  fi
  # Release lock on exit
  # shellcheck disable=SC2064
  trap "release_lock" EXIT

  # Dedup check again under lock (TOCTOU guard)
  if pr_in_log "$pr_num" "$repo_name"; then
    release_lock
    trap - EXIT
    return 0
  fi

  # Append: write the row to a tmp file, then cat-append.
  # On cat failure, the tmp file is removed and the log is left unmodified
  # (a partial cat-append is impossible for a single atomic write of a short
  # line; POSIX guarantees that a write(2) of <= PIPE_BUF bytes is atomic).
  local tmp
  tmp=$(mktemp "$(dirname "$LOG_FILE")/.estimate-log-tmp-XXXXXX")
  # shellcheck disable=SC2064
  trap "release_lock; rm -f '$tmp'" EXIT

  if ! printf '%s\n' "$row_json" > "$tmp"; then
    release_lock
    rm -f "$tmp"
    trap - EXIT
    echo "estimate-log.sh: WARN: failed to write row to temp file $tmp" >&2
    return 5
  fi

  local cat_rc=0
  cat "$tmp" >> "$LOG_FILE" || cat_rc=$?
  rm -f "$tmp"

  if [[ $cat_rc -ne 0 ]]; then
    release_lock
    trap - EXIT
    echo "estimate-log.sh: WARN: failed to append row to $LOG_FILE (cat rc=$cat_rc)" >&2
    return 5
  fi

  # Validate the last line of the log is parseable JSON with the correct PR.
  # A partial/corrupt write would fail this check and we surface a WARN.
  local last_line_pr
  last_line_pr=$(tail -1 "$LOG_FILE" | jq -r '.pr // empty' 2>/dev/null || true)
  if [[ "$last_line_pr" != "$pr_num" ]]; then
    release_lock
    trap - EXIT
    echo "estimate-log.sh: WARN: log validation failed for PR #$pr_num (last_line_pr=$last_line_pr)" >&2
    return 5
  fi

  release_lock
  trap - EXIT
  return 0
}

# ---------------------------------------------------------------------------
# Build one row JSON for a merged PR
# Returns JSON on stdout; prints WARN to stderr on soft errors; exits non-zero
# on hard errors.
# ---------------------------------------------------------------------------
build_row() {
  local pr_num="$1"
  local repo="$2"

  # Fetch PR data
  local pr_json
  pr_json=$(gh api "repos/$repo/pulls/$pr_num" 2>/dev/null) \
    || { echo "estimate-log.sh: WARN: could not fetch PR #$pr_num from $repo" >&2; return 3; }

  local merged_at state pr_created_at
  merged_at=$(printf '%s' "$pr_json" | jq -r '.merged_at // ""')
  state=$(printf '%s' "$pr_json" | jq -r '.state // ""')
  pr_created_at=$(printf '%s' "$pr_json" | jq -r '.created_at // ""')

  if [[ -z "$merged_at" || "$merged_at" == "null" ]]; then
    echo "estimate-log.sh: WARN: PR #$pr_num is not merged (state=$state merged_at=$merged_at)" >&2
    return 1
  fi

  # Resolve linked issue
  local pr_issue_ref_sh
  pr_issue_ref_sh=$(resolve_script pr-issue-ref.sh || true)
  local issue_num=""
  if [[ -n "$pr_issue_ref_sh" ]]; then
    # Pass GH_REPO so pr-issue-ref.sh resolves against the correct repository
    # even when estimate-log.sh is run from a different git checkout.
    issue_num=$(GH_REPO="$repo" "$pr_issue_ref_sh" "$pr_num" 2>/dev/null || true)
  fi

  # Fetch issue body if we have an issue number
  local issue_body=""
  if [[ -n "$issue_num" && "$issue_num" =~ ^[0-9]+$ ]]; then
    issue_body=$(gh api "repos/$repo/issues/$issue_num" 2>/dev/null \
      | jq -r '.body // ""' 2>/dev/null || true)
  fi

  # Parse estimate from issue body
  local est_parts="" lo="null" hi="null" bound="null" tier="null"
  est_parts=$(parse_estimate_from_body "$issue_body")
  if [[ -n "$est_parts" ]]; then
    read -r lo hi bound tier <<< "$est_parts"
  fi

  # Fetch claim timestamp
  local claim_result="" claim_ts="" start_source=""
  claim_result=$(fetch_claim_ts "${issue_num:-}" "$repo" "$pr_created_at" "$merged_at")
  claim_ts=$(printf '%s' "$claim_result" | awk '{print $1}')
  start_source=$(printf '%s' "$claim_result" | awk '{print $2}')

  # Compute actual duration
  local actual_min
  actual_min=$(compute_actual_min "$claim_ts" "$merged_at")

  # Outlier flag: actual_min > est_bound * OUTLIER_MULTIPLIER
  local outlier="false"
  if [[ "$bound" != "null" && "$bound" =~ ^[0-9]+$ && "$bound" -gt 0 ]]; then
    outlier=$(awk "BEGIN { print ($actual_min > $bound * $OUTLIER_MULTIPLIER) ? \"true\" : \"false\" }")
  fi

  # Build JSON row using jq for correct serialization
  local issue_json_val="null"
  [[ -n "$issue_num" && "$issue_num" =~ ^[0-9]+$ ]] && issue_json_val="$issue_num"

  local tier_str="null"
  [[ "$tier" != "null" && -n "$tier" ]] && tier_str="\"$tier\""

  local lo_val="null";    [[ "$lo" != "null" && "$lo" =~ ^[0-9]+$ ]]    && lo_val="$lo"
  local hi_val="null";    [[ "$hi" != "null" && "$hi" =~ ^[0-9]+$ ]]    && hi_val="$hi"
  local bound_val="null"; [[ "$bound" != "null" && "$bound" =~ ^[0-9]+$ ]] && bound_val="$bound"

  jq -cn \
    --argjson pr        "$pr_num" \
    --argjson issue     "$issue_json_val" \
    --argjson tier      "$tier_str" \
    --argjson est_lo    "$lo_val" \
    --argjson est_hi    "$hi_val" \
    --argjson est_bound "$bound_val" \
    --arg     claim_ts  "$claim_ts" \
    --arg     merge_ts  "$merged_at" \
    --argjson actual_min "$actual_min" \
    --arg     start_source "$start_source" \
    --arg     repo      "$repo" \
    --argjson outlier   "$outlier" \
    '{
      pr:           $pr,
      issue:        $issue,
      tier:         $tier,
      est_lo:       $est_lo,
      est_hi:       $est_hi,
      est_bound:    $est_bound,
      claim_ts:     $claim_ts,
      merge_ts:     $merge_ts,
      actual_min:   $actual_min,
      start_source: $start_source,
      repo:         $repo,
      outlier:      $outlier
    }'
}

# ===========================================================================
# MODE: --append
# Always exits 0; prints a single WARN: line on failure.
# ===========================================================================
mode_append() {
  local pr_num="$1"
  local repo="$2"

  # Fast-path: already in log
  if pr_in_log "$pr_num" "$repo"; then
    return 0
  fi

  local row_json
  row_json=$(build_row "$pr_num" "$repo" 2>/dev/null) || {
    # build_row returned non-zero; its WARN lines already went to stderr.
    echo "WARN: estimate-log.sh --append PR #$pr_num: could not build row (repo=$repo)" >&2
    return 0
  }

  # Verify we got valid JSON (not an error message)
  if ! printf '%s' "$row_json" | jq -e '.pr' >/dev/null 2>&1; then
    echo "WARN: estimate-log.sh --append PR #$pr_num: build_row returned non-JSON output" >&2
    return 0
  fi

  if ! append_row "$row_json"; then
    : # append_row already emitted a WARN: line; no duplicate needed.
  fi
  return 0
}

# ===========================================================================
# MODE: --backfill
# ===========================================================================
mode_backfill() {
  local repo="$1"
  local limit="$2"

  echo "estimate-log.sh: backfilling up to $limit merged PRs from $repo ..." >&2

  # Fetch merged PRs (gh returns newest first by default)
  local prs_json
  prs_json=$(gh pr list --repo "$repo" --state merged --limit "$limit" \
    --json number 2>/dev/null) \
    || die 3 "could not list merged PRs for $repo"

  local pr_numbers
  pr_numbers=$(printf '%s' "$prs_json" | jq -r '.[].number')

  local appended=0 skipped=0 failed=0
  while IFS= read -r pr_num; do
    [[ -z "$pr_num" ]] && continue

    # Skip if already in log (fast path)
    if pr_in_log "$pr_num" "$repo"; then
      (( skipped++ )) || true
      continue
    fi

    local row_json
    if row_json=$(build_row "$pr_num" "$repo" 2>/dev/null) \
        && printf '%s' "$row_json" | jq -e '.pr' >/dev/null 2>&1; then
      if append_row "$row_json"; then
        (( appended++ )) || true
        echo "  appended PR #$pr_num" >&2
      else
        (( failed++ )) || true
        echo "  WARN: failed to append PR #$pr_num" >&2
      fi
    else
      (( failed++ )) || true
      echo "  WARN: could not build row for PR #$pr_num" >&2
    fi
  done <<< "$pr_numbers"

  echo "estimate-log.sh: backfill done — appended=$appended skipped=$skipped failed=$failed" >&2

  [[ $failed -eq 0 ]] || return 3
  return 0
}

# ===========================================================================
# MODE: --rollup
# ===========================================================================
mode_rollup() {
  local output_file="$1"
  local repo="$2"

  if [[ ! -f "$LOG_FILE" ]] || [[ ! -s "$LOG_FILE" ]]; then
    echo "estimate-log.sh: log is empty or missing at $LOG_FILE — no rollup to generate" >&2
    return 1
  fi

  # Collect only schema-valid JSON rows for this repo, skipping malformed lines.
  # Checks: (1) valid JSON, (2) required numeric actual_min, (3) boolean outlier.
  # Parse each line individually so a single corrupt row doesn't drop the rest.
  local repo_rows
  repo_rows=$(grep -F "\"repo\":\"$repo\"" "$LOG_FILE" 2>/dev/null \
    | while IFS= read -r line; do
        if printf '%s' "$line" \
            | jq -e '((.actual_min | type) == "number") and
                     ((.outlier   | type) == "boolean")' >/dev/null 2>&1; then
          printf '%s\n' "$line"
        fi
      done \
    | jq -sc '.' 2>/dev/null || echo "[]")

  local row_count
  row_count=$(printf '%s' "$repo_rows" | jq 'length')
  if [[ "$row_count" -eq 0 ]]; then
    echo "estimate-log.sh: no rows for repo $repo in log at $LOG_FILE" >&2
    return 1
  fi

  # Per-tier stats using jq
  local stats_json
  stats_json=$(printf '%s' "$repo_rows" | jq '
    def percentile(p; arr):
      (arr | sort) as $s
      | ($s | length) as $n
      | if $n == 0 then null
        else
          (($n - 1) * p) as $idx
          | ($idx | floor) as $lo_i
          | ($idx | ceil) as $hi_i
          | if $lo_i == $hi_i then $s[$lo_i]
            else ($s[$lo_i] * ($hi_i - $idx) + $s[$hi_i] * ($idx - $lo_i))
            end
        end;
    group_by(.tier) | map({
      tier:          (.[0].tier // "Unknown"),
      count:         length,
      median:        (percentile(0.5; [.[].actual_min]) | . * 100 | round | . / 100),
      p90:           (percentile(0.9; [.[].actual_min]) | . * 100 | round | . / 100),
      outlier_count: ([.[] | select(.outlier == true)] | length)
    })
  ')

  # Recent rows (last 20 with estimates, newest merge first)
  local recent_rows
  recent_rows=$(printf '%s' "$repo_rows" | jq '
    [ .[] | select(.est_lo != null) ]
    | sort_by(.merge_ts) | reverse | .[0:20]
  ')

  local now
  now=$(date -u +%Y-%m-%dT%H:%M:%SZ)

  # Ensure output directory exists
  mkdir -p "$(dirname "$output_file")"

  # Generate the markdown document
  {
    printf '# Estimate Actuals — Guess vs. Reality\n\n'
    printf '> Auto-generated by `estimate-log.sh --rollup` on %s.\n' "$now"
    printf '> Source: `~/.claude/estimate-log.jsonl` (%s rows for `%s`).\n' \
      "$row_count" "$repo"
    printf '> Regenerate: `estimate-log.sh --rollup --repo %s`\n\n' "$repo"
    printf 'This table supplements the seed values in [`time-estimates.md`](time-estimates.md)\n'
    printf 'with medians measured from this repo'\''s real merge history.\n'
    printf 'The seed table remains authoritative for tiers with fewer than ~5 rows.\n\n'

    printf '## Recalibrated Tier → Time Table\n\n'
    printf '| Tier | Measured Median | ~P90 | Rows | Outliers |\n'
    printf '|------|----------------|------|------|----------|\n'
    printf '%s' "$stats_json" | jq -r '
      def fmt(x): if x == null then "—" else (x | tostring) + " min" end;
      .[] | "| \(.tier) | \(fmt(.median)) | \(fmt(.p90)) | \(.count) | \(.outlier_count) |"
    '

    printf '\n> **Outliers**: actual duration exceeded planning bound × 3 (likely\n'
    printf '> unattended/overnight). Included in quantiles; flagged for visibility.\n\n'

    printf '## Recent Guesses vs. Actuals\n\n'
    printf '| PR | Issue | Tier | Estimate | Actual | Δ | Source |\n'
    printf '|----|-------|------|----------|--------|---|--------|\n'

    local has_recent
    has_recent=$(printf '%s' "$recent_rows" | jq 'length')
    if [[ "$has_recent" -gt 0 ]]; then
      printf '%s' "$recent_rows" | jq -r '
        def fmt_min(x): if x == null then "—" else (x | tostring) + " min" end;
        def fmt_est(row): if row.est_lo == null then "—"
          else (row.est_lo | tostring) + "–" + (row.est_hi | tostring) + " min" end;
        def outlier_flag(row): if row.outlier then " ⚠" else "" end;
        def delta(row): if (row.est_bound != null and row.actual_min != null)
          then ((row.actual_min - row.est_bound) * 10 | round | . / 10 | tostring) + " min"
          else "—" end;
        .[] | "| #\(.pr) | \(if .issue then "#\(.issue)" else "—" end) | \(.tier // "—") | \(fmt_est(.)) | \(fmt_min(.actual_min))\(outlier_flag(.)) | \(delta(.)) | \(.start_source) |"
      '
    else
      printf '| (no rows with estimates yet) | | | | | | |\n'
    fi

    printf '\n> ⚠ Outlier: actual exceeded planning bound × 3 (likely includes unattended time).\n'
    printf '>\n'
    printf '> **Δ** = actual − planning bound. Negative = completed under budget.\n'
    printf '>\n'
    printf '> **Source**: `claim_comment` = accurate start (issue claim marker);\n'
    printf '> `pr_created` = approximate fallback (PR creation time).\n'
    printf '>\n'
    printf '> _Generated by `estimate-log.sh --rollup`. Do not edit manually._\n'

  } > "$output_file"

  echo "estimate-log.sh: rollup written to $output_file ($row_count rows)" >&2
  return 0
}

# ===========================================================================
# Argument parsing
# ===========================================================================
MODE=""
PR_ARG=""
REPO_ARG=""
LIMIT_ARG="50"
OUTPUT_ARG=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help)
      print_usage
      exit 0
      ;;
    --append)
      [[ -n "$MODE" ]] && die_usage "only one mode allowed (got --append after --$MODE)"
      MODE="append"
      [[ $# -lt 2 || -z "${2-}" ]] && die_usage "--append requires a PR number"
      PR_ARG="$2"
      shift 2
      ;;
    --backfill)
      [[ -n "$MODE" ]] && die_usage "only one mode allowed"
      MODE="backfill"
      shift
      ;;
    --rollup)
      [[ -n "$MODE" ]] && die_usage "only one mode allowed"
      MODE="rollup"
      shift
      ;;
    --repo)
      [[ $# -lt 2 || -z "${2-}" ]] && die_usage "--repo requires owner/repo"
      REPO_ARG="$2"
      shift 2
      ;;
    --repo=*)
      REPO_ARG="${1#--repo=}"
      [[ -z "$REPO_ARG" ]] && die_usage "--repo requires owner/repo"
      shift
      ;;
    --limit)
      [[ $# -lt 2 || -z "${2-}" ]] && die_usage "--limit requires a number"
      LIMIT_ARG="$2"
      shift 2
      ;;
    --limit=*)
      LIMIT_ARG="${1#--limit=}"
      [[ -z "$LIMIT_ARG" ]] && die_usage "--limit requires a number"
      shift
      ;;
    --output)
      [[ $# -lt 2 || -z "${2-}" ]] && die_usage "--output requires a file path"
      OUTPUT_ARG="$2"
      shift 2
      ;;
    --output=*)
      OUTPUT_ARG="${1#--output=}"
      [[ -z "$OUTPUT_ARG" ]] && die_usage "--output requires a file path"
      shift
      ;;
    -*)
      die_usage "unknown flag: $1"
      ;;
    *)
      die_usage "unexpected argument: $1"
      ;;
  esac
done

[[ -z "$MODE" ]] && die_usage "one of --append, --backfill, or --rollup is required"

# Validate limit
if [[ "$MODE" == "backfill" ]]; then
  if ! [[ "$LIMIT_ARG" =~ ^[0-9]+$ && "$LIMIT_ARG" -gt 0 ]]; then
    die_usage "--limit must be a positive integer"
  fi
fi

# ===========================================================================
# Dependency check (skip for --append to stay best-effort)
# ===========================================================================
if [[ "$MODE" != "append" ]]; then
  check_deps
fi

# ===========================================================================
# Resolve repo
# ===========================================================================
if [[ -z "$REPO_ARG" ]]; then
  REPO_ARG=$(detect_repo)
  if [[ -z "$REPO_ARG" ]]; then
    if [[ "$MODE" == "append" ]]; then
      echo "WARN: estimate-log.sh: could not detect repo" >&2
      exit 0
    else
      die_usage "could not detect repo from git remote; pass --repo owner/repo"
    fi
  fi
fi

# ===========================================================================
# Dispatch
# ===========================================================================
case "$MODE" in
  append)
    if ! [[ "$PR_ARG" =~ ^[0-9]+$ ]]; then
      echo "WARN: estimate-log.sh --append: invalid PR number: $PR_ARG" >&2
      exit 0
    fi
    # Best-effort dep check for --append
    if ! command -v jq >/dev/null 2>&1 || ! command -v gh >/dev/null 2>&1; then
      echo "WARN: estimate-log.sh --append: missing jq or gh — skipping log entry" >&2
      exit 0
    fi
    mode_append "$PR_ARG" "$REPO_ARG"
    ;;

  backfill)
    mode_backfill "$REPO_ARG" "$LIMIT_ARG"
    ;;

  rollup)
    [[ -z "$OUTPUT_ARG" ]] && OUTPUT_ARG=".claude/reference/estimate-actuals.md"
    mode_rollup "$OUTPUT_ARG" "$REPO_ARG"
    ;;
esac
