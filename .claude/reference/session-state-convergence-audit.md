# session-state.json convergence audit (issue #651)

Post-merge audit of `~/.claude/session-state.json` and the scripts that touch it,
read as one system rather than as the four diffs that produced it. Performed
2026-07-21/22 against `main`, after all four prerequisite changes had landed.

**Verdict: the composed system is coherent.** No mechanism was found solving a
problem another already solved, no dead branch, and no guard left keyed to a
field that the restructure had renamed. The defects that did surface are in the
*live file*, not the code, and they are all consequences of one thing: **scoping
was never retroactive.**

## Convergence evidence

| Issue | What it added | PR | Merged (UTC) |
|-------|---------------|-----|--------------|
| #640 | per-PR nested field-type validation | #654 | 2026-07-21T19:32:23Z |
| #647 | per-PR `root_repo` scoping in the polling gate | #653 | 2026-07-21T19:47:07Z |
| #638 | per-repo storage scoping + legacy migration | #659 | 2026-07-21T20:20:56Z |
| #639 | portable `mkdir` write lock | #662 | 2026-07-21T21:00:27Z |

A fifth change landed mid-audit and is folded in below: **#687** (`--session-view`,
PR #694, 2026-07-22).

## How the mechanisms compose

**Locking wraps the right thing.** `state_lock_acquire` is called in
`session-state.sh` *before* the state file is read, not around the `mv`, and the
lock is held through the jq pipeline, the type checks, and the rename. That is
the property that matters: the lost-update race #639 exists to close is between
the read and the write, so a lock that only covered the write would have been
decorative. `--get` deliberately does not lock, which is correct — `mv` is
atomic, so a reader sees either the whole pre-write or the whole post-write
document.

**The type contract survived the restructure.** #638 moved PR state a level
down, which could easily have made #640's nested guard a no-op: the guard
matches on a leading `.prs`, and the scoped path no longer starts that way.
`session-state.sh` avoids this by classifying on the caller's **original** path
and scoping only the concrete jq check path at the point of use. A whole-entry
write (`--set '.prs["999"]={...}'`) is covered separately by scanning every
known nested key in the written entry, and the per-repo shape itself
(`.repos` an object, each scope an object, each `prs` an object) is checked
before the move.

**#638 and #647 are not two answers to one question.** This was the specific
worry in the ticket, and it does not hold up:

- **#638 decides which scope to read** — `.repos["<owner>/<name>"].prs["<N>"]`,
  so two repos at PR #84 never share an entry.
- **#647 decides whether this checkout may poll that entry** — comparing per-PR
  `owner_repo`/`root_repo` against the active checkout's identity.

Delete either and something real breaks: without #638 the two repos collide in
storage; without #647 a session polls a PR that is registered but belongs to a
checkout it is not standing in. Both survive, deliberately.

The genuine vestige was **prose, not logic**: four comments in
`polling-state-gate.sh` still described `.root_repo` as "the single global
field… owned by whichever session wrote last". Post-#638 that is false —
`session-state.sh` rewrites a leading `.root_repo` into the active repo's own
scope, so the value read there is this repo's own recorded checkout. The
precedence that comment justified (live checkout outranks recorded path) is
still right, but for a different reason: a recorded path may name a worktree
that has since been removed. Comments corrected; behavior unchanged.

`reviewer-of.sh` carries no lock of its own, which is correct — #638 routed its
sticky write through `session-state.sh`, so it is already serialized. No vestige
of the lock plumbing that #662 briefly added and then removed survives.

## The live file

Audited with `session-state-audit.sh`, added by this issue.

**Clean:** valid single JSON object; `schema_version: 2`; no legacy top-level
`.prs`/`.root_repo`; **zero** field-type violations. The issue #625 corruption —
`.active_agents` holding the literal string
`"(.active_agents // [] | map(select(.pr_number != 71)))"` — is gone, healed to
`[]`. Three separate `/wrap` sweeps had flagged that file; the type contract now
rejects that write shape outright.

**The finding: 37 of 73 PR entries sit in `_unknown`** — more than any real repo
scope held. This is #638's migration behaving exactly as designed, not a leak:
it attributes a legacy entry by its own `owner_repo`, falling back to the repo
identity of its recorded `root_repo` when that path still resolves. Legacy
entries typically carry neither — `owner_repo` postdates them, and their
`root_repo` names a worktree long since removed — so they land in the reserved
bucket, preserved rather than dropped.

Confirmed as migration residue, not an ongoing defect: sessions writing during
the audit resolved correctly to `auerbachb/longlove` and `auerbachb/inventory`.

The consequence is easy to miss, and it is why this is worth repairing rather
than noting. Consumers disagree about `_unknown`, each defensibly:

| Consumer | `_unknown` policy |
|----------|-------------------|
| `session-state.sh --get '.prs'` | scoped only — invisible |
| `infer-pr.sh`, `pr-state.sh --infer-candidates` | merged into **every** repo's candidates |
| `session-state.sh --session-view` (#687) | scoped only — invisible |

So for those 37 entries the cross-repo collision #638 exists to prevent is still
present in candidate inference, while the same entries are hidden from
orchestration views.

A latent bug follows from this, worth recording even though it cannot fire
today. `--session-view`'s `active_agents` filter drops an agent whose `.pr` is
tracked by any scope other than the invoking one — and `_unknown` counts as
"another scope". Since `_unknown` holds PR keys that also belong to
`auerbachb/claude-code-config` (662, 661, …), an agent legitimately working PR
#662 would be filtered out of that repo's own session view. `.active_agents` is
currently `[]`, so nothing is being lost right now. Re-attribution removes the
condition rather than special-casing the filter.

## Repair tooling

`session-state-audit.sh` is the repeatable form of this pass, answering the
ticket's open question about whether the audit should recur: it should, and it
is now a `/memory-clean` sibling rather than a one-off. Detection is read-only
and the default. Repair is opt-in per category, backs the file up first
(never clobbering an earlier snapshot), holds the #639 lock across the whole
cycle, and re-checks integrity before the atomic move — refusing the write if
any untargeted entry would vanish or a new type violation would appear.

Two judgment calls are encoded deliberately:

- **Attribution is by commit SHA, never PR number.** A SHA is globally unique
  and checkable (`gh api repos/<owner>/<name>/commits/<sha>`); a PR number is
  precisely the ambiguous key that caused the original collision. Zero matches
  or two-plus matches both leave the entry in `_unknown` rather than guessing.
- **Retention alone does not authorize a delete.** Old entries carry
  `wrap_sweep.needs_decision` notes — questions a session asked that nobody
  answered. An otherwise-prunable entry holding them is withheld and its notes
  printed, prunable only via `--prune-with-notes`. This is the ticket's "check
  before deleting rather than pruning blind" made mechanical.

## Schema

`.claude/reference/session-state-schema.json` matches what the scripts read and
write. It is not merely documentation — `session-state.sh` loads `_field_types`
from it at runtime, so the contract and its description cannot drift apart. The
example document carries the `.repos` layout, `_unknown`, and per-PR nested
fields. `conflict_streak` was added by #683 concurrently with this audit and is
present.

## Test evidence

All suites run against the merged tree, green:

| Suite | Result |
|-------|--------|
| `session-state.test.sh` (#625/#640/#638) | 92 passed, 0 failed |
| `state-lock.test.sh` (#639, incl. 20-writer concurrency) | 41 passed, 0 failed |
| `session-state-migration.test.sh` (#638) | 29 passed, 0 failed |
| `infer-pr.test.sh` (#447/#448/#638) | 44 passed, 0 failed |
| `polling-state-gate.test.sh` (#647) | 20 passed, 0 failed |
| `polling-state-gate-multirepo.test.sh` (#638) | 11 passed, 0 failed |
| `escalate-review.test.sh` | 22 passed, 0 failed |
| `session-state-audit.test.sh` (#651, new) | 60 passed, 0 failed |
| `compaction-resume-polling-state-gate.test.sh`, `pr-state-infer-candidates.test.sh` | passed |

`infer-pr.sh --root-repo` runs clean — it exits 1 ("multiple candidates"), not
the exit 4 the ticket recorded. That failure was the malformed `last_cron_action`
on PRs #542/#544, which #640 fixed.

## Out of scope

Handoff files under `~/.claude/handoffs/` have the same unlocked
read-modify-write profile and the same global-namespace collision
(`pr-84-handoff.json` means two different PRs in two repos). #638 deferred the
decision; it is tracked separately as **issue #682** and deliberately not
addressed here.
