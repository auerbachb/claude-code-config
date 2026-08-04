# Merge Gate & Pre-Merge Verification

> **This is the single authoritative definition of the merge gate.** All other rule files reference this file instead of duplicating it.
> **Always:** Verify merge gate before any merge. Verify CI. Verify AC checkboxes against code. After gate + AC pass, auto-run full `/wrap` (Step 3).
> **Ask first:** Never for merge once gate + AC pass — proceed silently via `/wrap` (Step 3).
> **Never:** Merge without meeting the gate. Merge with failing CI. Merge with unchecked AC boxes. Stop polling because "nothing is unresolved right now" — see "Polling exit criterion" below.

## Polling exit criterion

Stop polling ONLY when the current-HEAD gate for the owning reviewer path is satisfied (freshness and retraction rules in Step 1): **CR path** — an explicit clean `APPROVED` from CodeRabbit or CodeAnt on current HEAD, plus a clean CodeAnt where CodeAnt participated on that SHA; **BugBot** — a clean pass on current HEAD; **Greptile** — severity gate passed.

"0 unresolved threads right now" is transient, not an exit condition. After any fix push, HEAD changes and reviewers re-run; keep polling for a current-HEAD gate.

## Step 1 — Confirm reviews are clean (merge gate)

The merge gate depends on which reviewer owns the PR. Per-path gates below; expanded prose: `.claude/reference/merge-gate-reviewer-paths.md`.

**CR path** (neither BugBot nor Greptile triggered — `merge-gate.sh` reviewer `cr`): **CodeRabbit** (`coderabbitai[bot]`) or **CodeAnt** (`codeant-ai[bot]`) with `state: "APPROVED"` and `commit_id == current HEAD SHA` — either bot alone suffices. Routing: CodeAnt/CodeRabbit in PR history → CR path; cursor-only → BugBot (`reviewer-of.sh`). Stale-SHA approvals never count — re-trigger that bot (rate cap applies), keep polling. A newer same-SHA `CHANGES_REQUESTED` retracts that bot's earlier `APPROVED` until fixed, pushed, re-approved. Bot `CHANGES_REQUESTED` on an old SHA is obsolete after a fix push — `/fixpr` dismisses via `dismiss-stale-bot-changes.sh` (bots only); dismiss leftovers rather than reading their `reviewDecision: CHANGES_REQUESTED` as a human block. Human `CHANGES_REQUESTED` on current HEAD blocks until addressed/withdrawn. **Not approvals:** the "Full review triggered" ack; "0 unresolved threads" without an APPROVED on current SHA; early absence of findings; a CR check-run without an APPROVED review object; a hollow `APPROVED` — no substantive footprint, or one predating that bot's own run marker, after its capability-failure notice, or naming another SHA (`review_evidence`; #875). **Re-trigger policy:** 12 min → `@coderabbitai full review`, max 2/PR/hour; after 2 failures on one SHA, escalate BugBot → Greptile → self-review.

**CodeAnt on the CR path:** applies when CodeAnt has a review/comment or check-run on current HEAD. Clean = `APPROVED` on HEAD or completed CodeAnt check with `conclusion: success`; `CHANGES_REQUESTED` blocks only if newer than the latest clean signal on that SHA. Threads: Step 1c.

**BugBot path** (CR failed, BugBot responded — sticky; `bugbot.md`): 1 clean BugBot pass on current HEAD satisfies the gate (review object or silent-pass success check-run — issue #844; see `bugbot.md` §Merge Gate for accepted shapes). Re-review after fixes: `bugbot.md` §Re-Reviews. Never switch back to CR; ignore late CR reviews.

**Greptile path** (sticky; `greptile.md`): merge-ready on **clean review** (👍); **no P0** (fix P1/P2, push, no re-review — the latest completed trigger-delimited zero-P0 round remains reusable after that fix-only push); or **P0 fixed + re-review clean**. A P0 round is never reusable, and no review history never passes. Max 3 reviews per PR; at 3 with persistent P0, self-review and report. Never switch back to CR/BugBot; ignore their late reviews.

**All three down:** self-review for risk reduction only — it never satisfies the gate; report the blocker.

Once Step 1 passes, proceed immediately to Step 1b.

### Code-owner bots

When a review bot is in `CODEOWNERS`, its fresh `APPROVED` on current HEAD satisfies the code-owner requirement (`merge-gate.sh` enforces this); re-trigger if stale after a push. Full handling: `.claude/reference/codeowner-bot-approvals.md`.

## Step 1b — CI Must Pass Before Merge (NON-NEGOTIABLE)

Before running `gh pr merge` on ANY PR, verify ALL CI check-runs are complete and passing. Use `.claude/scripts/ci-status.sh <PR_NUMBER_OR_SHA> --format summary` (exit `0` clean, `1` incomplete, `3` failures). `merge-gate.sh` calls it; fallback: `.claude/reference/cr-polling-commands.md`.

**If any check-run is incomplete: DO NOT MERGE.** Wait; null conclusion means not reported, not passed.

**If any check-run has a blocking conclusion (`failure`, `timed_out`, `action_required`, `startup_failure`, `stale`): DO NOT MERGE.** Read the failure output, fix, push, and merge only after ALL checks complete with non-blocking conclusions.

Check-runs dedupe per `(app, check name)` to the newest suite, so a stale failure never blocks (`check-runs-dedup.sh`).

Applies to ALL merge paths: `gh pr merge`, `/merge`, `/wrap`, Phase C verify-and-wrap.

## Step 1c — All Review Threads Resolved (NON-NEGOTIABLE)

Every thread must be `isResolved: true` via GraphQL `reviewThreads` (REST misses cursor/copilot bots). `merge-gate.sh` enforces this — any unresolved thread blocks, regardless of author. **If any unresolved: DO NOT MERGE.** Reply, then `resolve-review-threads.sh <PR>`, re-check.

## Step 1d — `mergeStateStatus` and branch sync (NON-NEGOTIABLE)

**Do not infer “behind base” from `mergeStateStatus: "BLOCKED"` alone.** Read **`mergeStateStatus` and `mergeable`** explicitly (`gh pr view <N> --json mergeStateStatus,mergeable,reviewDecision` — same as `merge-gate.sh`).

- **`CLEAN`** — OK for merge once Steps 1–1c and 1b pass.
- **`BEHIND`** — Run `.claude/scripts/clean-behind-check.sh <N>`:
  - Exit 0 → do **Step 2 first**, then **auto-merge via `admin-merge.sh <N> --auto-plain --ac-verified`** (no user turn; report evidence after). The `BEHIND` entry remains in `merge-gate.sh`'s `missing[]`; verified evidence satisfies only that blocker inside `admin-merge.sh`.
  - Exit 8 from `admin-merge.sh` (protection change or repeat) → **offer `/admin-merge`**, never auto-run.
  - Any other failure → rebase via `/fixpr` (`fixpr/SKILL.md`), **force-push only** after `dirty-main-guard.sh --check`. `churn.advisory` is context only.
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
> Re-run after every review round — verification reflects code **at merge time**.
>
> Skipping this step is a **blocking failure** — the user should never see unchecked AC boxes at merge time.

## Step 3 — Auto-merge via `/wrap`

**Default:** after Steps 1–2 pass, run **full `/wrap`** silently — no pre-merge prompt. `/merge` skips follow-ups/lessons but also proceeds without asking.

- Always use **squash and merge** (never regular merge or rebase)
- `/wrap`'s post-merge phases (see `wrap/SKILL.md`) run **after** the gate clears — they never gate the merge.
- Protection-**modifying** block (`enforce_admins` toggle) → stop and print `/admin-merge` — never auto-bypass. The plain shape (no protection change) auto-runs per Step 1d.
