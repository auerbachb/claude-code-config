## PR drill-down (issue #1768)

Below the Reviews view's level 3 (one diff, pasted whole): a PR made
addressable by number, so the operator can open one hunk and ask about it
(`skill/drilldown.md`). No migration, and nothing is stored: every call
rebuilds the outline from GitHub.

| The operator types | The desk runs |
|--------------------|---------------|
| `outline R-<n>` | `get R-<n> --json`, then `bin/pr-outline.sh OWNER/REPO pr-N` |
| `open R-<n> <node>…` | the same, with the nodes (`2`, `2.3`, `T1`, `T1.2`) after the key; `open R-<n>` alone stays level 2 |
| `ask R-<n>: <question>` | the outline, then one `open` of the nodes the question needs (every node's head checked against the outline's; a push in between means outline and open again); the answer ends `Read: 2.3, T1.1 · head <sha>` |

- **`bin/pr-outline.sh OWNER/REPO N [NODE...]`** is read-only. Without
  nodes it prints the outline: the files that are not tests numbered `1, 2,
  …` in GitHub's order (status, `+added -deleted`), their hunks `2.1, 2.2,
  …` (new-side line range, counts, heading), the tests touching each file as
  leaves, then `Tests` (`T1, T2, …`, the files each touches, its hunks). A
  test is a changed file the Reviews view counts as one; it touches a file
  when their stems match or its patch names the file's basename. With nodes
  it opens them in order: a file is its whole patch with a `[2.k]` line
  before each hunk; a hunk is widened from the file at head to
  `HQ_OUTLINE_CONTEXT` (20) lines on each side, as one hunk with a
  recomputed `@@` line, stopping at a neighbouring hunk or the file's edge
  and saying so. Each node starts with `=== ID · PATH · … · head SHA`.
- **GitHub calls.** `repos/O/R/pulls/N`, then `repos/O/R/pulls/N/files`
  (paginated), then `pulls/N` again: the file list has no SHA of its own, so
  a push in between lists the files again under the new head (up to three
  listings; a PR still moving exits 1, never pairing one head with another
  head's diff). Then, for opened hunks of changed files only, the file's blob
  at head (`git/blobs/<sha>`, raw), once per file per call. Each goes through
  `bin/lib/github.sh`, so `HUMAN_QUEUE_GH` and `HUMAN_QUEUE_GH_TIMEOUT` apply.
- **What it will not guess.** A file GitHub sent no patch for shows no hunks
  and says why; a patch whose hunks do not add up to their headers or to the
  file's counts is marked `patch incomplete`; a file at head that does not
  match the patch, or a fetch that fails, prints the hunk as GitHub gave it
  with one `(more context unavailable: …)` line; a partial file list says how
  many files it holds. GitHub's text prints with control characters as `?`,
  and a newline inside a path as `?`, so a path never starts a line.
- **Exit codes.** 0 ok; 1 GitHub failed (or a deadline, or a PR pushed to
  during each of three listings); 3 no such PR, an
  `issue-N` key (no GitHub call), or a node the outline lacks (its line names
  the ids it has; nothing on stdout); 4 usage (a node that is not `F`, `F.H`,
  `Tn`, or `Tn.H`, a context cap outside 1 to 500).
- **Tests.** `tests/drilldown-offline.test.sh` (offline, `tests/lib/gh-stub.sh`
  serving `tests/fixtures/drilldown/`): test 5.1's outline of a PR with three
  source files and two test files; test 5.2's `open 2.3` (eight lines above,
  stopped at hunk 2.2; twenty below), `open 2.1`/`2.4` at the file's edges,
  `open 2` with its markers; one fetch per file; the edge cases above;
  a push between the reads (listed again, the new head cited) and a PR that
  keeps moving (exit 1); a newline in a path; a CRLF file at head, with an
  LF or a CRLF patch, widened like any other;
  not found, unknown nodes, failures, the deadline; no temp file left; the
  skill's blocks under bash and zsh against a stub CLI. Under bash and
  `/bin/bash` 3.2. What `ask` answers is checked by a live run.
