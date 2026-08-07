<!-- churn-hotspot: .claude/skills/wave/SKILL.md -->
# Hotspot Decision — wave/SKILL.md

**Verdict:** KEEP as canonical wave-selection skill (no operative change)
**Decided:** 2026-08-07
**Issue:** #961
**Reporter:** `/wrap` post-merge churn report (PR #960)

*Reference for Issue #961 (`.claude/skills/wave/SKILL.md` churn hotspot). Not auto-loaded.*

## The problem being read

`wave/SKILL.md` was touched by 10 distinct merged PRs since 2026-07-19: #644, #702, #713, #736,
#738, #750, #760, #786, #799, #878.

The file is the single wave-selection skill: it ranks nothing, launches nothing, and writes no
code. It selects, caps, and offers. Its callers (users who run `/wave`) consume the Steps 0–10
contract; `subagent/SKILL.md` Step 6.0b references its Steps 3–4 as the launch-time overlap model;
`merge-sequencing.md` cites its Steps 3–5 as the model its merge-time sequencing extends.

## Section-level churn attribution

Churn mapped by diff trace across each of the 10 PRs:

| PR | Sections touched | What changed |
|----|-----------------|--------------|
| #644 | All (initial creation) | `/wave` skill added from scratch |
| #702 | Step 2 | Added item 2: cross-thread `/issue-maker` chip visibility via handoff log scan |
| #713 | NON-NEGOTIABLE header, Step 7 heading + 7.0, Execution boundary table | PM-context inline gate added; Step 7 split into 7.0 (inline) + 7.1 (chips); execution boundary rationalization updated |
| #736 | Step 7.1 | Added chip model contract non-negotiable paragraph |
| #738 | Step 2 item 3, IN_FLIGHT definition, Step 6 full-ceiling prose | Authorship scoping: collaborator PRs drop candidates but never count toward ceiling; IN_FLIGHT refined to count own PRs only |
| #750 | Step 9 output template | Model name updated Opus 4.8 → Opus 5 |
| #760 | Step 7.1 prompt bullet | Added merge-authority Constraints bullet reference |
| #786 | NON-NEGOTIABLE header, Step 6 full-ceiling behavior, Step 7.0 | Too-big fit bar: three visible outcomes enumerated; full-ceiling now distinguishes inline-queued vs deferred; slot availability no longer routes subagent-fit issues to separate threads |
| #799 | Step 7.1 chip model+effort contract, Step 9 output template | Added effort picker lines; versionless family names; effort appears in both summary and chip prompt |
| #878 | Step 2 item 4 | Added issue-claim lookup to candidate pool filter (batch pre-filter + `issue-claim.sh --check`) |

**Key finding: Steps 3–5 (the CR plan's proposed extraction target) were NOT modified by any of the 10 PRs.** The footprint extraction logic (Step 3), collision surface mapping table (Step 4), and independent-set selection (Step 5) have been stable since initial authoring.

## Churn classification

| Class | PRs | Count |
|-------|-----|-------|
| Chip-contract propagation shared with `chip-launching.md` | #713, #736, #750, #760, #786, #799 | 6 |
| Step 2 feature additions (unique to wave's candidate-pool logic) | #702, #738, #878 | 3 |
| Initial creation | #644 | 1 |

**Chip-contract propagation (6 PRs):** PRs #713, #736, #738, #760, #786, and #799 updated
`/wave`'s Step 7 and output template in lockstep with `chip-launching.md` evolution:
- `chip-launching.md` added PM-context inline gate → Step 7.0 added (#713)
- `chip-launching.md` added model guard contract → chip model paragraph added (#736)
- `chip-launching.md` added merge-authority bullet → Step 7.1 prompt bullet added (#760)
- `chip-launching.md` added effort picker → Step 7.1 effort lines + output template updated (#799)

Comparing the wave PR list against `chip-launching.md` hotspot window (#916, 14 PRs):

| PR | In chip-launching.md | In wave/SKILL.md | Class |
|----|---------------------|-----------------|-------|
| #702 | No | Yes | Skill-specific — issue-maker visibility |
| #713 | Yes | Yes | Chip contract — PM inline gate |
| #736 | Yes | Yes | Chip contract — model guard |
| #738 | Yes | Yes | Chip contract + skill — author-scoping |
| #750 | No | Yes | Propagation — model-fleet vocabulary |
| #760 | Yes | Yes | Chip contract — merge-authority |
| #786 | Yes | Yes | Chip contract + skill — too-big recalibration |
| #799 | Yes | Yes | Chip contract — effort lines |
| #878 | Yes | Yes | Chip contract + skill — claim-at-pick |

Six of nine post-creation PRs are shared with `chip-launching.md`. The pattern matches
`prompt/SKILL.md` (#949 → KEEP: "7 of 12 PRs are shared chip-contract propagation"),
`start-issue/SKILL.md` (#981 → KEEP), and `chip-launching.md` itself (#916 → KEEP).

**Step 2 feature additions (3 PRs):** #702 (cross-thread `/issue-maker` chip state), #738
(collaborator-PR authorship scope), and #878 (issue-claim batch lookup) each added a new filter
to the candidate pool. These are genuine independent additions, not repeated edits to the same
prose. They cannot be extracted because they define wave's core pool-building logic.

## Decision: KEEP

Keep `.claude/skills/wave/SKILL.md` as the single canonical `/wave` entry point. Make no operative
change.

**Splitting the skill is rejected.** `/wave`'s Steps 0–10 contract and the "never auto-launches"
guarantee are consumed by every caller. A physical split would require updates to every reference
to wave's step numbers — including `subagent/SKILL.md` Step 6.0b, `merge-sequencing.md`,
`chip-launching.md`, and the NON-NEGOTIABLE guarantee text. This follows the same reasoning as:

- `hook-scripts.yml` hotspot (#681) — extracted script logic, rejected split
- `pm/SKILL.md` hotspot (#783) — extracted long prose, rejected split
- `fixpr/SKILL.md` hotspot (#788) — extracted deterministic blocks, rejected split

**Extracting Steps 3–5 to `collision-surfaces.md` is rejected** because the CR plan's diagnosis
does not match the evidence:

1. Steps 3–5 were not touched by any of the 10 hotspot PRs. Extracting stable sections does not
   reduce the churn that actually occurred.
2. `subagent/SKILL.md` Step 6.0b already implements the pointer-not-duplication pattern: it says
   "Reuse `/wave`'s existing footprint model verbatim" and summarizes Steps 3–4 in three bullets.
   This is a documentation pointer, not a duplication that needs extraction.
3. `merge-sequencing.md` cites Steps 3–5 as context ("the launch-time model this extends") — a
   citation, not a copy.
4. Extraction would add an indirection layer (`collision-surfaces.md`) that wave and subagent both
   point to, replacing two live references with three, without reducing any actual edit frequency.

**Chip-contract propagation is not reducible by local restructuring.** The six chip-contract PRs
update `/wave` in lockstep with `chip-launching.md` and the other five canonical emitters (#615
origin; #736, #760, #799 propagation; #912, #916 decisions). That fanout is intentional until the
repository adopts and tests a composite emitter-loading contract with CI enforcement — the same
conclusion reached for `prompt/SKILL.md` (#949) and `start-issue/SKILL.md` (#981).

**The CI lint enforcement blocks safe extraction of Step 7 content.** `.github/scripts/chip-model-guard-lint.sh`
verifies that `**Model:**`, `**Effort:**`, the model-guard preamble, Fable pre-click warning, and
no-blank-line placement are present inline in `wave/SKILL.md`. Moving these to a reference file
without updating the lint and its fixtures would break CI. The extraction is therefore not a
documentation move; it is an enforcement-contract change.

## Concrete remedy

Record this decision only. No files other than this decision record and the README catalog entry
are changed.

## What was explicitly preserved

- Steps 0–10 sequential contract: unchanged
- "never auto-launches" guarantee and execution boundary table: unchanged
- Step 7 model-guard and effort lines required by `chip-model-guard-lint.sh`: unchanged
- `subagent/SKILL.md` Step 6.0b pointer to `/wave` Steps 3–4: unchanged
- `merge-sequencing.md` citation of `/wave` Steps 3–5: unchanged
- All 10 step numbers: unchanged

## Related

- `.claude/reference/prompt-hotspot-decision.md` — closest precedent; same chip-contract
  propagation pattern; KEEP verdict (Issue #949, 12 PRs)
- `.claude/reference/start-issue-hotspot-decision.md` — KEEP for another canonical chip emitter
  (Issue #981, 9 PRs); same propagation reasoning
- `.claude/reference/chip-launching-hotspot-decision.md` — KEEP for the source of chip-contract
  changes that propagated to wave (Issue #916, 14 PRs)
- `.claude/reference/fixpr-hotspot-decision.md` — the extraction bar: justified when three
  independently-churning deterministic blocks each had a distinct owner and no lint anchors
- `.github/scripts/chip-model-guard-lint.sh` — enforces model+effort+guard contracts in wave
- `.claude/skills/subagent/SKILL.md` Step 6.0b — pointer to `/wave` Steps 3–4 (not a duplicate)
- `.claude/reference/merge-sequencing.md` — cites `/wave` Steps 3–5 as launch-time precedent
- Issue [#961](https://github.com/auerbachb/claude-code-config/issues/961) — this adjudication
- Issue [#949](https://github.com/auerbachb/claude-code-config/issues/949) — prompt/SKILL.md KEEP
- Issue [#788](https://github.com/auerbachb/claude-code-config/issues/788) — fixpr extraction
  precedent (the bar extraction must clear)
