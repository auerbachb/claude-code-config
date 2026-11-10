<!-- churn-hotspot: .claude/scripts/README.md -->
# Hotspot Decision — .claude/scripts/README.md (re-anchor)

**Verdict:** KEEP the split delivered by PR #1448 + RE-ANCHOR the growth baseline
**Decided:** 2026-08-31
**Issue:** #1503 (supersedes closed Issue #898 as the scope anchor)
**Reporter:** `/wrap` churn sweep — `material_growth` bullet, score 11 vs baseline 5 @ 2026-08-25

Reference for Issue #1503. Not auto-loaded — the rule corpus carries none of this.

## Why this record exists

Issue #1503 asked for a structural cleanup of `.claude/scripts/README.md` plus a re-baselined growth gate. Measurement showed the **cleanup had already landed**: PR #1448 (Issue #898) split the index into 13 per-category docs under `docs/` on 2026-08-28. What remained was a stale gate anchor. This record documents the measurement, the re-anchor, and one non-obvious trap that would silently disable the watch.

## The structural cleanup was already delivered

Verified on this branch, not assumed:

| Check | Result |
|-------|--------|
| `scripts-catalog-lint.sh` | OK — 188 entries across 13 category docs |
| Entries on disk vs entries in docs | 188 = 188 (93 scripts + 93 tests + 2 Python helpers) |
| Ghost entries (listed, not on disk) | 0 |
| Missing entries (on disk, not listed) | 0 |
| Duplicate entries | 0 |
| Unique prose needing relocation | none — the README's `scripts/ vs hooks/` and `Not indexed here` sections are its own content, not displaced material |

So the issue's hypothesis — accretion ordering, uneven formats, ghost rows for removed scripts — did not hold at implementation time. `.claude/scripts/README.md` was left unmodified **deliberately**: it is a 38-line index that already meets the acceptance criteria, and gratuitously rewriting it would add a churn event to the very file under a churn watch.

The one real gap found against the "point at `--help` or the owning reference doc" criterion was that the category docs — the surface a reader actually lands on from the index — carried no contract pointer. One uniform line was added to each of the 12 non-test category docs. `docs/tests.md` was left alone: it already carries its own equivalent run instruction, and `--help` is not a uniform contract for test files.

## Why the gate fired: a trailing window, not live drift

The detector scores a file by **distinct merged PRs in a trailing 14-day window**. At the time of filing:

- `score: 11`, `pr_count: 11`, `conflict_rounds: 0`, window `--since 2026-08-17`.
- All 11 PRs are #1186, #1224, #1291, #1309, #1315, #1319, #1320, #1326, #1386, #1414, #1448 — **ten pre-split PRs plus the split itself**. Every one of them predates or performs the fix.
- Post-split churn on `.claude/scripts/README.md`: **0 PRs**. The detector does not report the path at all over `--since 2026-08-28` even at `--threshold 1`, while 21 other files do in that same run — a live, discriminating measurement, not an empty run.
- The accretion surface moved as designed: `docs/` took 6 PRs over the same post-split window, spread across 13 files, each below threshold.

The gate fired on churn the split had already eliminated but that the trailing window could not yet see.

## The re-anchor

`.claude/reference/churn-hotspot-baselines.json`, entry `.claude/scripts/README.md`:

| Field | Was | Now |
|-------|-----|-----|
| `score_at_decision` | 5 | 2 |
| `pr_count_at_decision` | 5 | 2 |
| `as_of` | 2026-08-25 | 2026-08-31 |
| `issue` | 898 | **898 (unchanged — see below)** |

The measured cleaned floor is 0 PRs. The schema requires `pr_count_at_decision >= 2`, so `2/2` is the closest legal encoding of that 0. It re-arms the watch at **score 4** — meaningful, since a file needs score >= 3 merely to enter the hotspot list, so re-entry at 3 stays quiet and 4 surfaces.

Recording the observed 11 instead would have set the next trip at 22 for a file whose post-cleanup rate is 0 — retiring the watch rather than re-anchoring it, which is the opposite of what Issue #1503 asked for.

## The trap: do not name #1503 as the baseline's issue key

`baseline_for()` in `churn-hotspot-wrap-plan.sh` matches a baseline entry only when `entry.issue == hotspot.existing_hotspot_issue`. The detector resolves `existing_hotspot_issue` by searching issues for the title `Refactor hotspot: <path>` or the body marker `<!-- churn-hotspot: <path> -->`.

- Issue #898 carries **both** the title convention and the body marker.
- Issue #1503 carries **neither**.

So the detector will keep resolving this path to #898 regardless of #1503 superseding it in scope. Pointing the baseline at 1503 was tested against the live detector output and produces:

```text
"kind": "closed_no_conflict_suppressed",
"baseline_score": null,
"reason": "no_matching_baseline"
```

— the path suppressed **permanently and silently**, with no bullet and no issue. The `issue` field is a join key, not provenance; supersession is recorded in the entry's `re_anchored_by: 1503` and here. **Do not "fix" this by pointing it at the newest issue.** If the anchor must move to a new issue, that issue has to carry the `Refactor hotspot: .claude/scripts/README.md` title or the `<!-- churn-hotspot: .claude/scripts/README.md -->` body marker first, and #898's marker has to stop winning the match.

## Expected transient (self-clearing, no action needed)

Because the 14-day window still holds the ten pre-split PRs, `/wrap` will keep emitting one `SWEEP_NEEDS_DECISION` bullet for this path while the score stays at or above the re-armed trip point of 4. Two distinct dates follow, as those PRs age out and the score decays 11 → 1:

- **~2026-09-08** — the score falls below 4 and **the bullet stops**.
- **~2026-09-11** — the last pre-split PR leaves the window; the score drops under the reporting threshold of 3 and the path leaves the hotspot list entirely.

That bullet **files nothing and blocks nothing** (`wrap/SKILL.md`: material-growth rows are reported, never auto-filed). It is expected, it is this record's subject, and it needs no new issue. After the drain the path drops out of the hotspot list entirely and the baseline sits armed at 4.

## Future-edits guardrail

Add new scripts by adding a row to the matching `docs/<category>.md`, never to `README.md` — that separation is what keeps this index off the hotspot list, and `scripts-catalog-lint.sh` fails CI if a script or test has no row. Re-file this hotspot only if `.claude/scripts/README.md` itself starts accreting again (score >= 4) or records a conflict round.

## Related

- `.claude/scripts/README.md` — the adjudicated index
- `.claude/scripts/docs/` — the 13 per-category docs that now carry every entry
- `.claude/reference/churn-hotspot-baselines.json` — the re-anchored baseline
- `.claude/scripts/churn-hotspots.sh` — detector (scoring, window, existing-issue lookup)
- `.claude/scripts/churn-hotspot-wrap-plan.sh` — classifier that owns `baseline_for()` and the 2× test
- `.github/scripts/scripts-catalog-lint.sh` — CI coverage gate for the catalog
- Issue #898 / PR #1448 — the split that delivered the cleanup; still the detector's join key
- Issue #1503 — this re-anchor
- Issue #1307 / PR #1319 — introduced the baseline file and the material-growth gate
- Issue #915 / PR #925 — why closed matches are reported rather than dropped
