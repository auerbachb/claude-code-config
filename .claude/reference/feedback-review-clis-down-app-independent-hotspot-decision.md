# Review CLIs Down ≠ App Reviewers Down — Memory Hotspot Decision

<!-- churn-hotspot: .claude/memory/feedback_review_clis_down_app_independent.md -->

Reference for Issue #1074 (`.claude/memory/feedback_review_clis_down_app_independent.md` churn hotspot). Not auto-loaded.

## Executive summary

### Verdict: **KEEP + targeted dedup** — trim the redundant "Standing state update" addendum to a one-line pointer

Keep `.claude/memory/feedback_review_clis_down_app_independent.md` as the durable incident record for the PR #763 both-CLIs-down event and the App-vs-CLI independence lesson. The core narrative is unique and has no canonical home elsewhere.

Trim the "Standing state update" addendum (added by PR #821, updated by PR #858) to a one-line pointer to `.claude/reference/codeant-graphite-supplemental.md` §Install state. The addendum is a confirmed three-place restatement; CLAUDE.md mandates "dedupe and prune stale entries."

## 1. Trigger and current evidence

Issue #1074 was filed by `/wrap` churn detection after PR #1073 merged. The issue body records 3 distinct merged PRs since 2026-07-24: PRs #806, #821, #858.

### PR attribution (verified per `git log --follow` and `gh pr diff`)

The hotspot detector is **correct** — all three PRs touched this file. The CodeRabbit implementation plan's claim that these PRs "actually touched the sibling file `local-review-cli-failure-modes.md`" is **wrong**: they touched both files. The "true anchors" framing in the CR plan confuses the incident references *inside* the file (PR #763, Issue #819) with the PRs that *modified* the file.

| PR | Commit message | Change to this file |
|---|---|---|
| #806 | `feat(#769): make zero-coverage local review loud at push time` | **Created** the file with the core incident narrative: PR #763 incident, 3 durable lessons, Provenance line |
| #821 | `fix(#819): restore dual-CLI coverage — CodeAnt CLI install path + absent-binary handling` | **Added** the "Standing state update" addendum |
| #858 | `feat(#852): add the browser as rung 4 of the capability ladder` | **Updated** addendum wording: changed "rung 3" to "rung-5 wall"; added "no MCP browser surface can drive it" |

Both `local-review-cli-failure-modes.md` and this memory file were touched by PRs #806, #821, and #858 — the detector correctly flagged each.

**Churn class:** Two-section file with independent ownership. The core narrative (section 1) was written once in PR #806 and never re-edited. The addendum (section 2) was added in PR #821 and refined in PR #858 — two coordinated state-update edits. Churn is low-severity and non-colliding; the two PRs post-creation both owned the same addendum, not independent edits to the same prose.

## 2. Dedup search — confirmed three-place restatement

The "Standing state update" addendum contains the following facts:
- CodeAnt CLI binary installed at v0.5.1 / `/opt/homebrew/bin/codeant`
- Auth blocked at rung 5 (browser OAuth, no non-interactive path)
- Coverage baseline is `cr-only`
- CodeAnt GitHub App is unaffected

These same facts appear in two other files:

| Location | Form | Canonical? |
|---|---|---|
| `feedback_review_clis_down_app_independent.md` §Standing state update | One-paragraph addendum | No |
| `.claude/reference/codeant-graphite-supplemental.md` §"Install state on this machine" | Full detailed section with runbook commands | **Yes** — the richest version |
| `.claude/reference/local-review-cli-failure-modes.md` §"Standing state on this machine" | One-sentence summary + cross-reference | No |

The memory file's addendum is the thinnest version: it has no runbook commands, no Option B path, and no stderr-check guidance. It adds no unique information not already in the canonical reference.

The core incident narrative (the PR #763 incident, the three durable App-vs-CLI lessons, the Provenance line) is **unique** and does not appear in any other file. It is the memory file's reason to exist.

## 3. Options considered

### Option 1: Pure KEEP — record the decision, change no files

Treat the memory note as small, cohesive, and append-only. Accept the three-place restatement as acceptable duplication given file size.

**Rejected.** CLAUDE.md §Memory System mandates "dedupe and prune stale entries." The addendum is a confirmed three-place restatement with no unique content, and its canonical home (`codeant-graphite-supplemental.md`) is already cross-referenced in `local-review-cli-failure-modes.md`. A pure KEEP leaves the addendum as a stale pointer-substitute where a pointer is shorter and more reliable.

### Option 2: KEEP + targeted dedup — trim addendum to a one-line pointer

Keep the core incident narrative intact; replace the addendum with a one-line pointer to the canonical source.

**Chosen.** The trim is the minimal correct action under the CLAUDE.md mandate. The core narrative is preserved. The addendum's content is reachable via the pointer.

### Option 3: SPLIT — separate the addendum into its own memory file

Create a separate memory file for the CodeAnt install-state fact.

**Rejected.** A state-update fact this small does not warrant its own memory file. The fact is already covered by `codeant-graphite-supplemental.md`. A separate file would add a third memory entry for the same state, worsening duplication rather than reducing it.

## 4. Canonical ownership boundaries

| Concern | Owner | Non-owner action |
|---|---|---|
| App-vs-CLI independence lesson; zero-coverage surfacing lesson; self-review scope | `.claude/memory/feedback_review_clis_down_app_independent.md` (core narrative) | Point here for the incident; do not restate the lessons |
| CodeAnt CLI install state, auth runbook, coverage baseline | `.claude/reference/codeant-graphite-supplemental.md` §Install state | Cross-reference; do not re-copy the install facts |
| CLI binary-absent failure mode and restore path | `.claude/reference/local-review-cli-failure-modes.md` §CodeAnt CLI not installed | Cross-reference; do not re-copy the diagnostic table |
| Enforced directive: dual-CLI review, coverage classification, self-review surface | `.claude/rules/cr-local-review.md` | The rule is binding; do not restate enforcement prose in memory |

## 5. Preserved invariants

- The core incident narrative (PR #763 incident, three durable lessons, Provenance line) stays byte-for-byte intact.
- `.claude/reference/codeant-graphite-supplemental.md` and `.claude/reference/local-review-cli-failure-modes.md` are not modified.
- `.claude/rules/cr-local-review.md` is not modified.
- The memory file remains a single cohesive note; it is not split.

## 6. Remediation and verification

Changes in this PR:
1. `.claude/memory/feedback_review_clis_down_app_independent.md` — "Standing state update" addendum trimmed to a one-line pointer.
2. `.claude/reference/feedback-review-clis-down-app-independent-hotspot-decision.md` — this decision record.
3. `.claude/reference/README.md` — one catalog bullet added.

`reference-catalog-lint.sh` must pass with exactly one registered bullet for the new decision doc and no phantom entries. `rule-lint.sh` and `verbatim-block-lint.sh` must pass unchanged.

## 7. Future edits and reconsideration

Future state-update edits for CodeAnt install state belong in `codeant-graphite-supplemental.md` §Install state, not in this memory file.

Reconsider if:
- The core incident narrative is superseded (e.g., a future policy change makes the App-vs-CLI distinction obsolete).
- A second distinct incident requires a new section, at which point the file's coherence should be re-evaluated.

## 8. Related precedent

- `.claude/reference/local-review-cli-failure-modes-hotspot-decision.md` — companion file hotspot (PRs #806, #821, #858 also touched that file); verdict KEEP single multi-incident reference; cross-referenced here because the CR plan confused the two files.
- `.claude/reference/monitor-mode-hotspot-decision.md` — KEEP + dedup precedent; confirmed downstream restatement trimmed to pointer.
- `.claude/reference/state-file-contracts-hotspot-decision.md` — KEEP + targeted-dedup precedent; two restatement sections deduped toward script headers.
- `.claude/reference/churn-hotspots.md` — hotspot mechanism, calibration, and re-open trigger logic.
