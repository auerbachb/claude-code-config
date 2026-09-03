# Universal Resume — Stoppage Classification for `/go-on`

Mechanism and rationale behind `/go-on` Step 0 (Issue #1397). The enforceable
contract lives at the call site (`.claude/skills/go-on/SKILL.md` Step 0); this
file holds the evidence map, the precedence rationale, and the degradation rules
that would otherwise bloat the skill.

Not auto-loaded.

## The problem it removes

Before this, getting work moving again depended on remembering *how* it stopped:
`/pause` wanted `/pause-resume`, `/end` wanted `/end-resume`, a dead session or a
stalled review loop wanted `/go-on`. The intent is identical every time — pick
the work back up — but the command was keyed to the stoppage, not the intent.
Reaching for the wrong one either did nothing or missed parked state.

Every planned stop already writes machine-readable notes about what it parked,
and unplanned stops leave their own trail. `/go-on` reads all of them. The
specialized commands are unchanged and still do the restores; `/go-on` is the
front door that routes into them.

## Evidence map

| Probe | Class | Source | Written by |
|---|---|---|---|
| A | `pause` / `end` | `.repos[k].execution_pauses[*]` with `active: true`, `cleared_at: null` — carries `command` and `at` | `execution-pause.sh --activate` (`/end` Step 1, `/pause` Step 1) |
| B | `pause` | **any** un-resumed record in the union of `.repos[k].pauses[*]` and the legacy singletons `.pause` / `.suspend`; fallback `~/.claude/handoffs/pause-*.md` / `suspend-*.md` | `/pause` Step 7 |
| C | `end` | `~/.claude/handoffs/portable-handoff-<owner>-<repo>-*.md`, excluding `*-checkpoint.md` | `portable-handoff-publish.sh` (`/end` Step 6) |
| D | `token_exhaustion` | `.repos[k].prs[*].handoff_reason == "token_exhaustion"` | Token/turn exhaustion protocol (`subagent-orchestration.md`) |
| E | `unplanned` | Live registry entries, `.repos[k].prs`, scoped handoff files, `*-checkpoint.md`, in-progress rebase, dirty/unpushed feature branch, open PR | Ordinary work, plus `checkpoint-handoff.sh` |

**Probe B reads a set, not a slot (issue #1576).** Pause records are keyed per
session, so a repo routinely holds several. Probe B is `present` when *any*
record in the union is un-resumed, and `record_at` is the newest such record's
`paused_at`. A sibling record with `active: false` says only that that session's
board was restored — reading one slot and stopping is what let a later `/pause`
hide an earlier one, and a resumed sibling then suppress the survivor. The
legacy singletons are members of the same union, never an else-branch that fires
only when the map is empty.

**`refill.paused` never discriminates.** Both `/end` and `/pause` write
`{paused: true, reason: "full_stop"}`, so it corroborates that *a* planned stop
happened and nothing more.

**A checkpoint note is not an `/end` note.** `checkpoint-handoff.sh` writes
`*-checkpoint.md` while work is still running; it stops nothing and decides
nothing (`portable-handoff.md` §"Two producers, two lifecycles"). Treating one
as an `/end` record would report a planned stop that never happened, so probe C
excludes the suffix and probe E includes it as ordinary in-flight evidence.

## Precedence, and why this order

1. **`pause` / `end`** — a planned stop armed the session execution gate, and
   only `/pause-resume` / `/end-resume` may clear it (`phase-protocols.md`
   §"Launch gate before every successor"). Any other lane would run with launches
   blocked and fail closed at the first successor.
2. **`token_exhaustion`** — an explicit, recorded stopping point with a phase and
   remaining work. It ranks below a planned stop for the gate reason above: a
   phase continued under an armed gate cannot launch anything.
3. **`unplanned`** — inferred from in-flight state rather than recorded by a stop.
4. **`none`** — every probe readable, nothing found.

**Explicit parked state outranks generic stall detection** because the two
routinely coexist: a `/pause` parks a PR that still looks perfectly in-flight to
probe E. Ranking E last means the parked board — which knows what was landed,
what was stopped, and what is waiting on a reviewer — is always preferred over
re-deriving a guess from the branch.

### `pause` vs `end` — newest wins, decided by probe A

An `/end` after a `/pause` (or the reverse) leaves both records. Probe A settles
it: every activation stamps `command` and `at` in the same UTC `Z` format under
one repo-scoped map, so the newest active entry names the class. String
comparison is valid **only** because every writer stamps `Z`; a non-`Z` stamp
sorts wrong against `Z` (`-` sorts before `Z`), so the probe validates every
active record's `command` and `at` *before* sorting and treats a failure as
unorderable evidence — reported, never ordered.

That is why probe A is tri-state — `present` | `absent` | `unreadable` — rather
than a map that defaults to empty. Collapsing a failed read, a malformed map, or
an invalid active record into `{}` reads as "no planned stop", drops the ladder
to rank 2 or 3, and starts a `token_exhaustion` or `unplanned` resume while a
gate may be armed: every successor launch then fails closed and the parked board
goes unread. Only `session-state.sh` exit 3 — no state file at all — is an
unambiguous `absent`; exits 4 and 5, an unresolved helper, and an unknown repo
key are all `unreadable`, and `unreadable` bars ranks 2, 3, and 4 outright.
Rank 2 is barred on the same evidence as the other two: a token-exhaustion
handoff says a phase ran out of budget, never that no planned stop is armed, and
continuing that phase is a resume like any other.

Probes B and C cannot break the tie. B's timestamp is an ISO string in state and
C's is a file mtime; they are not comparable, and no portable single command
reads a file mtime across BSD and GNU (`date -r` means different things on each,
and `stat -f %m` is a filename argument to GNU `stat`). So when A is missing or
unreadable and both B and C are present, the verdict is **unclassifiable** and
the user picks — a coin flip between two restores is exactly the guessed action
this design forbids.

## Refill and the launch gate

`/go-on` never writes `refill.paused`. `--resume-refill` is forwarded verbatim to
the delegated command, which performs the clear inside its own contract
(`/pause-resume` Step 6, `/end-resume` Step 1). Consequences:

- Without the flag, refill stays paused after a universal resume, exactly as it
  does after the dedicated commands. Universal resume never silently re-enables
  autonomous refill.
- On the `token_exhaustion` and `unplanned` lanes the flag has no delegate, so it
  has no effect and is reported as such, naming the command that clears it.
  Clearing a refill pause `/go-on` did not find the origin of would be the same
  silent re-enable in a different disguise.

## Idempotency — the resume receipt

`.repos[k].resumes[<session-id>]` records **that session's** last dispatch:
`{class, evidence_digest, at, session_id, dispatched_to}`. The digest is
`class|record_at|pr|head_sha|branch`, where a pause-class `record_at` is the
newest **un-resumed** record's `paused_at`.

**Keyed per session, for the same reason the pause records are (issue #1576).**
As a repo singleton, `.repos[k].resume` held only whichever session dispatched
last. A sibling's receipt could then match another session's digest and produce
an "already resumed" verdict while that session's own board was still parked —
the receipt masking exactly the work it was meant to avoid duplicating. A
session now reads only its own key. The legacy singleton `.resume` stays
readable, but only when its `session_id` matches the reading session or is
absent; an unconditional legacy read would be the same mask in a different slot.

Because `record_at` names the newest **un-resumed** record, a genuinely restored
board drops out of the union and changes the digest, while a still-parked one
keeps producing evidence. The verdict rests on the records; the receipt only
suppresses a repeat of the same evidence by the same session.

A second `/go-on` with an unchanged digest reports `nothing to resume`, naming
when and how the stoppage was already resumed, and writes nothing. Anything that
actually moves — a push, a new PR, a new stoppage record — changes the digest and
the next run resumes normally; `--again` forces a pass when the digest is
unchanged but a fresh poll is wanted.

The receipt is a backstop, not the only guard. The underlying records are
self-clearing: `/pause-resume` Step 7 sets that record's `active=false`, both resume
commands clear the execution gate, and the registry moves entries
`stopped -> rearming -> rearmed` under a lock. The receipt covers the lanes those
records do not close — most importantly `unplanned`, where nothing marks the
resume as done.

**Rank 4 writes nothing.** "Nothing to resume" is a read-only verdict; a state
write there would make a no-op look like an event.

## Duplicate suppression

Resuming must never produce a second live identity for work already running.
Before any lane, `/go-on` lists live registry entries
(`background-task-registry.sh --list --live`) and reads `.prs["<N>"].babysit.active`.
Covered work is reported, not relaunched. The delegated commands then take the
atomic `stopped -> rearming` claim (exit 7 = another invocation already claimed
it), which is what makes concurrent resumes single-writer.

## Monitors and watches: owned elsewhere, deliberately

`/go-on` does not re-arm Monitors or artifact watches that died with a session.
They belong to their owning skills' recovery paths — `/babysit-pr`,
`/pr-monitor-and-manage-wake`, `/pm day resume`, and `monitor-mode.md` §PM
Monitoring Recovery — which is where `/pause-resume` Step 5 already delegates.
A second arming path would be a second contract for generation tracking and
duplicate suppression, and the divergence risk is the one that produces two live
Monitors on the same PR. `/go-on` names what it found and which command owns it.

## Degradation — "could not look" is never "nothing there"

Every probe distinguishes *absent* from *unreadable*, the same rule `/pause` and
`/end` apply to their inventories. An unresolved helper prints the `DEGRADED:`
line from `portable-skill-resolution.md` and marks its class *unknown*. A verdict
of `none` requires that **every** probe was readable and empty; otherwise the
verdict is `unclassifiable`, which reports what was found and offers the
resolution paths as a menu (`ask-menu.md`).

Unclassifiable cases, all report-only:

| Case | Why it cannot be resolved automatically |
|---|---|
| Probe A `unreadable` | A planned stop may be armed; ranks 2, 3, and 4 are all barred |
| An active gate record with an unknown `command` or non-`Z` `at` | Unorderable and unclassifiable; sorting it would invent an answer |
| B and C both present, A absent/unreadable | Two planned stops, no comparable timestamps |
| This session's gate `active`, no class readable | Launches are blocked and nothing says which command closes them |
| A probe could not be read | Its class cannot be ruled out |
| A union record is `active: true` but `/pause-resume` finds no state or marker | The record and its restore path disagree; name the record's session key |
| A marker `/pause` published as not auto-discoverable (`_unknown` repo key) | Only the explicit `/pause-resume --marker <path>` form can select it; `/go-on` takes no `--marker` |
| Several token-exhaustion entries, none matching this branch's PR | No basis to pick one; name them all |

## Relationship to the dedicated commands

| Command | Still does | Now also |
|---|---|---|
| `/pause-resume` | Owns the parked-board restore, marker fallback, re-arm delegation, refill decision | Reachable as `/go-on` rank 1 |
| `/end-resume` | Owns the gate clear, registry inventory, recoverable-entry resume | Reachable as `/go-on` rank 1 |
| `/pause`, `/end` | Write their records exactly as before | Point at `/go-on` as the primary resume entry point |

Nothing about the stop side changed: planned stops keep writing their notes, and
`/go-on` learned to read them. The dedicated resume commands are kept
indefinitely — they are the executors, not aliases to be deprecated, and a
direct invocation stays the right move when you *do* know how the work stopped.
