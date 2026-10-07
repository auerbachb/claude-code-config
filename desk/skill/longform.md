# /desk — long-form and multipart Decisions

Loaded by `decisions.md` once a batch's menus are done ("Showing items", step 4), and by `SKILL.md` when the operator replies while a long-form prompt waits. Every Bash block starts with `SKILL.md`'s prelude (`DESK`, `HQ`, `SID`, `SESSION_STATE_SH`). Issue #1780; design: `desk/DESIGN.md` 2.6 ("Long-form questions come one at a time: write, hit return, routed. Multipart questions come piece by piece").

## What is long-form

`desk_split` in `desk.jq` (run by `decisions.md`, "Showing items" step 2) decides it, one predicate for both views. A Decision is **long-form** when a menu cannot hold it: no options (the answer is the operator's own words), one option, more than four, or a declared cost in hours, days, or weeks (`2h`, `1h30`, `half a day`). Everything else is a menu question.

A **multipart** Decision is a group of long-form Decisions that share a repo, a key, and a return address: one thread asking several things about one PR or issue. The store has no parts field; the capture hook already stores a multi-question ask as one Decision per question. `desk_split` returns the long-form ids already grouped, `"longform": [["D-45"], ["D-47", "D-48", "D-53"]]`, in the list's order (parked, then impact, then age). A group of one is a single long-form Decision. Each part keeps its own id, its own answer, and its own wake-up, so leaving a group halfway loses nothing already answered. For a tick event, a named part brings its whole open group, named or not: the capture hook adds a multi-question ask one Decision at a time, so a tick can land between two parts, and the later one must not arrive alone as part 1 of 1. A part left open earlier comes back with its group; `skip` leaves it open again.

## Presenting a group

One group at a time, one part at a time, never two prompts on screen.

1. **Open the group's set:** `"$HQ" set-open D-47 D-48 D-53 --json`. It prints `{"set_id": 14, "items": [{"n": 1, "id": "D-47"}, …]}` and records one `shown` event per part. Part *k* is number *k*, so the latest set this session opened is again the one on screen: `discuss 2` and `2:` resolve against it, as in a menu. Exit 4 (`no item D-48; no set was opened`) → that id is gone: drop it and open the set again with the rest.
2. **Render part *k* of *m*** (*m* is the group's size; 1 for a single Decision):

   <!-- test-anchor: desk-longform-render -->

   ```bash
   ITEM=$("$HQ" get D-48 --json); rc=$?
   if [ "$rc" -eq 0 ]; then printf '%s\n' "$ITEM" | jq -r -L "$DESK/skill" --argjson k 2 --argjson m 3 'include "desk"; longform_prompt($k; $m)'; else echo "exit=$rc"; fi
   ```

   Print its output as the message, exactly, and end the turn (after `SKILL.md`'s end-of-turn gate): the operator's next message is the reply. It is plain text, **never AskUserQuestion**: the answer cannot be enumerated (`ask-menu.md`'s prose exception), and a menu here would be captured as a brand-new Decision. The card is a blockquote because it quotes the asking thread's question; #1778's prose-question nudge reads a blockquote as a quotation, so the desk's own prompt is never mistaken for a question asked in prose.
   - The output is `D-48 is answered now, so it is skipped.` (answered or closed meanwhile, from another desk or a typed reply) → go to the next part without waiting.
   - `exit=4` (`no item D-48` on stderr) → the item is gone: next part. `exit=7` → the store is unreachable: say so in one line and present this part again after the next `recovered` event. `get` runs on its own first so a failure is never lost in the pipe to `jq`.

## Replies to a long-form prompt

While a prompt waits, read the operator's next message in this order:

1. **`skip`** or **`next`** (alone, any case) → nothing is stored and the item stays open: one line, `D-48 left open — type "D-48: …" any time.` Then the next part. **`skip all`** leaves this part and every remaining long-form item open for now.
2. **`discuss`**, `discuss <n>`, or `discuss D-<id>` → load `discuss.md` (a bare `discuss` names this part).
   **`show D-<n>`** or **`history`** as the whole message → `history.md`, then print this part's card again. Nothing is stored.
3. **A reply for another item**: the message starts with `D-<n>:` naming a different item → handle it as a typed reply (`decisions.md`, "Typed replies"; a long-form one goes through "Storing an answer" below), then print this part's card again.
4. **This item, addressed**: the message starts with this part's own `D-<n>:` → the answer is the text after that colon.
5. **Anything else is the answer**: the whole message, as typed. A long answer may hold numbered lines (`1: …`, `2: …`), commas, or quotes; they are part of the answer, never split into replies.

## Storing an answer

The answer goes to the store **word for word**: copy the operator's message into the here-document character for character. Never summarize it, fix its typos, reflow it, or add quotes or escapes. Two things the CLI does on its own are the only changes: leading and trailing blank space is dropped (including the newline the here-document ends with), and a message that is a single letter on an item with options stores that option's text. Inside a quoted here-document nothing expands, so `$(…)`, backticks, and backslashes arrive as typed, and `--stdin` keeps the text off the command line, so no shell quoting or reply parsing touches it:

<!-- test-anchor: desk-longform-answer -->

```bash
"$HQ" answer D-48 --stdin --json <<'DESK_ANSWER'
<the operator's message, exactly as typed>
DESK_ANSWER
echo "exit=$?"
```

If the message contains a line that is exactly `DESK_ANSWER`, pick another delimiter for both lines. Everything between the first and last non-blank character arrives byte for byte; `B` alone on an item with options stores option B's text.

- **Exit 0** → `{"id": "D-48", "answer": "…", "changed": true, "session": "…"}`, the shape `decisions.md`'s wake rule reads. Wake the asking thread now, before the next part ("Waking the asking threads": only when `changed` is true and `session` is not `SID`), so a thread parked on one part never waits on the rest of the group. Then one line, `Stored D-48; thread woken.` (or the wake-up's failure, worded as `decisions.md` words it), and the next part.
- **Exit 4** → nothing was written. Show its one stderr line and print this part's card again: an answer `longer than 4000 characters` (the store's limit) is shortened by the operator, and a `control character` is usually a pasted terminal escape. `no item D-48`: the item is gone, so move on without the card.
- **Exit 5** → `That answer looked like a credential, so it was not stored — answer D-48 again without it.` Then the card again.
- **Exit 7** → the store is unreachable; nothing was written. Keep the message in this conversation, exactly, say `Store unreachable — D-48's answer is kept here and stored once the store is back.`, and run this block with it after the next `recovered` event. Exit 1 (an unexpected store error) → show the CLI's line, keep the message the same way, and run the block with it again at the next tick.

## When a group ends

After its last part is answered, skipped, or found closed: one line naming what is still open (`D-53 left open.`), when anything is. Then the next group. When none is left, the long-form view is done until the next `new` event.

## Tick events while a prompt waits

A `desk-tick <GEN> new …` event that arrives while a long-form prompt waits is held, not shown: a menu would land on top of a half-written answer. Keep its ids in this conversation and say nothing; once this group ends (or after `skip all`), show them through `decisions.md`, "Showing items". An id already on screen or already held is not queued twice: a worker re-asking bumps the item, and the tick reports it again.

A `desk-tick <GEN> retry …` event is handled at once (`wakeups.md`), because a retry shows nothing. A parked notice that it produces is held the same way and printed when the group ends.

## A typed `D-<n>: …` for a long-form item

`decisions.md` sends a reply here when it is a single `D-<n>: …` pair for a long-form item (the item's `get --json` piped through `jq -L "$DESK/skill" 'include "desk"; menu_shaped'` prints `false`). Store the text after `D-<n>:` with "Storing an answer" — never through `set-resolve`, which would split a long answer at a later line that starts `2:` — and wake the same way. It needs no set: `answer` takes the id.
