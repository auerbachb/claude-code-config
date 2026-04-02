# Repo Bootstrap — Auto-Provision Configuration

> **Always:** Check for required workflows and branch protection at session start. Add missing workflows before any code work. Report missing branch protection to the user.
> **Ask first:** Branch protection changes — always ask the user before modifying repo-level settings.
> **Never:** Skip the checks. Modify workflows that already exist. Change branch protection without user confirmation.

## Session Start: Required Configuration Checks

At the start of every session, after creating the worktree but before any code work, run the checks below. Each is idempotent and safe to repeat.

### 1. Workflows

Verify that the repo has the required GitHub Actions workflows. If any are missing, add them as part of the first PR or as a standalone commit on the feature branch.

#### 1a. `cr-plan-on-issue.yml` — Auto-trigger CodeRabbit plan on new issues

**Check:** Does `.github/workflows/cr-plan-on-issue.yml` exist?

**If missing**, create it with this exact content (canonical source: `.github/workflows/cr-plan-on-issue.yml` — keep both in sync):

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

### 2. Branch Protection — Required Status Checks

Without required status checks on `main`, GitHub allows merges even when CI is red — breaking `main` for all subsequent PRs.

**Check:** Does `main` have required status checks enabled?

```bash
gh api "repos/{owner}/{repo}/branches/main/protection/required_status_checks" 2>&1
```

- **200** (returns `contexts`/`checks` array): configured — log which checks are required and move on.
- **404** ("Branch not protected"): not configured — proceed to remediation below.
- **403**: token lacks permission — note to user and skip.

**Remediation (requires user confirmation):**

1. **Discover CI check names** from the latest `main` commit's check-runs; if none exist, fall back to parsing `.github/workflows/*.yml` (extract each job's `name` field, or the job key if unnamed).
2. **Ask the user:** "This repo's `main` branch has no required status checks — PRs can merge with failing CI. Found checks: `lint`, `test`, `build`. Want me to enable branch protection requiring these to pass?"
3. **If approved:**
   - Read existing protection via `gh api repos/{owner}/{repo}/branches/main/protection` (may 404).
   - PUT to the same endpoint with `required_status_checks.contexts` set to the discovered check names and `strict: false` (or `true` for low-activity repos).
   - Preserve `required_pull_request_reviews`, `restrictions`, and `enforce_admins` from the read; default to `null`/`false` if no prior protection exists.
4. **If declined:** move on. Do not ask again in the same session.

### Rules

- **Only add missing workflows.** If the file already exists, do not modify it — even if the content differs. The repo owner may have customized it.
- **This check is idempotent.** Running it multiple times is safe — it only acts when the file is missing.
- **Branch protection changes require user confirmation.** Never modify branch protection settings autonomously — always report the gap and ask first.
- **Do not downgrade existing protection.** If branch protection is already configured with additional rules (required reviews, admin enforcement), preserve them when adding status checks.
