# CONTRIBUTING.md Hotspot Decision

Reference for Issue #1061 (`CONTRIBUTING.md` churn hotspot). Not auto-loaded.

## Executive summary

### Verdict: **KEEP** the single contributor-mechanics document; **no content change**

Keep `CONTRIBUTING.md` as the repo's sole canonical contributor guide. Do not split it, extract
any section, or deduplicate toward another file. Its churn records four feature-landing doc updates
in separate sections, each tracking a distinct infrastructure improvement. The file has a single
unifying purpose — how to change this repo — and its overlaps with `CLAUDE.md` and `.claude/rules/`
are thin linked cross-references, not unenforced duplicated content.

This decision is intentionally reference-only. `CONTRIBUTING.md` remains byte-for-byte unchanged.

## 1. Trigger and measured evidence

Issue #1061 recorded 4 merged PRs touching `CONTRIBUTING.md` since 2026-07-30:
PRs #830, #921, #932, #946.

File measured at `main` as of adjudication: **133 lines / 1,523 words** (no size lint governs
`CONTRIBUTING.md`; the 2,000-word per-file warning applies only to auto-loaded rule files).
No conflict rounds recorded.

Per-section churn attribution (traced from `gh pr diff` on each PR):

| Section | PRs | Classification |
|---------|-----|----------------|
| Adding a Test — run command update | #830 | By-design: documents `run-python-tests.sh` extraction (Issue #771) |
| Adding a Test — shared test helper paragraph added | #921 | By-design: documents `lib/skill-bash.sh` + test-anchor pattern (Issue #888) |
| Adding a Test — compact mode block added | #946 | By-design: documents `--json` compact result contract (Issue #782) |
| Adding a New Rule — ratchet cap mechanics expanded | #932 | By-design: documents ratchet cap as visibility mechanism not the gate (Issue #879) |

**Primary driver:** all 4 PRs are feature-landing documentation updates. Each landed a new piece
of infrastructure (a script, a test helper, a compact output contract, a budget mechanism) and
updated the contributor guide in the same PR to keep it current. This is canonical "feature ships
→ doc follows" churn — not incoherence, not duplication.

**Secondary driver:** three of the four PRs (#830, #921, #946) touched the "Adding a Test" section
in sequence. This is expected: the test infrastructure is the fastest-evolving area of the repo,
and CONTRIBUTING.md is the correct place to reflect that.

## 2. Options considered

### Option 1: Split `CONTRIBUTING.md` into multiple files

**Rejected.** The file has 133 lines / 1,523 words and a single topic: how to contribute to this
repo. There is no independently consumed or size-driven section that justifies a separate file.
The churn is spread across two sections (Adding a Test, Adding a New Rule) by four distinct PRs —
not concentrated evidence of a structural problem.

### Option 2: Extract a section into a reference doc

**Rejected.** Every section serves an active contributor audience: PR workflow mechanics, adding
skills/rules/hooks/tests, and git hygiene. None of this is reference-only content; it is the
working checklist for contributors. Extracting any section would bury actionable contributor
guidance behind an indirect pointer.

### Option 3: Deduplicate toward canonical owners

**Rejected.** The overlap investigation (§3 below) found only thin linked cross-references, not
unenforced duplicated prose. There is no content in `CONTRIBUTING.md` that both exists in a
canonical rule file and is enforced there — the rule budget numbers in "Adding a New Rule" appear
in `CLAUDE.md`, but that entry explicitly routes the procedural detail to `CONTRIBUTING.md`. No
dedup edit is warranted.

### Option 4: Keep the file; no content change (this verdict)

**Chosen.** The file is cohesive, sub-threshold in size, has zero conflict rounds, and contains no
unenforced duplication. A record-only adjudication closes the observational ticket without
perturbing the contributor guide.

## 3. Ownership boundaries

| Content | Canonical owner | Non-owner action |
|---------|-----------------|-----------------|
| PR gate mechanics (merge gate, CI, test plan) | `.claude/rules/cr-merge-gate.md` | `CONTRIBUTING.md` §PR Workflow summarizes and links |
| Local review loop | `.claude/rules/cr-local-review.md` | `CONTRIBUTING.md` §PR Workflow links |
| Skill frontmatter contract | `.claude/skills/*/SKILL.md` (per-skill) | `CONTRIBUTING.md` §Adding a New Skill documents the fields |
| Skill authoring judgment | `.claude/reference/skill-authoring-patterns.md` | `CONTRIBUTING.md` §Adding a New Skill links |
| Skill symlink mechanics | `.claude/rules/skill-symlinks.md` | `CONTRIBUTING.md` §Adding a New Skill links |
| Rule corpus budget (executive policy) | `CLAUDE.md` §Rule File Size Guidelines | `CONTRIBUTING.md` §Adding a New Rule documents contributor mechanics |
| Ratchet cap policy and rationale | `.claude/reference/budget-cap-raise-decision.md` | `CONTRIBUTING.md` §Adding a New Rule links |
| Hook event contracts and auto-registration | `ARCHITECTURE.md` | `CONTRIBUTING.md` §Adding a New Hook links |
| Test discovery contract and runner commands | `CONTRIBUTING.md` — single source for contributors | `.github/workflows/hook-scripts.yml` is the CI implementation |
| Git pre-commit hook mechanics | `CONTRIBUTING.md` — single source for contributors | No separate canonical doc |

## 4. Remediation applied

None. `CONTRIBUTING.md` is unchanged.

The duplication check (§3) found no unenforced prose duplicated from a canonical rule or reference
file. The "Adding a New Rule" ratchet cap numbers match `CLAUDE.md`, but the entry in
`CONTRIBUTING.md` is the procedural detail that `CLAUDE.md`'s brief executive summary deliberately
routes here — this is the intended "executive in `CLAUDE.md`, mechanics in `CONTRIBUTING.md`"
split, not duplication.

## 5. Preserved invariants

The following constraints must survive any future edit to `CONTRIBUTING.md`:

- **Rule budget numbers** — the 12,000/13,000 word gates and the per-file 2,000-word limit in
  §Adding a New Rule must stay consistent with `CLAUDE.md` §Rule File Size Guidelines and
  `.coderabbit.yaml`. Both sites must update together on any budget change.
- **Ratchet cap mechanics** — the `--update-cap --allow-raise` instructions in §Adding a New
  Rule must stay consistent with `rule-lint.sh`'s actual behavior.
- **Test runner commands** — the `run-hook-tests.sh` and `run-python-tests.sh` commands in
  §Adding a Test must stay consistent with the scripts' actual behavior and the CI workflow.
- **Compact mode output** — the `--json` flag and sample output in §Adding a Test must stay
  consistent with `compact-result-contract.md` and the runners' actual output.
- **`<!-- churn-hotspot: CONTRIBUTING.md -->` marker** — must remain in the issue body for the
  detector to track it; do not remove from the issue.

## 6. Verification and future edits

**Lints that must pass after any edit touching this record:**

- `.claude/scripts/reference-catalog-lint.sh` — verifies this decision record is cataloged
- `bash .github/scripts/rule-lint.sh` — verifies rule corpus budget (not applicable to `CONTRIBUTING.md` itself)
- `bash .github/scripts/verbatim-block-lint.sh` — verifies verbatim blocks in rules

**Future edits to `CONTRIBUTING.md`:**

- **Feature doc updates** are expected and welcome — when a new script, helper, or contract
  lands, update the relevant section. This is the pattern all four churn PRs followed.
- **Rule budget number changes** require updating both `CLAUDE.md` §Rule File Size Guidelines
  and `CONTRIBUTING.md` §Adding a New Rule in the same PR.
- **Reconsider splitting** only if the file crosses the auto-loaded 2,000-word per-file warning
  (it is currently at 1,523 words with ~477 words of headroom) or if an independently consumed
  section emerges that an external audience reads without the rest.

## 7. Related precedent

- `root-readme-hotspot-decision.md` — KEEP + dedup for `README.md`; unenforced catalog tables
  replaced with pointers. Applied because concrete unenforced duplication was found; no
  equivalent found in `CONTRIBUTING.md`.
- `claude-md-hotspot-decision.md` — KEEP with no content change for `CLAUDE.md`; recent
  compression passes already addressed the reducible portions. Same record-only pattern applied
  here.
- `skill-first-hotspot-decision.md` — KEEP with no content change; mixed-cause churn with no
  confirmed duplication. Classification mirrors this decision.
- `churn-hotspots.md` — the detector is observational; adjudication decides whether a structural
  remedy exists. Four by-design feature-landing edits do not constitute a structural problem.
