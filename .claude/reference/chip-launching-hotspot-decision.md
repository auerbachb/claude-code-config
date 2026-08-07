<!-- churn-hotspot: .claude/reference/chip-launching.md -->
# Hotspot Decision — chip-launching.md

**Verdict:** KEEP as canonical chip-semantics contract (no operative change)
**Decided:** 2026-08-06
**Issue:** #916
**Reporter:** `/wrap` post-merge churn report (PR #910); updated to 14 PRs after PR #1008

## Executive summary

### Verdict: **KEEP** the single canonical contract; make **no operative change**

Keep `.claude/reference/chip-launching.md` as the single source of chip-mechanics truth. Do not
split by concern, extract the PM-context inline gate, move the merge-authority line, or relocate
the cross-skill chip visibility section in this remediation.

The 14 reported touches span from the initial MODEL GUARD addition (#615, July 21) through the
cross-session dismiss gap documentation (#1008, August 5). Nearly every touch added a **new
section** to a file that was actively being built out, not a conflicting edit to an existing one.
The sections that churned most — the PM-context inline gate (3 PRs) and the model-guard preamble
(3 PRs) — are now stable and belong here by design: the file is the explicit single source that
six emitters, two CI lint scripts, and several rule files all reference by section name.

This decision is intentionally reference-only. `chip-launching.md`, the six canonical emitter
SKILL.md files, the two lint scripts, and the auto-loaded rule corpus remain byte-for-byte
unchanged.

## 1. Trigger and measured evidence

Issue #916 recorded 13 merged PRs touching `chip-launching.md` since 2026-07-18, with PR #1008
(August 5) noted as a 14th touch after the original report: PRs #615, #645, #702, #713, #736,
#738, #760, #775, #786, #799, #842, #857, #878, #1008.

Measured at `main` `acffe9043f3220fae27cbd3ef9f78998acad90fe`, the file is 267 lines, 5,080 words,
and 15 sections. The changes divide by section, then by how many distinct PRs hit each section:

| Section | PRs | Churn pattern |
|---------|-----|---------------|
| Model-guard preamble | #615, #736, #842 | Core contract — added (#615), extended to 6 emitters (#736), family-level comparison (#842) |
| PM-context inline gate | #713, #738, #786 | Routing gate — introduced (#713), author-scoping (#738), too-big recalibration (#786) |
| Literal vs resolved model names | #775 | Core contract — /harness-audit resolver class added |
| Cross-skill chip visibility | #645, #702 | issue-maker specific — initial section (#645), discovery snippet (#702) |
| Model and effort lines | #799 | Core contract — effort line added |
| Merge-authority line | #760 | Core contract — added once, lint-enforced |
| Claim the issue on click | #878 | Core contract — Form B for inherited claim added |
| Stale-chip hygiene | #857 | Hygiene — issue-closed trigger #4 added |
| Upstream requirement — `spawn_task` model parameter | #736 | Tracking note added |
| Upstream requirement — cross-session `dismiss_task` | #1008 | New gap section added post-#859 |

Nine of the 15 sections were **never touched** in the measured window: Availability detection,
`spawn_task` invocation shape, Short-summary transcript format, Chip state tracking, Print-on-demand
replay, Fallback mode, and the execution-boundary box. A file where 9 of 15 sections are stable
across 14 PRs is not a file that has grown incoherent.

## 2. Why the CR plan's extraction is not applied

CodeRabbit's plan recommended extracting three concerns:
1. PM-context inline gate → a new `chip-routing-gate.md`
2. Merge-authority line → a new `merge-authority-line.md`
3. Cross-skill chip visibility → `.claude/skills/issue-maker/references/chip-visibility.md`

The extraction proposal does not account for three structural constraints that make it unsafe:

### Constraint A — section-name references from consumer skills (hard block)

The memory note from this project's feedback records is explicit: "chip emitters copy only NAMED
sections — a section rename breaks them." The `/wave` SKILL.md references the following section
names from `chip-launching.md` verbatim in its Step 7.0, 7.1, and fallback prose:

- "PM-context inline gate" (Step 7.0: `chip-launching.md` "PM-context inline gate")
- "Precedence when the ceiling is full" (Step 5, ceiling-full routing)
- "Cross-skill chip visibility" (Step 2: referenced twice for discovery and error handling)
- "Merge-authority line" (Step 7.1: "the merge-authority bullet — the shared contract from
  `chip-launching.md` "Merge-authority line"")
- "Upstream requirement" (Step 7.1: model warning)
- "Fallback mode" (Step 8)
- "Model and effort lines" (Step 7.1)

Moving any section to a different file without updating every consumer reference first would make
the inline instructions in the emitter skills point to a non-existent section. A reference
accompanied by a `§ see also` pointer is not the same as a live section name: the skills embed
actionable directives to "follow `chip-launching.md` **verbatim**" and "apply the gate from
`.claude/reference/chip-launching.md` 'PM-context inline gate'" — these must resolve in place.

### Constraint B — lint script anchors (hard block)

Two CI lint scripts anchor directly to `chip-launching.md` and to named sections within it:

- `.github/scripts/chip-model-guard-lint.sh` — `CHIP_LAUNCHING=".claude/reference/chip-launching.md"`;
  checks that chip-launching.md defines the MODEL GUARD preamble, the emitter list, and the
  first-line placement contract. Moving any of these to a different file requires updating the lint
  and its fixtures.
- `.github/scripts/merge-authority-lint.sh` — `CHIP_LAUNCHING=".claude/reference/chip-launching.md"`;
  the `CANONICAL_BULLET` constant is the lint's single source of truth for the merge-authority
  sentence, and the lint verifies that chip-launching.md defines this shared contract. Moving the
  Merge-authority line section would require the lint to source the canonical sentence from the new
  file.

Both lints are designed to enforce that these contracts exist in chip-launching.md specifically. An
extraction that moves the canonical definition would require updating both lints and their test
fixtures — a scope that exceeds the observational hotspot and should be driven by a dedicated
change rather than a churn adjudication.

### Constraint C — churn is not independent (no demonstrated extract target)

A justified extraction requires sections that are iterated by different owners on independent
timelines (the `fixpr-hotspot-decision.md` precedent: reviewer-activity detection, wait-state
predicate, and classification rules each had their own clear independent owner). The sections
flagged for extraction here do not meet this bar:

- **PM-context inline gate**: 3 PRs across 7 days in late July as one feature (routing audit) was
  built and tuned. No PRs since July 29. This is burst construction, not independent churn.
- **Merge-authority line**: 1 PR. Added once and enforced by lint.
- **Cross-skill chip visibility**: 2 PRs on consecutive days in July. Initial authoring of a new
  feature, not ongoing maintenance from a different owner.

None of these sections show the pattern that justifies extraction: repeated independent edits from
different code paths requiring ongoing maintenance.

## 3. Pattern classification

The 14 PRs fall into four churn classes, all of which are expected for this file:

| Class | PRs | Description |
|-------|-----|-------------|
| New-section authoring | #615, #645, #702, #713, #736, #760, #775, #786, #842, #857, #878, #1008 | A capability added to the chip protocol landed once as a new section; that section has not changed since |
| Multi-PR section construction | #713, #738, #786 (PM gate); #615, #736, #842 (guard preamble) | A more complex feature was developed in 2–3 consecutive PRs, then stabilized |
| Upstream gap documentation | #1008 | A new tool limitation was documented; not a code change |
| Enforcement propagation | #736, #760 | Existing contract was extended to new emitters or made lint-enforced |

Class 1 (new-section authoring) is not a maintenance problem — it is the file behaving correctly
as the canonical write-once destination for chip-protocol additions. The file grew from the
execution-boundary section and `spawn_task` shape in PR #555 to 15 sections over 14 PRs. Now that
the chip protocol is mature, new additions will slow.

## 4. Options considered

### Option 1: Extract PM-context inline gate, Merge-authority line, Cross-skill chip visibility

**Rejected.** Section-name references from consumer skills and lint anchors make this unsafe
without a coordinated, larger-scope change. The burst-construction churn pattern does not
demonstrate the ongoing independent iteration that would justify the extraction overhead. See
Section 2 above.

### Option 2: Keep the file and record the ownership decision

**Chosen.** This records how to classify future touches, preserves the consumer-facing section
names, and avoids changing operative file content that CI enforces.

## 5. Canonical ownership

| Section | Why it belongs in chip-launching.md |
|---------|--------------------------------------|
| Execution boundary box | Cross-skill invariant; every emitter inherits it |
| PM-context inline gate | Routing gate applied by non-PM surfaces before offering a chip; /wave, /issue-maker, /start-issue all cite it by name |
| Availability detection | Defines chip mode vs fallback mode; governs all emitter behavior |
| `spawn_task` invocation shape | Shared contract for the tool call itself |
| Model and effort lines | Lint-enforced baseline unit; emitters copy the shape verbatim |
| Model-guard preamble | Verbatim block copied into every prompt; lint-enforced |
| Claim the issue on click | Cross-emitter claim protocol; two forms (A/B) inherited by reference |
| Literal vs resolved model names | Emitter class table; `chip-model-guard-lint.sh` enforces the two-class model here |
| Upstream requirements | Tool gaps that every emitter must work around; tracking issues live here |
| Merge-authority line | Verbatim bullet copied into every prompt; `merge-authority-lint.sh` enforces it |
| Short-summary transcript format | Shared display contract |
| Chip state tracking | Cross-emitter write rule; `/pm`'s Active Work table is named here |
| Cross-skill chip visibility | issue-maker's cross-thread record; /wave and /pm both consult the rule defined here |
| Stale-chip hygiene | Dismiss protocol applying to all surfaces; `dismiss_task` triggers defined here |
| Print-on-demand replay | Shared invariant: chip prompt is source of truth for replay |
| Fallback mode | Defines how all emitters degrade when spawn_task is unavailable |

Every section is referenced from at least one consumer (rule file, emitter skill, or lint script).
None is owned solely by a subconcern with its own independent maintenance lifecycle.

## 6. Preserved invariants

This decision changes no operative content. The following are all unchanged:

- `chip-launching.md` section headings, verbatim preamble blocks, and every sentence consumers
  reference by name
- Six canonical emitter SKILL.md files: `/pm`, `/prompt`, `/start-issue`, `/issue-maker`, `/wave`,
  `/harness-audit` — none modified
- `chip-model-guard-lint.sh` and its fixtures — none modified
- `merge-authority-lint.sh` and its fixtures — none modified
- `.claude/rules/chip-spawn.md` — unchanged

## 7. Future edits and reconsideration

Future chip-protocol additions should continue to land in `chip-launching.md`. A section belongs
here when it defines a contract that emitters implement verbatim or reference by name.

Reconsider extraction only if:
1. A specific section demonstrably iterates independently from the rest (multiple PRs with a
   distinct owner, not burst-construction), **and**
2. The extraction can be made safe without changing consumer skill references or lint anchors in
   the same commit.

If condition 2 is met, extraction becomes a viable scope for a dedicated refactor (not a churn
adjudication), and the section name must either be preserved as a pointer stub or every consumer
updated atomically.

## Related precedent and references

- `.claude/reference/phase-b-reviewer-hotspot-decision.md` — KEEP when 14 PRs are required
  propagation into a self-contained contract
- `.claude/reference/start-issue-hotspot-decision.md` — KEEP when 9 PRs are coordinated
  contract delivery (not independent iteration)
- `.claude/reference/fixpr-hotspot-decision.md` — the extraction precedent: justified when three
  independently-changing deterministic blocks each had a distinct owner
- `.claude/reference/chip-model-guard-doc-hotspot-decision.md` — KEEP for the companion decision
  record (`chip-model-guard-decision.md`); this file (mechanism) and that file (rationale) are
  the two halves of one chip-guard contract
- `.github/scripts/chip-model-guard-lint.sh` — enforces model-guard contracts in chip-launching.md
- `.github/scripts/merge-authority-lint.sh` — enforces merge-authority contract in chip-launching.md
- Issue [#916](https://github.com/auerbachb/claude-code-config/issues/916) — this adjudication
- Issue [#601](https://github.com/auerbachb/claude-code-config/issues/601) — model guard origin
- Issue [#788](https://github.com/auerbachb/claude-code-config/issues/788) — fixpr extraction precedent
