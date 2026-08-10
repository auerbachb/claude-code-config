# Model-Fleet Drift Guard Decision (#752)

## Decision

**Build a generational deny-list lint that auto-runs under the existing `rule-lint` required check.**

The guard flags enumerated legacy model versions matching `(Opus|Sonnet) 4.<digit>` (e.g. `Opus 4.8`, `Sonnet 4.6`) in live surfaces only — `.claude/rules/`, `.claude/skills/`, `.claude/agents/`, and `CLAUDE.md` — exempting the entire `.claude/reference/` tree. It fails **open**: a stale deny-list misses future drift rather than blocking unrelated PRs. No per-release editing is required for within-generation bumps.

**CI wiring — auto-discovery substitution (override of CR plan):** The CodeRabbit implementation plan said "wire into `rule-lint.sh` as a delegated sub-check." That approach is overridden: `.github/scripts/rule-lint.sh` is agent-unwritable. Instead, the script is named to match the `.github/scripts/*-lint.sh` glob auto-discovered by `run-doc-lints.sh` (PR #1147). Outcome is identical — the guard runs under the same `rule-lint` required CI check — with no protected-file edits.

## Rationale

The drift has recurred twice: Issue #547 (generation N) and Issue #749 (generation N+1). Both times it was noticed **weeks later**, by a human spotting a stale model name in a chip. The chip model guard (Issue #731) compares strings, so a stale recommendation does not degrade quietly — it **blocks the launched thread outright**. That makes drift expensive, which makes the case for catching it at PR time instead.

**Why generational, not per-version:**
Issue #749's reconciliation itself set the precedent: it moved `/prompt`'s Legacy list from enumerated versions (`Opus 4.8 / 4.7 / 4.6`) to a generation token (`Opus 4.x`). A deny-list built on the same idea — flag `(Opus|Sonnet) 4.<digit>` — catches every 4.x enumerated version without ever needing to know which specific sub-version existed. The `4.x` generational prose in `/prompt` correctly passes (x is not a digit). `Haiku 4.5` correctly passes (Haiku is not in the pattern; it is the current fleet member, not a legacy one). Dated `.claude/reference/` records correctly pass (entire directory excluded by design).

**Fails-open trade-off:** If a future generation drifts but the deny-list is not yet extended, the guard misses it — the same outcome as today's manual process. It never blocks an unrelated PR. An allow-list would invert this: a stale list fails closed, blocking unrelated PRs until hand-edited at each fleet bump, which relocates the maintenance burden rather than removing it.

**One bounded maintenance cost:** At the next cross-generation fleet bump (e.g. when 5.x becomes legacy), the deny-list pattern is extended by one line. This is explicitly accepted per the acceptance criteria ("maintenance cost is explicitly accepted and documented"). The cost is O(1) per generation, not per version.

## Explicitly Rejected

**Allow-list approach** — enumerate the current fleet; flag anything outside it. Rejected because it fails *closed*: a stale list blocks unrelated PRs until someone hand-edits it at every fleet bump. It relocates the maintenance burden rather than removing it, and it is strictly harder to maintain than the deny-list for the same drift-detection coverage.

**Won't-fix outcome** — record the reasoning and close, accepting continued hand-catching. Rejected because the recurrence rate (two occurrences, Issue #547 and #749), the multi-week detection lag both times, and the hard-blocking failure mode via the chip model guard (Issue #731) together clear the bar for small machinery.

**Wiring into `rule-lint.sh` directly** — the CR plan's preferred approach. Overridden: `.github/scripts/rule-lint.sh` is agent-unwritable (config-protection hard-deny on the `.github/scripts/` path). The auto-discovery substitution via PR #1147's `run-doc-lints.sh` delivers the same outcome with no protected-file edits.

## References

- Issue [#752](https://github.com/auerbachb/claude-code-config/issues/752) — this decision
- Issue [#749](https://github.com/auerbachb/claude-code-config/issues/749) — the fleet reconciliation this was deferred from; established the generational-prose precedent
- Issue [#547](https://github.com/auerbachb/claude-code-config/issues/547) — the previous generation's drift, fixed the same way
- Issue [#731](https://github.com/auerbachb/claude-code-config/issues/731) — the chip model guard that makes stale names hard-blocking rather than silent
- PR [#1147](https://github.com/auerbachb/claude-code-config/pull/1147) — introduced `run-doc-lints.sh` auto-discovery, enabling this wiring substitution
- `.github/scripts/model-drift-lint.sh` — the guard implementation
- `.github/scripts/tests/model-drift-lint.test.sh` — test coverage
- `chip-model-guard-decision.md` — house style this record follows (`## Decision / ## Rationale / ## Explicitly Rejected / ## References`)
