# Phase Completion Protocols & Exit Reports

> **Always:** Print a Structured Exit Report as the final output before every subagent exits. Execute the appropriate Completion Protocol immediately when a subagent returns. Verify outputs before marking complete.
> **Ask first:** Crashed/no-handoff respawns — tell the user first; exhaustion with valid handoff auto-respawns ("Always do").
> **Never:** Skip the exit report. Launch the next phase without verifying the previous phase's outputs. Do NOT ask permission for autonomous phase transitions — including Phase C after `merge_ready`.

## Launch gate before every successor

Immediately before any A→A, A→B, B→B, B→C, or queued-pipeline launch, re-read
both stop controls. Launch only when both reads succeed and return explicit
clear values: repo `refill.paused` false/null, and
`execution-pause.sh --status --session "$CLAUDE_SESSION_ID"` reporting
`inactive`. Anything else — paused, `active`, a missing helper, a non-zero read,
any other output — **fails closed**: persist the pending transition, report
which control was unreadable, launch nothing. This gate overrides every "within
60 seconds" instruction below; only an explicit `/end-resume` or
`/pause-resume` reopens it.

## Structured Exit Report (MANDATORY — all phases)

Every subagent MUST print an `EXIT_REPORT` block as its **final output** — one colon-separated field per line, no extra whitespace. Fields + valid `OUTCOME` values: `.claude/reference/exit-report-format.md`; evidence requirements: `.claude/reference/verification-evidence-patterns.md`. On exhaustion, print `OUTCOME: exhaustion` before the token limit.

## Phase A Completion Protocol (MANDATORY)

**WHEN** a Phase A subagent returns, execute immediately — before any other work:

1. **Parse the exit report.** Extract `PR_NUMBER`, `HEAD_SHA`, `OUTCOME`, `REVIEWER`, `NEXT_PHASE`. No exit report = silent failure — report to user, check GitHub.
2. **Branch on OUTCOME:**
   - `pushed_fixes` or `no_findings` → proceed to step 3
   - `exhaustion` → **run step 4 (worktree cleanup) now**, then launch replacement Phase A within 60s. Report to user. **STOP — do not execute steps 3, 5-7**.
3. **Verify the push.** `gh pr view N --json commits --jq '.commits[-1].oid'` — confirm SHA matches. Mismatch = silent failure.
4. **Clean up the Phase A worktree:** `git worktree remove <path> --force` (or `git worktree prune` on failure). Releases the branch lock for Phase B.
5. **Verify handoff file.** Resolve path with `handoff-state.sh --owner-repo owner/repo --path N` and confirm the file exists with `phase_completed: "A"`. If missing, reconstruct and write it yourself.
6. **Launch Phase B within 60 seconds.** Check all 3 comment endpoints; include findings and handoff path.
7. **Update `session-state.json`.** Record phase transition and HEAD SHA.

## Phase B Completion Protocol (MANDATORY)

**WHEN** a Phase B subagent returns, execute immediately:

1. **Parse the exit report.** No exit report = silent failure.
2. **Branch on OUTCOME:**
   - `merge_ready` → proceed to step 3 (launch Phase C). This is the single Phase-C-advancing terminal.
   - `clean`, `fixes_pushed`, or `exhaustion` → launch replacement Phase B within 60s, update `session-state.json` (keep phase B; record new SHA/remaining work as applicable), and **STOP**. Report `exhaustion` (a failure); `clean`/`fixes_pushed` are silent (`CLAUDE.md` #3).
3. **Verify review state via GitHub API.** Confirm the merge gate per `cr-merge-gate.md` Step 1. If verification fails, launch replacement Phase B instead of Phase C — STOP.
4. **Launch Phase C within 60 seconds.** No merge-approval pause — Phase C runs `/wrap` silently once gate + AC pass. Include the handoff path.
5. **Update `session-state.json`.** Record phase transition and HEAD SHA.

## Phase C Completion Protocol (MANDATORY)

**WHEN** a Phase C subagent returns, execute immediately:

1. **Parse the exit report.** No exit report = silent failure — check GitHub API.
2. **Branch on OUTCOME:**
   - `merged` → verify GitHub confirms the PR is merged (`merged == true`), then proceed to cleanup.
   - `blocked` → report blocker details to user. Do NOT merge.
3. **Update `session-state.json`.** Mark Phase C complete, remove from `active_agents`.
4. **Handoff cleanup (after successful merge only).** Delete the handoff file (`handoff-state.sh --owner-repo owner/repo --delete N`) after `OUTCOME: merged` confirmed by GitHub. If merge fails or is aborted, do NOT delete. Emit one line — `merged PR #N` — after a clean merge.

## `/wrap` → `/fixpr` Delegation Contract

`/wrap` Step 2.1 delegates recovery to the **full** `/fixpr` workflow — including when unresolved review threads are the only blocker. Full handoff semantics: `.claude/reference/wrap-fixpr-delegation.md`.
