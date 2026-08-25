# Churn hotspots — mechanism, calibration, and why the thresholds are what they are

Reference for `.claude/scripts/churn-hotspots.sh` and `/wrap` Phase 3 Step 3.10a (issue #755). Not auto-loaded — the rule corpus carries none of this.

## The problem being read

Some files are magnets: every feature passes through them, and any long-lived branch that touches one pays a conflict tax on every sync. The motivating incident: five separate PRs merged into the same form component in a single sitting while a sixth in-flight PR — a ~350-line re-indent of that file — re-resolved conflicts against it three times and rebased a fourth. The structural fix got filed, but only because a human noticed the pattern in a wrap-up summary. A prior fleet-wide episode (issue #671) surfaced the same way.

The signal was never hidden. It sits in merge history: the same path across many distinct merged PRs in a short window. Nothing read it. This tooling reads it.

## Division of responsibility

**`churn-hotspots.sh` detects. `churn-hotspot-wrap-plan.sh` classifies. `/wrap` mutates.**

The script is strictly read-only — no `gh issue create`, no comments, no state writes. That matches the other detectors here (`backlog-staleness.sh`, `clean-behind-check.sh`) and means it is safe to run anywhere, by anyone, at any time. Every mutation lives in `/wrap` Step 3.10a, where the reporting contract (`WRAP_FILED_ISSUES` → Step 4.3) already exists.

The wrap-specific classifier is also read-only. It consumes the detector's unchanged JSON envelope and `.claude/reference/churn-hotspot-baselines.json`, then emits disjoint comment, file, growth, unknown, and suppression sets. Keeping those predicates in an offline-tested consumer prevents the prose workflow from drifting away from the policy it claims to apply.

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

Step 3.10a takes the single highest-scoring **eligible** hotspot. Because each filed issue is then found by the lookup on subsequent runs, successive wraps work down the list one at a time, highest-signal first. Held-back candidates are always reported in one line — the repo's "no silent caps" norm — so a bounded run never reads as a complete one.

This is a deliberate exception to Phase 3's general "no cap on how many issues one run may file". That rule is right for transcript-derived loose ends, which are few and session-scoped. Churn candidates are neither.

**Eligible means one of two things** (issue #915). Either the hotspot has no existing issue at all — the original case, which files clean — or it has a **closed** match *and* `conflict_rounds > 0`, which re-files with the `Possibly duplicates #{N}` caveat and lands under "needs your decision" rather than "auto-handled". The one-issue-per-run cap spans both kinds, so widening eligibility does not widen volume.

**Why the conflict gate, specifically.** The closing note on the issue that exposed this asked for exactly this condition. That hotspot was closed because the churn was by design — a repo convention requiring every flow-changing PR to touch one canonical file — and the note said `/wrap` would re-file automatically once the churn started costing something measurable. `conflict_rounds` is the only measurable cost this detector records. Rising PR count is not — that is precisely what the closed issue already accounted for. So a closed hotspot with `conflict_rounds == 0` never re-files automatically; re-filing it on PR count alone would silently overturn a recorded owner decision, which is the failure mode #915 exists to stop.

**Closed zero-cost findings are aggregated, not re-asked** (Issue #1307). `/wrap` used to turn every closed match with `conflict_rounds == 0` into an individual pending decision. In a measured 66-PR window all 35 hotspots had zero conflict cost, so every session repeated the same owner question. The consumer now suppresses those per-file bullets and records one verbose aggregate: total hotspots, hotspots with conflict cost, items surfaced for decision, and closed/no-cost items suppressed. The detector still reports closed matches exactly as Issue #915 requires; this is strictly consumer-side filtering, and silent mode remains silent.

## Decision baselines and the material-growth gate

`.claude/reference/churn-hotspot-baselines.json` records the score present when an owner closed a zero-conflict hotspot or reaffirmed that its current structure should remain. Each file-keyed entry carries the exact issue number, `score_at_decision`, `pr_count_at_decision`, and `as_of` date. Both file and issue must match before the baseline is trusted; a reopened/replaced issue cannot accidentally inherit an older verdict.

A closed zero-conflict hotspot returns as a pending decision only when its current score is at least **2×** `score_at_decision`. Doubling is intentionally conservative: linear growth is normal for catalogs, registries, and central workflow contracts, while a 100% increase is a step-change in how much work passes through the file. Scores below that gate remain in the aggregate. A missing or mismatched baseline also remains suppressed and is counted as `no_matching_baseline`, because absent history cannot prove material post-decision growth.

When a zero-conflict hotspot issue is closed, or an owner explicitly reaffirms a keep/monolith verdict, capture or refresh the entry from an untruncated default-branch detector run. The baseline is evidence of a real decision, not a tuning knob: never raise it merely to silence a growth signal. Positive conflict cost bypasses this baseline and preserves the Issue #915 closed-match re-file behavior.

**Comment idempotency.** When a hotspot already has an open issue, `/wrap` appends evidence **only when the PR it just merged is one of that hotspot's PRs**. Without that guard, every later wrap would append another comment restating the same history. A merging PR appears in the list exactly once, so the comment fires exactly once per contributing merge. The comment set is **open-only** — a closed issue cannot take a new evidence comment, so a closed match routes to the branches above instead.

## Enumeration: git first, gh as fallback

**git path (primary).** `git log --no-merges --name-only` over the window. Squash-merged PRs carry GitHub's appended `(#N)` marker in the subject. Zero API calls, no rate limit, and it works in a fresh clone — a clone has the full history even with no session state.

**The scan is scoped to an explicit ref, never to the invoking checkout's `HEAD`** (issue #861). `/wrap` calls this from a feature-branch worktree, and that `HEAD` is wrong in both directions at once: it **misses** every squash commit merged to the default branch since the branch forked (including the one `/wrap` just created — Step 2.5 syncs the *root repo's* main, not the invoking worktree), and it **adds** unsquashed local commits that will never exist on the default branch. Measured on this repo from two real feature-branch worktrees over one 14-day window: one scan missed 7 merged PRs and 5 hotspots; the other invented a phantom PR that inflated 13 files by one PR each and manufactured 2 hotspots outright.

Resolution order: `--ref`, then `origin/HEAD` (so a default branch not named `main` resolves correctly), then `origin/main`, `origin/master`, `main`, `master` — remote-tracking refs before local branches, since a local `main` can lag origin. Resolution never reads `HEAD`, so a worktree and a detached HEAD resolve the same ref as the root checkout. An unresolvable `--ref` **exits 3**; scanning something other than what was asked for is the failure this guards against. When nothing resolves, the scan degrades to `HEAD` with a loud stderr warning, and **every run reports what it measured** via `scan_ref` / `scan_ref_source`.

Fetching is **opt-in** (`--fetch`), not the default: the script is otherwise read-only, and a blocking `git fetch` inside `/wrap` risks a hang (and, if killed, a stray `.git/FETCH_HEAD.lock`). In the `/wrap` flow the ref is already fresh — Step 2.5 syncs the root repo's `main`, and worktrees share that object database and those refs.

**Only a trailing `(#N)` marker is a PR number.** That suffix is what GitHub appends on squash-merge. A leading `type(#N):` prefix is an **issue** reference, so `fix(#749): repair thing (#750)` attributes to 750, and a subject carrying only the prefix — `docs(#838): summary`, the shape of every unsquashed feature-branch commit under this repo's convention — yields no PR and contributes nothing. Taking the *last* marker instead was correct only for commits already squashed onto the default branch; on any other commit it silently attributed churn to issue numbers.

A history the stricter rule empties out is indistinguishable from a merge-commit repo, so `--source auto` then falls through to the gh path below — real merged data rather than a confidently wrong empty answer.

**gh path (fallback).** `gh pr list --state merged` plus per-PR `pulls/{N}/files`, bounded by `--pr-cap`. Triggered when the git history carries **no PR markers at all** (merge-commit or rebase-merge repos leave none on file-bearing commits) or when `--repo` names a repo other than the checkout. This is the path that satisfies the "works from `gh` data alone" requirement.

**An explicit `--ref` never survives the gh fallback — it exits 3.** The gh path enumerates merged PRs repo-wide and has no way to honour a ref, so a run that reaches it with `--ref` set would answer a different question than the one asked, wearing the caller's ref as authority. `--source gh --ref` is already an up-front usage error; discovering the same combination later (the ref resolved, but carried no PR-marked commits) is refused just as hard rather than downgraded to a warning. A stderr warning would not do: `/wrap`'s documented call site is `"$CHURN_SH" --json 2>/dev/null`, which discards stderr entirely. `--source git` is the escape hatch — it pins the git path and scans the ref as-is, reporting a clean exit 1 when nothing crosses the threshold.

The fallback is gated on *marker count*, not on an empty result. A run whose every touched path was excluded is a legitimate empty answer, not a reason to re-enumerate over the API.

**The window is day-granular on both paths.** `--since` is a calendar date (ET-anchored via `gh-window.sh`, or a git ref resolved to that commit's date), while `mergedAt` is a UTC instant. Comparing the two as instants made the gh path disagree with `git log --since` for the same input, and was outright unsound on the ref path: a resolved ref carries a local offset (`2026-03-01T18:00:00-05:00`) that string-compares incorrectly against UTC `Z` timestamps. Both paths now compare calendar date to calendar date, inclusive at the start boundary (`>=`, never `>` — per the boundary-inclusivity lesson).

**Renames are not followed.** A renamed file reads as two paths. `git log --follow` is single-path-only, so rename tracking is out of scope; a rename resets a file's apparent history.

**Files absent from the scanned tree are dropped** (issue #1118). A path that appears in git history but no longer exists is not a refactor candidate — it cannot be split, extracted, or refactored. Before writing any row to the touch TSV, the detector checks that the file is present: `git cat-file -e "$SCAN_REF:$file"` on the git path (where `SCAN_REF` is the resolved default-branch ref), or `[ -e "$file" ]` on the gh fallback path when scanning the same checkout (`IN_CHECKOUT=1`, where `SCAN_REF` is empty and a working-tree check is reliable); cross-repository gh scans (`--repo` naming a different repo, so `IN_CHECKOUT=0`) skip the existence filter — the caller's working tree is unrelated to the target repository, and applying a local check would silently drop every valid remote path. Dropped paths increment `missing_count`, reported as a top-level JSON field alongside `excluded_count`. This prevents deleted files from being re-surfaced as hotspots on every subsequent `/wrap` run — a false-positive gap first noticed via the `open-code-review/SKILL.md` hotspot filed by PR #1117 (Issue #1118), where the file had been deleted by PR #822 but its three-PR git history still crossed the threshold.

## Exclusions

Default: `package-lock.json`, `yarn.lock`, `pnpm-lock.yaml`, `Cargo.lock`, `poetry.lock`, `go.sum`, `CHANGELOG.md` — generated or append-only files that churn by design and are never refactor candidates.

The list is deliberately **universal**. Repo-specific by-design churn belongs in `--exclude`, not baked in: this repo's `.claude/scripts/README.md` scores 12 PRs purely because every new script registers a row there, but that is a fact about this repo, not about lockfiles everywhere.

## The dedup key

Hotspots are keyed by **file path**, which has an exact answer, so the fuzzy `issue-dedup.sh` ladder is the wrong instrument. Full rationale and the contract live in `autofile-dedup.md` under "Exact-artifact dedup". In short: title `Refactor hotspot: <path>` or body marker `<!-- churn-hotspot: <path> -->`, compared **client-side with string equality** because GitHub tokenizes paths in `in:title` search and would match sibling files. A failed lookup (`existing_lookup_failed`) blocks filing rather than risking a duplicate.

**The lookup is `--state all`, and it reports which state matched** (issue #915). It was `--state open` at first, which quietly made the detector unable to see its own past output: once a hotspot issue was reviewed and closed, the path read as `existing_hotspot_issue: null` — a blank slate — so `/wrap` re-filed it, and re-filed it again on the next wrap, forever. It had already produced one duplicate in this repo — issue #815 closed and issue #881 open for the same file — and had two more queued in a sibling repo before the pattern was noticed. Each hotspot now carries `existing_hotspot_issue_state` beside the number: `open`, `closed`, `unknown` (matched, but the state could not be read), or `null` — and `null` means **no match at all**, never "matched but unclassifiable". That distinction is the same bug in miniature: a consumer branching on `state == null` would read a matched hotspot as a blank slate, so the unreadable case gets its own value rather than sharing null's.

**An open match beats a closed one for the same path.** That preference is not cosmetic — it is what terminates the loop. When `/wrap` re-files a closed hotspot, the new open issue becomes the chosen match on the following run, so the next wrap comments instead of filing again. Picking whichever the search returned first would leave the closed one winning at random and the loop half-alive.

**A capped lookup counts as a failed one.** When the search hits `ISSUE_LOOKUP_CAP` (200), a matching issue may sit beyond the cap, so "no match" no longer proves "no issue". Setting only `truncated` would leave callers — which gate filing on `existing_lookup_failed` — free to file a duplicate for a hotspot that already has a ticket. Both flags are set. **`--state all` enlarges the candidate set**, so this guard matters more than it did, not less — closed issues alone can now fill the cap. The cap stays at 200 rather than being raised: the count-based guard already fails safe, and raising it trades a known-safe bound for tuning nobody has evidence for.

## Implementation notes worth keeping

**Plain ASCII sentinels, not control bytes.** The git-log parser marks commit headers with `@@C@@`/`@@S@@`. An earlier version used `\x01`/`\x02`, which failed on macOS: under bash 3.2, `${line#$'\x01'}` silently does not strip even where the matching `case` pattern succeeds, so the byte leaked into every timestamp while the PR numbers parsed fine — a corruption visible only in the JSON output. Nothing in the parser now relies on ANSI-C quoting.

**`grep -c` is not a safe counter.** On an empty file it prints `0` *and* exits 1, so a `|| echo 0` fallback emits `"0\n0"` and breaks the downstream `jq --argjson`. Counters use `wc -l | tr -d '[:space:]'` and pass through an `as_number` coercion before any jq call, so a malformed counter can never abort the emit.

## Related

## Output fields (JSON envelope)

| Field | Type | Description |
|-------|------|-------------|
| `repo` | string | Owner/repo the scan targeted |
| `since` | string | Window start (YYYY-MM-DD or ISO timestamp) |
| `source` | string | `git` or `gh` — which enumeration path was used |
| `scan_ref` | string | Git ref scanned (empty on the gh path) |
| `scan_ref_source` | string | `explicit`, `origin-head`, `candidate`, `head-fallback`, or `n/a` |
| `threshold` | number | Score threshold (default 3) |
| `conflict_weight` | number | Weight per conflict round (default 2) |
| `min_prs` | number | Minimum distinct PRs floor (default 2) |
| `scanned_pr_count` | number | Distinct merged PRs seen in the window |
| `excluded_count` | number | Paths dropped by the exclusion list |
| `missing_count` | number | Paths dropped because the file does not exist at the scanned ref or in the working tree (issue #1118) |
| `truncated` | boolean | True when `--top` or the issue-lookup cap clipped output |
| `existing_lookup_failed` | boolean | True when the issue lookup was incomplete or errored |
| `total_hotspot_count` | number | Full pre-truncation hotspot count |
| `hotspots` | array | Scored hotspot entries (see fields below) |

Each `hotspots[]` entry: `file`, `pr_count`, `pr_numbers`, `conflict_rounds`, `conflict_prs`, `score`, `first_merged_at`, `last_merged_at`, `existing_hotspot_issue`, `existing_hotspot_issue_state`.

## Related

- Issue #754 — clean-BEHIND churn (removes the cost once churn happens; this reduces why it recurs).
- Issue #671 — the prior rebase-treadmill incident, hand-noticed.
- Issue #681 — `hook-scripts.yml` de-hotspotting, the change this detector would have flagged.
- Issue #1118 — false-positive for deleted file; added existence filter and `missing_count`.
