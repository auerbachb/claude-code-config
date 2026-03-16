## Issue Creation Flow

> **Always:** Create a GitHub issue before any code work. Trigger `@coderabbitai plan` on every new issue. Merge CR's plan into the issue body.
> **Ask first:** Never — issue creation and planning are autonomous.
> **Never:** Skip the issue. Start coding without a plan. Post the plan as scattered comments instead of editing the issue body.

When creating a new GitHub issue (whether the user asked for it or you identified the need):

### 1. Draft the issue locally
- Write the title, body, acceptance criteria, and any relevant context
- Do NOT post it yet

### 2. Create the issue and trigger CR plan
- Post the issue via `gh issue create`
- Immediately comment `@coderabbitai plan` on the new issue:
  ```
  gh issue comment N --body "@coderabbitai plan"
  ```
- CR will analyze the issue and post an implementation plan with file recommendations, edge cases, and architectural considerations. This feedback is valuable — it catches gaps in the spec before any coding begins.

### 3. If starting work immediately
- If you're about to start coding on this issue right away, proceed to the **Issue Planning Flow** below — it handles waiting for CR's plan.
- If the issue is for later (backlog), you're done — CR's plan will be there when someone picks it up.

---

## Issue Planning Flow

**Prerequisite:** Same CR check as the review loop below. If CR is not configured, skip the CR-specific steps.

When starting work on a GitHub issue, always follow this flow before writing any code:

### 1. Read the issue
- Fetch the full issue body and comments via `gh issue view N --comments`
- Understand the requirements, context, and any discussion

### 2. Check for CR's implementation plan
CR automatically posts an implementation plan when issues are created (triggered by `@coderabbitai plan`). Check whether it exists:

- **If the issue is older than 10 minutes:** Check comments for a plan from `coderabbitai[bot]`. If it exists, read it. If it doesn't exist (CR may not have been triggered), post `@coderabbitai plan` now and poll for up to 5 minutes. If still no response, proceed without it.
- **If the issue is less than 10 minutes old:** CR may still be generating the plan. Poll every 60 seconds for a comment from `coderabbitai[bot]` on the issue. Timeout after 10 minutes from issue creation time — if no plan appears by then, proceed without it.

### 3. Build Claude's plan
- Explore the codebase and design an implementation plan (use plan mode)
- Draft the plan internally — do not post it yet

### 4. Merge the plans into the issue body
This creates **one canonical document** for the coding agent to work from:

1. **If CR posted a plan:** Compare CR's plan against Claude's plan. Incorporate anything CR identified that Claude missed (files, edge cases, architectural considerations, risks). The goal is the most robust plan — pick the best ideas from each.
2. **If CR did not post a plan:** Use Claude's plan as-is.
3. **Edit the issue body** to include the merged plan. Fetch the current body first, then write back both the original content and the plan:
   ```bash
   current_body="$(gh issue view N --json body --jq .body)"
   gh issue edit N --body "${current_body}

   ## Implementation Plan
   <merged plan here>"
   ```
   This preserves the original issue description. (`gh issue edit --body` replaces the entire body — you must fetch-concatenate-edit to append.)
4. **Comment on the issue** confirming the merge:
   ```
   gh issue comment N --body "Implementation plan merged into issue body (Claude's analysis + CodeRabbit's recommendations). Ready for implementation."
   ```
   If CR's plan was not available, note that:
   ```
   gh issue comment N --body "Implementation plan added to issue body (Claude's analysis only — CodeRabbit plan was not available). Ready for implementation."
   ```

### 5. Start coding
- Create the feature branch (`issue-N-short-description`) and begin implementation
- The coding agent should read the **issue body** (not scattered comments) for the canonical plan
- When implementation is done, run the **Local CodeRabbit Review Loop** before pushing
