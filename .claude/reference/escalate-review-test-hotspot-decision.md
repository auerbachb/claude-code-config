# `escalate-review.test.sh` hotspot — concern-based split decision

Reference for Issue #966. Not auto-loaded.

## Churn diagnosis

As re-measured after PR #969 merged, the monolithic
`.claude/scripts/tests/escalate-review.test.sh` had been touched by 11 distinct
merged PRs in the hotspot window tracked by Issue #966. The production
escalation gate was not the source of avoidable churn: independent regression
scenarios accumulated in one 895-line test file whenever a reviewer, freshness,
cache, or identity guard changed.

At the split point, the monolith contained 42 named scenario headers and 91
runtime assertions. Its roughly 240-line fixture setup was shared by every
scenario, so copying that setup into several files would trade edit conflicts
for fixture drift.

## Decision: split by concern, share only the fixture

Replace the monolith with four independently runnable suites:

- `escalate-review-bugbot-classification.test.sh` — failure and genuine-response classification
- `escalate-review-gate-met.test.sh` — approval validity, freshness, retraction, and gate short-circuits
- `escalate-review-never-invited.test.sh` — invitations, grace windows, and cached availability
- `escalate-review-app-identity.test.sh` — publishing-app identity and spoof guards

The common temp directories, GitHub stub, copied sibling scripts, fixtures,
helpers, and assertion harness live in
`tests/lib/escalate-review-fixtures.sh`. The helper deliberately does not end in
`.test.sh`, so the existing non-recursive test glob does not execute it by
itself.

This follows the repository's `merge-gate-*.test.sh` and
`pr-state-*.test.sh` concern-family precedent. A documented no-op was rejected:
the repeated edits were independent test additions, not unavoidable churn in a
shared contract.

## Preserved invariants

- All 42 scenario headers and all 91 runtime assertions remain represented.
- Each concern suite runs independently and through the existing hook-test glob.
- `escalate-review.sh` is unchanged; this refactor changes no escalation behavior.
- The timestamp spelling matrix remains drift-pinned to scenarios `(h6b)`–`(h6e)`
  in `escalate-review-gate-met.test.sh`.
- Scenario labels stay stable so issue and review history remain searchable.

## Future ownership

New escalation regression coverage belongs in the narrowest concern suite.
Only reusable setup belongs in `tests/lib/escalate-review-fixtures.sh`; scenario
logic must not move into the helper merely to reduce line counts.
