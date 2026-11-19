# /desk — the operator's open human tasks

Loaded when the operator's whole message is `tasks` (also `human tasks`, `my tasks`, `tasks?`; any case). That holds at any time: with nothing on screen, after a menu, while a long-form prompt waits (it keeps waiting and its card is printed again after), or during a discussion. Every Bash block starts with `SKILL.md`'s prelude (`DESK`). Issue #2542.

**What it is.** Threads hand the operator work only a person can do: fill in a `.env`, sign in to an account, accept an agreement. Those requests live on GitHub, one list per repo, kept by `owner-task.sh` (issue #2538; `.claude/reference/owner-tasks.md`). This view shows the open ones across every repo, beside the Decisions and Reviews, with why each needs a person and where it came from, so the desk stays the one screen for "what is waiting on me".

**Read-only.** The desk stores nothing about tasks: no item, no state key, no copy. Marking a task done still happens on the list itself (`owner-task.sh done <ht-id> --proof '<the check that shows it>'`, or `--by operator`); the next `tasks` shows the change. Snooze, tags, notes, and personal priority (`todo.md`) work on items only, never on tasks.

## Showing the list

The list is read straight from `owner-task.sh`, so this needs no store URL: it calls `human-queue.sh` directly, not `$HQ`.

<!-- test-anchor: desk-tasks-list -->

```bash
"$DESK/bin/human-queue.sh" tasks 2>&1; echo "exit=$?"
```

- **`exit=0`** → print the output as is, without the `exit=` line:

  ```text
  2 open human tasks in 1 repo
  owner/name
    ht-1a2b3c4d  Fill in .env for staging
                 why a person: needs your API key · from: PR #12 · since 2026-11-18
  ```

  or `No open human tasks.`
- **`exit=1`** → the list could not be read (offline, `gh` unavailable or signed out, `owner-task.sh` not installed). Say it in one line with the reason the CLI printed: `The task list could not be read (<reason>). Decisions and Reviews are unaffected.` Never say there are no tasks.
- **Exit 4** → its one line (an unexpected argument); nothing else.

## In the check-in

The morning check-in's "Waiting now" line carries the open-task count beside the open Decisions and unreviewed Reviews (`checkin.md`, `checkin get --tasks`). When the list cannot be read, the line says so and the card still shows.
