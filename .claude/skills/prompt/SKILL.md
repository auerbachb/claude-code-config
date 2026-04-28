---
name: prompt
description: Analyze GitHub issues to assess complexity, recommend a model tier, and generate tailored prompts with pre-extracted context. Use when starting work, planning sprints, right-sizing model choice, or analyzing issue batches. When called with no args in a PM thread, auto-detects suggested issues and partitions subagent candidates from thread prompts.
triggers:
  - analyze issue
  - generate prompt
  - complexity check
argument-hint: "[#123 #124 ...] (issue numbers, or omit for PM auto-detect)"
---

Analyze one or more GitHub issues, classify complexity, and produce a copy-paste-ready prompt with a model recommendation. The goal is quality-conservative right-sizing — never under-resource a task, but don't waste Opus 4.7 1M tokens on a typo fix.

## Step 0: Parse Arguments and Detect Context

Parse `$ARGUMENTS` as space-separated issue references. Strip `#` prefixes to get bare issue numbers.

**Three paths based on input:**

### Path A: Explicit arguments provided

If `$ARGUMENTS` is non-empty, use the specified issue numbers. Proceed to Step 1. No filtering or partitioning — all issues get full prompt blocks (behavior unchanged from prior versions).

### Path B: No arguments + PM thread context detected

If `$ARGUMENTS` is empty, check for PM orchestration context. PM context is detected if EITHER condition is true (OR gate — PM output patterns alone are sufficient even without `pm-config.md`):

1. **Check for `pm-config.md`:**
   ```bash
   test -f .claude/pm-config.md && echo "PM_CONFIG_EXISTS" || echo "NO_PM_CONFIG"
   ```

2. **Scan conversation messages since the most recent `/pm` invocation for PM output patterns.** The scan window starts at the last message containing `/pm` (or its output markers) and extends to the current message. Look for ANY of these markers within that window:
   - A heading matching `## Suggested Next Issues`
   - A ranked list with issue references in the format `**#N — {Title}**`
   - An `## Active Work` table with issue numbers

3. **If PM context is detected** (either `pm-config.md` exists OR PM output patterns were found), extract issue numbers using include/exclude logic:

   **Include** (OR — issue qualifies if it matches any of these):
   - Referenced in the `## Suggested Next Issues` section
   - Listed in the `## Active Work` table with status "Awaiting thread start"

   **Then exclude** (AND NOT — remove any issue that matches any of these):
   - Marked as "Active", "In review", "Merged", or "Prompt generated" in the `## Active Work` table

   Example: If `## Suggested Next Issues` lists #42, #55, #61 and the Active Work table shows #42 as "In review", the result is #55 and #61.

   Use these extracted issue numbers as the input set. Set `PM_AUTO_DETECT=true` (this flag controls the subagent partition output in Step 6). Proceed to Step 1.

### Path C: No arguments + no PM context

If `$ARGUMENTS` is empty and no PM context is detected (no `pm-config.md` **and** no PM output patterns in conversation — both must be absent), ask the user which issue(s) to analyze. Stop and wait for input.

## Step 1: Gather Issue Data

For each issue number, fetch the full issue data:

```bash
gh issue view $NUMBER --json number,title,body,labels,milestone,assignees,createdAt,state,closedAt
```

For each issue, extract and record:
- **Full body content** — needed for complexity analysis (titles alone are insufficient)
- **Labels** — check for protocol-relevant labels (e.g., "orchestration", "multi-phase", "infrastructure")
- **Milestone** — priority and deadline context
- **Acceptance criteria** — count all checklist items matching `- [ ]` or `- [x]`/`- [X]` in the body (both checked and unchecked count toward `ac_count`)

## Step 2: Detect CR Implementation Plan

For each issue, fetch all comments (not just CR — discussion comments contain dependency and scope signals too):

```bash
gh api --paginate repos/{owner}/{repo}/issues/$NUMBER/comments --jq '.[] | {author: .user.login, body: .body}'
```

From all comments, extract:
- **Implementation plan:** Scan ALL comments (not just `coderabbitai[bot]`) for plan structure markers — file lists, implementation steps, phase breakdowns. CR plans are the most common source, but human-written plans in comments are equally valid. Prefer the most structured/detailed plan found regardless of author.
- **Discussion signals:** Scan all comments for dependency markers, scope clarifications, and complexity context (these feed into Step 3)
- If a CR plan exists, extract the **file list** using these patterns:
  - Look for headings containing "Files", "Files likely touched", "File list", or "Touched files" (case-insensitive)
  - Parse the block following that heading: bullet/numbered lists (`-`, `*`, `+`, or digits + `.`) or fenced code blocks with one path per line
  - Also capture inline backticked paths (e.g., `` `src/foo.ts` ``)
  - Normalize: trim whitespace, strip leading `./`, deduplicate, skip lines that don't look like file paths (no `/` and no file extension)
- The extracted file list becomes the primary "files likely touched" signal
- Store the CR plan content verbatim for inclusion in the output prompt
- If no CR plan exists, note it — the output will recommend waiting or proceeding with exploration

## Step 3: Detect Dependencies

Scan all issue bodies (from Step 1) AND all issue comments (from Step 2) for dependency markers:
- `blocked by #N`, `blocks #N`, `depends on #N`, `prerequisite for #N`, `after #N`
- `unblocks #N`, `enables #N`, `required by #N`, `before #N`
- `Fixes #N`, `Closes #N` (indicates a PR may already be in flight)

Record:
- Total dependency count across all issues
- Whether issues in the batch depend on each other (implies ordering)
- Whether any issue blocks others (root issues get priority)

## Step 4: Extract Complexity Signals

From the gathered data, compute these discrete signals:

| Signal | How to compute |
|--------|---------------|
| `file_count` | Per-issue count of files from CR plan file list (see Step 2 parsing). If no CR plan, count strings in the issue body that contain `/`, end with a file extension (`.ts`, `.md`, `.json`, `.py`, `.sh`, `.yml`, `.yaml`), and do NOT start with `http://` or `https://`. Default: 0 if no CR plan and no file paths detected. For batch tier decisions, use the highest per-issue `file_count`. |
| `dependency_count` | Total dependency references found in Step 3. Also record a **per-issue breakdown** (`dependency_count_per_issue`) for use in Step 5.5 subagent eligibility gating. |
| `touches_rules` | `true` if any file path matches `.claude/rules/*.md` OR issue body mentions "rule file", "workflow protocol". |
| `touches_claude_md` | `true` if any file path matches `CLAUDE.md` (case-insensitive) OR issue body mentions "CLAUDE.md". |
| `touches_skill` | `true` if any file path matches `.claude/skills/` OR issue is about creating/modifying a skill. |
| `ac_count` | Count of acceptance criteria checkboxes (both `- [ ]` and `- [x]`/`- [X]`) in issue body. |
| `is_multi_issue` | `true` if more than one issue number was provided. |
| `has_orchestration_keywords` | `true` if issue body contains: "subagent", "Phase A", "Phase B", "Phase C", "multi-phase", "orchestration", "monitor mode", "handoff". |
| `scope_keywords` | Collect any of: "typo", "rename", "comment", "config", "doc update", "README", "formatting". |

## Step 5: Classify Tier

Apply this decision tree. When signals conflict, choose the **higher** tier (conservative on quality).

**Batch handling rule:** First classify each issue independently to produce a per-issue tier (`issue_tier`). Then compute a batch tier from the most complex `issue_tier` in the set. A batch of 3 issues where one is Heavy makes the batch tier Heavy. The batch tier is used for thread-prompt output formatting and checkpoint inheritance, while per-issue decisions (like Step 5.5 subagent partitioning) must use `issue_tier`.

### Heavy — Opus 4.7 1M

Assign Heavy if ANY of these are true:
- `touches_rules` is true (rule files are highest-stakes)
- `touches_claude_md` is true (CLAUDE.md is the root config — highest-stakes)
- `has_orchestration_keywords` is true
- `is_multi_issue` AND at least one issue has `file_count > 1` or `ac_count > 3` (multiple non-trivial issues)
- `file_count > 5`
- `dependency_count > 2`

### Standard — Opus 4.7

Assign Standard if ANY of these are true (and Heavy was not triggered):
- `file_count` is 2–5
- `ac_count > 3`
- `touches_skill` is true
- Issue body is >200 words with structural patterns (includes a user story, describes a new feature via keywords like "implement", "add", "support")
- `is_multi_issue` with mixed complexity (at least one non-trivial issue that didn't trigger Heavy)

### Light — Sonnet 4.6

Assign Light if ANY of these are true (and Heavy/Standard were not triggered):
- `file_count` is 0–1
- `scope_keywords` include "typo", "rename", "comment", "formatting", "config", "doc update", "README"
- Issue describes a straightforward single-file addition or modification

### Fallback

If classification is unclear, default to **Standard**. It is better to slightly over-resource than to under-resource and get instruction adherence slippage.

## Step 5.5: Partition Subagent Candidates (PM auto-detect only)

**Skip this step entirely if `PM_AUTO_DETECT` is not `true`** (i.e., when explicit arguments were provided via Path A, or if Path C was taken). When skipped, all issues proceed to Step 6 as thread-prompt issues.

When `PM_AUTO_DETECT=true`, partition the classified issues into two groups using the subagent candidate criteria. Eligibility must be evaluated **per issue**. An issue is **subagent-eligible** if ALL of the following are true:

| Signal | Subagent-eligible threshold |
|--------|---------------------------|
| `file_count` | 0–1 |
| `ac_count` | ≤ 3 |
| `dependency_count_per_issue` | 0 (count only dependencies referencing or referenced by this specific issue, not the batch total) |
| `touches_rules` | `false` |
| `touches_claude_md` | `false` |
| `has_orchestration_keywords` | `false` |
| `issue_tier` | Light |

Use per-issue signal values from Steps 4–5, including `issue_tier` (the per-issue tier from the classification decision tree — not the batch tier). Do not use batch-aggregated values for per-issue gating. Apply the table as a gate: if ANY signal exceeds its threshold, the issue is **not** subagent-eligible.

**Result of partitioning:**
- **Subagent-eligible issues** — reported in a separate section with a `/subagent` command suggestion (see Step 6)
- **Thread-prompt issues** — everything else. These get full prompt blocks as normal.

If all issues are subagent-eligible, the thread-prompt group is empty — only the Subagent Candidates section is output. If no issues are subagent-eligible, the Subagent Candidates section is omitted entirely.

**Batch tier recomputation:** When `PM_AUTO_DETECT=true` and partitioning produces a non-empty subagent-eligible group, the batch tier from Step 5 may be incorrect (it was computed over all issues including the now-partitioned subagent candidates). Recompute the batch tier using only the thread-prompt issues. This includes recomputing all derived signals for that subset (e.g., `is_multi_issue`, dependency totals, and other batch-level aggregates) before reapplying the Step 5 decision tree. If all issues were subagent-eligible (empty thread-prompt group), skip tier computation entirely.

## Step 6: Generate Output

Produce the following output in Markdown. Use the gathered data to fill in each section. The output should be **copy-paste-ready** — a user can paste each issue's prompt directly into a new Claude Code thread as a single copyable block.

### Output Structure

The output has up to three parts:

1. **Subagent Candidates section** (only when `PM_AUTO_DETECT=true` and subagent-eligible issues exist) — shown first, before prompt blocks
2. **Tier Recommendation** — plain text (not inside a code fence), shown once. Applies only to the thread-prompt issues (not the subagent candidates).
3. **Per-issue prompt blocks** — one tilde-fenced block (`~~~`) per thread-prompt issue, each self-contained with all context needed by the executing agent

When `PM_AUTO_DETECT=true` and Step 5.5 produced a non-empty subagent-eligible group, output the Subagent Candidates section first (see template below). Then output the Tier Recommendation and prompt blocks for the remaining thread-prompt issues only.

If all issues are subagent-eligible, skip the Tier Recommendation and prompt blocks entirely — only output the Subagent Candidates section. If no issues are subagent-eligible (or `PM_AUTO_DETECT` is not `true`), skip the Subagent Candidates section entirely.

For single-issue input, there is one prompt block. For batch input, there are multiple prompt blocks, each independently copyable (i.e., self-contained with all context; this does not imply each block has its own tier). All blocks in a batch share the batch-level tier, so an individually Light issue's block may include Heavy-tier checkpoints when the batch tier is Heavy. **Batch tier is computed from thread-prompt issues only** — subagent candidates do not influence the batch tier.

**Fence nesting rule:** Outer prompt blocks open and close with tilde fences (`~~~`). Inner code examples (bash commands, SQL, file paths, etc.) use the standard three backtick characters. Per CommonMark, a fenced block can only be closed by a fence using the **same character** as the opening fence — so a `~~~`-delimited outer block safely contains any number of ```` ``` ````-delimited inner blocks without collision. This is more robust than nested backtick fences (e.g., 4-backtick outer + 3-backtick inner) because some renderers (including recent versions of the Claude Mac app) close the outer fence at the first inner triple-backtick in violation of CommonMark's requirement that fences close only with matching fence characters of equal or greater length. Tilde outer fences sidestep that renderer bug entirely.

### Subagent Candidates Template (PM auto-detect only)

When `PM_AUTO_DETECT=true` and subagent-eligible issues exist, output this section first:

```
## Subagent Candidates (skip thread — run inline)

These issues are small enough to run as subagents directly in this PM thread:
- #{N} — {Title} ({Tier} tier, {file_count} file(s))
- #{M} — {Title} ({Tier} tier, {file_count} file(s))

Run: `/subagent #{N} #{M}`
```

If there are also thread-prompt issues, follow with the Tier Recommendation and prompt blocks below. If all issues are subagent-eligible, this section is the entire output — add a note: "All detected issues qualify for subagent execution. No thread prompts needed."

### Output Template

Output the Tier Recommendation as plain text first (skip if all issues are subagent-eligible):

```
## Tier Recommendation

**{TIER_NAME}** — {MODEL}

Rationale: {1-line explanation of why this tier was selected, citing the dominant signal}
```

Then, for each issue, output a self-contained prompt block. Use tilde fences (`~~~`, shown here as the outer boundary):

~~~
### Issue #{NUMBER}: {TITLE}

**Acceptance Criteria:**
{List all checkbox items from the issue body, preserving the original text}

**Dependencies:**
{List any dependency relationships, or "None detected"}

**Labels:** {comma-separated labels, or "None"}

---

## Pre-extracted Context

### Files to read/modify
{List files from CR plan, or "No CR plan available — agent should explore the codebase to identify affected files."}

### Relevant rules
{Based on tier and task type, list which rule files contain relevant protocols:}
{- For Heavy + orchestration: "Read `.claude/rules/subagent-orchestration.md` (phase decomposition, spawning), `monitor-mode.md` (monitor loop, heartbeats, recovery), `handoff-files.md` (state transfer schema), and `phase-protocols.md` (exit reports, completion checklists)."}
{- For any tier involving PRs: "Read `.claude/rules/cr-github-review.md` for polling endpoints and thread resolution, and `.claude/rules/cr-merge-gate.md` for the authoritative merge gate (1 explicit CR APPROVED review on current HEAD SHA, with SHA freshness + explicit-approval-only)."}
{- For any tier involving CR local review: "Read `.claude/rules/cr-local-review.md` — specifically the fix loop and exit criteria (1 clean pass)."}
{- For issue creation: "Read `.claude/rules/issue-planning.md` — specifically the planning flow and plan merge step."}
{- For Light tier with no protocol involvement: "No special protocol rules needed — standard coding workflow."}

---

## CR Implementation Plan

{If CR plan was detected in Step 2, include it verbatim here.}
{If no CR plan: "No CodeRabbit implementation plan available. The agent should explore the codebase before coding. Consider waiting for CR to post a plan if the issue was recently created (< 10 minutes ago)."}

---

{ONLY when the assigned tier is Heavy (for batches, this is the batch-level tier from Step 5) — include this section in every issue block:}
## Protocol Checkpoints

These are mandatory verification points. The executing agent MUST follow these:

{Include relevant checkpoints based on the task type:}

**If the task involves pushing code and creating a PR:**
- [ ] After coding: Run `coderabbit review --prompt-only` — one clean pass required before pushing
- [ ] After pushing: Enter GitHub review polling loop immediately — do NOT ask permission
- [ ] After CR/Greptile posts findings: Fix all valid findings in ONE commit, push once, reply to every thread

**If the task involves subagent orchestration:**
- [ ] After Phase A completes: Launch Phase B within 60 seconds — this is the highest priority action
- [ ] Write handoff file to `~/.claude/handoffs/pr-{N}-handoff.json` before exiting Phase A
- [ ] Enter monitor mode when subagents are active — do NOT do substantive work yourself

**If the task involves merging:**
- [ ] Verify ALL AC checkboxes are checked against final code
- [ ] Confirm merge gate: 1 explicit CR APPROVED review on current HEAD (CR path), or 1 clean BugBot pass on current HEAD, or severity-gated Greptile pass
- [ ] Check ALL CI check-runs pass before merging — never merge with failing CI

---

## Exit Criteria

This task is done when:
{For each acceptance criterion from THIS issue, list it as a verification item:}
- [ ] {AC item 1 from issue body}
- [ ] {AC item 2 from issue body}
{...}
- [ ] PR merged and branch deleted (if applicable)
~~~

{Repeat the above tilde-fenced block for each issue in the batch. Each block is independently copyable.}

## Edge Cases

- **Issue doesn't exist or is closed:** Note it in the output and skip it. If all issues are invalid, report the error and stop.
- **CR plan not yet available:** Include a note recommending the user wait if the issue is < 10 minutes old, or proceed without if older.
- **No acceptance criteria in issue body:** Flag this in the output: "No acceptance criteria found — consider adding them before starting work."
- **Multiple issues with mixed complexity:** See the batch handling rule in Step 5 — the most complex issue determines the batch tier.
- **PM auto-detect finds no issues:** If PM context is detected but no extractable issue numbers are found (e.g., the "Suggested Next Issues" section has no valid issue references), tell the user: "PM context detected but no unstarted issues found in the latest suggestions. Provide issue numbers explicitly: `/prompt #N #M`"
- **All PM-detected issues are subagent-eligible:** Output only the Subagent Candidates section. No tier recommendation or prompt blocks needed.
- **All PM-detected issues are thread-prompt-eligible:** Output normally — skip the Subagent Candidates section entirely. This is the same as the explicit-args path.
- **`/subagent` skill not yet available:** The Subagent Candidates section outputs a `/subagent` command suggestion regardless of whether the skill exists. If the user runs it and the skill is missing, they will get a clear error. The `/prompt` skill does not gate on `/subagent` availability.

## Usage Examples

**Single issue:**
```
/prompt #115
```

**Multiple issues (batch):**
```
/prompt #110 #111 #112
```

**No arguments in a PM thread (auto-detect):**
```
/prompt
```
When called with no args in a PM thread, auto-detects recently suggested issues, classifies each, and partitions into subagent candidates (with `/subagent` command suggestion) and thread prompts.

**No arguments outside PM context:**
```
/prompt
```
Falls back to asking: "Which issue(s) should I analyze?"

### Sample output

For an issue with `touches_skill=true` and `ac_count=4`, the skill emits the Tier Recommendation as plain text first, then a self-contained prompt block in a tilde fence. The recommendation rendered to the chat looks like:

> **Standard** — Opus 4.7
>
> Rationale: touches_skill=true (modifies a file under .claude/skills/) drives Standard.

The prompt block that follows:

~~~
### Issue #110: {Title}

**Acceptance Criteria:**
{checklist items from the issue body}

**Dependencies:** {relationships, or "None detected"}

**Labels:** {comma-separated, or "None"}

---

## Pre-extracted Context

### Files to read/modify
{files from CR plan, or exploration note}

### Relevant rules
{rule files relevant to the tier}

---

## CR Implementation Plan
{CR plan verbatim, or "No CodeRabbit implementation plan available."}
~~~

**Note:** This skill produces a recommendation. The user decides whether to follow the tier suggestion. When in doubt, the skill errs toward the higher tier — it's better to slightly over-resource than to get instruction adherence failures on a complex task.
