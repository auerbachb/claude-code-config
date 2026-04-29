# Repo Bootstrap — Auto-Provision Configuration

> **Always:** Check for required workflows and branch protection at session start. Add missing workflows before any code work. Report missing branch protection to the user.
> **Ask first:** Branch protection changes — always ask the user before modifying repo-level settings.
> **Never:** Skip the checks. Modify workflows that already exist. Change branch protection without user confirmation.

## Session Start: Required Configuration Checks

At the start of every session, after creating the worktree but before any code work, run the bootstrap script. It is idempotent and safe to repeat.

### Run the bootstrap check

```bash
.claude/scripts/repo-bootstrap.sh --check
```

The script reports the workflow + branch-protection state without mutating anything. Exit codes: `0` clean, `1` gaps detected, `2` usage error, `3` environment error (not in a git repo / no `gh`), `4` `gh`/network error, `5` write failure (only from `--apply`). See `repo-bootstrap.sh --help` for the full contract.

If the report shows `[MISSING] .github/workflows/cr-plan-on-issue.yml`, install it as part of the first feature PR — do not open a bootstrap-only PR:

```bash
.claude/scripts/repo-bootstrap.sh --apply
```

`--apply` only installs the missing workflow. It never overwrites an existing workflow file (even if the content differs — the repo owner may have customized it) and never modifies branch protection.

### Branch protection — required status checks

The script reports state as `[OK]` / `[MISSING]` / `[SKIP]` (token lacks read perm) / `[UNKNOWN]` (investigate stderr). Without required status checks on `main`, PRs can merge with red CI. The script never changes branch protection — user confirmation required for any write.

**Remediation (requires user confirmation):**

1. **Discover CI check names** from latest `main` commit's check-runs; fall back to parsing `.github/workflows/*.yml` job names.
2. **Ask the user:** "No required status checks on `main` — PRs can merge with failing CI. Found checks: `lint`, `test`, `build`. Want me to enable protection?"
3. **If approved:** Read existing protection first (`gh api repos/{owner}/{repo}/branches/main/protection`; ignore 404). PUT to the same endpoint, merging `required_status_checks.contexts` with `strict: true` into any existing protection settings; use sensible defaults (`enforce_admins: false`) if 404.
4. **If declined:** move on. Do not ask again in the same session.

### Rules

- **Only add missing workflows.** Never modify existing workflow files — owner may have customized them.
- **Idempotent.** Safe to re-run; only acts when files are missing.
- **Branch protection requires user confirmation** — never modify autonomously.
- **Do not downgrade existing protection.** Preserve required reviews, admin enforcement, etc. when adding status checks.
