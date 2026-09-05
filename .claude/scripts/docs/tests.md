# Tests

<!-- catalog:category id=tests order=130 -->
<!-- catalog:covers Every test under `tests/`, all offline (no network required) -->

All tests live in `tests/` and run offline (no network required). Run from the repo root:
`bash .claude/scripts/tests/<name>.test.sh`

Rows are generated in `LC_ALL=C sort` order — byte order, not dictionary order,
so `overrun-check-tzdata.test.sh` comes before `overrun-check.test.sh` (`-` is
0x2D, `.` is 0x2E). Every category doc is ordered the same way now that the rows
are generated (#1578), which retired the per-doc `<!-- catalog-lint: ordered -->`
opt-in of issue #1544.

| Test | What it covers |
|------|----------------|
<!-- catalog:rows:begin -->
| [ac-gate.test.sh](../tests/ac-gate.test.sh) | Tests for `ac-gate.sh` — all exit codes, message assertions, both real regression failures (PR #588 / PR #593) |
| [active-work-cap.test.sh](../tests/active-work-cap.test.sh) | Tests for `active-work-cap.sh` — cap resolution, the three count sources, and fail-loud read errors |
| [admin-merge.test.sh](../tests/admin-merge.test.sh) | Tests for `admin-merge.sh` |
| [background-task-registry.test.sh](../tests/background-task-registry.test.sh) | Tests exact-ID registration, terminal transitions, stale fail-closed behavior, and concurrent writes |
| [backlog-health.test.sh](../tests/backlog-health.test.sh) | Tests for `backlog-health.sh` |
| [backlog-staleness.test.sh](../tests/backlog-staleness.test.sh) | Tests for `backlog-staleness.sh` |
| [bgwork-ceiling.test.sh](../tests/bgwork-ceiling.test.sh) | Tests for `bgwork-ceiling.sh` |
| [bounded-run.test.sh](../tests/bounded-run.test.sh) | Tests `lib/bounded-run.sh` — real exit status on the healthy path, 124 at the bound, the process-group kill, a late finisher's own status (failures included) rather than a false timeout, `normalize_bound` fallbacks, the source-only guard, and `kill_child`'s `ps`/`tr` guards keeping a missing helper off a caller's stderr contract |
| [candidate-ownership.test.sh](../tests/candidate-ownership.test.sh) | Tests `candidate-ownership.sh` — live-owner skip, dead-owner adoption, indeterminate liveness, bare-stale warn-and-proceed, corrupt-state degradation, and the read-only guarantee |
| [ccusage-baseline.test.sh](../tests/ccusage-baseline.test.sh) | JSON shape, human-readable output, ccusage-absent exit 3, empty-blocks exit 1, usage errors, and --help for `ccusage-baseline.sh` (#781) |
| [check-runs-dedup.test.sh](../tests/check-runs-dedup.test.sh) | Tests for `check-runs-dedup.sh` |
| [checkpoint-handoff-slow-bound.test.sh](../tests/checkpoint-handoff-slow-bound.test.sh) | Pins the ≥420s bound floor for the slow `checkpoint-handoff.test.sh` (#1505) — its banner is emitted before any fixture work and names a floor ≥420, and no runner, CI job, or other file applies a smaller bound that would cover it |
| [checkpoint-handoff.test.sh](../tests/checkpoint-handoff.test.sh) | Tests the degrade ladder in `checkpoint-handoff.sh` — the emitted document must pass `portable-handoff-lint.sh` in any repository, harness-shaped filenames included. **Slow (~71s idle, ~202s loaded): any bound must be ≥420s** (#1505) |
| [chip-offer-registry.test.sh](../tests/chip-offer-registry.test.sh) | Tests for `chip-offer-registry.sh` — reservation, cap exhaustion, transitions, counting, concurrent emitters, TTL expiry, and the `--help` / `--emitter` allowlist drift guard |
| [churn-hotspot-wrap-plan.test.sh](../tests/churn-hotspot-wrap-plan.test.sh) | Tests `/wrap` hotspot suppression, material-growth, evidence, re-file, unknown-state, and aggregate classification |
| [churn-hotspots.test.sh](../tests/churn-hotspots.test.sh) | Tests for `churn-hotspots.sh` |
| [ci-status.test.sh](../tests/ci-status.test.sh) | Tests for `ci-status.sh` |
| [claude-config-sync.test.sh](../tests/claude-config-sync.test.sh) | Tests `claude-config-sync.sh` against a real local origin + clone — stale-machine catch-up, the restart marker and its startup clear, the failure counter/threshold/recovery, the lock-contention skip, and the root-repo scope guard |
| [clean-behind-check.test.sh](../tests/clean-behind-check.test.sh) | Tests for `clean-behind-check.sh` |
| [compaction-resume-polling-state-gate.test.sh](../tests/compaction-resume-polling-state-gate.test.sh) | Tests `polling-state-gate.sh --verify-state` after synthetic post-compaction recovery |
| [cr-plan.test.sh](../tests/cr-plan.test.sh) | Tests for `cr-plan.sh` |
| [credit-budget.test.sh](../tests/credit-budget.test.sh) | Tests `credit-budget.sh` and `lib/usage-limit-classify.sh` — the plan-window vs credit-overage classifier matrix, reset-clause parsing and its refusals, plan-window events yielding `ok` with the pre-fix predicate as a negative control (#1633), a genuine overage still yielding `reached`, a reopened window never gating, and the fail-closed paths |
| [cursor-review-workflow-suppression.test.sh](../tests/cursor-review-workflow-suppression.test.sh) | Tests the one-nudge-per-HEAD guard in `.github/workflows/cursor-review-pr-comment.yml` |
| [date-r-ordering.test.sh](../tests/date-r-ordering.test.sh) | Pins every shipped `date -r` fallback chain GNU-first (#1587) — a GNU-semantics `date` shim plus an epoch-named decoy file prove each fixed site reads the epoch, not a filename, with per-site negative controls, structural order checks on the already-GNU-first sites, and the deliberate BSD-first negative-control fixture in `overrun-check-tzdata.test.sh` pinned as such |
| [diff-survival-check.test.sh](../tests/diff-survival-check.test.sh) | Tests for `diff-survival-check.sh` |
| [dirty-main-guard.test.sh](../tests/dirty-main-guard.test.sh) | Tests for `dirty-main-guard.sh` |
| [empty-array-expansion.test.sh](../tests/empty-array-expansion.test.sh) | Sibling-sweep regressions for the empty-array-under-`set -u` abort on bash 3.2 |
| [end-pause-contract.test.sh](../tests/end-pause-contract.test.sh) | Contract tests binding the `/end` and `/pause` skills, their resume companions, and the hooks and scripts they drive |
| [escalate-review-app-identity.test.sh](../tests/escalate-review-app-identity.test.sh) | Publishing-app identity and spoof-guard tests for `escalate-review.sh` |
| [escalate-review-bugbot-classification.test.sh](../tests/escalate-review-bugbot-classification.test.sh) | BugBot failure and response-classification tests for `escalate-review.sh` |
| [escalate-review-cr-retry-window.test.sh](../tests/escalate-review-cr-retry-window.test.sh) | CodeRabbit retry-window grace tests for `escalate-review.sh` |
| [escalate-review-evaluator-outage.test.sh](../tests/escalate-review-evaluator-outage.test.sh) | Bounded evaluator-outage suppression in `escalate-review.sh` — a `review-substance.sh` outage caps the verdict at `polling_cr` for an hour instead of authorising a paid review, then resumes escalation. The inclusive 3600 s boundary is both pinned in the source and **executed**: scenario (f2) lands a run on exactly the cap by re-aiming on the overshoot the script itself reports (a fixed exactly-3600 fixture races the clock upward, and a fixed-width sweep would just encode a guess about runner speed) and fails if no probe lands, and (f3) pins the first excluded second |
| [escalate-review-gate-met.test.sh](../tests/escalate-review-gate-met.test.sh) | Approval freshness and gate short-circuit tests for `escalate-review.sh` |
| [escalate-review-head-observation-anchor.test.sh](../tests/escalate-review-head-observation-anchor.test.sh) | Head-observation anchor tests for `escalate-review.sh` — a force-pushed older commit must not make a prior-HEAD banner or `@cursor review` trigger read as fresh |
| [escalate-review-merge-gate-freshness-parity.test.sh](../tests/escalate-review-merge-gate-freshness-parity.test.sh) | Drift guard that `escalate-review.sh` and `merge-gate.sh` reach the same approval-freshness verdict on one PR state, in-place re-reviews included |
| [escalate-review-never-invited.test.sh](../tests/escalate-review-never-invited.test.sh) | Invitation, grace-window, and cache-state tests for `escalate-review.sh` |
| [escalate-review-silent-exit.test.sh](../tests/escalate-review-silent-exit.test.sh) | Loud-exit contract tests for `escalate-review.sh` — every non-zero exit emits exactly one `escalate-review.sh: …` stderr diagnostic, the `EXIT` trap normalizes a raw 126/127 to exit 4 without fabricating a `STATUS=` verdict, and a negative control reproduces the pre-fix zero-output 126 on a copy with only the trap line removed |
| [estimate-resolve.test.sh](../tests/estimate-resolve.test.sh) | Tests for `estimate-resolve.sh`, including the empty-`GH_ARGS` unbound-variable regression |
| [fixpr-step3b-pushed-sha.test.sh](../tests/fixpr-step3b-pushed-sha.test.sh) | Static guard that `/fixpr` Step 3b passes the post-push `PUSHED_SHA` to `bugbot-refused-head.sh`, not the pre-push `HEAD_SHA` |
| [forgotten-pr-triage.test.sh](../tests/forgotten-pr-triage.test.sh) | Tests for `forgotten-pr-triage.sh` |
| [go-on-universal-resume.test.sh](../tests/go-on-universal-resume.test.sh) | Contract tests for `/go-on` as the universal resume front door — stoppage-class detection, precedence, refill-gate safety |
| [handoff-scoping.test.sh](../tests/handoff-scoping.test.sh) | Tests per-repo handoff path scoping in `handoff-state.sh` |
| [handoff-state.test.sh](../tests/handoff-state.test.sh) | Tests for `handoff-state.sh` |
| [help-output.test.sh](../tests/help-output.test.sh) | `--help` contract for every repo script (#1513/#1475/#1528) — repo-wide smoke sweep (exit 0, non-empty, silent stderr, never ends on a bare section heading) plus heading **and** body-content assertions for the 12 scripts whose extraction was BSD-fatal or truncating, fixtures proving the checker rejects both pre-fix forms, and (Part 4) the empty-extraction guard: an extraction that yields nothing must exit non-zero and say so on stderr, asserted end-to-end and at the `END`-block level, with a pre-fix control that still exits 0 |
| [infer-pr.test.sh](../tests/infer-pr.test.sh) | Tests for `infer-pr.sh` |
| [install-config-sync.test.sh](../tests/install-config-sync.test.sh) | Tests `install-config-sync.sh` / `uninstall-config-sync.sh` against `launchctl` and `uname` stubs — plist rendering, worktree-copy preference, `--interval` validation, teardown, and the non-Darwin guard |
| [issue-claim.test.sh](../tests/issue-claim.test.sh) | Tests for `issue-claim.sh` against a stateful `gh` stub, so a claim written by one run is read back by the next |
| [issue-dedup.test.sh](../tests/issue-dedup.test.sh) | Tests for `issue-dedup.sh` |
| [issue-maker-log-scoping.test.sh](../tests/issue-maker-log-scoping.test.sh) | Regression tests for the `/issue-maker` session log colliding across concurrent conversations |
| [leave-time.test.sh](../tests/leave-time.test.sh) | Runs the real skill-embedded bash for `/leave-by`'s lead-time cascade and `/subagent` Step 7's deadline decline (issue #1525), plus the cross-file contracts: one deadline source, Monitor wake, and teardown on both sides of a pause |
| [local-review.test.sh](../tests/local-review.test.sh) | Tests for `local-review.sh`; every CLI is a stub, so no network and no dependence on which CLIs are installed |
| [maybe-trigger-bugbot-suppression.test.sh](../tests/maybe-trigger-bugbot-suppression.test.sh) | Tests the BugBot spend-refusal suppression in `maybe-trigger-ai-review.sh` |
| [merge-gate-authorship.test.sh](../tests/merge-gate-authorship.test.sh) | Tests the authorship guard in `merge-gate.sh` |
| [merge-gate-bugbot.test.sh](../tests/merge-gate-bugbot.test.sh) | Tests the BugBot reviewer path in `merge-gate.sh` (issues #844, #962) |
| [merge-gate-ci-dedup.test.sh](../tests/merge-gate-ci-dedup.test.sh) | Tests CI check-run deduplication and CodeAnt supplemental gate in `merge-gate.sh` |
| [merge-gate-codeant-inplace-review.test.sh](../tests/merge-gate-codeant-inplace-review.test.sh) | Tests that a CodeAnt in-place review edit is not read as a stale approval in `merge-gate.sh` |
| [merge-gate-codeant-run-marker.test.sh](../tests/merge-gate-codeant-run-marker.test.sh) | Tests that CodeAnt pre-analysis approval stubs do not score as review coverage in `merge-gate.sh` |
| [merge-gate-greptile-comment.test.sh](../tests/merge-gate-greptile-comment.test.sh) | Tests Greptile comment handling in `merge-gate.sh` |
| [merge-gate-json-escaping.test.sh](../tests/merge-gate-json-escaping.test.sh) | Tests that `merge-gate.sh` emits control-character-free JSON built with jq rather than by string concatenation |
| [merge-gate-required-contexts.test.sh](../tests/merge-gate-required-contexts.test.sh) | Tests that `merge-gate.sh` blocks when every branch-protection required context is absent from HEAD |
| [merge-gate-review-substance.test.sh](../tests/merge-gate-review-substance.test.sh) | Tests that `merge-gate.sh` refuses hollow bot approvals as review coverage |
| [merge-gate-stale-approval.test.sh](../tests/merge-gate-stale-approval.test.sh) | Tests stale-approval rejection in `merge-gate.sh` |
| [merge-gate-sticky-cr-approval.test.sh](../tests/merge-gate-sticky-cr-approval.test.sh) | Tests that a fresh CR-path approval on current HEAD satisfies the gate even when the sticky reviewer is BugBot |
| [merge-gate-sut-override.test.sh](../tests/merge-gate-sut-override.test.sh) | Tests the `SUT` / `EVAL_SUT` / `MERGE_GATE` override contract for the `merge-gate-*` family — defaults, environment overrides, refusal of a mistyped path, and that no assignment is re-hardcoded |
| [merge-sequence.test.sh](../tests/merge-sequence.test.sh) | Tests for `merge-sequence.sh` |
| [model-fleet.test.sh](../tests/model-fleet.test.sh) | Tests for `model-fleet.sh` |
| [overrun-check-tzdata.test.sh](../tests/overrun-check-tzdata.test.sh) | Tests `overrun-check.sh`'s ET clock on a system where `America/New_York` does not resolve (#1529) — a PATH-shim `date` reproduces glibc-without-tzdata (zone falls back to UTC, `date` still exits 0); asserts cell mode and the breach alert render a **labelled** UTC value rather than an unlabelled 12-hour UTC clock under an `(ET)` header, with a negative control pinning unchanged Eastern output and a fidelity control proving the shim reproduces the bug |
| [overrun-check.test.sh](../tests/overrun-check.test.sh) | Tests `overrun-check.sh --readout-cells` — ET cell rendering, the pace-scaled overrun row, and the negative control proving the projected finish is floored at now |
| [pause-multisession.test.sh](../tests/pause-multisession.test.sh) | Tests per-session pause records and resume receipts (#1576) — interleaved concurrent pause writes staying independent, the extracted `/pause-resume` Step 1 selection program returning every un-resumed record newest-first, no masking when one is marked resumed, the legacy `.pause` / `.suspend` singletons as union members rather than an empty-map else-branch, and per-session resume receipts |
| [pm-day-horizon.test.sh](../tests/pm-day-horizon.test.sh) | Tests `/pm` day mode's usage-horizon reflex against the real fenced bash in the skill |
| [pmm-wake-step-4a.test.sh](../tests/pmm-wake-step-4a.test.sh) | Tests the `--auto-check` fleet scan in `/pr-monitor-and-manage-wake` Step 4a against the real fenced bash |
| [poll-watermarks.test.sh](../tests/poll-watermarks.test.sh) | Tests for `poll-watermarks.sh` |
| [polling-state-gate-multirepo.test.sh](../tests/polling-state-gate-multirepo.test.sh) | Tests multi-repo isolation in `polling-state-gate.sh` |
| [polling-state-gate.test.sh](../tests/polling-state-gate.test.sh) | Tests for `polling-state-gate.sh` |
| [portable-handoff-context.test.sh](../tests/portable-handoff-context.test.sh) | Tests for `portable-handoff-context.sh` |
| [portable-handoff-lint.test.sh](../tests/portable-handoff-lint.test.sh) | Tests that `portable-handoff-lint.sh` catches each violation class and does not fire on a genuinely useful handoff |
| [portable-handoff-publish.test.sh](../tests/portable-handoff-publish.test.sh) | Tests canonical `/end` handoff publication |
| [pr-authorship.test.sh](../tests/pr-authorship.test.sh) | Tests for `pr-authorship.sh` |
| [pr-issue-ref.test.sh](../tests/pr-issue-ref.test.sh) | Tests for `pr-issue-ref.sh` — tiered set-valued default mode, `--first` mode, `--all` mode, `owner/repo#N` form, word-boundary guards |
| [pr-preflight.test.sh](../tests/pr-preflight.test.sh) | Tests for `pr-preflight.sh` |
| [pr-state-check-runs.test.sh](../tests/pr-state-check-runs.test.sh) | Tests the canonical `pr-state-cr-split.jq` program invoked by `pr-state.sh` |
| [pr-state-classify.test.sh](../tests/pr-state-classify.test.sh) | Tests the canonical `pr-state-classify.jq` program invoked by `pr-state.sh --since` |
| [pr-state-infer-candidates.test.sh](../tests/pr-state-infer-candidates.test.sh) | Tests `pr-state.sh --infer-candidates` |
| [publish-agent-symlinks.test.sh](../tests/publish-agent-symlinks.test.sh) | Tests for `publish-agent-symlinks.sh` against a throwaway `HOME` |
| [publish-skill-symlinks.test.sh](../tests/publish-skill-symlinks.test.sh) | Tests `publish-skill-symlinks.sh` against a throwaway `HOME` — all five `migrate_symlink` states, the ownership predicate, pruning (absolute and relative legacy links alike), the exit-code contract for an un-removable link, and the `setup-skills-worktree.sh` delegation guard |
| [reference-catalog-lint.test.sh](../tests/reference-catalog-lint.test.sh) | Tests that `reference-catalog-lint.sh` fails on every drift class it claims to catch |
| [release-decide.test.sh](../tests/release-decide.test.sh) | Tests for `release-decide.sh` |
| [release-policy.test.sh](../tests/release-policy.test.sh) | Tests for `release-policy.sh` |
| [release-sweep.test.sh](../tests/release-sweep.test.sh) | Tests for `release-sweep.sh` |
| [reply-thread.test.sh](../tests/reply-thread.test.sh) | Tests for `reply-thread.sh` |
| [repo-bootstrap.test.sh](../tests/repo-bootstrap.test.sh) | Tests for `repo-bootstrap.sh` — file-set check/apply/report behavior and the exit-code contract |
| [repo-root.test.sh](../tests/repo-root.test.sh) | Tests `repo-root.sh`'s resolution contract and its wall-clock bound |
| [report-path.test.sh](../tests/report-path.test.sh) | Tests the collision-free report destination shared by `/review-stack-audit` and `/harness-audit`, over both series, with a month-only negative control |
| [review-stack-audit.test.sh](../tests/review-stack-audit.test.sh) | Tests `/review-stack-audit`'s measurement and drift engines offline through their fixture path |
| [scheduling-primitive-alignment.test.sh](../tests/scheduling-primitive-alignment.test.sh) | Regression coverage that recurring polls use `Monitor` end to end |
| [script-usage-log-redirect.test.sh](../tests/script-usage-log-redirect.test.sh) | Runtime regression that converted telemetry writes stay silent without `~/.claude` and still log with it (issue #1406) |
| [session-scheduling-reconcile.test.sh](../tests/session-scheduling-reconcile.test.sh) | Tests for `session-scheduling-reconcile.sh` against a redirected `HOME` |
| [session-state-active-agents.test.sh](../tests/session-state-active-agents.test.sh) | Tests the `.active_agents` keyed-map contract in `session-state.sh` — a negative control proving the old whole-value replace loses a sibling thread's entries, concurrent per-key writes that lose none, the array→map migration, and `--remove-agent` (issue #1631) |
| [session-state-audit.test.sh](../tests/session-state-audit.test.sh) | Tests for `session-state-audit.sh` |
| [session-state-cas.test.sh](../tests/session-state-cas.test.sh) | Tests `session-state.sh --cas` — compare-and-set success, loss, a distinct exit code, and concurrent writers |
| [session-state-migration.test.sh](../tests/session-state-migration.test.sh) | Tests the legacy-flat → per-repo migration in `session-state.sh` |
| [session-state.test.sh](../tests/session-state.test.sh) | Tests for `session-state.sh` |
| [skill-conventions-audit.test.sh](../tests/skill-conventions-audit.test.sh) | Tests for `skill-conventions-audit.sh` |
| [skill-usage-merge.test.sh](../tests/skill-usage-merge.test.sh) | Tests for `skill-usage-merge.sh` |
| [spend-telemetry-report.test.sh](../tests/spend-telemetry-report.test.sh) | Tests for `spend-telemetry-report.sh` against a stub log in a temp `HOME` |
| [stale-cleanup.test.sh](../tests/stale-cleanup.test.sh) | Tests for `stale-cleanup.sh` |
| [state-lock.test.sh](../tests/state-lock.test.sh) | Tests for `state-lock.sh` |
| [statusline.test.sh](../tests/statusline.test.sh) | Tests for `statusline.sh` |
| [subagent-limit-park.test.sh](../tests/subagent-limit-park.test.sh) | Tests the reactive subagent-thread usage-limit park (#1618) against the real fenced bash in `.claude/reference/subagent-thread-limit-park.md` and `/go-on` — structured-signal detection with its text-only negative controls, the compare-and-set park claim and its adoption of an existing day-mode or sibling park, per-pipeline phase records, the reset-plus-2-minute wake with its thrash cap and weekly branch, stale-generation rejection, and fail-closed recovery |
| [table-freshness.test.sh](../tests/table-freshness.test.sh) | Tests for `table-freshness.sh` — the four `--check` verdicts, the tick's firing case with a negative control on each silent one, durability across a simulated compaction, and per-session clock isolation |
| [ts-normalizer-parity.test.sh](../tests/ts-normalizer-parity.test.sh) | Drift guard that `merge-gate.sh` and `escalate-review.sh` order the same timestamps identically |
| [unset-home-contract.test.sh](../tests/unset-home-contract.test.sh) | Shared unset-`HOME` contract for `reviewer-of.sh`, `session-state.sh`, `silence-watchdog.sh`, and `script-usage-report.sh` — `--help` answers, load-bearing runs exit 8 named, no fabricated `/.claude/...` paths (issue #1434) |
| [usage-horizon.test.sh](../tests/usage-horizon.test.sh) | Tests for `usage-horizon.sh` — threshold matrix, hysteresis, fail-closed paths, observe-then-check round trip |
| [worktree-isolation-shapes.test.sh](../tests/worktree-isolation-shapes.test.sh) | Tests `worktree-status.sh` and `wait-until.sh` — the issue #1470 command shapes |
<!-- catalog:rows:end -->

## Pointing a merge-gate suite at another checkout

The `merge-gate-*` suites resolve the scripts they exercise through overridable
variables (issue #1485). Each defaults to this checkout's copy, so a plain
`bash .claude/scripts/tests/<name>.test.sh` behaves exactly as before:

| Variable | Script | Suites |
|----------|--------|--------|
| `SUT` | `merge-gate.sh` | every `merge-gate-*` suite except `merge-gate-authorship` |
| `EVAL_SUT` | `review-substance.sh` | `merge-gate-codeant-run-marker`, `merge-gate-json-escaping`, `merge-gate-review-substance` |
| `MERGE_GATE` | `merge-gate.sh` | `merge-gate-authorship` (its own long-standing name) |

Setting one runs the suite's assertions against a different copy of the script.
That is how you get a **negative control** — evidence that the assertions a PR
adds genuinely fail against the code being replaced, rather than passing for some
unrelated reason:

```bash
# Extract the pre-change evaluator once...
git show <sha-before-the-change>:.claude/scripts/review-substance.sh > /tmp/eval-main.sh
chmod +x /tmp/eval-main.sh
# ...then run the suite against it.
EVAL_SUT=/tmp/eval-main.sh bash .claude/scripts/tests/merge-gate-codeant-run-marker.test.sh
```

Two things to know:

- **`merge-gate.sh` resolves `review-substance.sh` as its own sibling.** So
  `EVAL_SUT` steers only the cases that invoke the evaluator directly; cases that
  run through `merge-gate.sh` follow whatever sits next to `SUT`. Point both at
  the same foreign checkout for a whole-suite control.
- **A mistyped path exits 1** with `FAIL: <VAR> is not an executable file: …`.
  Without that guard a bad path would empty every invocation, fail every
  assertion, and look exactly like a successful negative control while proving
  nothing.

---

[← back to the index](../README.md)
