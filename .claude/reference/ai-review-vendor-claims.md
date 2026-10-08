# AI review vendor claims — published accuracy figures

**Issue:** [#1811](https://github.com/auerbachb/claude-code-config/issues/1811) — increment 4 of 5 under [#1747](https://github.com/auerbachb/claude-code-config/issues/1747)
**Last verified:** 2026-10-08 (every source below was re-read on this date)
**Read by:** `/review-stack-audit` Step 7's claims-vs-observed table (`scorecard.sh`), which reads **only** the fenced block in §[Machine-readable claims](#machine-readable-claims-review-stack-claimsv1)

Each review vendor publishes numbers about itself: a catch rate on its own benchmark, a precision figure from a study, a score over a large sample of pull requests. This page records those claims once, each with its metric, benchmark, source URL, and the date it was read. The audit report then sets each claim beside what this stack measured.

## Read this first — these figures do not compare with ours

**The benchmarks behind these claims are small, partly vendor-authored, and measure injected or back-tracked bugs. Our figures are agent-judged verdicts on real PRs.** Put the two side by side to see where a vendor's story and our experience diverge, never to rank a vendor on its own claim.

- **Small samples.** 50 bugs (Greptile), 60 bugs (Signal65), 118 bugs (Macroscope), 50 PRs (Martian's offline track, Augment). One reclassified finding moves a percentage by one to two points.
- **Who ran it.** Most of these were run by a vendor, about itself or a rival. The one third-party study was commissioned by a vendor it ranked first. Each row below names who ran the benchmark.
- **What was measured.** Benchmarks plant a known bug, or rewind a repo to just before a historical bug, then check whether the tool flags it. The metric names collide: "catch rate" here means recall on a planted set, false positives often don't count at all, and Martian's "precision" means the share of comments a developer later acted on.
- **What we measure.** `precision` in the scorecard is `valid / (valid + declined)` over the findings a tool raised on our own merged PRs. Each verdict is the replying agent's own, and a real defect is one that agent stamped `defect=real` (`.claude/reference/review-stack-audit.md` "Value fields"). Different population, different judge, different definition.
- **Claims move.** Vendors re-run and re-word. A figure here is what the source said on its retrieval date and nothing more. Re-verify before quoting it.

## Per-vendor claims

`Status` is `verified` when the figure was re-read at the named source on the retrieval date, and `unverified` when it could not be re-confirmed there. An unverified claim is kept, with its original source and what the source actually says, never dropped.

| Vendor | Claim | Metric | Benchmark | Who ran it | Source | Retrieved | Status |
|---|---|---|---|---|---|---|---|
| Greptile | 82% catch rate (41 of 50) | bug catch rate (recall; false positives not counted) | Greptile's AI code review benchmark, July 2025: 50 PRs, 5 repos, 5 languages | Greptile (vendor, about itself) | <https://www.greptile.com/benchmarks> | 2026-10-08 | verified |
| Cursor BugBot | 95.95% precision (71 true, 3 false positives) | precision (true / all graded findings) | Signal65, "Evaluating AI Code Review Tools: A Real-World Bug Detection Study", March 2026: 60 historical bugs, 6 repos | Signal65 (third party), in partnership with CodeRabbit | <https://signal65.com/research/ai/evaluating-ai-code-review-tools-a-real-world-bug-detection-study/> | 2026-10-08 | verified |
| CodeRabbit | 45.76% detection (54 of 118) | runtime-bug detection rate (recall) | Macroscope's internal benchmark, published 2025-09-17: 118 self-contained runtime bugs, 45 repos | Macroscope (a competing vendor) | <https://macroscope.com/blog/code-review-benchmark> | 2026-10-08 | verified |
| Qodo | 63.4% precision, ranked first on precision | precision | Martian's Code Review Bench, March 2026 | Martian (third party), as reported by Qodo | <https://www.qodo.ai/blog/qodo-ranked-1-ai-code-review-tool-in-martians-code-review-benchmark> | 2026-10-08 | unverified |
| CodeAnt | 52.2% precision, 51.1% recall (F1 51.7%) | precision and recall | Martian's Code Review Bench; CodeAnt's post states the benchmark covers 200,000+ real PRs | CodeAnt (vendor, about itself) | <https://codeant.ai/blogs/ai-code-review-benchmark-results-from-200-000-real-pull-requests> | 2026-10-08 | verified |

What each source says, and where it differs from the claim as first recorded on 2026-10-01:

- **Greptile.** The page states the evaluation "was conducted in July 2025". A bug counted as caught only when a line-level comment named the faulty code and its impact; false positives and style comments "did not affect the catch rate". The same table puts BugBot at 58%, Copilot at 54%, CodeRabbit at 44%, and Graphite at 6%. Augment's December 2025 run, over 50 PRs from five codebases with a corrected answer key, scored Greptile at 45% recall.
- **Cursor BugBot.** "Roughly 96%" is 95.95% in the study's own table, the highest of five tools. The study is labelled "in partnership with CodeRabbit", which it ranks first overall (CodeRabbit 95.88% precision, 93 true positives to BugBot's 71). Third-party, but commissioned by a competitor of the tool it ranks highest on precision.
- **CodeRabbit.** "Roughly 46% in an independent 118-bug test" traces to Macroscope's own benchmark: 54 of 118 runtime bugs, 45.76%. Macroscope sells a competing reviewer and placed itself first at 48.31%, so the test is not independent in the neutral sense. Greptile's benchmark, a different vendor's, puts CodeRabbit at 44%.
- **Qodo.** **The 63.4% precision figure could not be re-confirmed at its source.** Qodo's post, dated 2026-03-15, reports 62.3% precision, 66.4% recall, and a 64.3% F1 for its research-preview "Qodo Extended" configuration. It ranks Qodo first **by F1**, not by precision, and its production configuration at 47.9% F1, fourth. The row keeps the claim as originally recorded, marked unverified. Qodo is not in this review stack, so the scorecard shows no observed figure beside it.
- **CodeAnt.** The figures are CodeAnt's own, from a post it published about its third-place ranking. The post cites 200,000+ real PRs as the benchmark's scope but does not say which of Martian's two tracks produced these three numbers. Treat it as vendor-reported, not independently confirmed.

Graphite and Vercel Agent have no claim recorded here. The scorecard renders each of them as a `no published claim` row, never drops it.

## Public benchmarks

| Benchmark | Date | Who built it | Size | What it measures | URL |
|---|---|---|---|---|---|
| Greptile AI code review benchmark | July 2025 | Greptile (vendor) | 50 PRs, 5 repos (Sentry, Cal.com, Grafana, Keycloak, Discourse), 5 languages | catch rate on reintroduced historical bugs | <https://www.greptile.com/benchmarks> |
| Augment's extension of it | 2025-12-11 | Augment Code (vendor, ranks itself first) | 50 PRs, 5 codebases; it builds on what it calls "the only public benchmark", correcting and expanding that dataset's golden comments | precision, recall, F-score | <https://augmentcode.com/blog/we-benchmarked-7-ai-code-review-tools-on-real-world-prs-here-are-the-results> |
| Qodo Code Review Benchmark 1.0 | 2026-02-04 | Qodo (vendor) | 100 PRs, 580 issues injected into real merged PRs | precision, recall, F1 on injected defects | <https://www.qodo.ai/blog/how-we-built-a-real-world-benchmark-for-ai-code-review> |
| Martian Code Review Bench (`withmartian/code-review-benchmark`) | 2026 | Martian (third party; open source) | offline: 50 PRs, 5 repos, 173 human-curated golden comments (recorded as 136 on 2026-10-01); online: a continuously sampled stream of real PRs | offline: an LLM judge matches comments to the golden set; online: which bot comments developers acted on | <https://github.com/withmartian/code-review-benchmark> |

Signal65's March 2026 study and Macroscope's September 2025 benchmark are one-off studies rather than published benchmarks. They are cited in the claims above.

## Machine-readable claims (review-stack-claims/v1)

`scorecard.sh` reads **only** this block, never the prose tables above. A claim changes here or nowhere. The block must be the only fence whose info string carries `review-stack-claims`, with `"schema": "review-stack-claims/v1"`. A duplicated, unterminated, or malformed block is refused whole: the report prints one caveat line in place of the table, never a partial one.

Rules the block keeps:

- **Every claim carries** `vendor`, `claim`, `metric`, `benchmark`, `authorship`, `source_url` (`https://`), `retrieved` (`YYYY-MM-DD`), and `status` (`verified` or `unverified`).
- **`tool_key`** is the `measure.sh` key of the tool the claim is about (`coderabbit`, `codeant`, `bugbot`, `greptile`, `graphite`, `vercel`), or `null` for a vendor outside this stack. The scorecard joins observed figures on it.
- **`page_url` and `retrieved` at the top** are the source and date a `no published claim` row cites, so every row of the rendered table carries a URL and a date.

```json review-stack-claims
{
  "schema": "review-stack-claims/v1",
  "retrieved": "2026-10-08",
  "page_url": "https://github.com/auerbachb/claude-code-config/blob/main/.claude/reference/ai-review-vendor-claims.md",
  "claims": [
    {
      "vendor": "Greptile",
      "tool_key": "greptile",
      "claim": "82% catch rate (41 of 50)",
      "metric": "bug catch rate (recall; false positives not counted)",
      "benchmark": "Greptile AI code review benchmark, July 2025, 50 PRs",
      "authorship": "vendor, about itself",
      "source_url": "https://www.greptile.com/benchmarks",
      "retrieved": "2026-10-08",
      "status": "verified"
    },
    {
      "vendor": "Cursor BugBot",
      "tool_key": "bugbot",
      "claim": "95.95% precision (71 true, 3 false positives)",
      "metric": "precision",
      "benchmark": "Signal65 real-world bug detection study, March 2026, 60 bugs",
      "authorship": "third party, in partnership with CodeRabbit",
      "source_url": "https://signal65.com/research/ai/evaluating-ai-code-review-tools-a-real-world-bug-detection-study/",
      "retrieved": "2026-10-08",
      "status": "verified"
    },
    {
      "vendor": "CodeRabbit",
      "tool_key": "coderabbit",
      "claim": "45.76% detection (54 of 118)",
      "metric": "runtime-bug detection rate (recall)",
      "benchmark": "Macroscope internal benchmark, 2025-09-17, 118 runtime bugs",
      "authorship": "competing vendor (Macroscope)",
      "source_url": "https://macroscope.com/blog/code-review-benchmark",
      "retrieved": "2026-10-08",
      "status": "verified"
    },
    {
      "vendor": "Qodo",
      "tool_key": null,
      "claim": "63.4% precision, ranked first on precision",
      "metric": "precision",
      "benchmark": "Martian Code Review Bench, March 2026",
      "authorship": "third party, as reported by Qodo",
      "source_url": "https://www.qodo.ai/blog/qodo-ranked-1-ai-code-review-tool-in-martians-code-review-benchmark",
      "retrieved": "2026-10-08",
      "status": "unverified"
    },
    {
      "vendor": "CodeAnt",
      "tool_key": "codeant",
      "claim": "52.2% precision, 51.1% recall (F1 51.7%)",
      "metric": "precision and recall",
      "benchmark": "Martian Code Review Bench, as reported over 200,000+ PRs",
      "authorship": "vendor, about itself",
      "source_url": "https://codeant.ai/blogs/ai-code-review-benchmark-results-from-200-000-real-pull-requests",
      "retrieved": "2026-10-08",
      "status": "verified"
    }
  ]
}
```

## Re-verifying

Re-read every source before an article or decision quotes it, then update the row, its note, the block, and **Last verified** together. A figure that moved gets its new value and date. A figure that can no longer be found becomes `unverified`, with the note saying what the source now says.
