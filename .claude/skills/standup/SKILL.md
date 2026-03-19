---
name: standup
description: Generate a daily standup summary of what was accomplished since the last standup, from a business logic perspective
disable-model-invocation: true
argument-hint: [since-time, e.g. "yesterday at noon ET"]
---

Generate a standup report summarizing what was accomplished since $ARGUMENTS (default: "yesterday at noon ET" if no argument given).

## How to gather data

1. **Find all repos the user works in.** Check recent git activity across known repo paths. Start with the current working directory, then check other repos mentioned in conversation context or memory.

2. **Convert the user's time reference to an ISO 8601 timestamp** with the correct UTC offset (handles EST/EDT automatically):
   ```bash
   # Example: "yesterday at noon ET" → ISO 8601 with correct offset
   SINCE_ISO=$(TZ='America/New_York' date -d 'yesterday 12:00' '+%Y-%m-%dT%H:%M:%S%z' 2>/dev/null || TZ='America/New_York' date -v-1d -v12H -v0M -v0S '+%Y-%m-%dT%H:%M:%S%z')
   ```
   Adjust the date expression to match the user's time reference.

3. **For each repo**, run:
   ```bash
   # Closed issues since the cutoff
   gh issue list --state closed --search "closed:>$SINCE_ISO" --json number,title,closedAt --limit 50

   # Merged PRs since the cutoff
   gh pr list --state merged --search "merged:>$SINCE_ISO" --json number,title,mergedAt,additions,deletions --limit 50

   # Currently open PRs (in progress work)
   gh pr list --state open --author @me --json number,title,createdAt,additions,deletions
   ```

## How to write the report

Write from the user's perspective ("I" / "we") for direct paste into a standup channel or meeting.

**Format:**

```text
**Since [time reference]:**

[2-4 bullet points summarizing what was accomplished in business logic terms — what capabilities were added, what problems were solved, what the system can now do that it couldn't before. Lead with the "so what" not the "what".]

**In progress:**
[1-2 bullets on open PRs or active work]

**Scale:** [N] issues closed, [M] PRs merged, [K] PRs open, ~[L] lines changed
```

**Writing rules:**
- Frame accomplishments in terms of **business value and system capabilities**, not file names or technical implementation details
- Group related issues/PRs into a single bullet when they serve the same goal
- "~lines changed" = sum of additions + deletions across merged PRs (rough scale indicator)
- Keep the whole report under 150 words — this is for a quick standup, not a changelog
- Do NOT list every issue/PR individually unless there are fewer than 4 total
- Do NOT mention CR review cycles, code review tooling, or process details — focus on outcomes
