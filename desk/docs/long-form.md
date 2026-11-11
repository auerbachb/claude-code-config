## Long-form, multipart, and discuss (issue #1780)

The desk's second increment (`skill/longform.md`, `skill/discuss.md`). The
deterministic parts live in one jq library, `skill/desk.jq`, which both
`decisions.md` and `longform.md` call (`jq -L "$DESK/skill" 'include
"desk"; …'`), so the menus and the long-form view share one classification.

- **Long-form.** A Decision a menu cannot hold: no options, one option, more
  than four, or a declared cost in hours, days, or weeks (`2h`, `1h30`,
  `half a day`). It is shown alone, as a quoted text card (never a menu), and
  the operator's next message is its answer, stored word for word (outer
  whitespace trimmed and a lone option letter stored as that option, as for
  every answer).
- **Multipart.** The store has no parts field: a multi-question ask is
  already one Decision per question. A multipart Decision is the open
  long-form Decisions that share a repo, a key, and a return address (one
  thread asking several things about one PR or issue), in list order. The
  desk opens one set per group, so part *k* is number *k*, and shows the
  parts one at a time; each keeps its own id, answer, and wake-up.
- **`answer --stdin` and `--json`.** `answer ID --stdin` reads the answer
  from standard input instead of the command line, so quotes, `$(...)`,
  backticks, and lines such as `2: B` arrive as written (at most 16000 bytes
  are read; a NUL byte is refused as a control character; the 4000-character
  limit and the trim of leading and trailing whitespace are unchanged).
  `--json` prints `{"id", "answer", "changed", "session"}`, the fields the
  desk's wake rule reads. Both are flags wherever they appear, so an answer
  that is exactly `--json` or `--stdin` goes through `--stdin`.
- **`discuss <n|D-id>`.** Loads one item with `get` and prints a card: the
  question, context, options with the default, impact and cost, where the
  answer goes, and a link to its PR or issue derived from `repo` and `key`
  (`pr-N`, `issue-N`, `branch:NAME`; none for `local/` repos or shortened
  keys). Follow-ups are answered from the card and read-only reads of the
  link; discussion writes nothing to the store, then presents the item again
  for an answer.
- **Tests.** `tests/longform-offline.test.sh` runs `desk.jq` on fixtures and
  checks `answer --stdin/--json` validation offline;
  `tests/longform.test.sh` (live, throwaway schema) stores a reply full of
  shell metacharacters through the skill's own here-document and compares it
  byte for byte.
