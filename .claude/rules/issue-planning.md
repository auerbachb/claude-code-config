# Issue Flow

> **Always:** Create a GitHub issue before any code work. Merge CR's plan into the issue body before coding.
> **Ask first:** Never — issue creation and planning are autonomous.
> **Never:** Skip the issue. Start coding without a plan. Post the plan as scattered comments instead of editing the issue body.

## 1. Draft the issue locally
- Write the title, body, acceptance criteria, and any relevant context
- Do NOT post it yet

## 2. Create the issue
- Post via `gh issue create`
- A GitHub Actions workflow (`.github/workflows/cr-plan-on-issue.yml`) automatically comments `@coderabbitai plan` on every new issue. The workflow skips bot-created issues.
- Do not manually post `@coderabbitai plan` unless the workflow failed (visible in the Actions tab).

## 3. Check for CR's implementation plan

> **Username note:** Use `coderabbitai` (no `[bot]` suffix) for issue comments; PR reviews use `coderabbitai[bot]`.

Issue age determines the polling strategy:
- **Older than 10 minutes:** Check comments for a plan from `coderabbitai`. If missing, post `@coderabbitai plan` and poll up to 5 minutes.
- **Less than 10 minutes old:** Poll every 60 seconds for a comment from `coderabbitai`. Timeout after 10 minutes from issue creation time.
- **No response after timeout:** Log "CR plan unavailable" and continue — Claude's plan (step 4) is always required regardless.

## 4. Build Claude's plan
- Explore the codebase and design an implementation plan (use plan mode)
- Draft the plan internally — do not post it yet

## 5. Merge plans into the issue body
This creates **one canonical document** for the coding agent to work from:

1. **If CR posted a plan:** Compare CR's plan against Claude's plan. Incorporate anything CR identified that Claude missed (files, edge cases, risks). Pick the best ideas from each.
2. **If CR did not post a plan:** Use Claude's plan as-is.
3. **Edit the issue body** — fetch the current body first, then write back both the original content and the plan:
   ```bash
   current_body="$(gh issue view N --json body --jq .body)"
   gh issue edit N --body "${current_body}

   ## Implementation Plan
   <merged plan here>"
   ```
   `gh issue edit --body` replaces the entire body — you must fetch-concatenate-edit to append.

## 6. Comment confirming the merge
```
gh issue comment N --body "Implementation plan merged into issue body (Claude's analysis + CodeRabbit's recommendations). Ready for implementation."
```
If CR's plan was not available:
```
gh issue comment N --body "Implementation plan added to issue body (Claude's analysis only — CodeRabbit plan was not available). Ready for implementation."
```

## 7. Begin implementation
1. **Create the feature branch** (`issue-N-short-description`).
2. **Read the issue body** (not scattered comments) for the canonical implementation plan.
3. **Implement the changes.**
4. **Run the Local CodeRabbit Review Loop** (see `cr-local-review.md`) — two clean passes required before pushing.
5. **Execute the post-clean checklist** (see `cr-local-review.md` "Post-Clean" section) — commit, push, create PR, enter GitHub review loop.
