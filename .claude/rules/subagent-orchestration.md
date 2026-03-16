## Subagent Context

When spawning subagents via the Task tool, **always pass the FULL contents of ALL rule files into the subagent's prompt.** Subagents do not automatically inherit CLAUDE.md or `.claude/rules/` context — they only see what you put in their prompt.

**How to pass rules to subagents:**
1. Read the root `CLAUDE.md` via `cat ~/.claude/CLAUDE.md`
2. Read ALL files in `.claude/rules/` via `cat ~/.claude/rules/*.md` (or the repo's `.claude/rules/*.md`)
3. Include the COMPLETE output of both in the subagent's task description
4. Do NOT summarize, excerpt, or paraphrase — pass the complete files

Without the full instructions, subagents will miss critical workflow steps (Macroscope fallback, ack-vs-completion detection, reply requirements) and improvise their own broken approach.

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

### Timestamped Status Updates (MANDATORY for parent agents)

**Every message the parent agent sends to the user must start with a timestamp** in New York City (Eastern) time, formatted exactly as:

`Mon Mar 16 02:34 AM ET`

Get the timestamp via: `TZ='America/New_York' date +'%a %b %-d %I:%M %p ET'`

This applies to ALL messages — status updates, failure reports, success reports, questions, summaries. No exceptions.

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
> "Mon Mar 16 02:34 AM ET — Subagent for PR #N (Phase B) failed — ran out of tokens during CR polling. The last push was commit `abc1234`. CR review is pending but unprocessed. Want me to respawn a new agent to continue, or would you like to handle it?"

The user should never have to discover a stalled PR by checking GitHub manually.

### Mandatory Subagent Review Protocol (COPY INTO EVERY SUBAGENT PROMPT)

Since subagents receive the full rules (see above), this section serves as a **quick-reference summary** of the review protocol. The full details are in the other rule files — this summary exists so subagents can quickly locate the critical steps without scanning everything.

```
## GitHub Review Loop — Quick Reference

After pushing code and creating/updating a PR, follow this EXACT sequence:

### Step 0: Check for unresolved findings BEFORE requesting any review
BEFORE triggering `@coderabbitai full review` or entering the polling loop:
1. Fetch all comments on the PR (all 3 endpoints, per_page=100)
2. Look for unresolved findings from coderabbitai[bot] or macroscope-app[bot]
3. If unresolved findings exist -> fix them, push, reply, resolve threads FIRST
4. Only request a new review after all prior findings are addressed
Skipping this step wastes a review cycle and burns CR quota.

### Step 1: Wait for CR review (fast-path check every cycle, 8-min slow-path max)
- Poll every 60s on all 3 endpoints (per_page=100):
  - `repos/{owner}/{repo}/pulls/{N}/reviews?per_page=100`
  - `repos/{owner}/{repo}/pulls/{N}/comments?per_page=100`
  - `repos/{owner}/{repo}/issues/{N}/comments?per_page=100`
- Filter by `coderabbitai[bot]` (with [bot] suffix)
- EVERY cycle, check commit status for rate limit (FAST PATH):
  `gh api "repos/{owner}/{repo}/commits/{SHA}/check-runs" --jq '.check_runs[] | select(.name == "CodeRabbit")'`
  If check shows "rate limit" in output.title with conclusion "failure" -> Macroscope IMMEDIATELY.
  If check-runs empty, also check: `gh api "repos/{owner}/{repo}/commits/{SHA}/statuses"`

### Step 2: After 8 minutes with no review -> trigger Macroscope (NO EXCEPTIONS)
If 8 minutes pass and CR has not delivered review content, trigger Macroscope.
It does NOT matter whether you see an explicit rate-limit signal.
The "Actions performed" ack means CR STARTED — it is NOT a review.
If you see the ack but no review within 8 minutes, CR failed to deliver.

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
- 2 clean CodeRabbit reviews
- 1 clean Macroscope + 1 clean CodeRabbit
- 1 clean self-review + 1 clean CodeRabbit
- NOT valid: 2 Macroscope only (need at least 1 CR)
- NOT valid: 2 self-reviews only (need at least 1 CR)

After Macroscope or self-review, wait 15 min then re-trigger `@coderabbitai full review`.
If CR is still rate-limited after 15 min, tell the user and stop — do not loop forever.
```
