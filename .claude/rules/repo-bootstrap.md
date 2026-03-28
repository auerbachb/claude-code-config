# Repo Bootstrap — Auto-Provision Workflows

> **Always:** Check for required workflows at session start. Add missing ones before any code work.
> **Ask first:** Never — bootstrapping is autonomous and non-destructive.
> **Never:** Skip the check. Modify existing workflows that already exist.

## Session Start: Check Required Workflows

At the start of every session, after creating the worktree but before any code work, verify that the repo has the required GitHub Actions workflows. If any are missing, add them as part of the first PR or as a standalone commit on the feature branch.

### Required Workflows

#### 1. `cr-plan-on-issue.yml` — Auto-trigger CodeRabbit plan on new issues

**Check:** Does `.github/workflows/cr-plan-on-issue.yml` exist?

**If missing**, create it with this exact content:

```yaml
name: Trigger CodeRabbit Plan on New Issues

on:
  issues:
    types: [opened]

permissions:
  issues: write

jobs:
  trigger-cr-plan:
    runs-on: ubuntu-latest
    if: "!endsWith(github.event.issue.user.login, '[bot]')"
    steps:
      - name: Comment @coderabbitai plan
        uses: actions/github-script@v7
        with:
          script: |
            await github.rest.issues.createComment({
              owner: context.repo.owner,
              repo: context.repo.repo,
              issue_number: context.issue.number,
              body: '@coderabbitai plan'
            });
```

**How to add it:** Include it in your first feature PR in that repo — do not open a bootstrap-only PR. If you're only planning (no PR yet), note it for the first PR.

### Rules

- **Only add missing workflows.** If the file already exists, do not modify it — even if the content differs. The repo owner may have customized it.
- **This check is idempotent.** Running it multiple times is safe — it only acts when the file is missing.
