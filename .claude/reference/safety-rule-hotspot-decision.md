# Safety Rule Hotspot Decision

Reference for Issue #957 (`.claude/rules/safety.md` churn hotspot). Not auto-loaded.

## Executive summary

### Verdict: **KEEP** the file as the canonical safety contract; make **no operative content change**

`.claude/rules/safety.md` is the canonical source of the SAFETY and MINDSET verbatim
blocks that `verbatim-block-lint.sh` byte-enforces in `subagent-phase-guardrails.md`;
agent definitions carry paraphrased versions and are explicitly excluded from byte comparison. Its 11-PR churn since 2026-07-19 falls into two dominant
classes — capability-ladder evolution (4 PRs, primary driver) and corpus compression
(4 PRs, cross-file) — neither of which a structural split or extraction reduces. No
merge conflicts were recorded across the full 11-PR window.

This decision is intentionally reference-only. The subject file, `subagent-phase-guardrails.md`,
`verbatim-block-lint.sh`, and the auto-loaded rule corpus remain byte-for-byte unchanged.

## 1. Trigger and current evidence

Issue #957 was filed by `/wrap` churn detection after PR #951 merged. It recorded 11 distinct
merged PRs touching the file since 2026-07-19: PRs #660, #739, #742, #762, #787, #804, #817,
`#858`, #870, #919, #920.

Measured at `main` at the 5dd7ddc commit, the file is 1,354 words — below the 2,000-word
per-file warning. The corpus total is 11,459 words against the 11,749 ratchet cap, with 290-word
headroom.

| PR | Title | Churn class |
|----|-------|-------------|
| #660 | refactor: condense rule corpus 12232 → 10921 words | Corpus compression |
| #739 | feat: hard authorship guard — automated PR tools touch only my own PRs | New policy: authorship guard |
| #742 | refactor: condense rule corpus 11969 → 11419 words | Corpus compression |
| #762 | fix: generalize capability discovery into an explicit CLI ladder | Capability-ladder evolution |
| #787 | fix: permit rm of verified-untracked files in the root repo | Destructive-command refinement |
| #804 | refactor: compress rule corpus 12166 → 10999 words | Corpus compression |
| #817 | fix: fire the capability ladder on deferral, not on "impossible" | Capability-ladder refinement |
| #858 | feat: add the browser as rung 4 of the capability ladder | Capability-ladder evolution |
| #870 | fix: gate the browser rung on rungs 1–3 actually failing | Capability-ladder refinement |
| #919 | refactor: free 430 words of rule-corpus budget | Corpus compression |
| #920 | fix: drop rule 3's flag enumeration, pin untracked selector to root repo | Destructive-command refinement |

Churn class summary:

| Churn class | PRs | Count |
|-------------|-----|-------|
| Capability-ladder evolution / MINDSET-block coupling | PRs #762, #817, #858, #870 | 4 |
| Corpus compression (cross-file sweeps) | PRs #660, #742, #804, #919 | 4 |
| New policy: authorship guard | PR #739 | 1 |
| Destructive-command refinement | PRs #787, #920 | 2 |

## 2. Options considered

### Option 1: Extract three inline sections to paired reference docs (CR plan)

The CodeRabbit plan for Issue #957 proposes extracting the mechanism and rationale from
§Destructive Commands, §Secrets & Credentials, and §Untrusted Code & Network into three
new reference docs (`env-guard.md`, `secrets-guard.md`, `untrusted-network-guard.md`),
leaving only binding directives and pointer lines in `safety.md`.

**Rejected** for three reasons:

(a) **Wrong target.** The extraction addresses only 2 of the 11 churn PRs (#787 and #920 in
the Destructive Commands section). The primary churn driver — capability-ladder evolution (4
PRs) — is untouched by extraction. The MINDSET verbatim block in §Capability Discovery and
the inline Capability Discovery prose must stay byte-identical, enforced by
`verbatim-block-lint.sh`. Every future ladder change produces a paired edit to both, regardless
of what happens to the other three sections.

(b) **Budget headroom is comfortable.** With 290-word headroom and no per-file warning
triggered, no budget pressure motivates the extraction.

(c) **No linting gap.** The task prompt's operative-change trigger is verbatim duplication the
lints do not already govern. The only verbatim duplication in this file is the SAFETY and
MINDSET blocks, and those are already byte-verified by `verbatim-block-lint.sh`. The three
inline sections (Destructive Commands, Secrets, Untrusted Network) contain no verbatim copies
elsewhere — they are inline mechanism, not lint-ungoverned duplication.

### Option 2: KEEP + record the decision (this option)

**Chosen.** The file is the correct and intentional single home for the safety prohibitions
and the canonical source for the SAFETY and MINDSET verbatim blocks. Its churn is required
propagation from feature-driven evolution, not an accumulation of independent structural
concerns.

## 3. Canonical ownership

| Content | Runtime owner | Canonical source |
|---------|---------------|------------------|
| SAFETY block text | `subagent-phase-guardrails.md` (verbatim copy) | `.claude/rules/safety.md` |
| MINDSET block text | `subagent-phase-guardrails.md` (verbatim copy) | `.claude/rules/safety.md` |
| Authorship-guard mechanism | `authorship-guard.md` | `.claude/rules/safety.md` §Authorship |
| Capability-discovery examples | `capability-discovery-examples.md` | `.claude/rules/safety.md` §Capability Discovery |
| Browser-rung detail | `browser-capability-rung.md` | `.claude/rules/safety.md` §Capability Discovery |
| Byte-identity enforcement | `verbatim-block-lint.sh` | CI check on every PR |

The §Authorship and §Capability Discovery sections already delegate mechanism to reference
docs — the pattern the CR plan proposes for the remaining three sections. Those two delegations
exist because the authorship guard is a single self-contained concern (PR #733) and the
capability-discovery examples are a long worked-example catalog. The remaining three sections
(Destructive Commands, Secrets & Credentials, Untrusted Code & Network) are short prohibitions
with inline exceptions; their mechanism fits the auto-loaded rule file.

## 4. Preserved invariants

- The SAFETY and MINDSET verbatim blocks remain byte-identical to their copies in
  `subagent-phase-guardrails.md` on every commit; `verbatim-block-lint.sh` CI-enforces this.
- The `.env.{example,sample,template}` token in §Destructive Commands remains byte-identical
  to the surface `env-template-allowlist-lint.sh` checks.
- No binding prohibition is removed or weakened.
- The corpus word count and ratchet cap remain unchanged.

## 5. Remediation and verification

The remediation adds only this decision record and its catalog entry in
`.claude/reference/README.md`. Verification must confirm:

- no diff in `safety.md`, `subagent-phase-guardrails.md`, or any auto-loaded rule file;
- exactly one catalog entry for this file in `README.md`;
- `reference-catalog-lint.sh` exits clean; and
- `verbatim-block-lint.sh` exits clean (blocks remain byte-identical).

## 6. Future edits and reconsideration

Every capability-ladder change must propagate simultaneously to both the inline Capability
Discovery section in `safety.md` and the MINDSET block in `subagent-phase-guardrails.md`.
This is structural: the lint enforces byte identity, so the two surfaces cannot drift.
No single-file edit removes this requirement.

Reconsider the extraction the CR plan proposes only if: (a) budget pressure returns — i.e.
the ratchet cap forces a targeted compression of the largest rule files — and (b) the three
sections have grown beyond their current inline scope. In that case, the CR plan's three-doc
approach (`env-guard.md`, `secrets-guard.md`, `untrusted-network-guard.md`) is the documented
starting point.

## 7. Related precedent

- `.claude/reference/subagent-phase-guardrails-hotspot-decision.md` — KEEP when all churn is
  required propagation from canonical rule files, byte-guarded by `verbatim-block-lint.sh`
  (Issue #1033). Closest structural parallel: that file holds the verbatim-block copies;
  this file is the canonical source.
- `.claude/reference/cr-github-review-rule-hotspot-decision.md` — KEEP single canonical
  polling-loop rule after 11 PRs; churn is corpus-compression sweeps + by-design review-chain
  policy evolution (Issue #953).
- `.claude/reference/bugbot-rule-hotspot-decision.md` — KEEP single canonical BugBot rule
  file after 5 PRs; only identified duplication already cleaned up before adjudication
  (Issue #1036).
- `.claude/reference/churn-hotspots.md` — hotspot reports are observational and require
  adjudication before any operative change is made.
