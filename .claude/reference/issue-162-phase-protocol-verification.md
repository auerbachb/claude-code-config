# Issue #162 — Phase protocols & exit reports verification

**Date:** 2026-04-29  
**Scope:** Static verification against shipped rules and agent templates (PR #160). No live Cursor parent/subagent runs in this environment.

**Artifacts added in this change:**

- `.claude/scripts/verify-exit-report-block.sh` — machine check for required `EXIT_REPORT` fields (stdin).

## 1. Exit report format (AC: structured `EXIT_REPORT` parses)

**Source of truth:** `.claude/reference/exit-report-format.md`, templates in `.claude/agents/phase-a-fixer.md`, `phase-b-reviewer.md`, `phase-c-merger.md`.

**Method:** Extracted canonical example blocks and ran:

```bash
.claude/scripts/verify-exit-report-block.sh < sample.txt
```

| Sample | Origin | Result |
|--------|--------|--------|
| Phase A block (8 fields) | `exit-report-format.md` | PASS |
| Phase B block | `phase-b-reviewer.md` template | PASS |
| Phase C block (`FILES_CHANGED:` empty) | `phase-c-merger.md` template | PASS |
| Incomplete block | synthetic | FAIL (missing fields) |

**Note on issue #162 wording:** Test scenarios asked for a “fenced” block; agent instructions use a ```text fence in markdown for readability. The runtime contract is the plain `EXIT_REPORT` header plus colon-separated lines (see `exit-report-format.md`).

## 2. Phase B Completion Protocol (6-step checklist)

**Source:** `.claude/rules/phase-protocols.md` — “Phase B Completion Protocol (MANDATORY)”, numbered steps 1–6:

1. Parse the exit report  
2. Branch on OUTCOME (`merge_ready` vs replacement path)  
3. Verify review state via GitHub API before Phase C  
4. Launch Phase C within 60s only with merge authorization  
5. Update `session-state.json`  
6. Report to user (with timestamp)  

**Verification:** Checklist is explicit and ordered; “Phase C launch is top priority after Phase B reports `merge_ready`” is stated immediately after the list. **Behavioral enforcement** in-repo is via parent-agent rules (`phase-protocols.md`, `subagent-orchestration.md`); this pass did not execute a live parent loop.

**Doc drift (GitHub issue vs rules):** Issue #162 “Test Scenarios §3” says to verify behavior “After Phase B reports `clean` or `merge_ready`”. The **authoritative** rule is: only `merge_ready` advances to Phase C; `clean` triggers replacement Phase B (`phase-protocols.md` Phase B step 2). Treat the issue scenario text as outdated relative to `phase-protocols.md`.

## 3. Phase C Completion Protocol

**Source:** `.claude/rules/phase-protocols.md` — “Phase C Completion Protocol (MANDATORY)” lists **five** numbered steps (parse → branch on OUTCOME → update session-state → handoff cleanup after confirmed merge → report). Issue #162 AC called this “4-step”; the committed rule file has five numbered items — align AC with the file or renumber in a follow-up doc edit.

**Merge / handoff:** Phase C agent template (`phase-c-merger.md`) states the parent deletes the handoff only after `OUTCOME: merged` and GitHub confirms merge — consistent with `phase-protocols.md` Phase C step 4.

**Doc drift:** Issue scenario §4 references `ac_verified`; Phase C `OUTCOME` values are `merged` | `blocked` per `exit-report-format.md` and agent template.

## 4. Monitor loop priority (transitions before heartbeats)

**Source:** `.claude/rules/monitor-mode.md` — “Monitor Loop — Per-Cycle Checklist (MANDATORY)”:

1. Process completed subagents and parse exit reports  
2. Execute phase transitions; launch transitions stalled in `session-state.json`  
3. Escalate-review for CR reviewer PRs  
4. Send heartbeat if due  
5. Investigate stale agents  

**Verification:** Steps 1–2 (parsing + transitions) are ordered **before** step 4 (heartbeat). **PASS** by specification audit.

## 5. Post-compaction recovery (pending phase transitions)

**Source:** `.claude/rules/monitor-mode.md` — “Post-Compaction Recovery (MANDATORY)” step 4: “Verify stale agent outputs, Phase B coverage, and **pending transitions**; launch anything stalled.”

**Verification:** Pending transitions are explicitly in the recovery checklist. **PASS** by specification audit.

## 6. Exhaustion / replacement (issue scenario 6)

Not exercised in this environment (no live token exhaustion). **Spec check:** Phase A template sets `OUTCOME: exhaustion` and `NEXT_PHASE: A`; Phase B template sets `OUTCOME: exhaustion` and `NEXT_PHASE: B`. Phase A protocol (`phase-protocols.md`) requires replacement Phase A within 60s without asking (exhaustion path). **Deferred:** runtime observation.

## Commands (reproduce)

```bash
# Phase A sample (from exit-report-format.md)
printf '%s\n' \
  EXIT_REPORT PHASE_COMPLETE: A PR_NUMBER: 618 HEAD_SHA: abc1234 \
  REVIEWER: cr OUTCOME: pushed_fixes \
  'FILES_CHANGED: src/foo.ts, src/bar.ts' NEXT_PHASE: B \
  'HANDOFF_FILE: ~/.claude/handoffs/pr-618-handoff.json' \
  | .claude/scripts/verify-exit-report-block.sh
```

## Follow-ups (optional GitHub issues)

1. Refresh issue #162 test scenarios: Phase B → C only on `merge_ready` (not `clean`); replace `ac_verified` with `merged` / `blocked`.  
2. Align “4-step” vs five numbered Phase C steps in AC wording.
