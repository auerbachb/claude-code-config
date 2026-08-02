# Compact Result Contract (`ok` / `failed_tests` / `relevant_error` / `log_path`)

The output shape shared by the wrappers around this repo's noisiest pass/fail pipelines.
Ships FU-7 of `token-efficiency-audit-2026-07.md`: tool I/O is the largest per-turn context
surface, and the pipelines below were the ones still folding full raw output into it.

**Selective wrappers only.** This is a shape a few named scripts opt into — never a universal
interception layer around every tool call. That layer was evaluated and **rejected** in the same
audit (fragile, over-minifies errors, subagent hook bypass). Adding a wrapper is a per-pipeline
decision with a measured payload win behind it; see "Scope" below for what is deliberately
excluded.

## Schema

One line of JSON, built with `jq -cn`:

```json
{"ok":false,"failed_tests":[".claude/scripts/tests/foo.test.sh"],"relevant_error":"FAIL: expects exit 3, got 0","log_path":"/tmp/run-hook-tests-1754107200-a1b2c3.log"}
```

| Field | Type | Meaning |
|---|---|---|
| `ok` | bool (required) | Overall verdict. `true` only for a **verified** clean run — not merely "exit 0" (both local review CLIs exit 0 on total failure). |
| `failed_tests` | array of strings | Failing suite/test identifiers. `[]` or omitted for non-test pipelines. |
| `relevant_error` | string or null (required) | The **decisive** line(s) only — the assertion that failed, the API error, the rate-limit notice. Never the whole log. Capped; see "Extraction rules". |
| `log_path` | string (required) | Absolute path to the persisted raw output. Always written, even on success. |

Emitters may add their own fields (`tool`, `findings`, `failure_mode`, `duration_s`, …). Consumers
must tolerate unknown keys — the four above are the stable core.

## Emission conventions

- **Single-line `jq -cn`.** No pretty-printing; one object, one line, on **stdout**.
- **stdout is the contract, stderr is the detail.** In compact mode stdout carries *only* the
  JSON object, so `$(cmd)` is directly parseable. Human/diagnostic output goes to stderr.
- **Compact mode is opt-in** where a human/CI mode already exists (`--json`), matching the repo's
  existing `--json` convention. A brand-new wrapper may default to JSON (as `ci-status.sh` does)
  and offer `--format summary`.
- **Raw output always persists to `log_path`** — the `pr-state.sh` "write the payload to a file,
  print only the path" idiom. Compaction moves bulk out of context; it never destroys it.
- **Documented exit-code matrix** in the script header, distinct codes per failure class.

## Failures are compacted, never hidden (NON-NEGOTIABLE)

`token-efficiency-audit-2026-07.md` §"What NOT to change" requires that failing CI print in full.
Compact mode therefore silences **passing** noise, not failing detail:

- Passing suites/units produce no output at all — that is where the savings come from.
- **Failing** ones still print their captured output in full, on stderr.
- `relevant_error` is an *index into* the failure, never a replacement for it: `log_path` holds
  the complete capture and the contract names it on every run.

A wrapper that summarizes a failure down to a status line and drops the detail is a bug.

## Extraction rules for `relevant_error`

- Test harnesses: the first matching decisive line per failing suite — `FAIL:`, `AssertionError`,
  `Error:`, `ERROR:`, `not ok`, `::error::`, or the runner's own failure line.
- Local review CLIs: the CLI's own error text — CodeRabbit's NDJSON `type:"error"` record
  (`errorType: message`), CodeAnt's stderr `API Error` / `[error]` line.
- Join multiple lines with `\n`; cap at **20 lines / 2000 characters** and mark truncation with a
  trailing `… (truncated; see log_path)`.
- `null` when `ok` is `true`.

## Adopters

| Pipeline | Wrapper | Compact mode | Notes |
|---|---|---|---|
| Bash test suites | `.github/scripts/run-hook-tests.sh` | `--json` | `failed_tests` = failing suite paths |
| Python unittest | `.github/scripts/run-python-tests.sh` | `--json` | `failed_tests` = `unittest` test ids |
| CodeRabbit / CodeAnt local review | `.claude/scripts/local-review.sh` | default (`--format summary` for text) | `failed_tests` always `[]`; adds `tool`/`findings`/`failure_mode`/`verified_run` |

`.github/workflows/hook-scripts.yml` runs both test wrappers in `--json` mode and writes the
contract to `$GITHUB_STEP_SUMMARY`, so an agent reading the run sees the verdict rather than every
suite's raw fold.

## Scope — what is deliberately NOT wrapped

- **Scripts that already emit a compact `--json` object** (`ci-status.sh`, `merge-gate.sh`,
  `escalate-review.sh`, `churn-hotspots.sh`, …). They are already at the target shape; rewriting
  them into this schema would be churn, not savings.
- **`gh` calls inside those scripts.** They are already `--jq`-projected at the source.
- **`pr-state.sh`'s stdout contract.** It already prints only a path. Its *bundle* was made
  smaller instead — see below — but its interface is unchanged, and it does not adopt this schema
  (it is a state snapshot, not a pass/fail verdict).
- **Anything not pass/fail-shaped.** Forcing `ok`/`failed_tests` onto a state dump produces a
  worse contract than the one it has.

### Related payload reduction: `pr-state.sh` field projection

Not a contract adopter, but the same FU-7 pass. The bundle embedded raw GitHub review/comment
objects; consumers read `body`, identity, timestamps, URLs, and the two SHA fields, and nothing
reads `diff_hunk`, `_links`, `reactions`, or the 18-field `user` object. Projecting those away —
**bodies kept in full** — measured on PR #931's live payload:

| Array | Raw | Projected | Cut |
|---|---|---|---|
| `pulls/{n}/comments` (inline) | 215,723 B | 67,014 B | 69% |
| `pulls/{n}/reviews` | 61,443 B | 25,700 B | 58% |
| `issues/{n}/comments` | 17,009 B | 6,164 B | 64% |
| **total** | **294,175 B** | **98,878 B** | **66%** |

`diff_hunk` alone (plus `reactions` and `_links`) accounted for 121,893 B of the inline array.
The projection is lossless for every field any consumer reads; `path` + `line` + `body` still
locate and describe each finding. Exact field list: `pr-state.sh` §"Field projection".
