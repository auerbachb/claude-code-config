---
name: prompt
description: Analyze GitHub issues to assess complexity, recommend a model tier, and generate tailored prompts with pre-extracted context. Use when starting work, planning sprints, right-sizing model choice, or analyzing issue batches. When called with no args in a PM thread, auto-detects suggested issues, partitioning inline subagent runs (the default) from the few too-big issues that need a separate thread.
triggers:
  - analyze issue
  - generate prompt
  - complexity check
argument-hint: "[#123 #124 ...] (issue numbers, or omit for PM auto-detect)"
---

Analyze one or more GitHub issues, classify complexity, and produce a copy-paste-ready prompt with a model recommendation. The goal is quality-conservative right-sizing — never under-resource a task, but don't waste Opus 5 tokens on a typo fix.

## Model Lineup & Effort Levels (current as of 2026-07-28)

The current fleet is **Fable 5, Opus 5, Sonnet 5, Haiku 4.5** — the same four models named in `CLAUDE.md`, `.claude/rules/subagent-orchestration.md` "Model Selection", and `.claude/agents/README.md`. In the Claude Code picker, **Opus 5** is the default. Every **Opus 4.x** and **Sonnet 4.x** release — including the immediately-previous Opus default — is Legacy; never recommend one. (Named by generation rather than version so the list doesn't go stale at the next fleet bump.) Opus 5 and Sonnet 5 ship with a native 1M context window; there is no separate "(1M context)" picker option, so an entry like "Opus 5 (1M context)" is not a distinct model. Bare aliases used elsewhere (agent frontmatter, spawn sites) resolve as (verified 2026-07-28): `opus` → Opus 5, `sonnet` → Sonnet 5, `haiku` → Haiku 4.5; Fable 5 has no bare alias and must be named explicitly (`claude-fable-5`). Model IDs, where named explicitly: `claude-fable-5`, `claude-opus-5`, `claude-sonnet-5`, `claude-haiku-4-5-20251001`.

The picker also exposes **effort levels** (`low`, `medium`, `high`, `xhigh`, `max`, plus session-only `ultracode`). This skill keeps its internal Heavy/Standard/Light tier vocabulary and decision tree unchanged, and maps each tier to a recommended effort level in the output: **Heavy → `xhigh`**, **Standard → `high`**, **Light → `low`**. Users may adjust within a tier's range — e.g., a Heavy task with correctness-critical work can step up to `max`; a Heavy task that needs multi-agent orchestration can step up to `ultracode`; a borderline Standard task can step up to `xhigh` or step down to `medium`. Model choice has its own step-up: the hardest long-horizon / orchestration work can move from Opus 5 up to **Fable 5** (see Heavy, below).

**Fast mode:** the picker has a Fast mode toggle (also `/fast`) that gives Claude Opus faster output — it speeds output without downgrading to a smaller model. It is offered on **Opus 5** (and on the legacy Opus 4.x models that still carry it); it is not offered for Sonnet 5, Haiku 4.5, or Fable 5, so it never pairs with a Light-tier recommendation. `/prompt` does NOT accept a `--fast` flag and does not factor Fast mode into recommendations — it is a user-toggled picker option. A `--fast` flag is a possible follow-up, not part of this skill.

Separately from Fast mode: for Light-tier work, **Haiku 4.5** is a valid cheaper alternative to Sonnet 5; the output notes this on Light-tier recommendations.

**MANDATORY OUTPUT FORMAT:** Every per-issue prompt block printed to the transcript MUST open and close with `~~~` tilde fences. NEVER use backtick fences as the outer prompt-block delimiter. This governs fallback mode and print-on-demand replay — the two paths that print a block. In chip mode the prompt rides inside the chip rather than being printed, so it needs no fence; its content is otherwise identical.

**Per-block model label (mandatory):** The first content inside each tilde-fenced block (immediately after the opening `~~~`) MUST be a single line: `**Model:** {MODEL} — {REASON}` where `{MODEL}` is the model string for **that issue's** `issue_tier` (from Step 5 — not the batch tier), and `{REASON}` is a concise task-type phrase of **at most 10 words** derived from that issue's signals (dominant drivers such as rules/CLAUDE.md, orchestration, file count, AC count, skills, dependencies, or scope keywords). The label must be **inside** the tilde fence so a pasted block is self-explanatory without surrounding prose. In chip mode the same line MUST open the chip's `prompt` text **and** appear in the visible short summary — chips cannot preset the model picker, so the user needs it before clicking and the spawned session needs it after.

**Model-guard preamble (mandatory):** Immediately after the `**Model:**` line — no blank line between — insert the model-guard preamble defined in `.claude/reference/chip-launching.md` "Model-guard preamble," verbatim, never reworded. It applies in both delivery modes: the launched thread's first action is to compare its actual running model against the `**Model:**` line and stop on any mismatch. See `chip-model-guard-decision.md` for why the guard rides in both the chip `prompt` and the fallback block. In chip mode the `**Model:**` line MUST also appear in the visible short summary; when the parent thread is on Fable 5 and the chip recommends a different model, add the pre-click warning from `chip-launching.md` "Upstream requirement."

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
   - Marked as "Inline", "Active", "In review", "Merged", "Prompt generated", or "Chip offered" in the `## Active Work` table

   "Chip offered" means `/pm` already offered that issue as a click-to-launch chip — it is offered-but-unstarted, exactly like "Prompt generated", so excluding it prevents double-offering the same issue. "Inline" means `/pm` is already running the issue as a subagent, so it is excluded for the same reason.

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

### Heavy — Opus 5, effort `xhigh` (step up to Fable 5 for the hardest long-horizon work)

Assign Heavy if ANY of these are true:
- `touches_rules` is true (rule files are highest-stakes)
- `touches_claude_md` is true (CLAUDE.md is the root config — highest-stakes)
- `has_orchestration_keywords` is true
- `is_multi_issue` AND at least one issue has `file_count > 1` or `ac_count > 3` (multiple non-trivial issues)
- `file_count > 5`
- `dependency_count > 2`

**Fable 5 step-up (within Heavy).** Opus 5 is the Heavy default. Recommend stepping up to **Fable 5** — the strongest model in the fleet, at roughly 2× Opus 5's cost — only for the hardest long-horizon work at the top of the Heavy band. Step up when Heavy was triggered AND at least two of: `has_orchestration_keywords`, `touches_rules` or `touches_claude_md`, `file_count > 5`, `dependency_count > 2`. A Heavy issue that trips exactly one trigger (the common case — e.g. a rules-only wording change) stays on Opus 5. Phrase it as a step-up, never a replacement: the recommendation line stays `Opus 5`, with the Fable 5 option noted alongside it.

**`max` effort step-up (within Heavy).** `xhigh` is the Heavy effort default — the documented sweet spot for demanding coding work, which every Heavy issue qualifies as. Step up to `max` (correctness-over-cost) only when the penalty for a wrong answer is high: security-adjacent edits (auth, secrets handling, permissions), merge-gate or state-machine logic where an error propagates silently, or when prior review rounds surfaced significant correctness failures (e.g., Greptile P0 findings or repeated CR rounds on the same issue). Issues that also meet the Fable 5 model step-up threshold (at least two of `has_orchestration_keywords`, `touches_rules`/`touches_claude_md`, `file_count > 5`, `dependency_count > 2`) are strong `max` candidates if they also carry a correctness signal. Single-trigger Heavy issues — the common case (e.g., a rules-only wording change) — stay on `xhigh`. Phrase it as a step-up: the recommendation line stays `xhigh`, with `max` noted as an option when warranted.

> **Effort rationale (Issue #558):** Heavy previously defaulted to `max`, skipping `xhigh` entirely. This over-spent on the most common Heavy cases (a single `touches_rules` trigger) that already run on Opus 5. `xhigh` is the documented sweet spot for demanding coding work; `max` is correctness-over-cost for cases where errors propagate at high cost. The new default mirrors the Fable-5 model step-up pattern from PR #554: default to capable-but-not-maximum, reserve the higher setting for cases where the extra cost is justified.

### Standard — Opus 5, effort `high`

Assign Standard if ANY of these are true (and Heavy was not triggered):
- `file_count` is 2–5
- `ac_count > 3`
- `touches_skill` is true
- Issue body is >200 words with structural patterns (includes a user story, describes a new feature via keywords like "implement", "add", "support")
- `is_multi_issue` with mixed complexity (at least one non-trivial issue that didn't trigger Heavy)

### Light — Sonnet 5 (or Haiku 4.5), effort `low`

Assign Light if ANY of these are true (and Heavy/Standard were not triggered):
- `file_count` is 0–1
- `scope_keywords` include "typo", "rename", "comment", "formatting", "config", "doc update", "README"
- Issue describes a straightforward single-file addition or modification

### Fallback

If classification is unclear, default to **Standard**. It is better to slightly over-resource than to under-resource and get instruction adherence slippage.

## Step 5.5: Partition Subagent Candidates (PM auto-detect only)

**Skip this step entirely if `PM_AUTO_DETECT` is not `true`** (i.e., when explicit arguments were provided via Path A, or if Path C was taken). When skipped, all issues proceed to Step 6 as thread-prompt issues.

When `PM_AUTO_DETECT=true`, partition the classified issues into two groups. **The default is subagent-eligible (inline execution); an issue falls into the thread-prompt group only if it is "too big for any subagent."** Evaluate the too-big test **per issue**, using the same three criteria as `/subagent` Step 4 — a judgment call about whole-issue size and interactivity, **not** tier and **not** file/AC/dependency arithmetic:

1. **Phase A won't fit one subagent's output budget** — a very large, many-file initial implementation a single Phase A subagent (~32K output budget) couldn't produce in one pass. Judge from the CR-plan file list and scope, not a fixed `file_count`.
2. **Needs interactive human judgment mid-build** — genuinely unresolved product/design decisions that must be settled *during* implementation. An "Open questions" section the issue already answers does not count.
3. **Should be split into multiple PRs** — the issue asks to be split, or its scope spans several independent deliverables.

If **none** hold, the issue is **subagent-eligible** (runs inline). If **any** holds, it is a **thread-prompt issue** (too big). Touching `.claude/rules`, `CLAUDE.md`, or `.claude/skills`, a high `ac_count`, dependencies, orchestration keywords, or a Heavy/Standard `issue_tier` no longer force the thread-prompt group on their own — none of them is a gate here.

**Result of partitioning:**
- **Subagent-eligible issues (the default, usually the majority)** — reported in a separate section with a `/subagent` command suggestion (see Step 6).
- **Thread-prompt issues (too big)** — everything the too-big test flagged. These get full prompt blocks as normal, each with a one-line too-big reason.

If all issues are subagent-eligible, the thread-prompt group is empty — only the Subagent Candidates section is output. If no issues are subagent-eligible (every detected issue is too big), the Subagent Candidates section is omitted entirely.

**Batch tier recomputation:** When `PM_AUTO_DETECT=true` and partitioning produces a non-empty subagent-eligible group, the batch tier from Step 5 may be incorrect (it was computed over all issues including the now-partitioned subagent candidates). Recompute the batch tier using only the thread-prompt issues. This includes recomputing all derived signals for that subset (e.g., `is_multi_issue`, dependency totals, and other batch-level aggregates) before reapplying the Step 5 decision tree. If all issues were subagent-eligible (empty thread-prompt group), skip tier computation entirely.

## Step 6: Generate Output

Produce the following output in Markdown. Use the gathered data to fill in each section.

### Delivery mode

Check chip availability per `.claude/reference/chip-launching.md`, then branch. The **prompt content is identical either way** — only delivery differs:

- **Chip mode** (`mcp__ccd_session__spawn_task` present): for each thread-prompt issue (after Step 5.5 partitioning), call `spawn_task` with `title` / `prompt` / `tldr` / `cwd`, where `prompt` is exactly the content that would sit **inside** that issue's `~~~` fences in fallback mode — the fence delimiters themselves are not part of the prompt. Everything between them, starting with the `**Model:**` line, is. Print only the short summary per issue — issue, title, `**Model:**` line, one-line rationale. The user clicks to launch; never launch for them.
- **Fallback mode** (tool absent): print today's `~~~`-fenced blocks for every thread-prompt issue — **copy-paste-ready**, each independently pasteable into a new thread. Byte-identical to the chip `prompt` (model-guard preamble included) — see `chip-model-guard-decision.md` for why this is no longer byte-for-byte identical to pre-chip output.

**Spawn outcomes are tracked per issue.** A failed `spawn_task` falls back for **that issue alone** — print its full block and note the fallback once for the batch (per `chip-launching.md`); the rest of the batch keeps its chips. Do not print a block for an issue whose chip spawned successfully. Every thread-prompt issue ends with exactly one of: a chip, or a printed block.

**Record every chip's `task_id`.** After each successful spawn, record the returned `task_id` against its issue and mark that issue `Chip offered` — an unrecorded chip can never be withdrawn, which would break stale-chip hygiene. In a PM thread, write it to `/pm`'s Active Work table (its `Task ID` column is the canonical home). Outside a PM thread, keep it in this thread's state so it stays dismissable within the session, and say so in the summary.

**Skip issues already offered.** Before spawning, check the recorded state (Path B's Active Work scan already excludes `Chip offered` — see Step 0) and skip any issue that already has a live chip. Re-running `/prompt` must not offer the same issue twice. Issues that were never spawned, or whose spawn failed, are still eligible.

Subagent candidates from Step 5.5 never get chips — they run inline via `/subagent`, so that section is unchanged in both modes.

`/prompt` introduces **no all-open-PR ceiling count of its own**: Path B's issue set comes from the PM thread's own `## Suggested Next Issues` / `## Active Work` (your work), and any slot/ceiling gating is delegated — chip offers follow `chip-launching.md`'s PM-context inline gate and inline runs follow `/subagent`'s concurrency ceiling, both author-scoped per `subagent-orchestration.md` (the canonical ceiling). The `Fixes #N` / `Closes #N` signal read during classification (Step 2) is a per-issue in-flight/dedup hint, not a `/prompt`-owned slot count, and never gates a launch on a collaborator's PR. (`/wave` is different: an issue covered by a PR *you* authored **does** count toward its `IN_FLIGHT` and reduces available slots — that is `/wave`'s slot accounting, not `/prompt`'s.)

If the user asks to "print the full prompt for #N" while in chip mode, re-emit that issue's complete tilde-fenced block verbatim. The chip stays offered.

### Output Structure

Below is the fallback-mode structure. In chip mode, parts 2 and 3 collapse to short summaries and the block content moves inside each chip's `prompt`.

The output has up to three parts:

1. **Subagent Candidates section** (only when `PM_AUTO_DETECT=true` and subagent-eligible issues exist) — shown first, before prompt blocks
2. **Tier Recommendation** — plain text (not inside a code fence), shown once. Applies only to the thread-prompt issues (not the subagent candidates).
3. **Per-issue prompt blocks** — one tilde-fenced block (`~~~`) per thread-prompt issue, each self-contained with all context needed by the executing agent

When `PM_AUTO_DETECT=true` and Step 5.5 produced a non-empty subagent-eligible group, output the Subagent Candidates section first (see template below). Then output the Tier Recommendation and prompt blocks for the remaining thread-prompt issues only.

If all issues are subagent-eligible, skip the Tier Recommendation and prompt blocks entirely — only output the Subagent Candidates section. If no issues are subagent-eligible (or `PM_AUTO_DETECT` is not `true`), skip the Subagent Candidates section entirely.

For single-issue input, there is one prompt block. For batch input, there are multiple prompt blocks, each independently copyable (i.e., self-contained with all context). **Per-issue `issue_tier`** drives the **Model** line at the top of that issue's block (each block can differ in a batch). **Batch tier** (from thread-prompt issues only) still drives the global **Tier Recommendation** prose and whether **Protocol Checkpoints** appear inside each block — when the batch tier is Heavy, include Heavy checkpoints in every thread-prompt block even if that issue's `issue_tier` is Light. **Batch tier is computed from thread-prompt issues only** — subagent candidates do not influence the batch tier.

**Fence nesting rule:** MUST use tilde fences (`~~~`) for all outer prompt blocks. Do NOT use backtick fences as outer delimiters. Inner code examples (bash commands, SQL, file paths, etc.) may use the standard three backtick characters because a `~~~`-delimited outer block is not closed by inner backticks; this keeps each full prompt block copyable as one unit in renderers that mishandle nested backtick fences.

### Subagent Candidates Template (PM auto-detect only)

When `PM_AUTO_DETECT=true` and subagent-eligible issues exist, output this section first:

```
## Subagent Candidates (run inline — default)

These issues run inline as subagents directly in this PM thread — the default for anything not too big for a subagent:
- #{N} — {Title} ({Tier} tier, {file_count} file(s))
- #{M} — {Title} ({Tier} tier, {file_count} file(s))

Run: `/subagent #{N} #{M}`
```

If there are also thread-prompt issues, follow with the Tier Recommendation and prompt blocks below. If all issues are subagent-eligible, this section is the entire output — add a note: "All detected issues qualify for subagent execution. No thread prompts needed."

### Output Template

Output the Tier Recommendation as plain text first (skip if all issues are subagent-eligible):

```
## Tier Recommendation

**{TIER_NAME}** — {MODEL} — effort: {EFFORT}

Rationale: {1-line explanation of why this tier was selected, citing the dominant signal}
```

**OUTPUT MUST USE `~~~` FENCES, NOT BACKTICKS.** The opening and closing lines of every per-issue prompt block must be exactly `~~~`.

**Map tier to `{MODEL}` and `{EFFORT}` strings** (same Heavy / Standard / Light mapping for both the batch **Tier Recommendation** line and each per-issue `**Model:**` line — use **batch tier** for Tier Recommendation and **per-issue `issue_tier`** for each block):
- **Heavy** → `Opus 5`, effort `xhigh` (step up to `max` for correctness-critical work — see Step 5 `max` effort step-up rule; step up to `ultracode` for multi-agent orchestration; append "(or Fable 5 — ~2× cost, for the hardest long-horizon work)" only when the Step 5 Fable 5 step-up rule is met)
- **Standard** → `Opus 5`, effort `high` (step up to `xhigh` for demanding coding work)
- **Light** → `Sonnet 5`, effort `low` (Haiku 4.5 is a valid cheaper alternative — append "(or Haiku 4.5)" to Light-tier recommendations)

**`{REASON}` construction:** Choose a short phrase (≤10 words) that names the main complexity driver for **this issue alone** — e.g. touches `.claude/rules`, touches `CLAUDE.md`, orchestration keywords, dependency web, many files from the CR plan, high `ac_count`, skill paths, multi-file feature work, or Light-scope keywords. Do not copy the batch Tier Recommendation rationale into every block when reasons differ per issue.

Then, for each issue, output a self-contained prompt block. Use tilde fences (`~~~`, shown here as the outer boundary):

~~~
**Model:** Opus 5 — skill change with many acceptance checks
{Model-guard preamble — insert verbatim from `chip-launching.md` "Model-guard preamble", immediately after this line, no blank line between}
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
- [ ] After coding: Run `coderabbit review --agent` and `codeant review --all --headless` — one clean pass on each available CLI required before pushing (fallbacks per `cr-local-review.md`)
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
- **All PM-detected issues are too big (thread-prompt):** Output normally — skip the Subagent Candidates section entirely. This is the same as the explicit-args path.
- **`/subagent` skill not yet available:** The Subagent Candidates section outputs a `/subagent` command suggestion regardless of whether the skill exists. If the user runs it and the skill is missing, they will get a clear error. The `/prompt` skill does not gate on `/subagent` availability.
- **Chip tool unavailable (CLI, headless, older client):** Fallback mode — output is byte-identical to the chip `prompt`, model-guard preamble included (see `chip-model-guard-decision.md`). Do not mention chips.
- **Spawn fails mid-batch:** Fall back to a printed block for that issue only; the rest of the batch keeps its chips. Do not retry the failed spawn.
- **User asks for the full prompt in chip mode:** Re-emit that issue's complete tilde-fenced block verbatim, guard included; leave the chip in place.
- **Launched thread's running model mismatches its `**Model:**` line:** The guard rules live in `chip-launching.md`, not here — the launched thread stops on any mismatch as its first action and waits for the user, per the model-guard preamble. `/prompt` only has to ensure the preamble is present in every block; it does not itself detect or resolve mismatches.

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
When called with no args in a PM thread, auto-detects recently suggested issues, classifies each, and partitions into subagent candidates (the default — run inline via `/subagent`) and the few too-big issues that get thread prompts.

**No arguments outside PM context:**
```
/prompt
```
Falls back to asking: "Which issue(s) should I analyze?"

### Sample output

For an issue with `touches_skill=true` and `ac_count=4`, the skill emits the Tier Recommendation as plain text first, then a self-contained prompt block in a tilde fence. The recommendation rendered to the chat looks like:

> **Standard** — Opus 5 — effort: high
>
> Rationale: touches_skill=true (modifies a file under .claude/skills/) drives Standard.

The prompt block that follows:

~~~
**Model:** Opus 5 — skill file with multiple acceptance criteria
{model-guard preamble — see "Model-guard preamble" above, verbatim, omitted here for brevity}
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

In **chip mode**, that same issue produces a chip plus this summary — the block above rides inside the chip instead of being printed:

> - **#110 — {Title}** — chip offered
>   **Model:** Opus 5 — skill file with multiple acceptance criteria
>   Modifies a skill under `.claude/skills/` with four acceptance criteria.

**Note:** This skill produces a recommendation. The user decides whether to follow the tier suggestion. When in doubt, the skill errs toward the higher tier — it's better to slightly over-resource than to get instruction adherence failures on a complex task.
