# Phase Completion Protocols & Exit Reports

> **Always:** Print a Structured Exit Report as the final output before every subagent exits. Execute the appropriate Completion Protocol immediately when a subagent returns. Verify outputs before marking complete.
> **Ask first:** Merging — always ask the user. Respawning a failed subagent — tell the user what happened.
> **Never:** Skip the exit report. Launch the next phase without verifying the previous phase's outputs. Ask permission for autonomous phase transitions.

## Structured Exit Report (MANDATORY — all phases)

Every subagent MUST print a structured exit report as its **final output**. The parent parses results mechanically from this block.

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

### Field Reference

| Field | Values | Description |
|-------|--------|-------------|
| `PHASE_COMPLETE` | `A`, `B`, `C` | Which phase just finished |
| `PR_NUMBER` | integer | The PR number |
| `HEAD_SHA` | string | HEAD SHA after last push (or current HEAD) |
| `REVIEWER` | `cr`, `greptile` | Which reviewer owns this PR |
| `OUTCOME` | see below | What happened |
| `FILES_CHANGED` | comma-separated paths | Files modified (empty string if none) |
| `NEXT_PHASE` | `B`, `C`, `none` | What parent should launch next |
| `HANDOFF_FILE` | path | Handoff file path (see `handoff-files.md`) |

### Valid OUTCOME Values

| Phase | Outcome | Meaning |
|-------|---------|---------|
| A | `pushed_fixes` | Findings fixed, code pushed |
| A | `no_findings` | Review already clean, code pushed as-is |
| A | `exhaustion` | Token budget low — partial fixes, replacement needed |
| B | `clean` | Review passed with no findings |
| B | `fixes_pushed` | Fixed findings, pushed — needs re-review |
| B | `merge_ready` | All checks green, merge gate satisfied |
| B | `exhaustion` | Token budget low — replacement needed |
| C | `ac_verified` | All AC verified and checked off |
| C | `blocked` | Merge blocked (CI failure, missing approvals, unchecked AC) |

**Rules:**
- Exit report MUST be the very last output before exiting
- `EXIT_REPORT` header line is required — parent uses it to locate the block
- One field per line, colon-separated, no extra whitespace
- On token exhaustion: print the report (with `OUTCOME: exhaustion`) **before** hitting the hard limit

## Phase A Completion Protocol (MANDATORY)

**WHEN** a Phase A subagent returns, execute immediately — before any other work:

1. **Parse the exit report.** Extract `PR_NUMBER`, `HEAD_SHA`, `OUTCOME`, `REVIEWER`, `NEXT_PHASE`. No exit report = silent failure — report to user, check GitHub API.
2. **Branch on OUTCOME:**
   - `pushed_fixes` or `no_findings` → proceed to step 3
   - `exhaustion` → launch replacement Phase A within 60s. Report to user. Skip steps 3-4.
3. **Verify the push.** `gh pr view N --json commits --jq '.commits[-1].oid'` — confirm SHA matches. Mismatch = silent failure.
4. **Verify handoff file.** Check `~/.claude/handoffs/pr-{N}-handoff.json` exists with `phase_completed: "A"`. If missing, reconstruct and write it yourself.
5. **Launch Phase B within 60 seconds.** Check if reviewers already posted findings (fetch all 3 comment endpoints, `per_page=100`). Include findings and handoff file path in prompt. If throttled, tell user and auto-retry.
6. **Update `session-state.json`.** Record phase transition and HEAD SHA.
7. **Report to user.** "Phase A complete for PR #N — fixes pushed (SHA `abc1234`). Phase B launched."

**Phase B launch is the highest-priority action after Phase A reports.** Do not start other work until Phase B is launched for every completed Phase A.

## Phase B Completion Protocol (MANDATORY)

**WHEN** a Phase B subagent returns, execute immediately:

1. **Parse the exit report.** No exit report = silent failure.
2. **Branch on OUTCOME:**
   - `clean` or `merge_ready` → proceed to step 3 (launch Phase C)
   - `fixes_pushed` → launch replacement Phase B within 60s. Update `session-state.json`. Report to user.
   - `exhaustion` → launch replacement Phase B within 60s. Report to user.
3. **Verify review state via GitHub API.** Confirm merge gate is met:
   - CR-only: verify 2 clean CR reviews exist
   - Greptile: verify severity gate (see `greptile.md`)
   - If verification fails, launch replacement Phase B instead of Phase C
4. **Launch Phase C within 60 seconds.** Include handoff file path in prompt.
5. **Update `session-state.json`.** Record phase transition and HEAD SHA.
6. **Report to user (with timestamp).**

**Phase C launch is the highest-priority action after Phase B reports clean.**

## Phase C Completion Protocol (MANDATORY)

**WHEN** a Phase C subagent returns, execute immediately:

1. **Parse the exit report.** No exit report = silent failure — check GitHub API.
2. **Branch on OUTCOME:**
   - `ac_verified` → ask user: "Reviews clean, all AC verified for PR #N. Want me to squash and merge, or review the diff first?"
   - `blocked` → report blocker details to user. Do NOT merge.
3. **Update `session-state.json`.** Mark Phase C complete, remove from `active_agents`.
4. **Report to user (with timestamp).**
