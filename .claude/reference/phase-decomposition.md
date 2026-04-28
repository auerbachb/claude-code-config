# Phase Decomposition — Detailed Procedures

Canonical reference for per-phase subagent procedures. Used by agent definitions (`.claude/agents/phase-{a,b,c}-*.md`) and as a fallback when agent definitions are unavailable.

## Phase A: Fix + Push (heaviest)

1. Read CR/BugBot/Greptile findings, read affected files, fix all valid findings + lint/CI failures
2. Commit all fixes in ONE commit, push once
3. Reply to all review threads (see `greptile.md` for Greptile reply format)
4. Write handoff file (see `handoff-files.md`)
5. Print exit report and EXIT (see `phase-protocols.md`). Do not enter polling loop.

## Phase B: Review Loop (lighter)

1. Read handoff file on startup (GitHub API fallback if missing)
2. Before ANY `@greptileai` trigger, check daily budget (see `greptile.md`)
3. CR path: poll for review (fast-path → check BugBot → 10-min BugBot timeout → Greptile trigger). BugBot path: poll for BugBot review on the 3 endpoints. Greptile path: poll for existing Greptile review; only re-trigger `@greptileai` for P0 findings (max 3 reviews/PR).
4. Greptile findings: classify P0/P1/P2, fix all, commit, push, reply. Re-trigger only for P0 (max 3 reviews/PR).
5. CR gate: verify an explicit `state: "APPROVED"` CR review exists on the current HEAD SHA (stale approvals don't count — re-trigger if the latest approval's `commit_id` is not HEAD)
6. Update handoff file. Deduplicate: `string[]` by exact value, `findings_dismissed` by `.id`.
7. Print exit report and EXIT.

## Phase C: Merge Prep (lightest)

1. Read handoff file. Verify merge gate per `cr-github-review.md` "Completion" section.
2. Read PR body, verify all AC against final code, check off all boxes.
3. Report ready for merge. Do not delete the handoff file — parent performs deletion after successful user-gated merge (see `phase-protocols.md`).
4. Print exit report and EXIT.
