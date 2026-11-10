# Issue claim reference hotspot decision

Issue #1956. Detector evidence is from the untruncated default-branch run after PR #2060, with a window starting 2026-10-25.

## Decision

KEEP `issue-claim.md` as one on-demand reference. Its four counted changes describe one ownership lifecycle, with score 4 and zero recorded conflict rounds. Correct its wording and `/wave`’s label-index description, and make the claim helper refuse a recognized newest marker it cannot interpret.

| Merged PR | Contribution |
|---|---|
| [PR #1928](https://github.com/auerbachb/claude-code-config/pull/1928) | Added same-holder renewal and the original pickup timestamp. |
| [PR #1944](https://github.com/auerbachb/claude-code-config/pull/1944) | Wired renewal into launch, review and wrap callers. |
| [PR #1954](https://github.com/auerbachb/claude-code-config/pull/1954) | Hardened the renewal and release interleavings. |
| [PR #2035](https://github.com/auerbachb/claude-code-config/pull/2035) | Preserved pickup evidence before release and pinned delayed cleanup to the observed marker. |

## Why keep it together

Renewal and release both depend on the marker format, holder and account boundaries, timestamps, and exit codes. The caller tables explain where that same contract is used. Splitting the 186-line reference would create another place to reconcile those definitions without a separate reader or recorded conflict cost to justify it.

The claim-label index is a performance hint. It can miss a marker-only claim when suggesting work; the launch-time claim gate still reads the real marker. Changing how `/wave` searches is a separate performance decision. The current shared post-merge boundary already warns on failed guarded cleanup, so the earlier suggestion to add a separate `/wrap` release warning is stale.

## Verified safety correction

With private GitHub fixtures, both actual shells returned `unclaimed` for a recognized newest marker containing malformed JSON, including when it followed an older valid claim. That could admit another worker or treat a malformed marker as absent during cleanup. The initial helper read now returns `unknown` (exit 4) before writes if the recognized winner has no usable string holder. Marker selection still uses the existing timestamp and ID order. Valid markers, genuine absence, and label-only lookup keep their existing paths.

## Reconsideration

Revisit a split if a separate caller repeatedly needs only one section, or if this lifecycle starts incurring measured conflict or maintenance cost. Keep one definition of the marker and ownership rules if that happens. The exact Issue #1956 baseline is score/count 4; the existing 2× material-growth gate remains unchanged.
