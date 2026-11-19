## Prose-question nudge (issue #1778)

The capture hook only sees questions asked through `AskUserQuestion`. A
question written as prose would wait in a transcript nobody reads, so a
second hook, [`desk/hooks/question-leak-warn.sh`](../hooks/question-leak-warn.sh) (registered on `Stop` as
`.claude/hooks/question-leak-warn.sh`), warns once per turn when the final
assistant message ends a line with `?` outside code fences and prints no
receipt line (`question D-<n> sent to human queue`) after it. The warning
names the fix from `.claude/rules/human-queue.md`. It never blocks, needs no
database, and fails open. Detection rules and output: [The prose-question nudge](../hooks/README.md#the-prose-question-nudge).
Tests: [`desk/tests/question-leak-warn.test.sh`](../tests/question-leak-warn.test.sh) (offline).
