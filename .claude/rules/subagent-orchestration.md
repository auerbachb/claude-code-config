# Subagent Context

> **Always:** Pass ALL rule files to subagents. Use `mode: "bypassPermissions"` on every Agent tool call. Use phase decomposition (A/B/C). Timestamp every message. Monitor subagent health. Report failures immediately. Enter monitor mode when subagents are active. Write handoff files on phase completion (Phase A writes `pr-{N}-handoff.json`; Phase B updates it). Read handoff files before reconstructing state from GitHub API (Phases B/C). Delete the handoff file on successful merge (Phase C). Print Structured Exit Report as the final output before every subagent exits (see "Structured Exit Report" section for format).
> **Ask first:** Respawning a failed subagent — tell the user what happened first. Breaking monitor mode for explicit user requests — warn about paused monitoring first.
> **Never:** Summarize rules for subagents. Spawn subagents without `mode: "bypassPermissions"`. Fire-and-forget subagents. Let a stalled PR go unreported. Skip timestamps. Go >5 minutes without a user-visible message. Report a PR as "awaiting review" for >5 minutes without a Phase B agent running. Do substantive work (coding, issue creation, file editing) while subagents are active.

When spawning subagents via the Agent tool, **always pass the FULL contents of ALL rule files into the subagent's prompt.** Subagents do not automatically inherit CLAUDE.md or `.claude/rules/` context — they only see what you put in their prompt.

**How to spawn subagents:**
1. **Always set `mode: "bypassPermissions"`** on the Agent tool call. Parent permissions do not propagate to subagents — without this flag, subagents will prompt for permission on every file read/write even when the parent has bypass enabled.
2. Read the root `CLAUDE.md` — check **project root first** (`cat ./CLAUDE.md`), fall back to global (`cat ~/.claude/CLAUDE.md`) only if no project-level file exists
3. Read ALL rule files — check **project root first** (`cat ./.claude/rules/*.md`), fall back to global (`cat ~/.claude/rules/*.md`)
4. Include the COMPLETE output of both in the subagent's task description
5. Do NOT summarize, excerpt, or paraphrase — pass the complete files

> **Why project-local first:** Per-project configs override global ones. If a repo has its own `CLAUDE.md` or `.claude/rules/`, those are the active instructions — not `~/.claude/`. Passing the global file when a project-level file exists will give subagents the wrong rules.

Without the full instructions, subagents will miss critical workflow steps (Greptile fallback, ack-vs-completion detection, reply requirements) and improvise their own broken approach.

**Handoff file instructions in subagent prompts:**
- Phase A prompts must include: the PR number and instruction to write `~/.claude/handoffs/pr-{N}-handoff.json` after pushing.
- Phase B and C prompts must include: the PR number, the handoff file path, and instruction to read the handoff file before starting work (with GitHub API fallback if missing).
- Phase B prompts must include: instruction to update the handoff file on completion.
- Phase C prompts must include: instruction to delete the handoff file after successful merge.

### Phase Transition Autonomy (Quick Reference)

Every transition below is classified as **"Always do"** (autonomous) or **"Ask first"** (requires user input). Agents MUST NOT ask permission for "Always do" transitions — just execute them immediately.

| Transition | Action | Classification |
|------------|--------|----------------|
| Coding complete | Run local CR review (`coderabbit review --prompt-only`) | **Always do** |
| Local review clean (2 passes) | Commit all changes, push branch | **Always do** |
| Branch pushed | Create PR via `gh pr create` | **Always do** |
| PR created/updated | Enter GitHub review polling loop (60s cycle) | **Always do** |
| CR/Greptile posts findings | Fix all valid findings, commit, push, reply to threads | **Always do** |
| CR rate-limited (fast-path) | Trigger Greptile immediately | **Always do** |
| CR timeout (7 min) | Trigger Greptile | **Always do** |
| Both reviewers down | Self-review for risk reduction | **Always do** |
| Phase A subagent completes | Parent launches Phase B within 60s | **Always do** |
| Phase B reports clean | Parent launches Phase C | **Always do** |
| Merge gate met | Verify AC checkboxes against code | **Always do** |
| AC verified, all boxes checked | Ask user about merging | **Ask first** |
| Subagent failed (crash / no handoff state) | Report failure, ask about respawn | **Ask first** |
| Subagent exited with valid exhaustion handoff | Launch replacement for same phase | **Always do** |

> **Anti-pattern:** If you find yourself composing "Should I...?" or "Want me to...?" for any "Always do" row, stop — the answer is always yes. Execute immediately.

### Token/Turn Exhaustion Protocol (MANDATORY)

Subagents have a 32K output token limit. Parent agents may hit turn limits. When approaching exhaustion, the agent MUST hand off remaining work — not ask the user what to do.

**Detection signals:**
- Subagent: you've used many tool calls and still have work remaining (polling, fixing, replying)
- Parent: you notice you're running low on turns or the conversation is getting very long

**When approaching exhaustion, do this (in order):**

1. **Write a handoff to `~/.claude/session-state.json`.** Update the PR's entry with:

   ```json
   {
     "phase": "B",
     "needs": "continue_polling",
     "handoff_reason": "token_exhaustion",
     "last_action": "pushed fixes at SHA abc1234, replied to 3/5 threads",
     "remaining_work": ["reply to threads 4-5", "poll for next review"],
     "head_sha": "abc1234"
   }
   ```

2. **Report concisely to the parent (subagent) or user (parent).** State what was done and what remains — do NOT ask "should I continue?" or "want me to spawn a new agent?" The parent will read session-state and act.
3. **Exit cleanly.** Do not attempt to squeeze in one more tool call that might fail mid-execution.

**Parent agent response to exhaustion handoff:**
- Read `session-state.json` for the PR's remaining work
- Launch a new subagent for the same phase with the remaining work in its prompt
- This is an **"Always do"** action — do not ask the user whether to continue

**NEVER do this on exhaustion:**
- Ask "should I continue?" — there is no user action needed
- Ask "want me to spawn a replacement?" — just do it
- Silently die without writing handoff state — this is the worst outcome
- Try to finish "just one more thing" when you're out of budget

### Subagent `--max-turns` Guidance

When spawning subagents via the Agent tool, consider the phase's token demands:

| Phase | Recommended approach | Rationale |
|-------|---------------------|-----------|
| Phase A (Fix + Push) | Keep prompts focused — avoid exploration instructions | Heaviest phase: reads findings, reads files, edits, commits, pushes, replies |
| Phase B (Review Loop) | Same | Lighter but involves polling loops — each poll cycle costs turns |
| Phase C (Merge Prep) | Same | Lightest — reads PR body, verifies AC, reports |

**Key insight:** The 32K output token limit is the binding constraint, not turns. To maximize effective work within 32K tokens:
- Do NOT include exploratory instructions ("also check if...", "while you're at it...")
- Give the subagent ONE clear phase with explicit exit criteria
- Include only the findings/context it needs — not the full PR history

### Structured Exit Report (MANDATORY — all phases)

Every subagent MUST print a structured exit report as its **final output** before exiting. This enables the parent agent to parse results mechanically — not by interpreting prose. The report must be a fenced code block with exactly these key-value pairs:

```text
EXIT_REPORT
PHASE_COMPLETE: A
PR_NUMBER: 618
HEAD_SHA: abc1234
REVIEWER: cr
OUTCOME: pushed_fixes
FILES_CHANGED: src/foo.ts, src/bar.ts
NEXT_PHASE: B
HANDOFF_FILE: ~/.claude/handoffs/pr-618-handoff.json
```

**Field reference:**

| Field | Values | Description |
|-------|--------|-------------|
| `PHASE_COMPLETE` | `A`, `B`, `C` | Which phase just finished |
| `PR_NUMBER` | integer | The PR number |
| `HEAD_SHA` | string | HEAD SHA after the phase's last push (or current HEAD if no push) |
| `REVIEWER` | `cr`, `greptile` | Which reviewer owns this PR |
| `OUTCOME` | see below | What happened during the phase |
| `FILES_CHANGED` | comma-separated paths | Files modified (empty string if none) |
| `NEXT_PHASE` | `B`, `C`, `none` | What the parent should launch next |
| `HANDOFF_FILE` | path | Path to the handoff file for this PR (Phase A creates, Phase B updates, Phase C reads then deletes) |

**Valid `OUTCOME` values per phase:**

| Phase | Outcome | Meaning |
|-------|---------|---------|
| A | `pushed_fixes` | Findings fixed, code pushed |
| A | `no_findings` | Review was already clean, code pushed as-is |
| B | `clean` | Review passed with no findings |
| B | `fixes_pushed` | Fixed findings, pushed — needs re-review (launch replacement Phase B) |
| B | `merge_ready` | All checks green, merge gate satisfied |
| B | `exhaustion` | Token budget running low — replacement Phase B needed |
| C | `ac_verified` | All acceptance criteria verified and checked off — ready for user merge decision |
| C | `blocked` | Merge blocked (CI failure, missing approvals, unchecked AC) |

**Rules:**
- The exit report MUST be the very last thing the subagent outputs before exiting
- The `EXIT_REPORT` header line is required — the parent uses it to locate the block
- One field per line, colon-separated, no extra whitespace around values
- When a subagent detects it is **approaching** token exhaustion (see detection signals above), it MUST write handoff state, print the exit report (with `OUTCOME: exhaustion` for Phase B, or the best-available outcome for other phases), and exit cleanly — all **before** hitting the hard token limit

### Subagent Task Decomposition (Token Safety)

Subagents have a hardcoded **32K output token limit** that cannot be configured ([known Claude Code limitation](https://github.com/anthropics/claude-code/issues/25569)). A single subagent that reads 10-20 CR findings, fixes code, pushes, replies to every thread, AND polls for the next review will exhaust its token budget and die mid-poll. To prevent this, break PR lifecycle work into sequential phases:

**Phase A: Fix + Push** (heaviest — uses most tokens)
- Read CR/Greptile findings from GitHub API
- Read affected source files
- Fix all valid findings + fix lint/CI failures
- Commit all fixes in ONE commit, push once
- Reply to all review comment threads (for Greptile: plain text only — do not include `@greptileai`, every @mention triggers a paid re-review)
- **Write handoff file** to `~/.claude/handoffs/pr-{N}-handoff.json` (see "Structured Handoff Files" section below) with all findings fixed, threads replied/resolved, files changed, and HEAD SHA. Include `findings_dismissed` for any findings verified as false positives (each entry: `{id, reason}`).
- **Print the Structured Exit Report and EXIT — do not enter polling loop.** The exit report is your final output. Use `OUTCOME: pushed_fixes` if you fixed findings, `OUTCOME: no_findings` if the review was already clean. Set `NEXT_PHASE: B`.

**Phase B: Review Loop** (lighter — incremental)
- **Phase B Initialization:** On startup, check for `~/.claude/handoffs/pr-{N}-handoff.json`:
  1. **If found:** Parse and validate (`schema_version`, `pr_number`, `phase_completed`). Extract `head_sha`, `reviewer`, `threads_replied`, `threads_resolved`, `findings_fixed` to avoid duplicate work. Log: "Loaded handoff file from Phase A."
  2. **If missing or invalid:** Fall back to GitHub API reconstruction (existing behavior — fetch all 3 comment endpoints). Log: "No handoff file found, reconstructing state from GitHub API."
- **Before ANY `@greptileai` trigger**, check the daily budget (see `greptile.md` "Daily Budget"). If exhausted, fall back to self-review and report the blocker — do not post `@greptileai`.
- If this PR is on CR: poll for CR review (fast-path + 7-minute slow-path Greptile trigger). If Greptile is triggered, the PR switches to Greptile permanently.
- If this PR is already on Greptile: skip CR polling, trigger `@greptileai` and poll for Greptile response directly.
- If Greptile posts findings: classify by severity (P0/P1/P2). Fix all valid findings, commit, push, reply.
  - **BEFORE any re-trigger:** Run the severity gate checklist (see `greptile.md` "Before EVERY `@greptileai` Re-Trigger (MANDATORY — after initial trigger)").
  - If any P0: proceed through severity gate → budget check → trigger `@greptileai` again (max 3 total Greptile reviews per PR).
  - If only P1/P2 (no P0): STOP — merge-ready after fix push. Do NOT trigger `@greptileai`. Proceed to Phase B completion.
- If clean pass on CR: trigger one more `@coderabbitai full review` for confirmation (2 clean CR passes needed)
- If clean Greptile pass (no findings at all): merge-ready immediately.
- **Phase B Completion:** Update the handoff file at `~/.claude/handoffs/pr-{N}-handoff.json` — set `phase_completed` to `"B"`, refresh `head_sha` if there was a new push, and merge new entries into `findings_fixed`, `threads_replied`, `threads_resolved`, and `files_changed`. **Deduplicate deterministically per field:** for `string[]` fields (`findings_fixed`, `threads_replied`, `threads_resolved`, `files_changed`), dedupe by exact string value; for object arrays (`findings_dismissed`), dedupe by `.id`. This prevents duplicate accumulation when replacement agents re-process the same findings.
- **Print the Structured Exit Report and EXIT.** Use the appropriate `OUTCOME`:
  - `clean` — review passed with no findings (set `NEXT_PHASE: C`)
  - `fixes_pushed` — fixed findings and pushed, needs re-review (set `NEXT_PHASE: B` for replacement agent)
  - `merge_ready` — merge gate satisfied, all checks green (set `NEXT_PHASE: C`)
  - `exhaustion` — token budget running low, replacement needed (set `NEXT_PHASE: B`)

**Phase C: Merge Prep** (lightest)
- **Phase C Initialization:** Read `~/.claude/handoffs/pr-{N}-handoff.json` if it exists. Use `reviewer` and `phase_completed` fields to confirm merge gate expectations. Fall back to GitHub API if missing.
- Verify merge gate is satisfied: if PR is on Greptile, see `greptile.md` "Detecting a Merge-Ready Greptile Review". If CR-only, 2 clean CR reviews.
- Read PR body, verify all acceptance criteria against final code
- Check off all boxes
- Report ready for merge
- **Phase C Cleanup (after successful merge only):** Delete the handoff file: `rm ~/.claude/handoffs/pr-{N}-handoff.json`. If merge fails or is aborted, do NOT delete the handoff file. Cleanup failure is non-fatal — log a warning but don't block.
- **Print the Structured Exit Report and EXIT.** Use `OUTCOME: ac_verified` when all acceptance criteria are verified and checked off (set `NEXT_PHASE: none`). Use `OUTCOME: blocked` if merge is blocked by CI failures, missing approvals, or unchecked AC items (set `NEXT_PHASE: none` — parent will report blocker to user).

**Orchestration rules:**
- Parent agent launches Phase A subagents (can run in parallel across different PRs)
- **When Phase A completes, parent MUST launch Phase B immediately** — see "Phase A Completion Protocol" below
- When Phase B reports clean, parent launches Phase C
- **Soft limit on parallel Phase B PRs:** aim for 3-4 active CR-polled PRs at once to reduce CR throttling and unnecessary Greptile fallback cost. Each PR tracks its own reviewer assignment: CR-only PRs need 2 clean CR passes; Greptile PRs use severity gate (see `greptile.md`).
- **Track CR quota.** Maintain a running count of CR reviews consumed this hour. Increment when: pushing to a PR with CR configured (auto-review), or posting `@coderabbitai full review`. If count reaches 7 in the current hour, expect Greptile to be the primary reviewer for remaining PRs until the window resets.
- Use judgment on small PRs: if CR only found 1-2 findings, a single subagent may handle the full lifecycle without hitting token limits

### Phase A Completion Protocol (MANDATORY)

**WHEN** a subagent returns and reports a PR was created or updated, **THEN** execute this checklist immediately — before any other work:

1. **Verify the push happened.** Run `gh pr view N --json commits --jq '.commits[-1].oid'` and confirm the SHA matches what the subagent reported. If the push didn't happen, the subagent silently failed — report to user.
2. **Verify the handoff file was written.** Check `~/.claude/handoffs/pr-{N}-handoff.json` exists and contains valid JSON with `phase_completed: "A"`. If missing, the subagent skipped the handoff write — reconstruct from the subagent's output and write it yourself before launching Phase B.
3. **Check if reviewers already posted findings.** Fetch all 3 comment endpoints for the PR (`per_page=100` on each). If CR or Greptile already posted findings (common if the review was fast), include those findings in the Phase B prompt.
4. **Launch Phase B within 60 seconds.** This is the immediate next action — queue it ahead of any other work (creating issues, reading files, responding to unrelated questions). If you cannot launch within 60 seconds due to tool throttling, tell the user why and when you will launch, then automatically retry until Phase B is launched (do not wait for user action). Record the planned retry in `session-state.json`. Include the handoff file path (`~/.claude/handoffs/pr-{N}-handoff.json`) in the Phase B subagent prompt.
5. **Update `session-state.json`.** Write the phase transition: PR moved from Phase A to Phase B, record the HEAD SHA, reset review state.
6. **Report to user.** "Phase A complete for PR #N — fixes pushed (SHA `abc1234`). Phase B launched, polling for reviews."

**Phase B launch is the highest-priority action after Phase A reports.** Do not start other substantive work until Phase B is launched for every PR that completed Phase A. If multiple Phase A agents complete simultaneously, launch Phase B for each one before doing anything else.

### Phase B Completion Protocol (MANDATORY)

**WHEN** a Phase B subagent returns, **THEN** parse its Structured Exit Report and execute this checklist immediately — before any other work:

1. **Parse the exit report.** Extract `PR_NUMBER`, `HEAD_SHA`, `OUTCOME`, `REVIEWER`, and `NEXT_PHASE` from the `EXIT_REPORT` block. If the subagent exited without printing an exit report, treat it as a silent failure — report to user and check GitHub API for current state.
2. **Branch on OUTCOME:**
   - `clean` or `merge_ready` → proceed to step 3 (launch Phase C)
   - `fixes_pushed` → launch a **replacement Phase B** subagent within 60 seconds. Include the handoff file path and note that this is a continuation. Update `session-state.json` with the new HEAD SHA. Report to user: "Phase B for PR #N pushed fixes (SHA `abc1234`). Launching replacement Phase B for re-review."
   - `exhaustion` → launch a **replacement Phase B** subagent within 60 seconds with the remaining work from the handoff file/session-state. Report to user: "Phase B for PR #N exhausted tokens. Launching replacement."
3. **Verify review state via GitHub API.** For `clean`/`merge_ready` outcomes, confirm the merge gate is actually met:
   - CR-only: verify 2 clean CR reviews exist
   - Greptile: verify severity gate is satisfied (see `greptile.md`)
   - If verification fails, launch a replacement Phase B instead of Phase C
4. **Launch Phase C within 60 seconds.** This is the immediate next action for `clean`/`merge_ready` outcomes. Include the handoff file path (`~/.claude/handoffs/pr-{N}-handoff.json`) in the Phase C subagent prompt.
5. **Update `session-state.json`.** Write the phase transition: PR moved from Phase B to Phase C (or Phase B to Phase B for replacements), record the HEAD SHA, update review state.
6. **Report to user (with timestamp).** "Mon Mar 16 02:34 AM ET — Phase B complete for PR #N — reviews clean (SHA `abc1234`). Phase C launched, verifying acceptance criteria."

**Phase C launch is the highest-priority action after Phase B reports clean.** Do not start other substantive work until Phase C is launched for every PR that completed Phase B with a clean/merge_ready outcome.

### Phase C Completion Protocol (MANDATORY)

**WHEN** a Phase C subagent returns, **THEN** parse its Structured Exit Report and execute this checklist immediately:

1. **Parse the exit report.** Extract `PR_NUMBER`, `OUTCOME`, and `HEAD_SHA` from the `EXIT_REPORT` block. If no exit report, treat as silent failure — check GitHub API.
2. **Branch on OUTCOME:**
   - `ac_verified` → all acceptance criteria verified and checked off. Ask the user: "Reviews are clean, all AC verified and checked off for PR #N. Want me to squash and merge and delete the branch, or do you want to review the diff yourself first?"
   - `blocked` → report the blocker to the user with details from the handoff file or subagent output. Do NOT merge.
3. **Update `session-state.json`.** Mark the PR as Phase C complete. Remove from `active_agents`.
4. **Report to user (with timestamp).** Include timestamp, the outcome, and next action (merge decision or blocker details).

### Monitor Loop — Per-Cycle Checklist (MANDATORY)

Every ~60-second monitor cycle, execute these steps **in priority order**. Higher-priority items MUST be handled before lower-priority ones:

1. **Check for completed subagents.** Poll all active subagent statuses. If any have returned results, process them immediately (steps 2-3).
2. **Execute pending phase transitions.** For each completed subagent:
   - Parse its Structured Exit Report
   - Execute the appropriate Completion Protocol (Phase A → B, Phase B → C, Phase C → merge decision)
   - This is the highest-priority action — do it before heartbeats or status checks
3. **Check for pending transitions from prior cycles.** Read `session-state.json` for any PRs where a phase completed but the next phase was not yet launched (e.g., due to tool throttling or compaction). Launch the pending phase immediately.
4. **Send heartbeat/status message.** If >5 minutes since last user message, send a status update. Include: active agents, PR phases, any pending transitions, any blockers.
5. **Check for stale agents.** If any subagent has been running for an unusually long time without reporting (>15 minutes for Phase A, >10 minutes for Phase B polling, >5 minutes for Phase C), investigate — it may have silently failed.

> **The key insight:** Execute transitions (Steps 2-3) before sending heartbeats (Step 4) — stale heartbeats reporting outdated phase state are misleading.

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

> **Monitor mode prerequisite:** The ~60s polling obligation below is enforceable precisely because Dedicated Monitor Mode (see below) prohibits the parent from doing competing substantive work. If you have active subagents, you are in monitor mode — polling is your primary job, not a side task.

1. **Poll subagent status every ~60 seconds.** When running subagents in the background, check their status regularly. Do not fire-and-forget. Monitor mode ensures you have no competing work — polling is your only responsibility.
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

> **Monitor mode makes this easy.** When in Dedicated Monitor Mode (see below), heartbeats are one of your few permitted activities. There is no competing work to displace them — if you miss a heartbeat while in monitor mode, something is fundamentally wrong with your loop.

**Rules:**
1. **In monitor mode**, heartbeats are part of your core loop: poll subagent status → compose status message → send to user → wait → repeat. There is no "multi-step operation" competing for attention.
2. **Outside monitor mode** (no active subagents), send a brief status message before entering any multi-step operation: "16:03 ET — Fixing 2 CR findings on PR #620. Will update in ~3 min."
3. **After completing any multi-step operation**, immediately send a status update — don't start the next operation first.
4. **If you're blocked waiting** (e.g., polling), use that wait time to compose a dashboard message to the user.
5. **Never batch status updates.** Don't wait until everything is done to report. Report incrementally: "PR #620 fix pushed. Now checking PR #618 status."
6. **Time your silences.** If your last message to the user was >5 minutes ago by wall clock, your next tool call must be a status message, not another background operation.

### Heartbeat Enforcement (Automatic)

The 5-minute heartbeat rule is enforced by a PostToolUse hook (`silence-detector.sh`). After every tool call, the hook checks how long it has been since the agent last sent a visible message. If >5 minutes, a warning is injected into the agent's context via `additionalContext`.

**How it works:** Stop hook (`silence-detector-ack.sh`) touches `/tmp/claude-heartbeat-$CLAUDE_SESSION_ID` after each response. PostToolUse hook (`silence-detector.sh`) checks mtime after tool calls; if >5 min elapsed, injects warning via `additionalContext`.

**When you see the warning:** Stop what you are doing and send a status message to the user immediately. Include a timestamp (run `date` command), what you're currently doing, what's pending, and any blockers. Then resume your work — the next tool call will check again and the warning will be gone (because the Stop hook touched the file after your status message).

### Dedicated Monitor Mode (MANDATORY for parent agents)

When one or more subagents are active, the parent agent enters **monitor mode**. In monitor mode, the parent's sole responsibility is orchestration — not substantive work. This prevents monitoring obligations (heartbeats, Phase B launches, failure detection) from being displaced by coding or other heavy tasks.

**Entry condition:** Monitor mode activates whenever `active_agents` in `session-state.json` is non-empty, or when you have spawned any subagent that has not yet completed or failed.

**Exit condition:** Monitor mode deactivates when ALL of the following are true:
- All subagents have completed or failed (no active agents)
- No PRs are awaiting review (no pending Phase B/C launches)
- All phase transitions have been executed (no Phase A completions waiting for Phase B launch)

**Permitted activities in monitor mode (exhaustive list):**
- Poll subagent status (~60s cycle)
- Send heartbeat/status messages to the user
- Launch next-phase agents (Phase A → B → C transitions)
- Verify subagent outputs (check pushes, check replies)
- Read `session-state.json` and update it
- Reconstruct state after context compaction
- Respond to user questions about status or progress
- Write checkpoint state to `session-state.json`

**Prohibited activities in monitor mode (substantive work):**
- Writing or editing code/files directly
- Creating GitHub issues or PRs
- Reading/analyzing source files for non-monitoring purposes
- Running local CR reviews
- Any non-monitoring multi-step operation that could displace the polling loop
  (monitoring tasks like state reconstruction, output verification, and checkpoint writes are exempt)
- Fixing code yourself instead of delegating to a subagent

> **The core principle:** If it can be delegated to a subagent, it MUST be delegated. The parent's job is to orchestrate, not to execute.

**Exception: Explicit user request.** If the user explicitly asks the parent to perform substantive work while subagents are active, the parent MAY do so — but must first warn:

> "I have N active subagent(s) monitoring PR(s) #X, #Y. Monitoring will pause while I work on this. Heartbeats and phase transitions may be delayed until I finish."

After completing the user-requested work, immediately re-enter monitor mode:
1. Check all subagent statuses (some may have completed or failed while you were working)
2. Execute any pending phase transitions
3. Send a status update to the user
4. Resume the normal monitoring loop

**How to delegate instead of doing it yourself:**

When you identify work that needs doing (e.g., a new issue to create, code to fix, a file to update) while in monitor mode:
1. Spawn a subagent with the task
2. Add it to `active_agents` in `session-state.json`
3. Continue monitoring — the new subagent is now part of your monitoring set

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
6. **Check for pending phase transitions.** Read `session-state.json` for any PRs where a phase completed but the next phase was never launched (e.g., Phase A done but Phase B not launched; Phase B `merge_ready` but Phase C not launched; Phase C `ac_verified` but merge prompt not shown). For each, execute the appropriate Completion Protocol immediately. This is the **second most common post-compaction failure** after missing Phase B coverage.
7. **Report to the user.** Post the reconstructed dashboard with a note: "Resuming after context compaction. Reconstructed state from GitHub. [N agents may need relaunching, N pending transitions executed]."
8. **Resume the monitoring loop.** Re-enter the polling cycle for any PRs still awaiting reviews.

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
  "greptile_daily": {"reviews_used": 12, "date": "2026-03-16", "budget": 40},
  "active_agents": [
    {"id": "a3f8d26fa75eddcb3", "task": "PR #623 Phase C", "launched": "2026-03-16T15:55:00Z"}
  ]
}
```
After compaction, read this file first: `cat ~/.claude/session-state.json`, then reconcile with live GitHub state. Also check `~/.claude/handoffs/` for any existing handoff files — if a handoff file exists for a PR that session-state reports is in Phase B or C, use the handoff file to bootstrap detailed state (findings fixed, threads replied, etc.) before falling back to GitHub API reconstruction.

### Structured Handoff Files (Per-PR Phase-to-Phase State Transfer)

Handoff files provide structured state transfer between subagent phases. Instead of each phase reconstructing state from GitHub API calls (fragile, token-expensive), the completing phase writes a handoff file that the next phase reads on startup.

#### Two-File State System

The orchestration uses two complementary state files:

| File | Scope | Purpose |
|------|-------|---------|
| `~/.claude/session-state.json` | Session-wide | High-level orchestration: which PRs exist, what phase each is in, CR/Greptile quota, active agents |
| `~/.claude/handoffs/pr-{N}-handoff.json` | Per-PR | Detailed phase state: findings fixed, threads replied/resolved, files changed — consumed by the next phase |

`session-state.json` must still be updated on phase transitions (existing behavior unchanged). Handoff files complement it with the detailed per-PR context that subagents need.

#### Handoff File Storage

- **Location:** `~/.claude/handoffs/` (create directory if it doesn't exist: `mkdir -p ~/.claude/handoffs/`)
- **Naming:** `pr-{N}-handoff.json` where `N` is the PR number (e.g., `pr-618-handoff.json`)
- **One file per PR at any time.** Phase A creates the initial handoff file. Phase B performs a read-modify-write update: read the existing file, merge changes (append new array entries, update scalar fields), preserve unknown fields, and write back. Phase C only reads the file for context, then deletes it after successful merge.
- **Lifecycle:** Created by Phase A → read/updated by Phase B → read then deleted by Phase C after merge.

#### Handoff File Schema

```json
{
  "schema_version": "1.0",
  "pr_number": 618,
  "head_sha": "abc1234",
  "reviewer": "cr",
  "phase_completed": "A",
  "created_at": "2026-03-24T17:00:00Z",
  "findings_fixed": ["comment-id-1", "comment-id-2"],
  "findings_dismissed": [
    {"id": "comment-id-3", "reason": "false positive — code already handles this case"}
  ],
  "threads_replied": ["thread-id-1", "thread-id-2"],
  "threads_resolved": ["thread-id-1", "thread-id-2"],
  "files_changed": ["src/foo.ts", "src/bar.ts"],
  "push_timestamp": "2026-03-24T17:00:00Z",
  "notes": "CR had 3 findings, all fixed. 1 dismissed as false positive."
}
```

**Field reference:**

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `schema_version` | string | yes | Always `"1.0"` — for forward compatibility |
| `pr_number` | number | yes | The PR number |
| `head_sha` | string | yes | HEAD SHA after the phase's last push |
| `reviewer` | string | yes | `"cr"` or `"greptile"` — which reviewer owns this PR |
| `phase_completed` | string | yes | `"A"`, `"B"`, or `"C"` |
| `created_at` | string | yes | ISO 8601 timestamp when the handoff file was written |
| `findings_fixed` | string[] | yes | Comment/review IDs of findings that were fixed |
| `findings_dismissed` | object[] | no | Findings dismissed with reason (id + reason) |
| `threads_replied` | string[] | yes | Thread IDs where a reply was posted |
| `threads_resolved` | string[] | yes | Thread IDs that were resolved via GraphQL |
| `files_changed` | string[] | yes | File paths modified during the phase |
| `push_timestamp` | string | yes | ISO 8601 timestamp of the phase's last push |
| `notes` | string | no | Free-text summary for debugging |

**Forward compatibility:** Unknown fields must be preserved when reading and rewriting the file. Do not strip fields you don't recognize — a future schema version may have added them.

### Mandatory Subagent Review Protocol (COPY INTO EVERY SUBAGENT PROMPT)

Since subagents receive the full rules (see above), this section serves as a **quick-reference summary** of the review protocol. The full details are in the other rule files — this summary exists so subagents can quickly locate the critical steps without scanning everything.

```text
## GitHub Review Loop — Quick Reference

AUTONOMY RULE: Every step below is AUTOMATIC. Do NOT ask "should I?" or "want me to?"
at any point. The ONLY user-prompted action is the final merge decision (Step 4).
If you are running low on tokens, write handoff state to session-state.json, print the
Structured Exit Report, and exit cleanly — do NOT ask the user what to do.

EXIT REPORT RULE: Before exiting, you MUST print a Structured Exit Report as your final
output. Format: fenced code block starting with `EXIT_REPORT`, one key-value pair per line:
PHASE_COMPLETE, PR_NUMBER, HEAD_SHA, REVIEWER, OUTCOME, FILES_CHANGED, NEXT_PHASE,
HANDOFF_FILE. The parent parses this mechanically — omitting it causes silent failures.

After pushing code and creating/updating a PR, follow this EXACT sequence:

### Step 0a: Check Handoff File (Phase B/C only)
Before any other work, check for `~/.claude/handoffs/pr-{N}-handoff.json`:
- If found: parse it. Use `head_sha`, `reviewer`, `threads_replied`, `threads_resolved`,
  `findings_fixed` to understand what the previous phase already did. This avoids
  duplicate API calls and duplicate thread replies.
- If missing: fall back to GitHub API reconstruction (fetch all 3 endpoints).
- Log which path was taken for debugging.

### Step 0b: Check for unresolved findings BEFORE requesting any review
BEFORE triggering `@coderabbitai full review` or entering the polling loop:
1. Fetch all comments on the PR (all 3 endpoints, per_page=100)
2. Look for unresolved findings from coderabbitai[bot] or greptile-apps[bot]
3. If unresolved findings exist -> fix them, push, reply, resolve threads FIRST
4. Only request a new review after all prior findings are addressed
Skipping this step wastes a review cycle and burns CR quota.

### Step 0b: Check ALL CI check-runs (MANDATORY — every poll cycle)
Fetch ALL check-runs once per cycle (reuse this result in Step 1b for CR rate-limit detection):
`gh api "repos/{owner}/{repo}/commits/{SHA}/check-runs?per_page=100" --jq '.check_runs[] | {id, name, status, conclusion, title: .output.title}'`
If ANY check-run has a blocking conclusion (`failure`, `timed_out`, `action_required`, `startup_failure`, `stale`):
1. Read the failure output: `gh api "repos/{owner}/{repo}/check-runs/{ID}" --jq '.output.summary'`
2. If test/lint/build failure -> fix code, commit, push BEFORE continuing review loop
3. If transient/infra failure -> note it, retry with no-op commit if needed
A PR with passing CR but failing CI is NOT merge-ready. Report CI status to user.

### Step 1: Check if PR is already on Greptile
If this PR has already switched to Greptile (check session-state `reviewer` field), skip CR polling entirely — go directly to Step 3 and trigger `@greptileai`.

### Step 1b: Wait for CR review (only if PR is still on CR)
- Poll every 60s on all 3 endpoints (per_page=100):
  - `repos/{owner}/{repo}/pulls/{N}/reviews?per_page=100`
  - `repos/{owner}/{repo}/pulls/{N}/comments?per_page=100`
  - `repos/{owner}/{repo}/issues/{N}/comments?per_page=100`
- Filter by `coderabbitai[bot]` (with [bot] suffix)
- Reuse the Step 0b check-runs result for CR rate-limit fast-path detection:
  Find the CodeRabbit entry in the already-fetched check-runs. If it shows "rate limit" in output.title with conclusion "failure" -> Greptile IMMEDIATELY.
  If no CodeRabbit check-run in the result, also check: `gh api "repos/{owner}/{repo}/commits/{SHA}/statuses"`

### Step 2: After 7 minutes with no review -> trigger Greptile (NO EXCEPTIONS)
If 7 minutes pass and CR has not delivered review content, trigger Greptile.
It does NOT matter whether you see an explicit rate-limit signal.
The "Actions performed" ack means CR STARTED — it is NOT a review.
If you see the ack but no review within 7 minutes, CR failed to deliver.
**Once Greptile is triggered, this PR stays on Greptile permanently.**

### Step 3: Trigger Greptile (if not already running)
0. **CHECK DAILY BUDGET FIRST** — read `greptile_daily` from session state. If `reviews_used >= budget`, do NOT trigger Greptile. Fall back to self-review and report the blocker to the user. See `greptile.md` "Daily Budget".
1. Post: `gh pr comment <PR_NUMBER> --body "@greptileai"`
2. Poll every 60s for `greptile-apps[bot]` comments on the same 3 endpoints
3. Timeout after 5 minutes (Greptile typically responds in 1-3 minutes)
4. If no response, do a self-review instead
5. Process Greptile findings same as CR: fix all valid findings in one commit, push once
6. Reply to EVERY Greptile comment thread confirming the fix using **plain text (no `@greptileai` mention)**:
   - Inline comments: `gh api repos/{owner}/{repo}/pulls/comments/{id}/replies -f body="Fixed in \`SHA\`: <what changed>"`
   - Issue/PR-level comments: `gh pr comment N --body "Fixed in \`SHA\`: <what changed>"`
   **Do NOT include `@greptileai` in replies** — every @mention triggers a new paid review ($0.50-$1.00).
   Greptile does not learn from text replies (only from 👍/👎 reactions). Replies are for thread management only.
   Pushing code does NOT resolve threads — you MUST post explicit replies.

### After Greptile fix+push: severity-gated re-review (MANDATORY checklist)
Once a PR is on Greptile, it stays on Greptile. Do NOT switch back to CR.
1. **Classify all findings** (P0/P1/P2).
2. **If NO P0:** STOP — skip `@greptileai`. Proceed to merge gate.
3. **If P0 present:** budget check → trigger `@greptileai`.
4. **Log severity counts in handoff notes.**
5. **Max 3 Greptile reviews per PR** (initial + up to 2 P0 re-reviews). After 3, self-review + tell user.

### Greptile clean / merge-ready detection
A Greptile review is merge-ready when:
- No findings at all (fully clean), OR
- Findings are all P1/P2 (no P0) — fix them but skip re-review, OR
- Re-review after P0 fix shows no P0 findings
Also watch for 👍 completion signal with no inline comments.
**Max 3 Greptile reviews per PR.** After 3, self-review + report blocker.
Check-run name: TBD — update after first Greptile review on this repo.

### Step 4: Merge gate
The merge gate depends on which reviewer owns the PR:
- **CR-only** (Greptile never triggered): 2 clean CR reviews required (confirmation pass needed due to unreliable signals)
- **Greptile** (triggered at any point): severity-gated:
  - No P0 on first review -> merge-ready after fixing P1/P2 (no re-review)
  - P0 on first review -> fix + 1 re-review to confirm P0 resolution
  - Max 3 Greptile reviews per PR. After 3, self-review + report blocker.

If BOTH reviewers are down (CR rate-limited + Greptile timeout), perform self-review for risk reduction and report the blocker. Self-review does NOT satisfy the merge gate.

### Final Step: Handoff File + Exit Report (per-phase)
- **Phase A (create + exit):** `mkdir -p ~/.claude/handoffs/` then write a new
  `~/.claude/handoffs/pr-{N}-handoff.json` with all schema fields:
  `schema_version`, `pr_number`, `head_sha`, `reviewer`, `phase_completed` ("A"),
  `created_at`, `findings_fixed`, `findings_dismissed`, `threads_replied`,
  `threads_resolved`, `files_changed`, `push_timestamp`, `notes`.
  Then print the Structured Exit Report: `OUTCOME: pushed_fixes` or `no_findings`,
  `NEXT_PHASE: B`.
- **Phase B (read-modify-write + exit):** Read existing handoff file, merge new entries
  into arrays (deduplicate per field: by exact string value for `string[]` fields,
  by `.id` for object arrays like `findings_dismissed`), update `phase_completed` to "B", refresh
  `head_sha` if pushed. Do NOT overwrite `created_at` or `push_timestamp` from
  Phase A — only set `push_timestamp` if Phase B itself pushed a new commit.
  Preserve unknown fields.
  Then print the Structured Exit Report: `OUTCOME: clean`/`merge_ready`/`fixes_pushed`/`exhaustion`,
  `NEXT_PHASE: C` (clean/merge_ready) or `B` (fixes_pushed/exhaustion).
- **Phase C (read then delete + exit):** Read handoff file for reviewer/state context.
  Do NOT update or rewrite the file. After successful merge only, delete it:
  `rm ~/.claude/handoffs/pr-{N}-handoff.json`. Deletion failure is non-fatal.
  Then print the Structured Exit Report: `OUTCOME: ac_verified` or `blocked`,
  `NEXT_PHASE: none`.
```
