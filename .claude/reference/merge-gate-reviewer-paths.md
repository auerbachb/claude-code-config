# Merge Gate — Reviewer Path Details

Full path-specific rules extracted from `.claude/rules/cr-merge-gate.md` Step 1. The rule file keeps the polling exit criterion and step headers; this file holds per-path semantics. **`merge-gate.sh` is authoritative** — re-read its JSON when in doubt.

## Check-run dedup — all paths (#675)

Every check-run read goes through `.claude/scripts/check-runs-dedup.sh` before anything classifies it: `ci-status.sh`, `merge-gate.sh`, `pr-state.sh` (and so `escalate-review.sh`), and `pr-preflight.sh`.

GitHub keeps a record for **every** run of a check on a commit, and each re-trigger opens a new check suite — so the `commits/{sha}/check-runs` endpoint returns an old failed run right next to the new passing one. The endpoint's `filter=latest` does not help; it is latest-per-*suite*. GitHub's own PR page resolves each check name to its newest run, and the dedup does the same:

- Runs are grouped by `(app, check name)`; only the group's newest `check_suite.id` survives.
- **All** runs in that newest suite are kept, so matrix legs sharing a name stay separate and a failing leg is never masked by a passing sibling.
- Ordering is by `check_suite.id`, not `completed_at` — an in-progress run has no `completed_at`, and a still-running newest run must read as *pending*, not as the older run's failure.
- Same-named checks from different apps never collapse into each other.
- A run with no `check_suite.id` is retained regardless: dropping a run can only mask a failure, so unknown data fails toward blocking.

**Consequence for polling:** a check that failed and was re-run stops blocking the moment the newer run lands — no rebase or new push required. If tooling still reports a failure GitHub's merge box shows as green, suspect the fetch bypassed the helper, not the dedup rule.

## CR path

Applies when neither BugBot nor Greptile was triggered (`merge-gate.sh` reviewer `cr`).

- **Gate:** at least one of **CodeRabbit** (`coderabbitai[bot]`) or **CodeAnt** (`codeant-ai[bot]`) with `state: "APPROVED"` and `commit_id == current HEAD SHA`. Either bot satisfies the primary review; you do not need both when only one reviewed.
- **Routing (live scan):** CodeAnt or CodeRabbit in PR history → CR path; cursor-only → BugBot (`merge-gate.sh`, `reviewer-of.sh`).
- **SHA freshness:** stale approvals do not count (wrong `commit_id`); re-trigger `@coderabbitai full review` or `@codeant-ai review` for the bot that must refresh, subject to the rate cap, and keep polling.
- **Retraction:** a newer same-SHA `CHANGES_REQUESTED` from the **same** bot retracts that bot's earlier `APPROVED` until findings are fixed, pushed, and re-approved (same rule as legacy CR-only, evaluated per bot).
- **Stale bot `CHANGES_REQUESTED`:** A bot review with `state: CHANGES_REQUESTED` but `commit_id` **not** equal to the current PR head is obsolete after you push fixes. **`/fixpr` dismisses these** via `.claude/scripts/dismiss-stale-bot-changes.sh` after every push (bots only — never humans). If `merge-gate.sh` or GitHub still shows `reviewDecision: CHANGES_REQUESTED` because of leftover bot reviews on old SHAs, **dismiss those reviews** (automation or GitHub UI) rather than treating it as a human change request. Human-authored `CHANGES_REQUESTED` on the current HEAD still blocks until addressed or withdrawn by that reviewer.
- **Not approvals:**
  - The "Actions performed — Full review triggered" ack comment (review started, not finished).
  - "0 unresolved threads right now" without an APPROVED review on the current SHA.
  - Absence of findings in the first N minutes after triggering (CR can run slowly or time out).
  - CR check-run `status: "completed"` without an accompanying APPROVED review object on the current SHA.
- **Re-trigger policy:** after 12 min without approval, re-trigger `@coderabbitai full review` up to 2 times on the same SHA, capped at 2 explicit triggers/PR/hour. Rate-limit signals override the timeout. After 2 failed re-triggers on one SHA, fall back BugBot → Greptile → self-review.

## CodeAnt on the CR path

`codeant-ai[bot]`; parallel to CR — see `cr-github-review.md`.

- **Applies** when CodeAnt has review/comment on current HEAD **or** a CodeAnt check-run on that commit.
- **Clean:** `APPROVED` on HEAD **or** completed CodeAnt check with `conclusion: success` — read from the deduped list, so a superseded CodeAnt success no longer counts as clean when a newer CodeAnt run failed (#675).
- **Retraction:** `CHANGES_REQUESTED` blocks only if newer than latest clean signal on that SHA. Threads: Step 1c in `cr-merge-gate.md`.

## BugBot path

CR failed, BugBot responded, Greptile never triggered — sticky; see `bugbot.md`.

- 1 clean BugBot review on the current HEAD SHA satisfies the gate (BugBot's completion signals are reliable).
- After fixing BugBot findings, CI already posted `@cursor review` on that push; `/fixpr` also posts it after agent pushes. If BugBot still hasn't completed after polling, post `@cursor review` again — duplicates are acceptable (see `bugbot.md`).
- Stay on BugBot — do not switch back to CR. Ignore late CR reviews.

## Greptile path

Greptile was triggered at any point — both CR and BugBot failed — sticky assignment, see `greptile.md`.

- Severity-gated: merge-ready when ANY of these hold:
  1. **Clean review:** no findings (thumbs-up with no inline comments).
  2. **No P0 findings:** only P1/P2 findings present — fix all of them, push, reply to threads; no re-review required.
  3. **P0 fixed + re-review clean:** P0 findings were present, fixed, and a re-triggered `@greptileai` review came back clean.
- Stay on Greptile — do not switch back to CR or BugBot. Ignore any late CR/BugBot reviews.
- Max 3 Greptile reviews per PR (initial + up to 2 P0 re-reviews). At 3 with persistent P0, self-review and report blocker.

## All three down

Self-review for risk reduction only. A clean self-review does NOT satisfy the gate; report the blocker.
