# Auto-file dedup — thresholds and the comment-vs-file decision

This is a **repo-wide contract** that applies to every code path that can call `gh issue create` without a human confirmation step. It is not a per-skill rule. Mechanical recall lives in `.claude/scripts/issue-dedup.sh`; the judgment described here is the caller's.

## Filer inventory

Run `grep -rn "gh issue create" .claude/` to reproduce this list. Every site must be classified; adding a new autonomous filer requires updating this table before merging.

| Site | Classification | Dedup behavior |
|------|---------------|----------------|
| `.claude/skills/wrap/SKILL.md` (Phase 3, Parts A + B) | **Autonomous** | Strong/weak/none — suppress + report (wired since PR #661) |
| `.claude/skills/wrap/SKILL.md` (Phase 3, Step 3.10a — churn hotspots) | **Autonomous** | **Exact-match** on a path key, not strong/weak/none — see "Exact-artifact dedup" below (issue #755) |
| `.claude/agents/pm-worker.md` (Task: Issue Creation) | **Autonomous** | Strong/weak/none — suppress + report (wired since PR #680) |
| `.claude/skills/harness-audit/SKILL.md` (Step 7) | **Autonomous** | **Exact-artifact** on the audited path — see "Exact-artifact dedup" below (issue #770) |
| `.claude/skills/issue-maker/SKILL.md` (Step 4) | **Human-in-the-loop** | Surface-only — never auto-suppress (wired since PR #661) |
| `.claude/skills/start-issue/SKILL.md` (Step 1a) | **Human-in-the-loop** | Surface strong matches, pause for confirmation (wired since PR #680) |
| `.claude/agents/researcher.md` | **Non-filer** | `gh issue create` appears in the agent's forbidden-command list |
| `.claude/skills/pm-clean/SKILL.md` | **Non-filer** | Confirmed — only calls `gh issue close`, never `gh issue create` |
| `.claude/rules/issue-planning.md` | **Documentation** | Describes the human-driven issue-creation flow; not itself a filer |

### Asymmetry rule

**Autonomous filers** (no human confirmation step): apply the full strong/weak/none suppression logic and always report suppressed filings — naming the issue deferred to, never silently.

**Human-present callers**: run the same helper and surface strong matches to the user for confirmation; do not auto-suppress. A human can judge context that the script cannot.

### Exact-artifact dedup (the narrow complement — issue #755)

The strong/weak/none ladder above is the default because most findings are prose: two tickets can describe the same problem in entirely different words, so recall has to be fuzzy and the judgment has to be a human-grade one.

A finding keyed to a **single unambiguous artifact** is a different problem. `/wrap`'s churn-hotspot category files one issue per **file path**, and "is there already an issue for `src/Form.tsx`?" has an exact answer. Fuzzy coverage scoring is the wrong instrument twice over: it can miss the existing issue (filing a duplicate) and it can match a *sibling* file (suppressing a real finding).

**A second category joined it in #770.** `/harness-audit` files findings keyed to one audited artifact — a rule file, a skill, a script, a hook. "Is there already an issue about `.claude/rules/safety.md`?" has the same exact answer, and the same two failure modes if scored fuzzily: a sibling rule file scores highly enough to suppress a real finding, while the genuine prior issue about that exact path can be missed. Both categories use the identical mechanism below, differing only in their title prefix and marker name.

That category therefore uses an exact key instead of `dedup_search`:

- **Title convention** — `Refactor hotspot: <path>` (`/wrap`) or `Harness redundancy: <path>` (`/harness-audit`), matched with string equality.
- **Body marker** — `<!-- churn-hotspot: <path> -->` / `<!-- harness-audit: <path> -->`, which still matches after a human edits the title. A **grouped** issue covering several artifacts that share one fix carries one marker per artifact, so each path still dedups independently.
- **Search is recall only.** `gh issue list --search "Refactor hotspot in:title"` (`/wrap`) or `gh issue list --search "Harness redundancy in:title"` (`/harness-audit`) narrows the candidate set; the decision is a **client-side exact comparison**, because GitHub tokenizes paths in `in:title` and would otherwise match `src/OtherForm.tsx` for `src/Form.tsx` — or `.claude/rules/cr-github-review.md` for `.claude/rules/cr-merge-gate.md`.
- **A failed lookup blocks filing.** `churn-hotspots.sh` reports `existing_lookup_failed`; the caller surfaces it and files nothing rather than risk a duplicate.

Both invariants from the fuzzy path still hold: suppression is reported (the evidence goes onto the existing issue as a comment, named in the closing report), and no finding is dropped silently.

**Use exact-artifact dedup only when the artifact genuinely is the key.** If a finding is about behavior, a decision, or a cross-cutting concern, it is prose — use `dedup_search`.

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

Action: `gh issue comment <N>` with the finding, using the template below. Record it in the run report as a **suppressed filing naming the target issue** — never silently.

### Weak / ambiguous match → file anyway, with the pointer

Anything that clears `--min-coverage` but fails any strong-match criterion — including "same area, unclear whether the scope covers it". Also every candidate that is **closed**: a closed issue cannot absorb a new finding, so surface it as context and file.

Action: file as normal, and include in the body, immediately under the title context:

```text
Possibly duplicates #<N> — <one line on the overlap and what is unclear>.
```

Flag it in the run report too, so the ambiguity is visible in two places rather than buried in an issue body.

### No match → file normally

Behavior is unchanged from before this check existed.

## Same-run batch self-check

Before filing, compare the candidate against issues **this run** already filed (tracked in a run-scoped registry such as `WRAP_FILED_ISSUES` in `/wrap`), not just against the repo. Two findings in one sweep that duplicate each other collapse into one issue; the second is recorded as suppressed, naming the first. Pass the run's already-filed numbers as `--exclude` so they cannot also come back as repo candidates and be double-counted.

## Never silent (shared obligation for every autonomous caller)

Every suppressed filing from any autonomous caller appears in that caller's run/sweep report with the issue it deferred to, in one of two shapes:

- `Appended to #638 instead of filing — "<finding summary>"`
- `Collapsed into #660 (filed earlier this run) — "<finding summary>"`

A finding that is neither filed nor reported is the outcome this whole mechanism exists to prevent. `/wrap`'s "Filings suppressed as duplicates" report section is the reference shape; every other autonomous caller must produce an equivalent — same content, its own format.

## Comment template (strong match)

```markdown
Additional observation from an automated filing:

<finding summary and context>

Filed here rather than as a new issue: this restates <the covering criterion>.

_Auto-filed by <caller name>._
```

## Tuning

`--min-coverage` (default `0.34`) controls **recall** — how many candidates you get to look at. Lowering it surfaces more candidates and costs only reading time; it does not by itself suppress anything, because suppression requires the four strong-match criteria. Raising it risks hiding the one candidate you needed to see. If in doubt, lower it.

## Reconciliation — Issue #677

Issue #677 ("improve /issue-maker title-only dedup") was closed as stale before this PR. Its premise — that `/issue-maker` used only title-matching — was superseded by PR #661, which pointed `/issue-maker` Step 4 at the shared body-aware `issue-dedup.sh` helper. Issue #677 covered no other autonomous filers (those are the subject of PR #680). There is no remaining work from #677 to carry forward.
