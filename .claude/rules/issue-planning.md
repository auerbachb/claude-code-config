# Issue Flow

> **Always:** Create a GitHub issue before any code work. Merge CR's plan into the issue body before coding.
> **Ask first:** Never — issue creation and planning are autonomous.
> **Never:** Skip the issue. Start coding without a plan. Post the plan as scattered comments instead of editing the issue body.

## Issue Planning Flow — Procedural Checklist

> **Username note:** Use `coderabbitai` (no `[bot]` suffix) for issue comments; PR reviews use `coderabbitai[bot]`.

1. **Draft the issue locally** — write the title, body, acceptance criteria, and relevant context. Do NOT post it yet.
2. **Create the issue** — post via `gh issue create`. A GitHub Actions workflow (`.github/workflows/cr-plan-on-issue.yml`) automatically comments `@coderabbitai plan` on every new issue. The workflow skips bot-created issues; do not manually post `@coderabbitai plan` unless the workflow failed (visible in the Actions tab).
3. **Read the issue and comments** — run `gh issue view N --comments` and check for an implementation plan comment from `coderabbitai`.
4. **If no CR plan exists, request and poll for one:**
   - Post `@coderabbitai plan` on the issue.
   - Poll every 60 seconds for up to 5 minutes for a comment from `coderabbitai`.
   - If no response appears after 5 minutes: log "CR plan unavailable" and continue. This fallback applies only to CR's plan; it does not skip Claude's plan or the issue-body merge below.
5. **Build Claude's plan** — explore the codebase and design an implementation approach. Claude's own plan is always required regardless of CR availability.
6. **Merge plans into the issue body** — create **one canonical document** for the coding agent to work from:
   - If CR posted a plan: compare CR's plan against Claude's plan. Incorporate anything CR identified that Claude missed (files, edge cases, risks). Pick the best ideas from each.
   - If CR did not post a plan: use Claude's plan as-is.
   - Edit the issue body — fetch the current body first, then write back both the original content and the plan:
   ```bash
   current_body="$(gh issue view N --json body --jq .body)"
   gh issue edit N --body "${current_body}

   ## Implementation Plan
   <merged plan here>"
   ```
   `gh issue edit --body` replaces the entire body — you must fetch-concatenate-edit to append.
7. **GATE: Verify the issue body contains the implementation plan before coding.**
   ```bash
   gh issue view N --json body --jq '.body' | grep -q '## Implementation Plan'
   ```
   If the command fails: **STOP** — you skipped steps 5-6. Go back and merge Claude's plan into the issue body before coding.
8. **Comment confirming the merge.**
   ```bash
   gh issue comment N --body "Implementation plan merged into issue body (<source>). Ready for implementation."
   ```
   Use "Claude's analysis + CodeRabbit's recommendations" when CR contributed, or "Claude's analysis only — CodeRabbit plan was not available" when it didn't.
9. **Start coding only after the gate passes** — create the feature branch (`issue-N-short-description`), read the issue body (not scattered comments) for the canonical implementation plan, implement the changes, then run the Local CodeRabbit Review Loop (see `cr-local-review.md`) and its Post-Clean checklist.

> Do NOT jump to step 9 without passing step 7. The `## Implementation Plan` section in the issue body is the canonical spec for the coding work.
