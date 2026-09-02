# Tests

All tests live in `tests/` and run offline (no network required). Run from the repo root:
`bash .claude/scripts/tests/<name>.test.sh`

| Test | What it covers |
|------|----------------|
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
| [checkpoint-handoff.test.sh](../tests/checkpoint-handoff.test.sh) | Tests the degrade ladder in `checkpoint-handoff.sh` — the emitted document must pass `portable-handoff-lint.sh` in any repository, harness-shaped filenames included |
| [chip-offer-registry.test.sh](../tests/chip-offer-registry.test.sh) | Tests for `chip-offer-registry.sh` — reservation, cap exhaustion, transitions, counting, concurrent emitters, TTL expiry, and the `--help` / `--emitter` allowlist drift guard |
| [churn-hotspot-wrap-plan.test.sh](../tests/churn-hotspot-wrap-plan.test.sh) | Tests `/wrap` hotspot suppression, material-growth, evidence, re-file, unknown-state, and aggregate classification |
| [churn-hotspots.test.sh](../tests/churn-hotspots.test.sh) | Tests for `churn-hotspots.sh` |
| [ci-status.test.sh](../tests/ci-status.test.sh) | Tests for `ci-status.sh` |
| [clean-behind-check.test.sh](../tests/clean-behind-check.test.sh) | Tests for `clean-behind-check.sh` |
| [compaction-resume-polling-state-gate.test.sh](../tests/compaction-resume-polling-state-gate.test.sh) | Tests `polling-state-gate.sh --verify-state` after synthetic post-compaction recovery |
| [cr-plan.test.sh](../tests/cr-plan.test.sh) | Tests for `cr-plan.sh` |
| [cursor-review-workflow-suppression.test.sh](../tests/cursor-review-workflow-suppression.test.sh) | Tests the one-nudge-per-HEAD guard in `.github/workflows/cursor-review-pr-comment.yml` |
| [diff-survival-check.test.sh](../tests/diff-survival-check.test.sh) | Tests for `diff-survival-check.sh` |
| [dirty-main-guard.test.sh](../tests/dirty-main-guard.test.sh) | Tests for `dirty-main-guard.sh` |
| [empty-array-expansion.test.sh](../tests/empty-array-expansion.test.sh) | Sibling-sweep regressions for the empty-array-under-`set -u` abort on bash 3.2 |
| [end-pause-contract.test.sh](../tests/end-pause-contract.test.sh) | Contract tests binding the `/end` and `/pause` skills, their resume companions, and the hooks and scripts they drive |
| [escalate-review-app-identity.test.sh](../tests/escalate-review-app-identity.test.sh) | Publishing-app identity and spoof-guard tests for `escalate-review.sh` |
| [escalate-review-bugbot-classification.test.sh](../tests/escalate-review-bugbot-classification.test.sh) | BugBot failure and response-classification tests for `escalate-review.sh` |
| [escalate-review-cr-retry-window.test.sh](../tests/escalate-review-cr-retry-window.test.sh) | CodeRabbit retry-window grace tests for `escalate-review.sh` |
| [escalate-review-gate-met.test.sh](../tests/escalate-review-gate-met.test.sh) | Approval freshness and gate short-circuit tests for `escalate-review.sh` |
| [escalate-review-head-observation-anchor.test.sh](../tests/escalate-review-head-observation-anchor.test.sh) | Head-observation anchor tests for `escalate-review.sh` — a force-pushed older commit must not make a prior-HEAD banner or `@cursor review` trigger read as fresh |
| [escalate-review-merge-gate-freshness-parity.test.sh](../tests/escalate-review-merge-gate-freshness-parity.test.sh) | Drift guard that `escalate-review.sh` and `merge-gate.sh` reach the same approval-freshness verdict on one PR state, in-place re-reviews included |
| [escalate-review-never-invited.test.sh](../tests/escalate-review-never-invited.test.sh) | Invitation, grace-window, and cache-state tests for `escalate-review.sh` |
| [estimate-resolve.test.sh](../tests/estimate-resolve.test.sh) | Tests for `estimate-resolve.sh`, including the empty-`GH_ARGS` unbound-variable regression |
| [fixpr-step3b-pushed-sha.test.sh](../tests/fixpr-step3b-pushed-sha.test.sh) | Static guard that `/fixpr` Step 3b passes the post-push `PUSHED_SHA` to `bugbot-refused-head.sh`, not the pre-push `HEAD_SHA` |
| [forgotten-pr-triage.test.sh](../tests/forgotten-pr-triage.test.sh) | Tests for `forgotten-pr-triage.sh` |
| [go-on-universal-resume.test.sh](../tests/go-on-universal-resume.test.sh) | Contract tests for `/go-on` as the universal resume front door — stoppage-class detection, precedence, refill-gate safety |
| [handoff-scoping.test.sh](../tests/handoff-scoping.test.sh) | Tests per-repo handoff path scoping in `handoff-state.sh` |
| [handoff-state.test.sh](../tests/handoff-state.test.sh) | Tests for `handoff-state.sh` |
| [help-output.test.sh](../tests/help-output.test.sh) | `--help` contract for every repo script (#1513/#1475) — repo-wide smoke sweep (exit 0, non-empty, silent stderr, never ends on a bare section heading) plus heading **and** body-content assertions for the 12 scripts whose extraction was BSD-fatal or truncating, with fixtures proving the checker rejects both pre-fix forms |
| [infer-pr.test.sh](../tests/infer-pr.test.sh) | Tests for `infer-pr.sh` |
| [issue-claim.test.sh](../tests/issue-claim.test.sh) | Tests for `issue-claim.sh` against a stateful `gh` stub, so a claim written by one run is read back by the next |
| [issue-dedup.test.sh](../tests/issue-dedup.test.sh) | Tests for `issue-dedup.sh` |
| [issue-maker-log-scoping.test.sh](../tests/issue-maker-log-scoping.test.sh) | Regression tests for the `/issue-maker` session log colliding across concurrent conversations |
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
| [overrun-check.test.sh](../tests/overrun-check.test.sh) | Tests `overrun-check.sh --readout-cells` — ET cell rendering, the pace-scaled overrun row, and the negative control proving the projected finish is floored at now |
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
| [ts-normalizer-parity.test.sh](../tests/ts-normalizer-parity.test.sh) | Drift guard that `merge-gate.sh` and `escalate-review.sh` order the same timestamps identically |
| [unset-home-contract.test.sh](../tests/unset-home-contract.test.sh) | Shared unset-`HOME` contract for `reviewer-of.sh`, `session-state.sh`, `silence-watchdog.sh`, and `script-usage-report.sh` — `--help` answers, load-bearing runs exit 8 named, no fabricated `/.claude/...` paths (issue #1434) |
| [usage-horizon.test.sh](../tests/usage-horizon.test.sh) | Tests for `usage-horizon.sh` — threshold matrix, hysteresis, fail-closed paths, observe-then-check round trip |

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
