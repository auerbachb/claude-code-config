# PM Data Gathering Patterns

Canonical `gh` CLI query patterns for PM skill data collection. When adding or modifying a PM skill that gathers GitHub data over a time window, use these patterns for consistency across `/pm-rate-team`, `/pm-sprint-review`, `/pm-team-standup`, `/pm-sprint-plan`, and `/prioritize`.

> **Scope:** This document covers cross-skill shared queries only. Skill-specific logic (ranking, narrative generation, per-skill filters) stays in each SKILL.md. Do NOT move query logic out of SKILL.md files — this doc is a reference, not a shared library.

## Consistency rules

1. **Use `>=` not `>` for GitHub search date qualifiers.** `merged:>$DATE` excludes boundary-day data; `merged:>=$DATE` is inclusive. All PM skills should use `>=`. (Source: memory note `feedback_date_filter_inclusivity.md`.)
2. **Always paginate review scans.** GitHub's default `per_page=30` silently truncates. Use `--paginate` and `per_page=100` when scanning PRs to fetch reviews.
3. **Always filter bots.** Exclude logins ending in `[bot]` plus the legacy `github-actions` account. `dependabot`, `renovate` also excluded when listing human contributors.
4. **Normalize timezone offsets.** GitHub search requires `+HH:MM` (colon-separated). `date` emits `+HHMM` — post-process with `sed`.
5. **Honor `TZ='America/New_York'`.** All time window calculations anchor to Eastern time for consistency with the rest of the workflow.

## Time window utilities

Use `.claude/scripts/gh-window.sh` to compute a `$DAYS`-ago window in both date-only (`YYYY-MM-DD`, for GitHub search qualifiers) and ISO 8601 (`YYYY-MM-DDTHH:MM:SS±HH:MM`, for JSON comparisons) forms. The script is ET-anchored and handles macOS (`date -v`) and GNU (`date -d`) transparently.

```bash
# Both values at once (recommended):
IFS=$'\t' read -r SINCE_DATE SINCE_ISO < <(bash .claude/scripts/gh-window.sh --days "$DAYS")

# Or individually:
SINCE_DATE=$(bash .claude/scripts/gh-window.sh --days "$DAYS" --format date)
SINCE_ISO=$(bash .claude/scripts/gh-window.sh --days "$DAYS" --format iso)
```

Exit codes: `0` OK, `2` usage error (missing/invalid `--days` or bad `--format`), `3` `date` command failed on this platform. See the script header for the full contract.

## Merged PRs in a time window

```bash
gh pr list --state merged --search "merged:>=$SINCE_DATE" \
  --json number,title,author,mergedAt,additions,deletions,commits --limit 200
```

Returns: PR number, title, author login, merge timestamp, code volume, commit count. Used by `/pm-rate-team`, `/pm-sprint-review`.

## Closed issues with closer attribution

`gh issue list` does not expose `closedBy`. Fetch the list server-side, then query the events API per issue to find who closed it:

```bash
# Step 1: list closed issues in the window
gh issue list --state closed --search "closed:>=$SINCE_DATE" \
  --json number,title,closedAt,labels --limit 200

# Step 2: for each issue number, find the closer
gh api --paginate "repos/{owner}/{repo}/issues/$ISSUE_NUM/events?per_page=100" \
  | jq -r '[.[] | select(.event == "closed")] | last | .actor.login'
```

Attach the `closer` value to each issue record, then compute per-contributor closed counts downstream. Used by `/pm-rate-team`, `/pm-sprint-review`.

## Review cycles per PR

Count review-then-fix rounds for a merged PR. A review counts as one cycle when at least one commit lands after it and before the next review (or merge). Reviews with no subsequent commits are non-actionable.

**Use the extracted script:**

```bash
CYCLES=$(.claude/scripts/cycle-count.sh "$PR_NUM" --exclude-bots)
```

Default includes all reviewers; `--exclude-bots` drops logins ending in `[bot]` or equal to `github-actions` (used for human-review metrics). See `.claude/scripts/cycle-count.sh --help` for the full contract (exit codes: `0` OK, `2` usage, `3` PR not found, `4` gh error).

Internally the script fetches `pulls/$PR_NUM/reviews?per_page=100` and `pulls/$PR_NUM/commits?per_page=100`, sorts by submitted_at / committer date, and counts reviews with `review.submitted_at < commit.date < next_boundary` (next review's `submitted_at`, or `mergedAt`, or now for open PRs). Used by `/merge`, `/wrap`, `/pm-rate-team`, `/pm-sprint-review`.

## Review participation (reviews given by a contributor)

Scan PRs updated during the window, then fetch reviews authored within the window:

```bash
gh api --paginate "repos/{owner}/{repo}/pulls?state=all&sort=updated&direction=desc&per_page=100" \
  | jq -r '.[] | select(.updated_at > "'"$SINCE_ISO"'") | .number' | while read -r pr_num; do
  gh api "repos/{owner}/{repo}/pulls/$pr_num/reviews?per_page=100" \
    --jq '.[] | select(.submitted_at > "'"$SINCE_ISO"'")
            | select(.user.login | (endswith("[bot]") or . == "github-actions") | not)
            | {reviewer: .user.login, pr: '"$pr_num"', state: .state}'
done
```

Count reviews per reviewer. Exclude self-reviews (reviewer == PR author). Used by `/pm-rate-team`, `/pm-sprint-review`, `/pm-team-standup`.

## Bot filtering

Drop contributors whose `login` matches any of:

- ends with `[bot]` (e.g., `coderabbitai[bot]`, `cursor[bot]`, `greptile-apps[bot]`, `dependabot[bot]`)
- equals `github-actions`, `dependabot`, `renovate`

jq filter for an author stream:

```bash
jq '[.[] | select(.author.login | (endswith("[bot]") or . == "github-actions" or . == "dependabot" or . == "renovate") | not)]'
```

## First-pass CR success rate

For each merged PR, check whether CodeRabbit's first review passed clean:

```bash
# 1. Fetch first CR review
gh api "repos/{owner}/{repo}/pulls/$PR_NUM/reviews?per_page=100" \
  --jq '[.[] | select(.user.login == "coderabbitai[bot]")] | sort_by(.submitted_at) | first'

# 2. Fetch its inline comments; empty array + state != CHANGES_REQUESTED = first-pass success
gh api "repos/{owner}/{repo}/pulls/$PR_NUM/reviews/$FIRST_CR_REVIEW_ID/comments?per_page=100"
```

If no `coderabbitai[bot]` reviews exist across all PRs in the window, skip this metric with a note. Used by `/pm-rate-team`.

## Graceful degradation

- **No reviews in window:** skip cycle-count metrics with a single-line note — do not emit zero-value rows.
- **No CR activity:** skip first-pass rate entirely — do not report 0%.
- **Single-contributor repo:** still produce the report; relabel as "Contribution Report" rather than "Team Contribution Report".
- **Empty window:** short-circuit with "No completed work found in the last $DAYS days" and stop.

## Maintenance

When updating any of the query patterns above, update this doc AND every PM skill that references it.

**Currently migrated** (cite this doc in a `## Data gathering` section):

- `.claude/skills/pm-rate-team/SKILL.md`
- `.claude/skills/pm-team-standup/SKILL.md`

**Not yet migrated** (share the same patterns but still inline them — migrate in follow-up work):

- `.claude/skills/pm-sprint-review/SKILL.md`
- `.claude/skills/pm-sprint-plan/SKILL.md`
- `.claude/skills/prioritize/SKILL.md`

When onboarding a skill from the "not yet migrated" list, add a `## Data gathering` reference section near the top and move it into "currently migrated." When adding a brand-new PM skill, add it directly to "currently migrated."

