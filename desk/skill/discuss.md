# /desk — `discuss <n|D-id>`

Loaded when the operator types `discuss`, `discuss <n>`, or `discuss D-<id>`, at any time, or types one of them into a menu question's "Other" box (`decisions.md`, "Turning the menu into a reply"). A short sub-conversation about one item with its context loaded; it always ends by presenting the item again for an answer. Every Bash block starts with `SKILL.md`'s prelude. Issue #1780; design: `desk/DESIGN.md` 2.6 and mockup 6.2 ("Discussion · with this item's context loaded").

## 1. Find the item

- **`discuss D-<id>`** (`d-43` is accepted) → that item, in a set or not.
- **`discuss <n>`** → number *n* of the latest set this session opened: the set on screen, a menu or a multipart group (whose parts are its numbers). Use the `{"n", "id"}` list `set-open` printed for it.
- **A bare `discuss`** → the item on screen: the long-form part waiting for its reply, or the menu question whose "Other" box held it. With nothing on screen: `Nothing on screen to discuss — type "discuss 2" or "discuss D-43".`
- **Not found** → one line naming what failed, and nothing else changes (a waiting long-form prompt keeps waiting): `discuss 5: set 14 has numbers 1 to 3.`, `discuss D-999: no such item.` (`exit=4` from step 2's block), or `discuss R-88: R-88 is a Review; discuss takes Decisions.`

## 2. Load its card

<!-- test-anchor: desk-discuss-card -->

```bash
ITEM=$("$HQ" get D-48 --json); rc=$?
if [ "$rc" -eq 0 ]; then printf '%s\n' "$ITEM" | jq -r -L "$DESK/skill" 'include "desk"; discuss_card'; else echo "exit=$rc"; fi
```

The card carries what the item holds: its status and when it was asked, the question, the numbered context, the options with the recommended default, when the default is taken, impact, cost and focus, the link to its PR or issue (from its repo and key), where the answer goes, and the answer so far. Print it, then one line: `Ask anything about D-48. "done" brings it back to answer; nothing is stored until you answer.` Keep the item's JSON in this conversation for the follow-ups. `get` runs on its own first so its exit status is not lost in the pipe: `exit=4` is step 1's "not found", and `exit=7` → `Store unreachable — can't load D-48 right now.` and nothing else changes.

## 3. Answer follow-ups

- **From the card first.** When it does not hold the answer, read the linked PR or issue, read-only: `gh pr view <n> --repo <owner/name>`, `gh pr diff <n> --repo <owner/name>`, `gh issue view <n> --repo <owner/name>`, or files in a local checkout of that repo. Say where the answer came from (`the PR's diff`, `issue #90's body`).
- **Never invent.** When neither the card nor its links hold the answer, say so plainly. The asking thread's conversation is not in the store, so never guess what it meant beyond what the item says.
- **Discussion writes nothing.** No `answer`, `comment`, `ack`, or status change, no wake-up, nothing posted to GitHub. What is said here is never stored as the answer: only the operator's answer, given after discussion, is.
- **Plain text only, never AskUserQuestion.** In the desk's own session the capture hook queues any menu that does not carry the desk's `N. [D-id]` prefix as a new Decision.

## 4. End the discussion

Read each operator message in this order:

1. **`done`** or **`back`** (alone, any case) → step 5.
   **Feedback tags** (`2: not important`, `D-48: good interrupt`) or **an interrupt verb** (`away`, `available`, `focus until …`, `focus for …`, `focus off`, `interrupts?`) as the whole message → `interrupts.md`, then go on discussing. A tag is never this item's answer.
2. **An answer** → the discussion ends and the message is the item's answer, through the normal path: it starts with the item's number in the latest set or its id, then a colon (`2: B`, `D-48: …`). A menu-shaped item goes to `decisions.md`, "Typed replies"; a long-form item goes to `longform.md`, "Storing an answer", with the text after the colon, word for word (bar the two changes that section names: outer blank space is trimmed, and a lone option letter stores that option). Then step 6.
3. **`skip`** → no answer; the item stays open. Step 6.
4. **`discuss <other>`** → discuss that item instead (step 1).
5. **`show D-<n>`** or **`history`** (`history <YYYY-MM-DD>`) as the whole message → `history.md`, then go on discussing. **`idea: …`**, **`file: …`**, or **`repo: …`** → `ideas.md`, then go on discussing.
   **A priority command** (`top: #a #b`, `bump #N`, `park #N until <date>`, `drop #N`, `priorities`) as the whole message → `priorities.md`, then go on discussing.
   **A plan verb** (`plan`, `plan?`, `plan off`, `plan: …`) or **`sweep`** as the whole message → `plan.md` or `sweep.md`, then go on discussing. A plan sentence (`I need to work on …`) is a follow-up here, never a plan.
6. **Anything else** is another follow-up (step 3).

## 5. Present the item again

Whatever its kind, the item comes back for an answer exactly as it is presented outside discussion:

- **Menu-shaped** (2 to 4 options, minutes): a one-question AskUserQuestion menu built as `decisions.md` builds one ("The menu": the `<n>. [D-<k>]` prefix, the recommended option first). When the item is in the latest set, it keeps its number there; otherwise open a set of its own first (`"$HQ" set-open D-43 --json`, number 1), so typed numbers keep resolving against the set on screen. Its answer → `decisions.md`, "Turning the menu into a reply", with that set's id.
- **Long-form**: its card again (`longform.md`, "Presenting a group", step 2), as the same part *k* of *m* when it is part of the group on screen, else part 1 of 1 in a set of its own. Its reply → `longform.md`, "Replies to a long-form prompt".
- **Answered or closed already**: present it the same way, after one line: `D-43 is answered ("Fix the window math"); a new answer replaces it.` Skipping it changes nothing.

## 6. Back to where the operator was

Continue from where `discuss` was typed: the rest of that menu's set, the next part of the group, or the next group. Set numbering does not change. A `desk-tick … new` event that arrived during the discussion is held the way `longform.md` holds one ("Tick events while a prompt waits") and shown after this.

## Its events

`discuss` reads the item with `get`, so it does not print the item's events. For the item's sub-thread (when it was shown, answered, woken, or `answer-parked`), the operator types `show D-<n>` (`history.md`, #1781). It is read-only and changes nothing here, and the discussion then continues. `history` lists today's answered items the same way.
