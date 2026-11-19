# `.claude/reference/README.md` — SPLIT decision (Issue #2188)

**Status: DECIDED — SPLIT.** The owner recorded the verdict on Issue #1996
([comment](https://github.com/auerbachb/claude-code-config/issues/1996#issuecomment-7023463332),
2026-11-19, answered in chat as question U-6), which satisfies Issue #2188's
first acceptance criterion. The 9,856-word categorized reference index becomes a
thin index at the same path plus one catalog page per category under
`.claude/reference/catalog/`. The owner can reverse it: a later recorded KEEP on
Issue #1996 reopens the question (see Reconsideration conditions).

**Decided:** 2026-11-19, from Issue #2188's Proposed solution. Before this, the
only KEEP on the churn-hotspot report (Issue #1996) was a CodeRabbit proposal,
never an owner verdict. This supersedes the Issue #816 keep decision
(append-only catalog with a completeness lint) **for this file only**, and the
completeness lint, kept, spans every catalog page.

## What was decided, and against what

The file was touched by 56 merged PRs in the 60 days to 2026-11-10, the highest
of any tracked file, and about 94% of its words are index entries that cite
issues. Every PR that adds a reference doc edits the same file, so unrelated PRs
conflict on it (one real conflict was recorded in PR #1983), and an agent that
wants one index line reads about 9,900 words.

The same shape was solved for `.claude/scripts/README.md`
(`scripts-readme-split-decision.md`). The goal here is the same one stated
there: not fewer rows, but **independent editability** — two PRs that register
docs in different categories no longer collide in one file.

## The structure

- **`.claude/reference/README.md`** keeps its path and all nine legacy heading
  lines, so every existing anchor stays valid. Each category heading now holds
  one link to its catalog page. The audit-snapshot exemption blockquote stays
  verbatim under its legacy heading, so the standing references to it need no
  rewrite.
- **`.claude/reference/catalog/`** holds seven pages, 1:1 with the previous
  `###` categories: `schemas.md`, `runbooks.md`, `workflow-pm-helpers.md`,
  `living-trackers.md`, `audits-and-research.md`, `diagrams.md`,
  `verification-logs.md`. Entries moved byte-for-byte and in order.
- Entries stay inline code, not links, so no moved line changed.

## Recurrence prevention

`reference-catalog-lint.sh` reads the hub for `catalog/` links, then parses
every page. It enforces one entry per root `.md`/`.json` file across all pages,
no phantoms, no duplicates within or across pages, a one-to-one match between
linked pages and pages on disk, and no registration rows in the hub.
`diagrams/` rows stay out of file parity, as before.

## Expected benefit, and what remains

Registrations in different categories no longer touch the same file. Contention
within one category remains: the audits page is the largest and will stay the
hot spot. If it keeps drawing conflicts, split it by year.

## Reconsideration conditions

- A recorded owner KEEP on Issue #1996 for this file.
- One catalog page being touched by more than 25 merged PRs in a 60-day window.
- A new category added to the hub (edit the hub, add a page; the lint enforces
  the link).

## Cross-references

- Issue #816 — earlier keep decision, superseded for this file only
- Issue #1996 — churn-hotspot report for this file
- Issue #2188 — this decision
- `scripts-readme-split-decision.md` — the precedent this follows
- `churn-hotspots.md` — detector and classifier division
