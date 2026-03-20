# Greptile — CodeRabbit Fallback Reviewer

> **Always:** Poll for response after triggering. Reply to every thread. Fix all valid findings. Classify by severity (P0/P1/P2). Only re-review for P0. Stay on G once triggered for a PR.
> **Ask first:** Never — fix findings autonomously.
> **Never:** Trigger Greptile proactively on a PR where CR hasn't failed yet. Ignore Greptile findings. Switch a PR back to CR after Greptile has been triggered.

Greptile is an AI code reviewer used as a **fallback** when CodeRabbit is rate-limited or unresponsive. It is trusted equally with CR in terms of review quality. The differences are cost ($1/review beyond the included 50/month quota) and completion-signal reliability — Greptile's signals are accurate, while CR's are not.

## Greptile Basics

- **GitHub App:** Greptile Apps
- **Bot username:** `greptile-apps[bot]`
- **Trigger:** Comment `@greptileai` on any PR (no special "full review" suffix needed)
- **Auto-trigger:** OFF — must be explicitly triggered via @mention
- **Rate limits:** None documented (50 reviews/seat/month included, $1/extra — no per-hour throttle)
- **Review time:** ~1-3 minutes for most PRs
- **Completion signals:** 👀 emoji on the PR = analyzing, 👍 = complete, 😕 = failed
- **No CLI:** Greptile cannot do local pre-push reviews. Local review loop uses CR CLI only.
- **Config:** Optional `greptile.json` in repo root (supports `strictness`, `customInstructions`, `scope`)
- **Feedback loop:** 👍/👎 reactions on Greptile comments train it over 2-3 weeks

## When to Trigger Greptile

**Greptile is fallback-only.** Never trigger it proactively alongside CR. It is only triggered when CR fails for a specific PR:

1. **CR rate limit detected (fast-path):** Check-runs or commit statuses show rate limiting → trigger Greptile immediately.
2. **CR timeout (slow-path):** CR has not delivered a review within 7 minutes of push → trigger Greptile.

### Sticky Assignment

**Once Greptile is triggered for a PR, that PR stays on Greptile for all remaining review cycles.** Do not switch back to CR. Rationale: if CR was slow or rate-limited once for this PR, it will likely be slow again, and switching back just wastes more time.

This means:
- After fixing Greptile findings, only trigger `@greptileai` again if there were P0 findings (not `@coderabbitai full review`)
- Ignore any late CR reviews that arrive after Greptile has taken ownership
- Merge gate is severity-dependent — see "Detecting a Merge-Ready Greptile Review" below

## Polling for Greptile Response

Poll every 60 seconds on all three endpoints (same pattern as CR):

- `repos/{owner}/{repo}/pulls/{N}/reviews?per_page=100`
- `repos/{owner}/{repo}/pulls/{N}/comments?per_page=100`
- `repos/{owner}/{repo}/issues/{N}/comments?per_page=100`

Filter by `greptile-apps[bot]` (with `[bot]` suffix).

**Timeout:** 5 minutes. Greptile typically responds in 1-3 minutes. If no response after 5 minutes, proceed without it and note in the PR that Greptile did not respond.

**Completion detection:**

- Check for 👍 reaction on the PR from Greptile (signals review complete)
- Also check for review objects or comments from `greptile-apps[bot]`
- If a review comment appears, it's done — process findings
- If no comments appear after 5 minutes and no 👍, treat as timeout

> **Note:** Check-run names for Greptile are not yet documented. After the first Greptile
> review on this repo, check `gh api "repos/{owner}/{repo}/commits/{SHA}/check-runs"` and
> update this section with the actual check-run name and completion detection logic.

## Processing Greptile Findings

Same protocol as CR findings, but with **severity-gated re-review**:

1. **Classify findings by Greptile badge only:** P0, P1, P2. Do not infer severity yourself.
2. Verify each finding against the actual code before fixing
3. Fix **all valid findings** (P0, P1, and P2) in a single commit
4. Push once
5. **Reply to every Greptile comment thread** confirming the fix:
   - Inline comments: `gh api repos/{owner}/{repo}/pulls/comments/{id}/replies -f body="Fixed in \`SHA\`: <what changed>"`
   - Issue comments: `gh api repos/{owner}/{repo}/issues/{N}/comments -f body="@greptileai Fixed: <summary>"`
6. Resolve threads via GraphQL (same as CR threads)
7. Use 👍/👎 reactions on Greptile comments to provide feedback
8. **Severity-gated re-review:**
   - **If any P0 findings were present:** Trigger `@greptileai` again to confirm P0 resolution. This consumes one re-review.
   - **If only P1/P2 findings (no P0):** Do NOT trigger `@greptileai` again. The PR is merge-ready after the fix push.
   - Stay on Greptile — do not switch back to CR.

## Detecting a Merge-Ready Greptile Review

A Greptile review is **merge-ready** when any of these are true:

- **No findings at all** (fully clean) — merge immediately.
- **Findings are all P1/P2 (no P0)** — fix them, push, reply to threads, but skip re-review. Merge-ready after the fix push.
- **P0 findings were present, fixed, and re-review shows no P0 findings** — merge-ready after the confirmation review.

Also watch for 👍 completion signal with no inline comments (= fully clean pass).

### Greptile Review Budget

**Max 3 Greptile reviews per PR** (1 initial + up to 2 re-reviews for P0 cascades). Track the count: increment on each `@greptileai` trigger. At 3 with persistent P0 findings, self-review + report blocker. Do not trigger a 4th review.

## Self-Review Fallback

If BOTH CR and Greptile are unavailable (CR rate-limited + Greptile timeout):

1. Perform a self-review of the full diff (`git diff main...HEAD`)
2. Check for: bugs, security issues, error handling, types, naming, edge cases
3. A clean self-review does NOT satisfy the merge gate
4. Tell the user both reviewers are down and what was left unreviewed
