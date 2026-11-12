---
name: tldr
description: Print a few-line, fixed-shape summary of what this thread needs from you — Needs you / Done / In flight / Watch out — covering everything the assistant said and did since your last real message. `/tldr all` covers the whole thread. Read-only. Also for "what do you need from me" and "what's waiting on me".
triggers:
  - tldr
  - tldr thread
  - what do you need from me
  - what's waiting on me
argument-hint: "[all]"
model: sonnet
---

Boil this thread down to the few lines the user needs to act. Thread summary only — for one PR or issue use `/recap`.

## Read-only (hard rule)

These limits apply only while `/tldr` runs and end once the summary is printed; later turns work normally. During the run, make **no tool calls at all**. Build the summary from the conversation already in context. Write nothing, post nothing, start no work, and **never answer or act on a pending question** — restate it for the user and stop. After printing, the thread is exactly where it was.

## Step 1: Pick the mode

Parse `$ARGUMENTS`:

- Empty → **default** window.
- `all` → **all** window (whole thread).
- A PR/issue reference (`#N`, a number, a GitHub PR/issue URL) → print exactly one line, `For a PR or issue summary use /recap <ref>.`, and stop.

## Step 2: Choose the window

- **Default:** everything the assistant said or did after the user's most recent *real* message. A real message is one the user typed. These are **not** real messages and never move the window start: the `/tldr` invocation itself (including a natural-language request that triggered this skill, e.g. "tldr?"), earlier `/tldr` outputs, tool results, and background or task notifications. Turns driven by notifications with no user message between them are all inside the window. A second `/tldr` in a row therefore covers the same window as the first — never summarize a prior `/tldr` output.
- **Earlier blockers:** a question or decision from before the window that is still unanswered belongs in **Needs you**, blocking or not — never print "safe to walk away" while one remains.
- **all:** from the start of the visible thread.
- If part of the window, or earlier history that could hold an unanswered question, was lost to context compaction, say so in one **Watch out** line instead of guessing what was there, and never print "safe to walk away" when a lost blocker is possible — print `Needs you: unknown` with that Watch out line.

## Step 3: Print exactly this shape

```text
Needs you: <decision or question, with its options>
Done: <what finished or changed>
In flight: <what is still running>
Watch out: <failures, blockers, risks only>
```

- **Needs you** is always first and always printed. Restate a pending question or decision with its options at their exact labels — do not paraphrase them away. With nothing pending, print `Needs you: nothing — safe to walk away`.
- **Done**, **In flight**, **Watch out** are omitted when empty.
- Order is fixed: Needs you, Done, In flight, Watch out.
- Each line is one short clause. Prefix GitHub numbers by type (`PR #N`, `Issue #N`) and make each a markdown link when its URL is known (never invent one; otherwise plain `PR #N`).

## Hard caps (never overflow)

| Mode | Lines | Words |
|------|-------|-------|
| default | at most 6 | about 60 |
| `all` | at most 10 | about 120 |

If content does not fit, the cap wins: shorten **Needs you** to the question plus option labels only (drop option explanations, never the labels; if labels alone exceed the cap, list the first ones and add `+N more options`), then compress or drop **In flight**, then **Done** detail, and mark the omission as `+N more`. **Watch out** is dropped last. Never overflow the cap quietly.

## Output rules

Output contains only the labeled lines — no greeting, no closing, no "here's your summary", no headings, no extra commentary.
