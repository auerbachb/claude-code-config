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

## Creation commits and repo-wide sweeps score 0 (issue #1547)

A three-round triage of the 39 flagged files closed **37** of them as by-design. `conflict_rounds` was **0** on all 39 — the conflict signal never false-alarmed once; the raw touch count did, 37 times. Two shapes supplied most of that inflation, and both are now filtered.

**1. A file's own creation is not churn.** 7 of round 3's 14 files were created inside their own scan window, so the birth commit counted toward the score: a brand-new file mechanically started at 1–2 and reached the reporting threshold on one sweep plus one real touch. The creating commit is now excluded — diff status `A` on the git path, `"status": "added"` on the gh path. A rename *destination* is not treated as a creation: renames already read as two unrelated paths here, and the mass renames that motivated this are caught by rule 2 anyway. `--include-creation` restores the old behaviour.

**2. A repo-wide mechanical sweep is not file-local churn.** One 72-file sweep (PR #1458, a `script-usage.log` redirection-order fix applied identically everywhere) and two 39-file rename sweeps (PRs #1313, #1320) supplied the majority of events across dozens of flagged files, with zero relationship to any of those files' concerns. A commit touching **>= `--sweep-threshold` paths (default 20)** now contributes nothing.

The sweep count is the commit's **raw** path total, taken *before* the exclusion and existence filters — a 72-file sweep is still a sweep after 60 of its paths were deleted or excluded. The unit differs per enumeration path: a **commit** on the git path, the **whole PR file list** on the gh path, which has no per-commit granularity. For a squash-merge repo those are the same thing.

**Both rules drop the touch EVENT; neither re-weights the score.** That is not a stylistic choice. `churn-hotspot-wrap-plan.sh` validates the envelope with `score == pr_count + conflict_weight × conflict_rounds` plus `floor == .` on every count, and `/wrap` Step 3.10a files nothing when that assertion fails. A *fractional* sweep weight would break the consumer contract outright, so the AC's "0 or fractionally" is implemented at 0 — which, expressed as a dropped event, needs no consumer change at all. A PR still counts for a file whenever some *other* commit of that PR touched it non-mechanically, which is exactly what weighting the sweep commit 0 means.

Only in-window commits are scanned, so a file created *before* the window is untouched by rule 1 — the #1415 shape, where the creation PR aged out of the window on its own.

**The creation fact is reported, not merely spent.** Each hotspot carries `created_in_window` and `creation_pr`, recorded whether or not the creation touch scored. A file born in the window that still crosses the threshold on its other PRs can then be read for what it is instead of looking like a long-standing magnet.

**Measured effect** on the `--since 2026-08-15` window (133 merged PRs, `origin/main`): **111 hotspots → 64**. 87 creation touches and 295 sweep touches across 10 sweep commits were dropped. Of the 53 files with an already-closed by-design hotspot issue that the old detector still flagged, **24 stopped being flagged**. The rest are catalogs, registries, and central contracts whose churn is genuinely file-local and by design — those were never mechanical inflation, and the consumer's closed/zero-conflict suppression is what handles them.

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

**Both backends enumerate NUL-delimited, end to end** (issue #1554). A path may carry any byte except NUL and `/` — a newline included — so NUL is the only separator a filename cannot forge. git emits `git log -z --name-status -M` tokens; the gh path pipes the raw `pulls/{N}/files` JSON through `jq`, which emits the same `status NUL filename NUL` pairs; and both spool files carry NUL-terminated rows, so nothing between the source and the report can split a path in half. Framing and the pre-fix failure modes: [Delimiters](#delimiters-why-nul-and-nothing-else) below.

**git path (primary).** `git log --no-merges --name-status -z -M` over the window. Squash-merged PRs carry GitHub's appended `(#N)` marker in the subject. Zero API calls, no rate limit, and it works in a fresh clone — a clone has the full history even with no session state.

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

The list is deliberately **universal**. Repo-specific by-design churn is not baked in here — a lint-enforced catalog belongs in the persisted **exemption file** below (which requires a stated lint), while `--exclude` stays what it always was: the per-invocation escape hatch, and the home for generated files.

## Catalog exemptions (issue #1571)

Three different things now keep a file quiet, and conflating them is how one of them ends up doing the wrong job:

| Term | Who does it | What happens to the file |
|------|-------------|--------------------------|
| **excluded** | detector, `--exclude` / `DEFAULT_EXCLUDES` | The touch event is dropped before aggregation. The file is never scored and appears nowhere but `excluded_count`. |
| **exempt (catalog)** | detector, `.claude/reference/churn-hotspot-exemptions.json` | The file is scored normally, then reclassified out of `hotspots[]` into `exemptions[]` and onto a distinct `# exempt (catalog)` TSV line. Score history stays complete; the **flag** is suppressed, not the fact. |
| **suppressed** | `churn-hotspot-wrap-plan.sh` | The file is a real hotspot with a closed issue and no conflict cost; `/wrap` hides the decision bullet until the 2× material-growth gate trips. |

**The problem being solved.** Some files churn because a **lint requires it**. `.claude/scripts/README.md` and `.claude/scripts/docs/tests.md` are enforced by `scripts-catalog-lint.sh` (via `run-doc-lints.sh` in `rule-lint.yml`): the index must link every category doc exactly once and hold no per-script rows, and every `tests/*.test.sh` needs exactly one catalog row. Adding or renaming a script or a test suite therefore *has* to edit them, or CI fails. No refactor can retire that flag — the scripts README hit 3–5× its baseline twice in one week *after* its hotspot issue (#898) closed, each time producing an advisory flag and a needs-decision item. A flag that can never be resolved is not a signal; it is training to skim past churn warnings, which is how a real hotspot eventually gets missed.

**Every entry must name its enforcing lint.** `lint` and `reason` are both required and both must be non-empty; an entry supplying neither is rejected with **exit 3 naming the offending path**. That is the whole guard against the mechanism becoming a mute button: a file cannot claim exemption by assertion, only by pointing at the check that forces the edit. `lint` is the short enforcing-check token the TSV prints; `reason` is the sentence explaining why that check forces a row edit.

**Scoring is untouched, and the flag is what is suppressed.** Exempt files run through the identical score formula and keep their real `pr_count`, `pr_numbers`, `score`, and window bounds — the open question in the ticket, answered the way it leaned. Only the classification changes. Consequences worth stating:

- **Reported, never silently omitted.** Any exempt file touched in the window appears in `exemptions[]` and on its TSV line *regardless of threshold*; the `score >= threshold AND pr_count >= 2` floor governs `hotspots[]` alone. It is also reported on the clean exit-1 path, which is exactly where a suppressed file would otherwise disappear.
- **Non-exempt scoring is byte-for-byte unchanged.** Partitioning happens after scoring, so a control file with identical churn flags exactly as before — pinned by a regression assertion comparing the same fixture with and without the feature.
- **The exit code keys on `hotspots[]` alone.** A run whose only reported paths are exempt is clean (exit 1).
- **The issue lookup is skipped** for exempt files — they are never filed, so there is nothing to dedupe against.
- **Exclusion still wins.** An excluded path never reaches aggregation, so it can never surface on the exempt line.

**No consumer change was needed.** `churn-hotspot-wrap-plan.sh` classifies `hotspots[]`; an exempt file is simply absent from it, so no comment, file, growth, unknown, or suppressed entry is produced and the wrap sweep stops asking the same keep-or-reopen question every run. The envelope validator checks named fields rather than rejecting unknown ones, so `exemptions`, `exempt_count`, and `exemptions_file` pass through untouched.

**`--no-exemptions` is the negative control**, and it wins over `--exemptions` (the file is then not read at all). The disabled state is never silent: `exemptions_file` reports `null`.

**An explicit `--exemptions` is a promise about which policy the run applied**, so every way of breaking it is refused rather than downgraded: an unreadable or invalid file **exits 3**, and an *empty* value (`--exemptions ''` or `--exemptions=`) **exits 2** at parse time. The empty case needs its own guard because it is the one that fails quietly — the argument is present, so the "requires a value" check passes, but downstream an empty value is indistinguishable from never having passed the flag, and the run would silently score against the **default** catalog the caller did not name.

**Possible follow-up, deliberately out of scope.** Auto-generating the catalog rows from the directory contents would remove both the churn *and* the recurring merge-conflict surface — a base-commit overlap in the tests catalog forced a rebase on PR #1543 on 2026-09-01. That is a larger change to the lint contract itself and is noted here rather than attempted.

## The dedup key

Hotspots are keyed by **file path**, which has an exact answer, so the fuzzy `issue-dedup.sh` ladder is the wrong instrument. Full rationale and the contract live in `autofile-dedup.md` under "Exact-artifact dedup". In short: title `Refactor hotspot: <path>` or body marker `<!-- churn-hotspot: <path> -->`, compared **client-side with string equality** because GitHub tokenizes paths in `in:title` search and would match sibling files. A failed lookup (`existing_lookup_failed`) blocks filing rather than risking a duplicate.

**The lookup is `--state all`, and it reports which state matched** (issue #915). It was `--state open` at first, which quietly made the detector unable to see its own past output: once a hotspot issue was reviewed and closed, the path read as `existing_hotspot_issue: null` — a blank slate — so `/wrap` re-filed it, and re-filed it again on the next wrap, forever. It had already produced one duplicate in this repo — issue #815 closed and issue #881 open for the same file — and had two more queued in a sibling repo before the pattern was noticed. Each hotspot now carries `existing_hotspot_issue_state` beside the number: `open`, `closed`, `unknown` (matched, but the state could not be read), or `null` — and `null` means **no match at all**, never "matched but unclassifiable". That distinction is the same bug in miniature: a consumer branching on `state == null` would read a matched hotspot as a blank slate, so the unreadable case gets its own value rather than sharing null's.

**An open match beats a closed one for the same path.** That preference is not cosmetic — it is what terminates the loop. When `/wrap` re-files a closed hotspot, the new open issue becomes the chosen match on the following run, so the next wrap comments instead of filing again. Picking whichever the search returned first would leave the closed one winning at random and the loop half-alive.

**A capped lookup counts as a failed one.** When the search hits `ISSUE_LOOKUP_CAP` (200), a matching issue may sit beyond the cap, so "no match" no longer proves "no issue". Setting only `truncated` would leave callers — which gate filing on `existing_lookup_failed` — free to file a duplicate for a hotspot that already has a ticket. Both flags are set. **`--state all` enlarges the candidate set**, so this guard matters more than it did, not less — closed issues alone can now fill the cap. The cap stays at 200 rather than being raised: the count-based guard already fails safe, and raising it trades a known-safe bound for tuning nobody has evidence for.

## Delimiters: why NUL, and nothing else

The detector once used a newline as its record separator on both backends. A filename may legally contain one, and each backend then failed differently on the same input (issue #1554):

- **gh — a miscount.** The record stream came from `gh api --jq '… | join("<TAB>")'` and the per-PR total came from `wc -l`. One embedded-newline filename made a 2-file PR count as **3**, which drove the `--sweep-threshold` classification off the wrong number. Measured against the pre-fix script: a 2-file payload at `--sweep-threshold 3` was classified as a sweep and scored nothing.
- **git — a disappearance.** git C-quotes such a path onto a single line (`"src/two\nlines.ts"`) even with `core.quotePath=false`, so the count was right — but the *escaped* string was then handed to `git cat-file -e`, which cannot find a file by that literal name, and the path was dropped as `missing_count`. Same measurement: the file was simply absent from the report.

So neither backend told the truth and the two disagreed about identical history, which is what the parity scenario now pins.

**git framing (`-z`, measured on git 2.50.1).** A `tformat` commit header is NUL-terminated; exactly one LF then precedes that commit's first status token; thereafter fields alternate `status NUL path NUL`, or `R100 NUL old NUL new NUL` for a rename/copy. The parser strips that LF only in the status state — a diff status can never begin with a newline, while a path can, so the strip is positional and cannot touch a filename. `%s` is the subject *line*, so a header token never contains a newline of its own.

**`core.quotePath=false` is now redundant, and deliberately kept.** `-z` emits paths verbatim even with quoting on (verified). Keeping the setting costs nothing and means a future edit that drops `-z` fails the embedded-newline test loudly instead of quietly regressing non-ASCII paths as well.

**Status and path live in parallel arrays, not one `status<TAB>path` string.** That is a requirement, not tidiness: `-z` hands over verbatim paths, so a filename containing a TAB now reaches the buffer, and `${row##*<TAB>}` would silently return its last fragment as the path. Separate array slots leave no delimiter to be forged.

**The NUL literal is spelled `[0] | implode`, not a `\u0000` escape.** `jq --raw-output0` reads better but arrived in jq 1.7, and this script claims no jq floor (CI runs ubuntu-latest *and* macos-latest). `implode` works everywhere jq does.

**The gh stream is spooled to a file, never captured.** Command substitution strips NUL bytes — precisely the byte carrying the record boundary — so `files=$(gh api …)` cannot hold this stream. jq also runs *outside* `gh` (no `--jq`): gh's writer newline-terminates every result, and a newline is exactly what must not delimit records here.

**Spool rows put the path last.** `TOUCH_TSV` rows are `pr <TAB> merged_at <TAB> file`; `CREATION_TSV` rows are `pr <TAB> file`. The reader rejoins every field past the last fixed one, so a TAB inside a filename survives as well as a newline does. The `--json` schema and the six documented TSV columns are unchanged — jq's `@tsv` already escapes `\n`, `\t`, `\r` and `\\` — so `churn-hotspot-wrap-plan.sh` needed no change.

**Behaviour on ordinary history is unchanged.** Verified against this repo's live 14-day window (135 merged PRs): the rewritten detector reproduces the pre-fix run's counters and its full 64-hotspot list exactly.

## Implementation notes worth keeping

**Plain ASCII sentinels, not control bytes.** The git-log parser marks commit headers with `@@C@@`/`@@S@@`. An earlier version used `\x01`/`\x02`, which failed on macOS: under bash 3.2, `${line#$'\x01'}` silently does not strip even where the matching `case` pattern succeeds, so the byte leaked into every timestamp while the PR numbers parsed fine — a corruption visible only in the JSON output. Nothing in the parser now relies on ANSI-C quoting.

**`grep -c` is not a safe counter.** On an empty file it prints `0` *and* exits 1, so a `|| echo 0` fallback emits `"0\n0"` and breaks the downstream `jq --argjson`. Counters use `wc -l | tr -d '[:space:]'` and pass through an `as_number` coercion before any jq call, so a malformed counter can never abort the emit.

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
| `sweep_threshold` | number | Path count at or above which a commit/PR is a sweep (default 20; 0 disables) — issue #1547 |
| `include_creation` | boolean | True when `--include-creation` re-enabled scoring of creation commits |
| `creation_skipped_count` | number | Touches dropped because the commit created that path |
| `sweep_commit_count` | number | Commits (git path) or PRs (gh path) classified as sweeps |
| `sweep_skipped_count` | number | Touches dropped because their commit was a sweep |
| `truncated` | boolean | True when `--top` or the issue-lookup cap clipped output |
| `existing_lookup_failed` | boolean | True when the issue lookup was incomplete or errored |
| `total_hotspot_count` | number | Full pre-truncation hotspot count |
| `exemptions_file` | `string` or `null` | Resolved exemption file, or `null` when the feature is off or no file was found — issue #1571 |
| `exempt_count` | number | Touched exempt files; always equals the length of `exemptions` |
| `exemptions` | array | Scored catalog-exempt entries, never bounded by `--top` or the threshold |
| `hotspots` | array | Scored hotspot entries (see fields below) |

Each `hotspots[]` entry: `file`, `pr_count`, `pr_numbers`, `conflict_rounds`, `conflict_prs`, `score`, `first_merged_at`, `last_merged_at`, `created_in_window`, `creation_pr`, `existing_hotspot_issue`, `existing_hotspot_issue_state`.

Each `exemptions[]` entry carries the same scored fields **minus** the two issue-lookup fields (exempt files are never filed), **plus** `lint` and `reason` copied from the exemption entry.

A path dropped by exclusion is counted only as `excluded_count`, never also as swept — the filters are applied in order (exclusion, existence, sweep, creation) and each touch is counted exactly once. Exemption is not one of those filters: it runs *after* scoring, so an exempt path is counted exactly once as an ordinary touch and then reclassified.

## Related

- Issue #754 — clean-BEHIND churn (removes the cost once churn happens; this reduces why it recurs).
- Issue #671 — the prior rebase-treadmill incident, hand-noticed.
- Issue #681 — `hook-scripts.yml` de-hotspotting, the change this detector would have flagged.
- Issue #1118 — false-positive for deleted file; added existence filter and `missing_count`.
- Issue #1547 — creation commits and repo-wide sweeps inflated every score; both now weighted 0. Evidence: the 37 by-design closures from triage rounds 1–3, notably Issues #1341, #1408, and #1415.
- Issue #1571 — lint-enforced catalog files churn by design and no refactor can retire their flag; they are now exempted (scored, reported, never flagged). Seeded with `.claude/scripts/README.md` and `.claude/scripts/docs/tests.md`, both enforced by `scripts-catalog-lint.sh`.
- Issue #898 — the scripts-catalog split that reduced, but could not remove, the index's lint-forced churn.
