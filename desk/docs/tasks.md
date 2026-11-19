## Open human tasks (issue #2542)

The desk shows the operator's open human tasks — what only a person can do,
such as filling in a `.env`, signing in, or accepting an agreement — beside
Decisions and Reviews, across every repo (`skill/tasks.md`). The tasks are
kept on GitHub, one list per repo, by `.claude/scripts/owner-task.sh` (issue
#2538; `.claude/reference/owner-tasks.md`). The desk only reads them.

| Subcommand | What it does |
|------------|--------------|
| `tasks [--json]` | Runs `owner-task.sh list --all-repos --json` and prints the open tasks by repo, oldest first, each with why it needs a person, where it came from, and since when. `--json`: `{"readable", "reason", "count", "repos", "tasks": [{id, repo, what, why, source, created_at, state, done_at, proof}]}`. Never connects to the store |
| `checkin get --tasks [--json]` | The check-in (`docs/morning-check-in.md`) with the counts: the text line gains `· 3 open Decisions · 19 unreviewed Reviews · 2 open tasks`, the JSON a `tasks` object `{"readable", "open", "reason"}` (`open_decisions` is in `checkin get --json` either way). The card's "Waiting now" line shows all three |

- **No second copy.** Nothing about tasks is stored in the desk: no schema
  change, no item kind, no state key. Marking a task done happens on the list
  itself (`owner-task.sh done ID --proof TEXT`). Moving tasks into the desk
  database, so snooze and priority work on them, is a later change that needs
  a migration of the item-kind and id-format rules.
- **Finding the script.** `owner-task.sh` is the first executable of
  `~/.claude/skills-worktree/.claude/scripts/`, `~/.claude/scripts/`, and
  `.claude/scripts/` (relative to the current directory); the two installed
  paths are skipped when `HOME` is unset (`bin/lib/owner-tasks.sh`).
- **A list that cannot be read is said, never shown as empty.** The script
  missing, a non-zero exit (offline, `gh` unavailable or signed out, a
  tracker that cannot be read: `owner-task.sh` exits 4), or output that is
  not a JSON array of task objects: `tasks` exits 1 with one line on stderr
  naming the reason (`--json` also prints `{"readable": false, ...}`), and
  `checkin get --tasks` still exits 0, with `task list could not be read`
  in place of the count, so Decisions and Reviews always show.
- **Only open tasks.** Entries whose `state` is not `open` are left out, so a
  list printed with done tasks never inflates the count.
- **One line each.** Control characters in task text become spaces in the
  text view.
- **Tests.** `tests/tasks-offline.test.sh` stubs `owner-task.sh` under a
  throwaway `HOME`: the list, the empty case, each read failure, the
  resolution order, the check-in's counts and card line, and the skill block.
