# Incremental Skill Loading Contract

**Status:** pilot contract for `/issue-maker` — Issue [#1872](https://github.com/auerbachb/claude-code-config/issues/1872), 2026-10-30.

## Contract

A skill entry is a small router, not a table of contents that imports every procedure. The entry classifies the requested operation and phase before reading a procedure. It then loads one selected module and follows that module's explicit prerequisite and trigger rules. Nested references stay unread until a selected procedure names the point where they are required. Split files and `@` imports alone do not prove lazy loading; in this pilot the entry has no imports and asks for an explicit file read of the resolver's single returned path.

Always-on safety, authority, and mandatory gates remain in universal repository instructions and the skill's small contract. A dispatcher cannot bypass them. A missing module or required gate is a recoverable blocker: persist operation, module/phase, issue/repository, current evidence, and next step; report the missing dependency; do not silently fall back to another procedure.

On compaction or restart, reload the entry and the minimal session-state procedure, revalidate pending gates against persisted evidence, then read only the active phase module. Reuse a module already read in the same valid context. Do not repeat completed writes, duplicate checks, or approvals when their evidence is persisted and still current.

## Pilot evidence and measurement method

Source measured on 2026-10-30: bytes and whitespace-delimited words, **not runtime tokens**. The former committed entry is 98112 bytes / 15208 words. Claude Code 2.1.312 is installed; no private harness-loader trace is available, so actual runtime reads, token/cache effects, and model adherence remain unknown.

The executable trace fixtures record caller-selected module paths, nested reference reads, bounded export excerpts, repeated-read reuse, and recovery from a persisted operation/phase. They validate this loading contract, not hidden harness behavior. Normal inline offers do not read chip-launching or the on-request payload module. The sizing rationale and ask-menu references remain conditional; their bytes are additional when triggered. No fixture claims to execute LLM reflection.

Offline behavior checks execute production Markdown blocks against temporary logs and stubbed gh. They verify repository/origin isolation, cross-process create/update receipts, target-checkout sizing, uncertain remote results, cleanup tokens, and survivor chain coordinates. The reservation/launch matrix uses the real repo-scoped registry and locked session writer with boundary fault injection. It covers concurrent fresh attempts, launch versus launch/cleanup, stale callers, in-flight reservations, committed writes with lost responses, failed release, and recovery. The locked writer compares full expected checkpoints before transitions; only confirmed unstarted work can release capacity. Unknown/confirmed tasks remain held for reconciliation. Explicit handoffs alone freeze rendered prompt bytes in a private file with a pointer/hash/issue-list replay receipt, retained after live-offer cleanup. Replay verifies and emits those bytes without reading mutable issues or the current template. Save/preflight failures stop before reservation/spawn; local byte verification cannot attest the actual provider's spawn arguments. Cleanup retains attempt/repository/registry/token identities until both stores are reconciled, then clears affected tokens and receipts in one local write. The writer resolves its existing `state-lock.sh` library from the same physical installation (including published skill symlinks); a missing library fails closed. Tests include bundled/installed helpers, symlinks, env -i, and direct system Bash 3.2. Existing issue-file and log-scoping suites exercise real checkout helper paths and canonical body/ownership outcomes.

| Representative context / phase trace | Bytes | Words |
|---|---:|---:|
| Initial capture setup | 29,380 | 4,151 |
| Normal create (modules only) | 94,475 | 13,850 |
| Normal create including nested references | 166,989 | 25,016 |
| Chain/batch including nested references | 176,400 | 26,524 |
| Update / recovery at update phase | 40,646 | 5,766 |
| Ordinary retract | 44,772 | 6,341 |
| On-request handoff after normal create | 246,962 | 36,689 |
| Comparable old create plus same nested references | 170,626 | 26,374 |
| Export (entry, export module, bounded body/handoff excerpts, chip reference) | 75,151 | 11,273 |

Create phase order: entry → session → reflection/tier/estimate → dedup/resolution reference/duplicate policy → optional chain/link modules → file → postfile; the chip module/reference is reached only on explicit handoff request. Chain sizing reads the estimate before its independent time threshold decision. Update trace: entry → session → update. After compaction at update: entry → session → active update phase only; completed create phases stay unread. The create dependency preflight checks required paths without reading their contents, and missing modules block remote writes.

Setup is the initial capture row above. A restart adds that setup plus the active phase again (the update row quantifies a complete update recovery); nested references are re-read only if the active phase needs them and they are no longer in context. Repeated reads in an unchanged valid context add zero source bytes. A missing-module retry adds entry/session setup and the selected phase after repair; no prior remote write is replayed. Actual retry frequency and execution-tool overhead remain unknown. The monolithic baseline already carried all phases on first invocation; comparisons include the same reached references on both sides. Export counts only its bounded template excerpts, not entire create workflows.

### Current module source inventory

| Path | Bytes | Words |
|---|---:|---:|
| `SKILL.md` | 8,000 | 1,120 |
| `modules/batch.md` | 1,893 | 315 |
| `modules/create/crossrefs.md` | 2,417 | 401 |
| `modules/create/dedup.md` | 5,945 | 862 |
| `modules/create/file.md` | 8,572 | 1,149 |
| `modules/create/increment-draft.md` | 5,101 | 792 |
| `modules/create/postfile.md` | 29,245 | 4,449 |
| `modules/create/reflect-and-draft.md` | 21,333 | 3,239 |
| `modules/handoff.md` | 24,086 | 3,259 |
| `modules/portable-prompt.md` | 7,781 | 1,196 |
| `modules/retract.md` | 15,392 | 2,190 |
| `modules/session-mode.md` | 1,279 | 188 |
| `modules/session-state.md` | 21,380 | 3,031 |
| `modules/update.md` | 11,266 | 1,615 |

Reproduce the exact inventory with `wc -wc .claude/skills/issue-maker/SKILL.md .claude/skills/issue-maker/modules/*.md .claude/skills/issue-maker/modules/create/*.md`; run `bash tests/test-issue-maker-dispatch.sh` for the caller trace and offline workflow checks. Sum each trace's distinct source paths and bounded excerpts, including the references listed above. No migration percentage is promised before runtime instrumentation.

## Pilot scope and remaining roadmap

The startup/rule and schema baselines remain coordinated with Issues [#1158](https://github.com/auerbachb/claude-code-config/issues/1158) and [#1160](https://github.com/auerbachb/claude-code-config/issues/1160); this slice measures selected skill sources and does not duplicate their startup/schema work.

| Skill | Entry guidance | Phase/branch inventory | Existing deterministic entry points | References loaded at their phase |
|---|---|---|---|---|
| `/issue-maker` | Capture boundary, classifier, resume contract | Session, reflect, dedup, file, postfile, chain, update, retract, export, requested handoff | `dispatch-module.sh`, `resolve-log.sh`, `set-log.sh`, `issue-file.sh`, `issue-dedup.sh` | Tier/estimate for drafting; duplicate policy for dedup; chip contract only for explicit handoff/export |
| `/pm` | Intent, authority, tooling, and execution boundary | Day preconditions, arming, tick, teardown, recovery, reactive park, and pre-emptive park/probe are dispatched separately. Resume and rank use selected load, fetch, score and presentation phases. Cleanup, forgotten PR triage, monitoring, dispatch, tracking, reporting, refill and handoff load as flow modules. | `scripts/dispatch-module.sh`, `active-work-cap.sh`, `issue-claim.sh` | Output templates when reporting, review/cap policy when routing work, and day references at the selected phase |
| `/subagent` | Fit test, claims, orchestration boundaries | Planning, task prompt, execution, review, merge/handoff | `issue-claim.sh`, `issue-deps.sh`, existing review helpers | Phase guardrails at dispatch; reviewer contracts at review |
| `/wrap` | PR target, authorship, merge authority | Discovery, gate verification, recovery, merge/sync, follow-ups, lessons | `merge-gate.sh`, `ci-status.sh`, `ac-checkboxes.sh`, `main-sync.sh` | Report templates when requested; duplicate policy for follow-up filing |
| `/pr-monitor-and-manage` | Fleet selection, authority, stop criteria | Discovery, polling, triage, repair, completion | `pr-state.sh`, `polling-state-gate.sh`, `merge-gate.sh` | Polling commands during observation; reviewer/escalation policy when actionable |
| `/go-on` | Resume routes, Step 0 classifier, receipt, stoppage log, live-work check | One module per stoppage kind (planned stop, usage-limit park, token exhaustion, unplanned); the review lane as prepare, publish, respond and merge | `scripts/dispatch-module.sh`, `merge-gate.sh`, `clean-behind-check.sh`, `diff-survival-check.sh` | Universal-resume ladder at Step 0; reviewer and merge-gate policy when the review lane reaches them |

The `/pm` and `/go-on` evidence below records their completed splits. The `/subagent`, `/wrap`, and `/pr-monitor-and-manage` rows describe planned migrations. Their proposed module prerequisites are established in the ordered slices below, and safety/required gates stay available regardless of source layout.

This issue establishes the contract and pilots it on `/issue-maker`; it does not rewrite the other giant skills. Migrate the rest as separately reviewable slices in this order:

1. **`/pm`** — keep the dispatch/ranking entry and universal gates short; separate backlog scan, candidate scoring, execution routing, and reporting by phase. Preserve issue ownership, active-work caps, unchanged-tick evidence rules, and persisted candidate state. Confirm no unrelated monitoring branch is read during a ranking-only request.
2. **`/subagent`** — keep safety, authority, and orchestration entry conditions available; load planning, prompt construction, execution, review, and handoff modules only at their phase. Preserve task-packet compactness, claim and dependency gates, and model/effort selection. Confirm a prompt-only request does not read execution or merge modules.
3. **`/wrap`** — separate PR discovery, gate review, repair, and merge readiness. Preserve authorship checks, required reviewers/CI, merge authority, and no-op behavior. Confirm status-only or blocked-gate paths do not read repair/merge procedures.
4. **`/pr-monitor-and-manage`** — separate discovery, active polling, triage, repair, and completion. Preserve no-unchanged-tick inference, telemetry boundaries, and monitoring stop conditions. Confirm a single observation tick reads only its monitor phase and required state.

For each slice, inventory content as (a) entry guidance, (b) branch/phase modules, (c) deterministic scripts, and (d) optional references. State each module's trigger and prerequisites in its header; prove with a trace fixture that a description/index does not read siblings or nested references. Add before/after source measurements and runtime evidence where available. Compare behavioral outputs, ownership, safety and merge gates, compaction recovery, missing-module handling, and retry overhead with the pre-split workflow before claiming parity.

### PM day-mode slice (#2170)

Ordinary cold start and resume use the entry and existing procedures. An active day route resolves one module path at a time. Arming checks path availability before claiming work. Recovery uses the persisted day generation and park/wake identity and reads the matching phase. The 2D instructions retain their order and behavior. Three relative Markdown prefixes changed so the original link targets remain reachable from the modules.

On baseline `475769d3`, the entry went from 38,107 to 24,573 words and from 258,458 to 165,258 bytes. The parity checker verifies the exact baseline with the seven modules. Fixture traces cover the installed symlink, unset HOME fallback, absent module, invalid phase and day/park/cadence behavior. The source measurements describe the instructions selected by the fixture. The final PM section records the source measurements and runtime evidence available for the split.

### PM ranking and resume slice (#2171)

Resume loads three phases. Ranking loads four phases as it reaches them. A saved-queue refill uses the existing shared priority and ownership checks and reads window fit only when it applies. A bounded rescan additionally loads rank fetch and score. A passive status question reads no rank or resume phase. Ranking-only requests exit before the orchestration loop.

The entry moves from 24,573 to 16,724 words and from 165,258 to 112,487 bytes on baseline `cccba0cb`. The parity check covers the line multiset and ordered phase contents, including previously extracted day modules. Its one ordered relocation puts the original pause and scope read before scoring as the block requires. The dispatcher fixture verifies the documented phase paths, including installed resolution. These measurements count source text.

### PM orchestration and final verification (#2172, #2173)

The PM entry selects one procedure at a time. The day phases, three resume phases, four ranking phases, three shared gates and eight orchestration modules use the same dispatcher. The entry still owns execution authority, the user and repository scope, and the pause, budget, usage horizon and deadline requirements. Launch, merge and reporting checks are exercised at their moved call sites.

The table counts the entry, distinct module files opened by each caller fixture, and the same bounded reference sections on both sides. The pre-split source is `475769d3`. Ranking-only uses a paused `--no-clean` run with forgotten-PR triage. Status uses an explicit board render. Refill uses a saved candidate that reaches the ownership and active-window checks. The day tick reaches that refill and a due board render. A rescan, park transition, helper failure, or an optional report can take a different route.

| Caller fixture | Before words | After words | Before bytes | After bytes |
|---|---:|---:|---:|---:|
| Ranking only | 38,238 | 12,922 | 259,263 | 88,845 |
| Status | 41,134 | 10,734 | 277,743 | 72,434 |
| Saved-queue refill | 38,107 | 13,042 | 258,458 | 89,828 |
| Day tick | 41,134 | 20,819 | 277,743 | 141,437 |

The fixtures exercise the real dispatcher and record each opened source. Reusing an already loaded procedure adds no source read in a valid context. Recovery reads the entry and the saved phase and rechecks the current gates before continuing. The fixture verifies that prior phases and an unrelated missing module stay unread. The existing state fixtures check persisted receipt, park and wake ownership, pause, dependency order, and merge-gate behavior. A missing selected module reports its path and keeps the affected launch held.

These are source words and bytes. No harness loader trace or runtime token measurement was collected. The fixture includes the entry in every scenario and counts the same bounded table or ranking excerpts for both versions. Compaction adds the entry and the active phase again when needed. The check does not estimate LLM reading, cache hits, tool overhead, or actual retry frequency.

The source paths are relative to `.claude/skills/pm/modules/`. Every fixture also reads `SKILL.md`.

- Ranking only reads `rank/load`, `shared/priority`, `rank/fetch`, `rank/score`, `rank/present`, `flow/cleanup`, and `flow/forgotten-prs`. The comparison includes the User-Scoped Sections and Full Ranking sections of `pm-output-templates.md`.
- Status reads `flow/progress` and the Running now Table section of `time-estimates.md`.
- Saved-queue refill reads `flow/refill`, `shared/priority`, `shared/ownership`, and `shared/window-fit`.
- Day tick reads `day-tick`, then the same refill paths and `flow/progress`. It includes the same Running now Table excerpt as status.

| Parity and recovery check | Verification |
|---|---|
| Entry authority and launch gates | Mutation fixtures remove each entry guard individually and reject whole-tree and automatic module imports. |
| Selected reads | The real dispatcher returns one readable path. The four caller fixtures check selected paths in order and reuse repeated source reads. |
| Behavioral outputs and writes | The PM suites cover ranking, queue and receipt outcomes, issue scope, ownership, wake recovery, fallback reporting, and merge authority. |
| Resume and missing source | The recovery fixture loads only the active saved phase. Removing it returns the path and a failure with no alternate module selected. |
| Original instructions | Each landed split has an exact ordered parity proof. The final duplicate truncation warning in `resume/fetch.md` cites the one in `rank/fetch.md` at the same 500-issue threshold. |
| Measurement and retry scope | Count each selected file or named reference section once. For recovery, add the entry and active phase again only if the context needs them. |

Run `bash .claude/scripts/tests/pm-split-verbatim-check.test.sh` for the source-read and guard fixtures. To reproduce the table, sum whitespace-delimited words and bytes in the listed files and excerpts, with `git show 475769d3:.claude/skills/pm/SKILL.md` as the baseline entry and the same reference excerpts.

### /go-on slice (#2181)

The issue asked for this slice after `/pm` and `/subagent`, so their loader conventions would be settled. On `origin/main` at `e0a68ddf` the `/pm` slices had landed and the `/subagent` slice had not. This slice therefore copies the `/pm` conventions and adds none of its own: a self-locating `scripts/dispatch-module.sh OPERATION PHASE` that prints one path, exit 2 for an unsupported pair, exit 3 with `required module unreadable: <path>` for a missing, unreadable or linked module, an installed-first resolver block in the entry (`go-on-module-resolver`), and `go-on-routing` markers around every line the split added.

The entry keeps the two read-only and approval routes, Step 0 (0.1 to 0.5a), the run-mode reread, the live-work check, the class-to-module table, and a module-routing section covering the preflight, the missing-module blocker and compaction recovery. Each stoppage kind's 0.6 dispatch text moved verbatim to `modules/kinds/` (`planned-stop`, `usage-limit-park`, `token-exhaustion`, `unplanned`). The review lane moved verbatim to `modules/review/`: `prepare` (lifecycle-helper resolution, Steps 0b, 1 and 1b), `publish` (Steps 2 to 4, including the claim-holder line from #2356), `respond` (Steps 5 to 7) and `merge` (Steps 8 to 10). Every module header states its route, trigger, prerequisites, and next module or loop-back. Step numbers, probe letters and test anchors are unchanged, so references elsewhere still resolve.

Before any write, the lane preflight resolves every module the selected lane can reach without reading them: the kind module, plus all four review modules for `token_exhaustion` and `unplanned`. A missing module is `[BLOCKED]`, naming the module, class, repository, PR or issue, evidence digest, last step and next step, with no fallback and no receipt. Before the receipt write the next step is a rerun. After it, the next step is a rerun with `--again`. On compaction, the entry is reloaded, the generation and live-work checks run again, and the class Step 0 selected is kept. A delegated lane reads only its kind module. A review lane reads its kind module, `review:prepare` and the active review module, and the lifecycle helpers are re-resolved and the authorship and diff-survival guards re-checked before any write. Completed prepare steps are not re-run.

Measured on baseline `e0a68ddf` (`.claude/skills/go-on/SKILL.md`, 97,195 bytes / 14,116 words) with `LC_ALL=C wc -wc` on macOS. Python `bytes.split()` gives the same word counts. Each trace counts the entry and the distinct modules it reads once. No nested references are included on either side: the review lane cites the same references before and after the split.

| Caller trace | Files read | Before bytes / words | After bytes / words |
|---|---|---:|---:|
| Classification only (rank 5 or unclassifiable) | entry | 97,195 / 14,116 | 51,782 / 7,340 |
| `pause` / `end` | entry, `kinds/planned-stop` | 97,195 / 14,116 | 52,732 / 7,478 |
| `usage_limit_park` | entry, `kinds/usage-limit-park` | 97,195 / 14,116 | 55,010 / 7,839 |
| `token_exhaustion`, `continue_polling` | entry, `kinds/token-exhaustion`, `review/prepare`, `review/respond`, `review/merge` | 97,195 / 14,116 | 95,390 / 13,748 |
| `token_exhaustion`, unpushed fixes | the previous row plus `review/publish` | 97,195 / 14,116 | 100,713 / 14,564 |
| `unplanned`, full lane | entry, `kinds/unplanned`, all four review modules | 97,195 / 14,116 | 100,141 / 14,476 |
| Compaction reread at Step 9a | entry, `kinds/unplanned`, `review/prepare`, `review/merge` | 97,195 / 14,116 (whole file again) | 79,281 / 11,504 |

A full review-lane resume reads about 3% more source than before: that is the routing text. The delegated lanes and classification-only runs read roughly half. These are source bytes and words, **not runtime tokens**. No harness loader trace was available, so actual reads, cache effects, and whether a model follows the routing were not observed. A missing-module retry adds the entry and the selected lane again after repair; nothing written before the blocker is replayed.

| Parity and recovery check | Verification |
|---|---|
| Original instructions | `go-on-dispatch-module.test.sh` compares the line multiset outside routing markers (blank lines and bare `---` separators ignored) with the baseline file while the comparison base is still unsplit; pin it with `GO_ON_SPLIT_BASELINE=e0a68ddf`. 1,004 instruction lines match. A one-word edit to a moved line fails it. |
| Outputs and delegation | The delegated lanes still forward `--resume-refill` and `--generation`, and still relaunch nothing themselves; the review lane's status lines, `/wrap` hand-off and the rule against running `admin-merge.sh` are unchanged text. Existing suites (`go-on-universal-resume`, `subagent-limit-park`, `pause-multisession`, `end-pause-contract`, `claim-renewal-wiring`, `go-on-thread-comment-bound`, `test_quota_resume_roster.py`, `desk/tests/stoppage-offline`) pass against the entry and the module that now holds each block. |
| Safety and merge gates | The generation gate, probes, receipt, stoppage log, run-mode reread and live-work check stay in the entry; the fixture fails if any leaves it or a lane step returns to it. Authorship, diff-survival and merge-gate text moved unchanged, and every negative contract check scans the entry and all modules. |
| Selected reads | The fixture builds each trace from the entry's routing table and the real dispatcher, and checks that no kind's trace reads another kind's module. |
| Missing module | The fixture removes a review module from a copied install: the preflight exits 3 naming the path before the simulated receipt write, and a delegated lane is not blocked by it. Invalid pairs exit 2; linked modules and linked module directories exit 3. |
| Compaction recovery | The fixture re-dispatches a persisted kind and step and reads only that kind module, `review:prepare` (helpers and write guards), and the review module holding the step. |
| Retry overhead | As in the table above: setup is the entry, and a rerun adds the selected lane again. Actual retry frequency is unknown. |

Preserved ambiguities, moved verbatim rather than resolved: a `token_exhaustion` entry at Step 6 does not say whether Step 5 runs first; the rank-4 report wording in Step 10; the rank-2 table's "Relaunch each" against the lane's delegate-only rule; and `--again` with an unreadable receipt. The one added prerequisite statement, in the `token-exhaustion` header, cites existing rules: the lifecycle helpers and Step 0b's authorship guard come from `review:prepare`, and Step 1 runs before any commit or push as that step already requires.

Run `bash .claude/scripts/tests/go-on-dispatch-module.test.sh`. Reproduce the table with `git show e0a68ddf:.claude/skills/go-on/SKILL.md | LC_ALL=C wc -wc` and `cat` of each trace's files piped to the same command.

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
