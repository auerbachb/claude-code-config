---
name: pm-okr
description: Manage the OKRs section of `.claude/pm-config.md`. Show current objectives, set new ones, or get AI-suggested updates based on recent work. OKRs drive `/pm-prioritize` ranking and `/pm-sprint-plan` planning. Use this whenever you want to view, set, or update project OKRs, objectives, key results, or goals. Triggers on "pm okr", "set okrs", "show okrs", "suggest okrs", "project goals", "objectives".
argument-hint: "show | set <objectives> | suggest (default: show)"
---

Manage the OKRs (Objectives and Key Results) section of `.claude/pm-config.md`. OKRs inform `/pm-prioritize` and `/pm-sprint-plan` — keeping them current ensures prioritization reflects actual goals.

Parse `$ARGUMENTS` to determine mode:
- **No argument or "show"**: Display current OKRs
- **"set ..."**: Replace OKRs section with the provided text
- **"suggest"**: Analyze recent work and propose OKR updates

## Step 1: Verify config exists

```bash
test -f .claude/pm-config.md || echo "NO_CONFIG"
```

If missing, tell the user: "No PM config found. Run `/pm` first to bootstrap it." Then stop.

## Step 2: Parse the config

Read `.claude/pm-config.md` and extract the `## OKRs` section content (everything between `## OKRs` and the next `## ` header or end of file).

## Mode: show (default)

Display the current OKRs section. If the section is empty or contains only the default placeholder ("No OKRs set"), tell the user:

```
No OKRs are currently set for this project.

To set OKRs, run: /pm-okr set <your objectives>

Example:
/pm-okr set O1: Launch MVP by April 15
  KR1: All 5 core API endpoints deployed and tested
  KR2: Frontend covers seed selection, pipeline trigger, and results view
  KR3: End-to-end pipeline runs without manual intervention
```

If OKRs exist, display them formatted clearly with any progress indicators the user has added.

## Mode: set

Replace the `## OKRs` section content with the text provided after "set". Preserve all other sections of pm-config.md verbatim.

1. Parse everything after "set " in `$ARGUMENTS` as the new OKRs content
2. Read the full `.claude/pm-config.md`
3. Replace only the content between `## OKRs` and the next `## ` header
4. Write back the file
5. Confirm: "OKRs updated in `.claude/pm-config.md`. These will be used by `/pm-prioritize` and `/pm-sprint-plan` for alignment scoring."

Display the new OKRs for confirmation.

## Mode: suggest

Analyze recent repo activity and suggest OKR updates or new OKRs.

### Step 3a: Gather recent activity

```bash
# Merged PRs in last 30 days
gh pr list --state merged --search "merged:>$(date -v-30d '+%Y-%m-%d' 2>/dev/null || date -d '30 days ago' '+%Y-%m-%d')" --json number,title,body --limit 50

# Closed issues in last 30 days
gh issue list --state closed --search "closed:>$(date -v-30d '+%Y-%m-%d' 2>/dev/null || date -d '30 days ago' '+%Y-%m-%d')" --json number,title --limit 50

# Open issues (to see what's left)
gh issue list --state open --json number,title,labels --limit 50
```

### Step 3b: Identify themes

Group merged PRs and closed issues into business themes (same approach as `/standup`):
- What capabilities were added?
- What areas saw the most investment?
- What's left in the open backlog?

### Step 3c: Generate suggestions

If OKRs already exist:
- For each existing objective, assess progress based on completed work
- Suggest updating key result progress (e.g., "KR2 appears 80% complete — 4 of 5 endpoints deployed based on merged PRs")
- Flag objectives that may be fully achieved
- Suggest new objectives if the backlog reveals work not covered by current OKRs

If no OKRs exist:
- Propose 2-3 objectives derived from the themes of recent and planned work
- Each objective should have 2-4 measurable key results
- Frame objectives around business outcomes, not technical tasks

### Step 3d: Output suggestions

Present suggestions clearly, distinguishing between updates to existing OKRs and new proposed OKRs:

```
## Suggested OKR Updates

### Existing OKRs — Progress Assessment
- O1: Launch MVP by April 15
  - KR1: All 5 core API endpoints deployed ✅ (completed — PRs #42, #45, #48)
  - KR2: Frontend covers core views — 80% (3 of 4 views merged, filtering PR #52 still open)
  - KR3: End-to-end pipeline — not started

### Suggested New Objective
- O2: Improve data pipeline reliability
  - KR1: Add retry logic to all scraping stages (3 open issues relate to this)
  - KR2: Reduce pipeline failure rate to <5%

To apply these updates, run: /pm-okr set <paste updated OKRs>
```

Do not auto-apply suggestions. The user reviews and applies via `/pm-okr set`.
