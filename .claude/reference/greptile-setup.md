# Greptile Dashboard Configuration (app.greptile.com)

Auto-review on PR open is disabled via a "Labels: includes: `greptile`" filter in the Greptile dashboard (app.greptile.com/review → Settings → Review Triggers). Since we never add that label, no PRs get auto-reviewed — manual `@greptileai` triggers still work.

| Setting | Value |
|---------|-------|
| Authors Exclude | `dependabot[bot]`, `renovate[bot]` |
| Labels: includes | `greptile` |
| File Change Limit | 100 |
| Automatically trigger on new commits | OFF |
| Review draft pull requests | OFF |

**Setup:** Add the "Labels: includes: greptile" filter at app.greptile.com/review → Settings → Review Triggers. The "new commits" toggle only affects commits to existing PRs, not PR-open events.
