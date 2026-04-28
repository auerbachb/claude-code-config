## GitHub CodeRabbit Review Loop (Fallback)

> **NEVER declare a PR done immediately after pushing.** Every push triggers a new CR/BugBot/Greptile review. Poll until `cr-merge-gate.md` is met; "0 unresolved threads" is not an exit condition.
>
> **Always:** Poll all 3 endpoints + check-runs every cycle. Use `per_page=100`. Filter by `coderabbitai[bot]`. Batch fixes into one commit. Reply to every thread. Resolve threads via GraphQL. **Enter the polling loop immediately after push — do NOT ask.** Invoke `/fixpr` when any trigger condition fires (see "Per-cycle check" below).
> **Ask first:** Merging — always ask the user. **Nothing else in this workflow requires permission.**
> **Never:** Poll only 1-2 endpoints. Use bare `coderabbitai` without `[bot]`. Push per-finding. Trigger `@coderabbitai full review` more than twice per PR per hour. Trigger Greptile proactively (only on CR failure). Merge without meeting the merge gate (see `cr-merge-gate.md` for the authoritative definition). **Exit polling on "nothing unresolved right now" — the only valid exit is the merge gate.** **Ask "want me to poll?" or "should I process this feedback?" — just do it.**
>
> **This fallback workflow runs after every push/PR.** Local review reduces findings; it does not replace GitHub review.

**Prerequisite:** Confirm the repo uses CodeRabbit (`.coderabbit.yaml` or prior `coderabbitai[bot]` PR reviews). If not configured, skip CR-specific polling but still verify CI/AC through `cr-merge-gate.md`.

After pushing to a PR, enter this loop automatically.

### Session-start / pre-review comment audit (MANDATORY)

Run this before the first poll tick and before any new review trigger (`@coderabbitai full review`, `@cursor review`, `@greptileai`) on fresh push, resume, or post-compaction re-entry.

1. Fetch **all 3 comment endpoints** on the PR with `per_page=100`:
   - `repos/{owner}/{repo}/pulls/{N}/reviews`
   - `repos/{owner}/{repo}/pulls/{N}/comments`
   - `repos/{owner}/{repo}/issues/{N}/comments`
2. Identify any unresolved findings from `coderabbitai[bot]`, `cursor[bot]`, or `greptile-apps[bot]` (no reply confirming a fix, code unchanged since the comment, not marked outdated/resolved).
3. **If ANY unresolved findings exist: invoke `/fixpr` now.** `/fixpr` fixes, commits once, pushes, replies to every thread, resolves via GraphQL. Do NOT request a new review on top of unaddressed feedback.
4. Do not poll/request review until step 3 completes.

### Per-cycle check (every 60 seconds)

Each cycle, query everything in "Polling" for every open PR owned by this session. **Re-read current HEAD SHA every cycle** so stale approvals never exit polling.

If **ANY** of the conditions below hold, invoke `/fixpr` and do NOT request a new review until `/fixpr` completes:

1. New bot findings since the last poll watermark (not old unresolved threads awaiting reviewer ack)
2. Any check-run with a blocking conclusion (`failure`, `timed_out`, `action_required`, `startup_failure`, `stale`)
3. `mergeStateStatus == "BEHIND"` (branch behind base, auto-rebase; `/fixpr` handles it)
4. `mergeable == "CONFLICTING"` (merge conflicts; `/fixpr` handles rebase + surfaces blockers)

> **Unresolved threads are NOT a trigger.** After a fix push, keep polling for reviewer catch-up unless conditions 1-4 occur.

**SHA freshness (every cycle).** A CR approval must have `.commit_id == current HEAD SHA`; otherwise it is stale. Re-trigger (respecting the 2/hour cap) and keep polling. See `cr-merge-gate.md` for retraction rules.

**Exit polling ONLY when the merge gate (`cr-merge-gate.md`) is met.** "0 unresolved threads right now" is NOT an exit condition — see the trap note at the top of this file. After any `/fixpr` push, reset the watermark and keep polling for the reviewer's response to the new SHA.

### Rate Limits & Behavior (Pro Tier)
- **8 PR reviews/hour** (each push or `@coderabbitai full review` consumes one), **50 chat interactions/hour**.
- **Batch fixes into ONE commit** before pushing — 4 fixes = 1 review consumed, not 4.
- **Max 2 explicit `@coderabbitai full review` triggers per PR per hour.** After 2 with no response, tell the user CR may be rate-limited.
- **Parallel agents:** stagger pushes; max 3-4 PRs triggering CR reviews/hour.
- **"Reviews paused" or rate-limit language:** fall back to **BugBot** (see `bugbot.md`). If BugBot also fails, fall back to **Greptile** (see `greptile.md`). If Greptile unavailable, fall back to **self-review**.

### Polling
- Poll every 60 seconds. Always use `per_page=100` on all GitHub API calls.
- **Poll ALL THREE endpoints every cycle** (`per_page=100`):
  1. `repos/{owner}/{repo}/pulls/{N}/reviews` — review objects
  2. `repos/{owner}/{repo}/pulls/{N}/comments` — inline diff comments
  3. `repos/{owner}/{repo}/issues/{N}/comments` — PR conversation (summary, ack, general findings). Missing this endpoint causes indefinite polling on clean passes.
- **Check merge metadata every cycle:** `mergeable` and `mergeStateStatus` drive `/fixpr` triggers 3-4.
- **Check commit status every cycle.** Query `repos/{owner}/{repo}/commits/{SHA}/check-runs` filtered to `name == "CodeRabbit"`; fallback: `/statuses` filtered to `context ~ "CodeRabbit"`. Full commands: `.claude/reference/cr-polling-commands.md`.
  - **Completion signal:** `status: "completed"` + `conclusion: "success"` = review done. Definitive signal.
  - **Fast-path rate limit:** "rate limit" in failed CodeRabbit check/status output escalates immediately: check BugBot first, wait only BugBot's push-time 10-min window, then Greptile. Sticky assignment applies.
  - **Ack ≠ completion.** "Actions performed — Full review triggered" = CR started. "CodeRabbit — Review completed" CI check = CR finished.
- **CR username:** `coderabbitai[bot]` (with `[bot]` suffix). Filter by `.user.login == "coderabbitai[bot]"` — NOT bare `coderabbitai`.
- **Watermark:** Track highest review ID from `pulls/{N}/reviews`. New reviews can have inline comment IDs lower than previous reviews (different ID sequences). For `issues/{N}/comments`, track by comment ID.
- **Hard timeout: 12 minutes.** Cadence 60 s; a CR `status: "completed"` exits polling immediately. No CR review after 12 min → check BugBot (see `bugbot.md`); if absent, trigger Greptile immediately (BugBot's 10-min window already elapsed). Sticky assignment applies.

### CI Health Check (MANDATORY — every poll cycle)

**Check ALL check-runs every poll cycle — not just CodeRabbit.** CI failures are independent merge blockers. Query `repos/{owner}/{repo}/commits/{SHA}/check-runs?per_page=100`; full command in `.claude/reference/cr-polling-commands.md`.

**Rules:**
- **Blocking conclusions:** `failure`, `timed_out`, `action_required`, `startup_failure`, `stale`. If any appear, **invoke `/fixpr` immediately**. (`cancelled`, `neutral`, `skipped` are non-blocking.)
  - Test/lint/build failure: `/fixpr` fixes, commits, pushes. Do NOT resume polling until CI is green on the new SHA.
  - Transient/infra failure (e.g., `timed_out`, `startup_failure`): `/fixpr` flags it; cannot auto-fix, user decides retry.
- CI failures block merge independently of CR — a PR with passing CR but failing tests is not merge-ready. Report pass/fail summary: "CI: 5/6 passed, `test` failed — invoking `/fixpr`."

### Timeout & Fallback — Three-Tier Review Chain

**Review chain:** CR (primary) → BugBot (second tier, free) → Greptile (last resort, paid) → self-review (emergency).

BugBot auto-runs on every push. When CR fails, check BugBot before Greptile; BugBot's 10-min timeout runs concurrently with CR's 12. See `bugbot.md` and `greptile.md`.

- **Sticky assignment:** CR fail → BugBot owns the PR. If BugBot also fails → Greptile owns permanently. Do not switch back up the chain.
- **If all three fail** (CR rate-limited + BugBot 10-min timeout + Greptile 10-min timeout): fall back to **self-review**. Self-review does NOT satisfy the merge gate.
- Tell the user which fallback was used and why.

### Processing CR Feedback
1. Fetch latest CR comments via `gh api`, verify each finding against the actual file
2. Fix **all valid findings**, commit and push **once**
3. **Reply to every thread** ("Fixed in `abc1234`: <what changed>"). Try inline reply; on 404, PR-level comment with `@coderabbitai Fixed in ...`
4. **Resolve each thread via GraphQL** after replying — replies alone don't resolve threads. Use `resolveReviewThread(threadId)`; fallback: `minimizeComment(subjectId, classifier: RESOLVED)`. Full mutations: `.claude/reference/graphql-thread-resolution.md`
5. **Verify all threads resolved** before requesting a new review
6. Resume polling; repeat until CR has no more findings

> **"Duplicate" findings are NOT resolved.** CR labels a comment "duplicate" when it raised the same issue before — this does NOT mean it was fixed. Always verify against actual code before dismissing any CR comment.

### Completion

Exit only through `cr-merge-gate.md` (review gate, CI, resolved threads, AC, user merge confirmation). This file owns polling/feedback only.
