## ⛔ ALWAYS USE A WORKTREE — READ THIS FIRST

**At the start of every session, before doing anything else, create a worktree.**

Tell the user: "I'll create a worktree for isolated work." Then use the `EnterWorktree` tool (or ask the user to say "use a worktree"). This gives you your own working directory and branch — completely isolated from the root repo and from any other agents.

**Why this is mandatory:**
- The root repo directory stays clean on `main`. You never touch it.
- Multiple agents get separate worktrees — no shared working directory, no overwriting each other's files.
- Each worktree has its own branch, its own staged files, its own uncommitted changes.
- Push and pull work normally — worktrees share the same remote.

**Do not write code, edit files, stage changes, commit, or push while on `main`. Ever.** If for any reason you cannot create a worktree, fall back to creating a feature branch manually (`git checkout -b issue-N-short-description`) before touching any files.

**Worktree cleanup:** After your PR is merged, remove the worktree via `git worktree remove <path>` or let the session exit prompt handle it. Periodically run `git worktree list` to check for stale worktrees.

---

## PR & Issue Workflow

### Issues — MANDATORY before any code work

- **Every PR must link to a GitHub issue. No exceptions.** If no issue exists, create one via `gh issue create` before writing any code, creating a branch, or making any changes.
- **Why this is non-negotiable:** Issues go through a CR planning review (`@coderabbitai plan`) that catches logic errors, identifies edge cases, and produces a refined spec — all before a single coding token is spent. Skipping the issue means skipping this spec refinement, which leads to wasted coding effort on poorly defined tasks.
- **The flow is always:** Create issue → CR reviews/refines the spec → plan implementation → create branch → write code → PR. Never jump straight to coding.
- Use `Closes #N` in the PR body to auto-close the issue on merge.
- If the user asks you to make a change and there's no existing issue, **create the issue first**, then proceed with the Issue Planning Flow below. Do not treat "quick fixes" or "small changes" as exceptions — the issue is the record of what was done and why.

### Acceptance Criteria
- Every PR must include a **Test plan** section with checkboxes for acceptance criteria.
- Before merging, verify each item against the actual code and **check off** every box in the PR description.
- If an item can't be verified from code alone (e.g. visual/runtime behavior), note that it requires manual testing.

### Testing Approach
- We do **not** use TDD unless the user explicitly requests it.
- Acceptance criteria are verified via code review and manual testing after deploy, not automated test suites.
- When verifying, read the relevant source files and confirm the logic satisfies each criterion.

### Branching & Merging
- **NEVER work on `main` — not editing, not committing, not pushing.** All code changes happen in worktrees on feature branches. If you're not in a worktree, create one first. If `git branch --show-current` returns `main`, do not touch any files.
- **Every change requires: GitHub issue → feature branch → PR → squash merge.** No exceptions.
- Branch naming: `issue-N-short-description` (e.g. `issue-10-nav-welcome-header`).
- Always **squash and merge** via `gh pr merge --squash --delete-branch`, then delete the branch.
- **Never merge immediately after a rebase or force-push.** Even trivial conflict resolutions (e.g. a single import line) trigger a new CR review cycle. Always wait for CR to review the rebased commit and confirm no findings before merging. The safe flow is: resolve conflict → force-push → wait for CR → confirm clean → merge.

---

## Issue Planning Flow

**Prerequisite:** Same CR check as the review loop below. If CR is not configured, skip steps 2, 4, and 5.

When starting work on a GitHub issue, always follow this flow before writing any code:

### 1. Read the issue
- Fetch the full issue body and comments via `gh issue view N`
- Understand the requirements, context, and any discussion

### 2. Kick off CR's plan (async)
- Immediately comment `@coderabbitai plan` on the issue via `gh issue comment N --body "@coderabbitai plan"`
- Do **not** wait for CR to respond — continue to step 3

### 3. Build Claude's plan
- Explore the codebase and design an implementation plan (use plan mode)
- Draft the plan internally — do not post it yet

### 4. Poll for CR's plan
- Poll every 60 seconds for a new comment from `coderabbitai` on the issue
- If 5 minutes pass with no response, continue with Claude's plan alone and check back later
- Once CR's plan appears, read it fully

### 5. Merge the plans
- Compare CR's plan against Claude's plan
- If CR identified files, edge cases, or considerations that Claude missed, incorporate them
- If Claude's plan already covers everything CR raised, no changes needed
- The goal is the most robust plan, not a compromise — pick the best ideas from each

### 6. Post the final plan
- Post the **merged final plan** as a single comment on the issue
- This is the plan of record — one clean comment, not multiple drafts

### 7. Start coding
- Create the feature branch (`issue-N-short-description`) and begin implementation
- When implementation is done, run the **Local CodeRabbit Review Loop** (below) before pushing

---

## Local CodeRabbit Review Loop (Primary)

This is the **primary** review workflow. Run CodeRabbit locally in your terminal to catch issues **before** pushing or creating a PR. This is faster than GitHub-based reviews (instant feedback, no polling), produces no noise on the PR, and doesn't consume your GitHub-based CR review quota.

### Prerequisites
- **CodeRabbit CLI** installed and authenticated:
  ```
  curl -fsSL https://cli.coderabbit.ai/install.sh | sh
  coderabbit auth login
  ```
- **Config:** `.coderabbit.yaml` in repo root (if the repo uses CodeRabbit)
- **Verify installation:** `coderabbit --version` or `which coderabbit`
- **Default install location:** `~/.local/bin/coderabbit`
- If `coderabbit` is not in PATH, use the full path: `~/.local/bin/coderabbit`
- **API key:** `CODERABBIT_API_KEY` is set in `~/.zshrc` — this links CLI reviews to the paid Pro plan with usage-based credits. Do NOT hardcode or commit this key anywhere.
- **Always prefer local** `coderabbit review --prompt-only` over GitHub CR polling. Do NOT fall back to the GitHub CR polling loop unless local review explicitly fails.

### When to run
- After finishing implementation on a feature branch, **before pushing or creating a PR**
- After making any significant changes during development (optional — use judgment on whether a local review pass is worthwhile mid-development)

### How to run
Run the CLI directly via Bash from the repo root:
- `coderabbit review --prompt-only` — review all changes (prompt-only mode is optimized for AI agent parsing)
- `coderabbit review --prompt-only --type uncommitted` — review only uncommitted changes
- `coderabbit review --prompt-only --type committed` — review only committed changes

### Fix loop
1. Run `coderabbit review --prompt-only` to review changes
2. Parse the findings — verify each against the actual code before fixing
3. Fix **all valid findings**
4. Run `coderabbit review --prompt-only` again
5. Repeat until CR returns no findings

### Timeout & fallback
- If `coderabbit review` hangs for more than **2 minutes** or errors out, skip it and run a **self-review** instead (see below).
- Do not retry more than once. If CR CLI fails twice, it's down — move on with self-review.

### Exit criteria
- **Two consecutive clean local reviews** with no findings (or two clean self-reviews if CR CLI is unavailable)
- Once clean, commit all changes and push the branch

### Then: push and create the PR
- After the local review loop passes, push the branch and create the PR
- CodeRabbit will still auto-review on GitHub — enter the **GitHub CodeRabbit Review Loop** below as a safety net
- Because you already cleaned up locally, the GitHub review should find nothing or very little

---

## GitHub CodeRabbit Review Loop (Fallback)
- note code rabbit is called cr or CR for short

> **This is the fallback review workflow.** It runs after you push and create a PR. If the local review loop above was thorough, CR should find few or no issues here. But edge cases exist (e.g., CI-only context, cross-file interactions the local review missed), so always let this loop run.

**Prerequisite:** Before entering this loop, check if the repo uses CodeRabbit (look for `.coderabbit.yaml` at the repo root, or check if CodeRabbit has ever commented on PRs via `gh api repos/{owner}/{repo}/pulls --jq '.[].number' | head -5 | xargs -I{} gh api repos/{owner}/{repo}/pulls/{}/reviews --jq '.[].user.login' | grep -q coderabbitai`). If CodeRabbit is not configured for the repo, skip this workflow.

After pushing a commit to a PR, automatically enter the CR review loop:

### Rate Limits (Pro Tier)
- **8 PR reviews per hour** — each push to a PR branch consumes one review. So does each `@coderabbitai full review` trigger.
- **50 chat interactions per hour** — each `@coderabbitai` comment (plan, review, resume, etc.) counts.
- **Hitting the limit makes things worse:** CR throttles further, retries reset the cooldown window, and polling burns Claude tokens for nothing.

### Rate-Limit-Aware Behavior
- **Batch fixes into a single commit before pushing.** If CR found 4 issues, fix all 4 in one commit — don't push 4 separate commits (that's 4 reviews consumed vs. 1).
- **Never trigger `@coderabbitai full review` more than twice per PR per hour.** After 2 explicit triggers with no response, stop and tell the user CR may be rate-limited.
- **When multiple agents are working in parallel on separate PRs**, each push consumes a review from the shared 8/hour pool. Coordinate: stagger pushes when possible, and never have more than 3-4 PRs triggering CR reviews in the same hour.
- **If CR responds with "Reviews paused" or rate-limit language**, do NOT retry immediately. Fall back to **Macroscope** (see below). If Macroscope is also unavailable, fall back to **self-review**.

### Polling
- Poll every 60 seconds for new CodeRabbit comments/reviews on the PR
- **⚠️ Always use `per_page=100` on all GitHub API calls.** The default `per_page=30` will silently miss reviews/comments when a PR exceeds 30 total. Example: `gh api repos/{owner}/{repo}/pulls/{N}/reviews?per_page=100`. This applies to all three endpoints below.
- **Poll ALL THREE endpoints every cycle.** These are distinct GitHub API endpoints that return different data:
  1. `repos/{owner}/{repo}/pulls/{N}/reviews` — review objects (approve, request changes, review-level comments)
  2. `repos/{owner}/{repo}/pulls/{N}/comments` — inline comments on specific lines of code in the diff
  3. `repos/{owner}/{repo}/issues/{N}/comments` — **main PR conversation thread** (where CR posts its summary review, the "✅ Actions performed" ack, and general findings)
  - **⚠️ The third endpoint (`issues/` not `pulls/`) is important.** When CR reviews with findings, it posts review objects on `pulls/{N}/reviews` (which you'll see). But CR also posts its summary and the "✅ Actions performed" ack as issue comments on `issues/{N}/comments`. Missing this endpoint means you'll catch reviews with findings but miss the ack and summary — causing indefinite polling on **clean passes** where CR has no findings to post as review objects.
- **Check the commit status on EVERY poll cycle** — this serves two purposes:
  ```
  gh api "repos/{owner}/{repo}/commits/{SHA}/check-runs" \
    --jq '.check_runs[] | select(.name == "CodeRabbit") | {name, status, conclusion, title: .output.title}'
  ```
  If check-runs returns empty for CodeRabbit, fall back to the commit statuses endpoint:
  ```
  gh api "repos/{owner}/{repo}/commits/{SHA}/statuses" \
    --jq '.[] | select(.context | test("CodeRabbit"; "i")) | {context, state, description}'
  ```
  - **Completion signal:** `status: "completed"` with `conclusion: "success"` = review done (visible as "CodeRabbit — Review completed" in the PR's CI checks box). This is the definitive signal, especially for clean passes.
  - **⚠️ Fast-path rate limit detection:** If EITHER endpoint shows rate limiting — check-run has `conclusion: "failure"` with `output.title` containing "rate limit" (case-insensitive), OR commit status has `state: "failure"`/`state: "error"` with `description` containing "rate limit" — **trigger Macroscope IMMEDIATELY.** Do not wait 8 minutes. This catches rate limits within ~60-120 seconds of pushing.
  - **⚠️ Do NOT confuse the ack with completion.** The "✅ Actions performed — Full review triggered" issue comment means CR **started** reviewing — it does NOT mean the review is finished. The CI check "CodeRabbit — Review completed" is what signals actual completion.
- **⚠️ CR's GitHub username is `coderabbitai[bot]` (with the `[bot]` suffix).** Always filter by `.user.login == "coderabbitai[bot]"` — NOT bare `coderabbitai`. Using the wrong username will silently miss all CR comments.
- Track the **highest comment ID** seen so far across all three endpoints. Any comment from `coderabbitai[bot]` with an ID greater than the watermark is a new finding that needs attention.
- If CR responds, process immediately
- **Hard timeout: 8 minutes.** If CR has not delivered a review after 8 minutes of polling, stop waiting and trigger **Macroscope** (see below). Do NOT keep polling — it wastes tokens and risks session timeout.

### Timeout & Fallback — Two Trigger Paths to Macroscope
- **Fast path (~1-2 min):** The check-runs or commit statuses API shows "Review rate limit exceeded" → trigger Macroscope immediately on that poll cycle. Do not wait.
- **Slow path (8 min):** No rate-limit signal visible, but CR has not delivered review content after 8 minutes → trigger Macroscope. The distinction between "rate-limited" and "slow" is irrelevant at this point — the action is the same.
- **If Macroscope also fails** (10-minute timeout with no response): fall back to **self-review** (see below).
- Tell the user which fallback was used and why.

### Processing CR Feedback
1. Fetch the latest CR comments via `gh api`
2. Parse each finding from CR's summary/review
3. Verify each finding against the actual file before applying
4. Fix **all valid findings**, then commit and push **once** (one commit = one review consumed)
5. **Reply to every CR comment thread** acknowledging the fix (e.g. "Fixed in `abc1234`: <what changed>"). Pushing a code fix does NOT resolve a GitHub comment thread — you must post an explicit reply via `gh api repos/{owner}/{repo}/pulls/comments/{id}/replies -f body="…"`. Unreplied threads show as unresolved in the PR and block merge.
6. **@mention CR in PR-level comments.** When posting general PR comments (via `gh pr comment`), always include `@coderabbitai` in the body so CR reads them. CR only reliably processes comments where it is explicitly mentioned — untagged PR comments are often ignored. This applies to fix summaries, duplicate-finding replies posted at the PR level, and any context you want CR to incorporate into its next review.
7. Resume polling for CR's next response
8. Repeat until CR has no more findings

> **⚠️ CRITICAL: "Duplicate" findings are NOT resolved findings.**
> CR labels a comment "duplicate" when it raised the same issue in a previous round — this does **not** mean the issue was fixed. Before dismissing any CR comment (actionable, duplicate, nitpick, or otherwise), **always verify the finding against the actual code**. Only dismiss it if the current code already addresses it. Never assume a prior round resolved something without checking the file.

### Autonomy Boundaries
- **Fix autonomously:** All files unless the user instructed otherwise

### Completion

**Step 1 — Confirm reviews are clean (2 consecutive clean reviews, at least 1 from CR):**
- If CR responds with no findings after a round of fixes, post `@coderabbitai full review` one more time to confirm.
- **How to detect a clean pass:** After triggering `@coderabbitai full review`, watch for these signals in order:
  1. **Ack (review started):** CR posts an issue comment (on `issues/{N}/comments`) with "✅ Actions performed — Full review triggered." This means CR **started** the review — it is NOT a completion signal.
  2. **Completion (review finished):** The commit status check for CodeRabbit shows `status: "completed"` with `conclusion: "success"` (visible as "CodeRabbit — Review completed" in the PR's CI checks). This is the **definitive completion signal**.
  3. **Clean = completed + no new findings:** Once the CI check shows completed, check all three comment endpoints for any new findings posted after the ack. If there are none, the review is a clean pass. You do NOT need to keep polling for the full 10 minutes once the CI check is green and no findings appeared.
- **Valid combinations for merge readiness (2 clean reviews required):**
  - ✅ 2 consecutive clean CodeRabbit reviews
  - ✅ 1 clean Macroscope review + 1 clean CodeRabbit review
  - ✅ 1 clean self-review + 1 clean CodeRabbit review
  - ❌ 2 clean Macroscope reviews (need at least 1 CR)
  - ❌ 2 clean self-reviews (need at least 1 CR)
- After a clean Macroscope or self-review, always re-trigger `@coderabbitai full review` to get the required CR clean pass. If CR is still rate-limited, wait 15 minutes and try again.
  - **Exception:** If you just pushed new code (e.g., Macroscope fixes), CR auto-triggers on the new SHA — no need to manually re-trigger or wait 15 minutes. Just enter the polling loop on the new commit.
- Once the 2-review requirement is met, proceed immediately to Step 2.

**Step 2 — Verify every Test Plan checkbox (MANDATORY — do NOT skip):**
> This is the **immediate next step** after CR is clean. Do not ask the user about merging until this is done.
>
> 1. Fetch the PR body via `gh pr view N --json body`
> 2. Parse **every** checkbox in the **Test plan** section of the PR description
> 3. For each item, read the relevant source file(s) and verify the criterion is met
> 4. Check off passing items by editing the PR body (replace `- [ ]` with `- [x]`)
> 5. If any item fails, fix the code first — do NOT offer to merge with unchecked boxes
> 6. Only after **ALL** boxes are checked, proceed to Step 3
>
> **⚠️ Re-run after every CR round.** If additional code changes were made during the CR loop (e.g. fixes from CR rounds after the initial AC pass), you must re-verify ALL AC items against the final code. AC verification reflects the code **at merge time**, not the code at some earlier checkpoint.
>
> Skipping this step is a **blocking failure** — the user should never see unchecked AC boxes when asked about merge.

**Step 3 — Ask the user about merging:**
- Ask the user: "CR is clean, all AC verified and checked off. Want me to squash and merge and delete the branch, or do you want to review the diff yourself first?"
- Always use **squash and merge** (never regular merge or rebase)

---

## Macroscope Fallback (CodeRabbit Rate Limit Recovery)

When CodeRabbit is rate-limited on GitHub, fall back to Macroscope for code review. Macroscope is **disabled by default** on all repos — it only runs when explicitly triggered via PR comment.

### When to trigger Macroscope
Trigger Macroscope when **any** of these are true — check ALL of them every polling cycle:
- **🚀 FAST PATH (check every cycle):** The commit's check-runs or statuses API shows CodeRabbit rate limiting (see "Fast-path rate limit detection" in Polling above). This catches rate limits within ~60-120 seconds — **trigger Macroscope immediately, do not wait 8 minutes.**
- **⏱️ SLOW PATH (8-minute timeout):** 8 minutes have passed since pushing or triggering `@coderabbitai full review` and no review content has appeared. This fires regardless of whether you see an explicit rate-limit signal.
- CR's review comment explicitly mentions rate limiting or throttling
- CR's issue comment (on `issues/{N}/comments`) contains the text "Rate limit exceeded"
- CR posts a "✅ Actions performed" ack but **no actual review body or inline comments appear within 8 minutes** — the ack alone is NOT a review

> **⚠️ THE #1 SUBAGENT FAILURE MODE:** Agents see the "✅ Actions performed" ack and interpret it as "CR is reviewing, keep waiting." But when CR is rate-limited, it posts the ack and then **never delivers the actual review**. The result: the agent polls forever, waiting for a review that will never come. **If 8 minutes pass after the ack with no review content, CR is rate-limited — trigger Macroscope immediately.**

### Triggering Macroscope review
When a CodeRabbit rate limit is detected:

1. **Post a review request on the PR:**
   ```
   gh pr comment <PR_NUMBER> --body "@macroscope-app review"
   ```

2. **Poll for Macroscope's response** using the same polling pattern as CodeRabbit:
   - Poll every 60 seconds via `gh api` for new review comments from `macroscope-app[bot]`
   - Check `repos/{owner}/{repo}/pulls/{N}/reviews?per_page=100` and `repos/{owner}/{repo}/issues/{N}/comments?per_page=100`
   - Timeout after **10 minutes** — if no response, fall back to **self-review** and inform the user that both CR and Macroscope are unavailable

3. **Process Macroscope findings** the same way as CR findings:
   - Fix all valid findings in a single commit
   - **Reply to every Macroscope comment thread** confirming the fix or explaining why it was declined. Use the same `gh api` reply pattern as CR:
     - For inline review comments: `gh api repos/{owner}/{repo}/pulls/comments/{id}/replies -f body="Fixed in \`abc1234\`: <what changed>"`
     - For issue-level comments: `gh api repos/{owner}/{repo}/issues/{N}/comments -f body="@macroscope-app Fixed: <summary of all fixes>"`
   - Pushing a code fix does NOT resolve a comment thread — you must post an explicit reply. Unreplied threads show as unresolved in the PR.
   - Push once (single commit for all fixes)

4. **Use 👍 or 👎 reactions** on Macroscope comments to provide feedback (same as CR workflow)

### Important constraints
- **Never run both reviewers simultaneously on the same push.** Trigger Macroscope only after CR fails to deliver a review within 8 minutes.
- **Macroscope has no CLI.** It only operates via GitHub PR comments — there is no local pre-push review fallback from Macroscope.
- **Macroscope counts as 1 of the 2 required clean reviews**, but at least 1 must come from CodeRabbit (see Completion criteria above).

### After Macroscope: Always Try CR Next
After fixing Macroscope findings and pushing a new commit:
1. **Do NOT wait 15 minutes.** The push creates a new commit with fresh check-runs — the old "Review rate limit exceeded" was on the previous SHA and is irrelevant. CR auto-triggers on every push, so the new commit gets a fresh CR review attempt.
2. Enter the normal polling loop on the **new** commit's SHA (fast-path + 8-minute slow-path).
3. On each poll cycle, check the **new** commit's check-runs for rate limit (fast path). The new commit won't have a stale rate-limit message — it's a clean slate.
4. If CR reviews successfully → process findings normally. This counts toward the required "at least 1 CR review."
5. If CR rate-limits again on the new commit (fast-path detects within ~2 min) → trigger Macroscope again.
6. **The alternation is automatic:** push → try CR (fresh SHA) → rate-limited? → Macroscope → fix + push (new SHA) → try CR → etc. Each push gives CR a fresh chance.

> **The 15-minute wait only applies when requesting a re-review of the SAME SHA** (e.g., `@coderabbitai full review` without pushing new code). If you pushed new code, skip the wait — the push is the trigger.

---

## Self-Review Fallback

When CodeRabbit is unavailable and Macroscope cannot help (non-rate-limit timeout, CLI failure, neither tool configured), Claude performs its own review as a last-resort fallback. This is not a replacement for CR or Macroscope — it's a safety net so the flow doesn't break.

### When to trigger
- CR CLI hangs or errors out twice during the local review loop
- Both CR and Macroscope are unavailable on GitHub (CR didn't deliver within 8 min + Macroscope timed out after 10 min)
- Neither CR nor Macroscope is configured for the repo

### How to self-review
Review the full diff (`git diff main...HEAD`) and check for:
1. **Bugs** — logic errors, off-by-one, null/undefined access, race conditions
2. **Security** — SQL injection, XSS, secrets in code, unsafe input handling
3. **Error handling** — missing try/catch, unhandled promise rejections, silent failures
4. **Types** — wrong types, missing null checks, implicit any
5. **Naming & clarity** — misleading names, dead code, confusing control flow
6. **Edge cases** — empty arrays, zero values, missing fields, boundary conditions

### Output format
List findings the same way you would process CR findings: verify each against the code, fix valid issues, and note what you checked. If no issues found, that counts as a clean pass for the exit criteria.

### Important
- Self-review is a **fallback**, not a substitute. When CR is available, always prefer it.
- Self-review counts toward the "two consecutive clean reviews" exit criteria only when CR is genuinely unavailable.
- If CR comes back online mid-flow (e.g., it comments on the PR after you've moved on), process those findings in the next round.

---

## Subagent Context

When spawning subagents via the Task tool, **always pass the FULL contents of this CLAUDE.md file into the subagent's prompt.** Subagents do not automatically inherit CLAUDE.md context — they only see what you put in their prompt. Read this file via `cat ~/.claude/CLAUDE.md` and include the entire output in the subagent's task description. Do NOT summarize, excerpt, or paraphrase — pass the complete file. Without the full instructions, subagents will miss critical workflow steps (Macroscope fallback, ack-vs-completion detection, reply requirements) and improvise their own broken approach.

### Subagent Task Decomposition (Token Safety)

Subagents have a hardcoded **32K output token limit** that cannot be configured ([known Claude Code limitation](https://github.com/anthropics/claude-code/issues/25569)). A single subagent that reads 10-20 CR findings, fixes code, pushes, replies to every thread, AND polls for the next review will exhaust its token budget and die mid-poll. To prevent this, break PR lifecycle work into sequential phases:

**Phase A: Fix + Push** (heaviest — uses most tokens)
- Read CR/Macroscope findings from GitHub API
- Read affected source files
- Fix all valid findings + fix lint/CI failures
- Commit all fixes in ONE commit, push once
- Reply to all review comment threads
- **EXIT after push — do not enter polling loop**

**Phase B: Review Loop** (lighter — incremental)
- Poll for new CR review (fast-path + 8-minute slow-path Macroscope trigger)
- If CR/Macroscope posts new findings: fix, commit, push, reply (same as Phase A but smaller scope)
- If clean pass: trigger one more `@coderabbitai full review` for confirmation
- **EXIT after confirming clean or after fixing one round**

**Phase C: Merge Prep** (lightest)
- Verify 2 consecutive clean reviews achieved
- Read PR body, verify all acceptance criteria against final code
- Check off all boxes
- Report ready for merge

**Orchestration rules:**
- Parent agent launches Phase A subagents (can run in parallel across different PRs)
- When Phase A completes, parent launches Phase B for that PR
- When Phase B reports clean, parent launches Phase C
- **Stagger Phase B launches:** max 3 PRs entering review loop simultaneously (avoids burning the shared 8 reviews/hour CR quota in one burst)
- Use judgment on small PRs: if CR only found 1-2 findings, a single subagent may handle the full lifecycle without hitting token limits

### Subagent Health Monitoring (MANDATORY for parent agents)

The user has no visibility into subagent failures. If a subagent runs out of tokens or times out, the parent agent is the only one who knows — and if the parent doesn't report it, the user won't discover the failure until they manually check GitHub 15-20 minutes later. **This is unacceptable.**

**Monitoring rules for parent agents:**
1. **Poll subagent status every ~60 seconds.** When running subagents in the background, check their status regularly. Do not fire-and-forget.
2. **Report failures immediately.** If a subagent exits with an error, times out, or returns without completing its task, tell the user right away. Include:
   - Which PR / issue the subagent was working on
   - What phase it was in (A/B/C)
   - How it failed (token exhaustion, timeout, error, incomplete work)
   - What was left undone
3. **Report success too.** When a subagent completes its phase successfully, give the user a brief status update (e.g., "Phase A complete for PR #619 — fixes pushed, entering Phase B").
4. **Detect silent failures.** A subagent that returns a result but didn't actually push code or complete its assigned task has silently failed. Check the subagent's output against what it was supposed to do before marking it as complete.
5. **Never assume success.** If a subagent was supposed to push code, verify the push happened (e.g., check `git log` or `gh pr view` for the expected commit). If it was supposed to reply to review threads, verify the replies exist.

**What to tell the user on failure:**
> "⚠️ Subagent for PR #N (Phase B) failed — ran out of tokens during CR polling. The last push was commit `abc1234`. CR review is pending but unprocessed. Want me to respawn a new agent to continue, or would you like to handle it?"

The user should never have to discover a stalled PR by checking GitHub manually.

### Mandatory Subagent Review Protocol (COPY INTO EVERY SUBAGENT PROMPT)

Since subagents receive the full CLAUDE.md (see above), this section serves as a **quick-reference summary** of the review protocol. The full details are in the sections above — this summary exists so subagents can quickly locate the critical steps without scanning the entire file.

```
## GitHub Review Loop — Quick Reference (details in full CLAUDE.md above)

After pushing code and creating/updating a PR, follow this EXACT sequence:

### Step 1: Wait for CR review (fast-path check every cycle, 8-min slow-path max)
- Poll every 60s on all 3 endpoints (per_page=100):
  - `repos/{owner}/{repo}/pulls/{N}/reviews?per_page=100`
  - `repos/{owner}/{repo}/pulls/{N}/comments?per_page=100`
  - `repos/{owner}/{repo}/issues/{N}/comments?per_page=100`
- Filter by `coderabbitai[bot]` (with [bot] suffix)
- EVERY cycle, check commit status for rate limit (FAST PATH):
  `gh api "repos/{owner}/{repo}/commits/{SHA}/check-runs" --jq '.check_runs[] | select(.name == "CodeRabbit")'`
  If check shows "rate limit" in output.title with conclusion "failure" → Macroscope IMMEDIATELY.
  If check-runs empty, also check: `gh api "repos/{owner}/{repo}/commits/{SHA}/statuses"`

### Step 2: After 8 minutes with no review → trigger Macroscope (NO EXCEPTIONS)
If 8 minutes pass and CR has not delivered review content, trigger Macroscope.
It does NOT matter whether you see an explicit rate-limit signal.
The "✅ Actions performed" ack means CR STARTED — it is NOT a review.
If you see the ack but no review within 8 minutes, CR failed to deliver. Move to Step 3.

### Step 3: Trigger Macroscope
1. Post: `gh pr comment <PR_NUMBER> --body "@macroscope-app review"`
2. Poll every 60s for `macroscope-app[bot]` comments on the same 3 endpoints
3. Timeout after 10 minutes — if no response, do a self-review instead
4. Process Macroscope findings same as CR: fix all valid findings in one commit, push once
5. Reply to EVERY Macroscope comment thread confirming the fix:
   - Inline comments: `gh api repos/{owner}/{repo}/pulls/comments/{id}/replies -f body="Fixed in \`SHA\`: <what changed>"`
   - Issue comments: `gh api repos/{owner}/{repo}/issues/{N}/comments -f body="@macroscope-app Fixed: <summary>"`
   Pushing code does NOT resolve threads — you MUST post explicit replies.

### After Macroscope fix+push: CR gets a fresh chance automatically
Pushing creates a new SHA with clean check-runs. CR auto-triggers on push.
Do NOT wait 15 minutes. Enter the normal polling loop on the new SHA.
The 15-min wait only applies to `@coderabbitai full review` on the SAME SHA.

### Step 4: Get 2 clean reviews for merge readiness
Valid combinations (at least 1 must be from CR):
- ✅ 2 clean CodeRabbit reviews
- ✅ 1 clean Macroscope + 1 clean CodeRabbit
- ✅ 1 clean self-review + 1 clean CodeRabbit
- ❌ 2 Macroscope only (need at least 1 CR)
- ❌ 2 self-reviews only (need at least 1 CR)

After Macroscope or self-review, wait 15 min then re-trigger `@coderabbitai full review`.
If CR is still rate-limited after 15 min, tell the user and stop — do not loop forever.
```