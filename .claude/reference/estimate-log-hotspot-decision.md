<!-- churn-hotspot: .claude/scripts/estimate-log.sh -->
# Hotspot decision: estimate-log.sh

**Verdict:** KEEP the current CLI and implementation; no structural extraction.
**Assessed:** 2026-11-08, Issue #2033, source main `e9eca6f5`.
**Detector:** since 2026-10-25, seven merged PRs, score 7, zero recorded conflict
rounds. This on-demand reference adds no permanent startup context.

## What changed

| PR | Concern |
|---|---|
| #1928 | Renewal-aware claim pickup timing |
| #1944 | Original pickup timestamps retained through renewal |
| #2017 | Dead lock recovery while preserving live mutation ownership |
| #2028 | Parsed JSON identity instead of whitespace-sensitive deduplication |
| #2037 | Rollup row parsing and safe report publication |
| #2047 | One locked replacement for a collected rounds-backfill batch |
| #2054 | Mode-zero and dash-prefixed report-output compatibility |

The original four-PR filing now has seven PRs of evidence. The separately tracked
Issues #1681, #2019, #2025 and #2027 are closed. Their completed correctness work
is not a reason to defer the assessment, and should not be reimplemented here.
Zero recorded conflicts is an observation from this window, not proof that the
file has no maintenance cost.

## Why keep the current structure

Append, backfill and rollup already have explicit mode boundaries. Append and
rounds backfill share one ledger and mutation authority: lock ownership,
in-flight writer liveness, row identity and replacement fences must agree.
Splitting those paths would add interfaces around the contract most of the
recent hardening established. Rollup has its own read/render/publication path;
the observed changes addressed correctness and portable file semantics rather
than repeated contention over that boundary.

There is no demonstrated independent change stream or measured review cost
that makes an extraction pay for its new deployment and parameter contracts.
Keep production `estimate-log.sh` byte-identical for this assessment. This
decision neither strengthens its locking guarantees nor removes its existing
failure handling or filesystem/scheduling limitations.

## Coverage already present

The earlier CodeRabbit proposal identified missing negative rewrite-fence
coverage. PR #2047 subsequently added `tests/test_estimate_rounds_batch.py`.
Its existing controls cover changed row counts, concurrent appends/checksum
changes, lost lock ownership, allocation/render/write/rename failures, retained
foreign lock tokens, and byte preservation of untouched rows. Add no duplicate
test module for those same contracts.

The current estimate CLI suite also exercises parsed rows, exact report
destinations, ledger aliases, malformed metadata, publication failures, and
permission preservation including mode 000 and special bits. These controls
remain the verification surface for future work.

## Baseline and reconsideration

`churn-hotspot-baselines.json` records this file with Issue #2033 and score/PR
count 7. The existing 2x material-growth rule therefore reaches its threshold
at score 14; the join must retain both this exact path and Issue #2033. Other
baselines and the multiplier remain unchanged.

Reconsider with evidence of new conflict rework, repeated changes coupling
otherwise independent modes, or a stable independently evolving pure-rendering
contract. A future proposal must retain the public CLI, every ledger row,
mutation ownership, rewrite fences, and exact report publication behavior.
