# Churn hotspots — mechanism, calibration, and why the thresholds are what they are

Reference for `.claude/scripts/churn-hotspots.sh` and `/wrap` Phase 3 Step 3.10a (issue #755). Not auto-loaded — the rule corpus carries none of this.

## The problem being read

Some files are magnets: every feature passes through them, and any long-lived branch that touches one pays a conflict tax on every sync. The motivating incident: five separate PRs merged into the same form component in a single sitting while a sixth in-flight PR — a ~350-line re-indent of that file — re-resolved conflicts against it three times and rebased a fourth. The structural fix got filed, but only because a human noticed the pattern in a wrap-up summary. A prior fleet-wide episode (issue #671) surfaced the same way.

The signal was never hidden. It sits in merge history: the same path across many distinct merged PRs in a short window. Nothing read it. This tooling reads it.

## Division of responsibility

**`churn-hotspots.sh` detects. `/wrap` decides.**

The script is strictly read-only — no `gh issue create`, no comments, no state writes. That matches the other detectors here (`backlog-staleness.sh`, `clean-behind-check.sh`) and means it is safe to run anywhere, by anyone, at any time. Every mutation lives in `/wrap` Step 3.10a, where the reporting contract (`WRAP_FILED_ISSUES` → Step 4.3) already exists.

## The score

```
score = distinct_pr_count + (conflict_weight × conflict_rounds)     # conflict_weight default 2
hotspot  ⇔  score >= threshold  AND  distinct_pr_count >= 2
```

**Why conflict rounds are weighted at all.** PR count measures how *often* a file is touched; conflict rounds measure how much that touching actually *hurt*. A file touched by four PRs that never conflicted is busy; a file touched by three PRs where one re-resolved conflicts twice is expensive. Weight 2 makes one conflict round worth two ordinary PR touches — enough to promote a genuinely painful file, not enough to let conflicts dominate the ranking.

**Why the `distinct_pr_count >= 2` floor exists.** Without it, a single PR that re-resolved conflicts three times scores `1 + 2×3 = 7` and clears any sane threshold — reported as "multi-PR churn" when exactly one PR touched the file. That is a different problem (a big PR against a moving base, which is issue #754's territory) and a different fix. Conflict rounds accelerate a genuinely multi-PR file across the line; they can never manufacture a hotspot alone. This resolves the open question the ticket raised about whether a conflict event should be *required* before filing: it is not required, but it also cannot substitute for multi-PR churn.

**Where conflict rounds come from.** `.prs["<N>"].babysit.conflict_streak` in session state — written by `/babysit-pr` when it dispatches `/fixpr` against a conflicting PR — maxed with a forward-compatible `.prs["<N>"].conflict_rounds`. **Maxed, never summed**, so a babysit-driven `/fixpr` round is not double-counted.

This signal is honestly weak, and the script's header says so. `conflict_streak` is a resettable per-watcher streak rather than a lifetime total, and `/fixpr` and `/merge-conflict` keep their conflict detail on transient stdout — nothing persists it. It under-reports more often than not. That is acceptable because it is a *bonus* term: absent conflict data, the score degrades exactly to the PR count, which is the primary signal. Making it load-bearing would have meant new writers in two conflict-resolution skills — scope the ticket explicitly did not ask for.

## Calibration — read this before tuning

The default threshold of 3 over 14 days is sensitive, and how many files clear it scales with repo activity. Measured on this repo over one 14-day window covering **103 merged PRs**:

| Threshold | Files flagged |
|-----------|---------------|
| 3 (default) | 63 |
| 5 | 33 |
| 8 | 16 |
| 10 | 9 |

The distribution has a long tail: one file at 24 PRs, one at 17, then a slope down through dozens of files at 2–4 PRs. The top of that list is genuinely diagnostic — `.github/workflows/hook-scripts.yml` at 24 PRs is precisely the file issue #681 rewrote *because* it had become a recurring merge-conflict hotspot. The tail is mostly routine activity.

Two consequences:

1. **An active repo should raise `--threshold`.** A quiet repo should leave it at 3, where three PRs into one file over two weeks is a real signal.
2. **Any caller that files on this output must bound its own volume.** 63 auto-filed issues would bury the backlog the feature exists to inform.

## Why `/wrap` files at most one per run

Step 3.10a takes the single highest-scoring hotspot with no existing issue. Because each filed issue is then found by the lookup on subsequent runs, successive wraps work down the list one at a time, highest-signal first. Held-back candidates are always reported in one line — the repo's "no silent caps" norm — so a bounded run never reads as a complete one.

This is a deliberate exception to Phase 3's general "no cap on how many issues one run may file". That rule is right for transcript-derived loose ends, which are few and session-scoped. Churn candidates are neither.

**Comment idempotency.** When a hotspot already has an open issue, `/wrap` appends evidence **only when the PR it just merged is one of that hotspot's PRs**. Without that guard, every later wrap would append another comment restating the same history. A merging PR appears in the list exactly once, so the comment fires exactly once per contributing merge.

## Enumeration: git first, gh as fallback

**git path (primary).** `git log --no-merges --name-only` over the window. Squash-merged PRs carry GitHub's appended `(#N)` marker in the subject. Zero API calls, no rate limit, and it works in a fresh clone — a clone has the full history even with no session state.

**The scan is scoped to an explicit ref, never to the invoking checkout's `HEAD`** (issue #861). `/wrap` calls this from a feature-branch worktree, and that `HEAD` is wrong in both directions at once: it **misses** every squash commit merged to the default branch since the branch forked (including the one `/wrap` just created — Step 2.5 syncs the *root repo's* main, not the invoking worktree), and it **adds** unsquashed local commits that will never exist on the default branch. Measured on this repo from two real feature-branch worktrees over one 14-day window: one scan missed 7 merged PRs and 5 hotspots; the other invented a phantom PR that inflated 13 files by one PR each and manufactured 2 hotspots outright.

Resolution order: `--ref`, then `origin/HEAD` (so a default branch not named `main` resolves correctly), then `origin/main`, `origin/master`, `main`, `master` — remote-tracking refs before local branches, since a local `main` can lag origin. Resolution never reads `HEAD`, so a worktree and a detached HEAD resolve the same ref as the root checkout. An unresolvable `--ref` **exits 3**; scanning something other than what was asked for is the failure this guards against. When nothing resolves, the scan degrades to `HEAD` with a loud stderr warning, and **every run reports what it measured** via `scan_ref` / `scan_ref_source`.

Fetching is **opt-in** (`--fetch`), not the default: the script is otherwise read-only, and a blocking `git fetch` inside `/wrap` risks a hang (and, if killed, a stray `.git/FETCH_HEAD.lock`). In the `/wrap` flow the ref is already fresh — Step 2.5 syncs the root repo's `main`, and worktrees share that object database and those refs.

**Only a trailing `(#N)` marker is a PR number.** That suffix is what GitHub appends on squash-merge. A leading `type(#N):` prefix is an **issue** reference, so `fix(#749): repair thing (#750)` attributes to 750, and a subject carrying only the prefix — `docs(#838): summary`, the shape of every unsquashed feature-branch commit under this repo's convention — yields no PR and contributes nothing. Taking the *last* marker instead was correct only for commits already squashed onto the default branch; on any other commit it silently attributed churn to issue numbers.

A history the stricter rule empties out is indistinguishable from a merge-commit repo, so `--source auto` then falls through to the gh path below — real merged data rather than a confidently wrong empty answer.

**gh path (fallback).** `gh pr list --state merged` plus per-PR `pulls/{N}/files`, bounded by `--pr-cap`. Triggered when the git history carries **no PR markers at all** (merge-commit or rebase-merge repos leave none on file-bearing commits) or when `--repo` names a repo other than the checkout. This is the path that satisfies the "works from `gh` data alone" requirement.

The fallback is gated on *marker count*, not on an empty result. A run whose every touched path was excluded is a legitimate empty answer, not a reason to re-enumerate over the API.

**The window is day-granular on both paths.** `--since` is a calendar date (ET-anchored via `gh-window.sh`, or a git ref resolved to that commit's date), while `mergedAt` is a UTC instant. Comparing the two as instants made the gh path disagree with `git log --since` for the same input, and was outright unsound on the ref path: a resolved ref carries a local offset (`2026-03-01T18:00:00-05:00`) that string-compares incorrectly against UTC `Z` timestamps. Both paths now compare calendar date to calendar date, inclusive at the start boundary (`>=`, never `>` — per the boundary-inclusivity lesson).

**Renames are not followed.** A renamed file reads as two paths. `git log --follow` is single-path-only, so rename tracking is out of scope; a rename resets a file's apparent history.

## Exclusions

Default: `package-lock.json`, `yarn.lock`, `pnpm-lock.yaml`, `Cargo.lock`, `poetry.lock`, `go.sum`, `CHANGELOG.md` — generated or append-only files that churn by design and are never refactor candidates.

The list is deliberately **universal**. Repo-specific by-design churn belongs in `--exclude`, not baked in: this repo's `.claude/scripts/README.md` scores 12 PRs purely because every new script registers a row there, but that is a fact about this repo, not about lockfiles everywhere.

## The dedup key

Hotspots are keyed by **file path**, which has an exact answer, so the fuzzy `issue-dedup.sh` ladder is the wrong instrument. Full rationale and the contract live in `autofile-dedup.md` under "Exact-artifact dedup". In short: title `Refactor hotspot: <path>` or body marker `<!-- churn-hotspot: <path> -->`, compared **client-side with string equality** because GitHub tokenizes paths in `in:title` search and would match sibling files. A failed lookup (`existing_lookup_failed`) blocks filing rather than risking a duplicate.

**A capped lookup counts as a failed one.** When the search hits `ISSUE_LOOKUP_CAP` (200), a matching issue may sit beyond the cap, so "no match" no longer proves "no issue". Setting only `truncated` would leave callers — which gate filing on `existing_lookup_failed` — free to file a duplicate for a hotspot that already has a ticket. Both flags are set.

## Implementation notes worth keeping

**Plain ASCII sentinels, not control bytes.** The git-log parser marks commit headers with `@@C@@`/`@@S@@`. An earlier version used `\x01`/`\x02`, which failed on macOS: under bash 3.2, `${line#$'\x01'}` silently does not strip even where the matching `case` pattern succeeds, so the byte leaked into every timestamp while the PR numbers parsed fine — a corruption visible only in the JSON output. Nothing in the parser now relies on ANSI-C quoting.

**`grep -c` is not a safe counter.** On an empty file it prints `0` *and* exits 1, so a `|| echo 0` fallback emits `"0\n0"` and breaks the downstream `jq --argjson`. Counters use `wc -l | tr -d '[:space:]'` and pass through an `as_number` coercion before any jq call, so a malformed counter can never abort the emit.

## Related

- Issue #754 — clean-BEHIND churn (removes the cost once churn happens; this reduces why it recurs).
- Issue #671 — the prior rebase-treadmill incident, hand-noticed.
- Issue #681 — `hook-scripts.yml` de-hotspotting, the change this detector would have flagged.
