# `/pm`'s Pre-Dispatch Ownership Sweep (issue #1431)

Mechanism behind `candidate-ownership.sh` and the sweep `/pm` runs at Step 1B.5 (cold start) and Step 3.4 (refill). Not auto-loaded; `pm/SKILL.md` carries the binding behavior, this file carries the reasoning and the reader set.

## The problem

A fresh `/pm` rebuilds the board from GitHub and refills the pipeline without being asked — that is the inline-dispatch default (issue #1190), and it is what makes yesterday's follow-ups get picked up. But GitHub is not the whole board. In-flight work also lives in other conversation threads: a coding thread paused mid-issue, a PM thread that parked itself, a fleet manager waiting on its wake command, a session that died with resumable state still on disk.

The only per-item guard was the claim gate, and `issue-claim.sh` deliberately ages a claim out after `CLAIM_STALE_HOURS` — a stale claim is re-picked with a *warning*, not a block, because a dead thread must not poison an issue forever. That is the right default in isolation and the wrong one when the "dead" thread is merely parked. It is also the exact shape that shipped issue #652 twice, as PR #661 and PR #673.

Even when `/pm` did hold back, it could only say "claimed by someone" — not *which* thread, what state it stopped in, or how to wake it. And when the owning thread was gone for good, its half-done work sat until a stale claim was re-picked and redone from zero, orphaning whatever the dead thread had already pushed.

## The three-way branch

| Verdict | Owner | `/pm` does | Why |
|---|---|---|---|
| `unowned` | nobody | dispatch, exactly as today | The common case must not change, and refill must never stall — `/pm` keeps filling from the unowned candidates |
| `owned_live` | a thread that is open or paused | skip, surface one line, move on | A human parked it. Resuming the same work in two places is how duplicates get shipped, so `/pm` never un-pauses, messages, or writes another thread's state |
| `owned_dead` | a thread that is archived or absent | **adopt** — take the claim over and resume from surviving state | Pointing at a thread that no longer exists helps nobody, and redoing the work from zero orphans what the dead thread already pushed |

This generalizes the old hand-maintained carve-out. The paused PR fleet is no longer a special case in the dispatch path — it is one instance of the rule whose `resume_route` happens to be `/pr-monitor-and-manage-wake` instead of `/go-on`.

## Reader set — shared, never a parallel store

The sweep adds **no new registry**. It reads the same sources `/wave` Step 2 and the chip-offer census already read, with the same attribution rules:

| Source | Read | Contributes |
|---|---|---|
| `issue-claim.sh <N> --check --json` | per candidate | `verdict`, `claimant`, `claimant_holder`, `claimed_at`, `stale` |
| `gh issue list --label in-progress` | once, batched | the cheap claim index (`/wave`'s batching pattern) |
| `active-work-cap.sh --json` | once | `offered_issue_nums` — a first-pass "already spoken for" signal |
| `gh pr list --state open` | once | open PRs and their closing refs, joining issue → PR → branch |
| `session-state.sh --get .repos[<key>].pause` | once | parked units, their stopping point, the marker path |
| `session-state.sh --get .repos[<key>].background_tasks` | once | per-task owner, session id, status, recovery path |
| `session-state.sh --get .repos[<key>].execution_pauses` | once | session-scoped launch gates — what makes an owner *paused* rather than dead |
| `session-state.sh --get .pmm_active` / `.pmm` | once | the paused PR fleet and the PRs it held |
| `~/.claude/handoffs/{owner}/{repo}/pr-{N}-handoff.json` | per linked PR | the phase the dead thread reached — the adoption entry point |
| `~/.claude/handoffs/pause-*.md`, `suspend-*.md`, `portable-handoff-*.md` | once, globbed (`*-checkpoint.md` excluded) | resume markers naming the issue, and the session id in the filename |
| `git for-each-ref` | per candidate, on demand | a surviving `issue-N-*` branch — the adoption source of last resort |

`.pause`, `.day`, `.resume`, and `.execution_pauses` are **invisible to `session-state.sh --session-view`** (that projection lifts only `.prs` and `.root_repo`), so each is fetched by explicit `--get`. A sweep built on `--session-view` would report every armed pause as absent.

Each of those also has to be addressed at its **repo-scoped** path. `session-state.sh` transparently rewrites only a leading `.prs` or `.root_repo` into the active repo's scope; everything else is read literally. `execution-pause.sh` writes solely to `.repos[<key>].execution_pauses[<session>]`, so a top-level `.execution_pauses` read matches nothing and every `/end` and `/pause` launch gate is invisible to the sweep — the same trap the `.pause` / `.background_tasks` rows above avoid, and one a passing test suite will not catch unless a negative control pins the top-level shape as *not* the contract.

## The owned-resumable upgrade

`issue-claim.sh` is not modified. The upgrade is an **external rule layered on top of its verdict**, applied by `candidate-ownership.sh`:

- `stale` **plus** resumable evidence (a parked entry, a background-task entry, an active execution pause, a marker file, a linked open PR, a handoff file, or a surviving branch) → **owned**, `state: stale`, skipped or adopted per liveness.
- `stale` with **no** evidence behind it → **unowned**. Today's warn-and-proceed survives byte for byte, which is the point: the stale window exists so a genuinely dead thread cannot park an issue forever.

Keeping this outside `issue-claim.sh` matters. That script's contract is "who holds the claim, and is it fresh" — one question, answered from GitHub alone. Teaching it about local markers and handoff files would make every one of its callers depend on local disk state to answer a question about a shared, remote claim.

## Adoption needs a startable claim

Adoption takes the claim over through the **existing** stale-takeover path — `issue-claim.sh <N> --claim`, which re-stamps a stale claim for the new holder. That path refuses a *fresh* foreign claim without `--allow-claimed`, and `--allow-claimed` is only ever an explicit per-issue instruction from the user in chat.

Adoption is therefore available only where that path would succeed — a claim verdict `issue-claim.sh` already reports startable (`stale`, `unclaimed`, `mine`). Every other verdict is `skip` **even when the owner's session is archived**:

| Claim verdict | Dead owner ⇒ | Why |
|---|---|---|
| `stale` / `unclaimed` / `mine` | `adopt` | The takeover path succeeds |
| `claimed` | `skip` | A fresh foreign claim needs `--allow-claimed`, and it ages out on its own |
| `unknown` | `skip` | Fail-closed runs in both directions: a claim we could not read is never permission to take it over |
| `unavailable` | `skip` | With no working claim gate, surfacing beats taking over a claim nobody can read |

The sweep still reports `verdict: owned_dead` in every one of those rows — the reading is accurate — and the `reason` names what is blocking the takeover rather than pretending the claim was not there.

Where adoption does fire, it picks the cheapest resume point rather than always respawning Phase A:

| Surviving state | `adopt.from` | `adopt.phase` |
|---|---|---|
| open PR + handoff with `phase_completed: A` | `pr` | `b` |
| open PR + handoff with `phase_completed: B` or `C` | `pr` | `c` |
| open PR, no handoff | `pr` | `b` — the PR is already in review; enrolling it in the normal flow beats rebuilding it |
| branch or worktree only | `branch` | `a` |
| nothing survived | `null` | `null` — adoption reduces to a fresh dispatch |

## Liveness fails toward surfacing

No CLI enumerates Claude sessions, so liveness is resolved against a **session listing the caller supplies** (`--sessions <path>`, or `CLAUDE_SESSION_LISTING`). The script normalizes the common shapes: a bare array or an object with `sessions` / `data` / `results`, whose entries name their id as `id` / `session_id` / `sessionId` / `uuid`, their state as `status` / `state`, and their title as `title` / `name` / `summary`.

| Listed status | Classified |
|---|---|
| `open`, `active`, `running`, `paused`, `idle`, `live`, `suspended`, `waiting` | **live** |
| `archived`, `deleted`, `closed`, `ended`, `dead`, `terminated`, `gone`, `expired` | **dead** |
| absent from a listing that was read | **dead** |
| unrecognized status word | **live** — an unknown word is not evidence of death |
| no listing supplied, unparseable listing, or no resolvable owner session id | **indeterminate → treated as live** |

The asymmetry is deliberate. Surfacing a thread that turned out to be dead costs one line the user can ignore; adopting work a live thread is still doing costs a duplicate implementation. Headless runs, where no listing tool exists, therefore land on surface-only by construction.

## Owner naming

Two tiers, and the human-readable one wins however late it is found: session-listing `title` > a title a source supplies (`background_tasks[].name`, the marker filename) > the claim-derived description (`<login> thread <holder>`) > the bare session id > `an unnamed thread`. Claims and state files carry session ids as the join key, so ids are the documented fallback, not a failure.

`pause-*.md` marker filenames encode the session id between the repo fields and `mktemp`'s uniqueness tag (`pause-<stamp>-<len-owner>-<owner>-<len-repo>-<repo>-<session>-<tag>.md`), which is how a marker attributes itself with no state file involved.

**Recover it by walking the length prefixes, never by splitting on dashes.** Session ids are UUIDs and keep their own dashes, so "the field before the tag" yields only the UUID's last group. A truncated id is absent from the session listing, absence reads as `dead`, and `dead` is the one classification that adopts — so the parse bug resumed a *live* paused thread underneath, the exact duplicate-ship failure the sweep exists to prevent. The same walk recovers the repo, which is why both come from one parser.

### A holder token is not a session id

`issue-claim.sh` reports `claimant_holder`, and `resolve_holder`'s documented last resort is `<hostname>:<worktree path>` — a token that can never appear in a session listing. Feeding it to the liveness lookup returns "absent", which again reads as `dead` and adopts. Absence is evidence of death only for something that could have been present, so a token carrying `:` or `/` is treated as holder-shaped: liveness `indeterminate`, owner treated as live, and the reason recorded in `degraded[]`.

### Markers must be attributed to this repo first

`~/.claude/handoffs/` is shared across every repository, and a marker is matched on issue or PR **text** — `#1431` exists in all of them. So a marker earns its say only once it is attributed to the repo under sweep, from either of two independent sources: the rendered ``Repository: `owner/repo` `` line (exact, and present in every marker shape — `portable-handoff-*` encodes no repo in its filename at all), or the length-prefixed `<len-owner>-<owner>-<len-repo>-<repo>` filename fields, an encoding that is injective precisely so owners and repos containing `-` survive it.

Three outcomes, and the middle one is the whole point:

- **Matches** the swept repo → full evidence, including its session id.
- **Names a different repo** → not evidence at all; the marker is skipped. Without this the sweep both skipped unrelated backlog work *and* — with the foreign session archived — carried the candidate into `owned_dead`, adopting another repository's parked work.
- **Unattributable** (a `/`-less repo key writes the literal `unknown`, and no `Repository:` line) → the candidate is still surfaced, because it may be ours and surfacing is the safe direction. But its session id is withheld from the liveness lookup, where "absent from the listing" means dead — so an unattributable marker can never become an adoption. The ambiguity is named in `degraded[]` rather than passed off as certainty.

## State precedence

`paused` > `active` > `stale`. Explicit parked state outranks an inference of activity — the same precedence `/go-on` uses (`universal-resume.md`). A fresh claim only proves the claim is recent, which is exactly what a thread parked twenty minutes ago also looks like, while a `/pause` record is a deliberate statement that the thread stopped. Reporting that thread as `active` would send the user hunting for work that is not running.

## Degradation contract

Every missing, unreadable, or unparseable source is appended by name to that candidate's `degraded[]`, and the sweep continues:

- A batch-level failure (a `gh` list, a state read) is recorded on **every** candidate — it was not read for any of them.
- A read failure **never** marks a candidate owned by itself. The failure this contract exists to prevent is a sweep that swallows a whole backlog because one file was corrupt.
- A degraded candidate falls back to **claim-gate-only** behavior at the caller: exactly what `/pm` did before this feature existed.
- The one fail-closed input is the claim gate's own `unknown` verdict, which keeps its own meaning — skip, per `.claude/rules/issue-planning.md` step 0. "We failed to look" is never permission.

## Read-only guarantee

`candidate-ownership.sh` never calls `--claim`, `--release`, or any `session-state.sh --set`. It has no write path at all; the only writes in the whole feature are on `/pm`'s adoption branch, and those go through the existing claim takeover and normal dispatch bookkeeping. `.claude/scripts/tests/candidate-ownership.test.sh` pins this by logging every helper invocation the sweep makes and asserting both that helpers were called and that no write flag appears among them.

## Exit status

`0` whenever the sweep ran — every candidate carries a verdict — and `2` for usage errors or a missing `jq`. There is deliberately **no** "something was owned" exit code: a sweep over N candidates has N answers, and collapsing them into one status is how a caller ends up blocking a dispatchable backlog because one item was owned.

## Relationship to neighbouring issues

- **#1190** — the inline-dispatch default this guards. The sweep narrows what gets dispatched; it never turns the default off.
- **#1397** — `/go-on` stays the universal resume front door a person runs. The live-owner branch points at it; the dead-owner branch applies its crash-recovery semantics proactively, at dispatch time.
- **#1428** — day mode's pre-emptive park writes exactly the parked state this sweep recognizes.
- **#873** — the claim gate, which still outranks the sweep in both directions: `claimed`/`unknown` blocks regardless of ownership evidence, and only its startable verdicts permit an adoption takeover.
