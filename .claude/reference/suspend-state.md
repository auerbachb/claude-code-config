# Suspend State — Shape, Triage Rule, and Deadline Semantics

Reference for the `.repos["<owner>/<name>"].suspend` block in `session-state.json`. Written by `/suspend` Step 7a and read by `/suspend-resume` Step 1.

## Why this is in `.claude/reference/` and not a rule file

The `/suspend` SKILL.md and `/suspend-resume` SKILL.md carry the authoritative contracts. This file holds the mechanism, rationale, and the state-shape prose that would push the corpus past its word-count budget if it lived in an auto-loaded rule. Rules load every turn; this file loads on demand.

## State shape

`.repos[<repo-key>].suspend`, beside `refill` and `day` (repo-scoped, one per repo):

```json
{
  "active": true,
  "suspended_at": "2026-08-22T22:10:00Z",
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
      "stopped_at": "Phase A in flight at suspend time",
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
  "marker_path": "~/.claude/handoffs/suspend-20260822T221000Z-<session>.md",
  "resumed_at": null
}
```

**Visibility:** Like `refill` and `day`, this block is **invisible to `session-state.sh --session-view`** (that projection lifts only `.prs` and `.root_repo` out of the repo block). Read it with an explicit `--get .repos["<key>"].suspend`. A caller who uses `--session-view` will see the suspend block as absent even when one is armed.

**One block per repo at any time.** A second `/suspend` in the same repo replaces the previous block. If the previous session is still parked and not yet resumed, the old block's history is overwritten — `/suspend-resume` should be run before running `/suspend` again.

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

`T_end = T_start + window_minutes * 60` is computed once in `/suspend` Step 0 and is not re-evaluated. It is a budget on how long `/suspend` waits on landing, not a promise to the user that work will finish.

**The window never relaxes a gate.** A PR that cannot pass the merge gate honestly inside the window is reclassified `park`. The classifier reads the actual gate; it does not approximate it.

**A `/wrap` in flight at expiry is not killed.** Killing mid-merge produces exactly the unrecorded state this command exists to prevent. `/suspend` stops *waiting*, reclassifies the unit `park`, and records the in-flight state. `/suspend-resume` re-reads GitHub before printing, so a merge that completed after the window shows up as landed at resume.

**`window_expired: true`** is set in the suspend block when the deadline passed before all `land` units finished. It tells resume to re-read GitHub rather than trusting the `landed` array as complete.

## Marker file format

The human-readable marker at `~/.claude/handoffs/suspend-<stamp>-<repo-key>-<session>.md` mirrors the state block in readable form and serves as the fallback index for `/suspend-resume`. The repo key (sanitized for filesystem use: `/` → `-`) is embedded in the filename so a resume from a different repo cannot accidentally pick up another repo's marker as its own.

If `session-state.sh` is unreadable at resume, the companion scans `suspend-*.md` files and validates each candidate's filename against the current repo's sanitized key before choosing the newest matching one. A marker whose filename does not contain the current repo key is skipped.

Sections (in order):
1. **Suspended at** — timestamp and window
2. **Landed** — list of merged PRs
3. **Parked** — each unit with stopping point, next move, and waiting-on
4. **Monitors** — each stopped Monitor with its owner and stopped status
5. **Refill pause** — status and how to lift
6. **Resume command** — `/suspend-resume` (with `--resume-refill` note if applicable)

## Relationship to other state blocks

| Block | Scope | `--session-view`? | Writer | Reader |
|---|---|---|---|---|
| `.repos[k].refill` | repo | No | `/pause` Step 1, `/suspend` Step 1 | `/pm` Step 3.4, `/subagent` Step 7 |
| `.repos[k].day` | repo | No | `/pm day` Step 2D | `/pm day` tick, `/suspend` Step 2 |
| `.repos[k].suspend` | repo | No | `/suspend` Step 7a | `/suspend-resume` Step 1 |
| `.prs[N].babysit` | PR | Yes (via `.prs`) | `/babysit-pr` | `/babysit-pr-stop`, `/suspend` Step 2 |

**Writing via `session-state.sh --set` is mandatory.** Never inline `jq … > tmp && mv tmp` — that bypasses the state lock described in `handoff-files.md` and can produce a corrupt write when two writes race.
