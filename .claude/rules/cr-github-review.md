## GitHub CodeRabbit Review Loop (Fallback)
- note code rabbit is called cr or CR for short

> **NEVER declare a PR done immediately after pushing a fix commit.** Every push triggers a new CR/BugBot/Greptile review — you MUST continue polling until you see the reviewer's response to the new SHA. "0 unresolved threads right now" ≠ merge gate met. The merge gate lives in `cr-merge-gate.md` and is the ONLY valid polling exit condition.
>
> **Always:** Poll all 3 endpoints + check-runs every cycle. Use `per_page=100`. Filter by `coderabbitai[bot]`. Batch fixes into one commit. Reply to every thread. Resolve threads via GraphQL. **Enter the polling loop immediately after push — do NOT ask.** Invoke `/fixpr` when any trigger condition fires (see "Per-cycle check" below).
> **Ask first:** Merging — always ask the user. **Nothing else in this workflow requires permission.**
> **Never:** Poll only 1-2 endpoints. Use bare `coderabbitai` without `[bot]`. Push per-finding. Trigger `@coderabbitai full review` more than twice per PR per hour. Trigger Greptile proactively (only on CR failure). Merge without meeting the merge gate (see `cr-merge-gate.md` for the authoritative definition). **Exit polling on "nothing unresolved right now" — the only valid exit is the merge gate.** **Ask "want me to poll?" or "should I process this feedback?" — just do it.**
>
> **This is the fallback review workflow.** It runs after you push and create a PR. If the local review loop was thorough, CR should find few or no issues here. But edge cases exist (e.g., CI-only context, cross-file interactions the local review missed), so always let this loop run.

**Prerequisite:** Before entering this loop, check if the repo uses CodeRabbit (look for `.coderabbit.yaml` at the repo root, or check if CodeRabbit has ever commented on PRs via `gh api repos/{owner}/{repo}/pulls --jq '.[].number' | head -5 | xargs -I{} gh api repos/{owner}/{repo}/pulls/{}/reviews --jq '.[].user.login' | grep -q 'coderabbitai\[bot\]'`). If CodeRabbit is not configured for the repo, skip this workflow.

After pushing a commit to a PR, **automatically** enter the CR review loop. Do not ask "want me to poll for reviews?" — polling is mandatory and immediate.

### Session-start / pre-review comment audit (MANDATORY)

Run this checklist BEFORE the first poll tick AND before triggering any new review (`@coderabbitai full review`, `@cursor review`, `@greptileai`). Applies on fresh push, session resume, and post-compaction re-entry. The "Before Requesting Any New Review" block is this section — there is no other.

> **Why:** A subagent that requests a fresh review on top of an unresolved thread wastes a review cycle and makes the bot look broken — CR reasonably asks "why the new review when the last one had unresolved comments?" This is the #2 subagent failure mode.

1. Fetch **all 3 comment endpoints** on the PR with `per_page=100`:
   - `repos/{owner}/{repo}/pulls/{N}/reviews`
   - `repos/{owner}/{repo}/pulls/{N}/comments`
   - `repos/{owner}/{repo}/issues/{N}/comments`
2. Identify any unresolved findings from `coderabbitai[bot]`, `cursor[bot]`, or `greptile-apps[bot]` (no reply confirming a fix, code unchanged since the comment, not marked outdated/resolved).
3. **If ANY unresolved findings exist: invoke `/fixpr` now.** `/fixpr` fixes, commits once, pushes, replies to every thread, resolves via GraphQL. Do NOT request a new review on top of unaddressed feedback.
4. **STOP condition:** do not proceed to the polling loop (or request a new review) until step 3 completes — either no unresolved findings, or `/fixpr` finished a pass.

### Per-cycle check (every 60 seconds)

Each poll cycle, for every open PR owned by this session, query everything listed in the "Polling" section below.

If **ANY** of the conditions below hold, invoke `/fixpr` and do NOT request a new review until `/fixpr` completes:

1. New findings from any bot (CR / BugBot / Greptile) since the last poll watermark
2. Any check-run with a blocking conclusion (`failure`, `timed_out`, `action_required`, `startup_failure`, `stale`)
3. `mergeStateStatus == "BEHIND"` (branch behind base, auto-rebase; `/fixpr` handles it)
4. `mergeable == "CONFLICTING"` (merge conflicts; `/fixpr` handles rebase + surfaces blockers)

> **Unresolved threads are NOT a trigger.** If unresolved threads remain after the last fix-commit push, keep polling for reviewer catch-up. See conditions 1–4 above.

**Exit polling ONLY when the merge gate (`cr-merge-gate.md`) is met.** "0 unresolved threads right now" is NOT an exit condition — see the trap note at the top of this file. After any `/fixpr` push, reset the watermark and keep polling for the reviewer's response to the new SHA.

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
- **Check merge metadata every cycle.** Query `mergeable` and `mergeStateStatus` via `gh pr view N --json mergeable,mergeStateStatus` — these drive `/fixpr` trigger conditions 3 and 4.
- **Check commit status every cycle.** Query `repos/{owner}/{repo}/commits/{SHA}/check-runs` filtered to `name == "CodeRabbit"`; fallback: `/statuses` filtered to `context ~ "CodeRabbit"`. Full commands: `.claude/reference/cr-polling-commands.md`.
  - **Completion signal:** `status: "completed"` + `conclusion: "success"` = review done. Definitive signal.
  - **Fast-path rate limit:** check-run `conclusion: "failure"` with "rate limit" in `output.title`, OR status `state: "failure"`/`"error"` with "rate limit" in `description` — **check BugBot first** (see `bugbot.md`). If BugBot already posted a review, use it. If not, wait up to 5 min **from push time** for BugBot. If BugBot also times out, trigger Greptile. Sticky assignment applies at each tier.
  - **Ack ≠ completion.** "Actions performed — Full review triggered" = CR started. "CodeRabbit — Review completed" CI check = CR finished.
- **CR username:** `coderabbitai[bot]` (with `[bot]` suffix). Filter by `.user.login == "coderabbitai[bot]"` — NOT bare `coderabbitai`.
- **Watermark:** Track highest review ID from `pulls/{N}/reviews`. New reviews can have inline comment IDs lower than previous reviews (different ID sequences). For `issues/{N}/comments`, track by comment ID.
- **Hard timeout: 7 minutes.** No CR review after 7 min → check BugBot (see `bugbot.md`). If BugBot already posted a review, use it. If not, trigger Greptile immediately (BugBot's 5-min window from push has already elapsed). Sticky assignment applies at each tier.

### CI Health Check (MANDATORY — every poll cycle)

**Check ALL check-runs every poll cycle — not just CodeRabbit.** CI failures (test, lint, build, audit, gitleaks) are independent of CR review status. Query `repos/{owner}/{repo}/commits/{SHA}/check-runs?per_page=100` and inspect `{name, status, conclusion}`. Full command: `.claude/reference/cr-polling-commands.md`.

**Rules:**
- **Blocking conclusions:** `failure`, `timed_out`, `action_required`, `startup_failure`, `stale`. If ANY check-run has one of these, **invoke `/fixpr` immediately — no permission required.** (`cancelled`, `neutral`, `skipped` are non-blocking.) `/fixpr` reads the output via `gh api repos/{owner}/{repo}/check-runs/{CHECK_RUN_ID} --jq .output.summary` and fixes deterministic failures.
  - Test/lint/build failure: `/fixpr` fixes, commits, pushes. Do NOT resume polling until CI is green on the new SHA.
  - Transient/infra failure (e.g., `timed_out`, `startup_failure`): `/fixpr` flags it; cannot auto-fix, user decides retry.
- CI failures block merge independently of CR — a PR with passing CR but failing tests is not merge-ready. Report pass/fail summary: "CI: 5/6 passed, `test` failed — invoking `/fixpr`."

### Timeout & Fallback — Three-Tier Review Chain

**Review chain:** CR (primary) → BugBot (second tier, free) → Greptile (last resort, paid) → self-review (emergency).

BugBot auto-runs on every push — poll for its reviews alongside CR. When CR fails (rate-limited or 7-min timeout), check BugBot before triggering Greptile; BugBot's 5-min timeout runs from push time, concurrent with CR's window. See `bugbot.md` and `greptile.md` for timing and trigger details.

- **Sticky assignment:** CR fail → BugBot owns the PR. If BugBot also fails → Greptile owns permanently. Do not switch back up the chain.
- **If all three fail** (CR rate-limited + BugBot 5-min timeout + Greptile 5-min timeout): fall back to **self-review**. Self-review does NOT satisfy the merge gate.
- Tell the user which fallback was used and why.

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
