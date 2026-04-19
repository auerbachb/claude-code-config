---
name: standup
description: Generate a daily standup summary of what was accomplished since the last standup, from a business logic perspective. Reads PR bodies to understand what changes actually enabled.
triggers:
  - daily standup
  - what did I do yesterday
  - recent work summary
argument-hint: "[since-time] — omit for smart default (skips weekends/holidays); e.g. \"Friday at noon ET\""
model: sonnet
allowed-tools:
  - Read
  - Glob
  - Grep
  - Bash
  - WebFetch
  - WebSearch
---

Generate a standup report summarizing what was accomplished since $ARGUMENTS (default: smart lookback to previous workday noon ET — skips weekends and US federal holidays).

## How to gather data

### Step 1: Find repos and set time range

1. **Find all repos the user works in.** Check recent git activity across known repo paths. Start with the current working directory, then check other repos mentioned in conversation context or memory.

2. **Determine the lookback cutoff.** If the user provided an explicit `$ARGUMENTS` time reference, use it directly (skip to the ISO conversion below). If no argument was given, compute the smart default: find the most recent prior workday by walking backwards from yesterday, skipping weekends, US federal holidays, and the day after Thanksgiving (a de facto holiday for most organizations).

   **Smart lookback algorithm** (run only when `$ARGUMENTS` is empty):

   ```bash
   # Delegates to .claude/scripts/workday.sh, which implements the full
   # weekend + US-federal-holiday + day-after-Thanksgiving calculator with
   # observed-date rules (Sat → Fri, Sun → Mon) and cross-year lookbacks.
   LOOKBACK_DATE=$(bash .claude/scripts/workday.sh --last-workday)
   # LOOKBACK_DATE is now the most recent prior workday (YYYY-MM-DD)
   ```

3. **Convert to an ISO 8601 timestamp** with the correct UTC offset (handles EST/EDT automatically):
   ```bash
   if [ -n "$ARGUMENTS" ]; then
     # User provided an explicit time reference — parse it directly, bypass smart lookback
     # The agent should convert $ARGUMENTS to the appropriate date -d / date -v expression.
     # Example for "yesterday at noon ET": date -d 'yesterday 12:00' or date -v-1d -v12H -v0M -v0S
     SINCE_ISO=$(TZ='America/New_York' date -d "$ARGUMENTS" '+%Y-%m-%dT%H:%M:%S%z' 2>/dev/null || TZ='America/New_York' date -jf '%Y-%m-%d %H:%M' "$ARGUMENTS" '+%Y-%m-%dT%H:%M:%S%z' 2>/dev/null)
     if [ -z "$SINCE_ISO" ]; then
       echo "Error: Could not parse time reference: $ARGUMENTS" >&2
       exit 1
     fi
   else
     # Smart default — LOOKBACK_DATE was computed above (most recent prior workday)
     if [ -z "$LOOKBACK_DATE" ]; then
       echo "Error: Failed to compute lookback date" >&2
       exit 1
     fi
     SINCE_ISO=$(TZ='America/New_York' date -d "${LOOKBACK_DATE} 12:00" '+%Y-%m-%dT%H:%M:%S%z' 2>/dev/null || TZ='America/New_York' date -jf '%Y-%m-%d %H:%M' "${LOOKBACK_DATE} 12:00" '+%Y-%m-%dT%H:%M:%S%z')
     if [ -z "$SINCE_ISO" ]; then
       echo "Error: Failed to convert lookback date to ISO timestamp" >&2
       exit 1
     fi
   fi
   SINCE_ISO=$(printf '%s' "$SINCE_ISO" | sed -E 's/([+-][0-9]{2})([0-9]{2})$/\1:\2/')
   ```
   The explicit `if/else` ensures `$ARGUMENTS` overrides the smart lookback cleanly. Both branches produce `SINCE_ISO` in the same format for downstream use.

### Step 2: Pull issues, PRs, and line counts

For each repo, run:
```bash
# Closed issues since the cutoff
gh issue list --state closed --search "closed:>$SINCE_ISO" --json number,title,closedAt --limit 100

# Merged PRs since the cutoff
gh pr list --state merged --search "merged:>$SINCE_ISO" --json number,title,mergedAt,additions,deletions --limit 100

# Currently open PRs (in progress work)
gh pr list --state open --author @me --json number,title,createdAt,additions,deletions
```

### Step 3: Read PR bodies (CRITICAL — do not skip)

**This is what makes the report useful.** Titles alone cannot convey business context.

For every merged PR and every open PR (using the `number` field from Step 2's JSON output), read the PR body:
```bash
# For each PR number from Step 2:
gh pr view "$PR_NUMBER" --json body,title,additions,deletions
```

Scan each PR body for:
- **What the change enables** — the "so what" for the business
- **Concrete numbers** — record counts, accuracy metrics, coverage stats, thresholds
- **Which part of the system** this advances — classification, scraping, data pipeline, UI, etc.

If a PR body is thin or template-only, extract the linked issue number (look for `Fixes #N`, `Closes #N`, or similar patterns in the PR body) and read the issue body:
```bash
gh issue view "$ISSUE_NUMBER" --json body,title
```

### Step 4: Identify business themes

Group the PRs/issues into **2-5 business themes** based on what they collectively accomplish. A theme is a capability or milestone, not a file or module. Examples of good themes:
- "Carrier classification pipeline is production-ready"
- "Portal coverage map is now accurate and scrapable"
- "Batch scraping infrastructure is ready to execute"

Each theme should map to one section of the report.

## How to write the report

### Opening line
Lead with scale stats in a single line:
```text
Since [time reference]: [N] PRs merged, [K] open, ~[M] issues closed, ~[L] lines added / ~[D] removed (~[net] net)
```
- Lines = sum additions and deletions across merged PRs separately, then compute net

### Body: themed sections

For each business theme, write a short paragraph (2-5 sentences) that explains:
1. **What the system can now do** that it couldn't before (lead with this)
2. **Key concrete numbers** from the PR bodies — record counts, accuracy percentages, coverage stats, state counts, etc. These make the report credible and useful.
3. **How it fits** into the broader goal or next step

Name each theme with a bold one-liner that captures the business outcome, not the technical action. e.g., "**Carrier classification pipeline is production-ready**" not "**Added classification code**".

### Open PRs
Mention open PRs inline if they relate to a theme, or as a standalone line at the end:
```text
**Open PR:** #N (short description of what it does and why)
```

### Closing synthesis
End with a 1-2 sentence "net effect" that answers: "What can the system do now that it couldn't at the start of this period?" This is the single most important line — it's what a PM or exec would read if they read nothing else.

## Writing rules
- Frame everything in terms of **business value and system capabilities**, not file names or technical implementation
- **Include concrete numbers** from PR bodies — these are what make the report useful vs. generic. Counts, percentages, thresholds, coverage metrics.
- Group related issues/PRs into a single theme — never list PRs individually unless there are fewer than 4 total
- Write from the user's perspective ("I" / "we") for direct paste into standup
- No word limit — let the report be as long as it needs to be to convey meaningful context, but stay concise. Typical range: 150-400 words depending on volume of work.
- Do NOT mention CR review cycles, code review tooling, or process details — focus on outcomes
- Do NOT pad with filler or repeat the same point in different words
