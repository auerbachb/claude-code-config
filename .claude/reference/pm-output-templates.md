# PM Output Templates

Presentation format templates for `/pm` Step 1B.5. Extracted from `pm/SKILL.md` to reduce churn surface on the formatting-only blocks. Referenced by Step 1B.5 for output format guidance.

---

## User-Scoped Sections (Step 1B.5)

`## Forgotten PRs` **always** renders — `forgotten-pr-triage.sh` defaults to `@me`, so it runs regardless of whether `$GH_USER` is set. The three `$GH_USER`-dependent sections render only when `$GH_USER` is set.

When `$GH_USER` is set, render all four in this order before the backlog ranking; when `$GH_USER` is **not** set, render only `## Forgotten PRs` in the same position (before `## Suggested Next Issues`):

```
## Your Open PRs
{List of open PRs authored by $GH_USER with last update time — or "none" if empty — only when $GH_USER is set}

## Forgotten PRs (>N days)
{Step 1D output — the forgotten set with per-PR close/merge recommendations, or a one-line "none" note when empty. Informational; never alters the ranking below. Always rendered.}

## PRs Awaiting Your Review
{List of open PRs where $GH_USER is a requested reviewer — or "none" if empty — only when $GH_USER is set}

## Issues Assigned to You
{List of open issues assigned to $GH_USER — or "none" if empty — only when $GH_USER is set}
```

---

## Suggested Next Issues (Step 1B.5)

Top 3-5 backlog issues for pickup. Each issue shows its per-issue estimate resolved via
`estimate-resolve.sh` (body `## Estimate` section → tier-label fallback → `unestimated`).

```
## Suggested Next Issues

Based on {N} open issues, {M} recent merges, and {OKR status}:

1. **#42 — {Title}** — {1-line rationale connecting to business value or OKR}
   - Labels: {labels} | Age: {days} days | Unblocks: #50, #53
   - Est: 45–90 min · plan on 90

2. **#38 — {Title}** — {rationale}
   - Labels: {labels} | Age: {days} days | Blocked by: #35
   - Est: 15–30 min · plan on 30

3. **#55 — {Title}** — {rationale}
   - Labels: {labels} | Age: {days} days
   - Est: unestimated

4. **#61 — {Title}** — {rationale}
   - Labels: {labels} | Age: {days} days
   - Est: 90–180 min · plan on 180

5. **#47 — {Title}** — {rationale}
   - Labels: {labels} | Age: {days} days
   - Est: 45–90 min · plan on 90

### Already In-Flight
{List open PRs with their linked issues — these don't need new threads}

### Dependency Note
{If any suggested issues have dependency chains, note the order}
```

**Resolve order for Est:** call `estimate-resolve.sh <N>` (resolved per the portable-skill-resolution.md
candidate order). If the script is unavailable, omit the `- Est:` line silently — the estimate is
informational and never a dispatch blocker.

---

## Full Ranking / Tiered View (Step 1B.5)

When the user asks to "rank the backlog", "priority list", or "full ranking", replace the top 3-5 list with the tiered view. "Full" means every tier is covered, not that every issue is listed: name the issues that earn a decision in each tier and summarize the rest. Omit any tier with no issues:

```
## Critical — must do to achieve the goal
- **#42 — {title}** — {1-line rationale tying the issue to the goal or OKR}
  - Unblocks: #50, #53 | Advances: O1/KR2

## High — significant enablers
- **#55 — {title}** — {rationale}

## Medium — supporting work (defer if necessary)
- **#61 — {title}** — {rationale}

## Low — tangential (skip for now)
- **#70 — {title}** — {rationale}

## Stop doing
{Only when 1B.4 flagged misaligned effort: name the current low-impact work and the
higher-impact work to switch to. Omit entirely when current work is well-aligned.}
```

Summarize rather than enumerate once a tier stops informing a decision — most often the Low tier: "68 additional issues are Low-priority relative to this goal". The tier still appears with its heading; it just carries a count instead of 68 bullets.
