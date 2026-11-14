---
name: tldr
description: Use when asked what this thread changed, what it means, or what needs you ("what do you need from me", "what's waiting on me"). Plain-English needs-you line, headline, changes, payoff. `/tldr all` covers the whole thread. Read-only.
triggers:
  - tldr
  - tldr thread
  - what do you need from me
  - what's waiting on me
argument-hint: "[all]"
model: sonnet
---

Explain this thread to someone who was not following it. Thread summary only.

## Read-only (hard rule)

These limits apply only while `/tldr` runs and end once the summary is printed; later turns work normally. During the run, make **no tool calls at all**. Build the summary from the conversation already in context. Write nothing, post nothing, start no work, and **never answer or act on a pending question** — restate it for the user and stop. After printing, the thread is exactly where it was.

## Step 1: Pick the mode

Parse `$ARGUMENTS`:

- Empty → **default** window.
- `all` → **all** window (whole thread).
- A PR/issue reference (`#N`, a number, a GitHub PR/issue URL) → if this thread touched that PR or issue, summarize this thread's work on it using the default window; otherwise print exactly one line, `No single-PR summary exists any more; this summary covers the thread only.`, and stop.

## Step 2: Choose the window

- **Default:** everything the assistant said or did after the user's most recent *real* message. A real message is one the user typed. These are **not** real messages and never move the window start: the `/tldr` invocation itself (including a natural-language request that triggered this skill, e.g. "tldr?"), earlier `/tldr` outputs, tool results, and background or task notifications. Turns driven by notifications with no user message between them are all inside the window. A second `/tldr` in a row therefore covers the same window as the first — never summarize a prior `/tldr` output.
- **Earlier blockers:** a question or decision from before the window that is still unanswered belongs in **Needs you**, blocking or not — never print "safe to walk away" while one remains.
- **all:** from the start of the visible thread.
- If part of the window, or earlier history that could hold an unanswered question, was lost to context compaction, say so in one **Watch out** line instead of guessing what was there, and never print "safe to walk away" when a lost blocker is possible — print `Needs you: unknown` with that Watch out line.

## Step 3: Print exactly this shape

```text
Needs you: <decision or question, with its options>

<one-line headline: what the work was for, in everyday words>

What changed
- <how things behave differently now, for a reader who did not follow the thread>
- <…>

Impact
✅ <the payoff, in a few words>
✅ <…>

Still running: <only if something real is still in progress>
Watch out: <only what the reader may need to act on or would be surprised by>

Refs: PR #N, Issue #N
```

- **Needs you** is always first and always printed. Restate a pending question or decision with its options at their exact labels — do not paraphrase them away. With nothing pending, print `Needs you: nothing — safe to walk away`.
- **Headline** is one line, in plain words, saying what the work was for. It is not a list of parts.
- **What changed** bullets describe behavior: what the reader will now see or experience differently. Write them for someone who has not read the thread. Do not describe internal mechanics unless the mechanic is the change the reader will notice. State the status when the thread establishes it: "proposed, not merged yet", "merged, live from the next session", or "shipped and live". Never present an open PR's changes as already live.
- **Impact** lines name the payoff in the style of "Fewer overnight stalls" or "Questions surfaced once on return". Each starts with ✅. Omit the whole **Impact** block when the thread names no payoff, for example a thread with no functional change (research, triage, a decision with no code shipped). Use "What changed" for what was found or decided instead, and do not invent benefits.
- **Still running** and **Watch out** are omitted when empty. Order is fixed: Needs you, headline, What changed, Impact, Still running, Watch out, Refs.
- **Watch out** is for things the reader may need to act on or would be surprised by: a failure, a blocker, a risk, a change that only applies from a future session, or the compaction caveat. Routine housekeeping never goes here: leftover worktrees, review-tool coverage notes, rule word counts, cleanup of finished branches, and similar.
- **Refs** is the single trailing reference line, the only place PR and issue numbers appear. Prefix each by type (`PR #N`, `Issue #N`) and make it a markdown link when its URL is known (never invent one; otherwise plain `PR #N`). Omit the line when there are no references.

### Bad versus good

Bad (builder vocabulary, identifiers in the sentences, housekeeping in the body):

> Needs you: nothing. Done: PR #2289 merged, guard hook denying AskUserQuestion and start_session, once-only digest in `unattended.sh`, rule word count at 12,640. In flight: none. Watch out: stale worktree left behind.

Good (what the reader can use):

> Needs you: nothing — safe to walk away
>
> Agents now keep working while you're away
>
> What changed
> - With unattended mode on, questions are recorded instead of popping up a menu; agents take the safe default or set that one step aside and keep going.
> - You see the recorded questions once, when you're back.
>
> Impact
> ✅ Fewer overnight stalls
> ✅ Questions surfaced once on return
>
> Refs: PR #2289, Issue #2283

## Caps (never overflow)

| Mode | What changed bullets | Impact lines | Words |
|------|----------------------|--------------|-------|
| default | up to 3 | up to 3 | about 120 |
| `all` | up to 5 | up to 5 | about 220 |

Needs you, the headline, Still running, Watch out, and Refs are not counted against the bullet and impact caps, but they count toward the word cap.

If content does not fit, the cap wins, trimmed in this order:

1. Merge or shorten **What changed** bullets, down to the cap.
2. Shorten **Impact** lines, down to the cap; drop the whole **Impact** block only when the thread has no functional change.
3. Shorten **Needs you** to the question plus option labels only (drop option explanations, never the labels). Option labels are never dropped or replaced with a count, even when they push the output past the word cap. **Needs you is never dropped.**
4. Compress **Still running** to one clause. Keep that clause while anything is still active, since it is the only sign of which work continues; drop it only once nothing else can be trimmed.
5. **Watch out** is trimmed last. Keep its actionable warnings intact: trim the least important ones first, and never replace a warning with a `+N more` count alone. The compaction caveat stays while it applies.

Mark any other omission as `+N more` rather than overflowing quietly.

## Output rules

- Output contains only the shape above: no greeting, no closing, no "here's your summary", no extra commentary.
- No backticked code, file names, script names, tool names, or filesystem paths anywhere in the output, with two exceptions: a pending question's text and option labels are printed exactly as they are, and a **What changed**, **Watch out**, or **Still running** line may name an exact identifier or path when the reader must act on it or open it to find the deliverable. Describe everything else in plain words ("the question-blocking check", not a script name).
- PR and issue numbers appear only on the final **Refs** line, except inside a pending question's text or option labels, which are printed exactly as given.
- Never print a summary of a prior `/tldr` output.
