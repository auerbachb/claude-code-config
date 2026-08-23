# AC Gate — Mechanism and Reference

CI gate that reads a PR body and blocks merge when unchecked acceptance-criteria
boxes remain unresolved. The agent-side check (`cr-merge-gate.md` Step 2) is the
primary path; this workflow is the CI backstop that catches skipped or rushed reads.

## Scope

The gate scans two section types for unchecked `- [ ]` boxes:

- **In-scope** (hard failures): `## Acceptance Criteria` and `## Test plan` /
  `## Test Plan` (case-insensitive heading match, following `ac-checkboxes.sh`).
- **Exemption region**: `## Post-merge verification` (EXACT heading, spelling and
  case). A misspelled or differently-cased heading is not an exemption region.
- **Everything else**: ignored. Unrelated checklists elsewhere in the body do not
  trigger the gate.

A PR with no unchecked in-scope boxes, or with an empty body, passes.

## Exemption Logic (`## Post-merge verification`)

Unchecked boxes inside the exemption section are allowed when **all three ordered
checks** pass. Each check has its own exit code and failure message naming the
condition and the fix.

### Check 1 — Tracking issue line present (exit 5 on failure)

A line matching `Tracking issue: #N` must exist **inside** the `## Post-merge
verification` section (between the heading and the next `## ` heading or EOF).
A tracking line outside the section grants no exemption.

### Check 2 — Tracking issue is not self-referential (exit 6 on failure)

The gate calls `pr-issue-ref.sh --all <PR>` to list every issue number that this
PR closes (via any of GitHub's nine closing keywords, in both the bare `#N` and
the `owner/repo#N` forms). If the tracking issue number appears in that list, the
exemption fails.

**Why this matters (the PR #588 pattern):** When the PR merges, GitHub closes
every issue referenced by a closing keyword. If the tracking issue is one of those
issues, the deferred work is sealed inside a closed issue and becomes invisible.
This failure was observed on 2026-08-22 when a self-referential tracking line
passed the gate because neither the agent nor CI checked for the collision.

### Check 3 — Tracking issue is OPEN (exit 7 on failure)

The gate calls `gh issue view N --json state --jq '.state'` (following the
`forgotten-pr-triage.sh` precedent) and fails if the state is `CLOSED`.

## Exit Codes

| Code | Meaning |
|------|---------|
| 0 | Gate passed |
| 1 | Unchecked box outside Post-merge verification section |
| 2 | Usage error |
| 3 | PR not found |
| 4 | `gh` / API error, or `pr-issue-ref.sh` not found |
| 5 | Exemption section has no `Tracking issue: #N` line inside it |
| 6 | Tracking issue is one this PR closes (self-referential) |
| 7 | Tracking issue is CLOSED |

## Real Failures (Regression Fixtures)

Both fixtures from 2026-08-22 (`auerbachb/inventory`) are reproduced in
`.claude/scripts/tests/ac-gate.test.sh` as PRs 588 and 593.

**PR #588 — self-referential tracking line (exit 6)**
The PR body contained `Closes #588` and the `## Post-merge verification` section
had `Tracking issue: #588`. On merge, issue #588 closed automatically, sealing the
deferred iOS import-path test inside a closed issue. Gate passed; human caught it.

**PR #593 — no tracking line (exit 5)**
The PR body had five hardware-only criteria under `## Post-merge verification` with
no `Tracking issue:` line at all. Gate passed; human caught it.

## Workflow Identity

The workflow job id is `ac-gate` (see `.github/workflows/ac-gate.yml`). This id is
the branch-protection status-check name. The job has no `name:` field — adding one
would silently drop the check from branch protection, blocking every PR in the repo.
Do not rename the job.

## Related

- `.claude/scripts/ac-gate.sh` — the gate script
- `.claude/scripts/pr-issue-ref.sh` — closing-keyword extractor (`--all` mode)
- `.claude/rules/cr-merge-gate.md` Step 2 — the agent-side AC verification this backstops
