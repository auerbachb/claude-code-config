# Issue Flow

> **Always:** Create a GitHub issue before any code work. Merge CR's plan into the issue body before coding.
> **Ask first:** Never — issue creation and planning are autonomous.
> **Never:** Skip the issue. Start coding without a plan. Post the plan as scattered comments instead of editing the issue body.

## Issue Planning Flow — Procedural Checklist

> **Username note:** `coderabbitai` (no suffix) for issue comments; `coderabbitai[bot]` for PR reviews.

1. **Draft the issue locally** — title, body, acceptance criteria, context. Do NOT post yet.
2. **Create the issue** via `gh issue create`. The `.github/workflows/cr-plan-on-issue.yml` workflow auto-comments `@coderabbitai plan` (skips bot-created issues). Only post manually if the workflow visibly failed.
3. **Check for an existing CR plan** — `.claude/scripts/cr-plan.sh N`; exit 0 = substantive plan found (filters out ack-only replies).
4. **If no CR plan, request/poll:**
   - If `@coderabbitai plan` was already requested: `.claude/scripts/cr-plan.sh N --poll 5`.
   - Else: post `@coderabbitai plan`, then `.claude/scripts/cr-plan.sh N --poll 5`.
   - 5-min timeout: log "CR plan unavailable" and continue. Claude's plan + issue-body merge are still required.
5. **Build Claude's plan** — explore codebase, design approach. Always required, regardless of CR.
6. **Merge into the issue body** — one canonical document for the coding agent:
   - If CR plan exists: incorporate anything Claude missed (files, edge cases, risks). Best of both.
   - Else: Claude's plan as-is.
   - `gh issue edit --body` replaces the entire body — fetch-concatenate-edit:

   ```bash
   current_body="$(gh issue view N --json body --jq .body)"
   gh issue edit N --body "${current_body}

   ## Implementation Plan
   <merged plan here>"
   ```
7. **GATE: Verify the implementation plan is in the issue body.**

   ```bash
   gh issue view N --json body --jq '.body' | grep -q '## Implementation Plan'
   ```

   If it fails: **STOP** — go back and merge before coding.
8. **Comment confirming the merge** with source attribution:

   ```bash
   gh issue comment N --body "Implementation plan merged into issue body (<source>). Ready for implementation."
   ```

   Source: "Claude's analysis + CodeRabbit's recommendations" or "Claude's analysis only — CodeRabbit plan was not available".
9. **Start coding only after the gate passes** — create branch `issue-N-short-description`, read the issue body (not scattered comments) as canonical spec, implement, then run Local CodeRabbit Review Loop (`cr-local-review.md`) + Post-Clean checklist.

> Do NOT jump to step 9 without passing step 7. The `## Implementation Plan` section in the issue body is the canonical spec for the coding work.
