# Work Log Auto-Update

> **Always:** Log issue creates, PR opens, and PR merges to the daily work log file. Check for `work-logs/` directory at session start.
> **Ask first:** At session start, confirm the work log directory with the user (once only — skip if already known from context).
> **Never:** Skip logging events. Overwrite existing narrative content in the log file. Log to a directory that doesn't exist.

## Session Start: Detect Work Log Directory

At the start of every session, before any code work:

1. Search the repo for directory matches named `work-logs/` (check common locations first: `docs/work-logs/`, `work-logs/`, `.docs/work-logs/`).
2. **If one match is found:** Ask the user once to confirm: "I found a work log directory at `{path}`. I'll log issues, PRs, and merges there — sound good?" If the user already mentioned the work log or it's clear from context, skip the ask and just use it.
3. **If multiple matches are found:** Ask the user once to choose the canonical path, then persist that choice for the session.
4. **If not found:** Do nothing — this rule is a no-op for repos without work logs.

Once confirmed (or inferred), remember the path for the rest of the session. Do not ask again.

## Daily Log File

- **Naming convention:** `session-log-YYYY-MM-DD.md` (e.g., `session-log-2026-03-16.md`)
- **If today's file doesn't exist**, create it with this header:

```markdown
# Session Log — March 16, 2026
```

Generate the date via: `TZ='America/New_York' date +'%B %-d, %Y'`

The file should also include an `## Activity Log` section (added on first event, or included in the header).

- **If today's file already exists**, append to the `## Activity Log` section at the bottom. If the section doesn't exist yet, add it at the end of the file.

## What to Log

Append a timestamped line to `## Activity Log` on each of these events:

| Event | Format |
|-------|--------|
| Issue created | `- {time} ET — Issue #{N} created: {title}` |
| PR opened | `- {time} ET — PR #{N} opened (Issue #{M}): {title}` |
| PR merged | `- {time} ET — PR #{N} merged (Issue #{M}): {1-line summary of what the PR accomplished}` |

**Time format:** `2:34 PM` (12-hour, no leading zero). Get via: `TZ='America/New_York' date +'%l:%M %p' | sed 's/^ //'`.

### PR merge summaries

On PR merge, write a brief 1-line summary of what the PR accomplished in context of the project — not just the PR title. Example:

```
- 3:15 PM ET — PR #635 merged (Issue #634): Adds global rule for automatic work log entries so every issue/PR/merge event is captured in real time
```

## Coexistence with Narrative Content

Work log files may contain hand-written narrative sections (project context, design decisions, results). The `## Activity Log` section is **append-only** and lives at the bottom of the file. Never modify or reorder existing content above it.
