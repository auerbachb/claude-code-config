# Subagent Context

> **Always:** Pass ALL rule files to subagents. Use phase decomposition (A/B/C). Timestamp every message. Monitor subagent health. Report failures immediately.
> **Ask first:** Respawning a failed subagent — tell the user what happened first.
> **Never:** Summarize rules for subagents. Fire-and-forget subagents. Let a stalled PR go unreported. Skip timestamps. Go >5 minutes without a user-visible message. Report a PR as "awaiting review" for >5 minutes without a Phase B agent running.

When spawning subagents via the Task tool, **always pass the FULL contents of ALL rule files into the subagent's prompt.** Subagents do not automatically inherit CLAUDE.md or `.claude/rules/` context — they only see what you put in their prompt.

**How to pass rules to subagents:**
1. Read the root `CLAUDE.md` — check **project root first** (`cat ./CLAUDE.md`), fall back to global (`cat ~/.claude/CLAUDE.md`) only if no project-level file exists
2. Read ALL rule files — check **project root first** (`cat ./.claude/rules/*.md`), fall back to global (`cat ~/.claude/rules/*.md`)
3. Include the COMPLETE output of both in the subagent's task description
4. Do NOT summarize, excerpt, or paraphrase — pass the complete files

> **Why project-local first:** Per-project configs override global ones. If a repo has its own `CLAUDE.md` or `.claude/rules/`, those are the active instructions — not `~/.claude/`. Passing the global file when a project-level file exists will give subagents the wrong rules.

Without the full instructions, subagents will miss critical workflow steps (Greptile fallback, ack-vs-completion detection, reply requirements) and improvise their own broken approach.

### Subagent Task Decomposition (Token Safety)

Subagents have a hardcoded **32K output token limit** that cannot be configured ([known Claude Code limitation](https://github.com/anthropics/claude-code/issues/25569)). A single subagent that reads 10-20 CR findings, fixes code, pushes, replies to every thread, AND polls for the next review will exhaust its token budget and die mid-poll. To prevent this, break PR lifecycle work into sequential phases:

**Phase A: Fix + Push** (heaviest — uses most tokens)
- Read CR/Greptile findings from GitHub API
- Read affected source files
- Fix all valid findings + fix lint/CI failures
- Commit all fixes in ONE commit, push once
- Reply to all review comment threads
- **EXIT after push — do not enter polling loop**

**Phase B: Review Loop** (lighter — incremental)
- If this PR is on CR: poll for CR review (fast-path + 7-minute slow-path Greptile trigger). If Greptile is triggered, the PR switches to Greptile permanently.
- If this PR is already on Greptile: skip CR polling, trigger `@greptileai` and poll for Greptile response directly.
- If reviewer posts new findings: fix, commit, push, reply (same as Phase A but smaller scope)
- If clean pass on CR: trigger one more `@coderabbitai full review` for confirmation (2 clean CR passes needed)
- If clean pass on Greptile: merge-ready (1 clean Greptile pass is sufficient)
- **EXIT after confirming clean or after fixing one round**

**Phase C: Merge Prep** (lightest)
- Verify merge gate is satisfied: if PR is on Greptile, 1 clean G review. If CR-only, 2 clean CR reviews.
- Read PR body, verify all acceptance criteria against final code
- Check off all boxes
- Report ready for merge

**Orchestration rules:**
- Parent agent launches Phase A subagents (can run in parallel across different PRs)
- **When Phase A completes, parent MUST launch Phase B immediately** — see "Phase A Completion Protocol" below
- When Phase B reports clean, parent launches Phase C
- **Soft limit on parallel Phase B PRs:** aim for 3-4 active CR-polled PRs at once to reduce CR throttling and unnecessary Greptile fallback cost. Each PR tracks its own reviewer assignment: CR-only PRs need 2 clean CR passes; Greptile PRs need 1 clean G pass.
- **Track CR quota.** Maintain a running count of CR reviews consumed this hour. Increment when: pushing to a PR with CR configured (auto-review), or posting `@coderabbitai full review`. If count reaches 7 in the current hour, expect Greptile to be the primary reviewer for remaining PRs until the window resets.
- Use judgment on small PRs: if CR only found 1-2 findings, a single subagent may handle the full lifecycle without hitting token limits

### Phase A Completion Protocol (MANDATORY)

**WHEN** a subagent returns and reports a PR was created or updated, **THEN** execute this checklist immediately — before any other work:

1. **Verify the push happened.** Run `gh pr view N --json commits --jq '.commits[-1].oid'` and confirm the SHA matches what the subagent reported. If the push didn't happen, the subagent silently failed — report to user.
2. **Check if reviewers already posted findings.** Fetch all 3 comment endpoints for the PR (`per_page=100` on each). If CR or Greptile already posted findings (common if the review was fast), include those findings in the Phase B prompt.
3. **Launch Phase B within 60 seconds.** This is the immediate next action — queue it ahead of any other work (creating issues, reading files, responding to unrelated questions). If you cannot launch within 60 seconds due to tool throttling, tell the user why and when you will launch, then automatically retry until Phase B is launched (do not wait for user action). Record the planned retry in `session-state.json`.
4. **Update `session-state.json`.** Write the phase transition: PR moved from Phase A to Phase B, record the HEAD SHA, reset review state.
5. **Report to user.** "Phase A complete for PR #N — fixes pushed (SHA `abc1234`). Phase B launched, polling for reviews."

**Phase B launch is the highest-priority action after Phase A reports.** Do not start other substantive work until Phase B is launched for every PR that completed Phase A. If multiple Phase A agents complete simultaneously, launch Phase B for each one before doing anything else.

### Timestamped Status Updates (MANDATORY for parent agents)

**Every message the parent agent sends to the user must start with a timestamp** in New York City (Eastern) time, formatted exactly as:

`Mon Mar 16 02:34 AM ET`

Get the timestamp via: `TZ='America/New_York' date +'%a %b %-d %I:%M %p ET'`

NEVER estimate, calculate, or mentally derive timestamps — always run the `date` command. This includes elapsed time: do not count poll cycles or steps to estimate minutes passed. If you need elapsed time, compare two `date` outputs.

This applies to ALL messages — status updates, failure reports, success reports, questions, summaries. No exceptions.

> **Compaction-proof:** This obligation survives context compaction. If you are resuming from compaction and realize you haven't been timestamping, start immediately — do not wait for the next "natural" message. Your first post-compaction message must include a timestamp and an acknowledgment that monitoring is being re-established.

### Subagent Health Monitoring (MANDATORY for parent agents)

The user has no visibility into subagent failures. If a subagent runs out of tokens or times out, the parent agent is the only one who knows — and if the parent doesn't report it, the user won't discover the failure until they manually check GitHub 15-20 minutes later. **This is unacceptable.**

**Monitoring rules for parent agents:**
1. **Poll subagent status every ~60 seconds.** When running subagents in the background, check their status regularly. Do not fire-and-forget. If you are also doing other work (fixing code, managing PRs), this obligation does NOT pause. Either: (a) delegate the fix work to a subagent so you can keep polling, or (b) send the user a status message BEFORE starting the fix work, explaining what you're doing and that monitoring is temporarily paused.
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

### User Heartbeat (MANDATORY for parent agents)

> **Core obligation is in CLAUDE.md item #3.** This section has the detailed rules. The 5-minute max silence is a non-negotiable behavior that applies to EVERY message — see the EVERY MESSAGE block.

The user must never go more than **5 minutes** without a status message. This is separate from subagent polling — it's about keeping the user informed.

**Rules:**
1. **Before entering any multi-step operation** (fixing code, reading multiple files, running a sequence of commands), send a brief status message first: "16:03 ET — Fixing 2 CR findings on PR #620. Other PRs (#618, #619, #621, #622) are waiting for review. Will update in ~3 min."
2. **After completing any multi-step operation**, immediately send a status update — don't start the next operation first.
3. **If you're blocked waiting** (e.g., polling), use that wait time to compose a dashboard message to the user.
4. **Never batch status updates.** Don't wait until everything is done to report. Report incrementally: "PR #620 fix pushed. Now checking PR #618 status."
5. **Time your silences.** If your last message to the user was >5 minutes ago by wall clock, your next tool call must be a status message, not another background operation.

### Heartbeat Enforcement (Automatic)

The 5-minute heartbeat rule is enforced by a PostToolUse hook (`silence-detector.sh`). After every tool call, the hook checks how long it has been since the agent last sent a visible message. If >5 minutes, a warning is injected into the agent's context via `additionalContext`.

**How it works:** Stop hook (`silence-detector-ack.sh`) touches `/tmp/claude-heartbeat-$CLAUDE_SESSION_ID` after each response. PostToolUse hook (`silence-detector.sh`) checks mtime after tool calls; if >5 min elapsed, injects warning via `additionalContext`.

**When you see the warning:** Stop what you are doing and send a status message to the user immediately. Include a timestamp (run `date` command), what you're currently doing, what's pending, and any blockers. Then resume your work — the next tool call will check again and the warning will be gone (because the Stop hook touched the file after your status message).

### Post-Compaction Recovery (MANDATORY)

Context compaction can happen at any time in long sessions. When it does, you lose your in-memory state: which agents are running, what phase each PR is in, which review cycles are pending, and what timestamps matter.

**Detection:** You've been compacted if the conversation starts with a summary block referencing prior work you don't have direct memory of. The compaction summary is your ONLY source of prior context.

**Immediate recovery protocol (do ALL of these before any other work):**

1. **Timestamp your first message.** (See "EVERY MESSAGE" rules in CLAUDE.md.)
2. **Re-run session-start checklist.** Compaction wipes in-memory state like the work-log path. Re-run the work-log detection from `work-log.md` (search from the **main worktree root**, not the current worktree — see that file for details). Also re-check any other session-start obligations from rule files.
3. **Reconstruct PR state from GitHub.** For every open PR in the summary:
   ```bash
   gh pr view N --json state,title,mergeStateStatus,commits
   gh api "repos/{owner}/{repo}/pulls/N/reviews?per_page=100"
   gh api "repos/{owner}/{repo}/pulls/N/comments?per_page=100"
   gh api "repos/{owner}/{repo}/issues/N/comments?per_page=100"
   ```
   Build a dashboard: PR number, HEAD SHA, last review state, last reviewer, pending action.
4. **Check for stale background agents.** Any agents mentioned in the summary are likely dead (compaction killed their parent's awareness). Verify by checking if their expected outputs exist (commits pushed, comments posted).
5. **Check Phase B coverage.** For every open PR, check `~/.claude/session-state.json` for a Phase B entry. If no Phase B record exists for a PR that has unprocessed review findings, launch Phase B immediately and record it in `~/.claude/session-state.json` — this is the most common post-compaction failure.
6. **Report to the user.** Post the reconstructed dashboard with a note: "Resuming after context compaction. Reconstructed state from GitHub. [N agents may need relaunching]."
7. **Resume the monitoring loop.** Re-enter the polling cycle for any PRs still awaiting reviews.

**Pre-compaction checkpointing (preventive):**

When running a long monitoring session with multiple PRs, write a status checkpoint to `~/.claude/session-state.json`. **Write on phase transitions (A→B, B→C) and key state-change events** (agent launched, agent completed, review received) — not just every 10 minutes. The checkpoint write forces you to stop, assess state, and act on pending transitions. Format:
```json
{
  "last_updated": "2026-03-16T16:00:00Z",
  "monitoring_active": true,
  "root_repo": "/Users/user/repos/my-project",
  "work_log_path": "docs/work-logs",
  "prs": {
    "618": {"phase": "B", "head_sha": "7b2cfbf", "reviewer": "cr", "needs": "cr_confirmation_pass"},
    "620": {"phase": "B", "head_sha": "d0e4fef", "reviewer": "g", "needs": "fix_and_push"}
  },
  "cr_quota": {"reviews_used": 5, "window_start": "2026-03-16T15:00:00Z"},
  "active_agents": [
    {"id": "a3f8d26fa75eddcb3", "task": "PR #623 Phase C", "launched": "2026-03-16T15:55:00Z"}
  ]
}
```
After compaction, read this file first: `cat ~/.claude/session-state.json`, then reconcile with live GitHub state.

### Mandatory Subagent Review Protocol (COPY INTO EVERY SUBAGENT PROMPT)

Since subagents receive the full rules (see above), this section serves as a **quick-reference summary** of the review protocol. The full details are in the other rule files — this summary exists so subagents can quickly locate the critical steps without scanning everything.

```text
## GitHub Review Loop — Quick Reference

After pushing code and creating/updating a PR, follow this EXACT sequence:

### Step 0: Check for unresolved findings BEFORE requesting any review
BEFORE triggering `@coderabbitai full review` or entering the polling loop:
1. Fetch all comments on the PR (all 3 endpoints, per_page=100)
2. Look for unresolved findings from coderabbitai[bot] or greptile-apps[bot]
3. If unresolved findings exist -> fix them, push, reply, resolve threads FIRST
4. Only request a new review after all prior findings are addressed
Skipping this step wastes a review cycle and burns CR quota.

### Step 1: Check if PR is already on Greptile
If this PR has already switched to Greptile (check session-state `reviewer` field), skip CR polling entirely — go directly to Step 3 and trigger `@greptileai`.

### Step 1b: Wait for CR review (only if PR is still on CR)
- Poll every 60s on all 3 endpoints (per_page=100):
  - `repos/{owner}/{repo}/pulls/{N}/reviews?per_page=100`
  - `repos/{owner}/{repo}/pulls/{N}/comments?per_page=100`
  - `repos/{owner}/{repo}/issues/{N}/comments?per_page=100`
- Filter by `coderabbitai[bot]` (with [bot] suffix)
- EVERY cycle, check commit status for rate limit (FAST PATH):
  `gh api "repos/{owner}/{repo}/commits/{SHA}/check-runs" --jq '.check_runs[] | select(.name == "CodeRabbit")'`
  If check shows "rate limit" in output.title with conclusion "failure" -> Greptile IMMEDIATELY.
  If check-runs empty, also check: `gh api "repos/{owner}/{repo}/commits/{SHA}/statuses"`

### Step 2: After 7 minutes with no review -> trigger Greptile (NO EXCEPTIONS)
If 7 minutes pass and CR has not delivered review content, trigger Greptile.
It does NOT matter whether you see an explicit rate-limit signal.
The "Actions performed" ack means CR STARTED — it is NOT a review.
If you see the ack but no review within 7 minutes, CR failed to deliver.
**Once Greptile is triggered, this PR stays on Greptile permanently.**

### Step 3: Trigger Greptile (if not already running)
1. Post: `gh pr comment <PR_NUMBER> --body "@greptileai"`
2. Poll every 60s for `greptile-apps[bot]` comments on the same 3 endpoints
3. Timeout after 5 minutes (Greptile typically responds in 1-3 minutes)
4. If no response, do a self-review instead
5. Process Greptile findings same as CR: fix all valid findings in one commit, push once
6. Reply to EVERY Greptile comment thread confirming the fix:
   - Inline comments: `gh api repos/{owner}/{repo}/pulls/comments/{id}/replies -f body="Fixed in \`SHA\`: <what changed>"`
   - Issue comments: `gh api repos/{owner}/{repo}/issues/{N}/comments -f body="@greptileai Fixed: <summary>"`
   Pushing code does NOT resolve threads — you MUST post explicit replies.

### After Greptile fix+push: stay on Greptile
Once a PR is on Greptile, it stays on Greptile. After pushing fixes, trigger `@greptileai` again.
Do NOT switch back to CR or enter the CR polling loop.

### Greptile clean detection
greptile-apps[bot] posts a review/summary with no actionable findings = clean pass.
Also watch for 👍 completion signal with no inline comments.
Check-run name: TBD — update after first Greptile review on this repo.

### Step 4: Merge gate
The merge gate depends on which reviewer owns the PR:
- **CR-only** (Greptile never triggered): 2 clean CR reviews required (confirmation pass needed due to unreliable signals)
- **Greptile** (triggered at any point): 1 clean Greptile review = merge-ready

If BOTH reviewers are down (CR rate-limited + Greptile timeout), perform self-review for risk reduction and report the blocker. Self-review does NOT satisfy the merge gate.
```
