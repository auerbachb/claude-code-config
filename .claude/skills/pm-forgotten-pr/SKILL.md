---
name: pm-forgotten-pr
description: One-shot triage of your open PRs with no activity above a configurable age threshold — classifies each as close or merge, renders a Forgotten PRs block, and dispatches confirmed merges as phase-c-merger subagents. Invoked inline by /pm Step 1D; can also be run standalone. Triggers on "pm-forgotten-pr", "forgotten PRs", "idle PRs", "stale PRs".
triggers:
  - forgotten PRs
  - idle PRs
  - stale PRs
argument-hint: "[days] (optional — default 3; PRs idle longer than this are surfaced)"
---

One-shot startup triage of open PRs that have gone idle. Does **not** enter a monitoring loop — continuous PR-fleet monitoring remains `/pr-monitor-and-manage`'s job.

When invoked by `/pm` Step 1D inline, `$GH_USER` and `$FORGOTTEN_PR_DAYS` are already set from the calling context. When run standalone, parse `$ARGUMENTS` as the days threshold (e.g. `/pm-forgotten-pr 7` → 7-day threshold); non-numeric or absent values fall back to 3 safely.

## Step 1: Detection

```bash
# Standalone: parse optional [days] argument from $ARGUMENTS into FORGOTTEN_PR_DAYS.
# When called inline by /pm Step 1D, FORGOTTEN_PR_DAYS is already set — skip.
if [[ -z "${FORGOTTEN_PR_DAYS:-}" ]] && [[ -n "${ARGUMENTS:-}" ]]; then
  _ARG=$(printf '%s' "$ARGUMENTS" | awk '{print $1}')
  [[ "$_ARG" =~ ^[1-9][0-9]*$ ]] && FORGOTTEN_PR_DAYS="$_ARG"
fi
# Threshold defaults to 3 days; override via FORGOTTEN_PR_DAYS (or a pm-config.md
# "Forgotten PR threshold" note resolved into it). --author defaults to @me; pass
# $GH_USER when Step 0 resolved it. The script re-validates --days and falls back
# to 3 on a non-numeric/non-positive value, so a bad override degrades safely.
DAYS="${FORGOTTEN_PR_DAYS:-3}"
.claude/scripts/forgotten-pr-triage.sh --json --days "$DAYS" ${GH_USER:+--author "$GH_USER"}
```

`forgotten-pr-triage.sh` (read-only — it never closes, merges, or deletes) enumerates your open PRs, keeps those whose **last activity** (`updatedAt`, the documented age basis) is strictly more than the threshold ago, and classifies each `close` or `merge` using exactly two close signals (first match wins; otherwise `merge`):

- **linked issue closed** — the PR's `Closes/Fixes #N` issue is already `CLOSED` (rationale `linked issue #N closed`).
- **superseded / already in main** — the PR contributes zero net-new commits to `main` (every commit already landed, including via another merged PR, by `git cherry` patch-id equivalence; rationale `superseded / already in main`).

CI/conflict state is **not** a close signal — a red or conflicted PR is surfaced as a `merge` candidate and will fail the gate visibly downstream. Each JSON record carries `number`, `title`, `url`, `headRefName`, `age_days`, `recommendation`, and `rationale`, so the block below renders and the action paths act without extra `gh` calls. Exit `0` (including the empty set) is success; only exit `2`/`3` (usage / environment) is a real error to surface.

## Step 2: Render

```
## Forgotten PRs (>N days)

- **PR #123 — {title}** — {age_days}d idle → **close** (superseded / already in main)
- **PR #130 — {title}** — {age_days}d idle → **close** (linked issue #99 closed)
- **PR #141 — {title}** — {age_days}d idle → **merge**
```

`N` is the active `--days` threshold (default 3). If the forgotten set is empty, print a single line — `## Forgotten PRs — none older than N days` — and skip the action paths entirely.

## Step 3: Close flow (confirmation-gated)

For every `close`-classified PR, present the PR and its rationale and **ask for explicit confirmation** before touching anything (recommend → confirm → apply, mirroring `/pm-clean`). Declining leaves the PR open.

- On confirmation: `gh pr close <N> --comment "<rationale>"`.
- **Separately** — a second, independent gate, never bundled with the close confirmation — offer to delete the PR's head branch. When confirmed, delete `<headRefName>` honoring `stale-cleanup.sh`'s branch-deletion safety rules (never a protected name — `main`/`master`/`develop`; never a branch checked out in a worktree), skipping with a one-line note if any check fails. Do **not** reimplement those safety checks — treat `stale-cleanup.sh` as their source of truth; its out-of-band sweep (via `/pm-update`) also reaps the branch later once it ages past the stale threshold.

## Step 4: Merge flow (confirmation-gated, delegated to `/wrap`)

For the `merge`-classified PRs, present them and require an explicit **"yes"** before acting on any of them. This is a **scoped exception** to the global auto-merge default in CLAUDE.md "PR MERGE AUTHORIZATION": these PRs are **triage-discovered** — enumerated by `forgotten-pr-triage.sh`, not created or monitored by PM's own A→B→C pipeline — and have not earned the standing auto-merge authorization that inline pipeline PRs carry. Issue #733's authorship caution reinforces this gate: acting on a PR whose CI and review history PM never tracked warrants an upfront consent step. This confirmation is this step's own triage design (matching the sibling close gate in Step 3), not a paraphrase of the merge-authorization rule. Declining leaves everything unmerged. The "yes" is the authorization; do not add a second per-PR merge prompt.

On confirmation, **dispatch one subagent per approved PR that executes the `/wrap #N` workflow** (the arbitrary-PR form) so the existing merge gate + AC verification + squash-merge run unchanged — **do not reimplement merge logic**. Spawn per `.claude/agents/README.md` and `subagent-orchestration.md`: `subagent_type: "phase-c-merger"`, `mode: "bypassPermissions"`, explicit `model: "sonnet"`, the verbatim SAFETY block, and the handoff path. Respect the **3–4 concurrent-pipeline ceiling** from `subagent-orchestration.md` — launch up to the cap and queue the rest, starting a queued merge as each running one finishes. This is a one-shot hand-off: once the merge subagents are dispatched, this step is done — it does not poll them (polling is monitoring, which belongs to `/pr-monitor-and-manage`).

**Sequence the approved set by file overlap before dispatching (issue #756).** Two approved PRs touching the same file merge in whichever order they finish, and the second inherits a conflict the first created. Run the planner once over the approved numbers and dispatch in its order:

```bash
SEQ=$(.claude/scripts/merge-sequence.sh --prs "$APPROVED_CSV" --skip-missing)
```

Dispatch `merge` and `batch` PRs; **hold back** anything the plan marks `hold` and say so in one line naming the shared file. A held PR is not dropped: it stays a merge candidate for the next `/pm` run or for `/pr-monitor-and-manage`, which owns the across-tick hold state. A non-zero exit other than `0`/`1` means the planner failed — log one line and dispatch in the original order rather than blocking the merges. Model: `.claude/reference/merge-sequencing.md`.

> **Never run two PRs from the same group concurrently.** The 3–4 parallel `phase-c-merger` dispatch above applies **across** groups, not within one. Members of a group share a file *by construction*, so merging two of them in parallel recreates exactly the conflict the plan just avoided — and `batch` members are always same-group. Dispatch at most one PR per `SEQ` group at a time (`plan[N].group`; `null` = no overlap, always parallel-safe), starting the next member of a group only after the previous one merges or blocks. PRs in different groups still fill the remaining slots in parallel.
