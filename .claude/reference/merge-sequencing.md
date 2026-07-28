# Overlap-Aware Merge Sequencing (issue #756)

Mechanism, state machine, and rationale behind `.claude/scripts/merge-sequence.sh`.
Not auto-loaded — the rule corpus carries none of this. The skills that consume it
(`/pr-monitor-and-manage`, `/subagent`, `/pm`) each hold only the few lines they need.

## The problem

Merge order is first-ready-first-merged, blind to file overlap. That is backwards
when one PR's diff dwarfs its siblings' in a shared file: every small PR that lands
first forces the big one into another conflict round.

The motivating incident: a keyboard fix that re-indented ~350 lines of one form
component stayed open while five sibling PRs landed in that same file. The big PR
paid for each of them — three manual conflict re-resolutions plus a fourth rebase,
and one of those re-resolutions nearly shipped a commit that had silently dropped
the entire fix. Manual conflict resolution is not just slow; each round is a fresh
chance to lose work.

`/wave` already checks file overlap when deciding what to **launch** in parallel
(its Steps 3–5). Nothing equivalent decided what to **merge**, in what order, once
the PRs were open. This closes that gap.

## Division of labour with the sibling issues

| Issue | Covers |
|-------|--------|
| #754 | The **clean** `BEHIND` case — zeroes the cost of mechanical rebase churn via `/admin-merge`. Cannot help a *conflicting* PR, which can't merge at all until someone resolves it. |
| #756 (this) | The **conflicting** case — minimizes how many conflict rounds a big PR pays while the hotspot file still exists. |
| #755 | The long-term structural fix — flags the hotspot file for splitting so the hotspot stops existing. |

#671 catalogued the rebase treadmill and listed "sequence by file overlap" as one of
four options; the fleet adopted the admin-merge path instead. This adopts the
deferred option, with the ItemForm incident as new evidence.

## The rule

PRs sharing at least one changed file form a **group** (transitive closure — A~B on
one file and B~C on another puts all three in one group). Within a group:

- The **anchor** is the member with the largest changed-line footprint summed across
  the group's shared files. It merges first.
- Every other member is a **follower**, held behind the anchor.

Footprint is measured **only in the shared files**, not overall diff size. A PR with
a 5000-line diff elsewhere and 10 lines in the contested file is not the anchor — it
isn't the one paying for conflict rounds there.

Ties break to the **lowest PR number**, so the plan is stable tick to tick rather
than dependent on iteration order.

## Hold state machine

Holds are bounded — sequencing can never deadlock the fleet. The anchor's
**signature** is `<head_sha>:<verdict>`; any real movement (new commit, verdict
change) resets the stall counter.

```
follower + anchor hard-blocked / gone / errored  -> batch  (release immediately)
follower + signature unchanged past stall_ticks  -> batch  (release; anchor is stuck)
follower + anchor ready or progressing           -> hold   (ticks++)
follower whose own verdict is not `wrap`         -> not_merge_ready (never held)
```

`stall_ticks` defaults to 1, i.e. release on the second consecutive quiet tick.
`--stall-ticks 0` disables holding entirely (every follower batches).

**Releasing as one batch is the point.** Followers that release merge in a single
window, so the anchor re-syncs **once** rather than once per follower. That is the
whole difference between the ItemForm incident's three re-resolutions and one.

**Why the stall counter also applies to a ready anchor.** A `wrap`-verdict anchor
normally merges the same tick and its group dissolves. But if `/wrap` keeps failing,
an unbounded hold would strand the followers forever — so the same counter releases
them. Every hold has an exit.

**Why a released entry keeps its tick count.** Carrying the past-threshold count
forward means a follower whose merge failed is not re-held next tick. A changed
anchor signature still resets it to 1, so a genuinely progressing anchor re-earns
its hold.

## Authorship (fail-closed)

Sequencing decides what gets **merged**, so it may only consider PRs the
authenticated user authored (`.claude/rules/safety.md`, issue #733). Each PR is
gated through `pr-authorship.sh` **before grouping**; anything not `mine` —
`not_mine`, `unknown`, `not_found` — lands in `excluded_prs[]` and can neither
become an anchor nor hold one of your PRs.

This matters more here than in most guards: a collaborator's large PR in the shared
file would otherwise become the anchor and hold *your* PRs behind a merge you have
no authority to perform. `--allow-nonauthor` opts out, and is only ever passed under
an explicit per-PR user override.

## Granularity: file-level, deliberately

Overlap is file-level, not hunk-level. Two PRs touching opposite ends of one file
usually rebase cleanly, so file-level over-sequences slightly — it holds a PR that
might not have conflicted.

That trade is intentional. The cost of an unnecessary hold is one extra tick; the
cost of a missed overlap is a manual conflict re-resolution. `clean-behind-check.sh`
already carries hunk-range helpers (`_parse_old_side_ranges`, `_ranges_intersect`)
if this proves too coarse in practice — that is the upgrade path, not a rewrite.

## State

Hold state lives at `pmm_merge_holds` in `~/.claude/session-state.json` (top-level
object; see `session-state-schema.json`), written through `session-state.sh --set`
like every other field. Shape, keyed by anchor PR:

```json
{
  "100": {
    "anchor": 100,
    "signature": "7b2cfbf...:wrap",
    "ticks": 1,
    "members": [101, 102],
    "released": false
  }
}
```

The planner emits the next tick's state as `holds` in its output — persist that
verbatim and pass it back as `--holds`. Entries for anchors that are no longer in
the fleet (merged, closed) simply stop being regenerated; there is no separate
cleanup pass to forget.

Groups themselves are **never cached** — they are recomputed every tick from live
`pulls/{N}/files`, matching PMM's "rediscover the fleet every tick" rule. Only the
stall counter persists.

## Launch side (`/subagent`)

The same overlap idea applies before any PR exists. `/subagent` Step 6.0b reuses
`/wave`'s issue-level footprint extraction (its Steps 3–4: plan file lists →
`## Related Files` → backticked paths → subject inference, mapped onto collision
surfaces including the shared `rule-corpus`) and **serializes** overlapping issues
instead of fanning them out concurrently.

Two subagents that would land in the same file produce exactly the merge-time
conflict this whole feature exists to avoid — cheaper to not create it. Serializing
at launch costs wall-clock; creating the conflict costs manual re-resolution.

## What this does NOT do

- **Never merges, rebases, or comments.** `merge-sequence.sh` prints a plan and
  exits. Every write stays with the calling skill, which still runs the full merge
  gate (`cr-merge-gate.md`) before landing anything. A `merge` action is not merge
  authorization — it only says this PR is not being held.
- **Never reorders by priority.** The only ordering input is footprint in the shared
  file. Sequencing does not promote, demote, or re-rank anything.
- **Never touches a PR you did not author** (see Authorship above).
- **Never gates a PR with no overlap.** A disjoint fleet exits 1, every PR reads
  `merge`, and dispatch is byte-for-byte what it was before this feature existed.

## Related

`.claude/scripts/merge-sequence.sh --help` (authoritative contract) ·
`.claude/scripts/tests/merge-sequence.test.sh` ·
`.claude/skills/pr-monitor-and-manage/SKILL.md` Steps 3.6 / 4 / 5d ·
`.claude/skills/subagent/SKILL.md` Step 6.0b ·
`.claude/skills/wave/SKILL.md` Steps 3–5 (the launch-time model this extends) ·
`.claude/scripts/clean-behind-check.sh` (hunk-level overlap, the upgrade path) ·
memory `feedback_rebase_race_parallel_extractions` (the folklore this replaces).
