---
name: subagent
description: Run Quick/Light issues as subagents directly from a PM thread. Validates complexity, spawns Phase A/B/C agents, monitors progress, and reports merge readiness. Use when small issues should be executed inline instead of in separate coding threads.
argument-hint: "#42 [#55 #61 ...] (one or more issue numbers)"
---

Execute one or more small issues as subagents within the current thread. Each issue goes through the full Phase A/B/C orchestration protocol (fix, review, merge prep) while this skill monitors progress and manages transitions.

Parse `$ARGUMENTS` as space-separated issue references. Strip `#` prefixes to get bare issue numbers. If no arguments provided, ask the user which issue(s) to execute.

---

## Step 1: Gather Issue Data

For each issue number, fetch the full issue:

```bash
gh issue view $NUMBER --json number,title,body,labels,milestone,assignees,createdAt,state,closedAt
```

**Validation:**
- If the issue does not exist or is closed, report: "Issue #N not found or already closed — skipping." Continue with remaining issues.
- If all issues are invalid, stop with an error message.

For each valid issue, extract and record:
- **Full body content** (needed for complexity analysis and subagent prompt)
- **Labels** (check for protocol-relevant labels)
- **Acceptance criteria** — count all checklist items matching `- [ ]` or `- [x]`/`- [X]` in the body

## Step 2: Detect Implementation Plan

For each issue, first try the shared CR plan detector — it encapsulates the canonical jq filter (CR author, skip "actions performed" ack lines, length > 200) behind a stable CLI. Branch on the exit code explicitly — don't swallow it with `|| true`, or a closed issue (exit 3) and a gh API outage (exit 4) look the same as "no plan" (exit 1):

```bash
PLAN=""
if PLAN=$(.claude/scripts/cr-plan.sh "$NUMBER"); then
  : # exit 0 — CR plan captured in $PLAN
else
  rc=$?
  case "$rc" in
    1) PLAN="" ;;  # no CR plan; fall through to the human-plan scan below
    3)
      echo "Issue #$NUMBER not found or already closed — skipping." >&2
      continue
      ;;
    4)
      echo "cr-plan.sh: gh error on issue #$NUMBER — skipping." >&2
      continue
      ;;
    *)
      echo "cr-plan.sh: unexpected exit $rc on issue #$NUMBER — skipping." >&2
      continue
      ;;
  esac
fi
```

Exit codes: `0` plan found on stdout, `1` no plan, `3` issue not found/closed, `4` gh error. Run `.claude/scripts/cr-plan.sh --help` for full usage.

**If `$PLAN` is empty (no CR plan), fall back to scanning comments for a human-authored plan** — a tech lead or teammate may have written one directly on the issue. The script intentionally only matches `coderabbitai`, so the human-only fallback scan is the agent's job. Explicitly filter out bot accounts so automated comments can't become `$PLAN`:

```bash
if [ -z "$PLAN" ]; then
  gh api --paginate repos/{owner}/{repo}/issues/$NUMBER/comments \
    --jq '.[] | select(.user.type != "Bot") | {author: .user.login, body: .body}'
fi
```

From the returned comments, prefer the most structured/detailed **human-authored** plan — file lists, implementation steps, phase breakdowns — and store that body in `$PLAN`. Never promote a bot-authored comment into `$PLAN` here; bot plans only reach `$PLAN` via the CR path above.

- **Implementation plan:** Use `$PLAN` (either the CR plan from `cr-plan.sh` or the best human-authored plan from the fallback scan) as the canonical plan for this issue.
- If a CR plan exists, extract the **file list** using these patterns:
  - Look for headings containing "Files", "Files likely touched", "File list", or "Touched files" (case-insensitive)
  - Parse the block following that heading: bullet/numbered lists or fenced code blocks with one path per line
  - Also capture inline backticked paths
  - Normalize: trim whitespace, strip leading `./`, deduplicate, skip non-path lines
- Store the CR plan content verbatim for inclusion in the subagent prompt

## Step 3: Extract Complexity Signals

Compute these signals per issue (same logic as `/prompt` Steps 3-4):

| Signal | How to compute |
|--------|---------------|
| `file_count` | Count of files from CR plan file list. If no CR plan, count path-like strings in the issue body (contain `/`, end with a file extension, don't start with `http`). Default: 0. |
| `dependency_count` | Count of dependency references: `blocked by #N`, `depends on #N`, `blocks #N`, `after #N`, etc. Scan both issue body and comments. |
| `is_multi_issue` | `true` if more than one issue number was provided as input. |
| `touches_rules` | `true` if any file path matches `.claude/rules/*.md` OR body mentions "rule file", "workflow protocol". |
| `touches_claude_md` | `true` if any file path matches `CLAUDE.md` (case-insensitive) OR body mentions "CLAUDE.md". |
| `touches_skill` | `true` if any file path matches `.claude/skills/` OR issue is about creating/modifying a skill. |
| `ac_count` | Count of acceptance criteria checkboxes (both `- [ ]` and `- [x]`/`- [X]`) in issue body. |
| `has_orchestration_keywords` | `true` if body contains: "subagent", "Phase A", "Phase B", "Phase C", "multi-phase", "orchestration", "monitor mode", "handoff". |
| `scope_keywords` | Collect any of: "typo", "rename", "comment", "config", "doc update", "README", "formatting". |

## Step 4: Classify Tier (Same as `/prompt` Step 5)

Apply this decision tree. When signals conflict, choose the **higher** tier.

### Heavy — reject
Assign Heavy if ANY: `touches_rules`, `touches_claude_md`, `has_orchestration_keywords`, `file_count > 5`, `dependency_count > 2`, or (`is_multi_issue` AND at least one issue has `file_count > 1` or `ac_count > 3`).

### Standard — reject
Assign Standard if ANY (and Heavy not triggered): `file_count` 2–5, `ac_count > 3`, `touches_skill`, body >200 words with feature keywords, or `is_multi_issue` with mixed complexity.

### Quick — accept
Assign Quick only if ALL: `scope_keywords` exclusively from "typo"/"rename"/"comment"/"formatting", `file_count` 0–1, `ac_count` <= 2, `dependency_count` 0, no orchestration/rule/skill signals.

### Light — accept
Assign Light if ANY (and Heavy/Standard/Quick not triggered): `file_count` 0–1, `scope_keywords` include "config"/"doc update"/"README", or issue describes a single-file change.

### Fallback
If unclear, default to **Standard** (which means rejection).

## Step 5: Gate Check — Validate Candidate Criteria

For each issue, verify ALL of the following:

| Signal | Threshold |
|--------|-----------|
| `file_count` | 0–1 files |
| `ac_count` | <= 3 acceptance criteria |
| `dependency_count` | 0 (no blockers or blocked-by) |
| `touches_rules` | `false` |
| `touches_claude_md` | `false` |
| `has_orchestration_keywords` | `false` |
| Tier classification | Quick or Light only |

**If any signal exceeds its threshold, reject the issue:**

```
Issue #N is too complex for subagent execution (classified as {tier}).
Failing signals: {list signals that exceeded thresholds}
Use `/prompt #N` to generate a thread prompt instead.
```

**If all issues are rejected**, stop and report the rejections. Do not proceed.

**If some pass and some fail**, report the rejections and proceed with the qualifying issues. Ask: "Proceeding with qualifying issues: #{a}, #{b}. The rejected issues need `/prompt` instead."

## Step 6: Pre-Spawn Setup

For each qualifying issue:

### 6.0: Check for existing open PRs

For each qualifying issue, verify no PR is already open:

```bash
gh pr list --search "head:issue-{NUMBER}" --json number,title,state
```

If a PR already exists for the issue, skip it: "Issue #N already has PR #{M} — skipping."

### 6.1: Ensure handoff directory exists

```bash
mkdir -p ~/.claude/handoffs/
```

### 6.2: Initialize session state

Read or create `~/.claude/session-state.json`. Add each qualifying issue to the `prs` section (PR number will be filled after Phase A creates it). Initialize:

```json
{
  "last_updated": "{ISO 8601 now}",
  "monitoring_active": true,
  "prs": {},
  "cr_quota": {"reviews_used": 0, "window_start": "{ISO 8601 now}"},
  "greptile_daily": {"reviews_used": 0, "date": "{YYYY-MM-DD}", "budget": 40},
  "active_agents": []
}
```

If session-state already exists, merge — do not overwrite existing PR entries or quota counters.

### 6.3: Read full rule files for subagent prompts

Read ALL rule files and CLAUDE.md to include in subagent prompts:

```bash
cat ./CLAUDE.md
cat ./.claude/rules/*.md
```

If no project-level files exist, fall back to global:

```bash
cat ~/.claude/CLAUDE.md
cat ~/.claude/rules/*.md
```

Store the complete output — do NOT summarize or excerpt.

## Step 7: Spawn Phase A Subagents

For each qualifying issue, spawn a Phase A subagent using the Agent tool.

**Parallel execution rules:**
- Spawn up to 4 Phase A subagents in parallel (soft limit from subagent-orchestration.md)
- If more than 4 qualifying issues, stagger: spawn the first 4, then spawn additional agents as earlier ones complete
- Each subagent gets its own worktree (use `isolation: "worktree"` on the Agent tool call)

**Subagent prompt template** (fill in variables per issue):

```
You are a Phase A coding agent. Your job: implement Issue #{NUMBER}, push code, create a PR, then EXIT.

## Issue Details
Title: {title}
Body:
{full issue body}

## CR Implementation Plan
{CR plan if available, or "No CR plan available — explore the codebase to identify affected files."}

## RULES (MANDATORY — read all of these)
{COMPLETE contents of CLAUDE.md}

{COMPLETE contents of all .claude/rules/*.md files}

## SAFETY WARNING
SAFETY: Do NOT delete, overwrite, move, or modify .env files — anywhere, any repo.
Exception: template files matching .env.<example|sample|template|dist|tpl>
(case-insensitive) are committed, non-secret, and safe to edit.
Do NOT run git clean in ANY directory. Do NOT run destructive commands (rm -rf, rm,
git checkout ., git stash, git reset --hard) in the root repo directory. Stay in your
worktree directory at all times.

## Phase A Instructions

1. You are already in a worktree — verify with `git branch --show-current`.
2. Read the issue body above — this is your implementation plan.
3. Implement the changes.
4. Run local CodeRabbit review: `coderabbit review --prompt-only`
   - Fix all valid findings.
   - Run again. Repeat until one clean pass with no findings.
   - If coderabbit CLI hangs >2 minutes or errors twice, do a self-review instead.
5. Commit all changes in ONE commit.
6. Push the branch.
7. Create the PR via `gh pr create` with:
   - `Closes #{NUMBER}` in the body
   - A **Test plan** section with acceptance criteria checkboxes from the issue
8. Write the handoff file:
   ```bash
   mkdir -p ~/.claude/handoffs/
   ```
   Then write `~/.claude/handoffs/pr-{PR_NUMBER}-handoff.json` with:
   ```json
   {
     "schema_version": "1.0",
     "pr_number": {PR_NUMBER},
     "head_sha": "{HEAD_SHA}",
     "reviewer": "cr",
     "phase_completed": "A",
     "created_at": "{ISO 8601 now}",
     "findings_fixed": [],
     "findings_dismissed": [],
     "threads_replied": [],
     "threads_resolved": [],
     "files_changed": ["{list of files you changed}"],
     "push_timestamp": "{ISO 8601 now}",
     "notes": "{brief summary of what was done}"
   }
   ```
9. Print the Structured Exit Report as your FINAL output:
   ```
   EXIT_REPORT
   PHASE_COMPLETE: A
   PR_NUMBER: {PR_NUMBER}
   HEAD_SHA: {HEAD_SHA}
   REVIEWER: cr
   OUTCOME: {pushed_fixes|no_findings|exhaustion}
   FILES_CHANGED: {comma-separated file paths}
   NEXT_PHASE: B
   HANDOFF_FILE: ~/.claude/handoffs/pr-{PR_NUMBER}-handoff.json
   ```
10. EXIT immediately after printing the exit report. Do NOT enter a polling loop.
```

**Agent tool call parameters:**
- `mode: "bypassPermissions"`
- `model: "opus"` (heavy reasoning — initial implementation, multi-file edits, PR creation — see `subagent-orchestration.md` "Model Selection")
- `isolation: "worktree"`
- `run_in_background: true` (so you can monitor multiple agents)

> **Note on `subagent_type`:** Do NOT set `subagent_type: "phase-a-fixer"` here. The `/subagent` skill's "Phase A" does **initial implementation** of a new issue (no PR exists yet), but `.claude/agents/phase-a-fixer.md` is designed for **fixing existing review findings** on an already-open PR — its workflow references findings, review threads, and push replies that don't apply to green-field implementation. Let this Agent call fall back to the default general-purpose agent; the long custom prompt below carries all the rules the subagent needs.

Record each spawned agent in `session-state.json` under `active_agents` and set `monitoring_active=true`. Also record the monitoring primitive state from `.claude/reference/pm-monitoring-decision.md`: use in-turn Dedicated Monitor Mode immediately, and arm between-turn `/loop` for 1-2 active workers or `CronCreate` for 3+ workers/cross-session durability when the campaign needs polling after the current turn.

## Step 8: Enter Monitor Mode

Once any subagent is spawned, enter **Dedicated Monitor Mode**. Your ONLY job is now orchestration.

### Monitor loop (repeat every ~60 seconds):

1. **Check for completed subagents.** Poll active agent statuses. If any returned results, process immediately (step 2).
2. **Execute pending phase transitions.** For each completed subagent:
   - Parse the Structured Exit Report from its output.
   - Execute the appropriate Completion Protocol (see below).
3. **Check for pending transitions from prior cycles.** Read `session-state.json` for PRs where a phase completed but the next phase was not launched.
4. **Send heartbeat.** If >5 minutes since last user message, send a status update. Include: active agents, PR phases, pending transitions, blockers. Always start with a timestamp: `TZ='America/New_York' date +'%a %b %-d %I:%M %p ET'`.
5. **Check for stale agents.** >15 min for Phase A, >10 min for Phase B, >5 min for Phase C without reporting — investigate.

### Permitted activities in monitor mode:
- Poll subagent status
- Send heartbeat/status messages
- Launch next-phase agents (A->B->C transitions)
- Verify subagent outputs (check pushes, replies)
- Read/update `session-state.json`

### Prohibited activities in monitor mode:
- Writing or editing code/files directly
- Creating GitHub issues or PRs
- Reading source files for non-monitoring purposes
- Any substantive work — delegate to a subagent instead

## Step 9: Phase Completion Protocols

### Phase A Completion

When a Phase A subagent returns:

1. **Parse the exit report.** Extract `PR_NUMBER`, `HEAD_SHA`, `OUTCOME`, `REVIEWER`, `NEXT_PHASE`.
   - If no exit report: treat as silent failure — report to user and check GitHub API.
2. **Branch on OUTCOME:**
   - `pushed_fixes` or `no_findings` -> proceed to step 3.
   - `exhaustion` -> launch a replacement Phase A subagent within 60s. Report to user.
3. **Verify the push:** `gh pr view {PR_NUMBER} --json commits --jq '.commits[-1].oid'` — confirm SHA matches.
4. **Verify handoff file:** `cat ~/.claude/handoffs/pr-{PR_NUMBER}-handoff.json` — confirm valid JSON with `phase_completed: "A"`.
5. **Launch Phase B within 60 seconds.** Check if reviewers already posted findings. Include handoff file path in the Phase B prompt.
6. **Update `session-state.json`** — record phase transition.
7. **Report to user** with timestamp.

### Phase B Subagent Prompt Template

```
You are a Phase B review-loop agent for PR #{PR_NUMBER} (Issue #{ISSUE_NUMBER}).

## Handoff File
Read ~/.claude/handoffs/pr-{PR_NUMBER}-handoff.json first. Use it to avoid duplicate work.
If missing, reconstruct state from GitHub API.

## RULES (MANDATORY)
{COMPLETE contents of CLAUDE.md and all .claude/rules/*.md}

## SAFETY WARNING
{Same safety warning as Phase A}

## Phase B Instructions

1. Read the handoff file at ~/.claude/handoffs/pr-{PR_NUMBER}-handoff.json.
2. Check for unresolved findings BEFORE requesting any review:
   - Fetch all 3 endpoints (reviews, inline comments, issue comments) with per_page=100.
   - If unresolved findings from coderabbitai[bot] or greptile-apps[bot] exist, fix them first.
3. Check ALL CI check-runs. Fix any failures before continuing.
4. Poll for CR review every 60s on all 3 endpoints. Filter by coderabbitai[bot].
5. Run `.claude/scripts/escalate-review.sh {PR_NUMBER}` every CR-owned poll cycle and branch on its single `STATUS=` verdict:
   - `polling_cr`: continue polling CR.
   - `switch_bugbot`: persist `reviewer: bugbot` and follow the BugBot path.
   - `trigger_greptile`: run `greptile-budget.sh --consume`, post `@greptileai`, persist `reviewer: greptile`, and follow the Greptile path.
   - `budget_exhausted`: persist the self-review fallback/blocker; do NOT post `@greptileai`.
   - `self_review`: perform/report self-review fallback; merge remains blocked.
6. Check commit status for CR completion signal and rate-limit fast-path.
7. If CR rate-limited or silent past the gate threshold, do NOT hand-roll fallback timing — use the escalation gate verdict above. Polling cadence stays 60 s; a clean CR check-run completion short-circuits the wait. Rate-limit signals override the timeout and are handled by `escalate-review.sh`.
8. Process findings: fix all valid ones in ONE commit, push once, reply to every thread, resolve threads via GraphQL.
9. Merge gate:
   - CR-only: 1 explicit CR APPROVED review on the current HEAD SHA (commit_id must match HEAD; acks / check-run completion alone do NOT count).
   - Greptile: severity-gated (no P0 after fix = merge-ready).
10. Update the handoff file: set phase_completed to "B", refresh head_sha, merge new entries.
11. Print Structured Exit Report:
    ```
    EXIT_REPORT
    PHASE_COMPLETE: B
    PR_NUMBER: {PR_NUMBER}
    HEAD_SHA: {current HEAD}
    REVIEWER: {cr|bugbot|greptile|self_review}
    OUTCOME: {clean|fixes_pushed|merge_ready|blocked_self_review|exhaustion}
    FILES_CHANGED: {files changed in this phase}
    NEXT_PHASE: {C|B}
    HANDOFF_FILE: ~/.claude/handoffs/pr-{PR_NUMBER}-handoff.json
    ```
12. EXIT immediately.
```

**Phase B Agent tool call parameters:**
- `subagent_type: "phase-b-reviewer"`
- `mode: "bypassPermissions"`
- `model: "opus"` (Phase B evaluates review findings and fixes code — see `subagent-orchestration.md` "Model Selection")
- `isolation: "worktree"` (same as Phase A — Phase B fetches and checks out the PR branch inside its own fresh worktree)
- `run_in_background: true`

### Phase B Completion

When a Phase B subagent returns:

1. **Parse exit report.**
2. **Branch on OUTCOME:**
   - `merge_ready` -> ask for merge authorization if it has not already been provided, then launch Phase C within 60s.
   - `clean` -> launch replacement Phase B within 60s (no explicit CR approval on current HEAD yet, or latest approval is on a stale SHA).
   - `fixes_pushed` -> launch replacement Phase B within 60s.
   - `blocked_self_review` -> report blocker to user; do NOT auto-loop Phase B without a reviewer availability change.
   - `exhaustion` -> launch replacement Phase B within 60s.
3. **Verify review state via GitHub API** for `merge_ready`.
4. **Update `session-state.json`.**
5. **Report to user** with timestamp.

### Phase C Subagent Prompt Template

```
You are a Phase C verify-and-wrap agent for PR #{PR_NUMBER} (Issue #{ISSUE_NUMBER}).
The user has authorized merging; execute the canonical `/wrap` flow after verification.

## Handoff File
Read ~/.claude/handoffs/pr-{PR_NUMBER}-handoff.json first.

## RULES (MANDATORY)
{COMPLETE contents of CLAUDE.md and all .claude/rules/*.md}

## SAFETY WARNING
SAFETY: Do NOT delete, overwrite, move, or modify .env files — anywhere, any repo.
Exception: template files matching .env.<example|sample|template|dist|tpl>
(case-insensitive) are committed, non-secret, and safe to edit.
Do NOT run git clean in ANY directory. Do NOT run destructive commands (rm -rf, rm,
git checkout ., git stash, git reset --hard) in the root repo directory. Stay in your
worktree directory at all times.

## Phase C Instructions

1. Read the handoff file.
2. Verify merge gate is satisfied:
   - CR-only: 1 explicit CR APPROVED review on the current HEAD SHA.
   - BugBot: 1 clean BugBot pass on the current HEAD SHA.
   - Greptile: severity gate satisfied.
3. Extract Test Plan checkboxes via the shared helper, branching on the exit code. Exit `1` ("no Test Plan") is a **blocking** outcome — every PR must include a Test Plan section (per CLAUDE.md):
   ```bash
   if ITEMS=$(.claude/scripts/ac-checkboxes.sh {PR_NUMBER} --extract); then
     : # $ITEMS is a JSON array of {index, checked, text}
   else
     rc=$?
     case "$rc" in
       1) OUTCOME=blocked; MSG="No Test Plan section in PR body — required per CLAUDE.md" ;;
       3) OUTCOME=blocked; MSG="PR not found" ;;
       *) OUTCOME=blocked; MSG="ac-checkboxes.sh failed (exit $rc)" ;;
     esac
   fi
   ```
4. If `OUTCOME=blocked` was set in step 3, skip steps 5–9 and go straight to step 10 (exit report) with `OUTCOME: blocked` and the captured `$MSG`.
5. For each item in `$ITEMS` with `checked == false`, read the relevant source file(s) and verify the criterion is met.
6. Tick passing items by index (or `--all-pass` if every unchecked item passed):
   ```bash
   .claude/scripts/ac-checkboxes.sh {PR_NUMBER} --tick "0,2,3"
   # or
   .claude/scripts/ac-checkboxes.sh {PR_NUMBER} --all-pass
   ```
7. If any item fails verification, do NOT tick it — set `OUTCOME: blocked` and list the failing items in the exit report.
8. Check ALL CI check-runs pass. If any fail, set `OUTCOME: blocked`.
9. If steps 1–8 pass, read `.claude/skills/wrap/SKILL.md` and execute it exactly from the current PR branch. Do not duplicate `/wrap` merge, main-sync, follow-up, or stale-cleanup logic in this prompt.
10. Print Structured Exit Report:
   ```
   EXIT_REPORT
   PHASE_COMPLETE: C
   PR_NUMBER: {PR_NUMBER}
   HEAD_SHA: {current HEAD}
   REVIEWER: {cr|bugbot|greptile}
   OUTCOME: {merged|blocked}
   FILES_CHANGED:
   NEXT_PHASE: none
   HANDOFF_FILE: ~/.claude/handoffs/pr-{PR_NUMBER}-handoff.json
   ```
11. EXIT immediately.
```

**Phase C Agent tool call parameters:**
- `subagent_type: "phase-c-merger"`
- `mode: "bypassPermissions"`
- `model: "sonnet"` (Phase C is lightweight verification plus the mechanical `/wrap` flow — see `subagent-orchestration.md` "Model Selection")
- `isolation: "worktree"` (same as Phase A — Phase C fetches and checks out the PR branch inside its own fresh worktree)
- `run_in_background: true`

### Phase C Completion

When a Phase C subagent returns:

1. **Parse exit report.**
2. **Branch on OUTCOME:**
   - `merged` -> verify GitHub shows the PR merged, then delete the handoff file.
   - `blocked` -> report blocker details to user. Do NOT merge.
3. **Update `session-state.json`** — mark PR as Phase C complete.
4. **Report to user** with timestamp.

## Step 10: Merge Authorization (User Input Required)

This is the **only step requiring user permission**.

For each PR where Phase B reported `merge_ready` and the user has not already authorized merging:

```
Reviews are clean for PR #{PR_NUMBER} (Issue #{ISSUE_NUMBER}). Phase C will re-check the merge gate, verify and tick AC, then run `/wrap` to squash-merge, sync root main, and detect follow-ups. Want me to launch Phase C now, or do you want to review the diff yourself first?
```

**If user approves:**
1. Launch Phase C with the explicit authorization text in the prompt.
2. Phase C runs the shared `/wrap` flow and exits with `OUTCOME: merged` or `OUTCOME: blocked`.
3. After `OUTCOME: merged`, verify GitHub shows the PR merged, delete the handoff file, update `session-state.json`, and report: "PR #{PR_NUMBER} merged. Issue #{ISSUE_NUMBER} closed."

**If user wants to review first:** wait for their response before merging.

## Step 11: Completion

When all subagent PRs are either merged or blocked:

1. Exit monitor mode.
2. Present a summary:

```
## Subagent Execution Summary

| Issue | PR | Status | Review Cycles |
|-------|----|--------|---------------|
| #42 | #88 | Merged | 1 |
| #55 | #91 | Merged | 0 |
| #61 | #93 | Blocked (CI failure) | 2 |
```

3. For any blocked PRs, suggest next steps.

---

## Edge Cases

- **Issue has no acceptance criteria:** Flag it: "Issue #N has no acceptance criteria — the subagent will implement based on the issue body but AC verification in Phase C will be skipped."
- **CR CLI unavailable:** Subagents fall back to self-review (per cr-local-review.md timeout rules). This does not block Phase A — it just means less pre-push coverage.
- **Subagent token exhaustion:** The parent detects this via the `exhaustion` outcome in the exit report and launches a replacement agent automatically (no user input needed).
- **All reviewers down:** Subagent performs self-review. Self-review does NOT satisfy the merge gate. Parent reports the blocker to the user.
## Usage Examples

**Single issue:**
```
/subagent #42
```

**Multiple issues:**
```
/subagent #42 #55 #61
```

**From a PM thread after `/pm` suggests issues:**
```
/subagent #42 #55
```
(Quick/Light issues run as subagents; remaining issues get `/prompt` for separate threads)
