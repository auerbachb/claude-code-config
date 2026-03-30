---
name: prioritize
description: Scan a repo's open issue backlog and produce a ranked priority list of what a specific engineer should work on next, ordered by impact on a stated business goal. When OKRs are defined in `.claude/pm-config.md`, uses them as an additional ranking signal.
argument-hint: "business goal | @username role-constraints | depth (e.g. \"increase scraping throughput | @auerbachb backend-python | 50\")"
---

Rank open issues by impact on a business goal for a specific engineer. When `.claude/pm-config.md` exists with a non-empty `## OKRs` section, OKR alignment is used as an additional ranking signal — issues that directly advance a key result rank higher than general maintenance. The business goal argument remains the primary signal; OKRs supplement, not replace it.

Parse `$ARGUMENTS` using pipe-delimited format:

```
$ARGUMENTS = "business goal | @username role-constraints | depth"
```

- **Segment 1 (required):** Business goal — the outcome to optimize for (e.g., "increase scraping throughput", "launch MVP by April")
- **Segment 2 (optional):** Engineer's GitHub username (with or without `@`) and role/skill constraints (e.g., `@auerbachb backend-python`, `janedoe frontend-react`). If omitted, rank for any engineer without role filtering.
- **Segment 3 (optional):** Number of open issues to scan. Default: 100.

If only a business goal is provided (no pipes), use defaults for segments 2 and 3. The repo defaults to the current working directory.

## How to gather data

### Step 0: Detect OKRs (optional enhancement)

Check if `.claude/pm-config.md` exists and has a non-empty OKRs section:

```bash
test -f .claude/pm-config.md && echo "CONFIG_EXISTS" || echo "NO_CONFIG"
```

If the config exists, extract the `## OKRs` section content: from a line matching `^## OKRs` at column 1 through the line before the next `^## ` header (or EOF). If the section is empty, contains only the default placeholder ("No OKRs set"), or the config doesn't exist, set `OKR_MODE=false` and proceed with heuristic-only ranking.

If the section contains objectives and key results, set `OKR_MODE=true` and parse the OKRs into a structured list. Expected format:

```
O1: [Objective text]
  KR1: [Key result text] [Progress: X%]
  KR2: [Key result text]
O2: [Objective text]
  KR1: [Key result text]
```

Store each objective with its key results for use in the scoring step.

### Step 1: Gather open issues

Fetch the open issue backlog:
```bash
gh issue list --state open --limit $DEPTH --json number,title,labels,assignees,createdAt,updatedAt
```

Store the result. Extract all issue numbers for the next step.

### Step 2: Read issue bodies (CRITICAL — do not skip)

**Titles alone are insufficient for scoring.** For every open issue from Step 1, read the full body and comments:

```bash
# For each issue number from Step 1:
gh issue view $NUMBER --json body,title,labels,comments,assignees
```

For each issue, extract:
- **Scope and intent** — what the issue actually asks for, not just the title
- **Acceptance criteria** — if present, these define "done"
- **Dependency references** — scan the body AND comments for patterns like:
  - `blocked by #N`, `depends on #N`, `prerequisite for #N`, `after #N`
  - `unblocks #N`, `enables #N`, `required by #N`, `before #N`
  - `Fixes #N`, `Closes #N` (indicates a PR may already be in flight)
- **Complexity signals** — number of acceptance criteria, files mentioned, architectural scope
- **Current assignee** — who (if anyone) is already working on it

### Step 3: Gather engineer context (if username provided)

If an engineer username was provided, understand their current workload and recent activity:

```bash
# Recent merged PRs — shows what they've been working on
gh pr list --author $USERNAME --state merged --limit 20 --json number,title,mergedAt,additions,deletions,files

# Currently open PRs — shows what they're actively doing RIGHT NOW
gh pr list --author $USERNAME --state open --json number,title,createdAt,additions,deletions,files

# Issues currently assigned to them
gh issue list --state open --assignee $USERNAME --json number,title,labels,createdAt
```

Record:
- **Active work:** Open PRs and assigned issues = what the engineer is currently spending time on
- **Recent expertise:** Merged PRs reveal which parts of the codebase they know well
- **Skill signals:** PR titles and changed file paths hint at their technical domain (frontend, backend, infra, data, etc.)

## Analysis instructions

### Score each issue against the business goal

For every open issue, assess:

1. **Goal alignment (primary signal):** How directly does completing this issue advance the stated business goal? Score on a 4-point scale:
   - **Critical:** Directly unblocks or achieves the goal. Without this, the goal cannot be met.
   - **High:** Significant enabler — completing this materially accelerates progress toward the goal.
   - **Medium:** Supporting work — useful but not on the critical path; it can be deferred without derailing the goal.
   - **Low:** Tangential — nice to have, or addresses a different goal entirely.

2. **Leverage (secondary signal):** Does this issue unblock other high-value issues? An issue that unblocks 3 Critical issues is itself Critical, even if its direct goal alignment is Medium.

3. **OKR alignment (when `OKR_MODE=true`):** Match issue content (title, body, labels) against each parsed objective and key result. Apply these adjustments:
   - An issue that directly advances an incomplete key result gets a **one-tier boost** (e.g., Medium → High) unless it's already Critical.
   - An issue that aligns with an objective broadly (but no specific KR) gets a tiebreaker advantage: it ranks ahead of other issues in the same tier that have no OKR alignment. The displayed tier label does not change (e.g., Medium stays Medium) — this only affects ordering within a tier.
   - Issues that don't align with any OKR receive no penalty — they are scored purely on goal alignment and leverage.
   - Record which OKR(s) each issue aligns with for the output rationale (e.g., "Advances O1/KR2").

4. **Cost-benefit:** A small issue that provides High alignment beats a massive issue that provides the same alignment. Factor in estimated effort (from scope signals in the body) when breaking ties within a tier.

### Filter by engineer role/constraints (if provided)

If role/skill constraints were specified (e.g., "backend-python", "frontend-react", "devops"):

- **Match issues to the engineer's domain.** Use issue labels, title keywords, body content, and file references to determine the technical domain of each issue.
- **Exclude issues outside their scope.** If the engineer is "frontend-only", exclude backend/infra issues from the priority list (but note them separately if they're Critical blockers someone else needs to pick up).
- **Boost issues in their expertise area.** Cross-reference with their recent merged PRs — issues touching code they've recently modified are cheaper for them to pick up.

### Detect dependencies

Build a dependency map from the references found in Step 2:

- For each issue, list what it **blocks** and what **blocks it**
- Flag circular dependencies (A blocks B, B blocks A) — these need human resolution
- Identify **dependency chains** — if issue #10 blocks #15 which blocks #20, the chain is: #10 → #15 → #20. The root (#10) gets a priority boost.

### Identify misaligned effort ("stop doing" candidates)

Cross-reference the engineer's **current work** (open PRs + assigned issues from Step 3) against the tier rankings:

- If the engineer is actively working on a **Low** or **Medium** issue while **Critical** or **High** issues sit unassigned in the backlog, flag the current work as a "stop doing" candidate.
- Only flag if the engineer *could* work on the higher-priority issue (matches their role/skills).
- Be specific: name the low-impact work they're on and the high-impact work they should switch to.

## Output format

Structure the output in four sections:

### 1. Summary line

```
Scanned [N] open issues against goal: "[business goal]". [M] issues match [engineer]'s scope. [K] have dependency relationships.
```

If `OKR_MODE=true`, append: `OKRs loaded from pm-config.md — [X] objectives with [Y] key results used for alignment scoring.`

### 2. Tiered priority list

For each tier (Critical, High, Medium, Low), list matching issues:

```
## Critical — Must do to achieve the goal

- **#42 — [Issue title]** — [1-line rationale connecting this issue to the business goal]
  - Unblocks: #50, #53
  - Advances: O1/KR2 *(only if OKR_MODE=true and alignment detected)*
- **#38 — [Issue title]** — [rationale]
  - Blocked by: #35 (assign #35 first)

## High — Significant enablers

- **#55 — [Issue title]** — [rationale]
- **#47 — [Issue title]** — [rationale]
  - Unblocks: #60

## Medium — Supporting work (defer if necessary)

- **#61 — [Issue title]** — [rationale]

## Low — Tangential (skip for now)

- **#70 — [Issue title]** — [rationale: does not advance the stated goal]
```

If a tier has no matching issues, omit it entirely.

### 3. Stop doing (only if applicable)

Only include this section if the engineer is currently working on Medium/Low tier issues while Critical/High issues are available:

```
## Stop doing

You're currently working on:
- **PR #88 — [title]** (addresses #61, Medium tier)
- **Issue #70 — [title]** (Low tier)

Consider pausing these. The Critical/High issues above have more impact on "[business goal]".
```

If the engineer's current work is already well-aligned (Critical/High), omit this section entirely and note: "Current work is well-aligned with the goal."

### 4. Next actions

Concrete, ordered list of what the engineer should do next:

```
## Next actions (in priority order)

1. Pick up **#42** — [what to do first and why]
2. After #42, start **#38** — [brief context]
3. Review **#55** — [may need design discussion before starting]
```

Limit to 3-5 actions. Each action should be specific enough to act on immediately.

## Writing rules

- **Every rationale must connect the issue to the business goal.** "This is a bug" is not a rationale. "This bug blocks the data pipeline that feeds the goal metric" is.
- **1-2 lines per issue maximum** in the tiered list. Save detail for the next actions section.
- **Flag dependencies inline** with the issue they affect (e.g., `Blocked by: #35`). Do not create a separate dependency section — keep it scannable.
- **"Stop doing" is sensitive.** Only include it when the misalignment is clear and the alternative is materially better. Do not flag Medium work as "stop doing" unless Critical work is available.
- **Do not list every issue.** If 80 of 100 issues are Low/tangential, say "68 additional issues are Low-priority relative to this goal" rather than listing them all.
- **Total output should be scannable in under 2 minutes.** An engineering manager should be able to read this and know what to assign.
- **Do not mention the scoring process.** The output should read as a confident recommendation, not a methodology explanation.
- **If no engineer was specified**, skip the "Stop doing" section and the role filtering. Rank all issues for any engineer.
