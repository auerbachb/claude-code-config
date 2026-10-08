# /desk — the end-of-day sweep

Loaded on a `desk-tick <GEN> eod` event, and when the operator's whole message is `sweep` (any case); `export` after a sweep is `export.md`. Every Bash block starts with `SKILL.md`'s prelude (`DESK`, `HQ`, `SID`). Issue #1784; design: `desk/DESIGN.md` 2.8, 5.5 ("at 5:30 the sweep lists what is left; you export it to paper"), and figure 5.4.

**When.** `desk-tick.sh` asks the store once the clock passes `desk/policy.json`'s `eod_time` (17:30 America/New_York by default): `human-queue.sh sweep due` marks the day, so the `eod` event comes once a day, and a desk started after `eod_time` sweeps at its first tick. `sweep` shows the same list at any time.

**Held like a Decision.** An `eod` event that arrives during `away`, a focus, or a plan block (`interrupts.md`) is kept in this conversation and shown after the release, as a parked notice is. One that arrives while a long-form prompt waits is shown when that group ends (`longform.md`, "Tick events while a prompt waits").

## The sweep

Everything still open, as **one numbered list**: open Decisions first (parked, then impact, then age), then unreviewed Reviews (oldest first), at most 99. The list is opened as a set, so its numbers are what typed replies resolve against (`2: B`, `decisions.md`, "Typed replies"), on screen and on the paper `export` prints.

<!-- test-anchor: desk-sweep -->

```bash
SWEEP_JSON=$(mktemp "${TMPDIR:-/tmp}/desk-sweep.XXXXXX"); SWEEP_SET=$(mktemp "${TMPDIR:-/tmp}/desk-sweep-set.XXXXXX")
rc=0; set_rc=0
"$HQ" sweep list --json > "$SWEEP_JSON" || rc=$?
if [ "$rc" -eq 0 ] && [ "$(jq '.items | length' "$SWEEP_JSON")" -gt 0 ]; then
  "$HQ" set-open $(jq -r '.items[].id' "$SWEEP_JSON") --json > "$SWEEP_SET" || set_rc=$?
  if [ "$set_rc" -ne 0 ]; then echo "set-open exit=$set_rc"; : > "$SWEEP_SET"; fi
fi
if [ "$rc" -eq 0 ]; then
  jq -r -L "$DESK/skill" --slurpfile set "$SWEEP_SET" 'include "desk"; sweep_view($set[0])' "$SWEEP_JSON"
fi
rm -f "$SWEEP_JSON" "$SWEEP_SET"; echo "exit=$rc"
```

- **Exit 0** → print the card as is: `**End of day · 6 items still open · set 31**`, then `1. D-44 · Retry the flaky upload test once? (widgets · pr-12) · parked`, …, `5. R-9 · Issue #202 · <its line>`, then one line: reply by number or id, and `Take it to paper: say export for a numbered PDF (#1759).` Keep the set id in this conversation (`export` prints that set on paper, `export.md`); the set is now the latest set this session opened (`decisions.md`). With nothing open the card is one line, `End of day: nothing is open.`, and no set is opened.
  An item that carries the operator's own priority, tags, or note (`todo.md`, #1769) has one nested line under it, `   - P2 · tags: prd · note: ask Sam first`, on the card and in the paper copy alike.
- **`set-open exit=<n>`** → the list could not be numbered in the store: the card numbers it in list order, says so, and replies use ids.
- **Exit 7** → `Can't reach the store — the end-of-day sweep shows once it is back.` Run this block again after the next `recovered` event (the store has marked the day, so no second `eod` event comes).

The sweep stores nothing but the set (`shown` events, one per item). It answers nothing and wakes nobody.

## Friday: the weekly report

After the card for an `eod` event's sweep (never a typed `sweep`), including the one-line `End of day: nothing is open.` card but not after an exit 7, check the day (issue #1771):

<!-- test-anchor: desk-sweep-friday -->

```bash
if [ "$(TZ=America/New_York date +%u)" = 5 ]; then echo "offer=report"; else echo "offer=none"; fi
```

- **`offer=report`** → one more line under the card: `It's Friday: say report for this week's attention report.` The `eod` event comes once a day and a typed `sweep` never offers, so the offer comes once a week. When the operator says `report`, the router loads `attention.md` (`SKILL.md`, "Replies the operator types").
- **`offer=none`** → nothing more.

## `export`

`export` after a sweep → load `export.md` (issue #1759): it prints this sweep's set on paper at the numbers on the card (`--set <the set id>`; with no set, the sweep's ids in its order), as a numbered PDF, or as Markdown when this machine has no PDF renderer, and closes with the file's path. With nothing open, or the store down at the sweep, there is nothing to export: say so.
