# Researcher Hotspot Decision

Reference for Issue #1172 (`.claude/agents/researcher.md` churn hotspot). Filed by `/wrap` after PR #1166 merged. Not auto-loaded.

## Executive summary

### Verdict: **KEEP** the self-contained agent definition; make **no operative change**

Keep `.claude/agents/researcher.md` as the single runtime contract for read-only exploration subagents. Do not split it by concern, replace embedded safety prose with reference pointers, or restructure the "When to Spawn" guidance.

The three reported touches are coordinated fixes and propagation passes — not independent concern accumulation. PR #1016 stripped duplicated autonomy prose as part of a shared inheritance-extraction sweep across all five agent files. PR #1131 added the required `name:` frontmatter field and renamed `allowed-tools:` to `tools:` — changes that applied to multiple agent files simultaneously. PR #1167 updated three prose body references from the old key name to the new one, a consistency follow-on to #1131. Zero merge conflict rounds were recorded across all three PRs. No structural change is warranted.

This decision is intentionally reference-only. `.claude/agents/researcher.md`, its YAML frontmatter, the other agent definitions, `.claude/agents/README.md`, and the auto-loaded rule corpus remain byte-for-byte unchanged.

## 1. Trigger and current evidence

Issue #1172 recorded three merged PRs touching `researcher.md` since 2026-07-30: PRs #1016, #1131, and #1167. These were verified by running `git log --follow -- .claude/agents/researcher.md` and inspecting the diff for each commit.

| Churn class | PRs | What changed |
|-------------|-----|--------------|
| Inheritance extraction | PR #1016 (`46c4d40`, Aug 5 2026) | Removed "## Autonomy Rules" section (4 lines); condensed Skill-First Note to one paragraph noting harness inheritance. Shared class — all five agent files were pruned in the same PR. |
| Agent registration fix | PR #1131 (`9a4ab06`, Aug 8 2026) | Added `name: researcher` frontmatter field (required for `subagent_type` resolution); renamed `allowed-tools:` → `tools:` in frontmatter (silently-ignored key corrected). Shared class — all five agent files received `name:`; researcher and phase-c-merger received `tools:`. |
| Prose consistency fix | PR #1167 (`2368c4c`, Aug 12 2026) | Updated three body-text references from the old `allowed-tools` key name to `tools`, matching the frontmatter rename in #1131. Researcher-specific follow-on. |

Measured at current `main`, the definition is 106 lines, well below the 2,000-word per-file warning. Zero conflict rounds across all three PRs. No touch changed the tool allow-list, the exit-report vocabulary, the read-only mandate, or the "When to Spawn" guidance. The dominant driver is coordinated registration-fix propagation, not accumulation of independent concerns.

## 2. CodeRabbit plan adjudication

CodeRabbit correctly identified the three PRs as the churn window, flagged a KEEP default, and requested git-verified attribution — noting that earlier exploration failed due to tool outages. The verified attribution confirms its KEEP recommendation without qualification.

CodeRabbit's three design alternatives — KEEP + targeted dedup, KEEP + content move, and SPLIT — each require independent churn evidence that is not present. The Safety Rules section is paraphrased, not verbatim, so it is not a `verbatim-block-lint.sh` target and not a lint-driven dedup opportunity. The Skill-First Note is already the adapted non-invoking form prescribed for Skill-less agents. The exit-report schema (`complete|partial|blocked`) is deliberately distinct from the phase-agent schema and not a dedup target. No pointer substitution is lint-viable or behavioral-neutral under the current loader.

## 3. Options considered

### Option 1: KEEP with no operative change

**Chosen.** Repository history does not show any section driving independent churn. All three PRs are coordinated propagation or a sequential two-step fix (#1131 renamed the key; #1167 updated the prose). A reference-only decision makes the next hotspot report evidence-aware while preserving the complete self-contained prompt.

### Option 2: KEEP + targeted dedup of Safety Rules

**Rejected.** The "Safety Rules (NON-NEGOTIABLE)" section in `researcher.md` is a paraphrased adaptation of the canonical SAFETY block — not verbatim — so `verbatim-block-lint.sh` does not cover it and a pointer substitution would not be lint-governed. Subagents do not auto-load `.claude/rules/` at spawn time, so the operative safety posture must remain inline.

### Option 3: KEEP + move "When to Spawn" to README

**Rejected.** The "When to Spawn" section has not changed in the reported window. Moving it to `.claude/agents/README.md` would split the self-contained agent contract and require readers to cross-reference a second file to understand when to use researcher. No churn evidence motivates this refactor.

### Option 4: SPLIT

**Rejected.** `researcher.md` is 106 lines and has one concern: providing the complete read-only research agent contract at spawn time. Its sections (tool restrictions, safety rules, runtime context, workflow, exit format, when-to-spawn, skill-first note) are short, mandated compliance restatements or stable guidance. A split would create multiple files each of which is too small to be coherent, without eliminating any source of churn.

## 4. Canonical ownership boundaries

| Content | Runtime owner | Detailed/canonical owner |
|---------|---------------|--------------------------|
| Tool allow-list and `gh api` POST self-enforcement caveat | `.claude/agents/researcher.md` frontmatter + body | Frontmatter enforced by `agents-frontmatter-lint.sh`; `allowed-tools` → `tools` rename guarded by the lint going forward |
| Safety posture (env files, destructive commands, directory scope) | Embedded paraphrase in `researcher.md` | `.claude/rules/safety.md` is canonical; paraphrase is spawn-time availability, not a competing authority |
| Workflow and search strategy | `.claude/agents/researcher.md` | Autonomous by design; no canonical rule file governs the read-only research loop |
| Exit report schema (`complete\|partial\|blocked` vocabulary) | Inline in `researcher.md` | Deliberately distinct from phase-agent schema in `.claude/reference/exit-report-format.md`; not delegated |
| When-to-spawn guidance | `.claude/agents/researcher.md` | `.claude/agents/README.md` and `.claude/rules/subagent-orchestration.md` own the broader agent-catalog and model selection |
| Skill-First Note (non-invoking adapted form) | `.claude/agents/researcher.md` | `.claude/rules/skill-first.md` is canonical; researcher's note is the adapted Skill-less-agent form from `.claude/reference/skill-first-subagent-delivery.md` |
| Model pin (`sonnet`) and agent name (`researcher`) | YAML frontmatter | `.claude/rules/subagent-orchestration.md` sets fleet defaults; frontmatter overrides per-agent |
| Agent catalog, frontmatter schema, and load behavior | `.claude/agents/README.md` | `.claude/rules/subagent-orchestration.md` owns spawn requirements |

## 5. Preserved invariants

- The `tools:` frontmatter field and the tool allow-list are unchanged. Read-only Bash commands remain the only permitted Bash surface.
- The `gh api` POST self-enforcement caveat remains inline — the harness cannot distinguish GET from POST on `gh api *`, so self-enforcement is the only safety gate.
- The exit-report vocabulary (`complete`, `partial`, `blocked`) and the `AGENT: researcher` line remain unchanged and distinct from the phase-agent schema.
- The `model: sonnet` pin in frontmatter is unchanged.
- The `name: researcher` frontmatter field added in PR #1131 is preserved — it is the required identifier for `subagent_type` resolution.
- No change is made to any other agent definition, `.claude/agents/README.md`, or any auto-loaded rule file.

## 6. Remediation and verification

The remediation consists of exactly two changes:

1. **`.claude/reference/researcher-hotspot-decision.md`** — this file.
2. **`.claude/reference/README.md`** — one catalog entry added (matching sibling format).

Verification must confirm:

- no diff in `researcher.md` or any other agent definition;
- exactly one catalog entry for `researcher-hotspot-decision.md` in `README.md`;
- `reference-catalog-lint.sh` exits clean;
- `run-doc-lints.sh` (6 lints, 0 failed) exits clean;
- `rule-lint.sh` exits clean.

## 7. Future edits and reconsideration

Edit `researcher.md` when the spawn contract, tool allow-list, exit-report vocabulary, or read-only mandate changes. Keep policy rationale and mechanism detail in rule files and references.

Reconsider SPLIT only if the researcher agent accumulates a second independent task type with a distinct caller (comparable to `pm-worker.md`'s issue-creation and repo-bootstrap tasks), or if the tool allow-list and safety posture diverge into competing seams that generate conflict rounds. Reconsider dedup only if the Safety Rules section diverges from `.claude/rules/safety.md` canonical text and `verbatim-block-lint.sh` scope is extended to cover it.

Reopen this ticket if a new churn window shows `conflict_rounds > 0` — PR count alone is not a structural signal for a file this focused.

## Related precedent

- `.claude/reference/phase-a-fixer-hotspot-decision.md` — KEEP/no-runtime-change for a self-contained phase-agent contract; 9 PRs driven by safety-posture propagation and one handoff contract introduction (Issue #975).
- `.claude/reference/phase-b-reviewer-hotspot-decision.md` — KEEP/no-runtime-change for the Phase B state machine; 14 PRs, all coordinated review-state-machine and embedded-safety propagation (Issue #942).
- `.claude/reference/phase-c-merger-hotspot-decision.md` — KEEP + dedup for phase-c-merger; researcher and phase-c-merger are the two Skill-less agents that share the `tools:` key (Issue #976).
- `.claude/reference/pm-worker-hotspot-decision.md` — KEEP + one safety bullet addition for pm-worker; shared churn class (PR #1016 inheritance extraction, PRs #787/#902/#920 safety propagation) shows cross-agent coordinated-edit pattern (Issue #1023).
- `.claude/reference/agents-readme-hotspot-decision.md` — KEEP for the agent-system documentation hub; PR #1016 resolved the inheritance-model structural concern across all agents simultaneously (Issue #973).
