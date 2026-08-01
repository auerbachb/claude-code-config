# Issue Flow

> **Always:** Create a GitHub issue before any code work. Merge CR's plan into the issue body before coding. A skill may open issues autonomously — reported in-thread only when filing is the ask; incidental filings are recorded, not narrated.
> **Ask first:** Never — issue creation and planning are autonomous. Filing is reversible — closing an unwanted issue is the escape hatch.
> **Never:** Skip the issue. Start coding without a plan. Post the plan as scattered comments instead of editing the issue body. Open an issue without recording it. Start a claimed issue absent an explicit chat override.

## Issue Planning Flow — Procedural Checklist

> **Username note:** `coderabbitai` (no suffix) for issue comments; `coderabbitai[bot]` for PR reviews.

0. **GATE: Claim the issue** — `.claude/scripts/issue-claim.sh N --check`, then `--claim`, at **pick** time: before planning, before the worktree, every entry path, freeform "work on #N" included. `claimed`/`unknown` → **STOP** and name the claim (`unknown` is never permission); `stale` → warn and proceed; `mine` → no-op. Release on merge, close, or abandonment. Override only on the user naming the issue in chat → `--allow-claimed`, stated as an override. Detail: `.claude/reference/issue-claim.md`.
1. **Draft the issue locally** — title, body, acceptance criteria, context. Do NOT post yet.
2. **Create the issue** via `gh issue create`. CI auto-comments `@coderabbitai plan` (`cr-plan-on-issue.yml`; skips bot-created issues). Only post manually if that workflow visibly failed.
3. **Check for an existing CR plan** — `.claude/scripts/cr-plan.sh N`; exit 0 = substantive plan found (ack-only replies and enrichment boilerplate are filtered out; real plans need actual sections/steps — `cr-plan.sh --help`).
4. **If no CR plan:** post `@coderabbitai plan` unless already requested, then `.claude/scripts/cr-plan.sh N --poll 5`. On 5-min timeout log "CR plan unavailable" and continue — Claude's plan + issue-body merge are still required.
5. **Build Claude's plan** — explore codebase, design approach. Always required, regardless of CR.
6. **Merge into the issue body** — one canonical document for the coding agent:
   - CR plan exists: incorporate anything Claude missed (files, edge cases, risks). Else: Claude's plan as-is.
   - `gh issue edit --body` replaces the entire body — fetch, concatenate, then edit. Snippet (with the re-run duplicate strip): `/start-issue` Step 5.
7. **GATE: Verify the implementation plan is in the issue body.**

   ```bash
   gh issue view N --json body --jq '.body' | grep -q '## Implementation Plan'
   ```

   If it fails: **STOP** — go back and merge before coding.
8. **Comment confirming the merge**, attributing the source — `Implementation plan merged into issue body (<source>). Ready for implementation.`, where `<source>` names Claude's analysis and whether CodeRabbit's plan was available.
9. **Start coding only after the gate passes** — create branch `issue-N-short-description`, read the issue body (not scattered comments) as canonical spec, implement, then run Local CodeRabbit Review Loop (`cr-local-review.md`) + Post-Clean checklist.

## Capture-only issue threads

Capture-only threads (just opening issues) use `/issue-maker`; steps 0 and 5–7 run later at `/start-issue` time.
