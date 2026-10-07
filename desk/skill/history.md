# /desk — `show D-<n>` and `history`

Loaded when the operator's whole message is `show D-<n>` (`show d-43` is accepted) or `history` (`history 2026-10-06` for another day). That holds at any time: after a menu, while a long-form prompt waits, or during a discussion. Both are read-only and write nothing to the store. Every Bash block starts with `SKILL.md`'s prelude. Issue #1781; design: `desk/DESIGN.md` 2.5 (state changes only, never transcripts) and 4.1.4 (no state line printed unasked).

## Output rule

Print the CLI's output and nothing else. No "Desk live …" line, no queue counts, no tick age, and no menu, before or after it: the operator asked for one item or one list, and the desk's state line appears only when asked for. Then go back to where the operator was. A waiting long-form prompt prints its card again (`longform.md`), and a discussion continues (`discuss.md`).

## `show D-<n>`: the item's sub-thread

<!-- test-anchor: desk-show -->

```bash
"$HQ" show D-43; echo "exit=$?"
```

It prints the item the way `get` does: the header with its status, the question, context, options, default, facts, and answer. Then comes `Events:`, one line per event, oldest first, each with its note: asked, bumped, shown (`set 12 #2`), answered (`option B`), woken or wake-failed (the address, or the reason), answer-parked, acknowledged, feedback, commented. That is the whole sub-thread, because the store keeps state changes only, never a conversation. Print it as is, without the final `exit=0` line. A Review id (`R-88`) works the same way.

- `exit=4` with `no item D-43` on stderr → `show D-43: no such item.` With `invalid item id` → `show takes an id such as D-43.`
- `exit=7` → `Store unreachable — can't show D-43 right now.`

## `history`: today's answered items

<!-- test-anchor: desk-history -->

```bash
"$HQ" history; echo "exit=$?"
```

It lists every Decision answered today, once each, in answer order, whatever happened to it since (acknowledged, still waiting, parked). "Today" is the America/New_York calendar day on the store's clock. Each item is one block: `D-43 · answered 14:02 ET · acknowledged · <repo> · <key>`, then the question in bold, then the answer. For another day, run `"$HQ" history --date 2026-10-06`.

- Nothing before `exit=0` → one line: `Nothing answered today.` (or `Nothing answered on 2026-10-06.`).
- `exit=4` (a bad date) → its one stderr line. `exit=7` → `Store unreachable — can't list today's answers right now.`
