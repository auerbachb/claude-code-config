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
- `state-file-contracts.md` — expanded scoping, write-lock, migration, and field-type mechanics for `session-state.json` + handoffs (`handoff-files.md`; #625, #638, #639, #651, #655, #682, #687, #704)
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
- `subagent-phase-guardrails.md` — canonical single home for the SAFETY/MINDSET/SKILLS verbatim blocks and RULES placeholder shared by `/subagent` Phase A/B/C spawn-prompt templates; CI-guarded by `verbatim-block-lint.sh` (#805)
- `verification-evidence-patterns.md` — claim→evidence checklist for AC, exit reports, and merge claims; complements phase protocols (#417 harvest from superpowers)

### Living trackers (updated each cycle — not point-in-time)

- `skill-repo-diff.md` — cross-repo pattern-harvest tracker (#417): gap analysis vs superpowers / everything-claude-code, prioritized import backlog, and import log; re-surveyed and appended each cycle

### Audits and research (point-in-time)

> **Exempt from corpus-wide rewrites (#791).** Every file in this section is a dated snapshot of what was true when it was written. Sweeping renames — the versionless model-name rename is the standing example — **must skip them**: rewriting a record to match today's vocabulary falsifies the history it exists to preserve. A versioned model name (`Opus 5`, `Haiku 4.5`) inside one of these files is correct by construction, not drift. The rename applies to the operative corpus — `CLAUDE.md`, `.claude/rules/`, `.claude/skills/`, `.claude/agents/` — plus the living contract docs in this directory that those files consume normatively (`chip-launching.md`, `chip-model-guard-decision.md`). Enforced by `.github/scripts/chip-model-guard-lint.sh`, whose scan is scoped to exactly that set.

- `ai-review-tool-audit-2026-04.md` — AI review tool chain audit (#368 / #377)
- `ai-review-tool-audit-2026-06.md` — 30-day AI review tool value audit + keep/cut verdicts (#376)
- `fixpr-hotspot-decision.md` — diagnosis and extract-not-split decision for `fixpr/SKILL.md` churn (17 PRs in the run-up to #788); verdict: KEEP single file + extract large command forms
- `claude-md-hotspot-decision.md` — diagnosis and no-content-change decision for `CLAUDE.md` churn (17 merged PRs in the Issue #928 window); verdict: KEEP the single executive contract after recent compression and policy updates
- `escalate-review-test-hotspot-decision.md` — diagnosis and split decision for `escalate-review.test.sh` churn (11 merged PRs in the #966 hotspot window, re-measured after #969); verdict: SPLIT into four concern suites plus one shared fixture helper
- `monitor-mode-hotspot-decision.md` — diagnosis and dedup decision for `monitor-mode.md` churn (9 merged PRs in the #984 hotspot window); verdict: KEEP single rule file + point PM recovery prose to its canonical owners
- `phase-b-reviewer-hotspot-decision.md` — diagnosis and no-runtime-change decision for `phase-b-reviewer.md` churn (14 merged PRs in the Issue #942 window); verdict: KEEP the self-contained Phase B state machine
- `scheduling-reliability-hotspot-decision.md` — diagnosis and dedup decision for `scheduling-reliability.md` churn (12 merged PRs in the #959 hotspot window, re-measured after #982); verdict: KEEP single rule file + remove downstream formula/enforcement restatements
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

### Diagrams (mermaid stubs and indexes)

- `diagrams/README.md` — index of diagram stub files
- `diagrams/skills-worktree-symlinks.md` — topology (stub)
- `diagrams/review-merge-pipeline.md` — review chain (stub)
- `diagrams/hook-lifecycle.md` — hook sequence (stub)

### Verification logs

- `issue-162-phase-protocol-verification.md` — static verification log for exit reports, phase B/C protocols, and monitor loop ordering (issue #162)
