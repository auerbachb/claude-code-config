# desk/hooks/

Hook implementations for the human queue live here.

| File | What it is |
|------|------------|
| `capture.sh` | The capture hook (issue #1755): a `PreToolUse` hook on `AskUserQuestion` that sends a thread's questions to the store instead of rendering them in the thread, while a live desk exists. A bash launcher that resolves its own location and runs `capture.py` |
| `capture.py` | The capture hook's logic (Python 3.9: the input is nested JSON, and every CLI call needs a hard timeout that kills its process group) |
| `question-leak-warn.sh` | The prose-question nudge (issue #1778): a `Stop` hook that warns, once per turn, when the final assistant message asks the operator a question in prose with no receipt line after it. Warn-only; bash, jq, and awk; needs neither the CLI nor the database |

Claude Code registers hooks from `.claude/hooks/`, so each hook here gets an
entry there that is a symlink into this folder
(`.claude/hooks/human-queue-capture.sh` → `../../desk/hooks/capture.sh`) and a
`global-settings.json` entry that `register-hooks.py` installs at session
start. A hook finds the CLI relative to its own resolved location
(`../bin/human-queue.sh`; tests override it with `HUMAN_QUEUE_CLI`) and fails
open on any failure, the CLI's exit 7 included.

The contract (the live-desk gate, the deny reason, what a Decision carries,
where the URL comes from, and every fail-open path) is in `../README.md`,
"Capture hook".

## The prose-question nudge

`question-leak-warn.sh` (`.claude/hooks/question-leak-warn.sh` →
`../../desk/hooks/question-leak-warn.sh`, registered on `Stop`) covers the one
leak the capture hook cannot see: a question written as prose
(`../DESIGN.md` 2.4). It backs up the worker contract in
`.claude/rules/human-queue.md`.

- **Input:** the final assistant message — `last_assistant_message` from the
  Stop payload, or, when the payload has none, the last assistant message in
  `transcript_path` (its final 2 MiB, malformed lines skipped).
- **A question line** ends in `?` (after trailing whitespace and `*` / `_` /
  `~` emphasis) outside fenced code blocks. Headings, blockquotes, table rows
  (also nested in a list item, `- > quoted?`), a bare URL, and
  punctuation-only lines never count; a
  `?` inside inline code or before a closing quote or bracket is never
  line-final, so it never counts either.
- **A receipt line** contains `question D-<n> sent to human queue` or the
  plural `questions D-<n>, D-<m> sent to human queue` (any case, any
  decoration) — the exact text the capture hook's denial tells a thread to
  print — outside fenced code blocks and blockquotes; a receipt inside one is
  an example or a quote and answers nothing.
- **Warns** when a question line has no receipt line after it: one
  `hookSpecificOutput.additionalContext` object that quotes the first such
  line and names the fix (ask through `AskUserQuestion`; with a live desk,
  print the receipt and proceed on the default or park; with none, the menu
  renders). Never `decision: "block"`.
- **Once per turn:** Stop context continues the conversation for one more
  model request, and every later Stop of that turn carries
  `stop_hook_active: true`. A warning leaves a marker directory
  (`$TMPDIR/claude-question-leak-warn-<session_id>`) that the turn's first
  Stop removes; in a continued turn the hook warns only if it can create
  that marker first. A turn another Stop hook continued is still checked; a
  turn it already warned in is not, so it cannot loop.
- **Fails open:** no jq, bad input, an unreadable transcript, any error —
  nothing printed, exit `0`.

Tests: `../tests/question-leak-warn.test.sh` (offline, fixture transcripts in
`../tests/fixtures/question-leak/`).
