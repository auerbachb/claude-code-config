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

## Stale-approval guard — all review paths (issue #836)

GitHub retargets a review's `commit_id` to the new HEAD SHA after a force-push (when diff context persists), but `submitted_at` is never changed. An approval submitted _before_ the force-push therefore shows `commit_id == HEAD` with a `submitted_at` that predates the HEAD commit's `committer.date`. `merge-gate.sh` rejects such approvals even when `commit_id` matches, using `LAST_COMMIT_TS` (HEAD committer date, already fetched for the Greptile freshness gate). Applies to: CR/CodeAnt `APPROVED` reviews, CodeAnt clean check-run `completed_at`, and BugBot reviews. Guard is disabled when `LAST_COMMIT_TS` is empty (API failure). Distinct `missing[]` reason: "predates the HEAD commit (force-push retargeting) — re-review required".

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

- A clean BugBot pass on the current HEAD SHA satisfies the gate. Two accepted shapes (issue #844):
  1. A `cursor[bot]` review object on HEAD with no `CHANGES_REQUESTED` and no fresh inline findings.
  2. A completed `Cursor Bugbot` check-run with `conclusion: "success"` on HEAD **published by the Cursor app** (`app.slug == "cursor"`, app id `1210556`), no failure-phrase `cursor[bot]` comment postdating the HEAD commit, and `completed_at`/`started_at` postdating the HEAD commit — the "silent pass" shape where BugBot found nothing and posted no review object. A same-named run from any other publisher does **not** satisfy this shape.
- **Silent-pass failure-phrase filter (issue #844):** `merge-gate.sh` only counts failure-phrase cursor[bot] comments whose `created_at` is after `LAST_COMMIT_TS`. Comments predating the HEAD commit are stale and cannot block a fresh success check-run. When `LAST_COMMIT_TS` is unknown, all failure-phrase comments are conservatively counted; when a comment has no `created_at`, it is also conservatively counted (fail-closed).
- **Silent-pass timestamp fail-closed:** when `LAST_COMMIT_TS` is known but the check-run has no `completed_at` or `started_at`, `merge-gate.sh` treats it as unverifiable and blocks (mirrors the CodeAnt supplemental gate).
- **Silent-pass publisher fail-closed (issue `#962`):** a check *name* identifies a check, never a publisher — any GitHub App may publish a run called `Cursor Bugbot`. `merge-gate.sh` therefore requires `app.slug == "cursor"` on the success check-run, and blocks with its own `missing[]` reason (`was not published by the Cursor app …`) when the slug is foreign, empty, or absent — checked ahead of the freshness checks, since an unattributable run is not worth dating. This fails **closed**, the opposite of the same identity check in `escalate-review.sh` (issue `#956`): there an unverifiable publisher costs one duplicate `@cursor review`, here it would satisfy the merge gate outright. Shape 1 is unaffected — it keys on `.user.login == "cursor[bot]"`, already an identity match.
- After fixing BugBot findings, CI already posted `@cursor review` on that push; `/fixpr` also posts it after agent pushes. If BugBot still hasn't completed after polling, post `@cursor review` again — duplicates are acceptable (see `bugbot.md`).
- Stay on BugBot — do not switch back to CR. The sticky pointer in `session-state.json` remains `bugbot` for the life of the PR.
- **Exception (issue #865):** a fresh CodeRabbit or CodeAnt `APPROVED` on the current HEAD SHA satisfies the gate even when `reviewer == bugbot`. `merge-gate.sh` sets `CR_PATH_APPROVED_ON_HEAD=true` (in the shared pre-case block) when `CR_APPROVAL_VALID || CA_APPROVAL_VALID`, and the `bugbot)` branch checks this flag before running any BugBot-specific checks. All freshness (#836), retraction (#893), and substance (#875/#876) guards that apply to the CR path also apply here — the same code paths are reused, not a weaker copy. Rationale: the sticky rule prevents gaming (switching to a friendlier reviewer), but a genuine APPROVED on the exact HEAD SHA is an independent verifiable signal that stands on its own regardless of which reviewer the PR is currently assigned to.

## Greptile path

Greptile was triggered at any point — both CR and BugBot failed — sticky assignment, see `greptile.md`.

- **Detection channel:** Greptile posts via **issue comments** (`issues/{N}/comments`), not formal PR review objects (`pulls/{N}/reviews`). `merge-gate.sh` detects a clean pass from the latest fresh `greptile-apps[bot]` issue comment with a 👍 reaction (`+1 >= 1`) and zero `greptile-apps[bot]` inline diff comments on the PR. Formal review objects are kept as a supplemental fallback signal. (Issue #723 — observed live on PR #721 where the script missed a clean pass because it only checked the formal-review endpoint.)
- **Freshness and fix-only reuse (issue #1000):** fresh signals still use the post-HEAD-push comment/review/inline path. When a later fix-only push has no fresh Greptile signal, the gate may reuse the latest completed review round's zero-P0 verdict. The durable round boundary is the latest `@greptileai` trigger in issue-comment history; Greptile evidence must follow it. An unanswered latest trigger fails closed. Legacy history without a retained trigger is scanned conservatively in full.
- Severity-gated: merge-ready when ANY of these hold:
  1. **Clean review:** fresh `greptile-apps[bot]` issue comment with 👍 AND zero inline diff comments.
  2. **No P0 findings:** only P1/P2 findings present — fix all of them, push, reply to and resolve threads; no re-review required. After the fix-only push, the latest completed trigger-delimited zero-P0 round satisfies reviewer evidence even though it predates HEAD.
  3. **P0 fixed + re-review clean:** P0 findings were present, fixed, and a re-triggered `@greptileai` review came back clean.
- A latest completed round containing any formal P0 badge is never reusable after a push; it requires a later triggered clean review. Complete absence of Greptile review history never satisfies the gate. Current-head authorship, CI, unresolved-thread, merge-state, and mergeability gates remain universal.
- Stay on Greptile — do not switch back to CR or BugBot. Ignore any late CR/BugBot reviews.
- Max 3 Greptile reviews per PR (initial + up to 2 P0 re-reviews). At 3 with persistent P0, self-review and report blocker.

## All three down

Self-review for risk reduction only. A clean self-review does NOT satisfy the gate; report the blocker.
