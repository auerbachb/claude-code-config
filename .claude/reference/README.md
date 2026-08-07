# Reference Files

This directory contains full forms of multi-line code snippets, JSON schemas, and GraphQL queries that would otherwise inflate the auto-loaded rule context. Rule files reference these when needed.

Files here are NOT auto-loaded by Claude Code. Agents read them on demand when working with the relevant workflow.

## Contents

### Schemas

- `handoff-file-schema.json` — full JSON schema for `~/.claude/handoffs/{owner}/{repo}/pr-{N}-handoff.json`
- `session-state-schema.json` — full JSON schema for `~/.claude/session-state.json`

### Runbooks and long command forms

- `admin-merge-auto-plain.md` — mechanism and contracts for the one `admin-merge.sh --auto-plain` shape Claude may execute itself; plain vs protection-modifying shape distinction (#754)
- `cli-tool-defaults.md` — installed service CLIs (vercel, neonctl, railway, cloudinary) and common commands; CLI-first over web dashboards
- `churn-hotspots.md` — mechanism, calibration, and threshold rationale for `churn-hotspots.sh`; exclusion list for by-design catalog files (#755)
- `cr-polling-commands.md` — full multi-line `gh api` commands for CR review polling and CI verification
- `cr-rate-limits.md` — full CR rate-limit caps, hourly-state mechanics, and `cr-review-hourly.sh` flags
- `codeowner-bot-approvals.md` — CODEOWNERS handling for review bots and stale-approval re-trigger commands
- `capability-discovery-examples.md` — false-walls vs real-walls catalog for try-every-path-before-handoff (`safety.md` Capability Discovery)
- `browser-capability-rung.md` — rung 4 (browser) detail: in-app vs Chrome surface selection, the single login/authorization ask, bounded attempt, untrusted-page posture, subagent reachability matrix, and the `phase-c-merger` stay-restricted decision (#852)
- `diff-survival-guard.md` — mechanism and rationale for `diff-survival-check.sh`; the failure mode where clean conflict markers hide a silently dropped fix (#757)
- `merge-gate-reviewer-paths.md` — per-reviewer merge-gate path details (CR/CodeAnt, BugBot, Greptile)
- `merge-gate-stale-approval-redemption.md` — CodeAnt in-place review edit: how `merge-gate.sh` redeems a stale approval by evidence rather than by reviewer identity (#876)
- `merge-sequencing.md` — mechanism and state machine for `merge-sequence.sh`; overlap-aware merge sequencing for PRs touching the same file (#756)
- `codeant-graphite-supplemental.md` — CodeAnt and Graphite supplemental polling on the CR path
- `local-review-cli-failure-modes.md` — how CodeAnt/CodeRabbit fake a clean pass on failure, 403 triage, 15-file cap, and binary-absent detection (#642, #819)
- `repo-bootstrap-protection.md` — branch-protection remediation mechanism: CI check-name discovery, the confirmation prompt, and the read-then-PUT payload that never downgrades existing protection (`repo-bootstrap.md`; #918)
- `dirty-main-guard.md` — how `--check` computes "dirty", what `--quarantine` preserves, and the recovery-branch listing/inspection/deletion commands (`main-hygiene.md`; #918)
- `review-substance-evidence.md` — why a bot APPROVED requires a substantive review footprint; hollow APPROVED failure mode and evidence checks in `merge-gate.sh` (#875)
- `wrap-fixpr-delegation.md` — `/wrap` Step 2.1 → full `/fixpr` recovery handoff contract
- `state-file-contracts.md` — expanded scoping, write-lock, migration, and field-type mechanics for `session-state.json` + handoffs (`handoff-files.md`; #625, #638, #639, #651, #655, #682, #687, #704, #757, #794, #967, #971)
- `session-state-schema-hotspot-decision.md` — KEEP + targeted-dedup adjudication for the `session-state-schema.json` churn hotspot; canonical ownership, preserved compatibility, and field-change checklist (#964)
- `session-state-collector.md` — the single definition of what a handoff *reads*, shared by `/pm-handoff` (Claude-native rendering) and `/pause` (portable rendering); one collector, two renderers (#901)
- `portable-handoff.md` — the `/pause` artifact: naming, atomic single-writer write, why it is a sibling to the PR-scoped JSON handoffs rather than one of them, and how `portable-handoff-lint.sh` enforces portability (#901)
- `authorship-guard.md` — `pr-authorship.sh` exit-code semantics, the three shared-script fail-safes, and `--allow-nonauthor` override plumbing (`safety.md` §Authorship; #733)
- `issue-claim.md` — `issue-claim.sh` mechanism: the three GitHub claim artifacts, why the holder token is finer-grained than the login, block-at-holder / release-at-account, staleness, the `--allow-claimed` override, and every call site (`issue-planning.md` step 0; #873)
- `autofile-dedup.md` — duplicate-check thresholds for autonomous issue filing (`/wrap` Phase 3, `/harness-audit` Step 7); strong/weak/none classification, exact-artifact dedup, and the comment-vs-file rule
- `harness-audit.md` — `/harness-audit` design record: two-pass split, the step-up chip that preserves the top-tier spawn invariant, the model-fleet resolver, dual watermarks, and the out-of-repo report default (#770)
- `graphql-thread-resolution.md` — full GraphQL queries/mutations for resolving PR review threads
- `exit-report-format.md` — full structured exit report block specification
- `greptile-setup.md` — Greptile dashboard setup notes
- `greptile-reply-format.md` — reply conventions for Greptile threads

### Workflow decomposition and PM helpers

- `chip-launching.md` — canonical mechanics for one-click coding-thread task chips; model-guard placement and guard preamble shared by all six canonical emitters (#731, #601)
- `cross-session-durability.md` — why `CronCreate` is not cross-session durable and why the durable `mcp__scheduled-tasks__*` primitive is not used here (#827)
- `phase-decomposition.md` — phase split reference material
- `pm-data-patterns.md` — PM skills data patterns and bot filters
- `pm-monitoring-decision.md` — `/pm` vs `/pr-monitor-and-manage` division of responsibility
- `pm-output-templates.md` — presentation format templates for `/pm` Step 1B.5; extracted from `pm/SKILL.md` to reduce churn surface on formatting-only blocks
- `continuous-work-posture.md` — why free capacity (not a finish) triggers refill, fill-vs-ramp, queue vs backlog refill, the human-in-chat stop, and the idle-reason taxonomy (`CLAUDE.md` "KEEP THE PIPELINE FULL"; #823)
- `pm-handoff-chips-decision.md` — decision record: `/pm-handoff` intentionally does not offer task chips; its portable prompt text is the deliverable (#562)
- `chip-model-guard-decision.md` — decision record: the chip model-guard preamble rides in both the chip `prompt` and the fallback block, redefining the fallback baseline (#601)
- `scheduling-failure-modes.md` — recurring poll failure analysis
- `bgwork-ceiling.md` — why background work arms a turn-independent silence ceiling, why `Monitor` over `ScheduleWakeup`/`CronCreate`, and why the number stays unpublished (#803)
- `skill-sync-hooks.md` — skills worktree sync and hook registration narrative
- `skill-symlink-setup.md` — why a dedicated worktree, session-start bootstrap, symlink install, and migration commands (`skill-symlinks.md`)
- `skill-usage-durability.md` — how skill-usage telemetry records survive machine moves, OS reinstalls, and `~/.claude` cleanups (#572)
- `skill-first-subagent-delivery.md` — the two delivery paths that carry the skill-first reflex into subagents, the `Skill`-tool precondition matrix, and the borderline-rung adaptation for autonomous agents (`skill-first.md`; #918)
- `trust-dialog-repair.md` — why `~/.claude.json` re-prompts per worktree, the three flags, and repair-script behavior (`trust-dialog-fix.md`)
- `double-loading-fix.md` — decision record for suppressing the duplicate global CLAUDE.md + rules copy via project-local `claudeMdExcludes` (#461)
- `budget-cap-raise-decision.md` — decision record: the `.budget-soft-cap` ratchet is a visibility mechanism raisable with a PR-body justification line; the 12,000/13,000 word limits are the actual gate (#879)
- `skill-authoring-patterns.md` — authoring *judgment* for skills/rules (description-as-trigger, match-form-to-failure, bulletproofing); complements CONTRIBUTING.md mechanics
- `subagent-phase-guardrails.md` — verbatim-block home for the SAFETY/MINDSET/SKILLS blocks and RULES placeholder shared by `/subagent` Phase A/B/C spawn-prompt templates (SAFETY/MINDSET edit source: `.claude/rules/safety.md`); CI-guarded by `verbatim-block-lint.sh` (#805)
- `verification-evidence-patterns.md` — claim→evidence checklist for AC, exit reports, and merge claims; complements phase protocols (#417 harvest from superpowers)

### Living trackers (updated each cycle — not point-in-time)

- `skill-repo-diff.md` — cross-repo pattern-harvest tracker (#417): gap analysis vs superpowers / everything-claude-code, prioritized import backlog, and import log; re-surveyed and appended each cycle

### Audits and research (point-in-time)

> **Exempt from corpus-wide rewrites (#791).** Every file in this section is a dated snapshot of what was true when it was written. Sweeping renames — the versionless model-name rename is the standing example — **must skip them**: rewriting a record to match today's vocabulary falsifies the history it exists to preserve. A versioned model name (`Opus 5`, `Haiku 4.5`) inside one of these files is correct by construction, not drift. The rename applies to the operative corpus — `CLAUDE.md`, `.claude/rules/`, `.claude/skills/`, `.claude/agents/` — plus the living contract docs in this directory that those files consume normatively (`chip-launching.md`, `chip-model-guard-decision.md`). Enforced by `.github/scripts/chip-model-guard-lint.sh`, whose scan is scoped to exactly that set.

- `ai-review-tool-audit-2026-04.md` — AI review tool chain audit (#368 / #377)
- `ai-review-tool-audit-2026-06.md` — 30-day AI review tool value audit + keep/cut verdicts (#376)
- `fixpr-hotspot-decision.md` — diagnosis and extract-not-split decision for `fixpr/SKILL.md` churn (17 PRs in the run-up to #788); verdict: KEEP single file + extract large command forms
- `pr-state-hotspot-decision.md` — diagnosis and extract-not-split decision for `pr-state.sh` churn (Issue #980); verdict: KEEP the public CLI + extract two pure jq programs
- `claude-md-hotspot-decision.md` — diagnosis and no-content-change decision for `CLAUDE.md` churn (17 merged PRs in the Issue #928 window); verdict: KEEP the single executive contract after recent compression and policy updates
- `escalate-review-hotspot-decision.md` — diagnosis and KEEP decision for `escalate-review.sh` churn (9 merged PRs, Issue #977); verdict: KEEP single file with no extraction; 7 of 9 PRs touched code unique to this script; overlapping BugBot classifier is structurally incompatible across callers (bundle vs separate bash vars, TSV vs MISSING[] output)
- `escalate-review-test-hotspot-decision.md` — diagnosis and split decision for `escalate-review.test.sh` churn (11 merged PRs in the #966 hotspot window, re-measured after #969); verdict: SPLIT into four concern suites plus one shared fixture helper
- `monitor-mode-hotspot-decision.md` — diagnosis and dedup decision for `monitor-mode.md` churn (9 merged PRs in the #984 hotspot window); verdict: KEEP single rule file + point PM recovery prose to its canonical owners
- `phase-a-fixer-hotspot-decision.md` — diagnosis and no-runtime-change decision for `phase-a-fixer.md` churn (9 merged PRs in the Issue #975 window); verdict: KEEP the self-contained Phase A agent contract
- `phase-b-reviewer-hotspot-decision.md` — diagnosis and no-runtime-change decision for `phase-b-reviewer.md` churn (14 merged PRs in the Issue #942 window); verdict: KEEP the self-contained Phase B state machine
- `phase-c-merger-hotspot-decision.md` — evidence-based diagnosis of `phase-c-merger.md` churn (9 merged PRs in the Issue #976 window); verdict: KEEP single file + dedup non-decision detail toward canonical owners
- `start-issue-hotspot-decision.md` — diagnosis of `start-issue/SKILL.md` churn (9 merged PRs in the Issue #981 window); verdict: KEEP the seven-step skill + no operative change
- `merge-gate-hotspot-decision.md` — diagnosis and extract-not-split decision for `merge-gate.sh` churn (16 PRs in the Issue #936 window); verdict: KEEP single file + extract CR/CodeAnt approval state machine into `_fetch_bot_approvals` local function
- `cr-merge-gate-rule-hotspot-decision.md` — diagnosis and keep + targeted-dedup decision for `cr-merge-gate.md` rule churn (15 PRs in the Issue #940 window); verdict: KEEP single canonical policy file + compress two downstream restatements + clarify policy-vs-runtime authority split
- `merge-gate-reviewer-paths-hotspot-decision.md` — diagnosis and keep + targeted-dedup decision for `merge-gate-reviewer-paths.md` churn (8 PRs in the Issue #1002 window); verdict: KEEP as designated expansion home for gate prose + add canonical-source markers to shared-mechanism sections
- `scheduling-reliability-hotspot-decision.md` — diagnosis and dedup decision for `scheduling-reliability.md` churn (12 merged PRs in the #959 hotspot window, re-measured after #982); verdict: KEEP single rule file + remove downstream formula/enforcement restatements
- `local-review-cli-failure-modes-hotspot-decision.md` — diagnosis and no-runtime-change decision for `local-review-cli-failure-modes.md` churn (6 merged PRs in the Issue #1005 window); verdict: KEEP the single multi-incident diagnostic reference
- `scheduling-failure-modes-hotspot-decision.md` — diagnosis and no-runtime-change decision for `scheduling-failure-modes.md` churn (7 PRs in the Issue #1007 window, including PR #1009 merged same day); verdict: KEEP as intentional append-only incident log; Pattern 5 dedup already applied by PR #987
- `polling-state-gate-test-hotspot-decision.md` — diagnosis and KEEP + extract decision for `polling-state-gate.test.sh` churn (7 merged PRs); verdict: coordinated shared-contract churn on the repo-scoping seam; shared helpers extracted into `tests/lib/polling-state-gate-fixtures.sh` and scoped-path coverage gap closed — both completed by PR #1024
- `polling-state-gate-multirepo-test-hotspot-decision.md` — diagnosis and KEEP decision for `polling-state-gate-multirepo.test.sh` churn (3 merged PRs, Issue #1025); verdict: coordinated shared-contract churn on the repo-scoping seam; mechanical duplication already resolved by PR #1024 (fixture extraction + scoped-path coverage gap closed); KEEP in place
- `global-settings-hotspot-decision.md` — diagnosis and KEEP + dedup decision for `global-settings.json` churn (6 merged PRs in the Issue #1019 window); verdict: KEEP single file + retire duplicated HOOKS_MANIFEST in setup-skills-worktree.sh; register-hooks.py is the single implementation for both install-time and session-start hook registration
- `merge-gate-review-substance-test-hotspot-decision.md` — diagnosis and KEEP decision for `merge-gate-review-substance.test.sh` churn (6 merged PRs, Issue #1014); verdict: purposeful regression accumulation tracking `review-substance.sh` contract evolution; no companion file, no coverage gap, no mechanical duplication — keep as-is
- `review-substance-evidence-hotspot-decision.md` — diagnosis and KEEP decision for `review-substance-evidence.md` churn (5 merged PRs, Issue #1029); verdict: purposeful evidence accumulation — each PR appended a trace and design-reasoning section for a new hollow-approval bypass fix; splitting would destroy the cumulative argument; consistent with companion test-file adjudication (Issue #1014)
- `agents-readme-hotspot-decision.md` — diagnosis and KEEP decision for `.claude/agents/README.md` churn (10 merged PRs, Issue #973); verdict: coordinated policy propagation into the agent-system documentation hub; PR #1016 already resolved the inheritance-model structural concern; model naming section is load-bearing for lint tooling; no operative content change
- `state-file-contracts-hotspot-decision.md` — diagnosis and KEEP + targeted-dedup decision for `state-file-contracts.md` churn (6 merged PRs, Issue #1012); verdict: KEEP as companion mechanism doc; file creation + two new-mechanism sections + two scope-resolution propagations + one prior dedup (#989); no merge conflicts; dedup applied to repo-scoping and write-locks sections toward script headers (#638, #639/#682)
- `pmm-lifecycle-hotspot-decision.md` — diagnosis and KEEP + dedup decision for `pmm-lifecycle.md` churn (6 merged PRs, Issue #1017); verdict: KEEP the PMM state-machine reference; churn driven by legitimate scheduling-substrate evolution; canonical-source marker added to `SKILL.md` pause-marker write block; mirror note added in `pmm-lifecycle.md`
- `token-efficiency-audit-hotspot-decision.md` — diagnosis and no-runtime-change decision for `token-efficiency-audit-2026-07.md` churn (5 merged PRs, Issue #1021); verdict: KEEP as intentional append-per-FU-resolution audit record; all 5 PRs were non-conflicting initial authoring, inline FU closure notes, or appended FU evaluation sections
- `pm-worker-hotspot-decision.md` — diagnosis and KEEP + safety-block fix decision for `pm-worker.md` churn (5 merged PRs, Issue #1023); verdict: KEEP + add capability-ladder MINDSET bullet (#1023)
- `subagent-phase-guardrails-hotspot-decision.md` — diagnosis and no-operative-change decision for `subagent-phase-guardrails.md` churn (5 merged PRs, Issue #1033); verdict: KEEP as verbatim-copy home (SAFETY/MINDSET edit source: `.claude/rules/safety.md`); all churn is required propagation from canonical rule files, byte-guarded by `verbatim-block-lint.sh`
- `bugbot-rule-hotspot-decision.md` — diagnosis and no-operative-change decision for `bugbot.md` churn (5 merged PRs, Issue #1036); verdict: KEEP single canonical BugBot rule file; churn is mixed-cause (two corpus-compression sweeps, two by-design policy adds, one already-completed dedup); only identified duplication removed by PR #1013
- `chip-model-guard-doc-hotspot-decision.md` — diagnosis and no-operative-change decision for `chip-model-guard-decision.md` churn (6 merged PRs, Issue #1011); verdict: KEEP as living decision record for the chip model-guard contract; churn is by-design amendment-record growth tracking guard evolution across PRs #736, #775, #799, #842, #857, #1008
- `chip-launching-hotspot-decision.md` — diagnosis and KEEP decision for `chip-launching.md` churn (14 merged PRs, Issue #916); verdict: KEEP as canonical chip-semantics contract; churn is burst-construction of new protocol sections, not independent iteration; section-name references from consumer skills and lint anchors block safe extraction
- `handoff-files-rule-hotspot-decision.md` — diagnosis and no-operative-change decision for `handoff-files.md` rule churn (11 merged PRs, Issue #943); verdict: KEEP the single auto-loaded binding rule; churn is by-design state-machinery evolution (8 PRs) and corpus compression (3 PRs); brief exit-code quick-reference facts stay in the auto-loaded corpus; state-file-contracts.md pointer already exists
- `prompt-hotspot-decision.md` — diagnosis and KEEP decision for `prompt/SKILL.md` churn (12 merged PRs, Issue #949); verdict: KEEP as canonical chip-emitter skill; 7 of 12 PRs are shared chip-contract propagation with chip-launching.md; lint anchors block safe extraction of output templates; no independent-churn pattern in classification or edge-case sections
- `session-state-script-hotspot-decision.md` — diagnosis and KEEP decision for `session-state.sh` churn (11 merged PRs, Issue #952); verdict: KEEP single-script implementation; churn is completed foundational build-out (repo scoping, locking, field-type validation); independently-evolving concerns already extracted (state-lock.sh, lib/repo-normalizer.sh); remaining inline concerns have exactly one caller (#952)
- `cr-github-review-rule-hotspot-decision.md` — diagnosis and no-operative-change decision for `cr-github-review.md` rule churn (11 merged PRs, Issue #953); verdict: KEEP single canonical polling-loop rule; churn is corpus-compression sweeps (4 PRs) + by-design review-chain policy evolution (3 PRs) + polling mechanism additions (2 PRs) + incidental (2 PRs); no avoidable duplication; file already uses pointer-not-prose pattern with six reference delegates
- `safety-rule-hotspot-decision.md` — diagnosis and no-operative-change decision for `safety.md` rule churn (11 merged PRs, Issue #957); verdict: KEEP as canonical safety contract and SAFETY/MINDSET verbatim-block source; dominant churn driver is capability-ladder evolution (4 PRs) byte-guarded by `verbatim-block-lint.sh`; extraction not warranted (no lint-ungoverned duplication, 290-word corpus headroom)
- `wave-hotspot-decision.md` — diagnosis and KEEP decision for `wave/SKILL.md` churn (10 merged PRs, Issue #961); verdict: KEEP as canonical wave-selection skill; Steps 3–5 (CR's proposed extraction target) untouched by all 10 hotspot PRs; actual churn is chip-contract propagation (6 PRs shared with chip-launching.md) + Step 2 feature additions (3 PRs); lint anchors block Step 7 extraction; same pattern as prompt/SKILL.md (#949) and start-issue/SKILL.md (#981) KEEP decisions
- `babysit-pr-hotspot-decision.md` — diagnosis and KEEP decision for `babysit-pr/SKILL.md` churn (9 merged PRs, Issue #986); verdict: KEEP unchanged — 18+ CI require_text guards in scheduling-primitive-alignment.test.sh pin critical Monitor identity invariants directly in SKILL.md; churn driven by scheduling substrate evolution (CronCreate → /loop → Monitor) and feature additions; extraction proposed by CR plan blocked by CI constraints
- `root-readme-hotspot-decision.md` — diagnosis and dedup decision for `README.md` churn (9 merged PRs in the Issue #988 hotspot window); verdict: KEEP single file + point Rule Files / Hook Scripts / Scripts Library catalog content to canonical owners; Slash Commands table (enforced by `skill-catalog-lint.sh`) unchanged
- `pm-monitoring-decision-hotspot-decision.md` — diagnosis and KEEP decision for `pm-monitoring-decision.md` churn (7 merged PRs, Issue #990); verdict: KEEP single-topic hub; churn is scheduling-substrate corrections (CronCreate durability, Monitor migration, repo-scoping precision) + one confirmed dedup already applied by PR #985; no new duplication found
- `cr-local-review-hotspot-decision.md` — diagnosis and no-operative-change decision for `cr-local-review.md` rule churn (7 merged PRs in the Issue #992 hotspot window); verdict: KEEP single cohesive local-review-loop policy file; all churn is legitimate (false-clean policy tightening, corpus compression, new coverage-visibility mandate, CLI abstraction refactor); no concrete duplication confirmed
- `admin-merge-hotspot-decision.md` — KEEP adjudication for the `admin-merge.sh` churn hotspot; per-section attribution for 7 PRs, dedup search result (no restatements found), and verdict rationale (#994)
- `review-substance-hotspot-decision.md` — diagnosis and KEEP decision for `review-substance.sh` churn (7 merged PRs, Issue #996); verdict: coordinated bug-fix additions to hollow-approval signal logic (#875, #885, #894, #897, #917, #933, #927); jq program cannot be modularized (no module convention), file is a verbatim-consumed junction contract for `merge-gate.sh` and `escalate-review.sh`, `canon_ts` divergence is CI-pinned by `ts-normalizer-parity.test.sh`; KEEP byte-identical
- `hooks-readme-hotspot-decision.md` — diagnosis and KEEP + targeted-dedup decision for `.claude/hooks/README.md` churn (6 merged PRs since 2026-07-28, Issue #998); verdict: additive one-section-per-new-hook growth, no merge conflicts; vestigial per-hook JSON setup blocks replaced with pointers to the `## Hook Auto-Registration` banner
- `chip-model-guard-lint-hotspot-decision.md` — diagnosis and extract-not-split decision for `chip-model-guard-lint.sh` churn (5 merged PRs); verdict: KEEP single file + extract shared lint boilerplate into `.github/scripts/lib/`
- `harness-audit-hotspot-decision.md` — diagnosis and no-operative-change decision for `harness-audit.md` churn (4 merged PRs, Issue #1049); verdict: KEEP as single-skill design record for `/harness-audit`; churn is 1 foundational creation (PR #775, Issue #770) + 1 doc-only correction (PR #825, Issue #808) + 2 coordinated scheduler-redesign propagations (PRs #867/#982, Issues #827/#924); conflict_rounds == 0
- `repo-audit-2026-05.md` — bundled org + efficiency + best-practices audit (#413–#415)
- `harness-model-audit-2026-06.md` — harness components vs current model fleet (#49)
- `script-extraction-audit.md` — deterministic script extraction inventory (#271)
- `graphite-stacked-prs-research-2026-05.md` — stacked PR economics (#418 / #433)
- `codeant-code-quality-eval-2026-06.md` — deeper CodeAnt Code Quality integration eval; verdict: keep advisory (#444)
- `instruction-set-audit-2026-07.md` — 1-month instruction-set size & optimization re-check; verdict: keep caps (#462)
- `session-state-convergence-audit.md` — post-merge convergence audit of `session-state.json` and all scripts that touch it as one system; verdict: coherent (#651)
- `token-efficiency-audit-2026-07.md` — token-efficiency playbook: adopt/skip/adapt verdicts, ranked cuts, shipped v1 (one-line heartbeats, delta PMM table, silence-detector dedupe) + FU-1…FU-7 (#773)
- `compact-result-contract.md` — the `ok`/`failed_tests`/`relevant_error`/`log_path` output shape, its adopters, why failures are never compacted away, and what is deliberately left unwrapped (FU-7; #782)
- `pm-routing-audit-2026-07.md` — thread-vs-inline routing effectiveness audit of #613; ground-truth attribution + the shared PM-context inline gate for chip surfaces (#701)
- `too-big-recalibration-2026-07.md` — re-derivation of the "too big for a subagent" fit bar against current capability: criterion 1 narrowed from size to non-resumability, A/B/C confirmed on grounds independent of the unverified 32K figure, ceiling held, and the chip-gate overflow defect fixed (#776)
- `skill-prune-audit-2026-07.md` — skill-usage telemetry audit; keep/prune verdicts based on 62-day usage data (#431)
- `subagent-orchestration-churn-audit-2026-07.md` — churn hotspot analysis for `subagent-orchestration.md` (13 PRs in 14 days); verdict: KEEP single file + dedup Phase A/B/C bullet descriptions toward canonical owners; ownership decisions recorded (#814)
- `usage-limit-signal-audit-2026-07.md` — audit finding: no trustworthy approaching-limit signal exists for hooks/skills/sessions; the status-line signal has no path into model context (#824)
- `hook-events-evaluation-2026-08.md` — evaluation of newer Claude Code hook events (WorktreeCreate/Remove, CwdChanged, SubagentStart/Stop, PreCompact/PostCompact, InstructionsLoaded) against indirect-detection mechanisms; PostCompact adopted, rest deferred with rationale (#813)

### Diagrams (mermaid stubs and indexes)

- `diagrams/README.md` — index of diagram stub files
- `diagrams/skills-worktree-symlinks.md` — topology (stub)
- `diagrams/review-merge-pipeline.md` — review chain (stub)
- `diagrams/hook-lifecycle.md` — hook sequence (stub)

### Verification logs

- `issue-162-phase-protocol-verification.md` — static verification log for exit reports, phase B/C protocols, and monitor loop ordering (issue #162)
