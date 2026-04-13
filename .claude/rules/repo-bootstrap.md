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

**If missing:** Canonical source is `.github/workflows/cr-plan-on-issue.yml` in this repo. Copy that file verbatim into the target repo. Include it in your first feature PR — do not open a bootstrap-only PR.

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

1. **Discover CI check names** from latest `main` commit's check-runs; fall back to parsing `.github/workflows/*.yml` job names.
2. **Ask the user:** "No required status checks on `main` — PRs can merge with failing CI. Found checks: `lint`, `test`, `build`. Want me to enable protection?"
3. **If approved:** PUT to `repos/{owner}/{repo}/branches/main/protection` with `required_status_checks.contexts` set to discovered checks and `strict: true`. Preserve existing protection settings; use sensible defaults if none exist.
4. **If declined:** move on. Do not ask again in the same session.

### Rules

- **Only add missing workflows.** If the file already exists, do not modify it — even if the content differs. The repo owner may have customized it.
- **This check is idempotent.** Running it multiple times is safe — it only acts when the file is missing.
- **Branch protection changes require user confirmation.** Never modify branch protection settings autonomously — always report the gap and ask first.
- **Do not downgrade existing protection.** If branch protection is already configured with additional rules (required reviews, admin enforcement), preserve them when adding status checks.
