## GitHub CodeRabbit Review Loop (Fallback)

> **NEVER declare a PR done immediately after pushing.** Every push triggers new CR/BugBot review activity; **Greptile** runs only when escalated. **CodeAnt** and **Graphite** (`codeant-ai[bot]`, `graphite-app[bot]`) may also run in parallel on the CR path. Poll until `cr-merge-gate.md` is met; "0 unresolved threads" is not an exit condition.
>
> **Always:** Poll all 3 endpoints + check-runs every cycle. Use `per_page=100`. Filter by `coderabbitai[bot]`. Batch fixes into one commit. Reply to every thread. Resolve threads via GraphQL. **Enter the polling loop immediately after push — do NOT ask.** Invoke `/fixpr` when any trigger condition fires (see "Per-cycle check" below).
> **Ask first:** Merging — always ask the user. **Nothing else in this workflow requires permission.**
> **Never:** Poll only 1-2 endpoints. Use bare `coderabbitai` without `[bot]`. Push per-finding. Trigger `@coderabbitai full review` more than twice per PR per hour. Trigger Greptile proactively (only on CR failure). Merge without meeting the merge gate (see `cr-merge-gate.md` for the authoritative definition). **Exit polling on "nothing unresolved right now" — the only valid exit is the merge gate.**
>
> **This fallback workflow runs after every push/PR.** Local review reduces findings; it does not replace GitHub review.

**Prerequisite:** Confirm the repo uses CodeRabbit (`.coderabbit.yaml` or prior `coderabbitai[bot]` PR reviews). If not configured, skip CR-specific polling but still verify CI/AC through `cr-merge-gate.md`.

After pushing to a PR, enter this loop automatically.

### Pre-polling procedural gate (MANDATORY — issue #315)

Before the first poll tick:

1. `.claude/scripts/polling-state-gate.sh <PR_NUMBER> --ensure-session` (`--root-repo <path>` if cwd is not the PR repo). Registers the PR, sets `root_repo`, creates/refreshes `~/.claude/handoffs/pr-<PR_NUMBER>-handoff.json`.
2. If session `root_repo` ≠ your checkout, stop and reconcile (multi-repo hazard).

**Each cycle:** `.claude/scripts/polling-state-gate.sh <PR_NUMBER>` — validates state then runs `merge-gate.sh`. Do not substitute prose for that script. Exit `0` = gate met; `1` = keep polling (plus `/fixpr` triggers below).

### Session-start / pre-review comment audit (MANDATORY)

Run this before the first poll tick and before any new review trigger (`@coderabbitai full review`, `@cursor review`, `@greptileai`) on fresh push, resume, or post-compaction re-entry.

1. Fetch **all 3 comment endpoints** on the PR with `per_page=100`:
   - `repos/{owner}/{repo}/pulls/{N}/reviews`
   - `repos/{owner}/{repo}/pulls/{N}/comments`
   - `repos/{owner}/{repo}/issues/{N}/comments`
2. Identify any unresolved findings from `coderabbitai[bot]`, `cursor[bot]`, `greptile-apps[bot]`, `codeant-ai[bot]`, or `graphite-app[bot]` (no reply confirming a fix, code unchanged since the comment, not marked outdated/resolved).
3. **If ANY unresolved findings exist: invoke `/fixpr` now.** `/fixpr` fixes, commits once, pushes, replies to every thread, resolves via GraphQL. Do NOT request a new review on top of unaddressed feedback.
4. Do not poll/request review until step 3 completes.

### Per-cycle check (every 60 seconds)

Each cycle, query everything in “Polling” for every open PR owned by this session. **Re-read current HEAD SHA every cycle** so stale approvals never exit polling.

If **ANY** of the conditions below hold, invoke `/fixpr` and do NOT request a new review until `/fixpr` completes:

1. New bot findings since the last poll watermark (not old unresolved threads awaiting reviewer ack)
2. Any check-run with a blocking conclusion (`failure`, `timed_out`, `action_required`, `startup_failure`, `stale`)
3. **`mergeStateStatus == “BEHIND”`** — each cycle, read this field explicitly (e.g. `gh pr view <N> --json mergeStateStatus,mergeable` or the PR snapshot used for polling). **Do not treat `mergeStateStatus: “BLOCKED”` as “behind base”**; BLOCKED covers missing checks/reviews as well. Only the literal value `BEHIND` triggers rebase + force-push via `/fixpr` (same merge-state handling as `/fixpr` Step 6 / `.merge_state` from `pr-state.sh` — see `fixpr/SKILL.md`).
4. `mergeable == “CONFLICTING”` (merge conflicts; `/fixpr` handles rebase + surfaces blockers)

> **Unresolved threads are NOT a trigger.** After a fix push, keep polling for reviewer catch-up unless conditions 1-4 occur.

**#362:** If this cycle does not require `/fixpr` **and** the session-start / pre-review audit has confirmed there are no unresolved bot findings for the current SHA, run `maybe-trigger-ai-review.sh <PR>` (`pm-config.md` **Complexity triggers**; `complexity-score.sh`; `cycle-count.sh --cr-only`; three separate `@` comments: `@codeant-ai review`, `@cursor review`, `@graphite-app re-review`). Dedupe `session-state.json` `.prs[N].ai_review_trigger_*`.

**SHA freshness (every cycle).** A CR approval must have `.commit_id == current HEAD SHA`; otherwise it is stale. Re-trigger (respecting the 2/hour cap) and keep polling. See `cr-merge-gate.md` for retraction rules.

**Exit polling ONLY when the merge gate (`cr-merge-gate.md`) is met.** "0 unresolved threads right now" is NOT an exit condition — see the trap note at the top of this file. After any `/fixpr` push, reset the watermark and keep polling for the reviewer's response to the new SHA.

### Reviewer escalation gate (MANDATORY per cycle)

Run **every poll cycle while `reviewer == cr`** after PR snapshot + CI:

```bash
STATUS=$(.claude/scripts/escalate-review.sh <PR_NUMBER> | sed -n 's/^STATUS=//p')
```

Verdicts: `polling_cr`, `switch_bugbot`, `trigger_greptile`, `budget_exhausted`, `self_review` — follow `escalate-review.sh` / `bugbot.md` / `greptile.md` (rate-limit → BugBot → Greptile; cache `bugbot_installed` in session-state).

### Rate Limits & Behavior (Pro Tier)

**Cap:** ~**8** CR PR reviews/hour (plan on 8). Batch fixes into one commit/push; max **2** explicit `@coderabbitai full review`/PR/hour (surface the user at the 2nd recorded trigger). On cooldown/exhaustion, local review first, then escalate CR → BugBot → Greptile → self-review. Consumption tracked via `cr-review-hourly.sh` (`cr_hourly.events`, `.prs[N].cr_explicit_triggers`). Full caps, hourly-state mechanics, and script flags: `.claude/reference/cr-rate-limits.md`.

### Polling

- Poll every 60 seconds. Always use `per_page=100` on all GitHub API calls.
- **Poll ALL THREE endpoints every cycle** (`per_page=100`):
  1. `repos/{owner}/{repo}/pulls/{N}/reviews` — review objects
  2. `repos/{owner}/{repo}/pulls/{N}/comments` — inline diff comments
  3. `repos/{owner}/{repo}/issues/{N}/comments` — PR conversation (summary, ack, general findings). Missing this endpoint causes indefinite polling on clean passes.
- **Check merge metadata every cycle:** fetch `mergeStateStatus` and `mergeable` every cycle (same PR JSON as `merge-gate.sh`). They drive `/fixpr` triggers 3–4; never infer BEHIND from `BLOCKED` alone.
- **Check commit status every cycle.** Query `repos/{owner}/{repo}/commits/{SHA}/check-runs` filtered to `name == "CodeRabbit"`; fallback: `/statuses` filtered to `context ~ "CodeRabbit"`. Full commands: `.claude/reference/cr-polling-commands.md`.
  - **Completion signal:** `status: "completed"` + `conclusion: "success"` = review done. Definitive signal.
- **Fast-path rate limit:** "rate limit" in failed CodeRabbit check/status output goes through the escalation gate above. Sticky assignment applies.
  - **Ack ≠ completion.** "Actions performed — Full review triggered" = CR started. "CodeRabbit — Review completed" CI check = CR finished.
- **CR username:** `coderabbitai[bot]` (with `[bot]` suffix). Filter by `.user.login == "coderabbitai[bot]"` — NOT bare `coderabbitai`.
- **Watermark:** Track highest review ID from `pulls/{N}/reviews`. New reviews can have inline comment IDs lower than previous reviews. For `issues/{N}/comments`, track by comment ID.
- **CR silence threshold:** Cadence 60 s; a CR `status: "completed"` exits polling immediately. Otherwise, the escalation gate owns silence, BugBot grace, and Greptile fallback. Sticky assignment applies.

### CI Health Check (MANDATORY — every poll cycle)

**Check ALL check-runs every poll cycle — not just CodeRabbit.** CI failures are independent merge blockers. Query `repos/{owner}/{repo}/commits/{SHA}/check-runs?per_page=100`; full command in `.claude/reference/cr-polling-commands.md`.

**Rules:**
- **Blocking conclusions:** `failure`, `timed_out`, `action_required`, `startup_failure`, `stale`. If any appear, **invoke `/fixpr` immediately**. (`cancelled`, `neutral`, `skipped` are non-blocking.)
  - Test/lint/build failure: `/fixpr` fixes, commits, pushes. Do NOT resume polling until CI is green on the new SHA.
  - Transient/infra failure (e.g., `timed_out`, `startup_failure`): `/fixpr` flags it; cannot auto-fix, user decides retry.
- CI failures block merge independently of CR — a PR with passing CR but failing tests is not merge-ready. Report pass/fail summary: "CI: 5/6 passed, `test` failed — invoking `/fixpr`."

### Timeout & Fallback — Three-Tier Review Chain

**Review chain:** CR → BugBot → Greptile → self-review. **Supplemental (CR path):** CodeAnt + Graphite — see the "CodeAnt & Graphite (supplemental)" subsection below.

When CR fails or stalls, the reviewer escalation gate checks BugBot before Greptile and caches whether BugBot is installed for the PR. See `bugbot.md` and `greptile.md`.

- **Sticky assignment:** CR fail → BugBot owns the PR. If BugBot also fails → Greptile owns permanently. Do not switch back up the chain.
- **If all three fail** (CR failed/stalled + BugBot absent/silent per the gate + Greptile timeout or budget exhaustion): fall back to **self-review**. Self-review does NOT satisfy the merge gate.
- Tell the user which fallback was used and why.

### CodeAnt & Graphite (supplemental)

> **Always:** When CodeAnt or Graphite is enabled, poll `codeant-ai[bot]` and `graphite-app[bot]` on the same three PR endpoints as CodeRabbit; clear threads and blocking CI like other bots.
> **Ask first:** Merging — always ask the user.
> **Never:** Treat Graphite as a merge-gate tier until it posts reliably; avoid spamming `@codeant-ai` / `@graphite-app`.

**CodeAnt (CR path):** If CodeAnt participated on current HEAD (comments or CodeAnt check-run), `merge-gate.sh` needs a clean signal per `cr-merge-gate.md`. Use `@codeant-ai review` to nudge.

**Graphite:** Poll like other bots; not a merge-gate tier until reliable. If silent: check [Graphite app](https://github.com/apps/graphite-app) access, AI review toggle, workspace link, limits; try `@graphite-app re-review` on a test PR.

CodeAnt and Graphite are parallel supplements; the primary chain stays CR → BugBot → Greptile.

### Processing CR Feedback

1. Fetch latest CR comments via `gh api`, verify each finding against the actual file
2. Fix **all valid findings**, commit and push **once**
3. **Reply to every thread** ("Fixed in `abc1234`: <what changed>"). Try inline reply; on 404, PR-level comment with `@coderabbitai Fixed in ...`
4. **Resolve each thread via GraphQL** after replying — replies alone don't resolve threads. Use `resolveReviewThread(threadId)`; fallback: `minimizeComment(subjectId, classifier: RESOLVED)`. Full mutations: `.claude/reference/graphql-thread-resolution.md`
5. **Re-query `pullRequest.reviewThreads` and verify every touched thread has `isResolved: true`** before requesting a new review. Retry with the minimize fallback; surface any still-dangling URLs — do not declare success.
6. Resume polling; repeat until CR has no more findings

> **"Duplicate" findings are NOT resolved.** CR labels a comment "duplicate" when it raised the same issue before — this does NOT mean it was fixed. Always verify against actual code before dismissing any CR comment.

### Completion

Exit only through `cr-merge-gate.md` (review gate, CI, resolved threads, AC, user merge confirmation). This file owns polling/feedback only.
