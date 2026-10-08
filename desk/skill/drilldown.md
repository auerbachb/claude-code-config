# /desk — PR drill-down: `outline`, `open R-<n> <node>`, `ask`

Loaded when the operator's whole message is a drill-down verb (`SKILL.md`, "Replies the operator types"). Below the Reviews view's level 3 (`reviews.md`: one diff, pasted whole), the drill-down makes a PR addressable: a numbered tree of its files, their hunks, and the tests that touch them; any node opened with context; and questions answered from just the nodes they need. Every Bash block starts with `SKILL.md`'s prelude. Issue #1768; design: `desk/DESIGN.md` 2.5 (summaries lazy, the diff never stored).

| The operator types | What happens |
|--------------------|--------------|
| `outline R-<n>` | The numbered tree: files `1, 2, …` with `+added -deleted`, their hunks `2.1, 2.2, …` with line ranges and counts, the tests touching each file as leaves, then `Tests` (`T1, T2, …` and their hunks) |
| `open R-<n> <node> [<node> …]` | Each node opened: a hunk (`2.3`, `T1.2`) with twenty more lines of context on each side, or a file (`2`, `T1`) as its whole diff |
| `ask R-<n>: <question>` | An answer from the outline plus the hunks it judged relevant, ending with the line naming every hunk it read |

`open R-<n>` with no node after it is the Reviews view's level 2 (`reviews.md`); one or more node ids after the R-number make it a drill-down.

## Rules for every verb

- **Nothing is stored.** Every verb rebuilds the outline from GitHub (`desk/bin/pr-outline.sh`, read-only) and shows it in the reply only. A block here runs `"$HQ" get` (a read) and the helper, nothing else: no `summary set`, no `comment`, no `flag`, no `review`, no `state set`, and no file that outlives the block. Numbers are rebuilt on every call: a merged PR's never change; an open PR that was pushed to since may renumber, so the outline's `head` SHA is the one to cite.
- **Ids are checked before they reach a block.** The R-number is `R-<digits>`; a node is `2`, `2.3`, `T1`, or `T1.2` (`T?[1-9][0-9]{0,5}(\.[1-9][0-9]{0,5})?`, the helper's own pattern: no `0`, no leading zero, at most six digits a part). Anything else → one line, `Node ids look like 2, 2.3, T1, or T1.2 — "outline R-<n>" lists them.`, and no block runs. The question in `ask` never goes into a command: it stays in this conversation.
- **Plain text only, never AskUserQuestion.** In the desk's own session the capture hook queues any menu that does not carry the desk's `N. [D-id]` prefix as a new Decision.
- **No state line.** Print what was asked for and nothing else (`desk/DESIGN.md` 4.1.4).
- **The same exits for every block.** `exit=7` → `Store unreachable — can't <verb> right now.` `exit=4` from `get` (alone, no header before it) → `R-2: no such Review.` `kind=issue` → `R-2 is an issue: it has no diff. "open R-2" shows its summary, "diff R-2" its full body.` From the helper (its `exit=` comes after the header lines): `exit=3` → its stderr line, which names the PR that is gone or the node the outline lacks and the ids it does have (say it in one line, e.g. `R-2 has no hunk 2.9: file 2 has 2.1-2.4.`); `exit=4` → its stderr line in one line (a node id the check above should have stopped, or an `HQ_OUTLINE_CONTEXT` that is not 1 to 500); `exit=1` → `Couldn't load R-2 from GitHub (<the line>).` Nothing is retried in a loop.
- Remember R-2 as the item on screen, for a bare `reviewed` (`reviews.md`).

## `outline R-<n>`

<!-- test-anchor: desk-outline -->

```bash
ITEM=$("$HQ" get R-2 --json); rc=$?
if [ "$rc" -ne 0 ]; then echo "exit=$rc"; else
  KEY=$(printf '%s\n' "$ITEM" | jq -r .key)
  case "$KEY" in
    issue-*) echo "kind=issue" ;;
    *)
      printf '%s\n' "$ITEM" | jq -r -L "$DESK/skill" 'include "desk"; review_header'
      "$DESK/bin/pr-outline.sh" "$(printf '%s\n' "$ITEM" | jq -r .repo)" "$KEY"; echo "exit=$?"
      ;;
  esac
fi
```

`exit=0` → print the header lines, then the outline in a ```` ```text ```` fence exactly as printed, then one hint line: `open R-2 2.3 for a hunk, open R-2 2 for a file · ask R-2: <question>`. The shape, for reference:

```text
PR acme/widgets#505 · head 5a5e505 · 5 files · +16 -5
1 docs/guide.md · modified · +1 -1
  1.1 lines 3-9 · +1 -1
  test T2 tests/gizmo_test.sh · +2 -0
2 src/widget.sh · modified · +6 -3
  2.1 lines 1-5 · +1 -1
  2.2 lines 28-35 · +2 -0
  2.3 lines 44-51 · +2 -1 · widget_count()
  2.4 lines 110-116 · +1 -1
  test T1 tests/widget.test.sh · +6 -0
3 src/gadget.sh → src/gizmo.sh · renamed · +1 -1
  3.1 lines 2-8 · +1 -1
  test T2 tests/gizmo_test.sh · +2 -0

Tests
T1 tests/widget.test.sh · added · +6 -0 · touches 2
  T1.1 lines 1-6 · +6 -0
T2 tests/gizmo_test.sh · modified · +2 -0 · touches 1, 3
  T2.1 lines 4-10 · +2 -0
```

A file GitHub sent no patch for says so on its line (`no patch (binary, or too large for GitHub to show)`) and has no hunks; `patch incomplete` means GitHub cut the file's patch short, so its hunks are not the whole change: say so when it matters. A `GitHub listed N of M changed files` line means the outline is partial. A test is a changed file in a test folder or with a test name; it hangs under a file when their names match or its diff names that file. Only tests this PR changes appear.

## `open R-<n> <node> [<node> …]`

The nodes go into the block's last line as separate words, in the operator's order (`2.3`, or `2.3 2.4 T1.1`):

<!-- test-anchor: desk-open-node -->

```bash
ITEM=$("$HQ" get R-2 --json); rc=$?
if [ "$rc" -ne 0 ]; then echo "exit=$rc"; else
  KEY=$(printf '%s\n' "$ITEM" | jq -r .key)
  case "$KEY" in
    issue-*) echo "kind=issue" ;;
    *)
      printf '%s\n' "$ITEM" | jq -r -L "$DESK/skill" 'include "desk"; review_header'
      "$DESK/bin/pr-outline.sh" "$(printf '%s\n' "$ITEM" | jq -r .repo)" "$KEY" 2.3; echo "exit=$?"
      ;;
  esac
fi
```

`exit=0` → print the header lines, then each node: its `=== 2.3 …` line as plain text, then the rest in a ```` ```diff ```` fence exactly as printed. A hunk comes widened to twenty lines of context on each side as one hunk with its own `@@` line, stopping early at a neighbouring hunk (`(context above stops at hunk 2.2)`, so a line from 2.2 never shows as plain context) or at the file's edge. `(more context unavailable: …)` means the hunk is shown as GitHub gave it; say why in one line after the fence. A file node is its whole diff, a `[2.1]` line before each hunk. When this conversation already showed R-2's outline and the `head` on the `===` lines is a different SHA, the PR was pushed to since and its numbers may now point elsewhere: say so in one line before the nodes (`R-2 moved to head <sha> since its outline: "outline R-2" renumbers it.`). Then the hint line: `ask R-2: <question> · outline R-2`.

## `ask R-<n>: <question>`

An answer from the PR itself, loading only the parts the question needs. The outline and the opened hunks are working material: do not print them.

1. **Outline.** Run the `outline` block (`desk-outline`) for R-<n>. Its exits are the rules above: an issue, an unknown Review, or GitHub failing ends the `ask` with that one line.
2. **Choose the nodes.** From the outline's paths, hunk headings, line counts, and test names, pick the hunks the question is about: usually two to six. Prefer hunks to whole files; open a whole file only when the question is about the file as a whole. A question about testing reads the `T` nodes.
3. **Open them in one call**: the `open` block (`desk-open-node`) with every chosen id on its last line.
4. **Check the head.** Every `===` line's `head` must be the outline's `head`. If one differs, the PR was pushed to between the two calls and the ids may now name other hunks: discard what was opened, run the outline again (step 1), choose again (step 2), and open again (step 3). Never answer from, or name on the `Read:` line, a node read under another head. If the head moves again, say the PR is being pushed to right now and stop.
5. **Answer from what was read.** Plainly and briefly, citing node ids where they carry the point (`2.3 keeps both facts because …`). If what was read does not settle it, open more nodes (steps 3 and 4 again) or say exactly what is missing; never fill a gap from memory of the codebase or a guess, and never call it settled when the hunks do not show it.
6. **End with the `Read:` line**, every node opened for this answer in the order opened, and the head SHA from their `===` lines (the outline's, after step 4):

   ```text
   Read: 2.3, 2.4, T1.1 · head 5a5e505
   ```

   An answer without this line is incomplete. A follow-up question about the same R-number may reuse what is already open in this conversation while every node it names carries the same head; its `Read:` line names the nodes that answer used, opened now or earlier.

Load the whole diff (`diff R-<n>`) only when the operator asks for it.
