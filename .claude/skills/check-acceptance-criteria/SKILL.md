---
name: check-acceptance-criteria
description: Verify all Test Plan checkboxes in a PR against the actual code, check off passing items, and report any failures.
disable-model-invocation: true
argument-hint: "[PR number, default: current branch's PR]"
---

Verify acceptance criteria for PR $ARGUMENTS (or the current branch's PR if no argument given).

## Steps

### Step 1: Identify the PR

If an argument was provided, use it as the PR number. Otherwise, detect from the current branch:

```bash
gh pr view --json number,title,body --jq '{number, title, body}'
```

If no PR exists, stop and tell the user.

### Step 2: Parse the Test Plan section

Extract the PR body and find the **Test plan** section (may also be labeled "Test Plan", "Acceptance Criteria", or "## Test plan").

Parse every checkbox line (`- [ ]` or `- [x]`). If there is no Test Plan section, warn the user: "No Test Plan section found in PR body. Nothing to verify."

### Step 3: Verify each criterion

For each checkbox item:

1. **Read the criterion carefully** — understand what it's asserting
2. **Identify the relevant source files** — which files need to be checked to verify this criterion
3. **Read those files** and confirm the criterion is satisfied by the current code
4. **Record the result** — pass or fail, with a brief explanation

Some criteria may not be verifiable from code alone (e.g., "renders correctly in browser", "performance is acceptable"). For these, note: "Requires manual testing — cannot verify from code."

### Step 4: Update the PR body

For each passing criterion, check it off by editing the PR body:

```bash
# Fetch current body, replace checkboxes, update
current_body="$(gh pr view N --json body --jq .body)"
# Replace specific - [ ] lines with - [x] for passing items
gh pr edit N --body "$updated_body"
```

Only check off items that are verified. Never check off items that failed or require manual testing.

### Step 5: Report results

Output a summary:
- Total criteria: N
- Passed (checked off): N
- Failed: N (list each with explanation)
- Requires manual testing: N (list each)

If all items pass, say: "All acceptance criteria verified and checked off. PR is ready for merge."
If any fail, say: "N acceptance criteria failed — fix before merging." and list the failures.
