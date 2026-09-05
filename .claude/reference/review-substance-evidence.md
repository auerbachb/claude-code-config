# Review substance — why a bot `APPROVED` is not automatically review coverage

Mechanism and evidence behind issue #875. Not auto-loaded; `cr-merge-gate.md`
Step 1 carries only the one-line rule.

## The failure

`merge-gate.sh` set `primary_review_met: true` on any bot `APPROVED` whose
`commit_id` matched HEAD. It checked SHA freshness (#836) and same-SHA
retraction, but never asked whether the approval represented an actual review.
`auerbachb/meeting_insights_and_actions#134` merged 539 lines of deploy tooling
on exactly that signal, and every Phase B agent in those sessions had to be told
in its prompt not to trust the gate's verdict.

## Observed traces

| PR | SHA | What happened |
|---|---|---|
| mia#171 | `3634336` | CodeAnt `APPROVED`, `bodylen=0`, 62 s post-push, status comment still naming the previous SHA `98f0bd0` |
| mia#172 | `d5976d8` | CodeAnt `APPROVED`, `bodylen=0`, 8 s post-push, status comment naming `396ced5` |
| mia#172 | `476798e` | CodeAnt `APPROVED` `bodylen=0` naming `cb1f770`; CodeRabbit `APPROVED` `bodylen=0` one minute after its own CLI reported an org-wide rate limit |
| mia#172 | `396ced5` | CodeRabbit `APPROVED`, `bodylen=0` — **but genuine**: its comment named the exact `95febff…396ced5` range, listed all 3 changed files, carried an accurate walkthrough |
| ccc#867 | `f54effb7` | CodeAnt `APPROVED` at 06:24:44Z; its own "CodeAnt AI is running the review" marker at 06:24:50Z — **six seconds later**; and "User … does not have a PR Review subscription" 11 s *before* the approval. Same inversion on the prior SHA `5a4a9d8d` (approved 06:18:05Z, marker 06:18:22Z) |
| ccc#883 | 5 SHAs | **This PR, during its own review.** CodeAnt `APPROVED` every SHA with `bodylen=0` — once **four identical approvals in the same second** (`8ef311a`, 07:50:35Z), never once updating the status comment past `a1c03ed`. On `e1cccbb` it approved 6 s after the push at 08:20:54Z and posted "CodeAnt AI is running the review" at 08:22:17Z — **83 s later** — then completed a real review that named no SHA at all. Caught live by this file's own evaluator: `temporal_inversion`, `self_report_mismatch`, `no_substantive_footprint`. Meanwhile GitHub's `reviewDecision` read `APPROVED` throughout |
| ccc#923 | `d04389e` | CodeAnt posted a substantive Sequence Diagram summary after its current-round run-start marker, accurately describing the UUID-fragment guard, but its simultaneous empty `APPROVED` stayed hollow because the summary did not repeat HEAD's SHA |

## Why body length alone was rejected

The `396ced5` row is the whole reason the obvious fix ("reject empty-bodied
approvals") is wrong. That review carried its substance in a sibling comment
rather than in the review body, and rejecting it would have blocked a real merge.

A gate that wrongly reports `met: false` is not the safe failure mode here: it
blocks real work and trains people to bypass the gate. False negatives cost as
much as false positives, so the evaluator errs toward *reporting* quality
(`review_evidence`) rather than refusing.

## Signals, in order of decisiveness

Implemented in `.claude/scripts/review-substance.sh` (pure evaluator; no network
— callers pass payloads they already fetched).

1. **Temporal inversion.** The `APPROVED` predates the *earliest post-push*
   "is running the review" marker from that same reviewer, **and** that reviewer
   left no evidence outside the approval object that it read this commit. A
   review that had not started cannot have finished; it is a pure ordering
   violation with no plausible innocent shape.
   *Earliest*, not latest, is load-bearing: a re-review kicked off **after** a
   genuine approval posts its own start marker, and keying off the latest marker
   would read that as an inversion. Requires the HEAD committer date; when that
   is unavailable the check is skipped rather than guessed, so a transient API
   failure cannot invent a blocker.
   The suppressing term is `external_evidence_on_head` — inline comments on HEAD,
   a status comment naming HEAD, a descriptive current-round comment, or a
   substantive non-`APPROVED` review — and it is deliberately **not** bounded
   relative to the approval timestamp.
   Both halves were review findings on PR #883 itself, pulling in opposite
   directions, and both are right:
   - Keying off the approval's *own body* is circular (CodeAnt): the body is the
     thing under suspicion, so a verbose rubber stamp posted before its own start
     marker would exonerate itself and inversion could never fire on it.
   - Requiring that external evidence *predate* the approval breaks the genuine
     `396ced5` shape (BugBot): CodeRabbit's `bodylen=0` approval whose walkthrough
     lands moments later. Evidence that the reviewer really did read this SHA
     redeems the approval whenever it arrives — the same "later real work wins"
     rule signal 2 already applies to a temporary rate limit.

   What survives both: an approval with no inline comments and no status comment
   naming HEAD, posted before that bot said it had started. That is the ccc#867
   shape, and it stays disqualified.
2. **Capability failure.** The reviewer said on this SHA that it could not review
   ("does not have a PR Review subscription", rate limit, "couldn't run"), and
   left no evidence outside the approval object that it read the commit anyway.
   The clearing term is `external_evidence_on_head` — the same one signal 1 uses,
   for the same two reasons (BugBot, PR #883):
   - The approval's **own body** must not clear the failure. It used to: the
     body's timestamp counted as post-failure evidence, so a long generic
     `APPROVED` posted right after a "cannot review" notice cleared
     `capability_failure` and took `counts_as_coverage` with it. That is the
     mia#172 `476798e` trace with a non-empty body.
   - Genuine external work redeems the approval whenever it lands, **before or
     after** the notice. CodeRabbit's rate-limit notice is temporary and is
     routinely followed by a real review an hour later (memory
     `coderabbit-rate-limit-is-temporary`) — and it is just as often a limit hit
     on a *later* re-review request, which must not retroactively void a
     walkthrough that already named this SHA.

   Signals 1 and 2 therefore share one rule, worth stating plainly because both
   halves were found the hard way: **an approval's own body never vouches for
   itself, and external evidence that the reviewer read this SHA redeems it
   whenever it arrives.**
3. **Self-report SHA mismatch.** Among the reviewer's comments that mention any
   commit id, the most recently **posted** names none matching HEAD. Ordered by
   `created_at`, never `updated_at` (BugBot, PR #883): these bots edit in place —
   CodeRabbit rewrote its rate-limit notice three times on PR #883 alone to name
   each new commit range as the branch moved — so an older comment naming HEAD,
   edited later for unrelated reasons, would otherwise sort last and mask the
   bot's genuinely newest SHA-naming post. Post time is the stable, monotonic
   dimension; the tokens still come from the comment's *current* body, which is
   what "what does this bot claim now" should mean. This fired on every
   hollow approval in the mia traces and on none of the genuine ones.
   Restricting to SHA-naming comments keeps content-free acks ("Full review
   triggered") from masking the walkthrough that carries the self-report.
4. **Substance across the whole footprint.** Review body ≥ `min_chars` **or**
   inline diff comments anchored to HEAD **or** a same-SHA status comment naming
   HEAD **or** a long descriptive comment tied to the current review round.
   Never body length on its own — and never a comment whose content is the
   reviewer *declining* to review.
   That last clause closes a loop this file's own live payload demonstrated
   (CodeAnt, PR #883). Capability-failure notices routinely name HEAD and run
   well past `min_chars`: CodeRabbit's rate-limit warning quotes the exact commit
   range it declined to review. Counted as a status comment, such a notice made
   itself substantive **and**, by becoming the reviewer's newest evidence,
   suppressed the signal-2 check that exists to catch it — so "I could not review
   commit X" would have satisfied coverage for commit X. Failure notices are now
   excluded from status evidence, which is what the documented
   failure-before-substance priority order always implied.
5. **Timing proximity to the push.** Reported as `seconds_after_push`,
   corroborating only. An 8-second approval is suspicious, not disqualifying.

`counts_as_coverage = approved ∧ (substantive ∨ redeemed_by_clean_run) ∧ disqualified_by = ∅`,
where `disqualified_by` collects `no_substantive_footprint`,
`self_report_mismatch`, `temporal_inversion`, `pre_run_approval` and
`capability_failure`.

`pre_run_approval` (issue #1365) is the fourth disqualifier, read off the
reviewer's own structured run record rather than inferred from prose;
`redeemed_by_clean_run` (issue #1432) is its one narrow redemption. Note what
redemption does and does not touch: the raw `pre_run_approval` **boolean stays
`true`**, and it is the **tag** that leaves `disqualified_by` (together with
`no_substantive_footprint`). Writing the predicate as `… ∧ ¬pre_run_approval`
would therefore be wrong — it would read a redeemed approval as still blocked.
Both are detailed under "Structured run markers" below.

`self_report_mismatch` is the latest SHA-naming conversation comment naming a commit other than HEAD, **unless** that reviewer also left inline comments anchored to HEAD (`commit_id` AND `original_commit_id` == HEAD). Those inlines are first-party evidence of which SHA was read, so they supersede a stale status table (inventory #416 / this repo #1380 — CodeAnt records only push-triggered auto-reviews). A long approval body or a SHA-less descriptive comment does **not** clear the mismatch: that would re-open the rubber-stamp hole and the #927 launder. A status comment that names no SHA at all is not a self-report candidate (`$selfrep` is null), so it never raises the mismatch.

### Descriptive evidence without a SHA (issue #927)

The ccc#923 trace showed a genuine review footprint that the original evidence
model could not admit: after CodeAnt announced that it was running the review,
it posted a long, accurate Sequence Diagram summary of the UUID-fragment change,
but did not repeat HEAD's SHA. `status_comment_names_head` was therefore false,
and the empty approval had no other coverage source.

`descriptive_evidence_on_head` admits that shape when a reviewer's conversation
comment satisfies every condition below:

- its reviewer-authored body is at least `min_chars` long after the existing
  echoed-author-line filter removes borrowed prose and blank or syntax-only
  remnants are excluded from the length calculation;
- it is not a capability-failure notice;
- it is not itself a run-start marker or fixed completion marker (which prove
  only that work began or ended);
- it is at or after `push_ts`; and
- the reviewer has an earliest post-push run-start marker, with the comment at
  or after that marker.

The push and marker bounds tie the prose to the current review round without a
new network input. This is why the alternative changed-file-path rule was not
chosen: it would require fetching the PR file list, introduce path-spelling
false negatives, and add evaluator input solely to prove context that the
existing round markers already establish.

The completion-marker exclusion is semantic, not an accident of the default
length threshold: the known `CodeAnt AI finished running the review.` notice is
currently 39 characters, but it remains ineligible even when `min_chars` is
configured below that. A fixed terminal status cannot certify that the reviewer
read the diff.

The safety property is one-directional and explicit in the evaluator dataflow.
`$descriptive_ev` is ORed only into `$ext_substantive`; it never enters
`$selfrep` or `$mismatch`. Turning the channel on can remove
`no_substantive_footprint`, but `self_report_mismatch` is byte-identical with or
without it. A reviewer whose latest SHA-naming comment identifies an older
commit therefore remains disqualified even when descriptive evidence is true.
The channel grants evidence of work; it cannot manufacture a false mismatch or
launder a wrong-commit self-report.

### What counts as a run-start marker

Only phrases denoting work **in progress** — "is running the review", "is
reviewing", "review in progress", "currently processing", "started reviewing",
"is analyzing". Deliberately **not** "review triggered" (BugBot, PR #883): that
is the request being *accepted*, not work beginning. `pr-state.sh` and
`poll-watermarks.sh` both classify "full review triggered" as an
`acknowledgment`, with a regression test pinning it, so admitting it here
contradicted the repo's own classification — and because `$marker` takes the
*earliest* post-push marker, a content-free ack landing first became the marker
and stopped a later approval from looking inverted against the bot's genuine
notice.

### Structured run markers and `run_marker_head` selection (issues #1365, #1419)

CodeAnt maintains one in-place-edited "Review Status" conversation comment and
embeds machine-readable per-run data behind its visible table:
`<!-- codeant-review-status:[{"commit":…,"started":…,"finished":…,"done":…}] -->`,
one row per run, full 40-char SHA, naive-UTC timestamps (canonicalised onto the
`Z` spelling before any compare). The evaluator parses it into `run_started_at`
/ `run_finished_at` / `run_done` and two verdict inputs: an **in-flight HEAD
row is not evidence** (`status_comment_names_head` stays false — a run marker
says work began, not that any diff was read), and an approval outside its own
recorded run is disqualified **`pre_run_approval`** (`done` false, or
`submitted_at < started`; the bound is the run *start* because CodeAnt stamps
`finished` after posting its verdict). `pre_run_approval` is deliberately not
suppressed by `external_evidence_on_head` — in the reported trace the
suppressing evidence *was* the marker comment — and a malformed or HEAD-less
payload degrades to the pre-#1365 verdict rather than blocking.

**Row selection is by content, never by list position** (issue #1419). The
first cut took `| last`, believing the payload appends in touch order; live
PR #1378 refuted it — CodeAnt **prepends** each new run row (three rows for one
SHA ordered 16:35, 16:31, 15:48, and the 5-row visible table dropped its oldest
commit when a new row arrived), so `last` returned the *oldest* run: a stale
completed run vouched for a re-review still in flight, and a stub posted
between two runs cleared `pre_run_approval` against the old row's `started`.
Selection is now `max_by([(.done | not), .started])` over the HEAD-matching
rows: an in-flight row outranks every completed one — a completed earlier run
must not vouch for an analysis currently back in flight — and otherwise the
latest `started` wins, so newest-first and append-ordered payloads resolve
identically.

### `redeemed_by_clean_run` — the one exception (issue #1432)

The paragraph above is still the rule; this is its single documented exception,
and it is narrow on purpose.

`pre_run_approval` conflates two shapes: *an approval with no run behind it* (a
rubber stamp — must block) and *an approval whose timestamp merely precedes a
run that then completed clean on the same SHA* (an emission-order artefact). On
some repos the second is the **only** shape a clean pass can produce. Observed
on still-point PR #696 (HEAD `1ecca19`): CodeAnt emitted `APPROVED` 18 s before
its own run started, followed with `COMMENTED` when it had findings, and
followed with **nothing** when the run came back clean. A perfectly-reviewed PR
therefore could never obtain a gate-valid approval — the CR path deadlocked with
no exit but a paid Greptile escalation or `/admin-merge`.

Re-triggering the bot is not a workaround and never can be. On this repo's
PR #1454 an explicit `@codeant-ai review` produced a genuine completed clean run
on HEAD `52a3338` (started 16:29:53Z, finished 16:32:38Z, `done: true`, zero new
findings, 0 unresolved threads) while `submitted_at` stayed frozen at the
previous day's 19:04:56Z — CodeAnt PATCHes the review object in place (#876), so
the only timestamp the guard can read is the *first* submission's and it can
never move forward. Any redemption keyed on `submitted_at` overtaking the run
start is structurally unable to fire for exactly the reviewer that needs it.

So the rule keys on the run marker instead:

> A `pre_run_approval` is redeemed **iff** the same reviewer's run marker for
> the **same SHA** reaches `done: true` **and** that reviewer left **zero
> findings from that run** — no `COMMENTED`/`CHANGES_REQUESTED` review on the
> SHA, and no HEAD-anchored inline comment that is either inside the run's
> window or still unresolved — **and** no other disqualifier survives.

**Review-state** findings (`$ridx`) are read by **presence on the
`commit_id`-scoped index**, never by ordering anything against the run window —
the same frozen `submitted_at` that motivates the rule would make an ordering
test meaningless. That detection is deliberately *not* filtered through
`fresh_review`: a `COMMENTED` review GitHub re-pointed onto HEAD cannot be proven
to belong to this round, and the conservative reading of an unprovable finding is
that it counts, since this term only ever **withholds** the redemption.

#### Inline findings are scoped to the governing run (issue #1632)

Counting **every** inline comment on the SHA left the gate's own stated remedy
unreachable. Where run 1 posted findings that were all declined-with-evidence and
**resolved**, no code change is warranted, so no new HEAD exists; the
`@codeant-ai review` re-run then completes with zero new comments, yet the
earlier ones keep `run_has_findings_on_head` `true` forever and no clean run can
ever redeem the stub. Observed on PR #1612 at `da2acd8` (re-run 05:27:55→05:28:20
with zero findings, still hollow) and PR #1627 at `d4ac833` — both fell to
Greptile with the stickiness that brings.

An inline comment on HEAD therefore counts as a finding when **either**:

- its `created_at` falls inside the governing run marker's `started`→`finished`
  window (open-ended while `finished` is empty, i.e. a run still in flight), **or**
- its `id` is absent from `resolved_comment_ids` — the thread is unresolved, or
  its resolution is unknown.

It is excluded only when it is **both** outside the window **and** resolved.

Two properties keep this from re-opening the hole it narrows. The window test is
a **disjunct, not a fallback**, so resolving a finding the governing run itself
posted does not launder it. And `created_at` is a legitimate ordering dimension
where `submitted_at` is not: it stamps a distinct comment *object* at the moment
it was posted, rather than a verdict the bot rewrites in place — and a bot that
did freeze a comment timestamp lands on the resolution branch, not on a false
clean. With `$runmark` null there is no window to test and every HEAD inline
comment counts, exactly as before.

#### `resolved_comment_ids` — the optional input

Thread-resolution state reaches the evaluator through one optional payload key:

```json
{ "…": "…", "resolved_comment_ids": [ 2415360912, 2415360913 ] }
```

the REST comment ids (GraphQL `databaseId`) of every comment sitting in a
resolved review thread. `merge-gate.sh` derives it from the `reviewThreads` query
it already runs; `escalate-review.sh` derives it from `pr-state.sh`'s
`threads.all`, which already requests `databaseId`. Neither costs an extra API
call. Ids are stringified on both sides, so a number and its string spelling
cannot silently miss.

The key is **optional and defaults to `[]`**. An empty set makes every inline
comment read as unresolved, which reproduces the pre-#1632 behaviour byte for
byte — so a caller with no thread data (today: `pr-preflight.sh`, whose only use
is deciding whether to re-trigger a bot, and which fails toward re-triggering)
degrades toward **refusing** redemption, never toward granting it. Pinned by case
(s4) in `tests/merge-gate-codeant-run-marker.test.sh`, the negative control that
keeps (s1) from being vacuous.

When the shape holds, both `pre_run_approval` and `no_substantive_footprint`
leave `disqualified_by` — the completed clean run *is* the footprint, and
withholding coverage for want of evidence while holding the reviewer's own
completed analysis of HEAD would just relocate the deadlock. `counts_as_coverage`
then flips through the ordinary rule, so `merge-gate.sh`'s `substance_reasons()`
/ `override_eligible()` and `escalate-review.sh`'s `.substantive[]` read need no
tag-specific logic and cannot drift apart
(`tests/escalate-review-merge-gate-freshness-parity.test.sh` projections (R)/(Rn)).

Never redeemed by: reviewer identity, an in-flight run (`done: false` — the
other `pre_run_approval` shape), a run that produced any finding on HEAD, an
absent/HEAD-less/unparseable run record, prose of any length, or a payload where
`temporal_inversion`, `self_report_mismatch` or `capability_failure` still
stands — `redeemed_by_clean_run` is `false` whenever any of those survive, so
the tag never reads as "gate cleared" when it was not. `--allow-hollow-approval`
is unchanged and still cannot launder a genuine stub.

The raw `pre_run_approval` boolean stays `true` when redeemed (the ordering
violation really did happen), a new `run_has_findings_on_head` boolean reports
the deciding term, and the login appears in both the `pre_run[]` and
`redeemed_by_clean_run[]` top-level buckets. `merge-gate.sh` announces every
redemption on stderr — the same "redemption is never silent" convention as
the #876 `STALE_REDEEMED` messages. The two are **separate axes**: #876 asks
whether the approval object is fresh, #1432 asks whether anything actually
reviewed the commit. Neither substitutes for the other.

The comment is PATCHed in place, so its `created_at` can predate the push by
hours (~19 h on PR #1378) while `updated_at` tracks the runs. The structured
path therefore reads **content, never `created_at`** — in both directions:
an in-flight row is refused and a completed run redeems regardless of how old
the comment object is. Fixtures (o)/(p) in
`merge-gate-codeant-run-marker.test.sh` pin exactly that, against the
plausible-looking `created_at >= push` refactor that would silently reopen the
PR #1378 hole.

### Substance is pooled across a bot's approvals on one SHA

`body_len` is the maximum across every `APPROVED` that reviewer left on HEAD, not
the latest one's. These bots approve in bursts — CodeAnt posted **four identical
empty `APPROVED` reviews in the same second** on PR #883 — so keying substance to
the newest approval let an empty duplicate discard a real review body, and the
ordering inside a same-second burst is arbitrary enough to make that
intermittent. Timing still keys off the latest approval; only substance pools
(BugBot, PR #883).

### Two deliberate anti-false-positive choices

- **SHA-like tokens are not decided by form alone.** `\b[0-9a-f]{7,40}\b` with no
  further test would read `20260731` or a line count as a commit id and
  manufacture a mismatch out of an ordinary sentence. Requiring an `a-f` letter
  fixed that, but then discarded a *genuine* short SHA that happens to be all
  decimal — 3.5% of commits. See "Three admission rules" below.
- **A comment naming HEAD needs no freshness filter.** Naming HEAD's SHA is
  itself proof the comment postdates HEAD, so the substance signal survives a
  missing push timestamp.
- **Timestamps are canonicalised before any comparison.** Every ordering test in
  the evaluator is a string compare, which is only correct while all timestamps
  share one spelling: `…T10:00:22+00:00` sorts *before* `…T10:00:16Z`, so a
  single non-`Z` form would silently erase an inversion. `canon_ts` folds the
  UTC spellings onto `Z` and drops fractional seconds — the same trap `norm_ts`
  guards in `merge-gate.sh` (BugBot, PR #883). A genuine non-UTC offset is left
  untouched rather than mangled into a wrong instant.
  Dropping fractional seconds means an approval and a marker in the **same
  second** cannot be ordered, so inversion compares with `<=`: no real review
  begins and finishes inside one second, and `external_evidence_on_head` still
  clears the innocent shape. Keeping sub-second precision was not the
  alternative — under mixed precision `"10:00:22.5Z"` sorts *before*
  `"10:00:22Z"` (`.` < `Z`), which would corrupt ordering outright.

## Three admission rules for SHA-like tokens (issue #894)

A 7-character short SHA is all decimal with probability (10/16)^7 ≈ 3.7%; measured
against this repo's real history, **15 of the last 431 commits on `main` (3.5%)**.
For every one of those commits the `a-f` requirement made `sha_tokens` return an
empty list for any comment naming HEAD's short form, so `status_comment_names_head`
was *structurally* false, `external_evidence_on_head` with it, and the #876
stale-approval redemption could not fire. A reviewer that did the work, said so,
and named the commit was still not believed — the exact wedge PR #893 removed,
back for one commit in thirty.

The fix stops deciding token-hood purely by form. `sha_tokens` now admits a token
under any of three rules, and **each addition can move the verdict in exactly one
direction**:

| # | Rule | Admits | Can grant coverage? | Can withhold coverage? |
|---|---|---|---|---|
| 1 | **FORM** (unchanged, #875) | `\b[0-9a-f]{7,40}\b` with at least one `a-f` | yes | yes |
| 2 | **IDENTITY** (#894) | all-decimal `\b[0-9]{7,40}\b` that prefix-matches the known HEAD SHA | yes | yes |
| 3 | **CODE SPAN** (#894) | all-decimal run that is a complete inline code span (`` `1234567` ``) | **no — structurally impossible** | yes |

**Rule 2 corroborates against HEAD's identity, not against token form** — precisely
the comparison `tokens_name_head` was about to make anyway, so nothing is guessed.
A decimal run that is a genuine prefix of the actual HEAD SHA is not a coincidence
worth guarding against (~1e-7), and it is the same exposure rule 1 has always
carried for hex tokens.

**Rule 3 exists only for the `self_report_mismatch` diagnostic.** Without it, a
rubber stamp whose status comment names an *older* all-decimal SHA yields no
tokens at all, is therefore not a self-report candidate, and a long-bodied
approval naming a different commit counts as full coverage.

**Rule 3 alone reads fence-stripped text.** A CodeRabbit walkthrough quotes diff
hunks inside ``` fences, and quoted code carries backticks of its own — a JS
template literal in a fenced hunk is a numeric literal being *discussed*, not a
commit the reviewer claims to have read (raised by the CodeRabbit CLI on the #894
PR). Rules 1-2 keep scanning the whole body on purpose: rule 1 must stay
byte-identical to its pre-#894 behaviour, and rule 2 is anchored on HEAD's
identity, so a run that matches HEAD is HEAD wherever it appears. Only rule 3
infers commit-hood from surrounding punctuation, so only rule 3 needs that
punctuation to be trustworthy.

> Four Markdown code-block shapes are stripped before rule 3 runs (issue #897):
>
> ```
> gsub("```.*?```"; " "; "m")   # 1. closed triple-backtick fences (lazy)
> gsub("~~~.*?~~~"; " "; "m")   # 2. closed tilde fences (lazy)
> gsub("```.*"; " "; "m")       # 3. unclosed backtick opener → end-of-body
> gsub("\n    [^\n]*"; " "; "m") # 4. four-space-indented lines
> ```
>
> Steps run in order: closed fences first so the unclosed-opener rule does not
> swallow content belonging to a later valid close. The flag is **`m`, not `s`** —
> jq inverts the PCRE convention: jq's `m` is what makes `.` match a newline, and
> its `s` only rebinds `^` and `$`. Written with `s` the gsubs match nothing at
> all and every fenced block is silently scanned as prose.

### Quoted and echoed text is excluded first (issue #933)

All three rules read a body with **borrowed lines removed**. A line is borrowed
when the identical line was already posted on the thread by someone who is *not*
one of the reviewers under evaluation; quote markers (`>`) are normalised out of
the comparison key, so GitHub's "Quote reply" shape (a `>` marker followed by the
original line) matches its source. Nothing else is removed.

The trace (PR #929, 2026-08-02). CodeAnt answers a re-review request by
reproducing the requester's comment verbatim under a `Question:` heading and
putting its own verdict under `Answer:`. The author's trigger prose named HEAD's
short SHA `5acd1e2`, so the bot's body contained HEAD's SHA that the bot never
wrote — and `status_comment_names_head`, the flag asserting *this reviewer
demonstrably read HEAD*, went true on the strength of the **author's** words.
Replayed on the live payload, `main` scored that empty CodeAnt approval
`counts_as_coverage: true`; with the exclusion it is `false`, and the reviewer's
`status_comment_shas` correctly reports `c441771` — the SHA its own status
comment actually names — instead of the echoed `5acd1e2`.

**Why not "strip every blockquote line"**, the obvious first cut: the live
payload refutes it twice. The PR #929 echo carries no `>` at all, so a blockquote
rule closes *none* of the reported trace; and the only `>` lines on that thread
are CodeRabbit quoting **itself** — its status notice renders its own reviewed
range as `> Reviewing files that changed … between <base> and <head>`. Blanket
quote-stripping would have deleted a reviewer's own self-report on every
CodeRabbit status comment in this repo while fixing nothing. The issue asks to
discount quoted/echoed *author* text; a bot's own callout is not author text.
Case `(ff-933)(e)` is the negative control that pins this distinction.

Two further properties, both deliberate:

- **Ordered.** The index stores the earliest time each line was seen, and a line
  is dropped only from comments written at or after it. Echo means the source
  came first; without ordering a human quoting a bot verbatim would retroactively
  strip the bot's original.
- **Edit-aware** (BugBot review of PR #951). The two sides of that comparison use
  deliberately different timestamps, both biased toward stripping: the index
  keeps `created_at` (the earliest time a source line can have existed) and the
  scan uses `updated_at` (the latest time the scanned body can have been
  written). GitHub freezes `created_at` on an in-place edit, and editing in place
  is routine here — CodeAnt PATCHes its review body on re-review (#876),
  CodeRabbit rewrites its walkthrough — so scanning on `created_at` let a bot
  edit an echo into a comment it had opened *before* the author wrote the line,
  sort ahead of the index entry, and manufacture HEAD evidence without ever
  writing the SHA. Unedited comments report `updated_at == created_at`, so the
  ordering guard is unchanged. Pinned by `(ff-933)(n)` and its unedited control.
- **Reviewers never seed the index**, so a reviewer can never strip *itself* —
  including a bot that repeats its own status line. One reviewer quoting another
  is therefore out of scope, pinned by `(ff-933)(i)` so that widening the index to
  bot-authored text stays a conscious decision.

One exception keeps the filter from breaking the masking above: **fence
delimiter lines (` ``` `, `~~~`) are never dropped as echoes.** A bare fence line
is among the most reproducible lines on a thread — every comment carrying a code
block has one — so it enters the index almost immediately, and dropping it would
delete the delimiters of a *reviewer's own* fenced block. Rule 3's masking is
paired-delimiter matching: lose the pair and quoted diff hunks are scanned as
prose again. Losing only the closer is the worse half, since the unclosed-opener
rule then runs to end-of-body and deletes rule-3 tokens that should have been
admitted. Only paired syntax needs the exception, which is why four-space
indented lines get none — dropping such a line removes its content with it.
Pinned by `(ff-933)(j)`.

**The exception is the delimiter, not the line** (CodeAnt review of PR #951).
Markdown info strings are free-form, so a fence opener can carry arbitrary text —
including HEAD's SHA. Written as "keep any line that *starts with* a fence
marker", the exemption is wider than the argument for it, and the gap falls on
the grant side: an echoed ` ```5acd1e2 ` readmits precisely the token the echo
filter just refused, and on a live-shaped payload an empty-body approval scored
`counts_as_coverage: true` off the author's words again. An echoed fence line is
therefore **truncated to its own delimiter run** — leading whitespace and quote
markers kept, info string and trailing text dropped. The masking regexes never
read the info string, so paired matching sees an identical delimiter either way.
Non-echoed fence lines are not rewritten at all. Pinned by `(ff-933)(k)` (the
smuggling attempt fails) and `(ff-933)(l)` (the truncated opener still pairs).

**Directions.** Dropping a line — or truncating an echoed fence line to its
delimiter — can only ever *remove* tokens. `split("\n") | join("\n")` is the
identity when nothing is dropped, an untouched line is emitted byte-for-byte,
and a truncated fence line keeps a prefix of itself on its own line, so no text
is joined across a boundary and a run of `` ` `` or `~` contributes no hex or
decimal digit. The indentation- and fence-sensitive rules above therefore still
see what they always saw. `status_comment_names_head`,
`external_evidence_on_head` and `substantive` are monotone in the token set and
so can only move **true → false**: the grant path #933 closes.

`self_report_mismatch` moves both ways. It goes false → true when a comment keeps
a non-HEAD token but loses its HEAD one, and **true → false** when a comment's
only tokens were quoted, so it stops being a self-report candidate at all. That
second direction is a grant, and it is the same correction rather than a side
effect: a SHA the reviewer never wrote was never the reviewer's report about
itself, and reading it as one yields a blocker no re-review can clear while the
trigger prose stays quoted. Issue #917 accepted the identical direction for the
identical reason (UUID fragments manufacturing mismatches out of CodeRabbit's own
request ids). It stays bounded — a comment carrying any SHA in the reviewer's own
prose keeps its tokens and its verdict.

`counts_as_coverage` therefore moves both ways as well, and **only through that
one channel**. Every other input pushes it down: `substantive` can only fall,
`no_substantive_footprint` can only appear, and `temporal_inversion` and
`capability_failure` are both suppressed by `external_evidence_on_head`, which
can only fall — so each can only newly fire. The single upward path is a cleared
`self_report_mismatch` on a reviewer that is substantive on its own footprint.

### Why rule 3 cannot weaken the gate

Any token admitted by rule 3 and **not** by rules 1-2 is, by construction, an
all-decimal run that does *not* prefix-match HEAD — otherwise rule 2 would already
have admitted it. So a rule-3-only token can never satisfy `tokens_name_head`:

- `status_comment_names_head` is byte-identical with and without rule 3;
- `external_evidence_on_head`, and so the #876 redemption, is byte-identical too;
- `$selfrep` is the newest token-bearing comment, so adding a candidate that fails
  to name HEAD can only move `self_report_mismatch` **false → true**, never back.

Rule 3's only reachable effect is to *withhold* coverage. A false positive there
blocks a merge, which is recoverable by a re-review and a push; the direction it
structurally cannot take is the one that grants a merge. `merge-gate-review-substance.test.sh`
case `(ee)` asserts this invariant directly rather than leaving it as an argument.

### What was rejected

- **Dropping the `a-f` filter outright.** Any 7-digit issue number, date or epoch
  becomes a commit id, able both to falsely redeem a stale approval and to falsely
  clear a mismatch — the failure the filter exists to prevent, in the direction
  that grants merges.
- **Rule 2 alone.** Fixes the redemption wedge but silently drops the mismatch
  diagnostic for all-decimal SHAs, which is a real hole and not merely a lost
  message (see rule 3 above).
- **Matching against a `known_shas` set (the PR's commit list).** The SHA a rubber
  stamp names is typically a *pre-rebase* commit that no longer appears in
  `gh pr view --json commits` — the exact #876 trace — so it would miss the case it
  was added for, at the cost of a new input contract.
- **Cue words (`commit`/`sha`/`for`/`at`).** The cues these bots actually use include
  `for`, `at`, `and` and `between` — broad enough to be meaningless. The inline
  code-span shape is what both bots genuinely emit (`` ## Review summary for `<sha>` ``)
  and it excludes prose numbers, `#1234` refs, and fenced-block contents.

This change is **upstream** of the redemption channel, not part of it: it alters what
`external_evidence_on_head` can *see*, never what redeems. The #876 channel stays
exactly one term wide, and `tests/ts-normalizer-parity.test.sh` passes unmodified.

## The evidence payload must be complete

`merge-gate.sh` paginates both comment endpoints, not just reviews (BugBot,
PR #883). One page each was survivable while those payloads only fed thread
bookkeeping; they are now this evaluator's evidence. On a PR busy enough to push
a walkthrough or the inline findings past comment 100, the evaluator sees no
external evidence, calls a genuine approval hollow, and blocks the merge — a
false negative, which this file weights as heavily as a false positive. PR #883
itself passed 40 comments across the two endpoints during its own review.

## What the gate does with it

- `primary_review_met` keeps its name and type. It tightens from "an approval
  exists" to "a substantive approval exists" — the meaning consumers already
  assumed. `escalate-review.sh` runs the same evaluator on its gate-already-met
  short-circuit, so a hollow approval cannot suppress escalation while the gate
  blocks on it.
- `review_evidence` is emitted on every path (`{}` only on early failure exits)
  with per-reviewer detail plus `substantive[]`, `hollow[]`, `mismatched[]`,
  `inverted[]`, `capability_failed[]`, `pre_run[]`,
  `redeemed_by_clean_run[]` and advisory `corroborating[]`.
- `missing[]` says *why* — "approved before CodeAnt announced it had started
  reviewing", not "need 1 approval".
- Discounted approvals are announced on stderr even when the gate passes on
  another reviewer, so a rubber stamp is never silently absorbed.
- **Redemptions are announced too**, on the same principle: `merge-gate.sh`
  prints the #876 `STALE_REDEEMED` line for a redeemed frozen `submitted_at`,
  and an issue-#1432 line naming the login, HEAD and the run start/finish for a
  `pre_run_approval` cleared by a completed clean run. A verdict that turned on
  a redemption is never silent in either direction. Both lines claim **only
  their own axis** — #876 says the approval object is *fresh*, #1432 says the
  approval is *substantive rather than hollow* — and neither announces merge
  coverage. Both fire before `<P>_APPROVAL_VALID` is derived, so an approval
  redeemed on one axis can still be rejected on an orthogonal one (a stale
  `submitted_at`, a newer same-SHA `CHANGES_REQUESTED`, failing CI, an
  unresolved thread). Worded as a coverage decision, the stderr would contradict
  the gate's own answer (CodeAnt, PR #1476).
- `--allow-hollow-approval` exists as an explicit per-PR user override. An agent
  must never pass it on its own; the evidence is still computed and emitted and
  the override is announced on stderr. Its scope is exactly one disqualifier,
  `no_substantive_footprint`, and nothing else (CodeAnt, PR #883): an approval
  naming a different SHA, predating the bot's own start marker, or following that
  bot's capability-failure notice is not *unevidenced* — it is evidence **against**
  a review of this commit, and no per-PR override should launder it. "The bot said
  nothing and I read the diff myself" is a defensible human claim; "the bot's own
  record contradicts its approval" is not.

## What a hollow approval does *not* do

A hollow approval from one bot does **not** block when the other bot's approval is
genuine. BugBot argued on PR #883 that a rubber-stamping CodeAnt should fail the
supplemental CodeAnt gate even when CodeRabbit passed. Declined, for two reasons:
`cr-merge-gate.md`'s CR path is "either bot alone suffices" and real coverage
demonstrably exists, so blocking would hold every PR hostage to whichever bot is
malfunctioning that day — the false-negative cost this evaluator is written to
avoid. The guarantee BugBot actually wanted, that a rubber stamp is never absorbed
*silently*, is already met: the approver stays in `review_evidence.hollow[]` and
merge-gate.sh announces every discounted approval on stderr even when the gate
passes. Pinned by case (r) in `merge-gate-review-substance.test.sh`.

## Corroboration is reported, not gating

`corroborating[]` lists reviewers with a substantive footprint on HEAD that did
not approve — through both sessions, consistently BugBot. It deliberately does
**not** satisfy the CR-path requirement: letting BugBot silently stand in would
be a different weakening of the gate, and keeping it advisory leaves the
sticky-reviewer decision in issue #865 open.

## Interaction with issue #865

#865 asks whether a fresh CR-path `APPROVED` should satisfy the gate while a PR
is sticky-assigned to BugBot. Orthogonal, and composes: this change only decides
whether a given `APPROVED` counts as coverage at all. If #865 later admits a
CR-path approval under sticky BugBot, it should key off `counts_as_coverage`,
which makes that option strictly safer than it would have been.

## Performance note

The evaluator originally took **11 minutes** on a real ~1 MB PR payload. The
cause was not jq: it was `[[ -z "${INPUT// /}" ]]`, a bash pattern substitution
over the whole payload, which is O(n²) on bash 3.2 (the macOS default). A plain
`-z` test plus the existing `jq -e .` validation is equivalent and runs in
microseconds; the real payload now evaluates in ~0.4 s. Worth remembering before
reaching for `${var//…}` on anything large in these scripts.
