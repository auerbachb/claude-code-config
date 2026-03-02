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

### Issues
- Every PR must link to a GitHub issue. If no issue exists before starting work, create one first.
- Use `Closes #N` in the PR body to auto-close the issue on merge.

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

### Exit criteria
- **Two consecutive clean local reviews** with no findings
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
- **If CR responds with "Reviews paused" or rate-limit language**, do NOT retry immediately. Wait at least 10 minutes, then post `@coderabbitai resume` followed by `@coderabbitai full review`. Only one retry — if still paused, inform the user.

### Polling
- Poll every 60 seconds for new CodeRabbit comments/reviews on the PR
- **⚠️ Always use `per_page=100` on all GitHub API calls.** The default `per_page=30` will silently miss reviews/comments when a PR exceeds 30 total. Example: `gh api repos/{owner}/{repo}/pulls/{N}/reviews?per_page=100`. This applies to all three endpoints below.
- **Poll ALL THREE endpoints every cycle.** These are distinct GitHub API endpoints that return different data:
  1. `repos/{owner}/{repo}/pulls/{N}/reviews` — review objects (approve, request changes, review-level comments)
  2. `repos/{owner}/{repo}/pulls/{N}/comments` — inline comments on specific lines of code in the diff
  3. `repos/{owner}/{repo}/issues/{N}/comments` — **main PR conversation thread** (where CR posts its summary review, the "✅ Actions performed" ack, and general findings)
  - **⚠️ The third endpoint (`issues/` not `pulls/`) is important.** When CR reviews with findings, it posts review objects on `pulls/{N}/reviews` (which you'll see). But CR also posts its summary and the "✅ Actions performed" ack as issue comments on `issues/{N}/comments`. Missing this endpoint means you'll catch reviews with findings but miss the ack and summary — causing indefinite polling on **clean passes** where CR has no findings to post as review objects.
- **Check the commit status to detect review completion** — this is the **primary completion signal**: `repos/{owner}/{repo}/commits/{SHA}/check-runs` (filter for `name == "CodeRabbit"` or `app.slug == "coderabbitai"`). When CR's check shows `status: "completed"` with `conclusion: "success"` (visible as "CodeRabbit — Review completed" in the PR's CI checks box), the review is done. This is the definitive signal, especially for clean passes where CR found no issues.
  - **⚠️ Do NOT confuse the ack with completion.** The "✅ Actions performed — Full review triggered" issue comment means CR **started** reviewing — it does NOT mean the review is finished. The CI check "CodeRabbit — Review completed" is what signals actual completion.
- **⚠️ CR's GitHub username is `coderabbitai[bot]` (with the `[bot]` suffix).** Always filter by `.user.login == "coderabbitai[bot]"` — NOT bare `coderabbitai`. Using the wrong username will silently miss all CR comments.
- Track the **highest comment ID** seen so far across all three endpoints. Any comment from `coderabbitai[bot]` with an ID greater than the watermark is a new finding that needs attention.
- If CR responds, process immediately
- **Poll for at least 10 minutes** (10 cycles) before giving up. CR regularly takes 6-8 minutes to review larger diffs — a 5-minute timeout will miss reviews that arrive at minute 6-7. Only after 10 minutes with no response, post `@coderabbitai full review` and resume polling for another **5 minutes** (5 cycles). Total wait ceiling is ~15 minutes. This second shorter window counts against the 8/hour review limit — be aware.

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

**Step 1 — Confirm CR is clean (2 consecutive clean full reviews):**
- If CR responds with no findings after a round of fixes, post `@coderabbitai full review` one more time to confirm.
- **How to detect a clean pass:** After triggering `@coderabbitai full review`, watch for these signals in order:
  1. **Ack (review started):** CR posts an issue comment (on `issues/{N}/comments`) with "✅ Actions performed — Full review triggered." This means CR **started** the review — it is NOT a completion signal.
  2. **Completion (review finished):** The commit status check for CodeRabbit shows `status: "completed"` with `conclusion: "success"` (visible as "CodeRabbit — Review completed" in the PR's CI checks). This is the **definitive completion signal**.
  3. **Clean = completed + no new findings:** Once the CI check shows completed, check all three comment endpoints for any new findings posted after the ack. If there are none, the review is a clean pass. You do NOT need to keep polling for the full 10 minutes once the CI check is green and no findings appeared.
- If CR has no findings on **2 consecutive** `full review` requests, the PR is clean. Proceed immediately to Step 2.

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

## Subagent Context

When spawning subagents via the Task tool, **always include the relevant CLAUDE.md instructions in the subagent's prompt.** Subagents do not automatically inherit CLAUDE.md context. If a subagent needs to follow any convention defined here (local CR review loop, GitHub CR polling, branching rules, AC verification, commit style, etc.), paste or summarize those specific sections into the subagent prompt. Without this, subagents will improvise their own approach instead of following the documented protocol.