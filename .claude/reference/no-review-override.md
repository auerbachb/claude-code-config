# No-review override (issue #1899)

Owner policy, stated in chat: when no AI reviewer has produced a verdict on a PR's current HEAD within a window (default **10 minutes**), merge anyway — provided every other hard stop passes — and log the merge so it can be reviewed later (Issue #1900's overnight backfill). The goal is cost: a PR whose free reviewers are rate-limited or silent should not sit blocked or pull in a paid reviewer. The override **never triggers, invites, or pays for a review**.

The auto-loaded rule is the short paragraph in `cr-merge-gate.md` Step 1; this file holds the mechanism.

## Where it lives

| Piece | File |
|-------|------|
| Decision (verdict inventory, anchor, window) | `.claude/scripts/no-review-override.sh` |
| Gate glue (which `missing[]` reasons may be waived) | `.claude/scripts/lib/no-review-override-apply.sh`, sourced by `merge-gate.sh` |
| Window setting | `NO_REVIEW_OVERRIDE_MINUTES` in the base branch's `## Review policy` ini block, read by `review-tier.sh` |
| Paid-escalation precedence | `escalate-review.sh` `emit_unless_override` |
| Admin-bypass refusal | `admin-merge.sh` (`AUTO_PLAIN_REFUSED: reason=no-review-override`, exit 1) |
| Merge + ledger + label + report suffix | `/wrap` Step 2.4 and Step 4.3; `/merge` Step 5 |
| Ledger | `.claude/scripts/unreviewed-merge-ledger.sh` → `~/.claude/unreviewed-merges.json` |

## What the gate waives — and what it never waives

`merge-gate.sh` appends every hard stop to `missing[]` first, then marks `REVIEW_BLOCKER_START`. Everything after the mark is **reviewer coverage** — the CR/CodeAnt approval and substance reasons, the CodeAnt supplemental gate, BugBot, Greptile, and the `ci+codeant-one-round` round requirement. Only those can be waived.

Never waived (they sit before the mark): authorship, `BEHIND` / `CONFLICTING` / `DIRTY` / `UNKNOWN` merge state, failing or incomplete build CI, branch-protection required contexts, unresolved threads, human `CHANGES_REQUESTED` (on HEAD or stale), the CODEOWNERS `reviewDecision` note, and an unresolved review tier. Test Plan / AC verification is `/wrap` Step 2.2 and runs unchanged.

**CI.** A pending reviewer check-run (CodeRabbit, CodeAnt, BugBot, Greptile, Graphite — matched by exact app slug, as `ci-status.sh --exclude-reviewers` does) would otherwise hold "CI incomplete" forever and extend the window without limit. When the override applies, the CI reasons are re-derived with `--exclude-reviewers`; the dropped runs are listed in `excluded_reviewer_checks`. A *completed* reviewer check is a verdict, so the override never applies with one present — unless that run is a refusal (rate limit, usage limit, no subscription), which is not a review; see "What counts as a verdict on HEAD" below. A pending reviewer check that branch protection **requires** still blocks through the required-context gate.

## What counts as a verdict on HEAD

Any one disables the override, and the normal reviewer path decides (so an adverse bot verdict is never waived):

- a non-`PENDING`, non-`DISMISSED` review by a reviewer bot with `commit_id == HEAD` — except an `APPROVED` that is hollow (`review_evidence.hollow`) or whose `submitted_at` predates the HEAD commit. Discounting an approval only removes a positive signal; `CHANGES_REQUESTED` and `COMMENTED` always count;
- an inline comment by a reviewer bot anchored to HEAD (`commit_id` or `original_commit_id`);
- a Greptile summary naming HEAD as its last reviewed commit;
- a `done` row of CodeAnt's run record that names HEAD;
- a completed reviewer-app check-run with conclusion `success`, `failure`, `action_required`, or `neutral` — unless the run is a refusal, which is not a review (Issue #1939). One classifier (usage limit, couldn't run, rate limit, review limit reached, no subscription) decides it two ways:
  - **Title:** the run's own `output.title` matches (CodeRabbit titles a rate-limited run "Review rate limited").
  - **Notice:** that bot has a matching comment written at or after the run's `started_at`, or up to **60 seconds** before it when the notice names HEAD. CodeRabbit posts "Review limit reached" about a second *before* its neutral run starts.
  - **Notice time** is the later of `created_at` and `updated_at`, since CodeRabbit rewrites the same summary comment in place on later pushes.
  - **Never discounted by a notice:** a run whose notice is older than the skew allows (one from before the push), one whose notice names another commit (`"headCommitId":"<sha>"`), or one whose `started_at` is unreadable — the commit date is never a stand-in run start.
  - A refused bot is reported in `missing_reviewers` as `capability_failure`. Full rule set and the no-upper-bound rationale: the `no-review-override.sh` header and its notice-block comment.

Not verdicts: pending reviewer check-runs, "review in progress", rate-limit and trigger-ack comments.

Each reviewer without a verdict is listed in `missing_reviewers` with a reason: `review_in_progress`, `capability_failure`, `discounted_approval`, or `no_head_signal`.

## The HEAD anchor

GitHub records no event for an ordinary push, and a committer date can be days older than the push, so "pushed 10 minutes ago" is reconstructed conservatively — the **latest** of:

- the HEAD committer date;
- the PR's `created_at`;
- the newest `ready_for_review`, `reopened`, or `head_ref_force_pushed` timeline event;
- the **earliest** `created_at` of a `pull_request`/`pull_request_target` workflow run for HEAD on the PR's own head repo and ref — **required**: those runs exist only once this PR points at HEAD, whereas check-runs on a SHA can predate the PR adopting it (an ordinary push of a SHA already built on another branch leaves no timeline event);
- the **earliest** `started_at` of the raw (undeduped) HEAD check-runs.

The latest lower bound never understates the push time, so the window can expire late, never early. Ineligible (override off for this evaluation, gate exactly as before): a draft PR, unreadable PR metadata, timeline, or workflow-run list, no such `pull_request` run (so a repo without a `pull_request` workflow never takes the override), a malformed timestamp, no HEAD check-run start time. "Now" is the real clock — deliberately no flag or environment override, so ambient state cannot expire a merge-authorizing window. The anchor is reported as `head_anchor_ts` + `anchor_source`, never as an exact push time.

## Configuration

```ini
NO_REVIEW_OVERRIDE_MINUTES=10
```

In the base branch's `.claude/pm-config.md` `## Review policy` section, inside a live ```` ```ini ```` block (same reading rule as `REVIEW_ESCALATION`). Absent → 10. An integer 1–1440 → that many minutes. `off` → disabled. A near-miss heading (`## Review Policy`) is read for this key like `REVIEW_ESCALATION` (the tier gate itself still resolves invalid → full). Anything else, or the key outside a live ini block, → disabled, with one stderr warning: an unclear merge-authorizing switch fails toward **not** merging unreviewed work. A `ci-only` tier has nothing to waive.

## Gate output

`merge-gate.sh` emits `no_review_override` (after `deferred_issues`):

```json
{"enabled": true, "window_seconds": 600, "eligible": true, "applied": true,
 "reason": "window_elapsed", "pending_reason": "",
 "head_anchor_ts": "…Z", "anchor_source": "earliest_head_check_start",
 "elapsed_seconds": 660, "eligible_at": "…Z",
 "verdicts_on_head": [], "missing_reviewers": [{"reviewer": "coderabbitai[bot]", "reason": "no_head_signal"}],
 "waived_reasons": ["need 1 explicit CodeRabbit or CodeAnt APPROVED review …"],
 "excluded_reviewer_checks": []}
```

`reason` is one of `disabled`, `not_needed` (the normal path already met), `tier_requires_no_review`, `verdict_on_head`, `draft_pr`, `anchor_unavailable: …`, `anchor_malformed: …`, `window_running`, `window_elapsed`, `ci_recheck_failed`. While the window runs, `pending_reason` is added to `missing[]` (with seconds remaining). `path` is `no-review-override` only when the override applied **and** `met` is true; `primary_review_met` stays false. Exit codes are unchanged. Any helper failure leaves `missing[]` untouched and the field `null` or not applied — fail closed.

## Merging

`/wrap` Step 2.4, when `no_review_override.applied`:

- `CLEAN` → `gh pr merge --squash --match-head-commit <gate head_sha>`. `UNSTABLE` takes the same command only when `excluded_reviewer_checks` is non-empty — a pending non-required reviewer check is then what produces it, and build CI and required contexts were already cleared by the gate. Any other `UNSTABLE` stops.
- `BEHIND` → never the clean-`BEHIND` admin path. `admin-merge.sh` refuses (`AUTO_PLAIN_REFUSED: reason=no-review-override`, exit 1); rebase via `/fixpr`, re-enter Step 2.1 — the rebased HEAD gets its own window. An unreviewed merge never also takes an admin bypass.
- A head-pin refusal re-enters Step 2.1.

Then `unreviewed-merge-ledger.sh record --pr N --gate-json -` with the authorizing gate JSON, and the report line becomes `merged PR #N (no AI review — logged)` (or `… — ledger write failed)`).

**Paid escalation.** `escalate-review.sh` asks `merge-gate.sh` at the two points that would spend on a paid reviewer (`switch_bugbot`, `trigger_greptile`); when the gate is met through the override it emits `gate_met` instead — so `gate_met` means "merge gate met on HEAD" (an approval or this override; stderr names which), and every consumer already branches on it the same way: stop escalating, let the merge gate end polling. The polling loop's own per-cycle `polling-state-gate.sh` → `merge-gate.sh` exit 0 then ends polling. Fails open to the old routing (a gate error changes nothing).

## The ledger

`~/.claude/unreviewed-merges.json` — `{"schema_version": 1, "entries": [...]}`, one entry per `(repo, pr, head_sha)`, repo lowercase `owner/name`. Durable across sessions and repos (it is not session state, which is repo-scoped and orchestration-only). Every write holds the `state-lock.sh` lock across the read-modify-write and commits by temp + rename.

`record` refuses (exit 4, nothing written) unless the gate JSON shows `met` and `no_review_override.applied`, and GitHub confirms the PR `MERGED` with `headRefOid` equal to the gate's `head_sha`. It then labels the PR `merged-unreviewed` (created if missing); a label failure writes the row with `label_applied: false` and a warning. Fields: `repo, pr, title, url, head_sha, merge_commit_sha, merged_at, recorded_at, window_seconds, head_anchor_ts, anchor_source, elapsed_seconds, missing_reviewers, waived_reasons, excluded_reviewer_checks, label_applied, backfill_status`.

**For the backfill (Issue #1900):** `unreviewed-merge-ledger.sh list [--repo R] [--pending]` reads it; `backfill --pr N --sha S --status <s> [--repo R]` updates `backfill_status` (starts `pending`) and stamps `backfill_updated_at`. A bot `CHANGES_REQUESTED` that lands after an override merge is the backfill's to act on — this issue only records what it needs.

Exit codes follow `session-state.sh`: 0 ok, 2 usage, 4 refused / invalid / no such entry, 5 write failure, 6 lock timeout, 8 `HOME` unset.

## Known limits

- 10 minutes will sometimes merge just before a slow CodeRabbit review would have landed. That is accepted; the backfill covers it, and the window is configurable once there is data.
- A force-push restarts the window (the `head_ref_force_pushed` anchor), so a busy main that keeps a PR `BEHIND` can repeat the wait after each rebase.
