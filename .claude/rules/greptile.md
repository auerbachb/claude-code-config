# Greptile — CodeRabbit Fallback Reviewer

> **Always:** Poll for response after triggering. Reply to every thread. Fix all valid findings. Classify by severity (P0/P1/P2). Only re-review for P0. Stay on G once triggered for a PR.
> **Ask first:** Never — fix findings autonomously.
> **Never:** Trigger Greptile proactively on a PR where CR hasn't failed yet. Ignore Greptile findings. Switch a PR back to CR after Greptile has been triggered. Include `@greptileai` in reply comments (triggers a paid re-review with no learning benefit).

Greptile is an AI code reviewer used as a **fallback** when CR is rate-limited or unresponsive. Both tools' findings must be verified against code. Differences: cost ($0.50-$1.00/review beyond 50/month quota) and completion-signal reliability (Greptile completion signals are accurate; CR completion signals require confirmation passes).

## Greptile Basics

- **GitHub App:** Greptile Apps
- **Bot username:** `greptile-apps[bot]`
- **Trigger:** Comment `@greptileai` on any PR (no special "full review" suffix needed)
- **Auto-trigger:** OFF — disabled via dashboard filter (see "Dashboard Configuration" below). Must be explicitly triggered via @mention.
- **Rate limits:** None documented (50 reviews/seat/month included, $1/extra — no per-hour throttle)
- **Review time:** ~1-3 minutes for most PRs
- **Completion signals:** 👀 emoji on the PR = analyzing, 👍 = complete, 😕 = failed
- **No CLI:** Greptile cannot do local pre-push reviews. Local review loop uses CR CLI only.
- **Config:** Optional `greptile.json` in repo root (supports `strictness`, `customInstructions`, `scope`). Review trigger filters are configured in the Greptile web dashboard (app.greptile.com), not in repo files.
- **Feedback loop:** 👍/👎 reactions on Greptile comments train it over 2-3 weeks

## Dashboard Configuration (app.greptile.com)

Auto-review on PR open is disabled via a "Labels: includes: `greptile`" filter in the Greptile dashboard (app.greptile.com/review → Settings → Review Triggers). Since we never add that label, no PRs get auto-reviewed — manual `@greptileai` triggers still work.

| Setting | Value |
|---------|-------|
| Authors Exclude | `dependabot[bot]`, `renovate[bot]` |
| Labels: includes | `greptile` |
| File Change Limit | 100 |
| Automatically trigger on new commits | OFF |
| Review draft pull requests | OFF |

**Setup:** Add the "Labels: includes: greptile" filter at app.greptile.com/review → Settings → Review Triggers. The "new commits" toggle only affects commits to existing PRs, not PR-open events.

## Daily Budget

Greptile charges $1/review beyond the 50/month included quota. To prevent runaway costs when many PRs are processed in parallel, enforce a hard daily cap.

- **Default budget: 40 reviews/day** (adjustable — set `budget` field in `session-state.json`).
- **Tracking:** The `greptile_daily` section in `~/.claude/session-state.json` tracks `reviews_used`, `date` (YYYY-MM-DD in ET timezone), and `budget`. See `handoff-files.md` for the schema.
- **Before EVERY `@greptileai` trigger**, read `greptile_daily` from session state and run the budget check:
  1. Get the current date in ET: `TZ='America/New_York' date +'%Y-%m-%d'`
  2. If `greptile_daily.date` differs from today's date, reset `reviews_used` to 0 and update `date` to today
  3. If `reviews_used >= budget`, the budget is **exhausted** — do NOT post `@greptileai`. Fall back to self-review (see below)
  4. Otherwise, increment `reviews_used` by 1 and write the updated `greptile_daily` back to session state **before** posting the `@greptileai` comment
- **Budget exhaustion fallback:** Perform a self-review instead. Self-review does NOT satisfy the merge gate. Report the blocker to the user:
  > "Greptile budget exhausted ({reviews_used}/{budget}). PR #{N} falling back to self-review — merge blocked until manual review or budget resets tomorrow."
- **This check applies to all Greptile trigger points** (CR GitHub fallback, local post-push, Phase B polling, and per-PR re-reviews). No `@greptileai` comment may be posted without passing the budget check first.

## Before EVERY `@greptileai` Re-Trigger (MANDATORY — after initial trigger)

Applies to 2nd/3rd triggers only; initial trigger requires only the budget check (no severity classification).

1. **Classify all findings from the previous review** (P0/P1/P2).
2. **If NO P0:** STOP — do NOT trigger `@greptileai`. Proceed to Phase B completion (merge gate check).
3. **If P0 present:** perform budget check (see "Daily Budget" above) → trigger `@greptileai`.
4. **Log severity counts in handoff `notes`.**

## When to Trigger Greptile

**Greptile is fallback-only.** Never trigger it proactively alongside CR. It is only triggered when CR fails for a specific PR:

1. **CR rate limit detected (fast-path):** Check-runs or commit statuses show rate limiting → trigger Greptile immediately.
2. **CR timeout (slow-path):** CR has not delivered a review within 7 minutes of push → trigger Greptile.

### Sticky Assignment

**Once Greptile is triggered for a PR, it stays on Greptile permanently.** Do not switch back to CR. After fixing findings, only re-trigger `@greptileai` for P0 findings. Ignore late CR reviews. Merge gate is severity-dependent — see `cr-merge-gate.md` (Step 1) for the authoritative definition.

## Polling for Greptile Response

Poll every 60 seconds on all three endpoints (same pattern as CR):

- `repos/{owner}/{repo}/pulls/{N}/reviews?per_page=100`
- `repos/{owner}/{repo}/pulls/{N}/comments?per_page=100`
- `repos/{owner}/{repo}/issues/{N}/comments?per_page=100`

Filter by `greptile-apps[bot]` (with `[bot]` suffix).

**Timeout:** 5 minutes (typical response: 1-3 min). No response after 5 min = timeout.

**Completion detection:** 👍 or review comments from `greptile-apps[bot]` = done. 😕 = failed (stop polling, report failure). No signal after 5 min = timeout.

## Processing Greptile Findings

Classify by severity (P0/P1/P2 — use Greptile badges only), verify against code, fix all valid findings in one commit, push once, reply to every thread, resolve via GraphQL. Use 👍/👎 reactions for feedback (this is Greptile's only learning mechanism).

> **CRITICAL: Do NOT include `@greptileai` in reply comments.** Every `@greptileai` mention — even in a reply — triggers a new paid review ($0.50-$1.00). Greptile does not learn from text replies (unlike CR which has a knowledge base). Replies are purely for GitHub thread management and human readability.
>
> | | CodeRabbit | Greptile |
> |--|-----------|----------|
> | Reply format | Include `@coderabbitai` (teaches knowledge base) | **No @mention** — plain text only |
> | Learns from replies | Yes | No — only from 👍/👎 reactions |
> | @mention cost | Within hourly quota | $0.50-$1.00 per triggered review |

**Reply format for Greptile threads:**
- Inline comments: `gh api repos/{owner}/{repo}/pulls/comments/{id}/replies -f body="Fixed in \`SHA\`: <what changed>"`
- Issue/PR-level comments: `gh pr comment N --body "Fixed in \`SHA\`: <what changed>"`
- **Never** include `@greptileai` in reply bodies. The only valid use of `@greptileai` is posting a standalone comment to intentionally request a new review (P0 re-review trigger).

**Severity-gated re-review:** See the "Before EVERY `@greptileai` Re-Trigger" checklist above.

## Merge Gate

**Canonical definition:** See `cr-merge-gate.md` (Step 1). That file is the single authoritative source for both the CR 2-clean-pass path and the Greptile severity-gated path (including the 3-review-per-PR cap and the self-review fallback when both reviewers are down).
