## Export to paper (issue #1759)

The operator reads long material on paper, marks it by pen, and dictates or
types the answers back. `export` prints a batch as a numbered PDF whose
numbers are a set's, so a reply typed from the paper (`2: B`, `D-43: B`)
lands on the right item.

- **The command.** `export --out FILE.pdf` with exactly one batch:
  `--kind decisions` (every open Decision, list order), `--kind reviews`
  (every unreviewed Review, oldest first; `--today` for today's), `--ids
  D-43 R-9 …` (that order), or `--set N` (a set at its own numbers: the
  end-of-day sweep's). `--level 1|2` picks how much of each Review (2, the
  cached twenty-line summary, by default); `--dry-run` reports the batch and
  the Reviews still missing a summary without writing or recording
  anything; `--json` prints the result as one object. At most 99 items, the
  rest counted as `more`. `export --help` has the whole contract.
- **Numbering.** `--kind` and `--ids` open a new set, as `set-open` does
  (`shown` events); `--set` opens nothing. Every item's heading carries its
  id, so `D-43: B` works whatever set is current.
- **Layout (ISO 2145).** A title, the set, the count, and the export time;
  then one section per item headed `n  D-43 · the question`: its repo, key,
  and triage facts (the impact as the card words it: derived, else
  declared), its context, a Review's summary, its options as `n.1
  A. Yes (Recommended)`, `n.2  B. No`, the default and when it applies, the
  operator's own priority, tags, and note when it carries them (#1769), the
  link, and a blank answer line (an item answered since shows its answer).
  Pandoc and headless Chrome print the export-time footer and page numbers
  on every page. The print system prints the footer at the end.
  `bin/lib/export.jq` renders it three ways (Markdown, plain text, HTML)
  from one item model, reusing `skill/desk.jq`'s labels and links. It runs
  as the head of the main jq program (`lib/export.sh`'s `hq_export_jq`),
  never as an included module: jq 1.8 aborts when a module's def calls a
  `desk.jq` function that calls another one.
- **Renderers.** No new dependency: the first of these that produces a PDF
  is used. pandoc (the Markdown, when pandoc and a PDF engine are
  installed; the items' text is escaped and read literally: its Markdown,
  raw TeX and HTML, math, YAML blocks, and images stay text, so nothing in
  it reaches the engine or is fetched, and no smart punctuation turns
  `--force` into a dash);
  headless Google Chrome or Chromium (the HTML, under a throwaway profile,
  so a running Chrome is never touched; offline, since no host name
  resolves; stopped once it reports the file written, because on macOS it
  can keep running after); the macOS print system (`/usr/sbin/cupsfilter`,
  the plain text). With none, the Markdown is written next to the
  requested path (`FILE.md`), the exit is still 0, and one stderr line
  names it and what each renderer did. Every renderer runs without the
  store's URL in its environment, with its temp files (`TMPDIR`, and
  Chrome's `MAC_CHROMIUM_TMPDIR`) in the export's private scratch
  directory, which is removed on exit, and under a deadline
  (`HUMAN_QUEUE_EXPORT_TIMEOUT`); an export interrupted mid-render stops
  its renderer. To get PDFs on a machine with none: install Google Chrome,
  or pandoc with a PDF engine.
- **The file.** Written through a temp file and a rename, owner-only
  (0600: it holds open questions); an existing file is replaced. The desk
  writes into `~/.claude/desk-exports/` (0700) unless the operator names a
  path.
- **Recording.** One `exported` event per item (note `set N #k`), in the
  transaction that reads the batch, so nothing else is logged. When the
  file then cannot be written, a second transaction removes that record
  (the set it opened, and its `shown` and `exported` events by the ids the
  first transaction returned), so no unseen set becomes the latest; exit 1,
  `nothing was recorded`. An export stopped before its file is in place
  (SIGTERM, SIGINT) takes the record back the same way, from its exit
  trap. Migration
  `013_exported_event.sql` adds the kind to whatever `events_kind_check`
  allows (as 010 does), so it applies before or after #1769's 010. Before
  013 is applied, `export` exits 1 naming `migrate` and records nothing; a
  dry run needs no migration. The weekly report does not count `exported`.
- **The desk.** `export` after a sweep prints that sweep's set; otherwise
  `export`, `export decisions`, `export reviews` (`level 1`, `today`), and
  `export D-43 R-9 …`, any of them `… to <path>.pdf` (`skill/export.md`).
  Before Reviews go out at level 2, the desk writes any missing twenty-line
  summary first (`reviews.md`'s `open` steps; summaries stay lazy). The
  sweep no longer writes its own Markdown copy.
- **Tests.** `tests/export-offline.test.sh` (offline: validation before
  connecting, the three renderings of `tests/fixtures/export/batch.json`
  — ISO 2145 numbering, the to-do line, a derived impact, escaping,
  levels — the renderer
  order and fallbacks against stub binaries, the URL kept out of their
  environment, their temp files in the scratch directory, Chrome offline
  and stopped after it writes, a renderer stopped when the export is
  interrupted, images in the text escaped, the same paper from every jq
  on the machine (and `HQ_T_EXTRA_JQ`, for a jq 1.8), a real cupsfilter and Chrome
  PDF read back by `pdftotext` on macOS, and the skill's blocks under bash,
  `/bin/bash` 3.2, and zsh); `tests/export.test.sh` (live, throwaway
  schema: test 5.1, three fixture Decisions to a PDF with three sections
  whose ids `pdftotext` finds; test 5.2, the Markdown fallback and its
  warning; the set and its events, `--set`, `--ids`, Reviews at both
  levels, `--today`, a dry run, the 99 cap, an empty batch, a derived impact
  in the batch's order and on paper, refusals, and a store before 013).
