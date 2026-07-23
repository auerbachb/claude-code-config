# Merge Gate & Pre-Merge Verification

> **This is the single authoritative definition of the merge gate.** All other rule files reference this file instead of duplicating it.
> **Always:** Verify merge gate before any merge. Verify CI. Verify AC checkboxes against code. Ask user before merging (except `/wrap`/`/merge`; Step 3).
> **Ask first:** Merging; `/wrap`/`/merge` skip this step (Step 3).
> **Never:** Merge without meeting the gate. Merge with failing CI. Merge with unchecked AC boxes. Stop polling because "nothing is unresolved right now" — see "Polling exit criterion" below.

## Polling exit criterion

Stop polling ONLY when one current-HEAD review path below is satisfied:

1. **CR path:** explicit clean `APPROVED` from CodeRabbit or CodeAnt on current HEAD (freshness/retraction rules in Step 1); when CodeAnt participated on that SHA, CodeAnt must also be clean.
2. **BugBot:** clean BugBot pass on current HEAD.
3. **Greptile:** severity gate passed.

"0 unresolved threads right now" is transient, not an exit condition. After any fix push, HEAD changes and reviewers re-run; keep polling for a current-HEAD gate.

## Step 1 — Confirm reviews are clean (merge gate)

The merge gate depends on which reviewer owns the PR. Compact per-path gates below (every binding condition retained); expanded per-path prose: `.claude/reference/merge-gate-reviewer-paths.md`.

**CR path** (neither BugBot nor Greptile triggered — `merge-gate.sh` reviewer `cr`): **CodeRabbit** (`coderabbitai[bot]`) or **CodeAnt** (`codeant-ai[bot]`) with `state: "APPROVED"` and `commit_id == current HEAD SHA` — either bot alone suffices. Routing: CodeAnt/CodeRabbit in PR history → CR path; cursor-only → BugBot (`reviewer-of.sh`). Stale-SHA approvals never count — re-trigger the bot that must refresh (rate cap applies) and keep polling. A newer same-SHA `CHANGES_REQUESTED` from the same bot retracts its earlier `APPROVED` until fixed, pushed, re-approved. Bot `CHANGES_REQUESTED` on an old SHA is obsolete after a fix push — `/fixpr` dismisses via `dismiss-stale-bot-changes.sh` (bots only, never humans); dismiss leftovers rather than reading their `reviewDecision: CHANGES_REQUESTED` as a human block. Human `CHANGES_REQUESTED` on current HEAD blocks until addressed/withdrawn. **Not approvals:** the "Full review triggered" ack; "0 unresolved threads" without an APPROVED on current SHA; early absence of findings; a completed CR check-run without an APPROVED review object. **Re-trigger policy:** 12 min without approval → `@coderabbitai full review`, max 2 per SHA within the 2/PR/hour cap (rate-limit signals override the timeout); after 2 failures on one SHA, fall back BugBot → Greptile → self-review.

**CodeAnt on the CR path:** applies when CodeAnt has a review/comment or check-run on current HEAD. Clean = `APPROVED` on HEAD or completed CodeAnt check with `conclusion: success`; `CHANGES_REQUESTED` blocks only if newer than the latest clean signal on that SHA. Threads: Step 1c.

**BugBot path** (CR failed, BugBot responded — sticky; `bugbot.md`): 1 clean BugBot review on current HEAD satisfies the gate. Re-review after fixes: `bugbot.md` §Re-Reviews. Never switch back to CR; ignore late CR reviews.

**Greptile path** (both CR and BugBot failed — sticky; `greptile.md`): merge-ready when ANY of: **clean review** (👍, no inline comments); **no P0** (only P1/P2 — fix all, push, reply; no re-review required); or **P0 fixed + re-triggered review clean**. Max 3 Greptile reviews per PR; at 3 with persistent P0, self-review and report the blocker. Never switch back to CR/BugBot; ignore their late reviews.

**All three down:** self-review for risk reduction only — it never satisfies the gate; report the blocker.

**CR detection order:** ack means started; CodeRabbit check-run success means complete; only an APPROVED review object on current HEAD satisfies the gate. Once Step 1 passes, proceed immediately to Step 1b.

### Code-owner bots

When branch protection requires code-owner reviews and a review bot is in `CODEOWNERS`, that bot's fresh `APPROVED` on current HEAD satisfies the requirement — don't ask the author to self-approve (`merge-gate.sh` enforces this). Stale/dismissed after a push → re-trigger and keep polling. Full handling + commands: `.claude/reference/codeowner-bot-approvals.md`.

## Step 1b — CI Must Pass Before Merge (NON-NEGOTIABLE)

Before running `gh pr merge` on ANY PR, verify ALL CI check-runs are complete and passing. Use `.claude/scripts/ci-status.sh <PR_NUMBER_OR_SHA> --format summary`: exit `0` clean+complete, `1` incomplete (WAIT), `3` blocking failures (FIX). `.claude/scripts/merge-gate.sh` calls it; fallback commands live in `.claude/reference/cr-polling-commands.md`.

**If any check-run is incomplete: DO NOT MERGE.** Wait; null conclusion means not reported, not passed.

**If any check-run has a blocking conclusion (`failure`, `timed_out`, `action_required`, `startup_failure`, `stale`): DO NOT MERGE.** Read the failure output, fix, push, and merge only after ALL checks complete with non-blocking conclusions.

Check-runs are deduped per `(app, check name)` to the newest check suite before classification, matching GitHub's merge box — a re-run supersedes its earlier result, so a stale failure never blocks (#675, `check-runs-dedup.sh`).

Applies to ALL merge paths: `gh pr merge`, `/merge`, `/wrap`, Phase C verify-and-wrap.

## Step 1c — All Review Threads Resolved (NON-NEGOTIABLE)

Every thread must be `isResolved: true` via GraphQL `reviewThreads` (REST misses cursor/copilot bots). `merge-gate.sh` enforces this — any unresolved thread blocks, regardless of author. **If any unresolved: DO NOT MERGE.** Reply, then `resolve-review-threads.sh <PR>`, re-check.

## Step 1d — `mergeStateStatus` and branch sync (NON-NEGOTIABLE)

**Do not infer “behind base” from `mergeStateStatus: "BLOCKED"` alone.** Read **`mergeStateStatus` and `mergeable`** explicitly (`gh pr view <N> --json mergeStateStatus,mergeable,reviewDecision` — same as `merge-gate.sh`).

- **`CLEAN`** — OK for merge once Steps 1–1c and 1b pass.
- **`BEHIND`** — Run `.claude/scripts/clean-behind-check.sh <N>` (#631, #667). Exit 0 (`safe_to_offer`) → **offer `/admin-merge`** — user choice, never auto-run; `churn.advisory` is context, not a gate. Otherwise rebase → re-run via `/fixpr` (`fixpr/SKILL.md` / `pr-state.sh`), **force-push only** after `dirty-main-guard.sh --check`; `merge-gate.sh` stays failing. Overlap detection and `--churn-threshold`: `clean-behind-check.sh --help`.
- **`BLOCKED`** — Use `reviewDecision`, CI, threads — not a substitute for **`BEHIND`**.
- **`UNSTABLE` / `DIRTY` / `UNKNOWN`** — Not merge-ready; wait, rebase, or resolve per `fixpr` / Step 1b.

**`mergeable == "CONFLICTING"`** — conflicts; `/fixpr` rebase path.

## Step 2 — Verify every Test Plan checkbox (MANDATORY — do NOT skip)

> After Steps 1b–1d pass (`merge-gate.sh` enforces CI, resolved threads, and merge metadata), verify AC before merge.
>
> 1. Fetch the PR body via `gh pr view N --json body`
> 2. Parse **every** checkbox in the **Test plan** section
> 3. For each item, read the relevant source file(s) and verify the criterion is met
> 4. Check off passing items by editing the PR body (`- [ ]` → `- [x]`)
> 5. If any item fails, fix the code first — do NOT offer to merge with unchecked boxes
> 6. Only after **ALL** boxes are checked, proceed to Step 3
>
> Re-run after every review round — verification reflects the code **at merge time**, not an earlier checkpoint. Skipping this step is a **blocking failure**; the user should never see unchecked AC boxes when asked about merge.

## Step 3 — Confirm merge intent with the user

**Default:** ask squash-merge vs review. **`/wrap` / `/merge`:** after Steps 1–2, `gh pr merge --squash` with no extra prompt; overrides this step and `CLAUDE.md` for that scope (see skills).

- Always use **squash and merge** (never regular merge or rebase)
- `/wrap`'s post-merge phases (follow-ups, session sweep, lessons; see `wrap/SKILL.md`) run **after** the gate clears — they never gate the merge.
