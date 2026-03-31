---
name: pm-sprint-plan
description: Generate a 2-week sprint plan from the open backlog with dependency detection, parallel tracks, team assignments, and OKR alignment. Reuses /prioritize ranking logic and pm-config.md for team/OKR context.
argument-hint: "[--days N] (default: 14)"
---

Generate a sprint plan from the open backlog. Parse `$ARGUMENTS`:

- If `$ARGUMENTS` contains `--days N`, use N days as the sprint length.
- If empty, default to 14 days.

Extract the value:

```bash
if [[ "$ARGUMENTS" =~ --days[[:space:]]+([0-9]+) ]]; then
  DAYS="${BASH_REMATCH[1]}"
else
  DAYS=14
fi
```

## Step 1: Load pm-config.md (optional)

Check if `.claude/pm-config.md` exists:

```bash
test -f .claude/pm-config.md && echo "CONFIG_EXISTS" || echo "NO_CONFIG"
```

If the config exists, parse it using line-anchored level-2 headers (`^## ` at column 1). Extract these sections when present:

- **`## Team`**: Parse contributor entries for GitHub usernames, display names, and roles. Expected format: lines containing `@username` with optional role/description text.
- **`## OKRs`**: Extract objectives and key results. Set `OKR_MODE=true` if the section is non-empty and does not start with "No OKRs set". Parse into structured list (O1/KR1, O1/KR2, etc.).
- **`## Notes`**: Read for any sprint-relevant context.

If the config is missing or a section is empty/placeholder, degrade gracefully — note which features are skipped.

## Step 2: Fetch and read open issues

### 2a: Fetch the open issue list

```bash
gh issue list --state open --limit 200 --json number,title,labels,assignees,createdAt,updatedAt
```

Store the result. For repos with very large backlogs (200+ issues), the limit caps the scan — note this in the output summary. If zero issues are returned, output: "No open issues found — nothing to plan. Create issues first, then re-run." Then stop.

### 2b: Read each issue body (CRITICAL — do not skip)

Titles alone are insufficient for scoring and dependency detection. For every open issue from 2a:

```bash
gh issue view $NUMBER --json body,title,labels,comments,assignees
```

For each issue, extract:
- **Scope and intent** — what the issue actually asks for
- **Acceptance criteria** — if present, these define "done"
- **Complexity signals** — number of acceptance criteria, files mentioned, architectural scope
- **Current assignee** — who (if anyone) is already working on it

## Step 3: Detect dependencies

### 3a: Explicit dependencies

Scan each issue body and all comments (already fetched via `gh issue view --json comments` in Step 2b) for these patterns (case-insensitive). For issues with 100+ comments, prioritize scanning the issue body and the 20 most recent comments to limit processing time:
- **Blocking patterns** (this issue is blocked BY another): `blocked by #N`, `depends on #N`, `prerequisite: #N`, `after #N`, `requires #N`
- **Dependent patterns** (this issue BLOCKS another): `unblocks #N`, `enables #N`, `required by #N`, `before #N`, `prerequisite for #N`
- **PR linkage**: `Fixes #N`, `Closes #N` — indicates a PR may already be in flight for that issue

Build directed edges: blocker → blocked.

### 3b: Implicit dependencies

Parse issue bodies for file path references — patterns like `src/`, `lib/`, specific filenames, or file extensions (`.ts`, `.py`, `.go`, etc.). Before treating a path as a conflict signal, verify it plausibly exists in the repo (matches directories or file patterns in the current git tree). Paths appearing inside code blocks or example snippets may be illustrative, not actual references — use judgment to filter false positives. Build a co-reference map: issues touching the same verified files likely conflict if run in parallel.

As a secondary signal, identify label overlap where issues share component/area labels (e.g., `backend`, `auth`, `database`, `frontend`). Filter out generic labels (`bug`, `enhancement`, `documentation`, `good first issue`) — only narrow/component labels indicate implicit ordering needs.

### 3c: Build dependency graph

- Create directed edges from blocking → blocked issues
- **Detect circular dependencies** (e.g., #10 → #15 → #20 → #10). Emit a non-fatal warning listing the cycle. Exclude cycled issues from automated track assignment but include them in a dedicated "Circular Dependencies" section of the output with suggested actions (break one link, reprioritize, or mark as external). Do not block overall plan generation.
- Identify dependency chains: if #10 blocks #15 which blocks #20, the chain is #10 → #15 → #20

## Step 4: Score issues against business goal / OKRs

### 4a: Goal alignment (primary signal)

If the user provided a business goal via `$ARGUMENTS` (any text that isn't `--days N`), score each issue on a 4-tier scale:
- **Critical:** Directly unblocks or achieves the goal
- **High:** Significant enabler — materially accelerates progress
- **Medium:** Supporting work — useful but not on the critical path
- **Low:** Tangential — nice to have or addresses a different goal

If no business goal is provided, score based on general impact: issues that unblock others rank higher, recent/active issues rank higher than stale ones.

### 4b: OKR alignment (when OKR_MODE=true)

Match issue content (title, body, labels) against each parsed objective and key result:
- Issue directly advancing an incomplete key result: **one-tier boost** (e.g., Medium → High) unless already Critical
- Issue broadly aligning with an objective (no specific KR): tiebreaker advantage within same tier
- No OKR alignment: no penalty — scored purely on goal alignment and leverage
- Record which OKR(s) each issue aligns with (e.g., "Advances O1/KR2")

### 4c: Leverage boost

An issue that unblocks multiple high-value issues gets a priority boost. A root issue in a dependency chain that unblocks 3+ Critical/High issues is itself Critical.

## Step 5: Group into parallel tracks

### 5a: Identify independent work streams

Using the dependency graph from Step 3:
- Issues in the same dependency chain belong to one track (executed sequentially within the track)
- Independent chains form separate parallel tracks
- Issues with no dependencies are free agents — assign to the track where they fit best by component/theme, or create a standalone track

### 5b: Label tracks

Label each track by its dominant theme or component when possible (e.g., "Frontend Track", "API Track", "Infrastructure Track"). If no clear theme, use "Track 1", "Track 2", etc.

### 5c: Order within tracks

Within each track, order by:
1. Dependency sequence (roots first, then dependents)
2. Priority tier (Critical before High before Medium)
3. Complexity (simpler issues first when priority is equal)

## Step 6: Suggest assignments (when Team section exists)

If `.claude/pm-config.md` has a non-empty `## Team` section:

### 6a: Gather contributor history

For each team member listed:

```bash
gh pr list --author $USERNAME --state merged --limit 20 --json number,title,mergedAt,files
```

Record which parts of the codebase each contributor has recently worked on (file paths, directories, components).

### 6b: Match issues to contributors

For each issue in the sprint:
- Compare issue file references and labels against each contributor's recent merge history
- Suggest the contributor whose recent work best overlaps with the issue's scope
- If an issue is already assigned, keep the existing assignee unless there's a clear mismatch

### 6c: Capacity check

If team config includes capacity hints (e.g., "part-time", "available 3 days/week"), estimate load per person:
- Count issues assigned to each contributor
- Weight by complexity signals (acceptance criteria count, estimated scope)
- Warn if any contributor is overloaded relative to the sprint length

If no capacity data exists, skip the capacity check and note: "No capacity data — verify load distribution manually."

## Step 7: Output the sprint plan

### Header

```
# Sprint Plan — {DAYS}-day sprint
Repo: {repo name}
Period: {start date} – {end date}
Issues planned: {count} across {track count} parallel tracks
Dependencies detected: {explicit count} explicit, {implicit count} implicit
```

If `OKR_MODE=true`, append: `OKR alignment active — {X} objectives with {Y} key results used for prioritization.`

If Team section was used, append: `Team assignments suggested based on contributor history.`

### Track sections

For each track:

```
## Track {N}: {Theme}

Priority | Issue | Title | Assignee | Dependencies
---------|-------|-------|----------|-------------
Critical | #42   | ...   | @alice   | Unblocks: #50, #53
High     | #50   | ...   | @alice   | Blocked by: #42
Medium   | #55   | ...   | @bob     | —

**Track rationale:** {1-line explanation of why these issues are grouped together}
```

If no Team section exists, omit the Assignee column.

### Unplanned issues

If some open issues were excluded from the sprint (Low priority, blocked by external factors, etc.):

```
## Deferred ({count} issues)

These issues are deprioritized for this sprint:
- **#70 — {title}** — Low priority relative to current goals
- **#72 — {title}** — Blocked by external dependency (waiting on API access)
```

If many issues are deferred, summarize: "{N} additional Low-priority issues deferred — run `/prioritize` for full ranking."

### Warnings

Include a warnings section if any of these conditions apply:
- Circular dependencies detected
- Overloaded contributors (capacity check failed)
- Issues with no clear ownership
- Sprint appears overcommitted (more work than the period allows)

### Config status

At the bottom, note which optional features were active:

```
---
**Config status:** OKRs ✓ | Team assignments ✓ | Capacity check ✗ (no capacity data)
```

## Writing rules

- **Every issue in the plan must have a clear rationale** connecting it to the sprint's priorities. Do not include issues without justification.
- **Keep track sections scannable.** Use tables for issue lists, prose for track rationale. Total output should be readable in under 3 minutes.
- **Do not list every open issue.** If 80 of 100 issues are Low/deferred, summarize them — do not enumerate all 80.
- **Dependency annotations are inline.** Show `Blocked by: #N` and `Unblocks: #N` in the table, not in a separate section.
- **Handle single-contributor repos gracefully.** If only one contributor exists, skip assignment suggestions and capacity checks. Use "Sprint Plan" framing without team-specific language.
- **Handle empty backlogs.** If no open issues exist, output a clear message and stop — do not generate an empty plan.
- **Do not mention the scoring methodology.** The output should read as a confident plan, not a process explanation.
