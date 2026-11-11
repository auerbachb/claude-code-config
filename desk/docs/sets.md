## Sets

| Subcommand | What it does |
|------------|--------------|
| `set-open ID... [--json]` | Numbers 1 to 99 distinct items 1..n under a new set id, in argument order, and records one `shown` event per item (note `set N #k`). Prints `set N` and one `k. ID **question**` line per item |
| `set-resolve REPLY [--set ID] [--json]` | Maps the operator's reply to the set's items and answers them, exactly as `answer` does. `--json` answers carry each item's `session` (its return address), so the desk wakes threads without another read |

- **Replies.** `"2: B"`, `"1: A, 2: C"`, `"D-43: B"`, or `"1: yes, but after
  CI; 3: use staging"`. A pair is opened by an item's number in the set or by
  its id (issue #1779; the id must be in the set, and one item may not be
  named by both). A pair starts at the beginning, or after a comma, semicolon, or
  line break followed by `N:` or `D-<n>:`; anything else continues the answer before it,
  so commas and line breaks inside an answer survive. A reply is at most 8000
  characters, which bounds the parse to under a second on bash 3.2.
- **All or nothing.** Every pair is validated (the number is in the set, the
  item is a Decision, a letter names one of its options) before any answer is
  written, and all answers are written in one transaction. One bad pair
  writes nothing.
- **Which set.** The latest set by default; a caller that holds a set id
  passes `--set`. Numbering restarts at 1 in every set. Four per menu is the
  question tool's limit, not the store's.
