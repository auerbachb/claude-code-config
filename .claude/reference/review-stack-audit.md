# Review stack audit — mechanism and contracts

Mechanism, rationale, and the decision-record contract behind
`/review-stack-audit` (issue #1201). Not auto-loaded: the operative contract is
`.claude/skills/review-stack-audit/SKILL.md`, and the two engines document their
own interfaces under `--help`. This file holds the reasoning that would
otherwise bloat either.

## Why a recurring audit at all

`.claude/reference/ai-review-tool-audit-2026-04.md` and `-2026-06.md` are two
hand-run instances of this audit. They worked — the 2026-06 pass caught CodeAnt's
exhausted trial while it was the merge gate's only approver, and cut a $30/mo
Greptile seat that had not fired in eight weeks. But each was a one-off, and the
2026-06 doc closes by naming a successor (`ai-review-tool-audit-2026-08.md`) that
nothing was scheduled to write.

That is the failure mode: an audit that depends on someone remembering. Between
audits, the gap between what we pay for and what the workflow assumes reopens
silently, and surfaces as PRs queuing on review rather than as a line item.

## Why a sibling skill rather than a section of `/harness-audit`

`/harness-audit` asks *"does the harness already do this natively?"* — internal
redundancy against a moving upstream. This asks *"does this external spend still
buy value?"* Different inputs (GitHub review activity and vendor billing signals
vs. harness release notes), different verdicts (roles and subscriptions vs. keep
/redundant/conflicting), different remedy owners (the person holding the credit
card vs. whoever edits the rule corpus).

Folding them together would give one skill two inventories and two verdict
vocabularies. They share the *shape* — monthly, advisory, issue-filing,
watermark-driven — and that shape is deliberately copied, which is why the
session-start nudge and the exact-marker dedup are near-identical. CodeRabbit's
plan for #1201 reached the same conclusion independently.

## Why the judgment is one pass, not two

`/harness-audit` splits into a cheap inventory tick and an expensive top-tier
judgment pass reached by a chip, because verdicting ~100 artifacts against live
harness behavior needs real reasoning per artifact.

This audit does not. Measurement is a script, and the comparison is a bounded
diff of two JSON documents over six tools and five rules — `drift.sh` does it
deterministically with no model in the loop. Issue #1201's AC4 ("a no-drift run
completes in one invocation and reports 'no change' in a single line") makes the
single pass a requirement rather than a preference: a chip handoff cannot satisfy
it. The cost of that choice is that the tick does real work; the benefit is that
a quiet month costs one invocation and one line of output.

## Billed state is a proxy, and says so

No vendor in this stack exposes a billing API these scripts can read. Three
things are readable, and the audit is careful about which is which:

| Signal | Source | Trust |
|---|---|---|
| `plan_observed` | The tier a vendor states in its own comment body. Only CodeRabbit does (`> **Plan**: Pro`). | Direct, but only for vendors that volunteer it. |
| `cap_signals` | Limit messages that appear when a plan runs out. | Direct evidence of a limit *being hit*; silence is not evidence of headroom. |
| `billed` | A human-maintained field in the baseline. | Authoritative by declaration, stale by default. |

The audit's job is to notice when these disagree. D2 ("paid but unused") fires
entirely on the declared field, which is why the seeded baseline leaves Greptile
as `paid` even though the 2026-06 audit recommended cancelling: cancellation is a
billing action outside the repo and was never confirmed. If the seat is live, D2
asks the question; if it was cancelled, the answer is one comment and a
one-word baseline edit. For a recurring charge, failing toward surfacing is the
correct direction.

## Why classifiers are grounded, and what happens when they rot

The `CAP_SIGNALS` table in `measure.sh` was extracted from 4,632 real bot
comments on this repo's 25 most recently merged PRs, not written from memory.
Each entry carries the observation that justifies it.

A phrase table is exactly the kind of thing that rots silently: a vendor rewords
its limit message, the pattern stops matching, and every affected tool reads
`active` forever. That failure is indistinguishable from good news, which makes
it the worst possible failure for this audit.

The mitigation is the `unclassified` array. Any comment from a known bot that
looks limit-shaped (`quota`, `usage limit`, `subscription`, `billing`, …) but
matches no declared pattern is reported. It is deliberately **not** counted as a
cap — a generic word is not evidence — but it is never dropped, and `drift.sh`
turns a non-empty array into a caveat on the whole run. "0 drift with 3
unclassified cap candidates" is a materially weaker claim than "0 drift", and the
user sees the difference without opening the JSON.

**One repo-specific caveat:** this repo's own subject matter *is* rate limits and
quotas, so bot comments reviewing our prose about caps land in `unclassified`
routinely. That is a true positive for the mechanism and a false alarm for the
question. Expect a small standing count here; a sudden jump is the signal.

Vendor boilerplate is stripped before the generic probe (collapsed `<details>`
blocks and CodeRabbit's `tips_start`/`tips_end` region), because both mention
limits routinely and would otherwise drown the report. Declared classifiers still
run against the **raw** body, so machine markers written as HTML comments — the
most reliable signals available — still match.

## `gates_merge` and `approves_via` are separate fields

The baseline records both, and collapsing them produces a permanent false
positive whichever way you collapse:

- **`gates_merge`** — would a cap here stall PRs? Drives D3's severity.
- **`approves_via`** — should this tool be posting `APPROVED` review objects?
  The only trigger for D4.

BugBot is why. A clean BugBot pass on current HEAD satisfies the merge gate alone
on its path (`bugbot.md` §Merge Gate), so a spend cap on it is a high-severity
problem — but it signals that pass through the `Cursor Bugbot` check-run and
posts no `APPROVED` review object. Drive D4 off `gates_merge` and BugBot is
flagged for a missing approval every single run; drive D3's severity off
`approves_via` and a cap on the gating fallback reads as routine.

CodeRabbit is the mirror case: it *can* satisfy the CR path with an `APPROVED`,
but the 2026-06 audit measured 0 approvals across 63 PRs and concluded it is a
finder, not an approver. The baseline records that measured reality
(`gates_merge: false`, `approves_via: "none"`), so the audit does not spend every
month reporting a fact we already decided about.

### Why the absent-field default does not include `primary`

`approves_via` is optional; when absent it is inferred from the role, and the
inference is `"review"` only for role `approver`. A pre-merge review of #1201
proposed widening that to `role in ("approver", "primary")`, on the reasoning
that any role gating the merge in practice should get D4 by default.

**Declined, because CodeRabbit is exactly that case and the widening breaks it.**
CodeRabbit's role is `primary` and it was measured issuing zero approvals; infer
`"review"` there and D4 fires against it on every run, forever — the permanent
false positive the two-field split was introduced to eliminate. The proposal
trades a silent gap for a guaranteed false alarm, and a check that cries wolf
monthly gets ignored faster than one that is quietly off.

The underlying concern was real, though: a future baseline author writing
`role: "primary"` without the field silently disables the check that catches the
merge gate's approver going quiet, and nothing said so. The fix is therefore to
make the inference **visible** rather than to change what it infers — `drift.sh`
emits a note naming every tool whose `approves_via` was inferred and what it was
inferred to, flagging that D4 does not run for any of them. The gap can still
exist; it can no longer exist unannounced.

## The decision-record contract (#1199)

`/review-stack-audit` reads its baseline from
`.claude/reference/review-stack-baseline.json`, schema
`review-stack-baseline/v1`. Fields are documented in `drift.sh --help`.

**#1199's decision record writes to that path.** It should replace the `tools`
array and set `source.provenance` to `"decision-record"` with `source.record`
pointing at the prose document. The file shipped with #1201 is marked
`"provenance": "seeded"` and carries the 2026-06 audit's verdicts, so the skill
has a real baseline before #1199 lands.

That seeding is the deliberate departure from CodeRabbit's plan, which had the
audit stop with "baseline missing — depends on #1199". Three reasons it does not:

1. #1199 was open with no PR when #1201 was built. A hard stop ships a skill that
   cannot run at all.
2. AC3 requires *each run* to append a dated snapshot. A stop produces none.
3. AC4 requires a one-invocation run reporting in a single line. A stop is not
   that run.

Bootstrap mode (no baseline resolvable at all) remains as the third rung: publish
the snapshot, file nothing, report that a baseline was established. A first run
with nothing to compare against has still done its job — it created what every
later run needs.

## Dedup: two layers, and why both

**Layer 1, the marker, is the authority.** `<!-- review-stack-audit: <tool>/<code> -->`
keys on `(tool, code)` and nothing else. The same unresolved drift re-found next
month produces a byte-identical string, which is what makes issue #1201's Test
Plan item 3 (a second consecutive run files no duplicate) deterministic rather
than probabilistic. Nothing that moves month to month — the window, a count, a
date — may enter the key, and there is a test asserting the marker survives a
moved window.

Compare the **fully-substituted** marker by string equality, never the
`<!-- review-stack-audit:` prefix. `/harness-audit` hit this on its first live
run: its own tracking issue documented the convention, so it contained the
template text, and a prefix match read that as an existing filing for every
artifact. This document and `SKILL.md` both contain such text.

**Layer 2, `issue-dedup.sh`, is recall.** The marker cannot find an issue a human
filed by hand about the same drift. AC2 names the helper explicitly, and it is
strictly additive. Its exit ≥ 2 is a *degraded* lookup, never "no duplicate" —
it blocks the filing exactly like a saturated search, because a duplicate filed
on an unverified lookup is worse than a filing deferred.

A saturated `gh issue list` (exactly `DEDUP_LIMIT` rows) is likewise a failed
lookup, not a clean one: the page was truncated and the issue you needed may be
the one that was cut.

## Cadence without a durable scheduler

This setup has no durable scheduler it trusts. `CronCreate` is session-scoped and
in-memory (`cross-session-durability.md`, #827), so a monthly job armed today is
gone by tomorrow — and a monthly audit that silently never runs is the worst
possible outcome for a skill whose entire job is noticing silent staleness.

The watermark file is durable, and `session-scheduling-reconcile.sh` reads it on
every session start. Sessions start far more often than monthly, so a month
cannot be missed. The review-stack block there is `2a-bis`, deliberately adjacent
to `/harness-audit`'s `2a` and computing its own `RS_MONTH` rather than reusing
`MONTH`, which only exists when the harness-audit watermark does.

Its state machine is simpler than `/harness-audit`'s: **off / done / due**, with
no `offered` state, because its tick runs the real comparison instead of offering
a step-up chip. A corrupt watermark reads as `off` — fail-soft and silent, never
as `due`, so a garbled file cannot nag every session start.

## Feeding issue #1191

Each run's Throughput section restates PRs and reviews per day for the window.
Issue #1191's concurrent-work cap derives from review throughput, and this is the
surface that refreshes that figure. It is stated in the report rather than left
inside the snapshot JSON so the number is readable without tooling.

## What this audit will not do

It never edits a rule, skill, script, or config, and never touches a
subscription. Its whole output surface is a snapshot, a report, and GitHub
issues. Billing actions belong to the person holding the card; the audit's
contribution is saying "this looks like a bill with no return" early enough to
matter.
