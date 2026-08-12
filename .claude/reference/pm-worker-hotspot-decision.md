# PM Worker Hotspot Decision

Reference for Issue #1023 (`.claude/agents/pm-worker.md` churn hotspot). Not auto-loaded.

## Executive summary

### Verdict: **KEEP** the single agent file; apply one targeted safety-block fix

Keep `.claude/agents/pm-worker.md` as the one pm-worker agent definition. Do not split it into
an issue-creation agent and a repo-bootstrap agent, replace its embedded safety posture with
pointers, or extract the tri-path resolver idiom in this remediation.

The measured churn falls into two clear classes: (1) propagation of repository-wide safety-block
policy changes and (2) a single feature addition (auto-file dedup). Neither class constitutes
independent concern accumulation; the two tasks share one spawn contract and no caller demarcation
separates them at runtime. The one genuine inconsistency is a missing capability-ladder MINDSET
bullet — present in `phase-a-fixer.md` and `phase-b-reviewer.md` but absent from `pm-worker.md`
since the PR #1016 inheritance extraction. This is fixed by a single bullet addition.

## 1. Trigger and evidence

Issue #1023 was filed by `/wrap` churn detection after PR #1022 merged. It recorded 5 distinct
merged PRs touching `.claude/agents/pm-worker.md` since 2026-07-23.

At diagnosis time the file is 139 lines (135 content + 4 frontmatter lines — 2 delimiters plus 2
key-value entries), well below the 2,000-word per-file warning.

### Churn-class table

| Churn class | PRs | What changed |
|-------------|-----|--------------|
| Feature propagation — dedup check | PR #725 | Added `issue-dedup.sh` tri-path invocation and strong/weak match logic to the Issue Creation task |
| Safety posture propagation | PRs #787, #902, #920 | Tightened rule 3 (permitted non-recursive `rm` on untracked root-repo paths); aligned env-template allow-list; pinned untracked selector to root-repo scope |
| Inheritance extraction | PR #1016 | Stripped SAFETY/MINDSET/SKILLS corpus injection that duplicated the auto-loaded rules corpus; retained prose-form safety bullets |

The dominant driver is propagation of repository-wide policy into a self-contained subagent prompt,
not conflict between the two tasks (Issue Creation and Repo Bootstrap) that the agent hosts.
PR #1016's inheritance extraction also introduced a gap: it removed the double-pay MINDSET block
but left the in-prose safety bullet list one bullet short compared to its phase-agent siblings.

## 2. Options considered

### Option 1: SPLIT into issue-creation agent and repo-bootstrap agent

**Rejected.** The two tasks share one spawn contract (`.claude/skills/pm/SKILL.md` calls
`pm-worker` with a task tag), the same model pin, the same safety posture, and the same exit
report schema. No independent-caller demarcation exists: `/pm` routes both tasks through the same
agent. A split would require a new router, two coordinated safety-block updates per policy change
instead of one, and a revised spawn call in the pm skill — net complexity increase with no
demonstrated merge-pain motivation.

### Option 2: Replace embedded safety prose with reference pointers

**Rejected.** Subagents do not auto-load `.claude/rules/` at spawn time. The operative safety
posture must be present in the spawned agent definition. Pointer-only bullets would contradict
the repository's self-contained-agent contract (`.claude/agents/README.md`).

### Option 3: Extract the tri-path resolver idiom into a shared helper

**Deferred.** The tri-path pattern (checking three standard install paths for a script) appears
in the Issue Creation dedup block only — the Repo Bootstrap section directly invokes
`.claude/scripts/repo-bootstrap.sh` without path-probing. The pattern has changed once
(PR #725 added it) and shows no recurring duplicate-maintenance need at its single site.
Extract if the same pattern is introduced elsewhere and then requires a coordinated change.

### Option 4: KEEP + add omitted capability-ladder MINDSET bullet

**Chosen.** A single bullet addition restores safety-posture parity with `phase-a-fixer.md` and
`phase-b-reviewer.md`, corrects a post-PR-#1016 gap, and avoids any behavioral refactor.

## 3. Canonical ownership boundaries

| Content | Runtime owner | Detailed/canonical owner |
|---------|---------------|--------------------------|
| Issue creation flow, dedup check, and CR plan polling | `.claude/agents/pm-worker.md` | `.claude/rules/issue-planning.md` and `.claude/reference/autofile-dedup.md` own shared procedure |
| Repo bootstrap flow | `.claude/agents/pm-worker.md` | `.claude/rules/repo-bootstrap.md` owns the policy; `repo-bootstrap.sh` implements checks |
| Safety and capability posture | Embedded in the agent definition for spawn-time availability | `.claude/rules/safety.md` is canonical; `subagent-phase-guardrails.md` holds verbatim spawn-prompt blocks |
| Skill-first reflex | Embedded prose in the agent definition | `.claude/rules/skill-first.md` is canonical |
| EXIT_REPORT block format | Inline in the agent definition | `.claude/reference/exit-report-format.md` owns the cross-phase field schema |
| OUTCOME vocabulary (`completed`, `blocked`, `exhaustion`) | `pm-worker.md` references the canonical set | `.claude/reference/exit-report-format.md` now owns the non-phase OUTCOME vocabulary (amended: Issue #1171) |
| Model pin (`sonnet`) and frontmatter | `pm-worker.md` YAML frontmatter | `.claude/rules/subagent-orchestration.md` sets the fleet default |

## 4. Preserved invariants

- The spawn contract in `.claude/skills/pm/SKILL.md` remains unchanged; `pm-worker` continues to
  receive a task tag and execute issue creation or repo bootstrap accordingly.
- The Sonnet model pin in frontmatter and in `.claude/rules/subagent-orchestration.md` is
  unchanged.
- The soft-degrade dedup semantics (strong match → comment and defer; weak match → file with note;
  helper missing → file with degraded-check note) are unchanged.
- `NEXT_PHASE: none` and the non-phase exit report schema remain unchanged.
- No change is made to `.claude/agents/README.md`, other phase agent definitions, or any auto-loaded
  rule file as part of this remediation.

## 5. Remediation and verification

The remediation consists of exactly two changes:

1. **`.claude/agents/pm-worker.md`** — one bullet added to the Safety Rules section: the
   capability-ladder MINDSET bullet, byte-identical to the one in `phase-a-fixer.md` (line 45)
   and `phase-b-reviewer.md` (line 26). No other edit.
2. **`.claude/reference/README.md`** — one catalog entry added under `### Audits and research
   (point-in-time)`.

Verification must confirm:

- exactly one new bullet in `pm-worker.md` (diff shows a single insertion in the Safety Rules
  section);
- no other diff in `pm-worker.md` or any other agent definition;
- exactly one catalog entry for `pm-worker-hotspot-decision.md` (no duplicate);
- `reference-catalog-lint.sh` exits clean;
- `verbatim-block-lint.sh` exits clean (`pm-worker.md` is an explicitly excluded paraphrased
  surface; no byte-compare is run against it);
- rule-lint and full Bash/Python test suites pass.

## 6. Future edits and reconsideration

Edit `pm-worker.md` when the spawn contract, exit report schema, or task scope changes. Keep
policy rationale in rule files; keep deterministic procedure in scripts.

Reconsider SPLIT only if a distinct independent caller emerges (e.g., a repo-bootstrap-only skill
that never creates issues), or if conflict evidence — not touch count — shows that the two tasks
require contradictory concurrent edits.

Revisit the tri-path resolver extraction if the same pattern requires a coordinated change across
both tasks in a future PR.

## 7. Related precedent

- `.claude/reference/phase-a-fixer-hotspot-decision.md` — KEEP + no runtime change when churn
  reflects policy propagation into a self-contained agent contract (Issue #975).
- `.claude/reference/phase-b-reviewer-hotspot-decision.md` — KEEP when churn follows the review
  state machine and embedded safety/capability posture, not independent concerns (Issue #942).
- `.claude/reference/phase-c-merger-hotspot-decision.md` — KEEP + dedup when churn is driven by
  shared prose rather than independent runtime tasks (Issue #976).
- `.claude/reference/scheduling-reliability-hotspot-decision.md` — KEEP when the dominant driver
  is an unstable substrate propagated through one owner, not accumulation of independent concerns.
- `.claude/reference/churn-hotspots.md` — hotspot reports are observational and require
  adjudication.

## Amendment — Issue #1171

The §3 ownership row for "OUTCOME vocabulary" was updated to reflect that the canonical values
(`completed`, `blocked`, `exhaustion` for pm-worker; `findings`, `inconclusive`, `blocked` for
researcher) now live in `.claude/reference/exit-report-format.md`. `pm-worker.md` and
`researcher.md` reference that set rather than defining a private vocabulary. This change was
required by Issue #1171, which identified that non-phase agents were inventing undefined OUTCOME
values because no canonical enumeration existed.
