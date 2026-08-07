# Root README Hotspot Decision

Reference for Issue #988 (`README.md` churn hotspot). Not auto-loaded.

## Executive summary

### Verdict: **KEEP** the single user-facing entry point; **deduplicate toward canonical owners**

Keep `README.md` as the repository's primary user-facing entry point. Do not split it. Apply
targeted deduplication: replace three unenforced catalog tables (Rule Files, Hook Scripts, Scripts
Library) with pointers to their canonical owners, and add a link from the FAQ worktree answer to
`ARCHITECTURE.md`. Leave the enforced Slash Commands table unchanged — `skill-catalog-lint.sh`
guards its one-row-per-skill contract and the two count-anchor prose strings.

The 2,000-word per-file warning does not apply here: `README.md` is a user-facing entry point,
not a rule or reference file in the auto-loaded corpus. Its 418 lines / 3,856 words are measured
at `main` `7e386a7` (2026-08-05, the HEAD at adjudication time).

## 1. Trigger and measured evidence

Issue #988 recorded 9 merged PRs touching `README.md` since 2026-07-21:
PRs #629, #644, #761, #775, #822, #833, #910, #931, #982.

Per-section churn attribution (traced from `gh pr diff` on each PR):

| Section | PRs | Classification |
|---------|-----|----------------|
| Slash Commands table — row add / remove / update | #629, #644, #761, #775, #822, #833, #910, #982 | **By-design** — enforced by `skill-catalog-lint.sh`; one-row-per-skill contract |
| "What You Get" slash-command count bullet | #629, #644, #775, #822, #833, #910 | By-design — `skill-catalog-lint.sh` checks the count anchor |
| Hook Scripts table — row description update | #931 | Unenforced — drifts from `.claude/hooks/README.md` |
| Config Files table — row description update | #931 | Unenforced — minor, no canonical owner with enforced sync |
| Rule Files table — row description update | #982 | Unenforced — drifts from `CLAUDE.md` §Rule Files |
| Scripts Library table — row add / update | #629, #761 | Unenforced — drifts from `.claude/scripts/README.md` |

**Primary driver:** 8 of 9 PRs touched the Slash Commands table — intentional, lint-enforced
churn that cannot be eliminated without removing the skill catalog from `README.md`. This is
accepted by-design churn.

**Secondary drivers:** The three unenforced catalog tables (Rule Files, Hook Scripts, Scripts
Library) and the FAQ worktree answer are the reducible portion. They restate content that has a
single canonical owner elsewhere and no enforcement mechanism keeping them in sync.

The `repo-audit-2026-05.md` §Section A already flagged the FAQ/ARCHITECTURE duplication as
unaddressed: "README — large FAQ is user-friendly but duplicates `ARCHITECTURE.md`; keep FAQ,
move deep architecture sentences behind one link."

## 2. Options considered

### Option 1: Split `README.md` into multiple files

**Rejected.** `README.md` is a cohesive user-facing entry point. GitHub renders it at the repo
root; external links and onboarding documentation point here. Splitting would fragment a surface
that readers navigate as a single document and produce no enforcement gain — each fragment would
still require manual updates when skills, hooks, or scripts change.

### Option 2: Extract one or more sections to a reference doc

**Rejected.** The unenforced sections (Rule Files, Hook Scripts, Scripts Library) duplicate content
that already has a designated owner. Extraction would create a third copy, not reduce duplication.
The enforced Slash Commands table must stay canonical in `README.md` because `skill-catalog-lint.sh`
reads `README.md` directly.

### Option 3: Keep + deduplicate toward canonical owners (this remediation)

**Chosen.** Replace the unenforced tables with brief pointers to their canonical files, and add
a link from the FAQ worktree answer to `ARCHITECTURE.md`. The Slash Commands table remains
unchanged. This closes the repo-audit finding, removes the surfaces that drift, and keeps
`README.md` a working entry point — pointers name their targets clearly so no user value is lost.

### Option 4: No remedy — close as by-design churn

**Rejected.** The Slash Commands table's churn is by-design, but the three unenforced catalog
tables and the FAQ duplication are not. The repo audit's specific unaddressed finding justifies
a targeted remediation.

## 3. Ownership boundaries

| Content | Canonical owner | Non-owner action |
|---------|-----------------|-----------------|
| Slash Commands catalog (one row per skill, count anchors) | `README.md` — `skill-catalog-lint.sh` enforces it | Skills must add a row here; the lint CI blocks omissions |
| Rule file index (area-grouped, loading semantics) | `CLAUDE.md` §Rule Files — `rule-lint.sh` enforces the index | `README.md` points to `CLAUDE.md` §Rule Files |
| Hook script manifest (per-hook event, purpose, auto-registration) | `.claude/hooks/README.md` — maintained alongside the hooks | `README.md` points to `.claude/hooks/README.md` + `ARCHITECTURE.md#hook-lifecycle` |
| Script contracts (arguments, exit codes, contracts) | `.claude/scripts/README.md` — maintained alongside the scripts | `README.md` points to `.claude/scripts/README.md` |
| Worktree architecture rationale (skills worktree, config availability) | `ARCHITECTURE.md` §Skills Worktree | `README.md` FAQ links into `ARCHITECTURE.md` |
| User-facing worktree isolation summary | `README.md` FAQ — short user-friendly answer | Points to `ARCHITECTURE.md` for full rationale |

## 4. Remediation applied

The following changes were made to `README.md`:

1. **FAQ "Why does the config require worktrees?"** — kept the two-sentence user-friendly
   explanation; added a link to `ARCHITECTURE.md#skills-worktree` for the full rationale.

2. **Rule Files section** — replaced the 16-row table restating each rule's purpose with a
   pointer to `CLAUDE.md` §Rule Files (the CI-enforced canonical index) and a note that each
   file's header block states its scope.

3. **Hook Scripts section** — replaced the 13-row table restating each hook's event and purpose
   with a pointer to `.claude/hooks/README.md` (per-hook detail) and `ARCHITECTURE.md#hook-lifecycle`
   (sequence context). Kept the auto-registration note in brief (it is not duplicated elsewhere).

4. **Scripts Library section** — replaced the multi-row table restating each script's purpose
   with a pointer to `.claude/scripts/README.md` (the canonical contract list). This section
   already carried a pointer in its closing line; the table itself was the duplication.

5. **Slash Commands table** — unchanged. `skill-catalog-lint.sh` enforces the one-row-per-skill
   contract and the two count-anchor prose strings ("X slash commands" / "All X commands are invoked").

## 5. Preserved invariants

The following constraints must survive any future edit to `README.md`:

- **Slash Commands table** — must remain canonical in `README.md`; `skill-catalog-lint.sh`
  reads the `## Slash Commands` section directly. Every skill directory in `.claude/skills/`
  must have a row; phantom rows are errors. The table must not be moved or renamed.
- **Two count anchors** — the prose string matching `/[0-9]+ slash commands/` (in "What You Get")
  and the string matching `/All [0-9]+ commands are invoked/` (in the Slash Commands section intro)
  must each appear exactly once, with the count matching the table row count.
- **`<!-- churn-hotspot: README.md -->` marker** — must remain present for the detector to
  recognize the issue as actionable; do not remove it from the issue body.
- **Documentation map** — the `## Documentation map` table must remain consistent with the
  actual set of top-level docs and reference directories; no lint enforces it, so check it
  on structural changes.

## 6. Verification and future edits

**Lints that must pass after any edit:**

- `bash .github/scripts/skill-catalog-lint.sh` — verifies the Slash Commands table
- `bash .github/scripts/rule-lint.sh` — verifies rule corpus word count + index alignment
- `bash .github/scripts/verbatim-block-lint.sh` — verifies verbatim blocks in rules
- `.claude/scripts/reference-catalog-lint.sh` — verifies this decision record is cataloged

**Future edits:**

- **Adding a skill** — add a row to the Slash Commands table; the lint will fail on push if
  omitted. Do not add rows to the now-removed Rule Files / Hook Scripts / Scripts Library tables
  in `README.md`; update the canonical owner instead.
- **Adding a hook** — update `.claude/hooks/README.md`; the `README.md` pointer requires no
  change unless the section heading in `.claude/hooks/README.md` moves.
- **Adding a script** — update `.claude/scripts/README.md`; the `README.md` pointer requires
  no change.
- **Adding a rule** — update `CLAUDE.md` §Rule Files (enforced by `rule-lint.sh`); the
  `README.md` pointer requires no change.

Lint-enforcing the unenforced catalog tables (Hook Scripts, Config Files) is future work — it
was not part of this remediation because no mechanical check currently exists for those surfaces.

## 7. Related precedent

- `monitor-mode-hotspot-decision.md` — KEEP + dedup when one concrete downstream restatement
  existed; pointer approach applied there as well.
- `agents-readme-hotspot-decision.md` — KEEP when churn is coordinated policy propagation into
  an operative doc surface; model-naming section kept because lint tooling references it by heading.
- `claude-md-hotspot-decision.md` — KEEP when frequent updates reflect a cohesive loaded contract.
- `fixpr-hotspot-decision.md` — extraction justified when large deterministic command forms drive
  churn; tables pointing to canonical owners are the analogous move for user-facing docs.
- `repo-audit-2026-05.md` §Section A — original finding that flagged the FAQ/ARCHITECTURE
  duplication as unaddressed; this remediation closes it.
- `churn-hotspots.md` — the detector is observational; adjudication decides whether a structural
  remedy exists.
