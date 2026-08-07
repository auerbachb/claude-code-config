# Hooks README Hotspot Decision

Reference for Issue #998 (`.claude/hooks/README.md` churn hotspot). Not auto-loaded.

<!-- churn-hotspot: .claude/hooks/README.md -->

## Executive summary

### Verdict: **KEEP** the single file; **deduplicate** vestigial per-hook JSON setup blocks

Keep `.claude/hooks/README.md` intact as the documentation hub for installed hooks. Its churn
is additive: each of the six flagged PRs added or refined one section for one new hook. No merge
conflicts were recorded. No independently consumed subsection warrants extraction into a separate
file.

Remove the vestigial `### Setup` JSON blocks from the `post-merge-pull.sh` and
`silence-detector.sh + silence-detector-ack.sh` sections. Both hooks are registered automatically
via `register-hooks.py` reading `global-settings.json`; the JSON blocks duplicate the
`## Hook Auto-Registration` banner without adding operator-actionable content. All `### Prerequisites`
subsections and behavioral prose are preserved.

This follows the KEEP + targeted-dedup pattern established by
`monitor-mode-hotspot-decision.md` and `session-state-schema-hotspot-decision.md`.

## 1. Trigger and current evidence

Issue #998 was filed by `/wrap` churn detection after PR #997 merged, recording 6 distinct merged
PRs touching `.claude/hooks/README.md` since 2026-07-28: PRs #774, #807, #811, #829, #931, and
#944. A seventh PR (#1032) landed after filing.

Current state: 244 lines, ~2,257 words (far below the 2,000-word per-file warning; this file is
not in the auto-loaded rule corpus, so the word gate does not apply).

### Per-section churn attribution

| PR | Section touched | Change class |
|----|----------------|-------------|
| #774 (Issue #773) | `## silence-detector.sh + silence-detector-ack.sh` | Additive: extended the `silence-detector.sh` behavior description with dedupe details (issue #773 time-injection cooldown) |
| #807 (Issue #803) | _new_ `## bgwork-ceiling-arm.sh + bgwork-ceiling-guard.sh` | Additive: entire section added for the background-work ceiling hook pair |
| #811 (Issue #792) | `## Hook Auto-Registration` banner | Clarification: tightened wording to name `SessionStart` event and "on each session start and resume" to match moved hook event |
| #829 (Issue #824) | _new_ `## usage-limit-record.sh` | Additive: entire section added for the `StopFailure` recorder |
| #931 (Issue #779) | `## Hook Auto-Registration` banner | Additive: added `register-hooks.py` paragraph documenting `statusLine` key sync behavior |
| #944 (Issue #941) | _new_ `## checkpoint-handoff.sh` | Additive: entire section added for the automatic portable-handoff writer |
| #1032 (Issue #813) | _new_ `## post-compact-reconcile.sh` | Additive: entire section added for the `PostCompact` reconciliation hook (landed after issue was filed) |

Classification: 5 of 7 touches are new-section additions for new hooks; 1 is a behavioral-description
extension; 1 is a banner clarification. All are independent — no two PRs touched the same section
heading. No merge conflicts were recorded.

### Dedup evidence: vestigial `### Setup` JSON blocks

At filing, the `post-merge-pull.sh` and `silence-detector.sh + silence-detector-ack.sh` sections
each carried a `### Setup` block with JSON that operators were instructed to manually merge into
`~/.claude/settings.json`. These blocks pre-date the auto-registration mechanism.

Confirmation that they are now vestigial:
- Both hooks appear in `global-settings.json` under their correct event types (`PostToolUse` for
  `post-merge-pull.sh` and `silence-detector.sh`, `Stop` for `silence-detector-ack.sh`).
- `session-start-sync.sh` (registered under `SessionStart`) calls `register-hooks.py`, which reads
  `global-settings.json` and registers any missing hooks automatically on every session start and
  resume.
- The `## Hook Auto-Registration` banner — already present — documents this mechanism as the
  authoritative setup path with the three-step "To add a new hook" procedure.
- The `skill-usage-tracker.sh + skill-command-tracker.sh` section (added post-audit) already uses
  the correct pattern: a `### Prerequisites` section that says "Registered automatically via
  `global-settings.json` — see **Hook Auto-Registration** above" with no JSON block.
- `bgwork-ceiling-arm.sh + bgwork-ceiling-guard.sh` and `usage-limit-record.sh` sections (added
  even later) carry only `### Prerequisites` with no setup JSON — confirming the drift pattern:
  early hooks accumulated vestigial JSON before auto-registration landed; newer hooks do not.
- `.claude/reference/repo-audit-2026-05.md` lines 77 and 101 flag the duplicate JSON in the hooks
  README as the removable churn lever.

No prerequisite text or behavioral notes are embedded in the setup JSON blocks themselves. The
closing sentence ("Replace `/absolute/path/to/claude-code-config` with the actual path to your
clone of this repo.") is superseded by `setup-skills-worktree.sh` / `SETUP.md` initial setup.

## 2. Options considered

### Option 1: Split into operator-setup and maintainer-manifest files

Separate the manual-setup instructions from the per-hook behavioral documentation.

**Rejected.** The flagged touches are all independent additive sections — one section per new hook.
There is no evidence of merge pain or competing edit frequencies across a split boundary. A split
would add a second file, create a caller-migration surface, and leave the underlying churn source
(new hook → new section) unchanged.

### Option 2: Extract per-hook documentation into per-hook files

Move each hook's section into its own reference document.

**Rejected.** No section carries independently consumed design rationale that requires its own
addressable anchor. The file is the natural home for the hook catalog. The size is well below
per-file limits even with the additive churn pattern.

### Option 3: Keep the file and record the verdict only (no dedup)

Write the decision doc, make no change to the README.

**Not chosen as the primary.** The JSON dedup is confirmed-vestigial and low-risk. Leaving it
would preserve a known drift source that the repo-audit already flagged. A no-op verdict is
defensible but inferior when evidence supports a targeted fix.

### Option 4: KEEP + targeted dedup of vestigial JSON setup blocks (chosen)

Retain the file, replace the two confirmed-vestigial `### Setup` JSON blocks with pointers to the
`## Hook Auto-Registration` banner, and record the verdict.

**Chosen.** This removes the one audit-flagged duplication without touching any behavior, tests,
or rule corpus. It follows the established precedent for KEEP + targeted-dedup verdicts.

## 3. Canonical ownership boundaries

| Content | Canonical owner | Non-owner action |
|---------|----------------|-----------------|
| Hook registration steps and mechanism | `## Hook Auto-Registration` banner in `README.md` | Per-hook sections point to the banner; do not restate JSON |
| Per-hook behavior and prerequisites | Respective `## <hook-name>` section | Self-contained; no coordination required across sections |
| Hook manifest (which hooks register under which events) | `global-settings.json` | `README.md` documents behavior; it does not define the manifest |
| Runtime registration logic | `register-hooks.py` | `README.md` references it for the `statusLine` case; registration steps are not duplicated |
| Initial setup | `setup-skills-worktree.sh` / `SETUP.md` | `README.md` defers to `SETUP.md` for initial setup; the `## Hook Auto-Registration` banner covers the ongoing sync |

## 4. Remediation applied

- Replaced the `### Setup` JSON block in `## post-merge-pull.sh` with a one-line pointer to
  `## Hook Auto-Registration`. The `### Prerequisites` subsection is preserved.
- Replaced the `### Setup` JSON block in `## silence-detector.sh + silence-detector-ack.sh` with
  a one-line pointer to `## Hook Auto-Registration`. The `### Prerequisites` subsection is preserved.
- Created this decision document.
- Added one catalog bullet in `.claude/reference/README.md` under "Audits and research
  (point-in-time)".

No hook behavior, prerequisites prose, or auto-registration steps were changed.

## 5. Preserved invariants

- All seven hook sections remain in the file with their behavior descriptions intact.
- `## Hook Auto-Registration` banner remains the single canonical source for registration steps.
- `### Prerequisites` subsections are unchanged across all sections.
- `post-compact-reconcile.sh` and `checkpoint-handoff.sh` sections (which correctly carry no setup
  JSON) are untouched.
- `skill-usage-tracker.sh + skill-command-tracker.sh` section's "Registered automatically"
  wording is the established pattern that the dedup now aligns the older sections toward.
- No runtime hook behavior, `global-settings.json` entries, or test files are changed.

## 6. Verification

- `.claude/scripts/reference-catalog-lint.sh` — confirms exactly one catalog bullet for this file.
- `bash .github/scripts/rule-lint.sh` — rule corpus unchanged; passes.
- `bash .github/scripts/verbatim-block-lint.sh` — no verbatim blocks changed; passes.
- Hook tests under `.claude/hooks/tests/` — no tests reference `hooks/README.md`; all pass.

## 7. Future edits and reconsideration

Each new hook added to the repo adds one section here. That cadence is expected and appropriate —
it is the purpose of the file. The dedup applied here ensures new sections follow the banner-pointer
pattern rather than accumulating fresh JSON blocks.

Reconsider splitting only if:
- Two or more sections begin to change together on a cadence unrelated to the others (coordinated
  edit pressure); or
- The file crosses the enforced per-file word threshold and contains a natural split boundary with
  independent callers.

Raw touch count alone (the current trigger signal) is not a reason to split.

## Related precedent

- `.claude/reference/monitor-mode-hotspot-decision.md` — KEEP + targeted dedup for a small,
  heavily cross-referenced file with one confirmed avoidable duplication.
- `.claude/reference/session-state-schema-hotspot-decision.md` — KEEP + targeted dedup for a
  canonical schema with downstream mirror churn.
- `.claude/reference/churn-hotspots.md` — observational detector semantics and adjudication goal.
- `.claude/reference/repo-audit-2026-05.md` — original source flagging the hooks README JSON
  duplication as the removable churn lever.
