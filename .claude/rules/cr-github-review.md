## GitHub CodeRabbit Review Loop (Fallback)
- note code rabbit is called cr or CR for short

> **Always:** Poll all 3 endpoints + check-runs every cycle. Use `per_page=100`. Filter by `coderabbitai[bot]`. Batch fixes into one commit. Reply to every thread. Resolve threads via GraphQL. **Enter the polling loop immediately after push — do NOT ask.**
> **Ask first:** Merging — always ask the user. **Nothing else in this workflow requires permission.**
> **Never:** Poll only 1-2 endpoints. Use bare `coderabbitai` without `[bot]`. Push per-finding. Trigger `@coderabbitai full review` more than twice per PR per hour. Trigger Greptile proactively (only on CR failure). Merge without meeting the merge gate (see `cr-merge-gate.md` for the authoritative definition). **Ask "want me to poll?" or "should I process this feedback?" — just do it.**

> **This is the fallback review workflow.** It runs after you push and create a PR. If the local review loop was thorough, CR should find few or no issues here. But edge cases exist (e.g., CI-only context, cross-file interactions the local review missed), so always let this loop run.

**Prerequisite:** Before entering this loop, check if the repo uses CodeRabbit (look for `.coderabbit.yaml` at the repo root, or check if CodeRabbit has ever commented on PRs via `gh api repos/{owner}/{repo}/pulls --jq '.[].number' | head -5 | xargs -I{} gh api repos/{owner}/{repo}/pulls/{}/reviews --jq '.[].user.login' | grep -q 'coderabbitai\[bot\]'`). If CodeRabbit is not configured for the repo, skip this workflow.

After pushing a commit to a PR, **automatically** enter the CR review loop. Do not ask "want me to poll for reviews?" — polling is mandatory and immediate.

### Rate Limits & Behavior (Pro Tier)
- **8 PR reviews/hour** (each push or `@coderabbitai full review` consumes one), **50 chat interactions/hour**.
- **Batch fixes into ONE commit** before pushing — 4 fixes = 1 review consumed, not 4.
- **Max 2 explicit `@coderabbitai full review` triggers per PR per hour.** After 2 with no response, tell the user CR may be rate-limited.
- **Parallel agents:** stagger pushes; max 3-4 PRs triggering CR reviews in the same hour.
- **"Reviews paused" or rate-limit language:** fall back to **BugBot** (see `bugbot.md`). If BugBot also fails, fall back to **Greptile** (see `greptile.md`). If Greptile unavailable, fall back to **self-review**.

### Polling
- Poll every 60 seconds. Always use `per_page=100` on all GitHub API calls.
- **Poll ALL THREE endpoints every cycle:**
  1. `repos/{owner}/{repo}/pulls/{N}/reviews` — review objects
  2. `repos/{owner}/{repo}/pulls/{N}/comments` — inline diff comments
  3. `repos/{owner}/{repo}/issues/{N}/comments` — PR conversation (summary, ack, general findings). Missing this endpoint causes indefinite polling on clean passes.
- **Check commit status every cycle.** Query `repos/{owner}/{repo}/commits/{SHA}/check-runs` filtered to `name == "CodeRabbit"`; fallback: `/statuses` filtered to `context ~ "CodeRabbit"`. Full commands: `.claude/reference/cr-polling-commands.md`.
  - **Completion signal:** `status: "completed"` + `conclusion: "success"` = review done. Definitive signal.
  - **Fast-path rate limit:** check-run `conclusion: "failure"` with "rate limit" in `output.title`, OR status `state: "failure"`/`"error"` with "rate limit" in `description` — **check BugBot first** (see `bugbot.md`). If BugBot already posted a review, use it. If not, wait up to 5 min for BugBot. If BugBot also times out, trigger Greptile. Sticky assignment applies at each tier.
  - **Ack ≠ completion.** "Actions performed — Full review triggered" = CR started. "CodeRabbit — Review completed" CI check = CR finished.
- **CR username:** `coderabbitai[bot]` (with `[bot]` suffix). Filter by `.user.login == "coderabbitai[bot]"` — NOT bare `coderabbitai`.
- **Watermark:** Track highest review ID from `pulls/{N}/reviews`. New reviews can have inline comment IDs lower than previous reviews (different ID sequences). For `issues/{N}/comments`, track by comment ID.
- **Hard timeout: 7 minutes.** No CR review after 7 min → check BugBot (see `bugbot.md`). If BugBot already posted a review, use it. If not, wait up to 5 min for BugBot. If BugBot also times out, trigger Greptile. Sticky assignment applies at each tier.

### CI Health Check (MANDATORY — every poll cycle)

**Check ALL check-runs every poll cycle — not just CodeRabbit.** CI failures (test, lint, build, audit, gitleaks) are independent of CR review status. Query `repos/{owner}/{repo}/commits/{SHA}/check-runs?per_page=100` and inspect `{name, status, conclusion}`. Full command: `.claude/reference/cr-polling-commands.md`.

**Rules:**
- **Blocking conclusions:** `failure`, `timed_out`, `action_required`, `startup_failure`, `stale`. If ANY check-run has one of these, **investigate immediately.** (`cancelled`, `neutral`, `skipped` are non-blocking.) Read the output via `gh api repos/{owner}/{repo}/check-runs/{CHECK_RUN_ID} --jq .output.summary`.
  - Test/lint/build failure: fix, commit, push before continuing the review loop.
  - Transient/infra failure (e.g., `timed_out`, `startup_failure`): note it, retry with a no-op commit if needed.
- CI failures block merge independently of CR — a PR with passing CR but failing tests is not merge-ready. Report pass/fail summary to the user: "CI: 5/6 passed, `test` failed — investigating."

### Timeout & Fallback — Three-Tier Review Chain

**Review chain:** CR (primary) → BugBot (second tier, free) → Greptile (last resort, paid) → self-review (emergency).

BugBot auto-runs on every push — poll for its reviews alongside CR. When CR fails, check BugBot before triggering Greptile.

- **Fast path (~1-2 min):** CR rate-limit detected → check if BugBot (`cursor[bot]`) already posted a review. If yes, use BugBot review (assign `reviewer: bugbot`). If no, wait up to 5 min for BugBot. If BugBot times out, trigger Greptile (budget gate applies — see `greptile.md` "Daily Budget").
- **Slow path (7 min):** CR has not delivered review content after 7 min → same BugBot-first check as fast path.
- **Sticky assignment:** CR fail → BugBot owns the PR. If BugBot also fails → Greptile owns permanently. Do not switch back up the chain.
- **If all three fail** (CR rate-limited + BugBot 5-min timeout + Greptile 5-min timeout): fall back to **self-review**. Self-review does NOT satisfy the merge gate.
- Tell the user which fallback was used and why.

### Before Requesting Any New Review (MANDATORY — applies to ALL agents)

> **THE #2 SUBAGENT FAILURE MODE:** A new subagent picks up a PR, sees it needs a review, and immediately posts `@coderabbitai full review` — while the PR still has unresolved findings from the previous round sitting right above the request. CR sees this and reasonably asks "why are you requesting a new review when the last one had unresolved comments?" This wastes a review cycle and makes the bot look broken.

**Before triggering `@coderabbitai full review` or entering the polling loop, ALWAYS do this first:**

1. **Scan all existing review comments on the PR** by fetching all three endpoints:
   - `repos/{owner}/{repo}/pulls/{N}/comments?per_page=100` (inline comments)
   - `repos/{owner}/{repo}/pulls/{N}/reviews?per_page=100` (review-level comments)
   - `repos/{owner}/{repo}/issues/{N}/comments?per_page=100` (PR conversation)
2. **Identify unresolved findings** — any comment from `coderabbitai[bot]`, `cursor[bot]`, or `greptile-apps[bot]` that:
   - Has no reply confirming a fix
   - Points to code that hasn't been changed since the comment was posted
   - Is not marked as resolved/outdated
3. **If unresolved findings exist: fix them first.** Read the findings, fix the code, commit, push, reply to each thread — then let CR auto-review the new push. Do NOT request a fresh review on top of unaddressed feedback.
4. **If all findings are already addressed:** Verify by reading the current code, then proceed with requesting a review.

### Processing CR Feedback
1. Fetch latest CR comments via `gh api`, verify each finding against the actual file
2. Fix **all valid findings**, commit and push **once** (one commit = one review consumed)
3. **Reply to every thread** ("Fixed in `abc1234`: <what changed>"). Try inline reply first: `gh api repos/{owner}/{repo}/pulls/comments/{id}/replies -f body="..."`. On 404, fall back to `gh pr comment N --body "@coderabbitai Fixed in ..."` (always @mention CR in PR-level comments so CR reads them)
4. **Resolve each thread via GraphQL** after replying — replies alone don't resolve threads. Use `resolveReviewThread(threadId)`; fallback: `minimizeComment(subjectId, classifier: RESOLVED)`. Full mutations: `.claude/reference/graphql-thread-resolution.md`
5. **Verify all threads resolved** before requesting a new review
6. Resume polling; repeat until CR has no more findings

> **"Duplicate" findings are NOT resolved.** CR labels a comment "duplicate" when it raised the same issue before — this does NOT mean it was fixed. Always verify against actual code before dismissing any CR comment.

### Autonomy Boundaries
- **Fix autonomously:** All files unless the user instructed otherwise
- **Poll autonomously:** Enter and remain in the polling loop without asking — this is the default behavior after any push
- **Process feedback autonomously:** When CR/BugBot/Greptile posts findings, fix them immediately — do not ask "should I fix these?"
- **Trigger fallbacks autonomously:** BugBot on CR timeout, Greptile on BugBot timeout, self-review on Greptile timeout — these are automatic, not user-prompted

### Completion

**See `cr-merge-gate.md` for the authoritative merge gate definition** (Steps 1/1b/2/3: review gate, CI verification, AC checkbox verification, and user merge confirmation). All merge-related logic lives there — this file covers the review polling loop only.
