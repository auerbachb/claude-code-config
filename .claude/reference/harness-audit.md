# `/harness-audit` — mechanism and rationale (#770)

Full design record for the monthly harness-redundancy audit. Not auto-loaded, so
it carries the reasoning the rule corpus cannot afford. The operational
procedure lives in `.claude/skills/harness-audit/SKILL.md`; this file explains
why it has the shape it does.

## The problem it exists for

Every rule, skill, script, and hook in this repo was written to make Claude Code
do something it did not do on its own **at the time**. The harness ships
continuously — each release automates more and adds first-class surfaces that
overlap with what we built by hand. Nothing in the workflow ever asked whether
that had happened.

The cost is not just clutter. It compounds three ways:

1. **The corpus is budgeted.** `CLAUDE.md` + `.claude/rules/` load on every turn
   under a 12,000-word soft cap and a committed ratchet. A redundant paragraph
   does not merely sit there — it evicts one that still earns its place.
2. **Redundant instructions actively misfire.** When our rule and a harness
   default describe the same behavior in slightly different words, the model
   gets two subtly conflicting sources. Literal-following models pick one, and
   not reliably ours.
3. **Staleness self-certifies.** The longer a dead rule sits unchallenged, the
   more confidently it reads as deliberate, and the less likely anyone is to
   remove it.

## Why two passes

The audit splits into a cheap **inventory** pass and an expensive **judgment**
pass. The split is forced by a constraint, not chosen for elegance.

The judgment is genuinely hard. Distinguishing *"the harness does this now"*
from *"the harness looks like it does this but ours is stricter"* is exactly the
reasoning that degrades on a cheaper tier — and the failure is asymmetric and
silent: a wrong `redundant` deletes a load-bearing guard, and the report reads
just as confidently either way. So the judgment wants the top of the fleet.

But `subagent-orchestration.md` reserves the top tier for **interactive step-ups
where a human watches the spend**, and states it is never a spawn default. A
monthly tick quietly burning top-tier tokens unattended contradicts that rule's
*stated harm model*, not merely its wording.

Issue #770 offered two resolutions: (a) carve a narrow exception into the rule,
or (b) have the tick do the cheap pass and *offer* the expensive one. **We took
(b).**

Why (b) over (a):

- The invariant's rationale (`agents/README.md`) is specifically about unattended
  spend with nobody watching. An unattended tick is the purest instance of that. An exception
  would contradict the reasoning while satisfying the letter — the worst kind of
  carve-out, because the next reader inherits a rule whose stated reason no
  longer matches its scope.
- Option (b) leaves **the invariant itself untouched**, in a corpus with roughly
  40 words of headroom. `subagent-orchestration.md` gained one short clause
  noting that this skill honors the invariant via a step-up chip — a pointer, not
  an amendment. Option (a) would have had to *weaken* the invariant's scope,
  which costs more words and, worse, leaves the next reader a rule whose stated
  reason no longer covers its exceptions.
- A human clicking a chip is precisely the "interactive step-up where a human
  watches the spend" the invariant describes. (b) does not evade the rule — it
  satisfies it exactly.

The cost of (b) is that an ignored chip means no audit that month. That is
acceptable: an audit nobody reads has no value either, and the report is advisory
by design.

## Why the model tier is resolved, not written

`.claude/model-fleet.json` + `.claude/scripts/model-fleet.sh` exist because this
skill's model recommendation is definitionally *"whatever the strongest model is
right now"* — not a judgment about the task. A literal would be correct on the
day it was written and wrong at the next fleet change, which is exactly what #749
had to repair across several surfaces at once.

The resolver **fails closed**: a missing file, malformed JSON, an absent
`top_tier`, or a `top_tier` not present in `fleet[]` all exit non-zero with a
specific message. There is deliberately **no fallback model name anywhere in the
script**. A silent degradation to a stale hardcoded default would defeat the
entire purpose of having one source, so the resolver would rather stop its caller
than answer wrongly.

`chip-model-guard-lint.sh` enforces the design as a **resolver emitter class**:
`/harness-audit` must reference the resolver, must carry the pre-click warning,
and must contain **no model literal**. That last check is inverted relative to
the other five emitters and is strictly stronger — the class table is in
`chip-launching.md`.

Migrating `/prompt`, the chip `**Model:**` lines, and `.claude/agents/*.md` off
their own literals is deliberately **out of scope** here and tracked in #749.
This PR introduces the source and one consumer.

## Why a session-start check for a monthly audit

The audit needs a cadence measured in weeks, and `CronCreate` — the scheduler
this skill used — does not last that long. It is in-memory and dies at session
exit; its 7-day expiry means even a literal monthly cron could lapse before
firing. Both failure modes are *silence* — the worst possible outcome for a
skill whose entire job is noticing silent staleness. (A durable scheduler *does*
exist in the harness; the separate reason this skill declines it is in
`.claude/reference/cross-session-durability.md`.)

An earlier design worked around this by registering the job **daily** and gating
on a monthly watermark, reasoning that seven daily chances would catch an
expired job inside the expiry window. That reasoning assumed the job outlived
the session, which it never did (issue #808, corrected in PR #825): a daily
re-registration only ever fired inside the session that armed it.

Issue #827 replaced the scheduler with the thing that is actually durable. The
watermark file already persists and already records everything the cadence
needs, so the tick moved to **session start** — `session-scheduling-reconcile.sh`
reads the watermark on every session start and nudges when the month is due.
Sessions start many times a day, so a month cannot be missed, and there is no
job id, expiry window, or `CronList` reconciliation to get wrong. `--arm` and
`--stop` toggle `nudge_enabled` in the same file.

Why not the genuinely durable scheduler the harness *does* provide
(`mcp__scheduled-tasks__*`): `.claude/reference/cross-session-durability.md`.

### Two watermarks, not one

`~/.claude/harness-audit/last-run.json` holds both:

| Field | Set when | Prevents |
|-------|----------|----------|
| `last_completed_month` | A judgment pass finished (including `--report-only`) | Re-auditing a month already done |
| `last_offered_month` | A step-up chip was successfully spawned | Re-offering the same chip on every session start |

One field alone forces a choice between two bad behaviors. Set it on offer, and
an unclicked chip marks the month done when nothing was audited. Set it only on
completion, and an ignored chip is re-offered every session until someone clicks it out
of irritation. Two fields make "offered but not yet done" a representable state,
which is what it actually is.

`--report-only` sets `last_completed_month` deliberately: a dry run still
produced verdicts, so the month's question has been answered. It just filed
nothing.

## Why the report defaults outside the repo

The CR plan for #770 had every run write `.claude/reference/harness-audit-YYYY-MM.md`.
That is wrong for the unattended path.

A tick can land in a session sitting on the **root repo, on `main`**.
Writing a report there puts changes on `main` — against `CLAUDE.md` §ALWAYS USE A
WORKTREE — and trips `dirty-main-guard` on the next session start. The tick would
be manufacturing exactly the dirty-main state another part of the harness exists
to clean up.

So the default destination is `~/.claude/harness-audit/harness-audit-YYYY-MM.md`,
outside the repo, touching no git state. `--report-to-repo` writes into
`.claude/reference/` and refuses unless cwd is a worktree that is **not** the root
repo, on a branch that is **not** `main`. Landing a report in the repo stays a
deliberate, human, PR-shaped act.

## Why exact-artifact dedup

Every finding names one unambiguous path, so `/harness-audit` uses the
exact-artifact variant of `autofile-dedup.md` rather than `issue-dedup.sh`'s
strong/weak/none scoring — the same mechanism `/wrap`'s churn hotspots use.

Fuzzy coverage scoring would be wrong in both directions here. Our rule files
share vocabulary heavily by design (they cross-reference each other constantly),
so `.claude/rules/cr-merge-gate.md` and `.claude/rules/cr-github-review.md` score
as near-neighbors — a sibling match would suppress a real finding. And the
genuine prior issue about the exact same path can be missed, filing a duplicate.

Key: title `Harness redundancy: <path>` compared by client-side string equality,
plus body marker `<!-- harness-audit: <path> -->` that survives a human
retitling. Search is recall only. **A failed lookup blocks filing** — the finding
is surfaced and reported rather than risked as a duplicate.

## The verdict bar, and its deliberate asymmetry

Three verdicts: `redundant`, `conflicting`, `keep`. The interesting rule is the
one that constrains the first:

> **Stricter than the harness default is never `redundant`.**

The worked example is `safety.md`'s authorship guard, which restricts automated
PR writes to PRs authored by the authenticated user. The harness has PR tooling
and permission modes, so a reading that stops at *"the harness handles PR
operations now"* would call the guard redundant — and delete a rule whose entire
value is the narrower thing it forbids. The harness has no per-PR **author**
gate. Correct verdict: `keep`.

Three more calibrations in the same direction: same behavior with a tighter
trigger is `keep`; a harness feature behind an opt-in we do not enable is `keep`;
and a rule that duplicates a mechanism but carries load-bearing rationale is
`keep` unless that reasoning lives elsewhere.

**Uncertainty resolves to `keep`**, always — the same asymmetry
`autofile-dedup.md` reasons from. A wrong `redundant` costs a guard; a wrong
`keep` costs one line of report.

## Live sources only

Model memory is **forbidden** as a source. Training cutoffs are exactly the
mechanism that makes stale confidence feel like knowledge — which is the failure
this audit exists to catch in our files, and would be absurd to reproduce in the
audit itself.

Preference order: the `claude-code-guide` agent, then official docs and release
notes via `WebFetch`/`WebSearch`, then observable local behavior (evidence about
*this session's* configuration only). Every verdict records
`{kind, ref, checked_at}`.

When no live source settles a question, the verdict is downgraded to `keep` and
flagged `unverified`, with the unanswered question written out. Never a guess.

## Completeness is a gate, not a goal

The skill asserts `verdicts == inventory count` **per category** and fails loudly
on any gap, naming the missing paths and filing nothing.

This exists because the natural failure mode of a long audit is quiet truncation
— a report covering 40 of 128 artifacts looks exactly like a thorough one, and
its silence about the other 88 reads as "nothing to report." `inventory.sh`
emits the counts precisely so that claim becomes checkable rather than asserted.
Its exclusions (`lib/`, `tests/`, `README.md`) are **declared in its output** and
quoted in the report, so even the skipped paths are visible.

## Self-audit

The skill inventories `.claude/skills/`, which now contains `harness-audit`
itself, plus `model-fleet.sh` and `inventory.sh`. It verdicts them like anything
else — a skill that exempted itself from its own question would be its own best
finding.

The single carve-out is at the filing step: it does not open an issue about its
own files while they are still unmerged on the first run, since there is nothing
yet for a reader to act on.

## References

- Issue [#770](https://github.com/auerbachb/claude-code-config/issues/770) — this work
- Issue [#749](https://github.com/auerbachb/claude-code-config/issues/749) — model-literal migration across the remaining surfaces
- `.claude/skills/harness-audit/SKILL.md` — the procedure
- `.claude/reference/chip-launching.md` — chip mechanics; the literal-vs-resolver emitter classes
- `.claude/reference/chip-model-guard-decision.md` — the #770 resolver amendment
- `.claude/reference/autofile-dedup.md` — the exact-artifact dedup contract
- `.claude/rules/scheduling-reliability.md` — scheduling primitive selection and the pre-exit checklist
- `.claude/rules/subagent-orchestration.md` — the top-tier spawn invariant this design preserves
- `.claude/reference/harness-model-audit-2026-06.md` — the closest prior precedent (harness components vs model fleet, #49)
