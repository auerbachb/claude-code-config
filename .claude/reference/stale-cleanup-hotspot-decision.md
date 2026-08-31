# `stale-cleanup.sh` hotspot — diagnosis and KEEP decision

<!-- churn-hotspot: .claude/scripts/stale-cleanup.sh -->

Reference for Issue #1479 (`.claude/scripts/stale-cleanup.sh` churn hotspot).
Not auto-loaded.

- **Verdict:** KEEP — no split, no extraction
- **Decided:** 2026-08-31
- **Issue:** #1479
- **Reporter PR:** #1478 (`/wrap` churn detection); evidence appended after #1481

## The problem being read

`.claude/scripts/stale-cleanup.sh` was touched by 5 distinct merged PRs since
2026-08-15: #1386, #1414, #1433, #1467, #1481.

The file is a 1,472-line worktree/branch/registration staleness sweeper. Two
skills consume it — `/pm-update` (Step 8) and `/pm-clean` (workspace sweep) —
as the single source of truth for stale-state detection, so their results can
never diverge (Issue #618).

## Evidence recovery — local history is NOT shallow

The CodeRabbit plan for this issue rests on the premise that "the repository is
a shallow clone with a single commit, so per-PR attribution cannot be recovered
from local git history," and that only #1386 is corroborable in-repo. **That
premise is false**, and it materially changed CR's reasoning: it is the stated
reason CR fell back to a default verdict rather than reading the churn.

Measured: `git rev-list --count HEAD` = **705**; no `.git/shallow` exists.
`git log --follow -- .claude/scripts/stale-cleanup.sh` resolves every PR with
full per-commit numstat. The same false premise was recorded against the
`chip-offer-registry` adjudication; it appears to be a recurring CR failure mode
on this repo rather than a one-off.

## Churn attribution — per-PR evidence

| PR | Commit | Δ in this file | Issue | Classification |
|----|--------|----------------|-------|----------------|
| #1386 | `9d841a9` | +17 / −7 | #1363 | Bounded-exec round 1 — bound `repo-root.sh`, drop worktree enumeration |
| #1414 | `80c49bf` | **+731 / −16** | #1402 | **Feature growth** — orphaned worktree-registration pruning |
| #1433 | `199c394` | +5 / −1 | #1430 | **Mechanical sweep** — telemetry stderr-guard ordering, repo-wide |
| #1467 | `cd0d764` | **+1 / −1** | #1435 | **Mechanical sweep** — missing-`tr` diagnostic on repo-root's timeout path |
| #1481 | `c217efd` | +232 / −169 | #1404 | **Extraction already performed** — bounded-exec moved to `lib/bounded-run.sh` |

Detector snapshot (`churn-hotspots.sh --json`, scan_ref `origin/main`):

```
score 5, pr_count 5, conflict_rounds 0, conflict_prs [],
existing_hotspot_issue 1479, existing_hotspot_issue_state "open"
```

### What the attribution shows

- **One feature round.** #1414 is 96% of the added lines and introduced a whole
  new detection class (registration pruning). That is growth by new capability,
  not rework.
- **Two passenger sweeps.** #1433 (+5/−1) and #1467 (+1/−1) were repo-wide
  mechanical passes that happened to include this file — #1433 touched 17 files
  in one commit. Neither was about this script.
- **Two rounds of one concern, since resolved.** #1386 and #1481 are the same
  bounded-execution concern, and #1481 *ended* it by extracting the primitives.
- **Zero merge conflicts** across all five PRs. No PR was reverted, and no
  defect in this file's structure drove any of them.

## Decision: KEEP — no extraction, no split

### CR's conditional extract path is moot

CR's Option 2 proposed extracting `now_epoch` / `kill_child` / `run_bounded`
into a shared `.claude/scripts/lib/bounded-exec.sh` sourced by
`stale-cleanup.sh` and `repo-root.sh`.

**PR #1481 already did exactly that**, as `lib/bounded-run.sh` — 249 lines,
sourced at `stale-cleanup.sh:326`, pinned by `bounded-run.test.sh` (41 tests).
CR's supporting claim that "the existing in-script comment keeps the primitives
local" is stale: that comment was replaced in #1481 and now reads as a pointer
to the shared library. Re-inlining or re-extracting is barred.

### Why SPLIT is wrong

The two consumers call one atomic CLI with a single JSON output surface, and
Issue #618 makes non-divergence the explicit design point. Splitting by concern
(bounded-exec / registration scan / branch classification) would multiply the
files a single mechanical sweep touches — the exact churn shape #1433 and #1467
represent — while giving no caller a smaller thing to depend on.

### Why the churn does not indicate a structural problem

The rubric trigger for extraction is *one section repeatedly re-contested by
independent PRs*. Here the only section touched twice (#1386, #1481) was
re-contested by a single concern that has now been resolved by extraction. The
remaining churn is disjoint: a new feature, and two sweeps that were not about
this file. Zero conflict rounds corroborates that no two PRs fought over the
same lines.

## The one real defect found while auditing

`print_help` is `awk` over line 2 through the first blank line, so the entire
header block **is** the CLI contract. The CONFIGURATION block stated:

> `STALE_CLEANUP_NET_TIMEOUT_SECS` — … Wall-clock bound on **the one NETWORK
> call**, `git push origin --delete`.

That was false. `gh pr list` (`fetch_open_prs`) is a second network call, and it
is the **only unbounded external call in the script**.

Verified exhaustively: all six `"${GIT[@]}"` call sites and both
`git -C "$wt"` dirty probes go through `run_bounded`. The `gh` invocation does
not — and it runs on *every* invocation, before any classification, paging in a
loop, hard-exiting 4 on failure.

The header's "Where the bound stops" paragraph — which exists precisely to
enumerate unbounded edges, and says so ("stated exactly because 'every
filesystem call' would overclaim") — omitted it entirely. So a reader consulting
`--help` to find the remaining hang surface would conclude every network path
was bounded, in a script whose stated purpose is that "the sweep must never
hang" and that exists to clean up the debris from a hang incident.

**Fixed here:** the false claim is corrected and the unbounded `gh` call is
disclosed in the enumeration, pinned by drift guard T17 in
`stale-cleanup.test.sh`.

**Deliberately not fixed here:** bounding the call itself. `run_bounded` returns
its child's stdout through `$CAPTURE` and its contract forbids use inside
`$( )`; `fetch_open_prs` reads `gh`'s stdout by command substitution and pages
on it. Rewiring that means rewriting the fail-closed open-PR safety path — the
code whose silent failure would make every branch look PR-free and eligible for
deletion. That is a behavioral change to the highest-risk code in the file, and
it does not belong in a KEEP adjudication. Tracked as **Issue #1509**.

## Scope boundary — handoff reaping is NOT in this script's remit

A sibling thread flagged stale cross-repo handoff entries (`_unknown/*`,
`meeting_insights/*`, `longlove/*`, `inventory/*`) as within `stale-cleanup.sh`'s
remit. They are not, and this is recorded here so the suggestion is not
re-litigated as scope growth:

- `stale-cleanup.sh` contains **zero** occurrences of "handoff" (measured).
- Its documented remit is four classes: local worktrees, local branches, remote
  branches, and orphaned worktree *registrations*.
- Handoff lifecycle is owned by `/wrap` plus `handoff-state.sh`, per
  `handoff-files.md` — the parent deletes a handoff after `OUTCOME: merged` is
  confirmed.

Stale handoffs may well be a real problem; if so they belong to the handoff
lifecycle owner, not to a worktree/branch sweeper. Adding a fifth, unrelated
detection class here is exactly the accretion this hotspot review exists to
catch.

## What was explicitly preserved

- Every documented contract in `--help`: the four detection classes, all exit
  codes (0/1/2/3/4), every JSON key, all safety checks, the bound-degradation
  semantics, and invoking-repo scope (Issues #687/#697).
- `lib/bounded-run.sh` and its sourcing — untouched (PR #1481 owns it).
- Behavior: the change is header prose plus tests. No executable line changed.

## Expected impact

None on behavior. The `--help` contract now describes the script's real hang
surface, and the drift guard prevents the false claim from returning. The
underlying gap is tracked where it can be fixed with proper test coverage.

## Verification

| Suite | Before | After |
|-------|--------|-------|
| `stale-cleanup.test.sh` | 92/92 | **98/98** (+6: T17 guard) |
| `repo-root.test.sh` | 92/92 | 92/92 (unchanged) |
| `bounded-run.test.sh` | 41/41 | 41/41 (unchanged) |

Negative control: the T17 disclosure assertions were re-run against the pre-fix
`origin/main` copy of the script. T17a, T17b, and T17c all **fail** there
(95 passed / 3 failed), proving the guard is not vacuous.

An earlier draft of T17c asserted only that the word "unbounded" appeared in
`--help`. The negative control caught that as a **vacuous pass** — the pre-fix
header already contains "unbounded" in unrelated sentences ("stop an unbounded
hang", "the parent's own glob unbounded"). T17c now requires `gh pr list` and
"unbounded" to co-occur on one line, tying the call to the property being
disclosed.

## Related

- Issue #1509 — bound the `gh pr list` open-PR query (the follow-up this review filed)
- Issue #1404 / PR #1481 — the bounded-exec extraction into `lib/bounded-run.sh`
- Issue #1402 / PR #1414 — orphaned worktree-registration pruning (the feature round)
- Issue #1363 / PR #1386 — the hang incident that motivated the bounds
- Issue #618 — the single-source-of-truth requirement that weighs against SPLIT
- `.claude/reference/escalate-review-hotspot-decision.md` — structural precedent for a KEEP with a scoped fix
- `.claude/reference/scripts-readme-hotspot-decision.md` — baseline re-anchoring precedent
- `.claude/reference/churn-hotspots.md` — detector and baseline mechanics
