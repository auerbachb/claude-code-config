# Runbooks and long command forms

Runbooks, procedures, and long command forms moved out of the auto-loaded rules.

Back to the [reference index](../README.md).

## Contents

- `terminal-output-enforcement-decision.md` — documentation-only verdict for human reply deduplication, evaluated mechanisms, delivery limits and reconsideration triggers (Issue #1665).

- `recovery-evidence.md` — typed gate/wait failures, private raw captures, separate failure indexes and read-only recovery after child exit (Issue #1974)
- `wait-handoff-selection.md` — pinned scoped/legacy wait persistence, locked identity guards, migration refusal and explicit repair (Issue #1975)
- `incremental-skill-loading.md` — operation/phase loading contract, source-measured `/issue-maker` pilot traces, recovery and parity checklist, and ordered migration roadmap for `/pm`, `/subagent`, `/wrap`, and `/pr-monitor-and-manage` (#1872)

- `ac-gate.md` — exemption logic, exact heading, three ordered checks, exit codes, and both real regression failures (PR #588 / PR #593) for `ac-gate.sh` CI gate (#1281)
- `admin-merge-auto-plain.md` — mechanism and contracts for the one `admin-merge.sh --auto-plain` shape Claude may execute itself; plain vs protection-modifying shape distinction (#754)
- `ai-quotas.md` — overview and index of the quota reference: the `~/.claude/ai-quotas.json` schema, per-account profile layout, where each provider keeps its credential (and why the macOS Keychain suffix is observed rather than derived), the display-only boundary for `/quotas-setup` (#1666), the one reserve consumer (#1863), and a topic map to the files below (split by topic in Issue #2180)
- `ai-quotas-reader.md` — the shared `/quotas` reader contract: row shape, statuses, test seams, overage and the cheapest-next hint, the read-outcome ledger, ordered usage sources and browser diagnostics, the last-known folder, the FETCHED column, paid usage, resets and top tier, and plan tier (#1667, #1669; Issue #2180)
- `ai-quotas-claude.md` — the Claude reader (usage endpoint, status-line and app-usage-tool readings) and renewing an expired access token (#1716; Issue #2180)
- `ai-quotas-codex.md` — the Codex reader, why the weekly window is chosen by `windowDurationMins`, and the captured Codex HTTP wire format (#1864; Issue #2180)
- `ai-quotas-cursor.md` — the Cursor reader on the IDE token: state-store paths, the captured endpoint and response, and the encrypted-token observation route (#1668, #1703, #1870; Issue #2180)
- `ai-quotas-history.md` — the snapshot history file, the daily unattended LaunchAgent, nicknames and the compact table's column budget, and burn-rate projection (#1700, #1701; Issue #2180)
- `ai-quotas-setup.md` — exact per-provider re-login commands, launchers and shared config, label/path repair, fresh-profile reauthentication, and export/import of the account list (#1851, #1850, #2468; Issue #2180)
- `quotas-plan-prices.json` — dated list of subscription plan prices (USD per month) that `/quotas` reads for its TIER and $/MO columns, with a verification date and source per plan; edit it, not the reader, when a price changes (Issue #2469)
- `quotas-setup-runtime-hotspot-decision.md` — KEEP the quota setup command (Issue #1907); five changes without recorded conflicts, plus a verified config-sharing backup guard
- `ai-quotas-antigravity.md` — Google Antigravity quota research (Issue #2407): documented five-hour and weekly windows, where the figure is shown, what was verified on this Mac, and why no provider is built yet
- `ai-quotas-reader-hotspot-decision.md` — KEEP the quota reader and its provider adapters together (Issue #1950); ten counted changes and no recorded conflicts
- `cli-tool-defaults.md` — installed service CLIs (vercel, neonctl, railway, cloudinary) and common commands; CLI-first over web dashboards
- `churn-hotspots.md` — detector/classifier division, calibration, thresholds, and closed/no-cost suppression policy for churn hotspots (Issues #755 and #1307)
- `churn-hotspot-baselines.json` — file-and-issue keyed score snapshots consumed by `churn-hotspot-wrap-plan.sh`, which `/wrap` invokes for its 2× material-growth gate (Issue #1307)
- `churn-hotspot-exemptions.json` — lint-enforced catalog files exempted from churn-hotspot flagging by `churn-hotspots.sh`; every entry must name the enforcing lint (`lint`) and why it forces the edit (`reason`), or the detector exits 3 (Issue #1571)
- `review-timing-baseline-2026-11-11.md` — dated before-picture for review-on-request timing: per-repo CI duration and failure share, reviewer response time from request or push, refusals, CodeAnt pre-review approvals, and stated blind spots (Issue #2196)
- `cr-polling-commands.md` — full multi-line `gh api` commands for CR review polling and CI verification
- `cr-rate-limits.md` — full CR rate-limit caps, hourly-state mechanics, and `cr-review-hourly.sh` flags
- `codeowner-bot-approvals.md` — CODEOWNERS handling for review bots and stale-approval re-trigger commands
- `capability-discovery-examples.md` — false-walls vs real-walls catalog for try-every-path-before-handoff (`safety.md` Capability Discovery)
- `browser-capability-rung.md` — rung 4 (browser) detail: in-app vs Chrome surface selection, the single login/authorization ask, bounded attempt, untrusted-page posture, subagent reachability matrix, and the `phase-c-merger` stay-restricted decision (#852)
- `diff-survival-guard.md` — mechanism and rationale for `diff-survival-check.sh`; the failure mode where clean conflict markers hide a silently dropped fix (#757)
- `merge-gate-reviewer-paths.md` — per-reviewer merge-gate path details (CR/CodeAnt, BugBot, Greptile)
- `backfill-review.md` — overnight backfill of no-review merges (issue #1900): merged-diff review method and why not a draft PR, free-only channel allowlist, fail-closed capacity rules, verification against main, marker dedup, ledger outcomes and label swap, launchd scheduling
- `no-review-override.md` — no-reviewer merge override (issue #1899): verdict inventory, HEAD anchor, window config, waived vs never-waived reasons, `/wrap` routing, and the `~/.claude/unreviewed-merges.json` ledger the backfill reads
- `quota-reserve.md` — pausing autonomous work on a Claude account once its provider-reported weekly usage reaches the owner's threshold (#1863): the owner's decisions, how the marker and the two hooks work, exactly what is blocked and what never is, every fail-open path, and what is deliberately not covered (Codex, Cursor)
- `ai-quotas-test-hotspot-decision.md` — KEEP the quota test dispatcher and its 30 fixture groups (Issue #1902); nine counted changes and the existing split
- `subagent-park-fixture-hotspot-decision.md` — keep the usage-limit park fixture together (Issue #1682); three counted changes share the same park and wake ownership checks
- `paid-review-approval.md` — one paid AI review per owner yes (issue #1898): when an attended session may ask, the `AskUserQuestion` shape and human-queue path, the single-use grant `paid-review-grant.sh` writes and spends (PR + HEAD + vendor + session), on-demand offer acceptance, and why headless contexts never ask
- `independent-areas.md` — optional service boundaries for launch-side overlap in `/wave` and `/subagent`, with config and matching rules (#2159).
- `hook-test-serial-group.md` — per-entry decision record for the 40-suite hook-test `SERIAL_GROUP`: why each suite stays serial, its timings, and what must change before it can return to the pool (#2207).
- `review-policy.md` — per-repo review tiers declared in pm-config `## Review policy`: table format, strictest-wins resolution across paths and labels, fail-closed invalid policies, base-branch reads, and what each gate (`ci-only` / `ci+codeant-one-round` / `full` / `legacy`) means; resolved by `review-tier.sh` (#1724, #1725)
- `review-request-timing.md` — when the agent asks for an AI review: `REVIEW_REQUEST` (`after-ci` default, `on-push`), named fast checks and the grace for checks that never report, one request per HEAD, and the manual dashboard checklist that switches reviewers' automatic triggers off (#2195)
- `merge-gate-stale-approval-redemption.md` — CodeAnt in-place review edit: how `merge-gate.sh` redeems a stale approval by evidence rather than by reviewer identity (#876)
- `merge-sequencing.md` — mechanism and state machine for `merge-sequence.sh`; overlap-aware merge sequencing for PRs touching the same file (#756)
- `codeant-supplemental.md` — CodeAnt supplemental polling on the CR path, plus CodeAnt CLI install state (Graphite retirement and retired-thread cleanup, #1889 and #2192)
- `local-review-cli-failure-modes.md` — how CodeAnt/CodeRabbit fake a clean pass on failure, 403 triage, 15-file cap, and binary-absent detection (#642, #819)
- `agent-issue-claims-block.md` — the single source of the provider-neutral issue-claim block that `repo-bootstrap.sh --apply` installs into `AGENTS.md` (check, claim, renew, release; plain-`gh` fallback recipe; #2285)
- `repo-bootstrap-protection.md` — branch-protection remediation mechanism: CI check-name discovery, the confirmation prompt, and the read-then-PUT payload that never downgrades existing protection (`repo-bootstrap.md`; #918)
- `repo-bootstrap-workflows.md` — provisioned-file design: the one-list guarantee, `get_file_content()` mechanism, drift guard, and `BOOTSTRAP_FILES` as the single authoritative list (`repo-bootstrap.md`; #1282)
- `dirty-main-guard.md` — how `--check` computes "dirty", what `--quarantine` preserves, and the recovery-branch listing/inspection/deletion commands (`main-hygiene.md`; #918)
- `worktree-isolation-command-shapes.md` — canonical catalog of the Bash command shapes the harness's worktree-isolation guard refuses for an isolated agent (`;`-separated compounds, raw `until … do sleep … done`, `cd … && … | …`), why the refusal names git operations that are not present, the allowed one-plain-call shape, and the wrapper for each recurring case (`worktree-status.sh`, `wait-until.sh`, `--repo`/`--repo-path` flags); #1470
- `worktree-registration-quarantine-20260826.md` — what the 2026-08-26 registration quarantine holds (63 entries, 22 locked, 19 still unreadable), why it is not deletable yet, and the inverse debris class of 59 checkouts with no registration (`stale-cleanup.sh`; #1363, #1402)
- `orphaned-worktree-checkouts-decision.md` — decision record for the inverse class of #1402: why the 59 legacy orphans are out of scope, why `stale-cleanup.sh` reports orphaned checkouts but gates removal behind `--remove-orphaned-checkouts`, why the class is exit-code neutral and fails closed, and why harness self-cleanup stays in the orchestration layer (`stale-cleanup.sh`; #1417)
- `review-substance-evidence.md` — why a bot APPROVED requires a substantive review footprint; hollow APPROVED failure mode and evidence checks in `merge-gate.sh` (#875)
- `review-coverage-2026-11.md` — how the 246 PRs merged in the 14 days to 2026-11-13 cleared AI review at merge HEAD (95.5% counted; 0 unknown); threshold decision not warranted, with the stricter-footprint sensitivity flagged for the owner; method and ledger cross-check (#2313)
- `fixpr-workflow-history.md` — on-demand rationale and original source-line map for the `/fixpr` trim (#2182)
- `wrap-fixpr-delegation.md` — `/wrap` Step 2.1 → full `/fixpr` recovery handoff contract
- `subagent-thread-limit-park.md` — reactive usage-limit park for threads running Phase A/B/C subagents: structured-signal detection, the shared `.day` park claim, per-pipeline phase records, the sleep-until-reset wake, `/go-on` resume, and session-start recovery (#1618)
- `subagent-thread-limit-park-hotspot-decision.md` — keep the usage-limit park procedure together (Issue #1693); two recent changes share the park and wake identity contract
- `release-cadence.md` — agent-initiated TestFlight cadence: policy schema, `auto` interval derivation, the per-repo trigger table, why the `release:ios` label must be applied pre-merge, and the structural exclusion of the App Store path (#1169)
- `pause-state.md` — state shape, triage rule rationale, deadline semantics, and legacy `.suspend` recovery for the `/pause` laptop-close wind-down command (Issues #1249 and #1310); companion to the `_pause_comment` block in `session-state-schema.json`
- `background-task-shutdown.md` — shared `/end` and `/pause` contract for launch gating, bounded cooperative checkpoint, exact-ID hard stop, recovery preservation, and zero-live-task verification (Issue #1308)
- `universal-resume.md` — evidence map, precedence ladder, `pause`-vs-`end` newest-wins tie-break, resume receipt, refill/launch-gate rules, and degradation contract behind `/go-on` Step 0, the single resume front door for every stoppage class (Issue #1397); companion to the `_resume_comment` block in `session-state-schema.json`
- `state-file-contracts.md` — expanded scoping, write-lock, migration, and field-type mechanics for `session-state.json` + handoffs (`handoff-files.md`; #625, #638, #639, #651, #655, #682, #687, #704, #757, #794, #967, #971)
- `run-modes.md` — PM run mode (`default` / `speed` / `cheap`) storage at `.repos[key].run_mode`, the sole `run-mode.sh get` read path, fail-open policy, human-chat-only authority, and parse rules for `/pm` (Issue #2428, increment 1)
- `handoff-missing-owner-repo-decision.md` — why `handoff-state.sh` warns rather than refuses when a write omits `--owner-repo`, the two rejected designs, why the scoping guarantees stay unweakened, and why the flat-path migration is not yet declared finished (`handoff-files.md`; #1302)
- `session-state-schema-hotspot-decision.md` — KEEP + targeted-dedup adjudication for the `session-state-schema.json` churn hotspot; canonical ownership, preserved compatibility, and field-change checklist (#964)
- `session-state-collector.md` — the single definition of what a handoff *reads*, used by `/end` (portable rendering); the Claude-native renderer retired with the PM handoff skill (#2344) (Issue #901)
- `session-state-collector-hotspot-decision.md` — keep the shared collector together (Issue #1329); four historical changes and zero current touches
- `portable-handoff.md` — the `/end` artifact: bounded takeover context, canonical repository/session naming, locked atomic publication, cross-agent resume safety, checkpoint compatibility, and mechanical portability enforcement (Issues #901, #912, and #1311)
- `authorship-guard.md` — `pr-authorship.sh` exit-code semantics, the three shared-script fail-safes, and `--allow-nonauthor` override plumbing (`safety.md` §Authorship; #733)
- `issue-claim.md` — `issue-claim.sh` mechanism: the three GitHub claim artifacts, why the holder token is finer-grained than the login, block-at-holder / release-at-account, staleness, the `--allow-claimed` override, and every call site (`issue-planning.md` step 0; #873)
- `issue-claim-script-hotspot-decision.md` — KEEP claim discovery, renewal and guarded release together (Issue #2072); five counted changes and no recorded conflicts
- `issue-claim-fixture-hotspot-decision.md` — KEEP the shared claim lifecycle fixture (Issue #2074); six counted changes, no recorded conflicts, and the fixture is unchanged.
- `issue-completion.md` — repo-qualified post-merge issue verification, full-scope missed closure recovery, interrupted/resumed PM reconciliation, and consumer audit (Issue #1973)
- `autofile-dedup.md` — duplicate-check thresholds for autonomous issue filing (`/wrap` Phase 3); strong/weak/none classification, exact-artifact dedup, and the comment-vs-file rule
- `review-stack-audit.md` — `/review-stack-audit` rationale and contracts: measured versus declared billing state, roles and deduplication, reply verdict and fallback attribution, value and velocity fields, scorecard, and study limits (Issues #1201 and #1949).
- `graphql-thread-resolution.md` — full GraphQL queries/mutations for resolving PR review threads
- `exit-report-format.md` — full structured exit report block specification
- `final-wrapup-format.md` — minimal terminal outcome or actionable blocker; explicit summaries and machine reports retain their formats (Issue #1396, Issue #1873)
- `greptile-setup.md` — Greptile dashboard setup notes
- `greptile-reply-format.md` — reply conventions for Greptile threads
- `aws-guidance.md` — full AWS new-experience guidance: terminology, Region/service constraints, spend-limit rules, service-availability check procedure, and help-level definitions; condensed summary in `CLAUDE.md` points here
