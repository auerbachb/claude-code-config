# `.claude/scripts/` catalog — GENERATE decision (Issue #1578)

**Verdict: GENERATE.** The per-script rows in `.claude/scripts/docs/*.md`, the
Categories table in `.claude/scripts/README.md`, and the catalog entries in
`.claude/reference/churn-hotspot-exemptions.json` are now derived from the
directory contents by `.github/scripts/scripts-catalog-gen.sh`. The two things a
human still writes — the category id and the description — moved into the file
they describe.
`.github/scripts/scripts-catalog-lint.sh` changed from a **row-authoring check**
into a **drift check**.

**Decided:** 2026-09-05, adopting CodeRabbit's plan on issue #1578 including
both of its design verdicts. **Extends** the issue #898 split rather than
reversing it: the index and the per-category docs stay exactly where they are,
browsable and committed.

## What was decided, and against what

Issue #898 split the shared script index into an index plus one doc per
category, and the catalog lint made the split authoritative: every script and
test needed exactly one hand-written row or CI failed. That bought accuracy and
paid for it twice.

- **Churn no refactor can retire.** Issue #1571 had to invent an exemption
  mechanism and exempt `.claude/scripts/README.md` and
  `.claude/scripts/docs/tests.md` from hotspot scoring, because the lint itself
  is what forces the edit. PR #1574 implemented that, and its own notes flagged
  generation as the real fix while deliberately leaving it out of scope.
- **A recurring merge-conflict surface.** Concurrent PRs adding rows to the same
  alphabetical region of `tests.md` collided; a base-commit overlap there forced
  a rebase on PR #1543 on 2026-09-01.

Three options were on the table.

1. **Description and category id in each file's own header.** Chosen. Adding a
   script becomes a single-file change: the file that is new is the only file
   edited. It reuses the header-comment convention `--help` extraction already
   depends on (`.claude/scripts/tests/help-output.test.sh`), so the description
   sits next to the contract it summarises.
2. **A sidecar registry** (one JSON keyed by path). Rejected: it reintroduces
   exactly one shared, merge-prone file — the problem, relocated.
3. **Generate only the surrounding structure, keep descriptions in the docs.**
   Rejected: it removes none of the authoring churn, which is the point.

And, separately, where the generated rows live.

1. **Committed docs with a generated region.** Chosen. The browsable in-repo
   catalog that #898 deliberately created survives, the repo convention of
   committed markdown plus check-only lints holds, and a region two branches
   both regenerated is resolved by re-running the generator instead of by
   reading a diff.
2. **CI-only tables, not committed.** Rejected: it eliminates textual conflicts
   completely, but by deleting the browsable catalog — reversing #898 rather
   than completing it.

Because option 1 leaves the generated region changing on each script add, the
issue #1571 exemption is **retained**, with an updated reason and a wider
scope: see "Exemptions are generated too" below.

## The structure

**What a human writes.** One line in each in-scope file's leading comment block:

```text
# catalog: <category-id> — <one-line description>
```

`<category-id>` is the filename stem of the owning doc under
`.claude/scripts/docs/`. Descriptions were migrated verbatim from the rows they
replace, so no description regressed. In scope, unchanged from the previous
lint: `.claude/scripts/*.sh`, `.claude/scripts/*.py`, and
`.claude/scripts/tests/*.test.sh` — `lib/`, `tests/lib/`, `tests/fixtures/`, and
non-script files stay out.

**What a category doc declares about itself**, so that adding a category means
adding a file and never editing a shared registry:

```text
<!-- catalog:category id=<id> order=<N> -->
<!-- catalog:covers <one-line summary for the index> -->
```

The doc's H1 supplies the category title; `order` places its row in the index.

**What the generator owns**, and nothing else:

| File | Region |
|------|--------|
| `.claude/scripts/docs/<id>.md` | `<!-- catalog:rows:begin [kind=sh\|py] -->` … `<!-- catalog:rows:end -->` |
| `.claude/scripts/README.md` | `<!-- catalog:categories:begin -->` … `<!-- catalog:categories:end -->` |
| `.claude/reference/churn-hotspot-exemptions.json` | entries stamped `generated_by` |

Everything outside those regions is human-edited and untouched: prose, the table
header rows (so each doc keeps its own `| Script | Purpose |` vs
`| Test | What it covers |` wording), `utilities.md`'s `## Python helpers`
subsection, `tests.md`'s trailing prose, every back-link, and the exemption
file's `source` block. `kind=py` exists because `utilities.md` carries two
tables; a file whose category doc has no region for its kind is reported as
unplaced rather than silently dropped.

**Row order is `LC_ALL=C` by link text for every doc**, tie-broken by path (the
top-level/`tests/` namesake pair of issue #1452 renders identically, so it has
no visible order of its own). This **supersedes issue #1544's** per-doc
`<!-- catalog-lint: ordered -->` opt-in and the workflow-role grouping the other
twelve docs used. That grouping was a real editorial choice, and it is the cost
of this change: mechanical order is what makes a conflicting region resolvable
by re-running the generator, and hand-curated order is what made the region
worth conflicting over. The marker and the lint check that read it are removed.

## Exemptions are generated too

The issue asked for the exemption list to be derivable from directory contents,
and it now is. Every catalog file the generator owns a region in gets an entry
stamped `"generated_by": ".github/scripts/scripts-catalog-gen.sh"`, built from
the same enumeration as the rows. Three properties matter:

- **The list cannot fall behind the docs.** Add a category doc, regenerate, and
  its exemption entry exists. Nobody has to remember.
- **The exit-3 guard is unweakened.** Generated entries carry a non-empty `lint`
  naming the enforcing check and a non-empty `reason` stating why it forces the
  edit, so `churn-hotspots.sh` validates them exactly as it validates a
  hand-written entry. Exemption still cannot be claimed by assertion.
- **Hand-written entries are preserved verbatim.** The generator rewrites only
  stamped entries; an entry without the stamp is somebody's deliberate,
  hand-argued exemption and is passed through untouched.

Scope widened from #1571's two files to the index plus all thirteen category
docs. Each qualifies on identical grounds — a lint-enforced generated region —
and `as_of` is carried forward from the committed entry when one exists, so a
re-run on an unchanged tree is a no-op rather than a date churn of its own.

## Recurrence prevention

- **`.github/scripts/scripts-catalog-gen.sh`** — `--write` rewrites the regions,
  `--check` regenerates into a temp buffer and exits 1 on drift, naming each
  stale file. It also rejects a missing or malformed `# catalog:` declaration, a
  category id with no doc, a doc with no declaration or no rows region, a
  duplicate category id, and a file no region accepts.
- **`.github/scripts/scripts-catalog-lint.sh`** — auto-discovered by
  `run-doc-lints.sh`, so CI needs no workflow edit. It checks the two properties
  generation cannot make structural — every category doc's back-link, and the
  absence of a hand-written row *outside* a generated region (which regeneration
  would otherwise preserve forever, unchecked) — and delegates everything else
  to `scripts-catalog-gen.sh --check`. Delegating rather than reimplementing is
  deliberate: a second spelling of "in scope" or of "the row format" is how a
  generator and its drift check start disagreeing. The shared enumeration, the
  header reader, and the row formatter live once, in
  `.github/scripts/lib/lint-common.sh`.
- **Checks deliberately removed**, because deterministic generation makes them
  structural rather than validated: coverage and uniqueness (every in-scope file
  contributes exactly one row by construction), link integrity and link-text
  agreement (the target is computed from the path), index purity (the index
  table is generated from the category declarations and cannot hold a per-script
  row), and per-doc row ordering.
- **Tests:** `.github/scripts/tests/scripts-catalog-gen.test.sh` and
  `.github/scripts/tests/scripts-catalog-lint.test.sh`, both auto-discovered by
  `hook-scripts.yml`. The generator suite runs against hermetic fixture trees
  and never mutates the repo; both suites end by asserting the real tree passes.

## Cross-references

- Issue #1578 (this decision), issue #1571 / PR #1574 (the exemption mechanism
  this completes), PR #1543 (the rebase that made the conflict surface concrete)
- Issue #898 / `scripts-readme-split-decision.md` — the split this extends
- Issue #1544 — the per-doc row-ordering opt-in, superseded here
- Issue #1452 — path-keyed entry identity, why the sort tie-breaks on path
- `churn-hotspots.md` — the detector, the exemption contract, and the
  `generated_by` stamp
- `.claude/reference/churn-hotspot-exemptions.json` — the exemption list itself
