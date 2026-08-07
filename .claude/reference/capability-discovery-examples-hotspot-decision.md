<!-- churn-hotspot: .claude/reference/capability-discovery-examples.md -->
# Capability Discovery Examples Hotspot Decision

Reference for Issue #1078 (`.claude/reference/capability-discovery-examples.md` churn hotspot). Not auto-loaded.

**Verdict:** KEEP (no structural change)
**Decided:** 2026-08-07
**Issue:** #1078
**Reporter:** `/wrap` post-merge churn report (PR #1077)

## 1. Trigger and current evidence

Issue #1078 was filed by `/wrap` churn detection after PR #1077 merged. The issue body records 3 distinct merged PRs since 2026-07-24: PR #762, PR #817, PR #858.

At diagnosis time the file is 118 lines / approximately 1,595 words. It is a reference file (not auto-loaded), organized into sections: header, GitHub false walls, provider-CLI false walls, scope-shaped deferrals with a worked example, rungs 1–3 in practice, web-only false walls (rung 4), real walls, and anti-pattern.

The file was created by PR #660 (merged 2026-07-21), predating the "since 2026-07-24" window in the issue report. The three flagged PRs are successive feature expansions of a pre-existing file, not repeated rework of the same content.

### Per-section churn attribution

| PR | Merged | Driving Issue | What changed in `capability-discovery-examples.md` |
|----|--------|--------------|------------------------------------------------------|
| PR #762 (`fix(#759): generalize capability discovery into an explicit CLI ladder`) | 2026-07-28 | Issue #759 | Renamed "Common false walls" to "Common false walls — GitHub"; added "Common false walls — provider CLIs" section with table of Railway/Vercel/Neon/Cloudinary commands; added "Rungs 1–3 in practice" section with worked bash examples; expanded real-walls section with structured runbook shape; updated anti-pattern paragraph |
| PR #817 (`fix(#810): fire the capability ladder on deferral, not on "impossible"`) | 2026-07-30 | Issue #810 | Added "Common false walls — scope, not capability" section: new category covering deferrals that never say "I can't" (reassignments, scope disclaimers); added worked example with railway variable-provisioning code block; updated heading reference from "Try the CLI Before Deferring" to "Try the CLI Before Deferring"; updated anti-pattern to cover scope-shaped deferrals |
| PR #858 (`feat(#852): add the browser as rung 4 of the capability ladder`) | 2026-08-01 | Issue #852 | Added "Common false walls — web-only (rung 4)" section with dashboard-action table; inserted rung 4 (browser) into the ladder; renumbered rung-4 references to rung-5 throughout; updated "Rungs 1–3 in practice" heading to acknowledge rung 4; delegated rung 4 detail to new `browser-capability-rung.md`; updated file header to reference that new file |

### Conflict analysis

Git history is strictly linear — no merge commits and no conflict markers across any of the three PRs. Specifically:
- PR #762 and PR #817 touched non-overlapping sections (PR #762 added provider-CLI and rungs-1–3 sections; PR #817 added the scope-deferral section after those).
- PR #858's rung renumbering (4→5) was a coordinated, consistent edit across the file — expected iteration when inserting a new rung, not structural instability.
- No `conflict_rounds` pain on this file.

## 2. Options considered

### Option 1: KEEP (no structural change) — **Chosen**

Record a by-design KEEP decision and leave `capability-discovery-examples.md` byte-for-byte unchanged.

**Chosen.** The file's scope is "worked-example catalog for the capability ladder." Each of the three PRs added one distinct worked-example concern (provider CLIs, scope-shaped deferrals, browser as rung 4), corresponding to a real issue (#759, #810, #852). The sections are sequentially authored and non-conflicting — the churn is the natural completion path for a catalog that grows as the ladder itself grows. A structural change would relocate churn without benefit.

### Option 2: Split by rung

Extract each rung's worked examples into a separate file (e.g., `capability-discovery-rung-1-3.md`, `capability-discovery-rung-4.md`).

**Rejected.** The file already delegates rung 4 detail to `browser-capability-rung.md` — the heaviest section is already extracted. The remaining sections are tightly coupled: the false-walls tables at the top motivate the rung descriptions below them; splitting by rung would force readers to open multiple files to understand the ladder as a whole. A per-rung split would not reduce future churn — each new ladder change would still touch the false-walls table and the rung description in tandem.

### Option 3: Extract provider-CLI table to a separate file

Move the provider-CLI false walls table into its own reference file.

**Rejected.** The provider-CLI table already delegates full command surface to `cli-tool-defaults.md` — the table in this file is the "false wall → actual command" quick-reference, not the authoritative CLI documentation. Extracting it removes the catalog's value without removing the churn driver: new providers added in future PRs would still need an entry in the quick-reference table and the `cli-tool-defaults.md` expansion simultaneously.

## 3. Preserved invariants

- **Extraction contract with `.claude/rules/safety.md` §Capability Discovery.** This file holds worked examples; `safety.md` holds the operative ladder and the verbatim `MINDSET:` block. That split must be maintained: do not copy the ladder rungs or MINDSET block here, and do not copy worked-example tables into `safety.md`.
- **Cross-links from `browser-capability-rung.md`.** That file references this one as the "false walls vs real walls" catalog. The file's title and purpose must remain stable enough for those cross-links to hold.
- **Rung numbering consistency.** The file now uses a 5-rung scheme (rungs 1–3: look/check/install; rung 4: browser; rung 5: runbook). Any future rung insertion requires consistent renumbering throughout both this file and `browser-capability-rung.md`.
- **For this PR:** `capability-discovery-examples.md` stays byte-for-byte unchanged.

## 4. Remediation and verification

The only changes in this PR are:
1. This decision record (`.claude/reference/capability-discovery-examples-hotspot-decision.md`).
2. One catalog bullet in `.claude/reference/README.md`.

No rule, script, reference doc, or agent file is modified. `reference-catalog-lint.sh` must pass with exactly one registered bullet for the new decision doc and no phantom entries.

## 5. Future edits and reconsideration

Ordinary additive edits — adding a new provider to the false-walls table, or a new section for a new capability class — do not require reopening this decision.

Reconsider if:
- A future PR re-edits an *existing* section in a way that conflicts with another concurrent PR, indicating that the section has become a shared live-policy surface rather than a sequentially-authored catalog.
- The file grows to compete with `safety.md` for canonical ladder ownership — e.g., if a section starts restating the operative rung rules rather than pointing to `safety.md`.
- A section begins restating `browser-capability-rung.md` in full instead of linking to it, creating a synchronization burden analogous to the Pattern 5 dedup in `scheduling-failure-modes-hotspot-decision.md`.
- File word count substantially exceeds the current ~1,595 words (e.g., doubles), at which point per-section extraction should be reconsidered.

## 6. Related precedent

- `.claude/reference/autofile-dedup-hotspot-decision.md` — KEEP decision for `autofile-dedup.md` churn (3 merged PRs, Issue #1076); same "additive, distinct-concern, non-conflicting" pattern; most recent decision immediately preceding this one.
- `.claude/reference/merge-gate-review-substance-test-hotspot-decision.md` — KEEP, no structural change; purposeful regression accumulation where each PR appended a new case group for a new correctness fix; sequential authorship with no shared-mechanism conflict.
- `.claude/reference/scheduling-failure-modes-hotspot-decision.md` — KEEP, no runtime change; append-only incident log; each PR added a new pattern class without competing on existing sections.
- `.claude/reference/token-efficiency-audit-hotspot-decision.md` — KEEP, no runtime change; designed append-per-FU-resolution lifecycle; non-conflicting sequential additions.
- `.claude/reference/safety-rule-hotspot-decision.md` — related precedent on the owning rule file; helps trace which concerns belong in `safety.md` vs this catalog.
