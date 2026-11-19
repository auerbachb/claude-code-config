---
name: infra-cost-audit
description: Read current infrastructure usage and flag costly settings across configured repositories. Use when checking Vercel, GitHub Actions, or Railway spending.
---

# Infrastructure cost audit

Read the [audit reference](../../reference/infra-cost-audit.md) for config and
coverage. Run the collector with a user-owned private config. It reads only
provider evidence, reports unavailable data as unavailable, and prepares issue
previews without filing by default.

Resolve the collector from the installed skills worktree first; if that is
unavailable, use the copy beside this skill in a trusted checkout. Invoke it as
`python3 -I <collector> --config <private-config>`. For a monthly comparison,
pass the last reviewed snapshot as `--baseline` and a new local destination as
`--snapshot`. Read the report before adopting it as a baseline.

Use `--file-issues` only when the operator requests filing for this run. The
collector also requires per-repository opt-in and verifies a private
destination and the open issue dedup check. The audit does not change
provider settings or install a schedule. Stop after reporting findings,
coverage gaps, and any issue URLs it returned.
