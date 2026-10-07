# /desk — reorder the backlog for `/pm`

Loaded when the operator's whole message is a priority command (below). That holds at any time: with nothing on screen, after a menu, while a long-form prompt waits, or during a discussion. Issue #1767; design: `desk/DESIGN.md` 2.1 (the Priorities surface) and 7.6 (one file per repo, next to `pm-config.md`).

The desk only records the operator's order. `/pm` honors it at its next ranking or refill (its steps 1B.1a, 1B.4 item 7, and 3.4): operator-ordered issues first, parked issues skipped until their date, everything else in `/pm`'s own ranking. Nothing here launches work, edits an issue, or writes to the store. The order lives in the target repo's `.claude/pm-priority.json`, at its main checkout, and `pm-priority.sh` is the only thing that writes it.

## The commands

| The whole message | Does |
|---|---|
| `top: #a #b #c` (or `top #a #b`) | The order becomes exactly these issues, first to last. Each is unparked |
| `bump #N` | #N moves to the head of the order (added if it was not there). Unparked |
| `park #N until <date>` | #N leaves the order and is skipped until `<date>`, returning on that day |
| `drop #N` | #N leaves the order and the parked list: `/pm` ranks it as it would anyway |
| `priorities` | Shows the order and the parked issues. Changes nothing |

- **Any of them may end with `in <repo>`**: `owner/name`, a bare repo name, or a checkout's absolute path. `park #12 until friday in sales-kit`.
- **`<date>`** is `tomorrow`, a weekday (`friday`: the next one after today), `in N days`, or `YYYY-MM-DD`, and must be later than today in America/New_York.
- **The `#` is required** on every issue number. It is what tells `bump #12` from a reply to item 12, and `top 3` from prose. Verbs are case-insensitive.
- Anything that does not fit this grammar exactly is not a priority command: go back to `SKILL.md`'s reply order. Never guess a command out of prose.

## 1. The target repo

| The command ends with | Target |
|---|---|
| `in owner/name` | `--repo owner/name` |
| `in <name>` (no slash) | `gh repo view <name> --json nameWithOwner --jq .nameWithOwner` (a bare name is the signed-in account's repo), then `--repo` with that. A failure → `No repo named <name> — use owner/name.` and stop |
| `in /an/absolute/path` | `--dir '<path>'`. A path holding a single quote → `Name the repo as owner/name instead.` and stop |
| nothing | The desk's own working directory: no flag |

`pm-priority.sh` finds the checkout. For `--repo`, that is the working directory when it is a checkout of that repo, else the `root_repo` session state recorded for it. It always writes at the **main** checkout, so every worktree of the repo shares one order.

## 2. Check the issues before a write

`top`, `bump`, and `park` add issues, so each must be an open issue in the target repo. `drop` and `priorities` skip this: removing is always allowed, and showing changes nothing. With a path target or no `in`, read the repo first: `"$PRIO" <TARGET> show --json` (step 3's block, with `show --json` as the verb), and use its `.repo`; `null` → `That checkout has no GitHub origin — nothing changed.` and stop.

```bash
gh api "repos/<owner/name>/issues/<N>" --jq '[.state, (.pull_request != null)] | @tsv'
```

- `open` and `false` → fine.
- `closed` → `#N is closed — nothing changed.` A pull request (`true`) → `#N is a pull request, not an issue — nothing changed.` A failed call (no such issue) → `#N is not an issue in <owner/name> — nothing changed.`

Check every issue before writing anything: a `top` is all or nothing.

## 3. Run the helper

<!-- test-anchor: desk-priority-run -->

```bash
PRIO=""
for c in "$HOME/.claude/skills-worktree/.claude/scripts/pm-priority.sh" "$HOME/.claude/scripts/pm-priority.sh"; do
  if [ -x "$c" ]; then PRIO="$c"; break; fi
done
if [ -z "$PRIO" ]; then
  echo "ERROR: pm-priority.sh not found (checked ~/.claude/skills-worktree/.claude/scripts and ~/.claude/scripts) — desk priorities unavailable"
else
  "$PRIO" <TARGET> <VERB>; echo "exit=$?"
fi
```

- `<TARGET>` is step 1's flag, or nothing.
- `<VERB>` is one of `top 12 4 9`, `bump 12`, `park 12 --until <date>`, `drop 12`, or `show`. `in N days` becomes `--until +Nd`; every other date passes through as typed (`tomorrow`, `friday`, `2026-10-09`): the helper turns it into a date, in America/New_York, so the date rule lives in one place.
- Only the verb, the digits, the date word, and step 1's target go into the command, never the rest of the operator's message.

## 4. Output

Print the helper's output without the final `exit=0` line, and nothing else: no "Desk live …" line, no queue counts, no menu (`history.md`'s output rule). A write prints one line naming the change, then the order and the parked issues as they now stand. Then go back to where the operator was: a waiting long-form prompt prints its card again (`longform.md`), and a discussion continues (`discuss.md`).

| Result | Say |
|---|---|
| `exit=2` | Its one stderr line (a usage error, such as a date that is not later than today, a word that is not a date, a bad number, or a malformed `owner/name`) |
| `exit=3` | `No local checkout of <owner/name> found — end the command with "in /path/to/checkout".` |
| `exit=4` | `The priority file is unreadable (<its one line>); nothing changed. /pm launches nothing on its own until it is fixed or removed.` |
| `exit=5` or `exit=6` | `Couldn't write the priority file (<its one line>) — nothing changed; try again.` |
| The `ERROR:` line | Print it as is |
