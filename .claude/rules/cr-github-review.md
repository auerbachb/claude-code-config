## GitHub CodeRabbit Review Loop (Fallback)
- note code rabbit is called cr or CR for short

> **Always:** Poll all 3 endpoints + check-runs every cycle. Use `per_page=100`. Filter by `coderabbitai[bot]`. Batch fixes into one commit. Reply to every thread. Resolve threads via GraphQL.
> **Ask first:** Merging — always ask the user.
> **Never:** Poll only 1-2 endpoints. Use bare `coderabbitai` without `[bot]`. Push per-finding. Trigger `@coderabbitai full review` more than twice per PR per hour. Trigger Greptile proactively (only on CR failure). Merge without meeting the merge gate (2 clean CR or Greptile severity gate — see greptile.md).

> **This is the fallback review workflow.** It runs after you push and create a PR. If the local review loop was thorough, CR should find few or no issues here. But edge cases exist (e.g., CI-only context, cross-file interactions the local review missed), so always let this loop run.

**Prerequisite:** Before entering this loop, check if the repo uses CodeRabbit (look for `.coderabbit.yaml` at the repo root, or check if CodeRabbit has ever commented on PRs via `gh api repos/{owner}/{repo}/pulls --jq '.[].number' | head -5 | xargs -I{} gh api repos/{owner}/{repo}/pulls/{}/reviews --jq '.[].user.login' | grep -q 'coderabbitai\[bot\]'`). If CodeRabbit is not configured for the repo, skip this workflow.

After pushing a commit to a PR, automatically enter the CR review loop:

### Rate Limits (Pro Tier)
- **8 PR reviews per hour** — each push to a PR branch consumes one review. So does each `@coderabbitai full review` trigger.
- **50 chat interactions per hour** — each `@coderabbitai` comment (plan, review, resume, etc.) counts.
- **Hitting the limit makes things worse:** CR throttles further, retries reset the cooldown window, and polling burns Claude tokens for nothing.

### Rate-Limit-Aware Behavior
- **Batch fixes into a single commit before pushing.** If CR found 4 issues, fix all 4 in one commit — don't push 4 separate commits (that's 4 reviews consumed vs. 1).
- **Never trigger `@coderabbitai full review` more than twice per PR per hour.** After 2 explicit triggers with no response, stop and tell the user CR may be rate-limited.
- **When multiple agents are working in parallel on separate PRs**, each push consumes a review from the shared 8/hour pool. Coordinate: stagger pushes when possible, and never have more than 3-4 PRs triggering CR reviews in the same hour.
- **If CR responds with "Reviews paused" or rate-limit language**, do NOT retry immediately. Fall back to **Greptile** (see greptile rules). If Greptile is also unavailable, fall back to **self-review**.

### Polling
- Poll every 60 seconds for new CodeRabbit comments/reviews on the PR
- **Always use `per_page=100` on all GitHub API calls.** The default `per_page=30` will silently miss reviews/comments when a PR exceeds 30 total. Example: `gh api repos/{owner}/{repo}/pulls/{N}/reviews?per_page=100`. This applies to all three endpoints below.
- **Poll ALL THREE endpoints every cycle.** These are distinct GitHub API endpoints that return different data:
  1. `repos/{owner}/{repo}/pulls/{N}/reviews` — review objects (approve, request changes, review-level comments)
  2. `repos/{owner}/{repo}/pulls/{N}/comments` — inline comments on specific lines of code in the diff
  3. `repos/{owner}/{repo}/issues/{N}/comments` — **main PR conversation thread** (where CR posts its summary review, the "Actions performed" ack, and general findings)
  - **The third endpoint (`issues/` not `pulls/`) is important.** When CR reviews with findings, it posts review objects on `pulls/{N}/reviews` (which you'll see). But CR also posts its summary and the "Actions performed" ack as issue comments on `issues/{N}/comments`. Missing this endpoint means you'll catch reviews with findings but miss the ack and summary — causing indefinite polling on **clean passes** where CR has no findings to post as review objects.
- **Check the commit status on EVERY poll cycle** — this serves two purposes:
  ```bash
  gh api "repos/{owner}/{repo}/commits/{SHA}/check-runs" \
    --jq '.check_runs[] | select(.name == "CodeRabbit") | {name, status, conclusion, title: .output.title}'
  ```
  If check-runs returns empty for CodeRabbit, fall back to the commit statuses endpoint:
  ```bash
  gh api "repos/{owner}/{repo}/commits/{SHA}/statuses" \
    --jq '.[] | select(.context | test("CodeRabbit"; "i")) | {context, state, description}'
  ```
  - **Completion signal:** `status: "completed"` with `conclusion: "success"` = review done (visible as "CodeRabbit — Review completed" in the PR's CI checks box). This is the definitive signal, especially for clean passes.
  - **Fast-path rate limit detection:** If EITHER endpoint shows rate limiting — check-run has `conclusion: "failure"` with `output.title` containing "rate limit" (case-insensitive), OR commit status has `state: "failure"`/`state: "error"` with `description` containing "rate limit" — **trigger Greptile IMMEDIATELY.** Do not wait 7 minutes. This catches rate limits within ~60-120 seconds of pushing. Sticky assignment applies (see below).
  - **Do NOT confuse the ack with completion.** The "Actions performed — Full review triggered" issue comment means CR **started** reviewing — it does NOT mean the review is finished. The CI check "CodeRabbit — Review completed" is what signals actual completion.
- **CR's GitHub username is `coderabbitai[bot]` (with the `[bot]` suffix).** Always filter by `.user.login == "coderabbitai[bot]"` — NOT bare `coderabbitai`. Using the wrong username will silently miss all CR comments.
- Track the **highest comment ID** seen so far across all three endpoints. Any comment from `coderabbitai[bot]` with an ID greater than the watermark is a new finding that needs attention.
- If CR responds, process immediately
- **Hard timeout: 7 minutes.** If CR has not delivered a review after 7 minutes of polling, stop waiting and trigger **Greptile**. Do NOT keep polling — it wastes tokens and risks session timeout. Sticky assignment applies (see below).

### Timeout & Fallback — Two Trigger Paths to Greptile

- **Fast path (~1-2 min):** The check-runs or commit statuses API shows "Review rate limit exceeded" -> trigger Greptile immediately on that poll cycle. Do not wait.
- **Slow path (7 min):** No rate-limit signal visible, but CR has not delivered review content after 7 minutes -> trigger Greptile. The distinction between "rate-limited" and "slow" is irrelevant at this point — the action is the same.
- **Sticky Greptile assignment:** Once either trigger path fires for a PR, that PR stays on Greptile permanently (see `greptile.md` "Sticky Assignment" for full details). Do not switch back to CR.
- **If Greptile also fails** (5-minute timeout with no response): fall back to **self-review**.
- Tell the user which fallback was used and why.

### Before Requesting Any New Review (MANDATORY — applies to ALL agents)

> **THE #2 SUBAGENT FAILURE MODE:** A new subagent picks up a PR, sees it needs a review, and immediately posts `@coderabbitai full review` — while the PR still has unresolved findings from the previous round sitting right above the request. CR sees this and reasonably asks "why are you requesting a new review when the last one had unresolved comments?" This wastes a review cycle and makes the bot look broken.

**Before triggering `@coderabbitai full review` or entering the polling loop, ALWAYS do this first:**

1. **Scan all existing review comments on the PR** by fetching all three endpoints:
   - `repos/{owner}/{repo}/pulls/{N}/comments?per_page=100` (inline comments)
   - `repos/{owner}/{repo}/pulls/{N}/reviews?per_page=100` (review-level comments)
   - `repos/{owner}/{repo}/issues/{N}/comments?per_page=100` (PR conversation)
2. **Identify unresolved findings** — any comment from `coderabbitai[bot]` or `greptile-apps[bot]` that:
   - Has no reply confirming a fix
   - Points to code that hasn't been changed since the comment was posted
   - Is not marked as resolved/outdated
3. **If unresolved findings exist: fix them first.** Read the findings, fix the code, commit, push, reply to each thread — then let CR auto-review the new push. Do NOT request a fresh review on top of unaddressed feedback.
4. **If all findings are already addressed:** Verify by reading the current code, then proceed with requesting a review.

### Resolving Comment Threads on GitHub

GitHub does not auto-resolve PR review comments when the fix touches different lines than where the comment was made (which is common — e.g., a comment about a missing null check on line 42 gets fixed by adding a guard on line 38). **You must explicitly resolve these threads.**

**How to resolve a comment thread after fixing it:**
1. **Reply to the thread** confirming the fix (this is already required — see processing steps below). **Note:** The inline reply endpoint may 404 for non-diff comments — see "Processing CR Feedback" step 5 for the full fallback procedure.
2. **Resolve the thread** via the GitHub API:
   ```bash
   gh api graphql -f query='mutation { minimizeComment(input: {subjectId: "<node_id>", classifier: RESOLVED}) { minimizedComment { isMinimized } } }'
   ```
   Or if the comment is a pull request review thread, use:
   ```bash
   gh api graphql -f query='mutation { resolveReviewThread(input: {threadId: "<thread_node_id>"}) { thread { isResolved } } }'
   ```
   To get the thread ID, fetch the review threads:
   ```bash
   gh api graphql -f query='query { repository(owner: "{owner}", name: "{repo}") { pullRequest(number: {N}) { reviewThreads(first: 100) { nodes { id isResolved comments(first: 1) { nodes { body author { login } } } } } } } }'
   ```
3. **Check that all threads are resolved** before requesting a new review. Unresolved threads signal to CR (and to human reviewers) that work is still outstanding.

### Processing CR Feedback
1. Fetch the latest CR comments via `gh api`
2. Parse each finding from CR's summary/review
3. Verify each finding against the actual file before applying
4. Fix **all valid findings**, then commit and push **once** (one commit = one review consumed)
5. **Reply to every CR comment thread** acknowledging the fix (e.g. "Fixed in `abc1234`: <what changed>"). Pushing a code fix does NOT resolve a GitHub comment thread — you must post an explicit reply. Unreplied threads show as unresolved in the PR and block merge.

   **How to reply — with 404 fallback:**
   - **First, try the inline reply endpoint:** `gh api repos/{owner}/{repo}/pulls/comments/{id}/replies -f body="..."`. This works for inline diff comments (comments attached to specific lines of code).
   - **If the reply endpoint returns 404:** The comment may be a review-level comment or a PR conversation comment rather than an inline diff comment — the `/replies` sub-resource only exists on diff-positioned comments. Fall back to posting a **PR-level comment** instead:
     ```bash
     gh pr comment N --body "@coderabbitai Fixed in \`abc1234\`: <what changed>. (Re: <brief description of the finding>)"
     ```
     Always include `@coderabbitai` so CR reads the reply. Include enough context (quote or paraphrase the finding) so CR can correlate the fix with the original comment.
   - **When to use which:**
     - Inline diff comments (`pulls/{N}/comments` endpoint, have `path` and `line` fields) → use `/replies` endpoint
     - Review-level or PR conversation comments (`pulls/{N}/reviews` or `issues/{N}/comments` endpoints) → use `gh pr comment` with `@coderabbitai` mention
     - If unsure, try `/replies` first — the 404 is harmless and tells you to fall back
6. **Resolve the comment thread** after replying (see "Resolving Comment Threads on GitHub" above). A reply alone does not mark the thread as resolved — you must explicitly resolve it via the GraphQL API.
7. **@mention CR in PR-level comments.** When posting general PR comments (via `gh pr comment`), always include `@coderabbitai` in the body so CR reads them. CR only reliably processes comments where it is explicitly mentioned — untagged PR comments are often ignored. This applies to fix summaries, duplicate-finding replies posted at the PR level, and any context you want CR to incorporate into its next review.
8. Resume polling for CR's next response
9. Repeat until CR has no more findings

> **CRITICAL: "Duplicate" findings are NOT resolved findings.**
> CR labels a comment "duplicate" when it raised the same issue in a previous round — this does **not** mean the issue was fixed. Before dismissing any CR comment (actionable, duplicate, nitpick, or otherwise), **always verify the finding against the actual code**. Only dismiss it if the current code already addresses it. Never assume a prior round resolved something without checking the file.

### Autonomy Boundaries
- **Fix autonomously:** All files unless the user instructed otherwise

### Completion

**Step 1 — Confirm reviews are clean (merge gate):**

> Canonical merge-gate definition is in `greptile.md` "Detecting a Clean Greptile Pass". Repeated here for subagent self-containment.

The merge gate depends on which reviewer owns the PR:

**CR-only path** (Greptile was never triggered for this PR):
- 2 clean CR reviews required. The second is a confirmation pass — CR's completion signal is unreliable (it may mark the check as "completed" but post findings minutes later), so a second clean pass is needed.
- If CR responds with no findings after a round of fixes, post `@coderabbitai full review` one more time to confirm.
- **After 2 failed re-triggers on the same SHA**, stop and tell the user. Do not loop forever.

**Greptile path** (Greptile was triggered at any point for this PR):
- Severity-gated merge gate — see `greptile.md` "Detecting a Merge-Ready Greptile Review" for authoritative rules.
- Stay on Greptile — do not switch back to CR.

**If both CR and Greptile are down** (CR rate-limited/timed out + Greptile 5-min timeout): perform a self-review for risk reduction. A clean self-review does NOT satisfy the merge gate — report the blocker to the user.

- **How to detect a clean CR pass:** After triggering `@coderabbitai full review`, watch for these signals in order:
  1. **Ack (review started):** CR posts an issue comment (on `issues/{N}/comments`) with "Actions performed — Full review triggered." This means CR **started** the review — it is NOT a completion signal.
  2. **Completion (review finished):** The commit status check for CodeRabbit shows `status: "completed"` with `conclusion: "success"` (visible as "CodeRabbit — Review completed" in the PR's CI checks). This is the **definitive completion signal**.
  3. **Clean = completed + no new findings:** Once the CI check shows completed, check all three comment endpoints for any new findings posted after the ack. If there are none, the review is a clean pass. You do NOT need to keep polling to the 7-minute timeout once the CI check is green and no findings appeared.
- Once the merge gate is met, proceed immediately to Step 2.

**Step 2 — Verify every Test Plan checkbox (MANDATORY — do NOT skip):**
> This is the **immediate next step** after the merge gate is met. Do not ask the user about merging until this is done.
>
> 1. Fetch the PR body via `gh pr view N --json body`
> 2. Parse **every** checkbox in the **Test plan** section of the PR description
> 3. For each item, read the relevant source file(s) and verify the criterion is met
> 4. Check off passing items by editing the PR body (replace `- [ ]` with `- [x]`)
> 5. If any item fails, fix the code first — do NOT offer to merge with unchecked boxes
> 6. Only after **ALL** boxes are checked, proceed to Step 3
>
> Re-run after every CR round. If additional code changes were made during the CR loop (e.g. fixes from CR rounds after the initial AC pass), you must re-verify ALL AC items against the final code. AC verification reflects the code **at merge time**, not the code at some earlier checkpoint.
>
> Skipping this step is a **blocking failure** — the user should never see unchecked AC boxes when asked about merge.

**Step 3 — Ask the user about merging:**
- Ask the user: "Reviews are clean, all AC verified and checked off. Want me to squash and merge and delete the branch, or do you want to review the diff yourself first?"
- Always use **squash and merge** (never regular merge or rebase)
