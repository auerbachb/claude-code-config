# /desk — simple Decisions: sets, menus, replies, answers, wake-ups

Loaded by `SKILL.md` on a `desk-tick … new` event, at start (the backlog), and when the operator types a reply. Every Bash block starts with `SKILL.md`'s prelude (`DESK`, `HQ`, `SID`, `SESSION_STATE_SH`). Issue #1779; design: `desk/DESIGN.md` 2.6, 4.2.4, 4.2.5.

## Showing items

1. **Read the items.** `"$HQ" list --kind decision --status open --json` prints every open Decision, already in the set order the design asks for: parked first, then impact, then age (`desk/DESIGN.md` 4.2.5). For a tick event, keep only the ids the event named; for the start backlog, keep them all. An id the list no longer has was answered or closed in the meantime: drop it.
2. **Split simple from held.** A Decision is **simple** when it has 2 to 4 options and its declared cost (if any) is not in hours or days. Only simple ones render here. The rest are **held** for the long-form view (#1780): no options, one option, more than four, or a cost such as `2h` or `half a day`. Held items are not lost: they stay open in the store, and the operator can answer one by typing `D-<n>: <answer>` (see "Typed replies").

   <!-- test-anchor: desk-split -->

   ```bash
   "$HQ" list --kind decision --status open --json | jq -c --arg ids "<the event's ids, or empty for all>" '
     ($ids | split(" ") | map(select(. != ""))) as $want
     | [ .[] | select(($want | length) == 0 or (.id as $i | $want | index($i))) ]
     | def long: (.cost // "") | test("[0-9] *h\\b|hours?|hrs?\\b|days?"; "i");
       { simple: [ .[] | select((.options | length) >= 2 and (.options | length) <= 4 and (long | not)) | .id ],
         held:   [ .[] | select((.options | length) < 2 or (.options | length) > 4 or long) | .id ] }'
   ```

3. **Number them in sets of up to four.** Four questions per menu is the question tool's limit (`desk/DESIGN.md` 4.2.4). Take the simple ids in order, four at a time; for each chunk:

   ```bash
   "$HQ" set-open D-43 D-44 --json
   ```

   It prints `{"set_id": 12, "items": [{"n": 1, "id": "D-43"}, {"n": 2, "id": "D-44"}]}` and records one `shown` event per item. Numbering starts at 1 in every set. Keep the set id: every reply to this menu names it.
4. **Render each set** as one AskUserQuestion call ("The menu" below), one set at a time; the next set follows once the operator has answered or dismissed this one ("next" chains them).
5. **Held items** get one line after the menus, never a menu: `Held for the long-form view (#1780): D-45, D-47 — answer by typing "D-45: …".` Say it once per item, not every tick.

## The menu

One question per item, in set order. For item `n` with id `D-<k>`:

- **question**: `<n>. [D-<k>] <the item's question>`, then ` — ` and its context lines joined by ` · ` when it has any, then ` (<repo> · <key>)`. The prefix is exact: a number, a dot, a space, the id in square brackets, a space. The capture hook recognises that prefix in the desk's own session as an item being shown again and does not queue it a second time; any other wording would be captured as a brand-new Decision.
- **header**: `<n> · D-<k>` (at most 12 characters).
- **options**: the item's own options, each label `<letter>. <option text>` with `A` for the item's first option, cut to about 60 characters with `…`. The description carries the full option text. The **recommended default first**: move the option equal to `default_option` to the top and end its label with ` (Recommended)`; its description adds `default — taken <default_at> if unanswered` when `default_at` is set. A captured option often already ends in `(Recommended)` (the asking thread's own label, stored as is): drop that suffix from every label first, so the marker appears once and only on the default. The letters stay the item's own, so a moved default may read `B. …` above `A. …`: the letter is what the answer records.
- **multiSelect**: false. The tool adds "Other" for a free-text answer.

A menu the operator dismisses answers nothing: the items stay open, and silence is never consent. Say `Set <set_id> left open — reply "1: A" any time.` and move to the next set.

## Turning the menu into a reply

Build one reply from the operator's choices, one line per answered item, in set order:

- a chosen label `<letter>. …` → `<n>: <letter>`
- an "Other" text → `<n>: <the text as typed>`
- an item left unanswered → no line

Then resolve it against **this** set (always pass `--set`: the default is the newest set in the store, which may be another desk's).

**The reply never goes into the command line itself.** It holds the operator's own words, and an "Other" text or a typed reply can contain `"`, `$(…)`, or backticks that a double-quoted argument would break on or run. Write it through a quoted here-document (no expansion of any kind happens inside one), then pass the file's contents:

<!-- test-anchor: desk-resolve -->

```bash
REPLY_FILE=$(mktemp "${TMPDIR:-/tmp}/desk-reply.XXXXXX")
cat > "$REPLY_FILE" <<'DESK_REPLY'
<the reply, verbatim>
DESK_REPLY
"$HQ" set-resolve "$(cat "$REPLY_FILE")" --set <set_id> --json; rc=$?; rm -f "$REPLY_FILE"; echo "exit=$rc"
```

The reply goes between the two delimiter lines exactly as built or typed, with nothing escaped. If it contains a line that is exactly `DESK_REPLY`, pick another delimiter for both lines.

- Exit 0 → `{"set_id": 12, "answers": [{"n": 1, "id": "D-43", "answer": "Ship now", "changed": true, "session": "…"}, …]}`. The answers are written, all in one transaction, through the same answer transaction as `human-queue.sh answer` (one `answered` event each). Go to "Waking the asking threads".
- Exit 4 → nothing was written. Show its one stderr line and ask again **only** for the item it names (a one-question menu, same number and id).
- Exit 5 → an answer looked like a secret and was not stored: `That answer looked like a credential, so it was not stored — answer <n> again without it.`
- Exit 7 → the store is unreachable; nothing was written. Keep the reply in this conversation, say so in one line, and resolve it again after the next `recovered` event.

## Typed replies

The operator may type instead of clicking, at any time: `2: B`, `1: A, 2: C`, `D-43: B`, `1: yes, but after CI; 3: use staging`. Pass the message **verbatim** as the reply, against the latest set this session opened, through the same here-document as above (never inside the command's quotes):

```bash
REPLY_FILE=$(mktemp "${TMPDIR:-/tmp}/desk-reply.XXXXXX")
cat > "$REPLY_FILE" <<'DESK_REPLY'
<the operator's message, verbatim>
DESK_REPLY
"$HQ" set-resolve "$(cat "$REPLY_FILE")" --set <latest set_id> --json; rc=$?; rm -f "$REPLY_FILE"; echo "exit=$rc"
```

`set-resolve` itself accepts numbers and ids (an id must be in that set), keeps commas and line breaks inside an answer, and refuses the whole reply when any pair is wrong. Handle its exits as above.

An id that is in no set this session opened (a held item, or one from before this desk started) gets a set of its own, so its answer comes back with `changed` and `session` like any other and the wake-up rule below applies unchanged: `"$HQ" set-open D-45 --json`, then resolve that pair (`D-45: <the answer>`) against the new set id with the here-document above. A reply that mixes such an id with pairs for the latest set is refused whole (`D-45 is not in set 12`, nothing written): split it, resolving the latest set's pairs there and each other id in its own set.

## Waking the asking threads

For each answer with `"changed": true` (an unchanged answer was delivered before) whose `session` is not `SID` (the desk's own questions need no wake-up). A `session` of null has no return address: record `failed` (step 3) with note `no return address` and skip steps 1–2.

1. **Find the address** of the session that asked. Items carry the Claude Code session id; messaging needs the running session's address:

   <!-- test-anchor: desk-wake-target -->

   ```bash
   "$DESK/bin/wake-target.sh" "<session>" --json
   ```

   - Exit 0 → `{"address": "local_…", "via": "host", "name": …}` (a desktop-app session) or `{"address": "<session name>", "via": "name"}` (a terminal session).
   - Exit 3 → no running session has that id: the thread has ended. Record `failed` (step 3) with note `no running session`.
2. **Send exactly** `human-queue: D-<k> answered` — a pointer, never the answer: the thread reads the store (`pending-for`). Use `SendMessage` with `to` = the address (load it with ToolSearch when it is deferred). When `SendMessage` is not available and `via` is `host`, use `mcp__ccd_session_mgmt__send_message` with `session_id` = the address. Neither available → record `failed` with note `no session-messaging tool in this session`.
3. **Record what happened**, every time, whatever it was:

   <!-- test-anchor: desk-wake-record -->

   ```bash
   "$HQ" wake D-43 --result sent --note "SendMessage to local_…: delivered"
   "$HQ" wake D-43 --result failed --note "no running session"
   ```

   `sent` only when the tool's result confirms the message reached the session (`delivered`, `queued`, or held for that session's approval: say which in the note). An error, a refusal, or no result → `failed`, with the tool's reason in one line (at most 200 characters). Never report a wake-up the tool did not confirm.

No retry in this increment: the answer is already durable, and a thread that wakes later reads it from `pending-for`. Retries and `answer-parked` are #1781.

**What the operator sees.** One line for the whole reply: `Answered D-43, D-44; both threads woken.` A failed wake-up names it: `Answered D-43, D-44; D-44's thread is not running — the answer waits in the store.`
