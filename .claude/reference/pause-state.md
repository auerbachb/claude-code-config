# Pause State — Shape, Triage Rule, and Deadline Semantics

Reference for the `.repos["<owner>/<name>"].pauses` map in `session-state.json`. Written by `/pause` Step 7b and read by `/pause-resume` Step 1.

## Why this is in `.claude/reference/` and not a rule file

The `/pause` SKILL.md and `/pause-resume` SKILL.md carry the authoritative contracts. This file holds the mechanism, rationale, and the state-shape prose that would push the corpus past its word-count budget if it lived in an auto-loaded rule. Rules load every turn; this file loads on demand.

## State shape

`.repos[<repo-key>].pauses[<session-id>]`, beside `refill` and `day`. The map is
repo-scoped; each **record** inside it belongs to one session. Keys are Claude
session IDs sanitized with `[^[:alnum:]_.-] -> _` — the same rule `/pause`
Step 7a applies to the marker filename, so the marker and the record name each
other.

```json
{
  "active": true,
  "session_id": "60aba151-c372-47f9-813b-7af00c2034db",
  "paused_at": "2026-08-22T22:10:00Z",
  "window_minutes": 10,
  "window_expired": false,
  "landed": [
    {"pr": 1250, "issue": 1249, "at": "2026-08-22T22:14:00Z"}
  ],
  "parked": [
    {
      "kind": "pr",
      "ref": 1251,
      "branch": "issue-1251-some-feature",
      "head_sha": "abc1234",
      "stopped_at": "fixes committed and pushed; awaiting CodeRabbit review",
      "next_move": "poll for CodeRabbit review and process findings",
      "waiting_on": "reviewer",
      "boundary": "pushed"
    },
    {
      "kind": "subagent",
      "ref": null,
      "branch": "issue-1252-another-feature",
      "head_sha": null,
      "stopped_at": "Phase A in flight at pause time",
      "next_move": "read handoff file and launch Phase B",
      "waiting_on": null,
      "boundary": "subagent — not interrupted",
      "handoff_path": "~/.claude/handoffs/auerbachb/claude-code-config/pr-1252-handoff.json"
    }
  ],
  "monitors_stopped": [
    {"owner": "babysit", "ref": 1251, "task_id": "abc123", "generation": "20260822T221000Z-12345-6789", "stopped": true},
    {"owner": "pmm", "ref": null, "task_id": "def456", "generation": "20260822T200000Z-12345-9876", "stopped": true},
    {"owner": "day", "ref": null, "task_id": "ghi789", "generation": "20260822T200000Z-12345-4321", "stopped": false}
  ],
  "refill_paused": true,
  "marker_path": "~/.claude/handoffs/pause-20260822T221000Z-9-auerbachb-18-claude-code-config-<session>-<unique>.md",
  "resumed_at": null
}
```

**Visibility:** Like `refill` and `day`, this map is **invisible to `session-state.sh --session-view`** (that projection lifts only `.prs` and `.root_repo` out of the repo block). Read it with an explicit `--get .repos["<key>"].pauses`. A caller who uses `--session-view` will see the pause state as absent even when one is armed.

### One record per session, not one block per repo (issue #1576)

Until #1576 this was a repo **singleton** at `.repos[<key>].pause`, and a second
`/pause` replaced the first outright. That is not a rare case: two sessions
pausing the same repo 80 seconds apart is ordinary, and it happened — the later
write replaced the earlier session's board, which then survived only as its
marker file.

The loss was silent by construction. `/pause-resume` read the singleton slot
*successfully*, so the marker-glob fallback never fired, and Step 2 acted on
whatever the slot held: if the surviving record was already resumed, `active:
false` produced an "already resumed" no-op and the earlier board was never
restored; if it was not, the first `/pause-resume` restored the *later* board
and marked the slot resumed, masking the earlier one just the same. Stopped
Monitors stayed unarmed and parked units stayed unlaunched, with no error
anywhere.

Keying by session ID — the shape `execution_pauses` already uses — removes the
overwrite at the source:

- **A second `/pause` in another session creates a distinct record.** Neither
  board is lost, and running `/pause` again is no longer something to avoid
  while another session is parked.
- **`/pause-resume` enumerates every un-resumed record**, newest first by
  `paused_at`, and restores each independently against its own state path. One
  record's verdict — resumed, skipped, or failed — ends that record only.
- **A sibling's `active: false` is never proof that nothing else is parked.**
  That inference is the bug; the enumeration is what replaces it.
- **Resume receipts are keyed the same way** (`.repos[<key>].resumes[<session>]`,
  `universal-resume.md`), so one session's receipt cannot suppress another's
  dispatch.

### Legacy state compatibility

Two legacy singleton slots survive as **read-only**: `.repos[<repo-key>].pause`
(the pre-#1576 shape) and `.repos[<repo-key>].suspend` (pre-#1310, which also
used `suspended_at` and published `suspend-*.md` markers). `/pause` writes
neither; it writes only `.pauses[<session-id>]` and `pause-*.md` marker names.

**The legacy slots are union members, not a fallback branch.** `/pause-resume`
Step 1 reads `.pauses`, `.pause`, and `.suspend` and selects the un-resumed
records from all three together. Reading the legacy slots *only when the map is
empty* would look like a reasonable fallback and would reproduce this exact bug
one level up: a session parked before the upgrade would become unreachable the
moment any session wrote a keyed record. Each selected record carries its own
`state_path`, so a legacy restore updates and closes the legacy block in place;
it does not create a partially migrated second record.
The resume display normalizes legacy `suspended_at` to the current `paused_at`
label so old records remain intelligible as well as recoverable.
When marker fallback selects a legacy `suspend-*.md` file, it also selects the
legacy state key before any completion write.

### Per-source degradation (issue #1611)

The three sources — `.pauses`, legacy `.pause`, legacy `.suspend` — are **each
validated on its own before the combine**, never validated as one combined read.
One shared jq rule does the classifying, carried verbatim in all three readers
(`/pause-resume` Step 1, `/go-on` probe B, `candidate-ownership.sh`):

```jq
def slot_class($kind):
  if type == "null" then "absent"
  elif $kind == "map"
    then (if type == "object" and (to_entries | all(.value | type == "object"))
          then "present" else "unreadable" end)
  elif type == "object" then "present"
  else "unreadable" end;
def slot_degraded($name; $kind):
  if slot_class($kind) == "unreadable" then [$name] else [] end;
```

`$kind` is `"map"` for the session-keyed map and `"slot"` for the legacy
singletons: only the *shape* differs, never the *rule*. A corrupt map is
therefore named exactly the way a corrupt singleton is — the earlier asymmetry,
where a bad map took a quiet `else []` branch while a bad singleton raised, is
gone.

**A damaged slot is named individually and drops out alone; every surviving slot
still contributes.** Each combine returns `{records, degraded}` (plus `total` in
`/pause-resume`), and the caller reports each name in its own idiom — a
`DEGRADED:` line plus `STATE_UNREADABLE` in `/pause-resume`, `batch_degrade` in
the ownership sweep, `PAUSE_SLOTS_UNREADABLE` in `/go-on` probe B. **No reader
raises out of the combine.** Raising aborts the whole program, which is how one
damaged pre-upgrade singleton used to discard every healthy keyed record read
beside it: `/pause-resume` emptied `PAUSE_RECORDS`, and the ownership sweep drew
no parked-unit evidence at all, so a candidate owned by a perfectly readable
keyed record could still be dispatched.

**Only the literal `null` is absent — an empty read is damaged.** The classifier
sees a slot's *value*, but every reader gets that value through
`session-state.sh --get`, which prints **nothing** (rc=0, empty stdout) for a slot
holding the JSON string `""`. Each reader used to fold that empty read back into
`null` before the classifier ran — `${VAR:-null}` in `/go-on`, `[[ -z "$v" ]]` in
the sweep's `pause_slot_arg`, `[[ -n "$1" ]]` in `/pause-resume`'s
`_json_or_null`, plus a `if . == "" then null` special case inside `/go-on`'s
`parse`. A slot holding `""` is neither a map of records nor a record, so
reporting it absent is the same "corrupt board read as nothing parked" masking
this contract exists to prevent. The empty read now survives to the classifier as
a JSON string and lands on `unreadable`. The readers therefore reserve the
literal `null` for the two cases that really are absent-or-already-named: a `--get`
on a missing path (which prints `null`), and `rc=3` (no state file has ever been
written). A read that failed some *other* way is handed `null` too, because its
caller has already named that slot — passing the empty read on instead would name
the same slot a second time.

Probe B is the one reader whose *verdict* is tri-state rather than a record list,
so it takes the boundary explicitly: a surviving slot's un-resumed record is
`present` evidence no matter what its damaged sibling holds, and probe B falls to
`unreadable` only when a damaged slot is all there is.

**Why the rule is inlined three times rather than sourced from `.claude/scripts/lib/`.**
Two of the three readers are SKILL.md prose, and their helper resolution
(`resolve_script`) deliberately covers only `$HOME/.claude/skills-worktree/.claude/scripts/`
and `$HOME/.claude/scripts/` — never the current checkout, since a resume command
may run from an unrelated repository. A jq module would add a new
unresolvable-dependency failure mode to exactly the readers whose contract is
"never degrade silently", and jq's module system needs `-L` plumbing the inline
`jq -n --argjson … '<program>'` call shape does not carry. Drift is prevented
instead by extraction: `pause-multisession.test.sh` lifts `slot_class` out of all
three sources, asserts the texts agree, and runs all three against one fixture
matrix — the same anti-drift mechanism already pinning the un-resumed predicate.

## Triage rule rationale

The rule is deliberately conservative, as the issue's Notes prescribe:

```
land  ←  merge-gate.sh exits 0 (gate MET on current HEAD)
      ←  OR the ONLY outstanding blocker is unchecked Test Plan boxes
          that verify mechanically against code already pushed on current HEAD

park  ←  everything else
```

**Why conservative:** Estimating "can this merge in ten minutes" cannot be done from a formula — bot review latency alone swamps any estimate. A PR awaiting a fresh CodeRabbit round is not ten-minute work: re-triggering and waiting is the case that should park. A PR that would have landed costs one pickup at resume; a PR merged on an optimistic estimate costs a revert and a rebase.

**Why "gate met OR mechanical AC boxes":** The gate produces a binary answer on the current state. The mechanical-AC extension covers the narrow case where the gate itself is met (reviewer approved, CI green, no unresolved threads) but a Test Plan checkbox has not yet been ticked — something the verifier can do before dispatching `/wrap`. This extension is the exact shape of the Step 2 AC verification in `cr-merge-gate.md`.

**Why subagents are never `land`:** A subagent is a running process, not a PR. It cannot be driven to a merge from outside; it reaches its own stopping point and writes its own handoff.

## Deadline semantics

`T_end = T_start + window_minutes * 60` is computed once in `/pause` Step 0 and is not re-evaluated. It is a budget on how long `/pause` waits, not a promise to the user that work will finish.

**The window is a ceiling on the whole run** (issue #1482), not only on the land phase. Before that change the deadline disciplined landing and the background-task hard-stop, while park bookkeeping, marker writing, and state persistence carried no deadline awareness at all — a plain `/pause` was observed still writing its marker 22 minutes into a 15-minute window. Every step that runs after `T_end` is computed now either calls the `past_deadline` check before each unit of work or is one of the named bounded moves.

**The fixed grace bound is three minutes.** `GRACE_SECONDS=180` and `T_grace_end = T_end + 180` are set in Step 0 beside `T_end`. Only the four terminal moves may run inside it — hard-stop leftover tasks, write the marker, persist pause state, print the report — plus Step 1's two gate writes, which run unconditionally wherever they are reached because an open launch gate is worse than an overrun. Three minutes covers one slow `TaskStop` or state-lock retry plus two file writes and a report; it is deliberately not a placeholder.

**`WINDOW_EXPIRED` is explicitly initialized.** Step 0 sets it `false`; the first `past_deadline` call that finds the deadline passed latches it `true`, and it never unlatches. It was previously read by the Step 7b `jq -n --argjson window_expired` build without ever being assigned anywhere — a latent bug that would fail the build on an empty string. Landing, park mutation, and marker verbosity all key off the same latched flag.

**The window never relaxes a gate.** A PR that cannot pass the merge gate honestly inside the window is reclassified `park`. The classifier reads the actual gate; it does not approximate it.

**A `/wrap` in flight at expiry is not killed.** Killing mid-merge produces exactly the unrecorded state this command exists to prevent. `/pause` stops *waiting*, reclassifies the unit `park`, and records the in-flight state. `/pause-resume` re-reads GitHub before printing, so a merge that completed after the window shows up as landed at resume.

**`window_expired: true`** is set in the pause block when the run passed its deadline — in any phase, not only during landing (widened in issue #1482, when the flag became the whole run's ceiling latch rather than a landing-only signal). It tells resume to re-read GitHub rather than trusting the `landed` array as complete.

The widening is deliberately conservative in one direction: a run whose landing finished cleanly but whose park bookkeeping crossed `T_end` also sets the flag, so resume may re-read GitHub for a `landed` array that was in fact complete. That costs one redundant read. The opposite error — a landing cut short but reported as final — costs a lost merge, and `/pause-resume` re-reads GitHub before printing regardless. One latched flag with a conservative bias beats two flags that can disagree.

## Marker file format

The human-readable marker at `~/.claude/handoffs/pause-<stamp>-<encoded-repo-key>-<session>-<unique>.md` mirrors the state block in readable form and serves as the fallback index for `/pause-resume`. The repo key uses an injective length-prefixed encoding, `<owner-length>-<owner>-<repo-length>-<repo>`, rather than lossy slash replacement. The first marker field is also `Repository: \`<exact owner/repo>\``.

If `session-state.sh` is unreadable at resume, the companion scans `pause-*.md`
files and requires both the injective filename key and exact `Repository` field
to match before choosing the newest candidate. A mismatch on either check is
skipped. Legacy `suspend-*.md` files retain their pre-Issue-1310 compatibility
scanner; new markers never use that lossy format.

Sections (in order):
1. **Paused at** — timestamp and window
2. **Landed** — list of merged PRs
3. **Parked** — each unit with stopping point, next move, and waiting-on
4. **Monitors** — each stopped Monitor with its owner and stopped status
5. **Refill pause** — status and how to lift
6. **Resume command** — `/pause-resume` (with `--resume-refill` note if applicable)

### Compact past-deadline marker

When `WINDOW_EXPIRED` is true the marker degrades to a compact form so the marker step can never be the reason the window blows. It keeps every machine-required field — the exact `Repository` line, the landed list, each parked unit with its recovery path, the stopped-task records, the refill status, and the resume command — and drops long-form narrative prose, per-unit rationale, and formatted tables.

**The compact marker also carries its own expiry note**, because a compact marker exists only on the expired path and the marker is the fallback index used precisely when `session-state.sh` is unreadable — a resume reading it never sees the JSON `window_expired` flag. A `Window expired: landed list may be incomplete; re-read GitHub` line preserves, in the degraded path, the same instruction `window_expired: true` gives in the state block: treat `landed` as provisional, since a `/wrap` in flight at expiry may have merged afterward. The mechanics are identical in both forms: same atomic publish, same injective filename encoding, same fallback path, same permissions, so `/pause-resume` discovers a compact marker exactly as it discovers a full one.

**Two consumers constrain what the compact form may drop.** `/pause-resume` requires the exact ``Repository: `owner/repo` `` field for auto-discovery. `candidate-ownership.sh` matches parked work by regex over `branch` (`issue-N`), `stopped_at` and `next_move` (`#N`), and `recovery_path` (`issue-N`) in the state block, and greps the marker file itself for `#N` or `issue-N`. A parked unit that maps to an issue must therefore keep those references in both artifacts; dropping them strands the unit rather than merely shortening its description.

## Relationship to other state blocks

| Block | Scope | `--session-view`? | Writer | Reader |
|---|---|---|---|---|
| `.repos[k].refill` | repo | No | `/end` Step 1, `/pause` Step 1 | `/pm` Step 3.4, `/subagent` Step 7 |
| `.repos[k].day` | repo | No | `/pm day` Step 2D | `/pm day` tick, `/pause` Step 2 |
| `.repos[k].pauses[<session>]` | repo map, one record per session | No | `/pause` Step 7b | `/pause-resume` Step 1 |
| `.repos[k].pause`, `.repos[k].suspend` | repo | No | nobody (legacy) | `/pause-resume` Step 1, `/go-on` probe B |
| `.repos[k].resumes[<session>]` | repo map, one record per session | No | `/go-on` Step 0.5 | `/go-on` Step 0.5 |
| `.prs[N].babysit` | PR | Yes (via `.prs`) | `/babysit-pr` | `/babysit-pr-stop`, `/pause` Step 2 |

**Writing via `session-state.sh --set` is mandatory.** Never inline `jq … > tmp && mv tmp` — that bypasses the state lock described in `handoff-files.md` and can produce a corrupt write when two writes race.
