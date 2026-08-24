---
name: pause-resume
description: Resume work stopped by /pause. Explicitly clears the current session's background-launch gate, reports preserved stopped tasks, and resumes selected recoverable work without duplicating live tasks. The refill gate stays paused unless --resume-refill is supplied. Triggers on "pause-resume", "resume from pause", "continue paused work", "resume stopped work".
triggers:
  - pause-resume
  - resume from pause
  - continue paused work
  - resume stopped work
argument-hint: "[--resume-refill] (--resume-refill also reopens pipeline refilling)"
---

Resume a cost-quiescent `/pause` explicitly. This is the only normal path that
reopens the session-scoped launch gate; unrelated messages and timers do not.

## Step 0: Resolve state helpers

Resolve `execution-pause.sh`, `background-task-registry.sh`, and
`session-state.sh` using the standard stop-command order: skills worktree,
`$HOME/.claude`, then the current repository. Parse only `--resume-refill`.

If `execution-pause.sh` is missing or cannot clear the current
`${CLAUDE_SESSION_ID:-default}` gate, stop without re-arming anything. A partial
resume behind an unknown gate is worse than a visible no-op.

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

## Step 3: Resume recoverable entries

- Agent: send a continuation message to the exact agent runtime ID, naming its
  checkpoint/output path. If that identity cannot resume, create a successor
  only from the recorded handoff or recovery path and record the new runtime ID.
- Workflow, background Bash, or Monitor: delegate to the owning skill or use
  the recorded recovery action. Never guess a command from its display name.
- Missing or unreadable recovery metadata: leave the entry stopped and report
  the exact missing field.

After a confirmed re-arm, transition the stopped entry to `rearmed`. Re-read
the registry and runtime list before reporting.

## Step 4: Report

```text
=== Pause resumed ===
Launch gate: cleared
Refill gate: <cleared | still paused | clear failed>
Rearmed: <exact old ID -> resumed/new ID, or none>
Still stopped: <exact IDs and missing recovery requirement, or none>
```

Never report an entry rearmed merely because a launch was attempted. A second
invocation must not duplicate anything already running.
