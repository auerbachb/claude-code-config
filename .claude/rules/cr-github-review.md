## GitHub CodeRabbit Review Loop (Fallback)

> **NEVER declare a PR done immediately after pushing.** Every push triggers new review activity (CR/BugBot; CodeAnt/Graphite in parallel; Greptile only when escalated). Poll until `cr-merge-gate.md` is met; "0 unresolved threads" is not an exit condition.
>
> **Always:** Poll all 3 endpoints + check-runs every cycle (`per_page=100`; filter per-bot logins like `coderabbitai[bot]` after fetching). Batch fixes into one commit. Reply to every thread. Resolve via `resolve-review-threads.sh`. Enter the polling loop immediately after push — do NOT ask. Invoke `/fixpr` when any trigger condition fires.
> **Ask first:** Merging only.
> **Never:** Poll only 1-2 endpoints. Use bare `coderabbitai` without `[bot]`. Push per-finding. Trigger `@coderabbitai full review` more than twice per PR per hour. Trigger Greptile proactively. Merge without meeting the merge gate. Exit polling on "nothing unresolved right now."

**Prerequisite:** Confirm the repo uses CodeRabbit (`.coderabbit.yaml` or prior `coderabbitai[bot]` PR reviews). If not configured, skip CR-specific polling but still verify CI/AC through `cr-merge-gate.md`.

### Pre-polling procedural gate (MANDATORY — issue #315)

Before the first poll tick:

1. `.claude/scripts/polling-state-gate.sh <PR_NUMBER> --ensure-session` (`--root-repo <path>` if cwd is not the PR repo).
2. Refusal = genuine cross-repo mismatch; stop and reconcile.

**Each cycle:** `.claude/scripts/polling-state-gate.sh <PR_NUMBER>` — validates state then runs `merge-gate.sh`. Exit `0` = gate met; `1` = keep polling (plus `/fixpr` triggers below).

### Session-start / pre-review comment audit (MANDATORY)

Run before the first poll tick and before any new review trigger on push, resume, or post-compaction re-entry.

1. Fetch all 3 comment endpoints (**Polling** below).
2. Identify unresolved findings from `coderabbitai[bot]`, `cursor[bot]`, `greptile-apps[bot]`, `codeant-ai[bot]`, or `graphite-app[bot]` (no fix reply, code unchanged, not outdated/resolved).
3. **If ANY unresolved: invoke `/fixpr` now** — no polling or new reviews until complete.

### Per-cycle check (every 60 seconds)

Query everything in “Polling” for every open PR owned by this session. **Re-read current HEAD SHA every cycle** so stale approvals never exit polling.

If **ANY** condition below holds, invoke `/fixpr` and do NOT request a new review until it completes:

1. New bot findings since the last poll watermark on **any** of the three endpoints (`pulls/{N}/reviews`, `pulls/{N}/comments`, `issues/{N}/comments`) — run `.claude/scripts/poll-watermarks.sh <PR> --check` (`NEW_FINDINGS=1`); not old unresolved threads awaiting reviewer ack
2. Any check-run with a blocking conclusion (`failure`, `timed_out`, `action_required`, `startup_failure`, `stale`)
3. **`mergeStateStatus == “BEHIND”`** — read explicitly each cycle. **Do not treat `BLOCKED` as “behind base”.** Only literal `BEHIND` triggers rebase + force-push via `/fixpr`.
4. `mergeable == “CONFLICTING”` (merge conflicts; `/fixpr` handles rebase + surfaces blockers)

> **Unresolved threads are NOT a trigger.** After a fix push, keep polling for reviewer catch-up unless conditions 1-4 occur.

If this cycle requires no `/fixpr` and the audit was clean for current SHA, run `maybe-trigger-ai-review.sh <PR>` (dedupe `session-state.json` `.prs[N].ai_review_trigger_*`).

**Exit polling ONLY when the merge gate (`cr-merge-gate.md`) is met.** After any `/fixpr` push, reset all three watermarks (`poll-watermarks.sh <PR> --reset`) and keep polling for the reviewer's response to the new SHA.

### Reviewer escalation gate (MANDATORY per cycle)

Run **every poll cycle while `reviewer == cr`** after PR snapshot + CI:

```bash
STATUS=$(.claude/scripts/escalate-review.sh <PR_NUMBER> | sed -n 's/^STATUS=//p')
```

Verdicts: `gate_met`, `polling_cr`, `switch_bugbot`, `trigger_greptile`, `budget_exhausted`, `self_review` — follow `escalate-review.sh` / `bugbot.md` / `greptile.md`. `gate_met` = CodeRabbit or CodeAnt holds a valid `APPROVED` on current HEAD — stop escalating; let the merge gate exit polling.

### Rate Limits & Behavior (Pro Tier)

**Cap:** **5 reviews/hour per developer** on Pro (#1204), not the ~8/hr account-wide we modelled — bursts block, not monthly volume. The `Review limit reached` banner names a retry window; `escalate-review.sh` waits it out before escalating. `cr_hourly` is our pacing proxy, never CodeRabbit's meter. Max 2 explicit `@coderabbitai full review`/PR/hour (surface user at 2nd). On cooldown: local review first, then escalate. Tracking: `cr-review-hourly.sh`; details: `.claude/reference/cr-rate-limits.md`.

### Polling

- Poll every 60 seconds, `per_page=100` on every GitHub API call.
- **Poll ALL THREE endpoints every cycle:**
  1. `repos/{owner}/{repo}/pulls/{N}/reviews` — review objects
  2. `repos/{owner}/{repo}/pulls/{N}/comments` — inline diff comments
  3. `repos/{owner}/{repo}/issues/{N}/comments` — PR conversation (summary, ack, general findings). Skipping this one causes indefinite polling on clean passes.
- **Merge metadata every cycle:** `mergeStateStatus` and `mergeable` (same PR JSON as `merge-gate.sh`).
- **Commit status every cycle.** Query CodeRabbit check-runs (fallback commands: `.claude/reference/cr-polling-commands.md`). Check-run `completed`/`success` = review done; the "Full review triggered" ack only means started.
- **Fast-path rate limit:** "rate limit" in failed CR check/status output routes to the escalation gate.
- **CR username:** `coderabbitai[bot]`. Filter by `.user.login == "coderabbitai[bot]"` — NOT bare `coderabbitai`.
- **Watermark:** highest ID per endpoint; persist via `poll-watermarks.sh` → `session-state.json` (schema: `.claude/reference/session-state-schema.json`).
- **CR silence:** a completed CR check-run ends the silence wait (the merge gate still decides exit); otherwise the escalation gate owns silence, BugBot grace, and Greptile fallback.

### CI Health Check (MANDATORY — every poll cycle)

**Check ALL check-runs:** `repos/{owner}/{repo}/commits/{SHA}/check-runs?per_page=100` (full command: `.claude/reference/cr-polling-commands.md`). Any blocking conclusion → **invoke `/fixpr` immediately** (`cancelled`/`neutral`/`skipped` are non-blocking). CI failures block merge independently of CR.

### Timeout & Fallback — Three-Tier Review Chain

**Chain:** CR → BugBot → Greptile → self-review. **Supplemental (CR path):** CodeAnt + Graphite — `.claude/reference/codeant-graphite-supplemental.md`. **Sticky:** once a PR falls to BugBot or Greptile, it never moves back up the chain. **If all three fail:** self-review (does NOT satisfy gate); tell the user which fallback ran and why. **Every tier is cap-degraded** — fall-through is normal, not exceptional; roles + cost rationale: `.claude/reference/ai-review-chain-roles-decision.md`.

### Processing CR Feedback

1. Fetch latest CR comments via `gh api`, verify each finding against the actual file (for the judgment layer — when to accept, decline, or push back — invoke `/receiving-code-review`)
2. Fix **all valid findings**, commit and push **once**
3. **Reply to every thread** ("Fixed in `abc1234`: <what changed>"). Try inline reply; on 404, PR-level comment with `@coderabbitai Fixed in ...`
4. **Resolve via `.claude/scripts/resolve-review-threads.sh <PR> --thread-ids <id1,id2>`** — **NEVER call `resolveReviewThread` inline** (mutations: `.claude/reference/graphql-thread-resolution.md`)
5. Resume polling; repeat until CR has no more findings

> **"Duplicate" findings are NOT resolved** — always verify against code before dismissing.

This file owns polling/feedback only.
