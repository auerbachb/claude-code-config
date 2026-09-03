---
name: end-resume
description: Resume work stopped by /end; `/go-on` is the primary resume entry point and routes here. Explicitly clears the current session's background-launch gate, reports preserved stopped tasks, and resumes selected recoverable work without duplicating live tasks. The refill gate stays paused unless --resume-refill is supplied. Triggers on "end-resume", "resume from end", "continue ended work", "resume ended work".
triggers:
  - end-resume
  - resume from end
  - continue ended work
  - resume ended work
argument-hint: "[--resume-refill] (--resume-refill also reopens pipeline refilling)"
---

Resume a cost-quiescent `/end` explicitly. This is the only normal path that
reopens the session-scoped launch gate; unrelated messages and timers do not.

> **`/go-on` is the primary entry point for resuming.** It classifies the
> stoppage from recorded evidence and routes here when the newest record is an
> `/end`, forwarding `--resume-refill` verbatim — so nobody has to remember which
> stop happened (Issue #1397; ladder:
> `.claude/reference/universal-resume.md`). This command keeps working unchanged
> and stays the direct path when you already know the session was ended; it
> remains the executor, and a routed invocation is still an explicit human
> invocation of it. Portable handoff documents keep naming `/end-resume` alone in
> their `Resume command:` field — that field is lint-restricted to this command
> because its reader may be outside this harness entirely.

## Step 0: Resolve state helpers

Resolve `execution-pause.sh`, `background-task-registry.sh`, and
`session-state.sh` using the standard stop-command order: skills worktree,
then `$HOME/.claude`. Do not execute a current-checkout fallback: this command
may be invoked from an unrelated or untrusted repository. Parse only
`--resume-refill`.

Before clearing the gate, require all three helpers to be resolved and readable.
Use the registry to list the current session and use `session-state.sh` to read
the repo key/refill state. If either inventory is unavailable or malformed,
report a degraded resume and leave the execution gate closed. If
`execution-pause.sh` is missing or cannot clear the current
`${CLAUDE_SESSION_ID:-default}` gate, likewise stop without re-arming anything.
A partial resume behind an unknown or unreadable inventory is worse than a
visible no-op.

## Step 1: Clear the execution gate

Call `execution-pause.sh --clear --session "$SESSION_ID"`. This explicit human
invocation authorizes new background starts again. Do not clear the independent
`.repos[REPO].refill.paused` gate unless `--resume-refill` was supplied.

When `--resume-refill` is present, set refill to
`{"paused":false,"reason":null,"scope":null,"at":null}` with
`session-state.sh`. Report a failed write; do not claim refilling resumed.

## Step 2: Inventory preserved work

List registry entries for the current repo and session in `stopped`, `failed`,
`rearmed`, and `abandoned` states. Display each exact runtime ID, logical name,
type, output file, worktree/recovery path, and work item. Keep the historical
entry after resume so a second invocation is idempotent.

Before re-arming an entry, inspect Claude Code runtime tasks. If the same work
is already live, do not launch a duplicate; mark or leave it `rearmed` and
report the existing identity.

For a stopped entry that still needs a launch, atomically claim it before the
runtime check with:

```bash
"$TASK_REGISTRY_SH" --transition --session "$SESSION_ID" \
  --task-id "$TASK_ID" --status rearming --from-status stopped
```

Exit 7 means another resume invocation already changed the entry; skip it and
re-read rather than launching. Only the successful claimant proceeds. A failed
or incomplete recovery transitions `rearming -> stopped` with
`--from-status rearming`; a confirmed recovery transitions `rearming ->
rearmed`. Because the compare-and-set runs under the registry lock, concurrent
`/end-resume` invocations cannot both launch the same continuation.

`rearming` is a reservation, not a stoppable runtime identity, and is excluded
from registry `--live` results. Immediately before launching, re-check the
execution gate; a concurrent `/end` or `/pause` activation therefore blocks
the new launch. A successful successor registers its own runtime ID through the
normal launch hook before the old reservation becomes `rearmed`, so shutdown
audits stop the successor ID rather than racing on the old stopped ID. If launch
is blocked or fails, compare-and-set the reservation back to `stopped`.

On a later resume, a `rearming` reservation older than five minutes is an
interrupted claim. Inspect runtime tasks and the registry first: finalize it as
`rearmed` when a successor is already registered, otherwise reset it to
`stopped` with `--from-status rearming` and retry. Never reclaim a fresh
reservation or infer successor liveness from the display name.

## Step 3: Resume recoverable entries

- Agent: send a continuation message to the exact agent runtime ID, naming its
  checkpoint/output path. If that identity cannot resume, create a successor
  only from the recorded handoff or recovery path and record the new runtime ID.
- Workflow, background Bash, or Monitor: delegate to the owning skill or use
  the recorded recovery action. Never guess a command from its display name.
- Missing or unreadable recovery metadata: leave the entry stopped and report
  the exact missing field.

After a confirmed re-arm, transition the claimed entry to `rearmed` with
`--from-status rearming`. Re-read the registry and runtime list before
reporting.

**Re-arm the table-freshness floor when a round resumes.** `/end` disarms it by
DATA (it clears the render record) and its shutdown stops the persistent
Monitor, so both halves are gone — and `/subagent` arms that watch **once per
session**, on the assumption it outlives the round. Nothing else re-arms it, so
without this a resumed round has no unprompted hourly pulse for the rest of its
life: `--check` still answers when a heartbeat asks, but the floor stops
volunteering, which is the whole guarantee. `/pause-resume` Step 5 handles this
same pair of lost halves; keep the two in step.

Do this only when a round is actually resuming (at least one pipeline re-armed
above), and only with a resolved repo key:

```bash
# `--repo-key` prints `_unknown` and exits 0 when it cannot resolve a repo, so
# an emptiness test alone never fires — normalise the sentinel, or the watch is
# armed on a scope no render will ever write to.
REPO_KEY=$("$SESSION_STATE_SH" --repo-key 2>/dev/null) || REPO_KEY=""
[[ "$REPO_KEY" == "_unknown" ]] && REPO_KEY=""
TABLE_FRESHNESS_SH=$(resolve_script table-freshness.sh) || TABLE_FRESHNESS_SH=""
if [[ -n "$TABLE_FRESHNESS_SH" && -n "$REPO_KEY" ]]; then
  # Record the resumed board FIRST, then arm: arming over an absent record
  # gives a watch that polls nothing and stays silent while looking armed.
  ACTIVE_COUNT=<pipelines re-armed above, running + queued>
  if [[ "${ACTIVE_COUNT:-}" =~ ^[0-9]+$ ]] && (( ACTIVE_COUNT > 0 )); then
    if "$TABLE_FRESHNESS_SH" --note-rendered --active "$ACTIVE_COUNT" \
         --repo "$REPO_KEY" --session "${CLAUDE_SESSION_ID:-default}" \
         --surface end-resume; then
      # Hand `--arm-command` output to the Monitor tool with persistent: true.
      "$TABLE_FRESHNESS_SH" --arm-command --repo "$REPO_KEY" \
        --session "${CLAUDE_SESSION_ID:-default}"
    else
      echo 'DEGRADED: table-freshness clock not recorded on resume — floor not re-armed; re-render the "Running now" table on every heartbeat'
    fi
  fi
fi
```

Nothing to re-arm (an empty board) correctly leaves the floor disarmed — that is
the idle exemption, not a gap.

## Step 4: Report

```text
=== End resumed ===
Launch gate: cleared
Refill gate: <cleared | still paused | clear failed>
Rearmed: <exact old ID -> resumed/new ID, or none>
Still stopped: <exact IDs and missing recovery requirement, or none>
```

Never report an entry rearmed merely because a launch was attempted. A second
invocation must not duplicate anything already running.
