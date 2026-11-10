# `.claude/scripts/README.md` — SPLIT decision (Issue #898)

**Verdict: SPLIT.** The 243-line categorized script index became a thin index at
the same path plus one doc per category under `.claude/scripts/docs/`.

**Decided:** 2026-08-28, by the owner in chat. **Supersedes** the no-split
precedent **for this file only** — every other `*-hotspot-decision.md` in this
directory stands unchanged.

## What was decided, and against what

`/wrap`'s churn detector filed this file twice. Issue #795 (2026-07-31) closed
with its implementation plan merged and unimplemented. Issue #898 re-filed it,
and CodeRabbit's plan on that issue recommended **against** splitting, on the
grounds that one row per script is the file's design and the churn is therefore
by-design registration traffic rather than a structural defect.

The owner overrode that disposition. Two reasons:

1. **The churn doubled after #795 closed** — 10 distinct merged PRs in the
   recent window against the roughly 5-PR baseline recorded at decision time
   (`churn-hotspot-baselines.json` holds `score_at_decision: 5`,
   `pr_count_at_decision: 5`, `as_of: 2026-08-25`).
2. **The goal was never fewer edits.** One row per script is correct and stays
   correct. The goal is **independent editability**: two concurrent PRs adding
   scripts in different categories were colliding in one shared file, so the
   cost of the design was paid in rebases rather than in rows.

CodeRabbit's *recurrence-prevention* idea was adopted in full — the parity lint
below is its Phase 2, implemented. Only its disposition verdict was overridden.

## The structure

- **`.claude/scripts/README.md`** keeps its path, so every existing prose
  reference stays valid. It now holds the index-only note, the "adding a new
  script" instruction pointed at the category docs, a categories table, the
  `scripts/ vs hooks/` section, and an explicit out-of-scope note.
- **`.claude/scripts/docs/`** holds one doc per category, 1:1 with the previous
  headings. No categories were merged — that is a separate editorial decision
  nobody asked for. `utilities.md` absorbs the two Python helpers as its own
  subsection; `tests.md` carries the full tests table.
- **Every entry is a relative markdown link to the file itself**
  (`[pr-state.sh](../pr-state.sh)`). Relative links are the file's path in
  GitHub: clickable on github.com and in editors, and they survive branches and
  forks where an absolute URL goes stale. Each category doc links back to the
  index.

## Recurrence prevention

`.github/scripts/scripts-catalog-lint.sh` (with
`.github/scripts/tests/scripts-catalog-lint.test.sh`) enforces five invariants:
exactly one row per in-scope file, every link resolving to the file its text
names, index↔docs bijection, a back-link in every category doc, and an index
that links only into `docs/`. It is discovered by `run-doc-lints.sh`'s
`*-lint.sh` glob and its test by `run-hook-tests.sh`, so neither needed a
workflow edit.

**Scope boundary** (pinned by passing test cases, not only by prose): in scope
are `.claude/scripts/*.sh`, `.claude/scripts/*.py` at the top level, and
`.claude/scripts/tests/*.test.sh`. Out of scope are `lib/` (sourced helper
libraries and `jq` programs), `tests/lib/`, `tests/fixtures/`, and non-script
files such as the launchd `.plist`.

## Drift found while splitting

The pre-change README indexed **130** entries against **182** in-scope files —
**52 undocumented** (15 scripts, 37 tests), about 29% of the catalog, with zero
phantom rows. Those 52 gained rows in this change so the lint could be adopted
without a grandfather allowlist, which would have rotted immediately. The
measured gap is itself the argument for the lint: registration traffic that
looks by-design in the churn data was, a third of the time, not happening at all.

## For future churn-hotspot runs

A re-file of this file is **not** a re-file of a consciously-dropped decision.
Issue #795 was dropped, issue #898 was implemented, and the churn signal that
drove it was real. Classify a future `.claude/scripts/README.md` hotspot against
this record rather than against issue #795's closure, and expect the index
itself to be nearly
churn-free from here — new scripts now register in a category doc.

## Cross-references

- Issue #795 — first filing; closed with plan merged, unimplemented
- Issue #898 — this decision; CodeRabbit's counter-plan lives in the issue body
  above the `## Implementation Plan` section
- `churn-hotspots.md` — detector/classifier division and suppression policy
- `churn-hotspot-baselines.json` — the recorded score this file was judged against
- `root-readme-hotspot-decision.md` — point-in-time record whose "adding a
  script → update `.claude/scripts/README.md`" line predates this split; the
  path it names is unchanged, and the row now lands in a category doc under it
