# /desk — ideas: file an issue from the desk

Loaded when the operator's message starts with `idea:`, `file:`, or `repo:` (any case). That holds at any time: after a menu, while a long-form prompt waits (print its card again afterwards), or during a discussion. Every Bash block starts with `SKILL.md`'s prelude (`DESK`, `HQ`, `SID`). Issue #1766; design: `desk/DESIGN.md` 2.1 ("Ideas: file an issue from the desk; the PM thread picks it up on its next scan"), 2.7, 4.2.5, and 7.5.

**The desk stays the desk.** An idea goes through `/issue-maker`'s **one-shot entry**: the same reflection, duplicate search, labels, seven-section body, and footer, created by the same script, `issue-file.sh`. There is no capture mode, no capture log, and no `/issue-maker` session; once the URL is printed the desk is exactly where it was.

What happens after: the issue is open, unassigned, and carries none of the labels `/pm` skips, so the PM thread's next backlog scan in that repo names it (`/pm` Step 1B.2, "New since the last scan"). Its body ends in `_Captured via /issue-maker._`, so `sync-reviews` brings it back as a Review, and the event this flow records puts `filed from the desk` on that Review.

## 0. A held idea first

At most one idea is **held** (waiting on a question below), in this conversation only; its text is never stored. When one is held and the message is exactly `idea: anyway`, `idea: re-cut`, `idea: yes`, or `idea: drop` (`file:` works the same), act on the held idea and skip step 1:

- `anyway` → file it as drafted (past a duplicate, a failed create, or all N increments).
- `re-cut` → only after the more-than-five-increments question: re-cut the chain to at most five, then file.
- `yes` → only after a `Possibly filed as #N` card (step 3, `file-exit=4`): that issue is this filing. Run `"$HQ" filed <repo> <N>` and go on as for `file-exit=0` with its number and URL, closing on the URL.
- `drop` → `Dropped the idea "<its first 60 characters>".` Nothing is filed.

Any other `idea:` or `file:` text is a new idea and replaces the held one: say `Dropped the held idea "<…>".` in one line, then go on with the new one.

## 1. Where it goes

<!-- test-anchor: desk-idea-target -->

```bash
"$DESK/bin/idea-target.sh" --session "$SID" <<'DESK_IDEA'
<the operator's message, exactly as typed>
DESK_IDEA
echo "exit=$?"
```

Copy the message into the here-document character for character (pick another delimiter if a line of it is exactly `DESK_IDEA`). It prints one JSON object: `verb`, `text` (the idea without a repository word), `repo`, `source` (`text`, `default`, or `reply`), `saved`, `suggest`, and `notes`.

The repository comes from, in order: **the text** (its first word, when it is `owner/name` or a GitHub link to a repository you can file issues in; a path such as `desk/skill` stays in the text, with a note), then **this desk session's default**, then **one question**.

| Result | Do |
|--------|-----|
| `exit=0`, verb `idea` | File `text` in `repo` (step 2). |
| `exit=3` | No repository yet. Hold the idea and ask the question below, once. A note (a default that can no longer take ideas, or a store that could not be read) goes in one line above the card. |
| `exit=0`, verb `repo` | The operator's answer. With `saved` true: `Ideas from this desk go to <repo> now.` With `saved` false: its note in one line (the store was unreachable; the desk will ask again next time). Then, only when an idea is held, file it there now (step 2); with none held, that line is the whole reply. |
| `exit=4` | Its note in one line. For a `repo:` answer the question stays open: print the card again. |
| `exit=1` | `gh` or `jq` is missing: one line, stop. The idea is not held. |

**The question**, as plain text, never AskUserQuestion: in the desk's own session the capture hook queues any menu that lacks the `N. [D-id]` prefix as a new Decision. It is a blockquote, as the desk's other prompts are, so the prose-question nudge reads it as the desk's own card:

> **Which repo should ideas from this desk go to?**
> Reply `repo: owner/name` — for the repo this desk runs in, `repo: <suggest>`. I'll file "<the idea's first 60 characters>" there and use it for every idea this session.

Leave out the "for the repo this desk runs in" clause when `suggest` is null. That is the one question per session: once `repo:` has saved a default, ideas without a repository go there without asking, as long as it still passes the same check (it is checked again for each idea; one that fails comes back as `exit=3` with a note). `repo: owner/name` also changes the default at any time.

## 2. File it: the one-shot entry

Read the shared procedure, the first that exists of:

1. `$DESK/../.claude/skills/issue-maker/references/one-shot-filing.md` (the checkout this desk runs from)
2. `$HOME/.claude/skills-worktree/.claude/skills/issue-maker/references/one-shot-filing.md`
3. `$HOME/.claude/skills/issue-maker/references/one-shot-filing.md`

None → `ERROR: one-shot-filing.md not found (checked all three paths) — idea filing unavailable`, and stop; the idea stays held. Otherwise follow it with the idea's text and repository, in **default** mode (**rapid-fire** when the operator wrote "just file it" or "no commentary"). Every `gh` call in it passes `--repo <repo>`.

Its pauses are asked here, one at a time, as plain-text blockquote cards, with the idea held:

- **A strong or exact-title duplicate** → name the candidate (`#N — title`, and why it looks the same). Reply `idea: anyway` to file it, or `idea: drop`.
- **A blocking ambiguity** → name the word and what it could mean. The reply is the idea again, pinned down (`idea: …`), which replaces the held one.
- **More than five increments** → name the count and the increments. Reply `idea: re-cut` or `idea: anyway`.

A tick event that arrives meanwhile is shown as usual: the cards wait for an `idea:` reply, so a typed `2: B` still answers its menu.

## 3. Create

One block per issue (a split or a chain files each member, head first). Fill in the repository, the title, the body (ending in the footer line), and one `--label` per label, and run:

<!-- test-anchor: desk-idea-file -->

```bash
ISSUE_FILE=""
for c in "$DESK/../.claude/scripts/issue-file.sh" "$HOME/.claude/skills-worktree/.claude/scripts/issue-file.sh" "$HOME/.claude/scripts/issue-file.sh"; do
  if [ -x "$c" ]; then ISSUE_FILE="$c"; break; fi
done
if [ -z "$ISSUE_FILE" ]; then
  echo "ERROR: issue-file.sh not found (checked the desk's checkout, ~/.claude/skills-worktree/.claude/scripts, ~/.claude/scripts) — idea filing unavailable"
else
  IDEA_REPO='<owner/name>'
  IDEA_TITLE=$(cat <<'DESK_IDEA_TITLE'
<the title>
DESK_IDEA_TITLE
)
  IDEA_BODY=$(mktemp "${TMPDIR:-/tmp}/desk-idea.XXXXXX")
  cat > "$IDEA_BODY" <<'DESK_IDEA_BODY'
<the body>
DESK_IDEA_BODY
  # When this attempt began: the exit-4 check below records only an issue
  # created at or after it.
  echo "attempt-started=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  rc=0
  FILED=$("$ISSUE_FILE" --repo "$IDEA_REPO" --title "$IDEA_TITLE" --body-file "$IDEA_BODY" --json <the labels>) || rc=$?
  rm -f "$IDEA_BODY"
  printf '%s\n' "$FILED"
  echo "file-exit=$rc"
  if [ "$rc" -eq 0 ]; then
    "$HQ" filed "$IDEA_REPO" "$(printf '%s' "$FILED" | jq -r '.number')"
    echo "filed-exit=$?"
  fi
fi
```

`<the labels>` is `--label 'enhancement' --label 'skill'` (single-quoted, a `'` inside written `'\''`), or nothing. The here-documents are quoted, so nothing in the title or body expands.

- **`file-exit=0`** → the JSON names `url`, `number`, the `labels` applied, and any `dropped_labels` (a label the repo lacks, or one that would hide the issue from `/pm`). The idea is no longer held.
  - `filed-exit=0` prints `noted R-12` (its Review already existed and now records the filing) or `pending` (`sync-reviews` records it when it adds the Review). Neither needs a word.
  - `filed-exit=7` → the store is unreachable. Keep `filed <repo> <number>` in this conversation and run it after the next `recovered` event; until then the Review would arrive without the note. Any other non-zero → show its one line once.
- **`file-exit=3`** → a check failed and nothing was sent: fix the title or body it names (the title is over 70 characters, a section is missing or out of order, the footer is not the last line) and run the block again.
- **`file-exit=4`** → `gh` failed, and the issue may have landed anyway (a lost response after the write). Check first: `gh issue list --repo <repo> --author @me --limit 5 --json number,title,url,createdAt`. Compare each issue with this title against the block's `attempt-started`:
  - `createdAt` at or after it → it was filed: go on as for `file-exit=0` with its number and URL (run `filed`).
  - `createdAt` in the minute before it → **uncertain**: clock skew between this machine and GitHub, or an earlier filing of the same idea. Record nothing yet and say once: `Possibly filed as #N (<url>), created just before this attempt — check it. Reply idea: yes if it is this idea, idea: anyway to file again, or idea: drop.` The idea stays held; `idea: yes` records that issue as this filing (step 0).
  - Older → an earlier filing (a re-filed idea, or a duplicate passed with `idea: anyway`); it never counts.
  - No same-title issue in the first two cases → `Not filed: <its message> (exit 4). Reply idea: anyway to try again.` and the idea stays held.
- **`file-exit=2`** → the call itself was malformed: fix it and run again.

## 4. Report

Per the one-shot entry's step 8, in this order:

1. One to three sentences on what was filed, in plain functional terms, ending with where `/pm` will pick it up: `It joins <repo>'s backlog; /pm names it on its next scan there.`
2. In default mode, the decision points: the repository and why (`named in your message`, `this desk's default`, or `your reply`), the labels applied and any dropped, a trimmed title, the duplicate verdict (none, or "possibly overlaps #N"), scope calls (narrowed, split, chained), assumptions, and any `notes` from step 1. Rapid-fire leaves these out.
3. **The issue URL as the closing line**, alone. A split or chain prints each member's URL as it is filed and closes on the last one.

On a failure there is no URL line: the error line and its exit code are the message.

## What is stored

Nothing about the idea itself. The store gets this desk session's default repository (`state` key `idea_repo:<SID>`, written by `repo:`) and the pending filing (`filed:<owner/name>:issue-<N>`, written by `filed` and consumed into the Review's one `commented` event). No other event is written and no transcript is kept (`desk/DESIGN.md` 2.5).
