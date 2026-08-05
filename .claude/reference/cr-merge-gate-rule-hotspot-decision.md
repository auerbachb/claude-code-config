# cr-merge-gate Rule Hotspot Decision

Reference for Issue #940 (`.claude/rules/cr-merge-gate.md` churn hotspot). Not auto-loaded.

Companion to `merge-gate-hotspot-decision.md` (Issue #936, PR #1010), which covers the same
gate enforced as a script (`merge-gate.sh`). This file covers the rule document itself.

## Executive summary

### Verdict: **KEEP** the single rule file; **targeted deduplication only**

Keep `.claude/rules/cr-merge-gate.md` as the single canonical policy definition of the pre-merge
gate. Do not split it into per-reviewer-path rule files. The churn is largely by design: the file
is the authoritative policy document that every flow-changing PR must touch by convention.

Two concrete duplication drivers are removed to reduce avoidable synchronized edits:
(1) the brief BugBot "two accepted shapes" restatement in `bugbot.md` §Merge Gate (already covered
in full by `.claude/reference/merge-gate-reviewer-paths.md` §BugBot path), and (2) the expanded
Greptile merge-ready conditions in `cr-merge-gate.md` Step 1 §Greptile path (covered by the same
reference). A clarifying clause is added to `merge-gate-reviewer-paths.md` to make the
policy-vs-runtime authority split explicit and non-circular.

## 1. Trigger and measured evidence

Issue #940 was filed after 12 merged PRs touched the rule file since 2026-07-18. By close, 15 PRs
had accumulated: PRs #650, #658, #660, #686, #719, #737, #742, #761, #787, #804, #849, #883,
#919, #968, #1001.

At diagnosis time (`main` `7e386a7`), the file is 1,175 words — below the 2,000-word per-file
warning. The touch history falls into four groups:

| Churn class | PRs | What changed |
|-------------|-----|--------------|
| Reviewer-path policy changes | PRs #686, #849, #883, #1001 | Check-run dedup, BugBot silent-pass shape, hollow-approval guard, zero-P0 Greptile reuse |
| Merge mechanics (BEHIND / admin-merge / Step 1d) | PRs #658, #719, #737, #761, #968 | BEHIND admin-merge, churn threshold, auto-wrap trigger, no-protection auto-plain, BEHIND auto-plain |
| Corpus compression | PRs #660, #742, #804, #919 | Broad corpus compression passes (not targeted at this file) |
| Other / incidental | PRs #650, #787 | Local-CLI failure handling, rm of untracked files |

## 2. Decision: keep, targeted deduplication

**Splitting is rejected.** The file declares itself the single authoritative definition of the
merge gate; all other rule files reference it rather than duplicating it. Every caller
(`merge.sh`, `wrap/SKILL.md`, `phase-c-merger.md`, `go-on`) depends on that single-contract
structure. Splitting into per-path rule files would scatter the gate into multiple authoritative
sources and force callers to reconcile partial reads — exactly the failure mode the canonical
structure prevents.

This follows the same extract-not-split precedent as:
- `fixpr/SKILL.md` hotspot (Issue #788, PR #789)
- `merge-gate.sh` hotspot (Issue #936, PR #1010) — the companion script

**Another compression pass is not needed.** The file was already 308 words below the ratchet cap
at diagnosis time (`11,749 − 11,441 = 308`); the targeted deduplication in §3 reduces the
corpus to 11,377 (−64 words), preserving 372 words of headroom. Broad per-file compression was
already applied by PRs #660, #742, #804, and #919.

**Churn by design (dominant driver).** Four of the fifteen PRs changed actual reviewer-path
policy, and five changed merge-mechanics prose. These must touch the canonical policy file by
convention — the same pattern that `churn-hotspots.md` §churn-by-design documents for canonical
junction files. No structural remedy reduces this driver.

**Corpus compression passes (four PRs) are cross-file and inherently touch the largest files.**
These are not a structural problem; they reflect that the file is the largest rule file in the
corpus. Future compressions will continue to touch it when it drifts above budget thresholds.

## 3. Concrete remedy

Two targeted deduplication changes and one authority clarification. Zero behavior change from this PR's structural remedy — the zero-P0 Greptile round reuse described in §3.2 is pre-existing policy established by PR #1001 (see §5); this PR removes its duplicate inline statement and points to the reference that already holds the full conditions.

### 3.1 BugBot §Merge Gate in `bugbot.md`

`bugbot.md` §Merge Gate summarized the "two accepted shapes" that are documented in full in
`.claude/reference/merge-gate-reviewer-paths.md` §BugBot path. Any BugBot shape change (like
PR #849) required synchronized edits in both files. Compressed to a single assertion line
plus a pointer to the reference, following the pointer-only pattern already established for
the Greptile path in `greptile.md` §Sticky Assignment.

No detail removed from `.claude/reference/merge-gate-reviewer-paths.md` — it remains the full
source.

### 3.2 Greptile path in `cr-merge-gate.md` Step 1

The Greptile path paragraph in `cr-merge-gate.md` expanded the three merge-ready conditions and
the 3-review cap in detail that is also present in `.claude/reference/merge-gate-reviewer-paths.md`
§Greptile path. Any Greptile gate change (like PR #1001) required synchronized edits in both
files. Compressed to a one-line summary of the outward merge-ready criteria plus a pointer to
the reference for full conditions.

The "Never switch back to CR/BugBot; ignore their late reviews" behavioral directive is retained
in the rule because it governs agent behavior in the polling turn without a reference lookup.

### 3.3 Authority clarity in `merge-gate-reviewer-paths.md`

`cr-merge-gate.md` declares itself "the single authoritative definition of the merge gate";
`merge-gate-reviewer-paths.md` said "`merge-gate.sh` is authoritative — re-read its JSON when
in doubt." These nominated different authoritative sources without clarifying the split. Added a
qualifying clause to the reference file header: `merge-gate.sh` is authoritative for **runtime
behavior and enforced JSON output** (what the script does when run); the rule file is
authoritative for **gate policy and intent** (what should happen and why). The reference holds
expanded per-path prose. No gate semantics changed.

## 4. Re-open trigger

Per `.claude/reference/churn-hotspots.md`, `/wrap` must re-file this hotspot only when
`conflict_rounds > 0` — i.e. when churn starts costing measurable conflict rounds. Rising PR count
alone (the inherent canonical-file convention) is not a re-filing trigger; the closed decision on
record covers that case explicitly.

## 5. Related

- Issue #936 / PR #1010 — `merge-gate.sh` hotspot, companion script decision
- Issue #788 / PR #789 — `fixpr/SKILL.md` hotspot, structural precedent
- Issue #844 — BugBot silent-pass shape (the rule PR #849 added, whose duplication this removes)
- Issue #1000 / PR #1001 — zero-P0 Greptile reuse (the rule PR #1001 added, whose duplication this removes)
- `.claude/reference/merge-gate-reviewer-paths.md` — the single detailed source for all reviewer-path semantics
- `.claude/reference/churn-hotspots.md` — hotspot mechanism, calibration, and re-open trigger logic
