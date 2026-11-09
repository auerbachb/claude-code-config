# Infrastructure cost audit

Use `/infra-cost-audit` to review reported infrastructure usage and the
settings that can drive it up. It is separate from the AI review audit.
The collector runs on demand; use the same monthly review cadence with a
separate snapshot for this report. It does not install or change a schedule.

## Private configuration

Save JSON outside Git in a user-owned mode-600 file. Use the provider's
existing authorization. The audit never signs in, creates a token, or opens a
provider settings page.

```json
{
  "schema": "infra-cost-audit/v1",
  "vercel": {"scope": "team-slug"},
  "github": {"kind": "user", "account": "owner"},
  "railway": {"workspace": "workspace-id"},
  "repositories": [
    {
      "repo": "owner/project",
      "personal": true,
      "monorepo": true,
      "vercel": {"id": "prj_example", "name": "project-web"},
      "railway": "railway-project-id",
      "related_issues": [123],
      "allow_filing": false
    }
  ],
  "thresholds": {"preview_per_day": 6, "preview_per_merge": 5, "share_jump": "0.15"}
}
```

Omit an unavailable provider. Set the Vercel scope to `null` explicitly to
use the CLI's current default scope. Mark personal projects and monorepos
explicitly; the audit does not infer those classifications from billing
plans or repository visibility. GitHub organizations use
`"kind": "organization"`. Railway requires an explicit workspace. Prefer
provider IDs to display names for mapping. If an installed executable is
outside the standard locations on PATH, set its absolute path in `tools`
under the key `vercel`, `gh`, or `railway`.

From the trusted config checkout, run:

```bash
python3 -I .claude/skills/infra-cost-audit/audit.py \
  --config "$HOME/.claude/infra-cost-audit/config.json" \
  --snapshot "$HOME/.claude/infra-cost-audit/snapshot-2026-11.json"
```

Pass the last reviewed snapshot with `--baseline`. A snapshot is private and
cannot overwrite an existing file. `--month YYYY-MM` selects a GitHub and
Railway month; Vercel currently reports its active billing window. Treat an
unavailable provider as a coverage gap, including when its CLI is absent
from PATH. A missing row does not prove zero usage.

## What the report can establish

- **Vercel:** [grouped billing usage](https://vercel.com/docs/cli/usage) supplies
  the provider's billing window and project breakdown. Build CPU Minutes and
  Build Minutes stay separate; hours are each reported count divided by 60.
  The billed amounts shown by the CLI are not invoice totals. The
  [project API](https://vercel.com/docs/rest-api/projects/find-a-project-by-id-or-name)
  verifies the pinned ID, name and repository link before reporting the build
  machine and whether the dashboard ignore command is configured.
- **Preview volume:** the [deployment list](https://vercel.com/docs/rest-api/deployments/list-deployments)
  supplies preview deployments; GitHub supplies the default-branch merge count
  for the same interval. Preview deployments are a volume measure, not charged
  builds. An empty dashboard ignore command does not rule out a
  [repository override](https://vercel.com/docs/project-configuration/vercel-json#ignorecommand).
- **GitHub Actions:** the [enhanced billing report](https://docs.github.com/en/rest/billing/usage#get-billing-usage-report-for-a-user)
  supplies minutes and net USD by repository for Actions rows in minute units.
  Storage and other units are excluded. Workflow duration is not used as a
  billing substitute.
- **Railway:** [project usage](https://docs.railway.com/cli/usage#inspect-usage-by-project)
  supplies current usage dollars for the selected workspace and project.
  Estimates are excluded.

The findings are a premium Vercel machine on a configured personal project,
an empty dashboard ignore command on a configured monorepo, preview volume
above both configured thresholds, and a project's share above its baseline by the configured fraction. Each
share uses the same provider scope, unit, and denominator: Vercel billed cost,
GitHub Actions net minute charges, or Railway project usage. Missing evidence
suppresses its finding; independent findings still appear.

## Issue previews and filing

By default the report shows an issue preview, or the existing open issue
that should receive attention. Existing audit markers, configured related
issue numbers, and related open issue titles prevent new filings. An
incomplete issue list prevents filing. If the operator requests filing,
pass `--file-issues` and set `allow_filing` on the intended private repositories.
Run from one host using one private config. Each repository receives at most one
combined issue; the audit never edits or closes an existing issue.
