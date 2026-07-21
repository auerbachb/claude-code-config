# Auto-file dedup — thresholds and the comment-vs-file decision

Canonical rules for any skill that opens GitHub issues **without a human in the loop** (`/wrap` Phase 3 Parts A and B today; the same rules apply to any future autonomous filer). Mechanical recall lives in `.claude/scripts/issue-dedup.sh`; the judgment described here is the caller's.

## Why this exists

`/wrap` gained autonomous follow-up filing in issue #633. On day one it filed issue #647 thirteen minutes after issue #638, proposing `.prs[<N>].root_repo` scoping — a restatement of #638's second acceptance criterion. #638 was open and searchable the whole time; the sweep simply did not look. The two issues share almost no title words but overlap heavily in body text, which is why **title-only search cannot fix this** and `issue-dedup.sh` scores bodies.

## The asymmetry that sets the threshold

The two failure modes are not equally bad:

| Failure | Cost |
|---------|------|
| Filed a duplicate | Two tickets covering one problem. Noisy; recoverable with `gh issue close`. |
| Suppressed a real finding | The finding is **gone** — buried as a comment on a ticket whose scope never covered it, and nobody re-derives it. |

So: **bias toward filing.** Suppression must clear a high bar; ambiguity resolves to "file, and say so."

## The three outcomes

Run `issue-dedup.sh "<2–6 keyword phrase from the finding>"` and read the ranked candidates. Then classify against the **top** candidate:

### Strong match → comment on the existing issue, do not file

All four must hold:

1. The candidate is **OPEN**. A closed issue never suppresses a filing (see below).
2. The finding and the candidate name the **same primary artifact** — the same file, script, field, or command path. Not "both are about session state"; the same concrete thing.
3. You can point to a **specific sentence or acceptance criterion** in the candidate's body that already covers this finding. Implementing the candidate as written would close the finding.
4. `coverage ≥ 0.6` on the top candidate.

If you cannot quote the covering criterion, it is **not** a strong match — drop to weak. Criterion 3 is the load-bearing one; the numeric floor in 4 is a guard against thin matches, not a substitute for reading the issue.

Action: `gh issue comment <N>` with the finding, using the template below. Record it in the sweep report as a **suppressed filing naming the target issue** — never silently.

### Weak / ambiguous match → file anyway, with the pointer

Anything that clears `--min-coverage` but fails any strong-match criterion — including "same area, unclear whether the scope covers it". Also every candidate that is **closed**: a closed issue cannot absorb a new finding, so surface it as context and file.

Action: file as normal, and include in the body, immediately under the title context:

```text
Possibly duplicates #<N> — <one line on the overlap and what is unclear>.
```

Flag it in the sweep report too, so the ambiguity is visible in two places rather than buried in an issue body.

### No match → file normally

Behavior is unchanged from before this check existed.

## Same-run batch self-check

Before filing, compare the candidate against issues **this run** already filed (`WRAP_FILED_ISSUES` in `/wrap`), not just against the repo. Two findings in one sweep that duplicate each other collapse into one issue; the second is recorded as suppressed, naming the first. Pass the run's already-filed numbers as `--exclude` so they cannot also come back as repo candidates and be double-counted.

## Never silent

Every suppressed filing appears in the report with the issue it deferred to, in one of two shapes:

- `Appended to #638 instead of filing — "<finding summary>"`
- `Collapsed into #660 (filed earlier this run) — "<finding summary>"`

A finding that is neither filed nor reported is the outcome this whole mechanism exists to prevent.

## Comment template (strong match)

```markdown
Additional observation from a /wrap session sweep on PR #<PR_NUMBER>:

<finding summary and context>

Filed here rather than as a new issue: this restates <the covering criterion>.

_Appended by /wrap._
```

## Tuning

`--min-coverage` (default `0.34`) controls **recall** — how many candidates you get to look at. Lowering it surfaces more candidates and costs only reading time; it does not by itself suppress anything, because suppression requires the four strong-match criteria. Raising it risks hiding the one candidate you needed to see. If in doubt, lower it.
