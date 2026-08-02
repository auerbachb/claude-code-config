# Branch-Protection Remediation — Discovery & Payload

Mechanism behind the remediation paragraph in `.claude/rules/repo-bootstrap.md` §Branch protection. That rule owns the constraints — ask before changing protection, never downgrade it, drop the subject for the session if declined. This file carries how to discover check names and what to PUT.

`repo-bootstrap.sh` reports protection state but never changes it. Everything below runs only after the user has said yes in chat.

## 1. Discover CI check names

Primary source — the check-runs on the latest commit on `main`:

```bash
SHA=$(gh api repos/{owner}/{repo}/commits/main --jq .sha)
gh api "repos/{owner}/{repo}/commits/${SHA}/check-runs?per_page=100" \
  --jq '.check_runs[].name' | sort -u
```

Fallback when `main` has no recent check-runs (fresh repo, workflows never triggered): parse job names out of `.github/workflows/*.yml`. Job *names* are what appear as contexts, so prefer an explicit `name:` on the job over the job key.

## 2. Ask, naming what you found

```text
No required status checks on `main` — PRs can merge with failing CI.
Found checks: lint, test, build. Want me to enable protection with those required?
```

If declined: move on, and do not raise it again in the same session.

## 3. Read-then-PUT (never a blind PUT)

GitHub's branch-protection API is a whole-object replace: a PUT carrying only `required_status_checks` silently drops required reviews, admin enforcement, linear-history, and everything else already configured. Always read first, then send the read payload back with only the fields you intend to change.

```bash
gh api repos/{owner}/{repo}/branches/main/protection > /tmp/protection.json   # 404 = none yet
```

- **Existing protection (200):** send the full read payload back, changing only `required_status_checks.contexts` (merge your discovered checks into whatever is already listed — do not replace the list wholesale) and `required_status_checks.strict: true`.
- **No protection (404):** send a sensible-default payload instead:

```json
{
  "required_status_checks": { "strict": true, "contexts": ["lint", "test", "build"] },
  "enforce_admins": false,
  "required_pull_request_reviews": null,
  "restrictions": null
}
```

`enforce_admins: false` is deliberate on a solo-owner repo: it is what keeps the plain `admin-merge.sh --auto-plain` shape available without modifying protection (`.claude/reference/admin-merge-auto-plain.md`). Turning it on converts every admin merge into a protection-modifying operation, which Claude may never auto-run.

## 4. Verify

```bash
gh api repos/{owner}/{repo}/branches/main/protection --jq '.required_status_checks'
```

Confirm the contexts you added are present *and* that everything that was there before still is. A remediation that removed a pre-existing requirement is a downgrade, not a fix.
