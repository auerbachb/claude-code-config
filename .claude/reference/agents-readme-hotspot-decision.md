# Agents README Hotspot Decision

Reference for Issue #973 (`.claude/agents/README.md` churn hotspot). Not auto-loaded.

## Executive summary

### Verdict: **KEEP** the file as the agent-system documentation hub; make **no operative content change**

`.claude/agents/README.md` is the single index for the custom-agent system. Its churn across
10 PRs reflects coordinated propagation of cross-cutting policy changes into the authoritative
documentation surface — not separable, independently-owned concerns that extraction would decouple.
The most substantial restructuring need (the inheritance-model correction) was already resolved by
PR #1016 today before this issue was addressed. The remaining model-naming policy and per-phase
rationale sections are load-bearing documentation that external lint tooling and canonical reference
files point to by heading name.

## 1. Trigger and measured evidence

Issue #973 recorded 9 merged PRs touching `.claude/agents/README.md` since 2026-07-21; a
subsequent comment appended PR #1016 (2026-08-05), bringing the measured window to 10 PRs:
PRs #617, #750, #762, #787, #799, #817, #858, #902, #920, #1016.

Measured at `main` `5a3a0f4`, the file is 136 lines. The changes divide cleanly by concern:

| Churn class | PRs | What changed |
|-------------|-----|--------------|
| Skill-first reflex propagated into spawn guidance | PR #617 | SKILLS block placement documented in spawning pattern |
| Model-fleet vocabulary update | PR #750 | "Opus 5" → bare family names; model essay added (#791) |
| Capability-ladder CLI step added | PR #762 | MINDSET paraphrase updated to add CLI install rung |
| Root-repo untracked rm selector | PR #787 | SAFETY paraphrase updated with `ls-files --others` pattern |
| Versionless naming policy + effort | PR #799 | Model naming essay and per-phase rationale table added |
| Capability-ladder deferral trigger | PR #817 | MINDSET paraphrase updated to fire on deferral not "impossible" |
| Browser rung added | PR #858 | MINDSET paraphrase updated to add browser rung; Browser MCP note added |
| Env-template allow-list alignment | PR #902 | SAFETY paraphrase updated to canonical exception token |
| Untracked selector pin | PR #920 | SAFETY paraphrase pinned to root-repo ls-files output |
| Inheritance model verification + de-dup | PR #1016 | Rewrote intro, spawning note, Adding New Agents to reflect harness-native rule injection; removed SKILLS from mandatory spawn list; confirmed inheritance via live probe (Issue #777 / FU-1) |

## 2. What PR #1016 already resolved

PR #1016 performed the most substantial structural fix before this issue was actioned. It:

- **Updated the intro** to accurately state harness-native inheritance: "The harness automatically
  injects the project CLAUDE.md hierarchy and `.claude/rules/*.md` into every custom `subagent_type`
  agent at spawn — no manual rule-file injection needed."
- **Removed the SKILLS block** from the spawning pattern example (SKILLS is inherited for custom
  agents).
- **Updated the spawning note** to correctly distinguish: SAFETY and MINDSET remain as deliberate
  safety-critical restatements; SKILLS is only needed for Explore/Plan and non-custom spawns.
- **Updated Adding New Agents** to say "Always include the SAFETY and MINDSET blocks as
  safety-critical restatements" with no mention of SKILLS.

Post-PR #1016, there is no stale prose that assumes manual rule-file injection for custom agents.

## 3. CodeRabbit plan adjudication (pre-PR #1016 plan)

The CR plan was generated before PR #1016 landed and proposed extraction of two concerns:

### Proposed extraction: model-naming policy essay + per-phase rationale table

**Not applied for this remediation.** The model naming section carries a heading ("Model naming —
families, never versions") that is directly referenced by two external surfaces:

- `.github/scripts/chip-model-guard-lint.sh` line 248 error message: points users to
  `.claude/agents/README.md "Model naming"` when a versioned model name is detected.
- `.claude/reference/chip-launching.md` line 68: "see `.claude/agents/README.md` 'Model naming'
  for the rule and its scope."

These references make the section load-bearing as a user-facing policy anchor. Moving the body to
a reference file would require updating both pointers, re-testing the lint, and the moved prose
would not reduce future churn — policy changes would still require a paired edit in the reference
doc. The section is short enough (25 lines) that the coordination cost of moving it exceeds its
churn-reduction benefit. The per-phase rationale table (10 lines) provides context that naturally
belongs alongside the model-selection table in the agent system's primary docs.

### Proposed extraction: SAFETY/MINDSET paraphrase from spawning pattern

**Not applied; already improved by PR #1016.** The spawning pattern example is intentionally
paraphrased (not verbatim) and explicitly excluded from `verbatim-block-lint.sh`. The example
shows block *placement*, not the canonical text. PR #1016 removed the SKILLS block from the
example and updated the explanatory note to point readers to `.claude/rules/safety.md`. The
canonical verbatim copies for spawn prompts live in
`.claude/reference/subagent-phase-guardrails.md`; the spawning note now correctly notes that only
SAFETY and MINDSET are mandatory for custom agents.

## 4. Options considered

### Option 1: Extract model naming essay and SAFETY/MINDSET paraphrase to reference docs

**Rejected.** The model naming section is referenced by lint tooling by heading name; extraction
requires paired updates to two external files and does not eliminate future policy churn — it only
relocates it. The SAFETY/MINDSET paraphrase is intentionally short and already points to canonical
sources. Extraction would add a transitive-loading dependency without a measurable churn benefit
given the small section sizes.

### Option 2: Mark entire file as by-design churn and take no action

**Rejected.** While the FU-1 fleet listing is accepted by-design churn (see §5 below), the
broader churn has structural causes (policy essays duplicating separate canonical owners) that
warrant diagnosis and documentation even without a content change.

### Option 3: Keep the file; record the diagnosis and ownership decision

**Chosen.** The file's churn is driven by the same cross-cutting policy propagation observed in
`phase-a-fixer-hotspot-decision.md`, `phase-b-reviewer-hotspot-decision.md`, and
`claude-md-hotspot-decision.md`. PR #1016 already resolved the most significant structural
concern. Recording the diagnosis preserves the classification reasoning for future editors and
establishes what "by-design" versus "policy-drift" edits look like in this file.

## 5. Preserved invariants

The following constraints must survive any future edit to `.claude/agents/README.md`:

- **FU-1 fleet listing** — The Agent Inventory table must list the same model fleet (Opus, Sonnet,
  Haiku, Fable) as the other three FU-1 surfaces identified in
  `.claude/reference/token-efficiency-audit-2026-07.md`. Updates to this table are accepted
  by-design churn — they propagate when the model fleet changes.
- **`.env.<example|sample|template>` token** — The exact string `.env.<example|sample|template>`
  must remain in the file. `.github/scripts/env-template-allowlist-lint.sh` checks it explicitly
  (see the file's `SURFACES` array).
- **"Model naming" heading** — `.github/scripts/chip-model-guard-lint.sh` error message and
  `.claude/reference/chip-launching.md` reference this heading by name. The heading must remain
  present at its current location.
- **Placeholder and agent-inventory tables** — The placeholder reference table and agent inventory
  are the canonical index for spawn-site authors. They must remain in this file; detail belongs
  here, not in a separate reference doc.
- **Adding New Agents checklist** — The five-step checklist must continue describing the correct
  sync steps (no SKILLS mention; SAFETY/MINDSET explicitly required).
- **SAFETY/MINDSET vs SKILLS distinction in spawning note** — Post-PR #1016, the note must
  continue to distinguish SAFETY/MINDSET (mandatory deliberate restatements, even though inherited)
  from SKILLS (only needed for Explore/Plan and non-custom spawns). This distinction must never
  be conflated back to "all three are mandatory."

## 6. Canonical ownership boundaries

| Content | Operative owner in README.md | Shared/detailed owner |
|---------|------------------------------|-----------------------|
| Placeholder syntax and agent inventory | README.md — the primary spawn reference | Agent `.md` files own their own frontmatter |
| Model naming policy | README.md §"Model naming" — the lint-referenced anchor | `chip-model-guard-lint.sh` enforces the scope; `chip-launching.md` cites the section |
| Per-phase model rationale | README.md §"Per-phase rationale" | `subagent-orchestration.md` owns the defaults table (bare model names only, no "why") |
| SAFETY/MINDSET verbatim blocks | `subagent-phase-guardrails.md` — byte-verified canonical home | README.md spawning example shows placement (intentionally paraphrased; excluded from verbatim lint) |
| Inheritance mechanics | README.md §"How It Works" | `token-efficiency-audit-2026-07.md` §FU-1 owns the verification evidence |
| Browser MCP reachability | README.md Agent Inventory note | `browser-capability-rung.md` owns the full surface-selection rules and `phase-c-merger` decision |

## 7. Remediation and verification

The remediation adds only this decision record and its reference-catalog entry. Verification must
prove:

- no diff in `.claude/agents/README.md` or any operative file (rules, scripts, skills, CI);
- exactly one catalog entry for this decision record in `.claude/reference/README.md`;
- `reference-catalog-lint.sh` passes;
- `chip-model-guard-lint.sh`, `env-template-allowlist-lint.sh`, `verbatim-block-lint.sh`, and
  `rule-lint.sh` all pass; and
- all Bash and Python suites remain green.

## 8. Future edits and reconsideration

**Fleet updates:** update only the Agent Inventory table's Default Model column and the model
family name mentions in the "Model naming" section. These are intentional by-design edits — do
not file a new hotspot for them.

**Naming policy changes:** edit only the "Model naming" section body. The lint-referenced heading
must be preserved. Record the change in a dated note in this decision file rather than filing a
new hotspot.

**SAFETY/MINDSET block updates:** update the verbatim copies in `subagent-phase-guardrails.md`
and `rules/safety.md` first. The spawning example in README.md is intentionally paraphrased and
need not be byte-synced on every update — review it once per major SAFETY restructuring.

**Reconsider extraction** of the model naming section only if: (1) the lint error message is
updated to point to a separate reference file, (2) `chip-launching.md` is updated accordingly,
and (3) the section grows beyond 50 lines. All three must hold simultaneously; partial evidence
does not justify the coordination cost.

## Related precedent

- `phase-a-fixer-hotspot-decision.md` — KEEP when churn is required propagation into an operative
  instruction surface.
- `phase-c-merger-hotspot-decision.md` — KEEP + dedup when independently-authored detail can point
  to its canonical owner.
- `claude-md-hotspot-decision.md` — KEEP when frequent updates reflect a cohesive loaded contract.
- `start-issue-hotspot-decision.md` — KEEP when churn is coordinated contract delivery, not
  separable runtime owners.
- `churn-hotspots.md` — hotspot reports are observational; evidence-based structural verdict
  required before any content change.
