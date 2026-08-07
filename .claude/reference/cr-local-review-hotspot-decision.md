# cr-local-review Rule Hotspot Decision

Reference for Issue #992 (`.claude/rules/cr-local-review.md` churn hotspot). Not auto-loaded.

## Executive summary

### Verdict: **KEEP, no change**

Keep `.claude/rules/cr-local-review.md` as-is. The file is 684 words, well below the 2,000-word
per-file warning. All 7 churn PRs carried legitimate changes: policy tightening from false-clean
incidents, corpus compression under budget pressure, a new coverage-visibility mandate, and a
CLI abstraction refactor. No concrete duplication with any other file is confirmed.

## 1. Trigger and measured evidence

Issue #992 was filed by `/wrap` churn detection after PR #991 merged. The 7 triggering PRs —
#650, #660, #666, #742, #804, #806, #946 — all merged since 2026-07-21.

At diagnosis time (`main` `7e386a7`), the file is **684 words, 55 lines** — below the 2,000-word
per-file lint warning. Corpus total: ~11,443 words (CLAUDE.md 1,358 + rules 10,085), under both
the 11,749 ratchet cap and the 12,000-word soft gate.

## 2. Per-section churn attribution

Evidence traced via `gh pr diff` for each of the 7 PRs.

| PR | Title | Section(s) touched | Driver |
|----|-------|--------------------|--------|
| #650 | `fix(#642): treat local-CLI false-clean runs as failures` | Added entire "A clean result may be a failed run (NON-NEGOTIABLE)" section with inline shell detection snippet; tightened fix-loop step 5 from "no findings" to "verified-successful run with no findings"; tightened exit criteria | Policy tightening — false-clean incident proved exit 0 was being misread as a clean pass |
| #660 | `refactor(#646): condense rule corpus 12232 → 10921 words` | Condensed anti-rate-limit pre-flight section; merged Post-Clean section into Exit criteria | Corpus compression under budget pressure |
| #666 | `fix(#663,#664): CodeAnt 403 is a daily review cap, not auth` | Added CodeAnt 403 advisory blockquote | Specific fix from incident — CLI was advising re-auth for an undocumented daily cap |
| #742 | `refactor(#740): condense rule corpus 11969 → 11419 words` | Minor phrasing condensation of CodeAnt 403 blockquote | Corpus compression |
| #804 | `refactor(#790): compress rule corpus 12166 → 10999 words` | Removed anti-rate-limit pre-flight section (content already in `cr-github-review.md`); further condensed CodeAnt 403 advisory; condensed "A clean result" detection narrative | Corpus compression; one targeted dedup (anti-rate-limit → `cr-github-review.md`) |
| #806 | `feat(#769): make zero-coverage local review loud at push time` | Added "Coverage classification" paragraph to Timeout & fallback; added "Determine and record coverage" bullet to Exit criteria | New policy requirement — zero-coverage local review must be surfaced before push |
| #946 | `feat(#782): compact result contracts for the noisiest test + review pipelines` | Replaced raw CLI invocations in "When/how to run" with `local-review.sh` wrapper; replaced inline shell detection snippet with compact reference to `local-review.sh` output contract | CLI abstraction refactor — mechanics extracted to `local-review.sh` (308 lines, new in PR #946) |

**Stable section:** "Never Suppress Linter Errors (NON-NEGOTIABLE)" — zero churn across all 7
PRs. It remained byte-identical through every corpus compression and policy pass.

## 3. Decision: KEEP, no change

**Splitting is not warranted.** The file is 684 words and covers a single cohesive concern: the
local dual-CLI review loop (CodeRabbit + CodeAnt), its false-clean guard, and its exit criteria.
All content belongs in a single policy document; there are no independently-evolving concerns
that a split would isolate.

**Corpus compression passes are cross-file.** Three of the seven PRs (#660, #742, #804) were
broad compression sweeps that touched this file because it was among the larger rule files at
the time. These sweeps reduced the file from an earlier peak to its current 684 words — no
further compression is indicated.

**No concrete duplication is confirmed.** Two apparent overlap surfaces were checked:

1. *Coverage enum* (`both | cr-only | codeant-only | none`): appears in this rule file (policy
   owner — defines what the agent must classify and surface) and in
   `.claude/reference/local-review-cli-failure-modes.md` (diagnostic guide — explains failure
   shapes and how to triage). These serve different audiences and are linked by cross-reference,
   not duplication. Removing either copy would break the role separation.

2. *Exit codes* (`0` clean · `1` findings · `3` failed run · `4` timeout · `5` not installed):
   appear in this rule (agent-facing policy — "a CLI counts as covered only on exit 0 clean")
   and in `local-review.sh`'s header comment (programmer-facing contract for the script's
   callers). Different audiences; not removable duplication.

**KEEP-no-change rationale matches prior precedents.** This is the same verdict reached for
`cr-github-review.md` (Issue #953) and `safety.md` (Issue #957), both of which showed cohesive
files with legitimate-churn PR histories and no actionable duplication.

## 4. Options considered

| Option | Rationale for rejection |
|--------|------------------------|
| SPLIT into separate concern files | No independently-evolving concerns exist; 684 words is well within single-file thresholds; would scatter the single-topic policy |
| Extract mechanics into script | Already done by PR #946 (`local-review.sh`); the rule now delegates all mechanics to the script and retains only policy prose |
| KEEP + targeted dedup | No concrete duplication confirmed; no dedup is actionable |
| **KEEP, no change** | **Chosen.** All churn is legitimate; no structural remedy is warranted |

## 5. Ownership table

| Concern | Canonical owner | Non-owner action |
|---------|----------------|------------------|
| Local dual-CLI review policy | `.claude/rules/cr-local-review.md` | Point to this rule |
| CLI invocation + false-clean checks | `.claude/scripts/local-review.sh` | Import the script, do not copy invocation logic |
| Failure shapes, 403 triage, 15-file cap | `.claude/reference/local-review-cli-failure-modes.md` | Cross-reference for diagnostic detail |
| Linter-error suppression prohibition | `.claude/rules/cr-local-review.md` ("Never Suppress" section) | CLAUDE.md cites this file as canonical owner; do not move |

## 6. Preserved invariants

- "Never Suppress Linter Errors (NON-NEGOTIABLE)" section stays in `cr-local-review.md`.
  Rationale: `safety.md` scopes to destructive-command and secret prohibitions — thematic mismatch.
  CLAUDE.md cites `cr-local-review.md` as the canonical owner. Moving it would add net prose
  against a tight budget and create a cross-file navigation burden. This placement was considered
  and maintained through all 7 churn PRs.
- The `local-review.sh` output contract (`ok`, `findings`, `verified_run`, `failure_mode`,
  `relevant_error`, `log_path`) and behavior stay byte-for-byte unchanged by this adjudication.
- The coverage classification enum (`both | cr-only | codeant-only | none`) definition stays
  in this rule as the policy owner.
- All cross-references to `.claude/reference/local-review-cli-failure-modes.md` stay in place.

## 7. Verification

- `bash .github/scripts/rule-lint.sh` — must pass (no rule files changed).
- `bash .github/scripts/verbatim-block-lint.sh` — must pass.
- `.claude/scripts/reference-catalog-lint.sh` — must pass after README entry added.
- Corpus word count unchanged (no rule files edited).

## 8. Related precedents

- Issue #953 / `cr-github-review-rule-hotspot-decision.md` — KEEP for the sibling polling-loop rule; same "cohesive, cross-reference hub, compression-driven churn" pattern
- Issue #957 / `safety-rule-hotspot-decision.md` — KEEP no-operative-change for the canonical safety contract
- Issue #1005 / `local-review-cli-failure-modes-hotspot-decision.md` — KEEP for the companion reference file; both files share the same review-loop topic
- `.claude/reference/churn-hotspots.md` — hotspot mechanism, calibration, and re-open trigger logic
