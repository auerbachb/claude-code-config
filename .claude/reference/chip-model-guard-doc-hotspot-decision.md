<!-- churn-hotspot: .claude/reference/chip-model-guard-decision.md -->
# Hotspot Decision — chip-model-guard-decision.md

**Verdict:** KEEP (no operative change)
**Decided:** 2026-08-06
**Issue:** #1011
**Reporter:** `/wrap` post-merge churn report (PR #1008)

## Churn summary

`churn-hotspots.sh` flagged `.claude/reference/chip-model-guard-decision.md` as touched by 6
distinct merged PRs since 2026-07-23: PRs #736, #775, #799, #842, #857, #1008.

| PR | Churn class | What changed |
|----|-------------|--------------|
| PR #736 | Amendment — guard enforcement | Recorded that the guard now covers all five canonical emitters (Issue #731) |
| PR #775 | Amendment — sixth emitter + resolver class | Recorded the `/harness-audit` Amendment (#770): resolver class, `model-fleet.sh`, literal vs resolved distinction |
| PR #799 | Amendment — versionless names + effort line | Recorded Amendment (#791): bare family name as the written form; effort line travels with the guard but is not itself guarded |
| PR #842 | Amendment — family-level comparison | Recorded Amendment (#837): comparison axis is the family, not the full version string; scope limit and retired-family gap documented |
| PR #857 | Amendment — stale-chip sweep outcome | Recorded #838 sweep result: 28 pre-#837 chips enumerated, all closed, none re-emittable; added issue-closed stale-chip trigger |
| PR #1008 | Cross-reference accretion | Added upstream requirement note for the cross-session `dismiss_task` gap (#859); pointer to `chip-launching.md` §Upstream requirement |

## Diagnosis

The churn is uniform single-cause with no recorded merge conflicts across all 6 PRs.

**Every touch is an amendment to the guard or a cross-reference to an amendment outcome.**
`chip-model-guard-decision.md` is a living decision record: it tracks the full history of choices
made about how the chip model guard behaves. The amendment pattern is structural — each change to
the guard mechanism (enforced via `chip-model-guard-lint.sh`) generates a corresponding
"Amendment (#N)" section in the decision record. The file's churn IS its design: an amendment log
for an actively evolving contract.

**The ownership boundary is already clear.** `chip-launching.md` is the sole owner of the
mechanism — the guard preamble verbatim text, the six-emitter list with literal vs resolved
classes, the model and effort line format. `chip-model-guard-decision.md` is the sole owner of the
rationale — why the guard rides in both prompt and fallback, what was rejected, and the amendment
history. The README already names both files in their respective sections without overlap.

**No split is warranted.** The file has one clear responsibility: record the decisions and
rationale for the chip model-guard contract. Its amendment sections map one-to-one to the Issues
that changed the guard. No amendment section has grown beyond documenting a single decision
context. The 6 touches are 5 by-design amendment records and 1 cross-reference addition — none of
these motivate a split or restructuring.

**A decision-record-about-a-decision-record adjudication is a lighter lift.** This file exists to
document `chip-launching.md`'s guard. Its continued growth mirrors `chip-launching.md`'s continued
evolution. When the guard is stable, this file will stabilize too. Re-filing is appropriate only
when `conflict_rounds > 0`.

## Decision

**KEEP** `.claude/reference/chip-model-guard-decision.md` as the single living decision record for
the chip model-guard contract. Make no operative change.

The ownership boundary between this file (rationale) and `chip-launching.md` (mechanism) is
already enforced — `chip-model-guard-lint.sh` checks `chip-launching.md`'s operative corpus, and
this decision record is a non-auto-loaded reference that does not affect the rule corpus budget.
The 6 reported touches are intentional amendment-record growth, not structural churn.

Per `.claude/reference/churn-hotspots.md`, re-file this hotspot only when
`conflict_rounds > 0` — rising PR count alone on a living decision record is not a re-filing
trigger.

## Expected impact

None. No rule corpus files were changed. The corpus word count remains unchanged at the
pre-adjudication baseline.

## Related

- Issue #1042 — `chip-model-guard-lint.sh` hotspot; separate queued issue (script, not doc)
- `chip-model-guard-decision.md` — the adjudicated file; its `## References` section names all six amendment Issues
- `chip-launching.md` — mechanism owner; `chip-model-guard-decision.md` rationale pointer in §Model-guard placement
- `.github/scripts/chip-model-guard-lint.sh` — lint that enforces `chip-launching.md`'s guard across all canonical emitters
- `.claude/reference/churn-hotspots.md` — hotspot mechanism, calibration, and re-open trigger logic
