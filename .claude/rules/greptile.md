# Greptile — Last-Resort Fallback Reviewer

> **Always:** Poll for response after triggering. Reply to every thread. Fix all valid findings. Classify by severity (P0/P1/P2). Only re-review for P0. Stay on G once triggered for a PR.
> **Ask first:** Never — fix findings autonomously.
> **Never:** Trigger Greptile before both CR AND BugBot have failed. Ignore Greptile findings. Switch a PR back to CR/BugBot after Greptile has been triggered. Include `@greptileai` in reply comments (triggers a paid re-review with no learning benefit).

Greptile is the **last-resort paid** AI code reviewer — only triggered when both CR and BugBot (Cursor) have failed. Review chain: **CR → BugBot → Greptile → self-review.** Verify all findings against code. Key differences from CR/BugBot: cost ($1/review beyond 50/month quota), accurate completion signals (no ambiguity between ack and approval as there is with CR).

## Greptile Basics

- **Bot username:** `greptile-apps[bot]`
- **Trigger:** Comment `@greptileai` on any PR (no "full review" suffix, unlike CR)
- **Auto-trigger:** OFF (see `.claude/reference/greptile-setup.md`). Must be explicitly triggered.
- **Rate limits:** 50 reviews/seat/month included, $1/extra — no per-hour throttle
- **Review time:** ~1-3 minutes
- **Completion signals:** 👀 = analyzing, 👍 = complete, 😕 = failed
- **No CLI** — local review loop uses CR CLI only
- **Config:** Optional `greptile.json` in repo root. Trigger filters at app.greptile.com.
- **Feedback:** 👍/👎 reactions train it over 2-3 weeks

## Dashboard Configuration

One-time setup at app.greptile.com. See `.claude/reference/greptile-setup.md` for settings table and setup steps.

## Daily Budget

Hard daily cap prevents runaway costs when many PRs run in parallel.

- **Default budget: 40 reviews/day** (set `budget` in `session-state.json`).
- **Tracking:** The `greptile_daily` section in `~/.claude/session-state.json` tracks `reviews_used`, `date` (YYYY-MM-DD in ET timezone), and `budget`. See `handoff-files.md` for the schema.
- **Enforcement:** `.claude/scripts/greptile-budget.sh` is the single source of truth for this contract. Every `@greptileai` trigger point MUST gate on `greptile-budget.sh --consume` (exit 0 = consumed, exit 1 = exhausted). The script handles same-day reset, cross-day reset, atomic write-back, and sibling preservation on the state file. Do not reinvent the budget math inline.
- **Example gate:**
  ```bash
  if ! .claude/scripts/greptile-budget.sh --consume >/dev/null; then
    echo "Greptile budget exhausted — falling back to self-review" >&2
    exit 1
  fi
  gh pr comment "$PR" --body "@greptileai"
  ```
  Use `--check` for a read-only snapshot and `--reset` to force-zero today's counter. See `greptile-budget.sh --help` for full details.
- **Budget exhaustion fallback:** Perform a self-review instead. Self-review does NOT satisfy the merge gate. Report the blocker to the user:
  > "Greptile budget exhausted ({reviews_used}/{budget}). PR #{N} falling back to self-review — merge blocked until manual review or budget resets tomorrow."
- **This check applies to all Greptile trigger points** (CR GitHub fallback, local post-push, Phase B polling, and per-PR re-reviews). No `@greptileai` comment may be posted without a successful `--consume` first.

## Before EVERY `@greptileai` Re-Trigger (MANDATORY — after initial trigger)

Applies to 2nd/3rd triggers only; initial trigger requires only the budget check (no severity classification).

1. **Classify all findings from the previous review** (P0/P1/P2).
2. **If NO P0:** STOP — do NOT trigger `@greptileai`. Proceed to Phase B completion (merge gate check).
3. **If P0 present:** perform budget check (see "Daily Budget" above) → trigger `@greptileai`.
4. **Log severity counts in handoff `notes`.**

## When to Trigger Greptile

**Greptile is last-resort only.** Never trigger it before both CR AND BugBot have failed. It is only triggered when both upstream reviewers fail for a specific PR:

1. **CR rate-limit + BugBot timeout:** CR is rate-limited (fast-path) AND BugBot has not posted within 10 min → trigger Greptile. Rate-limit signals override CR's 12-min ceiling (escalate immediately, wait only on BugBot's 10).
2. **CR timeout + BugBot timeout:** no CR review within 12 min AND no BugBot review within 10 min → trigger Greptile.

In both cases, always check if BugBot (`cursor[bot]`) already posted a review before triggering Greptile — BugBot auto-runs on every push, so it may have responded while you were waiting for CR.

### Sticky Assignment

**Once Greptile is triggered for a PR, it stays on Greptile permanently.** Do not switch back to CR or BugBot. After fixing findings, only re-trigger `@greptileai` for P0 findings. Ignore late CR/BugBot reviews. Merge gate is severity-dependent — see `cr-merge-gate.md` (Step 1) for the authoritative definition.

## Polling for Greptile Response

Poll every 60 seconds on all three endpoints (same pattern as CR — `pulls/{N}/reviews`, `pulls/{N}/comments`, `issues/{N}/comments` with `per_page=100`). Filter by `greptile-apps[bot]`.

**Timeout:** 10 minutes. Cadence stays 60 s. **Completion:** 👍 or review comments = done (exit immediately). 😕 = failed. No signal after 10 min = timeout.

## Processing Greptile Findings

Classify by severity (P0/P1/P2 — use Greptile badges only), verify against code, fix all valid findings in one commit, push once, reply to every thread, resolve via GraphQL. Use 👍/👎 reactions for feedback (this is Greptile's only learning mechanism).

> **CRITICAL: Do NOT include `@greptileai` in reply comments.** Every `@greptileai` mention — even in a reply — triggers a new paid review ($0.50-$1.00). Greptile does not learn from text replies. Use plain text only in replies — `@greptileai` is ONLY for intentionally requesting a new review.

Reply commands and CR-vs-Greptile comparison: `.claude/reference/greptile-reply-format.md`.

**Severity-gated re-review:** See the "Before EVERY `@greptileai` Re-Trigger" checklist above.

## Merge Gate

**Canonical definition:** See `cr-merge-gate.md` (Step 1). That file is the single authoritative source for the CR 1-explicit-APPROVED-on-current-HEAD path, the BugBot 1-clean-pass path, and the Greptile severity-gated path (including the 3-review-per-PR cap and the self-review fallback when all three reviewers are down).
