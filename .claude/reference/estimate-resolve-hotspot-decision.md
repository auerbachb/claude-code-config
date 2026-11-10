<!-- churn-hotspot: .claude/scripts/estimate-resolve.sh -->
# Hotspot Decision — .claude/scripts/estimate-resolve.sh

**Verdict:** KEEP — no split; the hotspot is below signal
**Decided:** 2026-09-01
**Issue:** #1513
**Reporter:** `/wrap` churn sweep after PR #1501
**Detector snapshot:** `score 3`, `pr_count 3`, `pr_numbers [1332, 1379, 1458]`, `conflict_rounds: 0`, `conflict_prs []`

Reference for Issue #1513. Not auto-loaded — the rule corpus carries none of this.

## Churn decomposition — five lines of real churn

| PR | Issue | Diffstat here | PR total | Class |
|----|-------|---------------|----------|-------|
| #1332 | #1324 | **+204 / −0** | 6 files, +605 | **Creation** — dispatch estimates + batch makespan, increment 3/4 |
| #1379 | #1371 | +4 / −1 | 5 files, +446 | **Sibling sweep** — tolerate empty arrays under `set -u` on bash 3.2, applied to this script *and* its siblings |
| #1458 | #1406 | +1 / −1 | **72 files**, +649 | **Mechanical sweep** — one-line `script-usage.log` stderr-guard reordering |

**Post-creation churn: +5 / −2**, across two repo-wide sweeps in which this file
was a passenger. Score 3 is the detector's **threshold floor** — the minimum that
enters the hotspot list at all. The file is 207 lines with one job (resolve an
issue number to its estimate string) and `conflict_rounds: 0`.

On churn alone this is a clean CLOSE, and no structural change is warranted.

## What the audit found instead: `--help` was dead on macOS

At the help branch the script ran

```bash
sed -n '2,/^set -/{ /^#/{ s/^# \?//; p }; /^set -/q }' "$0"
```

BSD sed (stock macOS) rejects the nested block —
`sed: 1: "2,/^set -/{ /^#/{ s/^#  ...": extra characters at the end of p command`
— so `--help` produced **zero bytes on stdout and exit 1**, because
`set -euo pipefail` kills the script at the failing sed before the `exit 0` on the
next line.

For this script the wrong status is not cosmetic. **Exit 1 is a documented,
in-band result** of normal operation (`tier-table fallback (label-derived tier)`),
so a caller that runs `--help` and branches on status cannot distinguish "help is
broken" from "resolved via tier fallback". Broken help masqueraded as the
documented tier-table fallback.

Five siblings shared the identical pattern and failed identically —
`audit-skill-usage.sh`, `makespan.sh`, `overrun-check.sh`,
`skill-conventions-audit.sh`, `window-plan.sh` — and a second, quieter family of
six printed a section heading with its body dropped (`repo-root.sh`,
`greptile-budget.sh` on `EXAMPLES`; `cr-review-hourly.sh`, `credit-budget.sh`,
`pr-preflight.sh`, `usage-horizon.sh` on `DEPENDENCIES`). **Twelve scripts in
all**, fixed in the one PR that closes this issue and Issue #1475.

### Why it survived

1. **CI was Linux.** Six of seven workflows run `ubuntu-latest`, where GNU sed
   accepts the nested block. The `macos-latest` job existed but exercised no
   `--help`. The bug fired **only** on the machines this repo is developed on.
2. **No `--help` coverage anywhere.** `estimate-resolve.test.sh` has no help
   assertion, and neither did the other eleven.
3. The healthy majority (30 scripts) already used the portable `awk` form, so the
   failures read as a minority dialect rather than a defect.

The remedy is the prevailing idiom —
`awk 'NR == 1 { next } /^$/ { exit } { sub(/^# ?/, ""); print }' "$0"` — which uses
no sed at all and terminates on the first blank line, so neither family can recur.
`.claude/scripts/tests/help-output.test.sh` pins it: content assertions per script
(headings **and** body lines, since the truncation family proved headings alone
are vacuous) plus a repo-wide `--help` smoke sweep that runs on both CI platforms.

## Baseline

`.claude/reference/churn-hotspot-baselines.json` records
`score_at_decision: 3`, `pr_count_at_decision: 3`, `issue: 1513`, matching the
detector snapshot above. The 2× material-growth gate therefore re-surfaces this
path only at score 6 — meaningful, since 3 is merely the entry threshold.

The baseline's `issue` key must stay **1513**: `baseline_for()` in
`churn-hotspot-wrap-plan.sh` joins on `existing_hotspot_issue`, which the detector
resolves from the `Refactor hotspot: <path>` title or the
`<!-- churn-hotspot: <path> -->` marker — both of which point at #1513.
