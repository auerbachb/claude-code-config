---
name: safe-close
description: Use when you want to know whether this thread can be closed without losing work or leaving something running — "safe to close?", "what's still open here". Read-only report with a verdict line, then outstanding items tagged lost, keeps running, orphaned or harmless; unverifiable means not yet. Stops and cleans up nothing.
triggers:
  - safe to close
  - safe-close
  - can I close this thread
  - what's still open
  - is this thread done
argument-hint: "[--json]"
---

Tell the user whether this thread can be closed right now, and exactly what is in the way. **This command only looks.** It stops no process, deletes nothing, releases no claim, and writes no state — stopping running work and cleaning up are separate, later commands.

It reports only on this thread's own things. Another thread's work, or another author's PR, is context at most and never counts against the verdict.

## Step 0: Resolve the inventory script

```bash
resolve_script() {
  local name="$1" candidate
  for candidate in \
    "${HOME:+$HOME/.claude/skills-worktree/.claude/scripts/$name}" \
    "${HOME:+$HOME/.claude/scripts/$name}" \
    ".claude/scripts/$name"; do
    if [[ -n "$candidate" && -x "$candidate" ]]; then echo "$candidate"; return 0; fi
  done
  return 1
}
INVENTORY_SH=$(resolve_script safe-close-inventory.sh) || INVENTORY_SH=""
[[ -n "$INVENTORY_SH" ]] || { echo "ERROR: safe-close-inventory.sh not found (checked all three paths) — thread inventory unavailable" >&2; exit 1; }
```

If it is missing, say so in one line and stop; do not reconstruct the inventory by hand.

## Step 1: Run the script

Run it from this thread's own checkout, passing the session id and, when the thread has one, its scratchpad directory (named in the session environment):

```bash
"$INVENTORY_SH" --session "${CLAUDE_SESSION_ID:-}" --scratchpad "$SCRATCHPAD_DIR"   # JSON on stdout
```

Set `SCRATCHPAD_DIR` to the scratchpad path from your environment, and drop the `--scratchpad` flag if the thread has none. An empty session id is accepted: the script then reports the session-scoped categories as unknown, which is correct. Exit `0` = clear, `1` = not yet; any other exit is a failed inventory: report it, never read it as clear.

The JSON is the whole inventory (`verdict`, `outstanding`, `categories`, `items[]`, `excluded[]`, `agent_checks[]`; schema in the script's `--help`). It covers: registered background tasks, subagent records, queued or deferred pipeline work, `session-state.json` pause/leave markers, the bgwork ceiling, this thread's worktrees (uncommitted or unpushed work), its branches with no PR, its open PRs with merge-gate state, per-PR handoff files, issue claims it still holds, and scratchpad files.

## Step 2: Do the agent checks

The script cannot see what only the harness or the conversation knows. Work through `agent_checks[]` yourself, and add one item per finding. In prose use the words below; in the `--json` output use the schema values `lost`, `keeps_running`, `orphaned`, `harmless`, `unknown`:

| Check | Consequence if found |
|-------|----------------------|
| Background shell commands, Monitors, wake-ups the harness is running for this thread (including any never registered) | keeps running |
| Subagents this thread launched that are still running | keeps running |
| Worktrees this thread created that no registered task names (the script only inspects its own checkout and registered agents' paths) | lost if uncommitted or unpushed work, orphaned if a branch has no PR |
| Sessions this thread started that are still live | keeps running |
| A question to the user in this conversation with no answer yet | lost |
| Questions this thread queued to the human desk that are still open (`human-queue.sh list --status open`) | lost |
| Work this thread said it would do later and has not queued anywhere (conversation-derived: label it as such) | lost |

If you cannot tell for one of these, it is **unknown**, not "none". Do not count a thing twice: before adding a harness finding, match its runtime id against `items[]` — both registry items (`ref.task_id`) and subagent state records (`ref.key`) — and add it only when neither already names it.

## Step 3: Print the report

The **first line is the verdict**, nothing before it:

- `Safe to close.` when the script verdict is `safe` and your agent checks found nothing non-harmless.
- `Not yet — N outstanding.` otherwise, where N is the script's `outstanding` plus your agent-check findings and unknowns. Unknown always counts.

Then one line per non-harmless item: `[consequence] what it is — what happens if you close now`. Consequence words: **lost** (the work or question disappears), **keeps running** (it continues unattended), **orphaned** (it stays behind with nothing carrying it forward), **harmless** (nothing depends on it; summarize as a count, do not list). Unknown items say what could not be verified and why.

A clean thread is at most three lines: the verdict, one line counting harmless leftovers, and, if relevant, one line noting other threads' work that was excluded.

Do not offer to stop or clean anything unprompted beyond one closing line naming what the next step would handle. `--json` prints the merged inventory instead of the prose report: the script JSON plus your agent-check items, with `outstanding` recounted over the merged `items[]` (every non-harmless item) and `verdict` set to `not_yet` whenever that count is above zero, so an unregistered running task reads `not_yet` in JSON exactly as in prose. Once Step 2 has cleared every `agent_checks[]` entry, empty that array and set `needs_agent_checks` to `false`; leave it populated for any check you could not complete (and count that one as unknown).

## Notes

- Ownership is shown by the session id on a record, the thread's own worktree or branch, or a runtime id this session registered. A non-terminal record that names no owner is reported as one `unknown` item, never claimed and never ignored.
- The verdict is only as good as what was recorded: a task or agent that was never registered is invisible to the script, which is why Step 2 exists.
