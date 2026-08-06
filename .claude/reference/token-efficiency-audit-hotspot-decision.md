# Token-Efficiency Audit Hotspot Decision

Reference for Issue #1021 (`.claude/reference/token-efficiency-audit-2026-07.md` churn hotspot).
Not auto-loaded.

<!-- churn-hotspot: .claude/reference/token-efficiency-audit-2026-07.md -->

## Executive summary

### Verdict: **KEEP** the single audit-and-playbook file; **no runtime change**

Keep `.claude/reference/token-efficiency-audit-2026-07.md` as the durable record for the July 2026
token-efficiency research, its adopt/skip/adapt verdicts, and per-FU closure sections. Do not split
it, extract sections, or merge it into another file.

The 5 flagged PRs fall into three causal classes: one initial authoring commit, two inline FU
closure notes (marking shipped items with strikethrough + implementation detail), and two full FU
evaluation sections appended at the bottom. Every touch was non-conflicting — no two PRs ever
competed on the same section — and every append was the designed outcome of a follow-up item
reaching resolution. This is the identical append-per-FU-resolution shape that
`local-review-cli-failure-modes-hotspot-decision.md` and `scheduling-failure-modes-hotspot-decision.md`
both adjudicated as KEEP.

## 1. Trigger and current evidence

Issue #1021 was filed by `/wrap` churn detection after PR #1020 merged. The issue body records 5
distinct merged PRs since 2026-07-28: PRs #774, #931, #946, #1016, #1020.

At diagnosis time the file is approximately 3,800 words. It is a reference file (not auto-loaded),
so the 2,000-word per-file warning that gates `.claude/rules/*.md` files does not apply here.
The file is organized into: a Verdict section, five cost-surface tables, adopt/skip/adapt verdict
tables by concern, a ranked recommendations table, guardrails, a cargo-cult list, key numbers, and
sources — followed by growing FU-resolution sections at the bottom.

The 5 PRs map to three causal classes:

| Churn class | PRs | What changed |
|---|---|---|
| Initial authoring | PR #774 | Created the entire audit file as primary deliverable for Issue #773; shipped FU-3/FU-7 references with pending status |
| FU closure notes (inline strikethrough + implementation detail) | PRs #931, #946 | Marked FU-3 (statusline, PR #931) and FU-7 (compact result contracts, PR #946) as shipped; added implementation notes and caveats inline using `~~` strikethrough |
| FU resolution appended sections | PRs #1016, #1020 | Appended the full FU-1 Verification section (subagent inheritance, PR #1016) and the full FU-4 Evaluation section (poller model-routing, PR #1020) at the bottom of the file |

**Non-conflicting growth.** No two PRs edited the same section. PRs #931 and #946 edited the
inline FU status entries in the Follow-ups section and ranked table, each touching separate FU
items. PRs #1016 and #1020 each appended an entirely new section at the bottom of the file.
There were no rebase-conflict rounds.

**Designed lifecycle.** The file was authored with an explicit FU-1 through FU-7 list at the
bottom. Each entry says "resolve via follow-up issue." The mechanism — appending a resolution
section and/or updating the inline status entry — is the natural completion path the file itself
describes. The churn is the design working as intended.

## 2. Options considered

### Option 1: KEEP (no runtime change) — **Chosen**

Record the by-design KEEP decision and leave the file byte-for-byte unchanged. No sections
extracted, no follow-up issues filed, no dedup of other files against this one.

**Chosen.** The file's scope is "durable record of the token-efficiency research and its
resolution progress." The FU-resolution appends are the designed completion path; each one
closes a pending item and records the outcome for future reference. Non-conflicting, sequential,
and scoped to one research topic. This is the same rationale as `local-review-cli-failure-modes.md`
and `scheduling-failure-modes.md`, whose churn was adjudicated KEEP under the same "intentional
append-only log" framing.

### Option 2: Extract FU-resolution sections into per-FU files

Move each FU evaluation section (FU-1, FU-4, and future ones) into separate reference files
(e.g., `token-efficiency-fu1-verification.md`).

**Rejected.** The FU sections are evidence closures for the parent audit. Each section
cross-references the parent's recommendations table ("Ranked #3 in the table above", "the FU-4
entry"), the parent's cost-surface analysis, and each other (FU-4 cites the Monitor primitive
constraint documented in the parent's fan-out table). Splitting them breaks that logical chain
without reducing churn, because each new FU resolution would still need to update the parent's
inline status entry and create a new fragment. Extraction precedent (`fixpr-hotspot-decision.md`)
applies only when the extracted content is deterministic/mechanical and has no shared-mechanism
dependency with the parent.

### Option 3: SPLIT the audit into per-topic reference files

Break the audit into, for example, `token-efficiency-monitoring.md`, `token-efficiency-models.md`,
`token-efficiency-context.md`.

**Rejected.** The tables cross-reference each other: the ranked recommendations table links the
cost surface analysis, the adopt/skip/adapt tables, and the FU index. Splitting would force
readers to open three files to reconstruct the ranked priority ordering. The SPLIT precedent
(`escalate-review-test-hotspot-decision.md`) applies where sections have independent authors and
no shared-mechanism dependency. These sections were authored in one commit as an integrated
research record; their cross-references are the point.

## 3. Canonical ownership boundaries

| Concern | Owner | Non-owner action |
|---|---|---|
| One-line heartbeat contract and delta-table rule | `.claude/rules/monitor-mode.md`, `CLAUDE.md` §3 | Audit references these; do not copy operative directives here |
| PMM dispatcher / references / scripts split (FU-2) | Yet to be done; target skill and reference files are TBD | Audit carries the plan; resolution will append a FU-2 section when ready |
| Subagent rule inheritance model (FU-1 resolved) | `CLAUDE.md`, `.claude/rules/subagent-orchestration.md`, `.claude/rules/skill-first.md` | Audit's FU-1 section is the verification record; policy lives in those rule files |
| Model routing defaults (FU-4 resolved) | `.claude/rules/subagent-orchestration.md` §Model Selection | Audit's FU-4 section is the evaluation record and re-check triggers; defaults live in the rule |
| FU-5 rule-corpus kernel / path-scoping | Future; tied to #768/#770 | Audit carries the plan; resolution will append a FU-5 section when ready |
| FU-6 measurement baseline (MCP pruning, ccusage) | Future; tied to #710 | Audit carries the plan |
| Token-efficiency research record and adopt/skip/adapt verdicts | `.claude/reference/token-efficiency-audit-2026-07.md` | Append FU closures; do not copy audit verdicts into rule files |

## 4. Preserved invariants

- For this PR: `.claude/reference/token-efficiency-audit-2026-07.md` stays byte-for-byte unchanged.
- Future FU closures (FU-2, FU-5, FU-6) should append a new section and update the inline
  status entry in the Follow-ups list — exactly the pattern PRs #931, #946, #1016, and #1020
  established. No structural change to the parent file is needed.
- The `§FU-1` and `§FU-4` section anchors (implied by the level-2 headings at the bottom of
  the file) are referenced by the ranked recommendations table's Status column. Any future rename
  of those sections must update the table row's Status cell in the same commit.
- The cargo-cult list, key numbers table, and sources section are point-in-time audit content.
  They must not be updated to reflect later harness changes — those belong in a new FU section
  or a separate follow-up audit.

## 5. Remediation and verification

The only changes in this PR are:
1. This decision record (`.claude/reference/token-efficiency-audit-hotspot-decision.md`).
2. One catalog bullet in `.claude/reference/README.md`.

No rule, script, reference doc, or agent file is modified. `reference-catalog-lint.sh` must
pass with exactly one registered bullet for the new decision doc and no phantom entries.

## 6. Future edits and reconsideration

A future PR resolving FU-2, FU-5, or FU-6 should append a new `## FU-N …` section and update
the inline status entry — that is the expected pattern and is not a reason to reopen this
decision.

Reconsider if:
- A future PR re-edits an *existing* section (other than updating an inline FU status from
  pending to shipped), indicating competing ownership rather than sequential closure.
- Two PRs conflict on the same section of this file, signaling that it has become a live
  policy document rather than a point-in-time audit record.
- The file word count grows beyond ~6,000 words (roughly double the current 3,800), at which
  point extracting individual FU evaluation sections into per-FU reference files should be
  reconsidered — though only if their cross-references to the parent can be replaced with
  stable anchor links.

## 7. Related precedent

- `.claude/reference/local-review-cli-failure-modes-hotspot-decision.md` — KEEP, no runtime
  change; identical "intentional append-only log" framing; the two decisions are named as
  explicit analogues in `scheduling-failure-modes-hotspot-decision.md` §7.
- `.claude/reference/scheduling-failure-modes-hotspot-decision.md` — KEEP, no runtime change;
  same "append-only incident evidence log" shape; §7 of that decision establishes the precedent
  this decision follows.
- `.claude/reference/review-substance-evidence-hotspot-decision.md` — KEEP, no runtime change;
  purposeful evidence accumulation where each PR appended a trace and design-reasoning section;
  splitting would destroy the cumulative argument.
- `.claude/reference/fixpr-hotspot-decision.md` — KEEP + extract precedent; contrasting case
  where deterministic command forms (not research prose) justified extraction.
- `.claude/reference/escalate-review-test-hotspot-decision.md` — SPLIT verdict; contrasting case
  where sections had independent authors and no shared-mechanism dependency.
- `.claude/reference/churn-hotspots.md` — hotspot mechanism, calibration, and re-open trigger
  logic.
