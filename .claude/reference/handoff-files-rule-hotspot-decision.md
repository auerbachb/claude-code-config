# Handoff-Files Rule Hotspot Decision

Reference for Issue #943 (`.claude/rules/handoff-files.md` churn hotspot). Not auto-loaded.

Companion to `state-file-contracts-hotspot-decision.md` (Issue #1012, PR #1012), which covers the
expanded mechanism doc for the same state machinery that `handoff-files.md` governs. The churn
drivers overlap: both files were touched by the eight state-machinery evolution PRs (#625/#630,
#638/#659, #639/#662, #687/#694, #651/#698, #682/#718, #655/#724, #704/#728).

## Executive summary

### Verdict: **KEEP** the single rule file; **no operative changes**

Keep `.claude/rules/handoff-files.md` as the single auto-loaded binding rule governing agent
behavior around session state and handoff files. Do not split or restructure it. Apply no dedup
changes: the file's brief inline exit-code facts (exit 4, exit 6) are auto-loaded quick-reference
directives, not duplicated mechanism explanation, and must remain in the rule corpus for immediate
agent access. The existing pointer at line 21 ("Mechanism + migration:
`.claude/reference/state-file-contracts.md`") already routes to the full expanded rationale.

The dominant churn cause is by-design state-machinery evolution: every bug fix or feature to the
session-state or handoff infrastructure must also update the binding rule file that agents
auto-load to govern that same behavior. Three corpus compression sweeps are the secondary cause.
Neither warrants structural change.

## 1. Trigger and measured evidence

Issue #943 was filed after 11 merged PRs touched `handoff-files.md` since 2026-07-19.

| PR | Issue | Merged | Title | Churn class |
|----|-------|--------|-------|-------------|
| #630 | #625 | 2026-07-21 | fix: enforce field-type contract in session-state.sh | State-file bug fix (field-type enforcement) |
| #659 | #638 | 2026-07-21 | fix: scope session-state.json per repo | State-file bug fix (repo scoping) |
| #660 | #646 | 2026-07-21 | refactor: condense rule corpus 12232→10921 words | Corpus compression |
| #662 | #639 | 2026-07-21 | fix: serialize session-state.json writes with a portable mkdir lock | State-file bug fix (write lock) |
| #694 | #687 | 2026-07-22 | fix: scope /pm orchestration to the invoking repo | State-file bug fix (read scope) |
| #698 | #651 | 2026-07-22 | fix: post-convergence audit of session-state.json | State-file bug fix (audit/repair) |
| #718 | #682 | 2026-07-23 | fix: serialize handoff-file writes behind the shared state lock | Handoff-file fix (write lock) |
| #724 | #655 | 2026-07-23 | feat: scope handoff files per repo | Handoff-file feature (repo scoping) |
| #728 | #704 | 2026-07-23 | fix: lowercase the repo scope key everywhere via a shared normalizer | State-file bug fix (key normalization) |
| #742 | #740 | 2026-07-24 | refactor: condense rule corpus 11969→11419 words | Corpus compression |
| #804 | #790 | 2026-07-30 | refactor: compress rule corpus 12166→10999 words | Corpus compression |

At diagnosis time (`main` `2a3abc8`), the file is 440 words — well below the 2,000-word per-file
warning. No merge conflicts are recorded across the 11 PRs.

**Churn-class breakdown:**

| Class | PRs | Count |
|-------|-----|-------|
| State-file bug fixes (session-state.json) | #630, #659, #662, #694, #698, #728 | 6 |
| Handoff-file infrastructure fixes/features | #718, #724 | 2 |
| Corpus compression | #660, #742, #804 | 3 |

## 2. Duplication evidence

Three short passages in `handoff-files.md` overlap with content in
`state-file-contracts.md`, which is the non-auto-loaded expanded mechanism companion for the same
machinery:

| Passage in `handoff-files.md` | Also in | Assessment |
|-------------------------------|---------|------------|
| "Both exit **6** on lock timeout — retry." (Writes §) | `state-file-contracts.md` §Write locks: "Both exit **6** on lock timeout; the caller retries." | Near-verbatim, 8 words; quick-reference directive — **keep** |
| "Wrong `--set` type exits **4** (unmodified)." (Field types §) | `state-file-contracts.md` §Field-type: "a `--set` carrying the wrong type exits **4** and leaves the file unmodified" | Near-verbatim, 6 words; quick-reference directive — **keep** |
| "**Never pass a raw jq filter as a `--set` value** — evaluate first." | `state-file-contracts.md` §Field-type: "The most common way to corrupt a field is passing a raw jq filter as a `--set` value" | Not verbatim; binding behavioral directive in the rule — **keep** |

**Key distinction from the state-file-contracts.md adjudication (Issue #1012):** That file kept
"Exit-code 6 contract, self-heal behavior, and the inline-jq ban" as "actionable and not restated
in the script headers." The analogous sentences in `handoff-files.md` are the auto-loaded rule
equivalents: they must exist in the rule corpus so agents can act on them without fetching a
non-auto-loaded reference file. The existing pointer at line 21
("Mechanism + migration: `.claude/reference/state-file-contracts.md`") already routes to the full
mechanism for any agent that needs it.

The `findings_dismissed` dedup-by-`.id` sentence (Forward compatibility §) has no equivalent in
`state-file-contracts.md`; it is unique to the handoff-file schema and is governed by
`handoff-file-schema.json`. Not a duplication target.

## 3. Decision: KEEP, no operative changes

**Splitting is rejected.** The file is 440 words — a sixth of the 2,000-word per-file warning.
The four sections (State Files, Handoff File Storage, Phase Operations table, Token Exhaustion
Handoff) describe a single coordinated mechanism from the agent's point of view. Splitting by
section would scatter binding directives across multiple auto-loaded files without reducing any of
the churn classes.

**Dedup changes are rejected.** The two near-verbatim overlaps (exit 6, exit 4) are each 6–8
words. Replacing them with pointer prose would yield the same byte savings as the pointer but
require agents to fetch `state-file-contracts.md` to recover the behavior fact. The auto-loaded
rule file's purpose is to make behavioral facts immediately available; the pointer at line 21
already serves as the extended-reading link. Removing the facts while the pointer exists would
invert the correct level of detail for each document.

**Churn is by design (dominant driver).** Eight of the eleven PRs made a targeted edit because the
machinery that the file governs changed. `handoff-files.md` IS the canonical behavioral contract
for session-state and handoff use. Any improvement to `session-state.sh`, `handoff-state.sh`, or
`state-lock.sh` that changes what agents must do will correctly produce a synchronized edit to
this file. This is the same pattern that `churn-hotspots.md` §churn-by-design documents for
canonical junction files; the companion file `state-file-contracts.md` and its decision record
(Issue #1012) both confirm the pattern.

**Corpus compression (three PRs)** is a secondary driver. These sweeps apply when total corpus
exceeds budget thresholds; they touch the largest rule files first. No structural change reduces
this driver.

## 4. Canonical ownership

| Content | Canonical owner | Role of `handoff-files.md` |
|---------|-----------------|---------------------------|
| Always/Never/Ask-first quick rules | `handoff-files.md` | Sole binding authority |
| Exit-6 lock timeout behavior | `state-file-contracts.md` §Write locks | Quick-reference fact only (6 words); pointer exists |
| Exit-4 type enforcement | `state-file-contracts.md` §Field-type | Quick-reference fact only (6 words); pointer exists |
| "Never pass raw jq filter" | `handoff-files.md` | Binding directive; not a mechanism explanation |
| Handoff file lifecycle (A→B→C→delete) | `handoff-files.md` and `phase-protocols.md` | Rule file supplies the lifecycle table; protocols own deletion timing |
| Phase Operations table | `handoff-files.md` | Sole owner; no equivalent in state-file-contracts.md |
| Forward-compatibility dedup rules | `handoff-files.md` pointing to `handoff-file-schema.json` | Schema is single source of truth |
| Expanded scoping, lock, migration rationale | `state-file-contracts.md` | Referenced by the pointer on line 21 |
| Token-exhaustion handoff fields | `handoff-files.md` pointing to `subagent-orchestration.md` + schema | Rule owns the trigger condition |

## 5. Preserved invariants

- `handoff-files.md` remains the single auto-loaded binding rule for all handoff and
  session-state behavior.
- The Always/Ask-first/Never header block is unchanged — all three behavioral directives
  (including "Write `session-state.json` outside `session-state.sh` or handoff files outside
  `handoff-state.sh`") are preserved verbatim.
- Exit-6 and exit-4 quick-reference facts remain in the rule corpus for immediate agent access.
- The "Never pass a raw jq filter" directive remains as a binding behavioral rule.
- The pointer on line 21 ("Mechanism + migration: `.claude/reference/state-file-contracts.md`.
  Canonical contracts: `session-state.sh --help`, `handoff-state.sh --help`, `state-lock.sh`
  header.") remains as the route to extended reading.
- No runtime code, scripts, tests, CI, skills, or agent definitions are changed.
- `reference-catalog-lint.sh` passes: one entry added to README.md, no phantoms, no duplicates.

## 6. Targeted remediation

No changes to `handoff-files.md`. Changes applied in this PR (Issue #943):

1. **`.claude/reference/handoff-files-rule-hotspot-decision.md`** — this decision record.
2. **`.claude/reference/README.md`** — one index line added to the "Audits and research"
   section, consistent with the twenty sibling records already present.

## 7. Reconsideration

Reconsider splitting if:
- The file grows past the 2,000-word per-file warning and has sections that change on clearly
  independent cadences.
- A new section is added that has no relation to session-state or handoff files and creates a
  cross-concern dependency for readers.

Reconsider dedup if:
- A verbatim multi-sentence block appears that duplicates a non-auto-loaded reference file,
  and removing it does not require agents to look up an external file to recover a needed fact.

Reconsider structural change if:
- Merge-conflict evidence accumulates (multiple rounds per PR from competing edits to the
  same section) — touch count alone is never sufficient justification.

Raw touch count alone is never a reason to restructure a binding rule file.
