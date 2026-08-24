# Background-task shutdown contract

`/pause` and `/suspend` share this procedure. Their windows differ, but their
success condition does not: no task started by the current Claude Code session
may still be billable when the command reports completion.

## Scope and identities

Read current-session entries from `background-task-registry.sh --list --live`.
The registry records the exact runtime ID returned by `Agent`, background
`Bash`, `Monitor`, and `Workflow`; a logical agent name is never a substitute
for that ID. Separately launched `claude agents` sessions are outside this
command's ownership and must be reported as out of scope.

## Shutdown sequence

1. Activate `execution-pause.sh` and the refill pause **before** inspecting or
   waiting. The PreToolUse hook then rejects every new Agent, Workflow,
   Monitor, and background Bash launch while leaving foreground teardown
   commands available.
2. Snapshot the current session's live registry entries. Stop Monitors and
   passive background watchers immediately; they have no useful checkpoint
   work. For each agent, workflow, or productive background process, request a
   cooperative checkpoint when the window is greater than zero. Tell agents
   to finish only their current atomic write, preserve uncommitted work and
   output paths, and stop without launching successors.
3. Treat `--window` as a maximum, not a sleep. Re-check the registry as work
   completes and proceed as soon as every productive task is terminal. Do not
   start another Monitor merely to wait for the deadline. A zero-minute window
   skips the cooperative interval.
4. At the deadline, mark each remaining exact ID `stopping`, call `TaskStop`
   for that ID, then mark it `stopped` only after success. A no-match response
   is success only when runtime inspection confirms the task already ended.
   Record other failures as `stop_failed`; never discard their IDs, worktrees,
   output files, or recovery paths.
5. Re-audit both the registry and Claude Code's runtime task list. Clear a
   background-work-ceiling marker only after its owning Monitor is confirmed
   stopped. Also inspect the session's
   `claude-background-registry-failed-<session>` marker: its presence means at
   least one runtime identity may be missing from the registry, so runtime
   inspection must prove zero live tasks before the marker can be cleared.
   Report success only when both sources show zero live tasks in this session
   and no unresolved tracking-failure marker remains. Otherwise report an
   incomplete shutdown, list every unresolved exact ID or tracking failure,
   and keep both launch gates closed.

The commands do not delete worktrees, branches, logs, handoffs, or task output.
Resume commands clear the execution gate explicitly and use those preserved
locations to continue work without duplicating already-running tasks.
