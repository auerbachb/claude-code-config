# /desk — `export`: a batch on paper

Loaded when the operator's whole message is an export verb below (`SKILL.md`, "Replies the operator types"), at any time: after a menu, after the end-of-day sweep, while a long-form prompt waits (it keeps waiting and is shown again after). The CLI writes the paper copy (`human-queue.sh export`, issue #1759); this page picks the batch and the file and says what came of it. Every Bash block starts with `SKILL.md`'s prelude. Design: `desk/DESIGN.md` 5.5 ("at 5:30 the sweep lists what is left; you export it to paper and dictate answers by number in the morning").

The operator reads long material on paper, marks it by pen, and dictates or types the answers back. The paper carries each item's id in its heading and the set's numbers, so `2: B` and `D-43: B` typed from it land on the right item (`decisions.md`, "Typed replies").

| The operator types | Exports | Flags |
|--------------------|---------|-------|
| `export`, right after a sweep in this conversation | That sweep's list, at the numbers on its card | `--set <the sweep's set id>` |
| `export` otherwise, or `export decisions` | Every open Decision (the pending batch), numbered as a new set | `--kind decisions` |
| `export reviews` | Every unreviewed Review, oldest first, with its twenty-line summary | `--kind reviews` |
| `export reviews level 1` | The same, one line each | `--kind reviews --level 1` |
| `export reviews today` | Only those synced today (`level 1` may follow) | `--kind reviews --today` |
| `export D-43 R-9 …` | Those items, in that order, numbered as a new set | `--ids D-43 R-9` |
| any of them, then `to <path>.pdf` | The same, written there | (the path, below) |

Item ids are `D-<n>` or `R-<n>` (any case); a word that is not one is not an id: `Export what? Say export, export decisions, export reviews, or export D-43 R-9.` A sweep whose list could not be numbered (`set-open exit=<n>`, `sweep.md`) has no set: its `export` uses `--ids` with the sweep's ids in its order.

## Rules

- **Plain text only, never AskUserQuestion.** In the desk's own session the capture hook queues any menu that does not carry the desk's `N. [D-id]` prefix as a new Decision.
- **The path never goes inside the command's own quotes.** It is the operator's own text: it goes through a quoted here-document, as `decisions.md` passes replies.
- **No state line.** Print the lines below and nothing else.
- **Exit 7** from any `"$HQ"` call → `Store unreachable — can't export right now.` Nothing is retried in a loop.

## 1. Reviews at level 2: write the missing summaries first

Only when the batch can hold Reviews at level 2: `export reviews` (without `level 1`), `export` after a sweep that listed a Review, or ids that name one. Summaries are written by the desk, lazily, the first time they are read; an export is a read. Ask the store which are missing:

<!-- test-anchor: desk-export-missing -->

```bash
"$HQ" export <the flags> --dry-run --json; echo "exit=$?"
```

Read the result in this order:

- `exit=4` → its one stderr line (`no item D-99; nothing was exported`, `no set 31`), and stop.
- `"count": 0` → `Nothing to export.` and stop.
- `"missing_summary": []` → step 2.
- Ids listed → say `Writing the twenty-line summary for <k> Reviews first.` and, for each, follow `reviews.md`, "`open R-<n>`: level 2, cached": its `desk-open` block loads the material, write the summary in the operator's shape, and cache it with its `desk-open-cache` block. Print nothing of it here: the summary is for the paper. One whose material fails (`exit=1` GitHub, `exit=3` gone) stays unwritten and prints its one-line summary on paper, marked; never stop the export over one item. Then step 2.

## 2. Export

The default file is in `~/.claude/desk-exports/` (only the operator can read it: it holds the open questions), named for the batch and the minute: `<what>` is `sweep`, `decisions`, `reviews`, or `items` (ids). With `to <path>`, the path goes between the delimiter lines verbatim; with none, that line is left empty.

<!-- test-anchor: desk-export -->

```bash
EXPORT_DIR="${HUMAN_QUEUE_EXPORT_DIR:-$HOME/.claude/desk-exports}"
PATH_FILE=$(mktemp "${TMPDIR:-/tmp}/desk-export-path.XXXXXX")
cat > "$PATH_FILE" <<'DESK_EXPORT_PATH'
<the path after "to", verbatim, or nothing>
DESK_EXPORT_PATH
OUT_PDF=$(head -n 1 "$PATH_FILE"); rm -f "$PATH_FILE"
case "$OUT_PDF" in
  "") mkdir -p "$EXPORT_DIR" && chmod 700 "$EXPORT_DIR"
      OUT_PDF="$EXPORT_DIR/desk-<what>-$(TZ=America/New_York date +%Y-%m-%d-%H%M%S).pdf" ;;
  "~/"*) OUT_PDF="$HOME/${OUT_PDF#"~/"}" ;;
esac
"$HQ" export <the flags> --out "$OUT_PDF" --json; echo "exit=$?"
```

If the path holds a line that is exactly `DESK_EXPORT_PATH`, pick another delimiter for both lines.

- **Exit 0** → the JSON says what was written. Reply in at most three lines, the path last:
  - `"new_set": true` → first `Numbered as set <set_id>: reply by number while it is the latest set here, or by id any time.` The set is now the latest set this session opened (`decisions.md`): typed numbers resolve against it.
  - `"more"` above 0 → `<more> more were left out (an export holds 99).`
  - `"format": "pdf"` → the path, alone on the closing line.
  - `"format": "markdown"` → `No PDF renderer here, so the Markdown is saved instead; open it to print:` then the path. (The `warning` names what each renderer did; `desk/README.md`, "Export to paper", says how to add one.)
  - `"path": null` → `Nothing to export.` (the batch is empty: nothing was written, no set opened).
- **Exit 4** → its one stderr line, once: an id with no item, a set that does not exist, or a path the CLI refused (`--out must name a .pdf file`, `--out's directory does not exist`). Nothing was recorded.
- **Exit 1** naming `migrate` → run `"$HQ" migrate; echo "exit=$?"` once, then this block again. Another `exit=1` → its one stderr line.

Every exported item gets one `exported` event (note `set N #k`); the export answers nothing and wakes nobody. A reply dictated or typed from the paper is an ordinary typed reply (`decisions.md`, "Typed replies"): numbers resolve against the latest set this session opened, which the paper's header names, and ids always work. The paper says so in its header.
