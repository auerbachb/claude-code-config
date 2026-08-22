<!-- churn-hotspot: .claude/reference/codeant-graphite-supplemental.md -->
# Hotspot Decision — codeant-graphite-supplemental.md

**Verdict:** KEEP + minor factual correction (Graphite status update)
**Decided:** 2026-08-07
**Issue:** #1083
**Reporter:** `/wrap` post-merge churn report (PR #1082)

Reference for Issue #1083 (`.claude/reference/codeant-graphite-supplemental.md` churn hotspot). Not auto-loaded — the rule corpus carries none of this.

## Churn summary

`churn-hotspots.sh` flagged `.claude/reference/codeant-graphite-supplemental.md` as touched by 3 distinct merged PRs since 2026-07-24: PRs #821, #858, and #946.

| PR | Title | Churn class | Sections affected |
|----|-------|-------------|-------------------|
| PR #821 | fix(#819): restore dual-CLI coverage — CodeAnt CLI install path + absent-binary handling | Information accumulation | Created `### Install state on this machine` subsection |
| PR #858 | feat(#852): add the browser as rung 4 of the capability ladder | Coordinated contract update | Updated Auth description and runbook label (rung renumbering) |
| PR #946 | refactor(#782): compact-result-contract / FU-7 | Correctness fix | Updated proof-review command to use wrapper script |

## Per-section churn attribution (evidence)

Attribution verified via `git log --follow -p -- .claude/reference/codeant-graphite-supplemental.md` and `gh pr diff` for all three PRs.

### PR #821 — Install-state subsection creation (Issue #819)

PR #821 installed the CodeAnt CLI binary (`npm install -g codeant-cli`) and documented the
resulting machine state. The target file gained an entire new subsection: `### Install state
on this machine (updated 2026-07-30, issue #819)`.

The subsection introduced:
- Binary: installed at v0.5.1, `/opt/homebrew/bin/codeant`
- Auth: `codeant login` is browser OAuth only — no non-interactive path at the time, framed as "blocked at rung 3" under the then-current 4-rung ladder
- Current baseline: `cr-only`
- Restore runbook: two options (browser OAuth, API key) plus a raw proof-review stderr check

PR #821 also added the same install-state facts as a "Standing state update" addendum in
`.claude/memory/feedback_review_clis_down_app_independent.md` (adjudicated separately in
Issue #1074). The `feedback-review-clis-down-app-independent-hotspot-decision.md` decision
record confirmed this file (`codeant-graphite-supplemental.md`) §Install state as the
**canonical** owner; the memory addendum was later trimmed to a pointer by Issue #1074's PR.

Conflict rounds: 0.

### PR #858 — Rung-number update (Issue #852)

PR #858 inserted the browser as a new rung 4 in the capability ladder, pushing CLI-initiated
OAuth to rung 5. This required a coordinated update across every doc that referenced the old
rung numbering.

The target file's Install state subsection was updated:
- Auth description changed from "blocked at capability-ladder rung 3" to "a rung-5 wall";
  added "no non-interactive path exists, and no MCP browser surface can drive it, so rung 4
  does not apply"
- Runbook heading changed from "Rung-4 restore runbook" to "Rung-5 restore runbook"

This is purely a coordinated contract propagation. The underlying facts did not change; only
the rung numbers shifted to match the new ladder. Companion updates in the same PR:
`capability-discovery-examples.md`, `local-review-cli-failure-modes.md`,
`browser-capability-rung.md` (new), and all three agent definition files.

Conflict rounds: 0.

### PR #946 — Proof-review command update (Issue #782)

PR #946 (compact-result-contract, FU-7) updated the proof-review command in the restore
runbook. The original command was a raw stderr capture and grep:

```bash
codeant review --all --headless >ca.json 2>ca.err
grep -qE 'API Error|\[error\]|40[13]' ca.err && echo "FAILED RUN" || echo "clean"
```

This was replaced with a call to the `local-review.sh` wrapper:

```bash
.claude/scripts/local-review.sh --tool codeant
# exit 0 clean · 1 findings · 3 failed run · 4 timeout · 5 not installed
```

The wrapper applies every false-clean check (stderr error, 403, noFiles, 15-file cap, idle
hang) and returns a single well-typed exit code. Using the raw approach meant the runbook
could silently miss the noFiles, 15-file-cap, and hang failure modes that the wrapper catches.
This is a correctness fix for the runbook command, not a structural change.

Conflict rounds: 0.

## Diagnosis

The churn is single-lineage with no recorded merge conflicts across all 3 PRs.

**PR #821 is information accumulation.** The file existed before this PR as a concise
reference for CodeAnt and Graphite supplemental polling. PR #821 extended it with a new
Install state subsection that has a clear owner boundary (Issue #1074 confirmed it as
canonical). The content was not restated from any existing file; it was net-new ground truth
for a newly installed CLI.

**PR #858 is coordinated contract propagation.** Adding browser as rung 4 required renumbering
rung references across ~15 files in a single commit. The target file's Install state subsection
held two references to rung numbers ("rung 3", "Rung-4 runbook") that needed updating. This is
the expected maintenance cost of a cross-cutting contract change; it does not indicate instability
in this file's content.

**PR #946 is a correctness fix.** Replacing a fragile ad-hoc stderr check with the repo-standard
wrapper improves the runbook's reliability. The fix touched only the proof-review command block
inside the Install state subsection — no structural change.

**No merge conflicts: 0 across all 3 PRs.** Each PR owned a distinct concern within the same subsection.

## Dedup search

The Install state section is the canonical owner of these facts, as confirmed by:

1. `feedback-review-clis-down-app-independent-hotspot-decision.md` (Issue #1074) — explicitly
   named this file's §Install state as the canonical source, directing future state-update edits
   here. The memory-file addendum was trimmed to a pointer toward this canonical section.

2. `local-review-cli-failure-modes.md` §CodeAnt CLI not installed — cross-references the restore
   runbook here ("Full runbook with Option B (API key) and the proof-run stderr check:
   `.claude/reference/codeant-graphite-supplemental.md` §Install state"). It does not restate
   the runbook content; it delegates.

3. The auth wall classification and restore runbook commands are unique to this file.
   `local-review-cli-failure-modes.md` does carry the binary path (`/opt/homebrew/bin/codeant`)
   and version (`v0.5.1`) as install-state context in its §Standing state section, but those
   entries anchor its coverage-enum table and delegate back to this file's §Install state for the
   canonical runbook — they are not a duplicate of the runbook content or auth-wall analysis.
   The intro section's polling protocol (CodeAnt as CR-path supplement, `merge-gate.sh`
   clean-signal requirement) is unique to this file.

**Conclusion: no dedup warranted.** The file is the designated canonical home for CodeAnt CLI
state and does not restate content from any sibling doc.

## Graphite status — stale fact requiring correction

The `## Graphite — Known Outage` section states:

> **Status: confirmed non-functional repo-wide, not a per-PR or docs-only-skip pattern.**

As of 2026-08-07:

- Issue #614 (the Graphite outage tracker) was **closed** on 2026-08-07.
- PR #1104 (merged 2026-08-07) shows `graphite-app[bot]` posting a `COMMENTED` review
  (`state: COMMENTED`, `submittedAt: 2026-08-07T18:55:58Z`) and a completed
  `Graphite / AI Reviews` check-run (`status: completed`, `conclusion: success`,
  `started_at: 2026-08-07T18:58:20Z`) — confirming the GitHub App is alive and reviewing again.
- The diagnostic method documented in the section itself (checking for the check-run, not just
  comment absence) is satisfied: the check-run is present, the app is active.

The "confirmed non-functional" claim, the "STOP and mark Graphite inactive" directive, and the
"every PR opened since #463 through #612 shows zero Graphite activity" summary are now
historically accurate but no longer describe the current state.

The appropriate correction is a **status-update note** appended to the outage section — not a
rewrite. The historical record (when the outage was detected, its diagnostic evidence, the
retained-trigger rationale) is accurate and worth preserving as context for future re-checks.

## Options considered

### Option 1: Pure KEEP — decision record only, no file changes

Accept the Graphite outage section as historical context, even if the status is stale.

**Rejected.** The "confirmed non-functional" language is an active directive that could cause
an agent to mark Graphite as non-functional when it is actually posting reviews. The issue
instructions explicitly identify this as a legitimate correction to make (issue body: "if the
file asserts Graphite silence as current fact, that is a legitimate small correction to note or
fix (cite PR #1104's graphite-app[bot] comment as evidence)").

### Option 2: KEEP + Graphite status update (chosen)

Add a one-paragraph status-update note at the end of the Graphite outage section stating that
Issue #614 was resolved, Graphite is active again (citing PR #1104 evidence), and the
"non-functional" diagnosis is now historical.

**Chosen.** This is the minimal correct action. The historical narrative is preserved; a reader
picking up this file after the outage resolution will see the resolution status clearly.

### Option 3: Rewrite / remove the outage section

Remove or substantially rewrite the outage section now that the outage is resolved.

**Rejected.** The diagnostic method, the trigger rationale (why Graphite remained in the active
trigger set despite the outage), and the check-run evidence approach are useful operational
guidance for future monitoring. The section's value is not the status claim alone; the
surrounding context warrants preservation.

## Canonical ownership boundaries

| Concern | Owner | Non-owner action |
|---------|-------|-----------------|
| CodeAnt supplemental polling protocol (merge-gate.sh signal, `@codeant-ai` nudge) | This file (intro section) | Referenced from `cr-github-review.md` prose |
| Graphite supplemental polling protocol and outage history | This file (outage section) | Referenced from `cr-github-review.md` §Three-Tier |
| CodeAnt CLI install state, auth runbook, coverage baseline | This file §Install state | Point here; do not restate (`local-review-cli-failure-modes.md` does this correctly) |
| CLI binary-absent failure mode and diagnostic table | `local-review-cli-failure-modes.md` §CodeAnt CLI not installed | Cross-reference; runbook pointer already in place |
| App-vs-CLI independence lesson (PR #763 incident) | `feedback_review_clis_down_app_independent.md` core narrative | Do not restate the incident; this file is the runbook |

## Preserved invariants

- The intro section (CodeAnt and Graphite as supplemental reviewers) is unchanged.
- The Graphite outage section historical record is preserved byte-for-byte; only a status-update
  note is appended.
- The `## CodeAnt Local CLI` section and the `### Install state` subsection are unchanged.
- `cr-github-review.md`, `cr-merge-gate.md`, `local-review-cli-failure-modes.md`,
  `feedback_review_clis_down_app_independent.md` are not modified.

## Remediation and verification

Changes in this PR:
1. `.claude/reference/codeant-graphite-supplemental.md` — Graphite status-update note appended
   to the Known Outage section.
2. `.claude/reference/codeant-graphite-supplemental-hotspot-decision.md` — this decision record.
3. `.claude/reference/README.md` — one catalog bullet added.

`reference-catalog-lint.sh` must pass. `rule-lint.sh` and `verbatim-block-lint.sh` must pass
unchanged. `git diff origin/main...HEAD --stat` shows only these three files.

## Future edits and reconsideration

- Future CodeAnt install-state updates belong in this file's §Install state subsection.
- The Graphite outage section can be further condensed if the historical context ages to the
  point where it creates confusion rather than clarity.
- Reconsider if the "Decision: kept in the active trigger set, not removed" rationale changes
  (e.g., if Graphite proves unreliable again after resuming).

## Related

- `.claude/reference/codeant-graphite-supplemental.md` — the adjudicated file; CodeAnt and Graphite supplemental review protocol + CodeAnt CLI state
- `.claude/reference/feedback-review-clis-down-app-independent-hotspot-decision.md` — companion decision (Issue #1074); confirmed §Install state as canonical; the addendum in the memory file was trimmed to a pointer here
- `.claude/reference/local-review-cli-failure-modes.md` — cross-references §Install state runbook; §CodeAnt CLI not installed is the sibling failure-mode doc
- `.claude/reference/local-review-cli-failure-modes-hotspot-decision.md` — sibling file hotspot (similar 3-PR window, same contributing PRs #821 and #858); verdict KEEP
- `.claude/reference/capability-discovery-examples-hotspot-decision.md` — PR #858 also touched this file; coordinated rung-renumbering propagation
- Issue #1083 — this hotspot
- Issue #819 — CodeAnt CLI install (PR #821)
- Issue #852 — browser rung 4 addition (PR #858)
- Issue #782 — compact-result-contract / FU-7 (PR #946)
- Issue #614 — Graphite outage tracker; closed 2026-08-07 after Graphite resumed
- PR #1104 — first confirmed Graphite activity post-outage; `graphite-app[bot]` COMMENTED review + completed check-run as evidence
