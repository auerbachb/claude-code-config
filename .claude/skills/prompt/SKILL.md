---
name: prompt
description: Analyze GitHub issues to assess complexity, classify effort tier, recommend model selection, and generate tailored prompts with pre-extracted context. Use when starting work, planning sprints, estimating effort, right-sizing model choice, or analyzing issue batches.
argument-hint: "#123 [#124 #125 ...] (one or more issue numbers)"
---

Analyze one or more GitHub issues, classify complexity, and produce a copy-paste-ready prompt with a model/effort recommendation. The goal is quality-conservative right-sizing — never under-resource a task, but don't waste Opus 4.6 1M tokens on a typo fix.

Parse `$ARGUMENTS` as space-separated issue references. Strip `#` prefixes to get bare issue numbers. If no arguments provided, ask the user which issue(s) to analyze.

## Step 1: Gather Issue Data

For each issue number, fetch the full issue data:

```bash
gh issue view $NUMBER --json number,title,body,labels,milestone,assignees,createdAt
```

For each issue, extract and record:
- **Full body content** — needed for complexity analysis (titles alone are insufficient)
- **Labels** — check for protocol-relevant labels (e.g., "orchestration", "multi-phase", "infrastructure")
- **Milestone** — priority and deadline context
- **Acceptance criteria** — count checkbox items (`- [ ]`) in the body

## Step 2: Detect CR Implementation Plan

For each issue, check if CodeRabbit posted an implementation plan:

```bash
gh api repos/{owner}/{repo}/issues/$NUMBER/comments --jq '.[] | select(.user.login == "coderabbitai[bot]") | .body'
```

- Look for plan structure markers: file lists, implementation steps, phase breakdowns
- If a CR plan exists, extract the **file list** using these patterns:
  - Look for headings containing "Files", "Files likely touched", "File list", or "Touched files" (case-insensitive)
  - Parse the block following that heading: bullet/numbered lists (`-`, `*`, `+`, or digits + `.`) or fenced code blocks with one path per line
  - Also capture inline backticked paths (e.g., `` `src/foo.ts` ``)
  - Normalize: trim whitespace, strip leading `./`, deduplicate, skip lines that don't look like file paths (no `/` and no file extension)
- The extracted file list becomes the primary "files likely touched" signal
- Store the CR plan content verbatim for inclusion in the output prompt
- If no CR plan exists, note it — the output will recommend waiting or proceeding with exploration

## Step 3: Detect Dependencies

Scan all issue bodies (from Step 1) for dependency markers:
- `blocked by #N`, `depends on #N`, `prerequisite for #N`, `after #N`
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
| `dependency_count` | Total dependency references found in Step 3. |
| `touches_rules` | `true` if any file path matches `.claude/rules/*.md` OR issue body mentions "rule file", "workflow protocol", "CLAUDE.md". |
| `touches_skill` | `true` if any file path matches `.claude/skills/` OR issue is about creating/modifying a skill. |
| `ac_count` | Count of acceptance criteria checkboxes (`- [ ]`) in issue body. |
| `is_multi_issue` | `true` if more than one issue number was provided. |
| `has_orchestration_keywords` | `true` if issue body contains: "subagent", "Phase A", "Phase B", "Phase C", "multi-phase", "orchestration", "monitor mode", "handoff". |
| `scope_keywords` | Collect any of: "typo", "rename", "comment", "config", "doc update", "README", "formatting". |

## Step 5: Classify Tier

Apply this decision tree. When signals conflict, choose the **higher** tier (conservative on quality).

**Batch handling rule:** When multiple issues are provided, the tier is determined by the most complex issue in the batch. A batch of 3 issues where one is Heavy makes the whole batch Heavy.

### Heavy — Opus 4.6 1M / High effort

Assign Heavy if ANY of these are true:
- `touches_rules` is true (rule files are highest-stakes)
- `has_orchestration_keywords` is true
- `is_multi_issue` AND at least one issue has `file_count > 1` or `ac_count > 3` (multiple non-trivial issues)
- `file_count > 5`
- `dependency_count > 2`

### Standard — Opus 4.6 / Medium effort

Assign Standard if ANY of these are true (and Heavy was not triggered):
- `file_count` is 2–5
- `ac_count > 3`
- `touches_skill` is true
- Issue body is >200 words with structural patterns (includes a user story, describes a new feature via keywords like "implement", "add", "support")
- `is_multi_issue` with mixed complexity (at least one non-trivial issue that didn't trigger Heavy)

### Quick — Haiku 4.5 / Low effort

Assign Quick only if ALL of these are true (evaluated before Light to prevent Light's broader conditions from preempting):
- `scope_keywords` are exclusively from: "typo", "rename", "comment", "formatting"
- `file_count` is 0–1
- `ac_count` ≤ 2
- `dependency_count` is 0
- No orchestration, rule, or skill signals

### Light — Sonnet 4.6 / Medium effort

Assign Light if ANY of these are true (and Heavy/Standard/Quick were not triggered):
- `file_count` is 0–1
- `scope_keywords` include "config", "doc update", "README"
- Issue describes a straightforward single-file addition or modification

### Fallback

If classification is unclear, default to **Standard**. It is better to slightly over-resource than to under-resource and get instruction adherence slippage.

## Step 6: Generate Output

Produce the following output in Markdown. Use the gathered data to fill in each section. The output should be **copy-paste-ready** — a user can paste this directly into a new Claude Code thread.

### Output Template

```
## Tier Recommendation

**{TIER_NAME}** — {MODEL} / {EFFORT} effort

Rationale: {1-line explanation of why this tier was selected, citing the dominant signal}

---

## Issue Summary

{For each issue, include:}

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
{- For Heavy + orchestration: "Read `.claude/rules/subagent-orchestration.md` — specifically the Phase A/B/C protocol, handoff file schema, and monitor mode rules."}
{- For any tier involving PRs: "Read `.claude/rules/cr-github-review.md` — specifically the merge gate (2 clean CR passes), polling endpoints, and thread resolution."}
{- For any tier involving CR local review: "Read `.claude/rules/cr-local-review.md` — specifically the fix loop and exit criteria (2 clean passes)."}
{- For issue creation: "Read `.claude/rules/issue-planning.md` — specifically the planning flow and plan merge step."}
{- For Light/Quick tiers with no protocol involvement: "No special protocol rules needed — standard coding workflow."}

---

## CR Implementation Plan

{If CR plan was detected in Step 2, include it verbatim here.}
{If no CR plan: "No CodeRabbit implementation plan available. The agent should explore the codebase before coding. Consider waiting for CR to post a plan if the issue was recently created (< 10 minutes ago)."}

---

{ONLY for Heavy tier — include this section:}
## Protocol Checkpoints

These are mandatory verification points. The executing agent MUST follow these:

{Include relevant checkpoints based on the task type:}

**If the task involves pushing code and creating a PR:**
- [ ] After coding: Run `coderabbit review --prompt-only` — two clean passes required before pushing
- [ ] After pushing: Enter GitHub review polling loop immediately — do NOT ask permission
- [ ] After CR/Greptile posts findings: Fix all valid findings in ONE commit, push once, reply to every thread

**If the task involves subagent orchestration:**
- [ ] After Phase A completes: Launch Phase B within 60 seconds — this is the highest priority action
- [ ] Write handoff file to `~/.claude/handoffs/pr-{N}-handoff.json` before exiting Phase A
- [ ] Enter monitor mode when subagents are active — do NOT do substantive work yourself

**If the task involves merging:**
- [ ] Verify ALL AC checkboxes are checked against final code
- [ ] Confirm merge gate: 2 clean CR passes (CR path) or severity-gated Greptile pass
- [ ] Check ALL CI check-runs pass before merging — never merge with failing CI

---

## Exit Criteria

This task is done when:
{For each acceptance criterion, list it as a verification item:}
- [ ] {AC item 1 from issue body}
- [ ] {AC item 2 from issue body}
{...}
- [ ] PR merged and branch deleted (if applicable)
```

## Edge Cases

- **Issue doesn't exist or is closed:** Note it in the output and skip it. If all issues are invalid, report the error and stop.
- **CR plan not yet available:** Include a note recommending the user wait if the issue is < 10 minutes old, or proceed without if older.
- **No acceptance criteria in issue body:** Flag this in the output: "No acceptance criteria found — consider adding them before starting work."
- **Multiple issues with mixed complexity:** See the batch handling rule in Step 5 — the most complex issue determines the batch tier.

## Usage Examples

**Single issue:**
```
/prompt #115
```

**Multiple issues (batch):**
```
/prompt #110 #111 #112
```

**Note:** This skill produces a recommendation. The user decides whether to follow the tier suggestion. When in doubt, the skill errs toward the higher tier — it's better to slightly over-resource than to get instruction adherence failures on a complex task.
