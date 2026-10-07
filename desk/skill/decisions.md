# /desk — simple Decisions: sets, menus, replies, answers, wake-ups

Loaded by `SKILL.md` on a `desk-tick … new` event, at start (the backlog), and when the operator types a reply. Every Bash block starts with `SKILL.md`'s prelude (`DESK`, `HQ`, `SID`, `SESSION_STATE_SH`). Issue #1779; design: `desk/DESIGN.md` 2.6, 4.2.4, 4.2.5.

## Showing items

1. **Read the items.** `"$HQ" list --kind decision --status open --json` prints every open Decision, already in the set order the design asks for: parked first, then impact, then age (`desk/DESIGN.md` 4.2.5). For a tick event, keep only the ids the event named (a named long-form part brings the rest of its open group: `longform.md`, "What is long-form"); for the start backlog, keep them all. An id the list no longer has was answered or closed in the meantime: drop it.
2. **Split simple from long-form.** A Decision is **simple** when it has 2 to 4 options and its declared cost (if any) is not in hours, days, or weeks. Only simple ones render here, as menus. The rest are **long-form** (`longform.md`): no options, one option, more than four, or a cost such as `2h`, `1h30`, or `half a day`. They come one at a time as text prompts, grouped into multipart items. The predicate is `desk_split` in `desk.jq`, shared with `longform.md`:

   <!-- test-anchor: desk-split -->

   ```bash
   ITEMS=$("$HQ" list --kind decision --status open --json); rc=$?
   if [ "$rc" -eq 0 ]; then printf '%s\n' "$ITEMS" | jq -c -L "$DESK/skill" --arg ids "<the event's ids, or empty for all>" 'include "desk"; desk_split($ids)'; else echo "exit=$rc"; fi
   ```

   It prints `{"simple": ["D-43", "D-44"], "longform": [["D-45"], ["D-47", "D-48"]]}`: the simple ids in list order, and the long-form ids as groups (one array per multipart item). `list` runs on its own first so its exit status is not lost in the pipe: `exit=7` means the store is unreachable (say so in one line and show this batch after the next `recovered` event), any other `exit=<n>` is the CLI's one stderr line to report.

3. **Open and render one set at a time, up to four items each.** Four questions per menu is the question tool's limit (`desk/DESIGN.md` 4.2.4). Take the simple ids in order, four at a time. Open a set for the **next chunk only**:

   ```bash
   "$HQ" set-open D-43 D-44 --json
   ```

   It prints `{"set_id": 12, "items": [{"n": 1, "id": "D-43"}, {"n": 2, "id": "D-44"}]}` and records one `shown` event per item. Numbering starts at 1 in every set. Keep the set id: every reply to this menu names it. Render that set at once as one AskUserQuestion call ("The menu" below). Open the following chunk's set only after the operator has answered or dismissed this menu. Never open every chunk up front: the latest set this session opened must always be the one whose menu is on screen, because typed numbers (`2: B`) resolve against it ("Typed replies").
4. **Long-form groups come after the menus**, never as a menu: once this batch's last set is answered or left open, load `longform.md` and follow "Presenting a group" for the `longform` groups, one at a time. A batch with no simple items goes there at once.

## The menu

One question per item, in set order. For item `n` with id `D-<k>`:

- **question**: `<n>. [D-<k>] <the item's question>`, then ` — ` and its context lines joined by ` · ` when it has any, then ` (<repo> · <key>)`. The prefix is exact: a number, a dot, a space, the id in square brackets, a space. The capture hook recognises that prefix in the desk's own session as an item being shown again and does not queue it a second time; any other wording would be captured as a brand-new Decision.
- **header**: at most 12 characters, the tool's limit: `<n> · D-<k>` when that fits (ids up to six digits), else `D-<k>` alone when that fits, else `<n>`. The question's own prefix always carries the full id.
- **options**: the item's own options, each label `<letter>. <option text>` with `A` for the item's first option, cut to about 60 characters with `…`. The description carries the full option text. The **recommended default first**: move the option equal to `default_option` to the top and end its label with ` (Recommended)`; its description adds `default — taken <default_at> if unanswered` when `default_at` is set. A captured option often already ends in `(Recommended)` (the asking thread's own label, stored as is): drop that suffix from every label first, so the marker appears once and only on the default. The letters stay the item's own, so a moved default may read `B. …` above `A. …`: the letter is what the answer records.
- **multiSelect**: true when the item's `context` holds the line `More than one option may be chosen.` (the capture hook's note for a multi-select question; `desk/README.md`, "What a Decision carries"), else false. The tool adds "Other" for a free-text answer either way.

A menu the operator dismisses answers nothing: the items stay open, and silence is never consent. Say `Set <set_id> left open — reply "1: A" any time.` and move to the next set.

## Turning the menu into a reply

Build one reply from the operator's choices, one line per answered item, in set order:

- a chosen label `<letter>. …` → `<n>: <letter>`
- several chosen labels (a multi-select item) → `<n>: <option text> | <option text>`: the chosen options' full texts in letter order, joined by ` | `. `set-resolve` stores that as the free-text answer, which is what the asking thread reads; a single letter could name only one option
- an "Other" text → `<n>: <the text as typed>`
- an "Other" text that is `discuss`, `discuss <n>`, or `discuss D-<id>` → no line: it is not an answer. Resolve the rest of the reply, then load `discuss.md` for it (a bare `discuss` names this question's item)
- an item left unanswered → no line

When at least one line remains, resolve it against **this** set (always pass `--set`: the default is the newest set in the store, which may be another desk's). When none does (the only choice was a `discuss` text, or nothing was answered), skip `set-resolve`, which refuses an empty reply, and go straight to `discuss.md` (or, with no `discuss` either, treat the menu as dismissed, as "The menu" says).

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

The operator may type instead of clicking, at any time: `2: B`, `1: A, 2: C`, `D-43: B`, `1: yes, but after CI; 3: use staging`. Pass the message **verbatim** as the reply, against the latest set this session opened (the set whose menu was shown last: sets open one at a time, "Showing items" step 3), through the same here-document as above (never inside the command's quotes):

```bash
REPLY_FILE=$(mktemp "${TMPDIR:-/tmp}/desk-reply.XXXXXX")
cat > "$REPLY_FILE" <<'DESK_REPLY'
<the operator's message, verbatim>
DESK_REPLY
"$HQ" set-resolve "$(cat "$REPLY_FILE")" --set <latest set_id> --json; rc=$?; rm -f "$REPLY_FILE"; echo "exit=$rc"
```

`set-resolve` itself accepts numbers and ids (an id must be in that set), keeps commas and line breaks inside an answer, and refuses the whole reply when any pair is wrong. Handle its exits as above.

A reply that is a single `D-<n>: …` pair for a **long-form** item goes to `longform.md` instead ("A typed `D-<n>: …` for a long-form item"): `set-resolve` would split a long answer at a later line that starts `2:`.

Any other id that is not in the latest set this session opened (one from before this desk started, from an earlier set, or left open earlier) gets a set of its own, so its answer comes back with `changed` and `session` like any other and the wake-up rule below applies unchanged: `"$HQ" set-open D-45 --json`, then resolve that pair (`D-45: <the answer>`) against the new set id with the here-document above. A reply that mixes such an id with pairs for the latest set is refused whole (`D-45 is not in set 12`, nothing written): split it, resolving the latest set's pairs there and each other id in its own set.

## Waking the asking threads

For each answer with `"changed": true` (an unchanged answer was delivered before) whose `session` is not `SID` (the desk's own questions need no wake-up). A `session` of null has no return address: record `failed` (step 3) with note `no return address` and skip steps 1–2.

1. **Find the address** of the session that asked. Items carry the Claude Code session id; messaging needs the running session's address:

   <!-- test-anchor: desk-wake-target -->

   ```bash
   "$DESK/bin/wake-target.sh" "<session>" --json
   ```

   - Exit 0 → `{"address": "local_…", "via": "host", "name": …}` (a desktop-app session) or `{"address": "<session name>", "via": "name"}` (a terminal session).
   - Exit 3 → no running session has that id: the thread has ended. Record `failed` (step 3) with note `no running session`.
   - Exit 5 → the session **is** running but has no messaging address (no `local_…` id and no name). Record `failed` with note `session running, no messaging address`; it reads its answer from `pending-for` the next time it checks.
   - Exit 1 → the registry could not be read well enough to tell (its one stderr line says why). Record `failed` with that line as the note.
2. **Send exactly** `human-queue: D-<k> answered` — a pointer, never the answer: the thread reads the store (`pending-for`). Use `SendMessage` with `to` = the address (load it with ToolSearch when it is deferred). When `SendMessage` is not available and `via` is `host`, use `mcp__ccd_session_mgmt__send_message` with `session_id` = the address. Neither available → record `failed` with note `no session-messaging tool in this session`.
3. **Record what happened**, every time, whatever it was:

   <!-- test-anchor: desk-wake-record -->

   ```bash
   "$HQ" wake D-43 --result sent --note "SendMessage to local_…: delivered" --json
   "$HQ" wake D-43 --result failed --note "no running session" --json
   ```

   `sent` only when the tool's result confirms the message reached the session (`delivered`, `queued`, or held for that session's approval: say which in the note). An error, a refusal, or no result → `failed`, with the tool's reason in one line (at most 200 characters). Never report a wake-up the tool did not confirm. A note that quotes a tool's own words goes through the same quoted here-document as a reply (`--note "$(cat "$NOTE_FILE")"`), never inside the command's quotes.

   It prints `{"id", "result", "failures", "retries_left", "status", "parked"}`. `"parked": true` (an answer with no return address parks on its first failure) → `wakeups.md`, "The parked notice". Exit 7 or 1 → `wakeups.md`, "A wake-up the store did not record".

**Retries.** A failed wake-up is retried on each of the next three ticks (`wakeups.md`). The record in step 3 is what counts the attempts, so it is made every time. When the last retry fails too, the answer is parked for the next thread on that PR or issue and shown once. Either way the answer is already durable, and a thread that wakes later reads it from `pending-for`.

**What the operator sees.** One line for the whole reply: `Answered D-43, D-44; both threads woken.` A failed wake-up names it with its reason: `Answered D-43, D-44; D-44's thread is not running — retrying at the next ticks; the answer is safe in the store.` (exit 3), or `… D-44's thread is running but has no messaging address — retrying at the next ticks; it reads the answer from the store when it next checks.` (exit 5).
