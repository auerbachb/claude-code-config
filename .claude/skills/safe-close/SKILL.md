---
name: safe-close
description: Use when you want to know whether this thread can be closed without losing work or leaving something running — "safe to close?", "what's still open here". Reports a verdict line, then outstanding items tagged lost, keeps running, orphaned or harmless; unverifiable means not yet. `--check` only looks; bare `/safe-close` also stops what the thread left running, removes finished leftovers (never anything that still holds work), re-checks, and offers to archive only if the re-check is clean.
triggers:
  - safe to close
  - safe-close
  - can I close this thread
  - what's still open
  - is this thread done
argument-hint: "[--check] [--json]"
---

Tell the user whether this thread can be closed right now and exactly what is in the way; then stop what this thread left running, tidy what it left behind, and re-check. **Steps 0–3 only look.** `/safe-close --check` (and `--json`) run only those steps: no menu, nothing stopped, nothing removed, no state written. Bare `/safe-close` adds Steps 4–7 (stop what is running) and Steps 8–10 (remove finished leftovers, keep and name anything that still holds work, re-run the check, and offer to archive the thread only when that re-run is clean). Nothing is archived without the user's yes.

It acts only on this thread's own things. Another thread's work, or another author's PR, is context at most: never counted, never stopped.

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

With `--check` or `--json`, stop here and add at most one closing line naming what the stop step would handle. Bare `/safe-close` continues to Step 4 when something is running. `--json` prints the merged inventory instead of the prose report: the script JSON plus your agent-check items, with `outstanding` recounted over the merged `items[]` (every non-harmless item) and `verdict` set to `not_yet` whenever that count is above zero, so an unregistered running task reads `not_yet` in JSON exactly as in prose. Once Step 2 has cleared every `agent_checks[]` entry, empty that array and set `needs_agent_checks` to `false`; leave it populated for any check you could not complete (and count that one as unknown).

## Notes

- Ownership is shown by the session id on a record, the thread's own worktree or branch, or a runtime id this session registered. A non-terminal record that names no owner is reported as one `unknown` item, never claimed and never ignored.
- The verdict is only as good as what was recorded: a task or agent that was never registered is invisible to the script, which is why Step 2 exists.

## Step 4: Plan the stop (bare `/safe-close` only)

Skip this step and everything after it for `--check` and `--json`. Resolve `safe-close-stop.sh` the same way as Step 0 (missing: say so in one line and stop; never improvise a stop). Feed it the merged inventory, which already folds in your Step 2 findings — in particular, add each harness-only background shell, Monitor, wake-up and subagent as an item `{category:"harness_tasks", consequence:"keeps_running", ref:{task_id, type}}`, and each live session this thread started as `{category:"linked_sessions", consequence:"keeps_running", ref:{session_id}}`, so the plan covers them (an item with another category is ignored, so use these exact shapes):

```bash
STOP_SH=$(resolve_script safe-close-stop.sh) || { echo "ERROR: safe-close-stop.sh not found (checked all three paths) — stop step unavailable" >&2; exit 1; }
# Pass the merged inventory (script JSON + your Step 2 items, as in --json) on stdin, so no
# scratchpad is needed; a file path works too (--inventory FILE).
printf '%s' "$MERGED_INVENTORY_JSON" | "$STOP_SH" plan --inventory -   # stop_items[], unknown_items[], menu_required
```

The plan covers only items the inventory attributed to this thread. Items the inventory marked **unknown** are in `unknown_items[]`: list them to the user (what could not be verified and why) and **never stop them**. Sessions this thread started are separate conversations: list each by name and ask about it individually; never stop them as a group.

If `menu_required` is false there is nothing to ask: the Step 3 report (verdict, every non-harmless item, the unknown list) already stands, so add nothing. No menu, no extra output. Go straight to Step 8 only when `unknown_items[]` is also empty (nothing running, nothing unverified, so nothing to verify stopped); with an unknown item left, stop here — cleanup deletes things an unverified task might still use.

## Step 5: One confirmation menu

Ask exactly once, with `AskUserQuestion` (recommended option first, per `ask-menu.md`); never stop anything before the answer:

1. **Stop all, park unfinished work (Recommended)** — every item stops; any with unlanded work (`choice_required`) is parked.
2. **Choose per item** — one follow-up `AskUserQuestion` for the items with `choice_required`, with `multiSelect` where the choices are independent. Offer `finish`, `park`, `drop` and, when the item's `offers` includes it, `wrap` (a merge-ready PR gets a final `/wrap` instead of being parked). The default is `park`. Offer a runway for `finish` (default 15 minutes); when it passes, the item falls back to `park`.
3. **Cancel** — nothing is stopped.

A plan item with `kind: "session"` is a conversation this thread started: it gets its own question (`keep` is the default, `stop` the alternative, no park or drop), one per session, and "Stop all" never includes it.

**Drop is never the default and is never chosen for the user**: it is recorded only when the user picks it for that item by name. Anything the user did not answer for is parked. If the question tool is unavailable (headless), do not stop anything: report the plan and end.

## Step 6: Stop it (reusing /pause's machinery)

**Linked sessions the user chose to stop** are not task ids: stop each with the harness's session-management tool by its `session_id` (stop that one session, nothing else), then confirm with a fresh session list that it is no longer running. With no such tool, or if the list cannot be read, report the session as not stopped. Sessions follow no park/owner/registry flow below.

Do not add a second stop path. Use the same pieces `/pause` Step 2 and `background-task-shutdown.md` use, scoped to the exact ids in the plan:

1. **Land or checkpoint the work first.** `finish`: wait up to the runway for the item to reach a terminal state (re-check the registry), then fall back to `park`. `wrap`: run `/wrap` for that PR only. `park`: ask a running agent for a cooperative checkpoint (finish only its current atomic write, preserve uncommitted work and output paths, launch no successors) and wait for it, so what you record is where it actually stopped.
2. **Write the park record before stopping anything that depends on it.** For every parked item, write the decisions file (`parked[]` entries need `kind`, `stopped_at`, `next_move`, `boundary`, plus `branch`, `ref`, `handoff_path` as `/pause` Step 6 records them) and run `"$STOP_SH" park --session "$SESSION_ID" --repo "$REPO" --decisions <file>`. It writes the same `.repos[<repo>].pauses[<session>]` record and `pause-*.md` marker `/pause` writes, so `/go-on` resumes it from any thread. A non-zero exit means nothing was parked: stop nothing that depends on it and say so. Do not list a task under `background_tasks_stopped[]` yet.
3. **Stop by exact runtime id**, never by logical name: for each item, `safe-close-stop.sh owner --task-id <id> --repo "$REPO"` (`--repo` is required: the day, day-limit-wake and wind-down watchers are repo-scoped, so without it the script exits 2 and the id stays unattributed, never `none`). A named watcher goes through its owner's stop command (`babysit` → `/babysit-pr-stop <PR>`, `pmm` → `/pr-monitor-and-manage-stop`, `day` and `day_limit_wake` and `leave_winddown` → `/pause` Step 2 items 3–5, in that order, including the generation invalidation for the wind-down). Owner `none` → call `TaskStop` on the exact id. An **unreadable owner (exit 3)** is not `none`: stop nothing for that id, report it as unverified, and leave it for the user — never send an id you cannot attribute to a bare `TaskStop`. Mark the registry as you go: `background-task-registry.sh --transition --session "$SESSION_ID" --task-id <id> --status stopping`, then `stopped` only once a fresh read of the harness task list no longer shows that id. A stop that errors is `stop_failed`. Scheduled wake-ups and cron jobs the harness listed for this thread are removed with the harness's own tool.
4. **Record what is confirmed stopped.** Only for tasks confirmed gone in step 3 that the user parked, run `park` again with those in `background_tasks_stopped[]` (their exact `task_id`, `type`, `name`, `recovery_path`) — it extends the existing record rather than replacing it, so `/go-on` re-arms them. **If this second write fails**, the task is stopped but its re-arm entry is not recorded: say so plainly, name each affected exact `task_id` with its `recovery_path` and output file (the registry still holds them as `stopped`, and the first park record names the parked unit), and leave the verdict at not yet until the user has that list. Never describe it as parked.
5. **Ceiling.** Only after every task, subagent and Monitor this thread owned is confirmed stopped (the registry lists none live), run `"$STOP_SH" clear-ceiling --session "$SESSION_ID" --repo "$REPO"`.

## Step 7: Re-check — a stop's exit status is not proof

List the runtime's own tasks (the harness task list) into a file — a JSON array of ids, or one id per line; write an empty list as `[]`, because an empty file is read as a failed read — and run:

```bash
"$STOP_SH" verify --session "$SESSION_ID" --repo "$REPO" --worktree "$PWD" \
  --runtime-live-file "$RUNTIME_LIST" --stopped-id <id> [--stopped-id <id> ...] \
  [--confirmed-gone <subagent-key> ...] [--pid <pid-you-spawned> ...]
```

Pass `--stopped-id` for **every** id you tried to stop, including harness-only tasks and chosen linked sessions (their `session_id`), and include those sessions in the runtime list file, so a survivor the registry never knew is still caught. If you could not read the runtime list, pass `--runtime-unreadable` instead; the verdict is then never clean (exit 1, `[unverified]`), and every stopped id is reported unverified, never gone. `--confirmed-gone` is only for a subagent record whose runtime id the harness list showed absent; it counts only when the runtime list was read and does not name that id. It re-runs the inventory, so the check is against current state, not what you remember doing.

The first line is the result. `Nothing owned by this thread is still running.` ends the step. Otherwise it prints `Not yet` and each item still running or unverified, by name; relay those lines, keep the verdict at not yet, and offer one retry of the stop for the named items only. Never report success while one is alive. Then continue to Step 8 **only** when verify exited 0 with the clean line above as its first line (a following `N other item(s) ... are left for cleanup.` line is expected and is not a block) and every attempted stop is confirmed. Any `Not yet` line, any unverified id, or an unreadable runtime task list (`--runtime-unreadable`) means stop here: cleanup waits for a verified stop, since it deletes things a running or unverified task may still use. Say in one line what was stopped, what was parked (and that `/go-on` resumes it), what the user dropped and what is unknown.

## Step 8: Plan the cleanup (bare `/safe-close` only, after a verified stop)

Resolve `safe-close-clean.sh` the same way as Step 0 (missing: say so in one line and stop; never delete by hand). Re-run the inventory script for fresh state (the stop changed it) and merge your Step 2 findings as before. **Gate: clean up only if that fresh merged inventory has no `keeps_running` item and no `unknown` item in `background_tasks`, `subagents`, `ceiling`, `harness_tasks` or `linked_sessions`, and no Step 2 check is unverified.** If one does, report it by name and stop before any cleanup (a plan with an empty `ask[]` is not verification that nothing is running). Then pipe the merged inventory to the plan. Pass the session id, repo, the thread's own checkout, and the scratchpad when it has one — all required except the scratchpad (the script exits 2 without them, and never skips a scoped check silently):

```bash
CLEAN_SH=$(resolve_script safe-close-clean.sh) || { echo "ERROR: safe-close-clean.sh not found (checked all three paths) — cleanup unavailable" >&2; exit 1; }
SCRATCH_ARGS=(); [[ -n "${SCRATCHPAD_DIR:-}" ]] && SCRATCH_ARGS=(--scratchpad "$SCRATCHPAD_DIR")
printf '%s' "$MERGED_INVENTORY_JSON" | "$CLEAN_SH" plan --inventory - --session "$SESSION_ID" --repo "$REPO" --worktree "$PWD" ${SCRATCH_ARGS[@]+"${SCRATCH_ARGS[@]}"}
```

The plan writes nothing. It sorts what the inventory attributed to this thread into `would_remove` (finished work, each removal done by the helper that already owns it: the finished-work sweep for worktrees and local branches, `issue-claim.sh` for claims, `handoff-state.sh` for handoffs of merged PRs, `session-state.sh` for this session's own entries, plain scratch files), `kept` (anything that still holds work — named, with a pickup note), `ask` (things that carry your own intent and cannot be shown finished) and `failed` (a read that did not work: nothing is cleaned on its say-so). A thread that only filed issues leaves nothing here; the issues are the record, so say that in one clause rather than leaving it to read as an oversight.

## Step 9: One question, then apply

If `ask[]` is empty, apply without asking: everything in `would_remove` is verified finished. Otherwise ask **once** with `AskUserQuestion` (recommended option first, per `ask-menu.md`; `multiSelect: true`, one option per `ask` entry, each worded from its `why`; **"Keep them all" is the recommended first option**). Pass only the ticked kinds back as `--approve <kind>` (one entry per kind; ticking it clears every record of that kind this session holds, which the option text says). If "Keep them all" is ticked, pass no `--approve` at all, even when other options are ticked too. No menu tool (headless): approve nothing.

```bash
APPLY_ARGS=(${SCRATCH_ARGS[@]+"${SCRATCH_ARGS[@]}"})   # then append: --confirmed-gone <agent-key> ... and --approve <kind> ...
printf '%s' "$MERGED_INVENTORY_JSON" | "$CLEAN_SH" apply --inventory - --session "$SESSION_ID" --repo "$REPO" --worktree "$PWD" ${APPLY_ARGS[@]+"${APPLY_ARGS[@]}"}
```

`--confirmed-gone` is for a subagent state record whose runtime id Step 7 saw absent from the harness's task list; without it the record is kept. Run the scratch cleanup only now, after Step 7: other agents of this session may share the scratchpad until then. Never run `git clean`, never delete a worktree, branch, claim, handoff or state entry yourself, and never force anything the report kept: the report is the whole list of what this step may touch. The report's exit status and its `removed[]` are not proof: the next step is.

## Step 10: Re-run the check — the verdict comes from it

Run the inventory script again (Steps 1–3, merging your Step 2 findings), fresh. **That re-run's verdict is the verdict**, never the cleanup's exit code or its `removed[]`. A `failed[]` entry, an `unknown` category, or a read that did not work can therefore never end in "safe": it ends in the re-run still saying not yet, and the report names it.

- **Clean** (`Safe to close.`): one line only — what was cleaned, for example `Safe to close — cleaned 3 worktrees/branches, 1 claim, 2 handoffs.` — then offer to archive the thread with one `AskUserQuestion` (recommended: **Archive this thread**; alternative: **Leave it open**). Archive only on the user's yes, using the harness's own session-archive tool for this thread's own session (never another thread's). In a harness with no archive capability, say in the same line that it is safe to close by hand and ask nothing. Remote branches are left to the merge and to `/pm-clean`.
- **Not clean** (`Not yet — N outstanding.`): list each remaining item as `[consequence] what it is — what it needs` (use the kept items' pickup notes: commit and push, merge the PR, resume with `/go-on`, cancel with `/leave-by cancel`), and **archive nothing**. Do not offer to archive.

A second `/safe-close` on an already-clean thread finds nothing to remove, runs no sweep and changes nothing: it prints the clean line and the archive offer again.
