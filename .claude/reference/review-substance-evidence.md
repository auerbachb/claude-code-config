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
   The suppressing term is `external_evidence_on_head` — inline comments on HEAD
   or a status comment naming HEAD — and it is deliberately **not** time-bounded.
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
   produced no substantive evidence *after* saying so. The trailing condition
   matters: CodeRabbit's rate-limit notice is temporary and is routinely followed
   by a real review an hour later (memory `coderabbit-rate-limit-is-temporary`),
   and that later work must win.
3. **Self-report SHA mismatch.** Among the reviewer's comments that mention any
   commit id, the most recent names none matching HEAD. This fired on every
   hollow approval in the mia traces and on none of the genuine ones.
   Restricting to SHA-naming comments keeps content-free acks ("Full review
   triggered") from masking the walkthrough that carries the self-report.
4. **Substance across the whole footprint.** Review body ≥ `min_chars` **or**
   inline diff comments anchored to HEAD **or** a same-SHA status comment naming
   HEAD. Never body length on its own — and never a comment whose content is the
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

`counts_as_coverage = approved ∧ substantive ∧ ¬inversion ∧ ¬capability_failure ∧ ¬mismatch`.

### Two deliberate anti-false-positive choices

- **SHA-like tokens must contain at least one `a-f` letter.** `\b[0-9a-f]{7,40}\b`
  alone would read `20260731` or a line count as a commit id and manufacture a
  mismatch out of an ordinary sentence.
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

## What the gate does with it

- `primary_review_met` keeps its name and type. It tightens from "an approval
  exists" to "a substantive approval exists" — the meaning consumers already
  assumed. `escalate-review.sh` runs the same evaluator on its gate-already-met
  short-circuit, so a hollow approval cannot suppress escalation while the gate
  blocks on it.
- `review_evidence` is emitted on every path (`{}` only on early failure exits)
  with per-reviewer detail plus `substantive[]`, `hollow[]`, `mismatched[]`,
  `inverted[]`, `capability_failed[]` and advisory `corroborating[]`.
- `missing[]` says *why* — "approved before CodeAnt announced it had started
  reviewing", not "need 1 approval".
- Discounted approvals are announced on stderr even when the gate passes on
  another reviewer, so a rubber stamp is never silently absorbed.
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
