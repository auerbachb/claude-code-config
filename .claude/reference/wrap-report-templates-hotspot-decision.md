<!-- churn-hotspot: .claude/skills/wrap/references/wrap-report-templates.md -->
# Wrap-Report-Templates Hotspot Decision

Reference for Issue #1124 (`.claude/skills/wrap/references/wrap-report-templates.md` churn hotspot). Not auto-loaded.

**Verdict:** KEEP (no structural change)
**Decided:** 2026-08-08
**Issue:** #1124
**Reporter:** `/wrap` post-merge churn report (PR #1123)

## 1. Trigger and current evidence

Issue #1124 was filed by `/wrap` churn detection after PR #1123 merged. The issue body records 3 distinct merged PRs since 2026-07-28: PR #848, PR #862, and PR #982.

At diagnosis time the file is 52 lines. It is a single-section skill-local reference holding only the `--verbose` report template and its rendering rules for `/wrap` Step 4.3.

The file was created by PR #848 as an extraction from `wrap/SKILL.md`. The other two PRs are coordinated policy-propagation touches, not independent concerns accumulating in the file.

### Per-PR churn attribution

| PR | Merged | Driving issue | What changed in `wrap-report-templates.md` |
|----|--------|--------------|----------------------------------------------|
| PR #848 (`refactor(#800): slim wrap/SKILL.md — extract prose to skill-local references/`) | 2026-07-31 | Issue #800 | File created — 52 lines, verbose report template and rendering rules extracted from `wrap/SKILL.md` Step 4.3 |
| PR #862 (`feat(#851): cut agent chatter to heartbeat + decision points`) | 2026-08-01 | Issue #851 | Policy propagation: updated description to note silent-default (Issue #851); changed section heading from "Verbose report (`--verbose`)" to "Verbose report (`--verbose`, or on explicit request)" |
| PR #982 (`fix(#924): move recurring polls to Monitor`) | 2026-08-03 | Issue #924 | Terminology pass: changed "/loop jobs" to "Monitor tasks" in the Auto-handled bullet template, consistent with the Monitor-migration change across the codebase |

### Consumer verification

`grep -rn "wrap-report-templates" .claude/skills/` returns exactly two results, both in `.claude/skills/wrap/SKILL.md` (lines 63 and 743). No other skill file references this template.

### Conflict analysis

Git history for this file is strictly linear — three commits, no merge conflicts, no conflict markers. Each commit touched a different concern: creation, policy-propagation description update, and a single-word terminology substitution. The only section that changed across more than one PR is the file header; even there, PR #848 added it and PR #862 updated one sentence in it without conflict. No `conflict_rounds` pain on this file.

## 2. Options considered

### Option 1: KEEP (no structural change) — **Chosen**

Record a by-design KEEP decision and leave `wrap-report-templates.md` byte-for-byte unchanged.

**Chosen.** The file is 52 lines, single-purpose (verbose report template for `/wrap` Step 4.3), and has exactly one consumer (`wrap/SKILL.md`). It is itself already an extraction from `wrap/SKILL.md` (PR #848), so any further split would reverse the extraction without addressing the measured churn. The three flagged PRs are: one creation event, one policy-propagation pass for Issue #851 output-discipline, and one coordinated terminology update for Issue #924 Monitor migration. None introduced new sections or independently churning sub-concerns. The pattern matches the burst-construction-plus-coordinated-propagation class recorded in related KEEP decisions (see Section 6).

### Option 2: Extract shared output-rendering conventions — **Deferred, out of scope**

Pull the cap-then-summarize, omit-empty-section, and fixed-canonical-string rules that `wrap-report-templates.md`, `pm-output-templates.md`, and `wrap/SKILL.md` Step 3.5 each restate into one shared reference.

**Not applied; recorded as a future option.** No PR in the Issue #1124 window touched `pm-output-templates.md` or `wrap/SKILL.md` Step 3.5. The proposed overlap would require verifying which rendering rules are genuinely byte-near-identical across all three files and designing a shared-reference loading contract. That scope exceeds the observational ticket and would not reduce the churn that triggered Issue #1124 — policy propagation and terminology changes are not caused by rendering-convention duplication. If a future PR finds the shared-convention prose diverging after a policy change, that is the right time to revisit. See Section 5 for the revisit trigger.

### Option 3: SPLIT — **Rejected**

Divide the file into a template file and a rendering-rules file.

**Rejected.** The template and its rendering rules are tightly coupled — the rendering rules exist solely to specify how the template sections are emitted, and neither is useful without the other. The file has a single consumer that reads it as a unit. No PR in the window touched template sections and rendering rules independently. A split would add a transitive loading requirement without reducing any observed conflict or independent maintenance burden.

## 3. Preserved invariants

- **Extraction contract with `wrap/SKILL.md`.** This file holds the verbose template and rendering rules; `wrap/SKILL.md` keeps the silent-default rules, the `## Wrapped up` block, blocker path strings, and selector logic. The division must be maintained: do not copy template content back into `SKILL.md`, and do not copy operational logic here.
- **Single consumer.** The file currently has exactly one consumer. If `pm-output-templates.md` or another skill begins linking here directly, the single-consumer rationale no longer holds and the Option 2 extraction becomes the appropriate recourse.
- **For this PR:** `wrap-report-templates.md` stays byte-for-byte unchanged.

## 4. Remediation and verification

The only changes in this PR are:
1. This decision record (`.claude/reference/wrap-report-templates-hotspot-decision.md`).
2. One catalog bullet in `.claude/reference/README.md`.

No existing rule, script, agent file, or template is modified. `reference-catalog-lint.sh` must pass with exactly one registered bullet for the new decision doc and no phantom entries.

## 5. Future edits and reconsideration

Ordinary policy-propagation touches — e.g., adding a new section to the verbose template when `/wrap` gains a new phase — do not require reopening this decision.

Reconsider if:
- A PR edits `wrap-report-templates.md` for a concern that has no corresponding change in `wrap/SKILL.md`, indicating the template has become independently owned.
- A second consumer begins referencing this file, making the single-consumer premise false.
- The shared rendering rules (`cap-then-summarize`, `omit-empty-section`, fixed `Verdict` canonical strings) appear verbatim in a third file and then diverge after a policy change — that is the trigger for the Option 2 extraction.
- File line count grows substantially beyond 52 lines with independently changing sections.

## 6. Related precedent

- `.claude/reference/capability-discovery-examples-hotspot-decision.md` — KEEP for a 3-PR hotspot where churn is sequential additive growth; same "single-consumer leaf, no merge conflicts, creation plus propagation" pattern; most closely analogous to this case.
- `.claude/reference/autofile-dedup-hotspot-decision.md` — KEEP for `autofile-dedup.md` churn (3 merged PRs; Issue #1076); creation + extension pattern; no merge conflicts.
- `.claude/reference/start-issue-hotspot-decision.md` — KEEP when churn is required propagation into a canonical skill emitter; coordinated-propagation pattern applies directly to PR #862 and PR #982 here.
- `.claude/reference/churn-hotspots.md` — hotspot reports are observational and require an evidence-based structural verdict.
