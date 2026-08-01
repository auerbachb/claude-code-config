# Stale-approval redemption — the CodeAnt in-place review edit (issue #876)

Reference material for `merge-gate.sh`. Not auto-loaded; the enforced rule lives
in the script and in `.claude/scripts/tests/merge-gate-codeant-inplace-review.test.sh`.

## The quirk

CodeAnt does not post a new review object on a re-review. It **PATCHes the
existing one**. After a force-push its review keeps the same `id`, has
`commit_id` correctly advanced to the new HEAD — and `submitted_at` **frozen at
the original submission**, because GitHub's review API treats that field as
immutable creation time rather than last-modified time.

The #836 staleness guard compares `submitted_at` against the HEAD commit's
committer date. So for CodeAnt specifically, a genuinely completed post-push
re-review is stale **forever**, and no amount of re-triggering can clear it: each
re-run edits the same object and leaves the same frozen timestamp.

### Live trace — `auerbachb/skingod` PR #2596

```text
04:57:00Z  CodeAnt APPROVED, review id 4833716091, on pre-rebase SHA 3e9dfd0e
04:59:42Z  force-push to f9b6041c                    <-- HEAD committer date
05:02:01Z  @codeant-ai review posted
05:02:06Z  "CodeAnt AI is running the review."
05:02:34Z  sequence-diagram summary naming f9b6041c, accurately describing the
           actual diff ("adds a SafeAreaProvider inside the native modal root…")
05:03:35Z  "CodeAnt AI finished running the review."
```

`gh api .../pulls/2596/reviews` still returned review id **4833716091**, now
`commit_id: f9b6041c…`, `submitted_at` still **04:57:00Z** — before the SHA it
claimed to cover existed. `merge-gate.sh` reported
`"CodeAnt approval on HEAD f9b6041 predates the HEAD commit (force-push
retargeting)"` for 8 poll ticks over 15+ minutes, while a real verdict on the
current SHA sat in the conversation the whole time.

## The rule

> A stale `submitted_at` may be **redeemed by external evidence on the current
> SHA**. It is never **waived by reviewer identity**.

`merge-gate.sh` computes `<P>_APPROVAL_STALE` exactly as #836 always did — the
`norm_ts` ordering, unchanged, one meaning. Redemption is a separate, separately
named term:

```text
<P>_STALE_REDEEMED         = <P>_APPROVAL_STALE AND external_evidence_ok(<login>)
<P>_APPROVAL_STALE_BLOCKING = <P>_APPROVAL_STALE AND NOT <P>_STALE_REDEEMED
```

`<P>_APPROVAL_STALE_BLOCKING` is what the rest of the path consumes. Because
redemption cannot fire unless the approval is already stale, the ordinary fresh
path is byte-for-byte unaffected.

The redemption term is `review-substance.sh`'s `external_evidence_on_head`:
a substantive footprint anchored to HEAD and produced **outside the review object
whose timestamp is in doubt** —

- inline diff comments with `commit_id` **and** `original_commit_id` == HEAD, or
- a `>= min_chars` conversation comment naming HEAD's SHA that is not a
  capability-failure notice, or
- a substantive non-`APPROVED` review on HEAD with `submitted_at >= push_ts`.

Redemption is announced on stderr and is visible in the emitted
`review_evidence`. Nothing about it is silent.

## Three designs that were rejected

**1. "CodeAnt's `submitted_at` is unreliable, so skip staleness for CodeAnt."**
This is the shape the issue's own fix sketch offered as an option, and it is the
one that must not ship. The same night #876 was filed, CodeAnt was observed
across three repos emitting genuinely hollow approvals — `bodylen=0`, four in one
second, one approving a commit that did not exist until 16 minutes later. An
identity waiver re-opens exactly the hole issue #875 closed hours earlier. The
correct shape is narrower by construction: evidence redeems, identity never does.
CodeRabbit gets the identical redemption on identical evidence, and case (f) of
the regression suite fails if that ever stops being true.

**2. Corroborate with the "CodeAnt AI finished running the review" notice.**
This was CodeRabbit's coding plan for the issue, and it is the intuitive reading
of the AC. It is too weak: the notice is a fixed, content-free string, so
accepting it lets a bot certify its own freshness with a constant. Case (c) pins
the rejection. The live trace supplies a *better* signal at 05:02:34Z — the
substantive summary naming the new SHA — and that is what the fix consumes.

**3. Trust `commit_id == HEAD` outright for CodeAnt.**
Rejected for the reason CodeRabbit itself gave: the retargeted `commit_id`
*always* matches HEAD, so the AC's requirement that the uncorroborated shape stay
blocked could not be satisfied.

## Why this does not weaken #875

`external_evidence_on_head` is strictly **stronger** than the `substantive`
verdict it feeds — it is `substantive` minus the approval's own body. So the
redemption channel is narrower than the coverage test, and the two are ANDed:
a redeemed approval still has to clear `counts_as_coverage`.

The practical consequence is case (e) of the regression suite. A reviewer with a
summary naming HEAD *is* redeemable, but if its own newest SHA-naming comment
names a different commit, `self_report_mismatch` still blocks it — and the
`missing[]` entry is the #875 substance reason, not the #836 staleness one. The
approval's own body never enters either verdict, so an approval can never vouch
for its own frozen timestamp.

## The parity pin was updated, not defeated

`.claude/scripts/tests/ts-normalizer-parity.test.sh` pins that `merge-gate.sh` keeps the
freshness verdict on the **outside** of the substance check, so the deliberately
more permissive `canon_ts` in `review-substance.sh` (which drops fractional
seconds) can never reorder something `norm_ts` ruled stale.

That property is unchanged, because **redemption is not a timestamp comparison at
all**. The pin's needle moved to `<P>_APPROVAL_STALE_BLOCKING`, and new
structural assertions now keep the redemption channel exactly one term wide:

- `<P>_APPROVAL_STALE_BLOCKING` may be derived only from `<P>_APPROVAL_STALE`
  AND NOT `<P>_STALE_REDEEMED` — no disjunction, and exactly those two operands
  (a third `&&` conjunct would narrow when staleness blocks while every
  substring assertion still passed).
- `<P>_STALE_REDEEMED` may be granted only by `external_evidence_ok`, only on an
  already-stale approval, with no disjunction, and may not consult
  `substance_ok`, `counts_as_coverage` (circular — includes the approval's own
  body), or `norm_ts` (already decided).

## Scope, and how this relates to issue #865

Only the **CR path** is touched. `review_evidence` is `{}` on the BugBot and
Greptile paths, so there is no evidence to redeem with there, and #876's trace is
CodeAnt on the CR path. BugBot's own `submitted_at` staleness check (which has
the same #836 shape) is deliberately left alone — BugBot has not been observed
editing reviews in place, and widening the change without a trace would be
speculative.

Issue **#865** is the adjacent, still-open question: whether a fresh CR-path
`APPROVED` (CodeRabbit or CodeAnt) should satisfy the gate while a PR is
sticky-assigned to BugBot. The two do not collide and neither forecloses the
other:

- #876 changes **whether a CodeAnt approval is fresh**. It runs entirely inside
  the `cr` path and never touches reviewer resolution or stickiness.
- #865 would change **which path is consulted**. It is a routing decision.

They compose in the obvious direction: if #865 is later decided in favour of
letting a fresh CR-path approval satisfy a sticky-BugBot gate, #876 is what makes
"fresh" mean the right thing for an in-place-edited CodeAnt review, so the two
together remove the wait #865 describes. If #865 is decided the other way, #876
still stands on its own. Notably, the workaround used in the #876 live run was
precisely an #865-shaped escalation — switching PR #2596 to the BugBot path —
which is why the two issues keep surfacing together.

`review-substance.sh`'s `corroborating[]` field remains advisory for the same
reason: letting BugBot silently stand in for the CR-path requirement is #865's
decision to make, not this one's.
