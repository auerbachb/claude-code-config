# Incremental Skill Loading Contract

**Status:** pilot contract for `/issue-maker` — Issue [#1872](https://github.com/auerbachb/claude-code-config/issues/1872), 2026-10-30.

## Contract

A skill entry is a small router, not a table of contents that imports every procedure. The entry classifies the requested operation and phase before reading a procedure. It then loads one selected module and follows that module's explicit prerequisite and trigger rules. Nested references stay unread until a selected procedure names the point where they are required. Split files and `@` imports alone do not prove lazy loading; in this pilot the entry has no imports and asks for an explicit file read of the resolver's single returned path.

Always-on safety, authority, and mandatory gates remain in universal repository instructions and the skill's small contract. A dispatcher cannot bypass them. A missing module or required gate is a recoverable blocker: persist operation, module/phase, issue/repository, current evidence, and next step; report the missing dependency; do not silently fall back to another procedure.

On compaction or restart, reload the entry and the minimal session-state procedure, revalidate pending gates against persisted evidence, then read only the active phase module. Reuse a module already read in the same valid context. Do not repeat completed writes, duplicate checks, or approvals when their evidence is persisted and still current.

## Pilot evidence and measurement method

Source measured on 2026-10-30: bytes and whitespace-delimited words, **not runtime tokens**. The former committed entry is 98112 bytes / 15208 words. Claude Code 2.1.312 is installed; no private harness-loader trace is available, so actual runtime reads, token/cache effects, and model adherence remain unknown.

The executable trace fixtures record caller-selected module paths, nested reference reads, bounded export excerpts, repeated-read reuse, and recovery from a persisted operation/phase. They validate this loading contract, not hidden harness behavior. Normal inline offers do not read chip-launching or the on-request payload module. The sizing rationale and ask-menu references remain conditional (rationale requests and blocking questions respectively); their bytes are additional when triggered. No fixture claims to execute LLM reflection. Offline behavior checks execute the production Markdown blocks against temporary logs/stubbed gh and verify repository/origin isolation, update metadata, uncertain close results, retained cleanup tokens, and survivor chain coordinates. Existing issue-file and log-scoping suites exercise real helper paths and canonical body/ownership outcomes.

| Representative context / phase trace | Bytes | Words |
|---|---:|---:|
| Initial capture setup | 24,701 | 3,521 |
| Normal create (modules only) | 81,572 | 12,218 |
| Normal create including nested references | 154,086 | 23,384 |
| Chain/batch including nested references | 163,263 | 24,871 |
| Update / recovery at update phase | 33,013 | 4,737 |
| Ordinary retract | 35,662 | 5,165 |
| On-request handoff after normal create | 217,826 | 32,976 |
| Comparable old create plus same nested references | 170,626 | 26,374 |
| Export (entry, export module, bounded body/handoff excerpts, chip reference) | 75,082 | 11,266 |

Create phase order: entry → session → reflection/tier/estimate → dedup/resolution reference/duplicate policy → optional chain/link modules → file → postfile; the chip module/reference is reached only on explicit handoff request. Chain sizing reads the estimate before its independent time threshold decision. Update trace: entry → session → update. After compaction at update: entry → session → active update phase only; completed create phases stay unread. The create dependency preflight checks required paths without reading their contents, and missing modules block remote writes.

Setup is the initial capture row above. A restart adds that setup plus the active phase again (the update row quantifies a complete update recovery); nested references are re-read only if the active phase needs them and they are no longer in context. Repeated reads in an unchanged valid context add zero source bytes. A missing-module retry adds entry/session setup and the selected phase after repair; no prior remote write is replayed. Actual retry frequency and execution-tool overhead remain unknown. The monolithic baseline already carried all phases on first invocation; comparisons include the same reached references on both sides. Export counts only its bounded template excerpts, not entire create workflows.

### Current module source inventory

| Path | Bytes | Words |
|---|---:|---:|
| `SKILL.md` | 7,931 | 1,113 |
| `modules/batch.md` | 1,893 | 315 |
| `modules/create/crossrefs.md` | 2,417 | 401 |
| `modules/create/dedup.md` | 5,900 | 859 |
| `modules/create/file.md` | 6,788 | 940 |
| `modules/create/increment-draft.md` | 4,867 | 771 |
| `modules/create/postfile.md` | 24,130 | 3,792 |
| `modules/create/reflect-and-draft.md` | 20,053 | 3,106 |
| `modules/handoff.md` | 7,853 | 1,178 |
| `modules/portable-prompt.md` | 7,781 | 1,196 |
| `modules/retract.md` | 10,961 | 1,644 |
| `modules/session-mode.md` | 1,279 | 188 |
| `modules/session-state.md` | 16,770 | 2,408 |
| `modules/update.md` | 8,312 | 1,216 |

Reproduce the exact inventory with `wc -wc .claude/skills/issue-maker/SKILL.md .claude/skills/issue-maker/modules/*.md .claude/skills/issue-maker/modules/create/*.md`; run `bash tests/test-issue-maker-dispatch.sh` for the caller trace and offline workflow checks. Sum each trace's distinct source paths and bounded excerpts, including the references listed above. No migration percentage is promised before runtime instrumentation.

## Pilot scope and remaining roadmap

The startup/rule and schema baselines remain coordinated with Issues [#1158](https://github.com/auerbachb/claude-code-config/issues/1158) and [#1160](https://github.com/auerbachb/claude-code-config/issues/1160); this slice measures selected skill sources and does not duplicate their startup/schema work.

| Skill | Entry guidance | Phase/branch inventory | Existing deterministic entry points | References loaded at their phase |
|---|---|---|---|---|
| `/issue-maker` | Capture boundary, classifier, resume contract | Session, reflect, dedup, file, postfile, chain, update, retract, export, requested handoff | `dispatch-module.sh`, `resolve-log.sh`, `set-log.sh`, `issue-file.sh`, `issue-dedup.sh` | Tier/estimate for drafting; duplicate policy for dedup; chip contract only for explicit handoff/export |
| `/pm` | Intent, authority, ranking/execution selection | Backlog scan, ranking, routing, active-work observation, reporting | `active-work-cap.sh`, `issue-claim.sh`, existing backlog helpers | Output templates when reporting; review/cap policy when routing work |
| `/subagent` | Fit test, claims, orchestration boundaries | Planning, task prompt, execution, review, merge/handoff | `issue-claim.sh`, `issue-deps.sh`, existing review helpers | Phase guardrails at dispatch; reviewer contracts at review |
| `/wrap` | PR target, authorship, merge authority | Discovery, gate verification, recovery, merge/sync, follow-ups, lessons | `merge-gate.sh`, `ci-status.sh`, `ac-checkboxes.sh`, `main-sync.sh` | Report templates when requested; duplicate policy for follow-up filing |
| `/pr-monitor-and-manage` | Fleet selection, authority, stop criteria | Discovery, polling, triage, repair, completion | `pr-state.sh`, `polling-state-gate.sh`, `merge-gate.sh` | Polling commands during observation; reviewer/escalation policy when actionable |

This is a migration inventory for the four remaining skills, not a claim that they are already split. Their proposed module prerequisites are established in the ordered slices below, and safety/required gates stay available regardless of source layout.

This issue establishes the contract and pilots it on `/issue-maker`; it does not rewrite the other giant skills. Migrate the rest as separately reviewable slices in this order:

1. **`/pm`** — keep the dispatch/ranking entry and universal gates short; separate backlog scan, candidate scoring, execution routing, and reporting by phase. Preserve issue ownership, active-work caps, unchanged-tick evidence rules, and persisted candidate state. Confirm no unrelated monitoring branch is read during a ranking-only request.
2. **`/subagent`** — keep safety, authority, and orchestration entry conditions available; load planning, prompt construction, execution, review, and handoff modules only at their phase. Preserve task-packet compactness, claim and dependency gates, and model/effort selection. Confirm a prompt-only request does not read execution or merge modules.
3. **`/wrap`** — separate PR discovery, gate review, repair, and merge readiness. Preserve authorship checks, required reviewers/CI, merge authority, and no-op behavior. Confirm status-only or blocked-gate paths do not read repair/merge procedures.
4. **`/pr-monitor-and-manage`** — separate discovery, active polling, triage, repair, and completion. Preserve no-unchanged-tick inference, telemetry boundaries, and monitoring stop conditions. Confirm a single observation tick reads only its monitor phase and required state.

For each slice, inventory content as (a) entry guidance, (b) branch/phase modules, (c) deterministic scripts, and (d) optional references. State each module's trigger and prerequisites in its header; prove with a trace fixture that a description/index does not read siblings or nested references. Add before/after source measurements and runtime evidence where available. Compare behavioral outputs, ownership, safety and merge gates, compaction recovery, missing-module handling, and retry overhead with the pre-split workflow before claiming parity.

## Behavior-preservation map

| Original procedure | Incremental module(s) | Parity check |
|---|---|---|
| Steps 1–2: session initialization, recovery, capture refusal | `modules/session-state.md` | Private log, recovered repository, mode, pending offer, and compact checkpoint are restored before operation work |
| Steps 3 and 5: reflect, draft, estimate, canonical body | `modules/create/reflect-and-draft.md` | Seven sections, title, estimate, footer, tone, and capture invariants remain |
| Step 4: duplicate screening | `modules/create/dedup.md` | Uses proposed title/problem statement and retains default/rapid-fire thresholds |
| Step 5 chain variant | `modules/create/increment-draft.md` | Loaded only after sizing selects a chain; boundaries, estimates, and title cap remain |
| Steps 6–8: batch ordering, labels, cross-references | `modules/batch.md`, `modules/create/file.md`, `modules/create/crossrefs.md` | Sequential create order, validated labels, issue links, and chain links remain |
| Steps 9a–9c: log, report/table, tier and offer | `modules/create/postfile.md`, `modules/handoff.md` | Single/batch summary, one offer, repo-wide cap, offer stamp, and explicit acceptance remain |
| Steps 10–11: structured and natural edits | `modules/update.md` | Confirm before write; verify uncertain remote results before logging success |
| Step 12: retract | `modules/retract.md` | Only ask about open chain successors; verify remote close before changing local state |
| Step 13 and modes summary | `modules/portable-prompt.md` plus bounded template sources | Export-only branch; summary format, sizing, mode rules, and handoff fallback remain |

The former tail section with usage examples and post-merge symlink setup is operator guidance rather than a runtime branch. After merge, follow `.claude/rules/skill-symlinks.md` for installation.

## Behavioral parity and recovery checklist

- Create, batch, update, retract, and export retain their existing user-visible outcomes and file/write authority.
- A create-only case does not read batch, update, retract, export, or unused references.
- Ordinary update and retract avoid unrelated procedures; chain re-cut loads update, and offer refresh loads the shared postfile procedure only when required.
- Batch/chain instructions load only after the request or sizing result requires them; chain handling and handoff are deferred until the applicable phase.
- Recovery includes operation, module/phase, issue/repo, evidence, and next step; it rechecks required gates without replaying completed phases.
- Missing module and required-gate failures stop safely with a useful next action.
- Setup/retry reads are included in measurements; source-level reductions are not reported as runtime token savings.
