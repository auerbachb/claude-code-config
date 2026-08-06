# PMM Lifecycle Hotspot Decision

Reference for Issue #1017 (`.claude/skills/pr-monitor-and-manage/references/pmm-lifecycle.md` churn
hotspot). Not auto-loaded.

## Executive summary

### Verdict: **KEEP + dedup**

Keep `pmm-lifecycle.md` intact as the detailed reference document for the PMM pause/resume/stop
state machine. The file's churn was driven primarily by legitimate hub edits as the scheduling
substrate evolved. One avoidable driver existed: the pause-marker `--set` write block in
`pmm-lifecycle.md` Step 4 was byte-identical to the same block in `SKILL.md`, making future
state-machine changes require coordinated edits in two places.

Remedy: designate `SKILL.md` as the canonical source for the pause-marker write block by adding
named HTML anchor comments around it, and add a canonical-source note in `pmm-lifecycle.md` so
editors know where changes belong. The existing pointer relationship (`SKILL.md` → `pmm-lifecycle.md`
for "full procedure") was already correct; this change makes the reverse direction explicit.

This is a documentation-ownership remedy. No runtime behavior changes.

## 1. Trigger and diagnosis

The hotspot detector recorded 6 merged PRs touching `pmm-lifecycle.md` since 2026-07-30:
PRs #843, #862, #867, #887, #899, #982. At diagnosis time the file was 237 lines, far below the
2,000-word per-file warning.

| PR | Touch class | Driver |
|----|-------------|--------|
| #843 | Hub/policy propagation | Slim SKILL.md — extract prose to references/; pmm-lifecycle.md created here |
| #862 | Hub/policy propagation | Incremental state-machine hardening (scheduler durability / Monitor migration) |
| #867 | Hub/policy propagation | Monitor migration — retire CronCreate / adopt persistent Monitor for auto-wake (#827, #924) |
| #887 | Hub/policy propagation | Fail-closed resume (#871): exact task teardown, abort on failed TaskStop |
| #899 | Hub/policy propagation | Fix pmm-lifecycle cross-refs pointing at non-existent SKILL.md steps |
| #982 | Hub/policy propagation | Session reconciliation / Monitor-migration cleanup (#924) |

All six touches are legitimate hub edits: `pmm-lifecycle.md` documents the pause/resume/stop state
machine, which is precisely what issues #827, #871, #872, and #924 improved. Splitting the file
cannot remove that driver.

One avoidable driver exists: the pause-marker `--set` write block in `pmm-lifecycle.md` `### 4.
Write pause marker` is byte-identical to the same block in `SKILL.md` `## Pause`. A state-machine
change to those five `--set` fields requires two coordinated edits.

The Step 0a resume guard is near-verbatim between files but is not byte-identical. `SKILL.md` holds
a condensed runtime stub ("full contract in `references/pmm-lifecycle.md`") and `pmm-lifecycle.md`
holds the full documented form with numbered steps and rationale. That relationship is the intended
design (SKILL.md stub → lifecycle detail); it is not avoidable duplication.

## 2. Options considered

### Option 1: KEEP + dedup with canonical-source markers (Chosen)

Retain both files with their current structure. Mark the byte-identical pause-marker write block in
`SKILL.md` with named HTML anchor comments (`pmm-canonical: pause-marker-write:start/end`), matching
the `<!-- test-anchor: … -->` convention in `pr-monitor-and-manage-wake/SKILL.md`. Add a
canonical-source note in `pmm-lifecycle.md` above the mirrored block.

**Chosen.** Removes the confirmed drift risk without altering runtime behavior or losing the
explanatory prose that makes `pmm-lifecycle.md` useful as a reference. Consistent with the
anchor-comment pattern already used in the companion wake skill.

### Option 2: KEEP + pointer replacement

Strip the pause-marker write block from `pmm-lifecycle.md` entirely and replace it with a
prose-only pointer.

**Rejected.** The surrounding prose in `pmm-lifecycle.md` explains *when* to add or omit additional
`--set` lines (after `TaskStop` succeeds, etc.). Removing the block makes the section harder to
read without a meaningful improvement over the canonical-source note in Option 1.

### Option 3: Split the file into pause, resume, and stop sub-files

**Rejected.** The file is small and its sections are a single coupled state machine. `SKILL.md` and
`pmm-wake/SKILL.md` both cite its named sections by path. Splitting would add cross-file navigation
without isolating independently changing concerns.

### Option 4: Record without a code change

Accept all churn as unavoidable and produce the decision doc only.

**Rejected.** The byte-identical write block is concrete, removable duplication. Leaving it
preserves a known drift risk that a one-line canonical-source note removes.

## 3. Ownership boundaries

| Content | Canonical owner | Non-owner action |
|---------|-----------------|------------------|
| Pause-marker `--set` write block (five-field batch) | `SKILL.md` `## Pause` (`pmm-canonical: pause-marker-write`) | `pmm-lifecycle.md` mirrors it; update both together |
| Step 0a resume guard — condensed runtime stub | `SKILL.md` `## Step 0a` | Points to `pmm-lifecycle.md` for the full contract |
| Step 0a full transactional resume logic (numbered steps, rationale) | `pmm-lifecycle.md` `## Step 0a: Resume from pause` | `SKILL.md` stub points here; do not duplicate numbered steps there |
| Pause procedure prose (heartbeat, Monitor stop, fleet snapshot, config build, auto-wake, summary) | `pmm-lifecycle.md` `## Pause` | `SKILL.md` delegates via "Full pause procedure: `references/pmm-lifecycle.md`." |
| Stop & Clean Exit procedure and summary format | `pmm-lifecycle.md` `## Stop & Clean Exit` | `SKILL.md` delegates via "Full summary format: `references/pmm-lifecycle.md`." |
| Cross-session continuity rationale and `#827`/`#924` context | `pmm-lifecycle.md` | Background reference; not in auto-loaded corpus |

## 4. Remediation applied

- In `SKILL.md` `## Pause`: added `<!-- pmm-canonical: pause-marker-write:start -->` and
  `<!-- pmm-canonical: pause-marker-write:end -->` around the five-field `--set` batch. Executable
  content unchanged.
- In `pmm-lifecycle.md` `### 4. Write pause marker (atomic batch)`: added a canonical-source
  blockquote above the code block. Surrounding prose and batch content unchanged.
- In `pmm-lifecycle.md` `## Deferred follow-ups`: added a resolved-item note for the
  `SKILL.md`↔`pmm-lifecycle.md` pause-marker-write duplication.
- Registered this decision in `.claude/reference/README.md`.

## 5. Preserved invariants

- `pmm-lifecycle.md` remains the full reference document for the PMM pause/resume/stop state machine.
  All named sections cited by `SKILL.md` and `pmm-wake/SKILL.md` remain intact.
- `SKILL.md` remains the canonical runtime owner. The condensed Step 0a stub, the Pause section, and
  the Stop & Clean Exit section are unchanged in executable content.
- The `<!-- test-anchor: pmm-wake-step-4a-scan -->` and `pmm-wake-step-4a-compare` anchors in
  `pr-monitor-and-manage-wake/SKILL.md` are unaffected; they are a different file and different test.
- No auto-loaded rule corpus changes; `.claude/rules/.budget-soft-cap` is untouched.
- No runtime behavior changes; no agent-judgment policy moves to a script.

## 6. Verification and future edits

Verification: `reference-catalog-lint.sh` exits clean with exactly one new catalog entry.
`SKILL.md` diff shows only two HTML comment lines added around the write block. `pmm-lifecycle.md`
diff shows only the canonical-source blockquote and deferred-follow-up update.

Future edits: when the pause-marker write block changes, update `SKILL.md` `## Pause` first (the
canonical source, marked `pmm-canonical: pause-marker-write`), then mirror the change to
`pmm-lifecycle.md` `### 4`. When the transactional resume steps change, update `pmm-lifecycle.md`
`## Step 0a: Resume from pause` (the detailed doc), then adjust the condensed stub in `SKILL.md`
`## Step 0a` if the runtime interface changes.

Reconsider splitting only if the file crosses the per-file size warning or if pause, resume, and
stop logic acquire independent callers with no shared state references.

## Related precedent

- `.claude/reference/monitor-mode-hotspot-decision.md` — KEEP + dedup for a heavily referenced rule
  hub; same pattern of clarifying canonical ownership with pointers rather than splitting.
- `.claude/reference/scheduling-reliability-hotspot-decision.md` — KEEP + dedup; confirms scheduling-
  substrate churn drives legitimate hub edits that splitting cannot prevent.
- `.claude/reference/fixpr-hotspot-decision.md` — KEEP + extract; contrasting case where extraction
  into a script was appropriate for deterministic command forms.
- `.claude/reference/churn-hotspots.md` — detector scope and observational-ticket rationale.
