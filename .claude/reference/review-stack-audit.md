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

The mitigation is the `unclassified` array. Limit-shaped language from a known
bot (`quota`, `usage limit`, `subscription`, `billing`, …) that no declared
pattern explains is reported. It is deliberately **not** counted as a cap — a
generic word is not evidence — but it is never dropped, and `drift.sh` turns a
non-empty array into a caveat on the whole run. "0 drift with 3 unclassified cap
candidates" is a materially weaker claim than "0 drift", and the user sees the
difference without opening the JSON.

That guarantee is per **signal**, not per comment (#1342). The probe used to be
skipped entirely once any declared pattern matched the body, so a banner that
announced a recognized cap *and* a second, unrecognized one recorded only the
first — and the more complete the phrase table got, the more bodies matched and
the less the audit could see. The probe now runs on every body, excluding the
spans a matched pattern already accounts for so the declared phrases' own
limit-shaped words (`…hit a usage or spend limit`) are not read back as unknowns.

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

## Value fields (issue #1810)

Counting findings says how loud a reviewer is, not how right. Every finding
already gets a verdict when an agent replies to its thread — `Fixed in <sha>`,
`Deferred to #N`, or a decline with a reason — and the ledger reads those
verdicts back instead of letting them vanish when the thread resolves. These
are the working definitions; the verdict buckets are the ones sales-kit
Issue #184's hand-built ledger used, so the two compare (differences below). The
fields land in the snapshot in ledger mode only; rendering them is increment 4
of Issue #1747.

### What a finding and a verdict are

A **finding** is a review thread whose first comment a review tool wrote
(GraphQL `reviewThreads`, first 100 comments per thread). Its verdict comes only
from the replies after that first comment written by a GitHub `User` account —
the same qualifying-reply rule as [deferred findings](review-policy.md#what-counts-as-a-follow-up-reply).
A bot's reply, the tool's own included, never decides a verdict; GraphQL bot
logins carry no `[bot]` suffix, so the account type is what is tested. Quoted
lines (`> …`) are skipped, so a reply that quotes the finding cannot borrow its
wording, its numbers, or a marker inside it.

Each reply is read, in order of precedence:

| Rule | Verdict |
|---|---|
| A marker `<!-- review-verdict: fixed\|deferred\|declined defect=real\|not agent=<name> -->` outside any code span or fenced block | the marker's verdict |
| The reply **starts** with `Declined`, `Not a defect`, or `Won't fix` (straight or curly apostrophe), after any leading @mentions, HTML comments, emphasis, or fenced code block | `declined` |
| `Fixed in <sha>` anywhere outside a fenced code block (7–40 hex digits; backticks and a `commit` word tolerated) | `fixed` |
| A follow-up link — `#N`, `owner/repo#N` for this repo, or an `/issues/N` URL | `deferred` |

Fenced blocks are read as CommonMark reads them: a fence closes on a line of
the same character (backtick or tilde) at least as long as its opener, and an
unclosed fence runs to the end of the reply. Emphasis is up to three `*` or `_`
characters (`***Declined***`, `_Won't fix_`).

Per thread, the **latest marker** wins over everything; with no marker, the
**latest reply whose wording matched** wins ("Fixed in…" then "Declined: on
reflection…" is declined); with neither, the thread is `unanswered`.

Two choices here are deliberate:

- **A leading decline beats a cited number.** Replies in this repo cite PRs as
  precedent ("Declined: same as the pattern in PR #1222"), and the follow-up
  parser cannot tell an issue from a PR without a lookup. The opening verb is
  the agent's stated disposition, so it wins. An agent deferring with a
  decline-shaped opening should lead with "Deferred to" or stamp the marker.
- **`deferred` is syntactic only.** The ledger reads links with the merge gate's
  own parser (`.claude/scripts/lib/deferred-refs.jq`, one shared file), but makes
  none of the gate's issue lookups: a batch audit over hundreds of threads should
  not carry that API cost or its failure modes. The gate still verifies every
  link it acts on.

A marker whose verdict is unknown is ignored and counted in a note; the reply is
then read by its wording. Only `defect=real` counts as a real defect — an unknown
or missing value reads as not real — and an `agent` outside a plain token shape
reads as unnamed.

### The marker

Real-defect judgment stays with the agent at reply time, which is where the
evidence is; no text heuristic guesses it afterwards. `defect=real` means the
test sales-kit Issue #184 §2.3 applied: as merged, the code or spec would have
behaved incorrectly, insecurely, or undefinedly for a reachable input (or led a
reader to build the wrong thing), and the fix closes a behavioral gap rather
than style drift.

`reply-thread.sh` writes the marker: `--verdict <v> --defect real|not` (plus
`--agent <name>`, default `claude-code`) appends it as its own line after the
reviewer's @mention rules run; without the flags a reply is byte-identical to
before. A reply that ends inside an open fenced block gets that fence closed
first, so the marker never lands in code where the ledger would skip it. The
`agent` field is recorded so a later study can split results by
coding agent without a second collection pass; this increment does not
aggregate by it.

### The fields

| Field | Definition |
|---|---|
| `findings` | Threads whose first comment the tool wrote |
| `valid` | `fixed` + `deferred` |
| `real_defects` | Threads whose deciding marker says `defect=real`. A valid finding without the marker is not a real defect |
| `declined`, `unanswered` | The other two verdicts |
| `precision` | `valid / (valid + declined)`, 3 decimals; `null` when both are 0. Unanswered findings are left out: no verdict is not a no |
| `cost_per_real_defect_usd` | `spend_usd / real_defects`, in cents; `null` when either is null or 0 — a $0.00 receipt floor per defect would read as free |
| `median_response_min` | The median, over the PRs the tool reviewed or commented on, of the minutes from the start of its clock to its first review or comment |

The clock starts at the earliest **trigger comment** for that tool that precedes
its first response, and at PR open otherwise — so a tool that reviews at open on
its own is never timed from a later re-request. Triggers are non-bot PR
conversation comments outside quoted lines: `@coderabbitai review` or `@coderabbitai
full review` (CodeRabbit), `@cursor review` (BugBot), `@codeant-ai review`
(CodeAnt), `@graphite-app re-review` (Graphite), any `@greptileai` mention
(Greptile). Vercel has none. A PR the tool cannot be timed on is left out of the
median and counted in a note: one where any of its responses has no timestamp
(that response may have been the first, so a later dated one never stands in),
or one with nothing to start from.

Multi-repo totals are recomputed, never averaged: counts are summed, precision
comes from the summed counts, the median pools every repo's response times, and
the cost divides the total spend. Each repo's cost divides its own share of a
flat fee after the split.

### Limits

- **The sample is the PRs, not the window.** Threads are read for every PR the
  run samples (merged in the window, up to `--limit`), whenever the reply came;
  spend is timed by event inside the window. At the window's edges the two do
  not line up exactly, so cost per real defect is an approximation there.
- **100 comments per thread.** A reply past the 100th is unseen; a thread that
  long is counted in a note.
- **Fallback replies are outside the thread.** `reply-thread.sh` posts a PR-level
  comment when the inline reply 404s, and the ledger reads only thread replies,
  so that finding reads `unanswered`.

### Comparing with sales-kit Issue #184

Shared: the four outcomes (fixed, deferred, declined, unanswered), valid as
fixed plus deferred, and the real-defect test above. Different, and worth
reading before putting the two side by side:

- **Spend.** sales-kit Issue #184's headline cost per real defect uses
  **marginal** spend, the extra cost a review added. That is why it shows
  CodeAnt at $0.00 — the seat is paid either way. This ledger reports CodeAnt's
  **prorated flat** fee (the `flat` label), so its CodeAnt figure is not $0.00
  and is not comparable with that marginal one.
- **Who judged real.** That ledger classified real defects afterwards, by a
  verifier pass, so a real defect could be unanswered or declined. Here only the
  replying agent's marker makes one, so a finding nobody stamped is never real.
- **What a finding is.** That ledger also counted findings written in a review
  body; this one counts review threads only.

## What this audit will not do

It never edits a rule, skill, script, or config, and never touches a
subscription. Its whole output surface is a snapshot, a report, and GitHub
issues. Billing actions belong to the person holding the card; the audit's
contribution is saying "this looks like a bill with no return" early enough to
matter.
