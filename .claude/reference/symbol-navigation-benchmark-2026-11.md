# Symbol navigation benchmark · November 2026

Issue #1874 · Measured 2026-11-11 UTC · Source commit
`2b4740ab5967070661da06d2c18ca2e28f193290` · On-demand reference

**Defer a structural-navigation integration.** Python's installed AST parser
reduced confirmed evidence by about 11% across three tasks after counting its
command contract. The sum of the three median retrieval times was about 8.5
times as long. The mixed-language task required text search for five callers
and the Bash task used text search for every answer.

## Method

Both paths searched 369 tracked `.py` and `.sh` files under `.claude/scripts/`,
including 24 Python files. Ripgrep used a task-specific pattern followed by
bounded source excerpts. The pilot used Python AST function and call nodes,
then the same excerpts and text search for embedded Python and Bash. The
fixture records expected coordinates independently of the query results.

Seven repetitions per path ran on macOS arm64 with Python 3.15.2 and ripgrep
15.2.0. Times include process launch, search or parse, and source confirmation.
The common file allowlist took 21.73 ms once. The parser checks that allowlist
again in each process. Both executables were present. There was no install,
server startup, persistent index, or MCP schema. The pilot's on-demand command
contract is 73 UTF-8 bytes. Output volume counts UTF-8 bytes from the result and
the confirmation excerpts, including duplicate lines and repeated file paths.
These are payload measurements. They do not measure tokenizer output, model
reasoning time, cache behavior, or an actual coding session.

## Fixed tasks and source answers

1. **Definition.** `.claude/scripts/lib/review_ledger.py:479` rounds a Decimal
   to `0.01` with `ROUND_HALF_UP`. Its import and quantum appear at lines 64
   and 80. The result is a Decimal amount with two decimal places.
2. **Callers.** The production calls in `review_ledger.py` are at 490, 507,
   512, 517, 531, 559, 560, 565, 570, and 1014. Five more are in the Python
   embedded in `.claude/scripts/review-daily-cap.sh` at 418, 790, 814, 821,
   and 828. The nearby `parse_cents` declaration's docstring, comments, and
   import-only sites are outside the answer. The task covers direct calls in
   the tracked script scope. Aliases, computed names, and runtime dispatch
   require separate evidence.
3. **Minimal change surface.** An ASCII-locale-independent normalizer would
   need the shared `.claude/scripts/lib/repo-normalizer.sh:31` and five shell
   fallbacks in `.claude/scripts/` at `handoff-migrate.sh:53`,
   `polling-state-gate.sh:174`, `release-decide.sh:98`, `release-sweep.sh:64`,
   and `table-freshness.sh:374`. Call sites and the two deliberate test
   overrides in `polling-state-gate.test.sh` are outside that edit surface.

## Measurements

The rows list the correct locations recovered before final source confirmation.
The last column includes the search output and the same bounded read protocol
for each path. All three confirmed answers matched the fixed source answers.

| Task | Path | Found | Candidates | First / median / max ms | Bytes / characters |
| --- | --- | ---: | ---: | ---: | ---: |
| Definition | `rg` | 1/1 | 1 | 14.37 / 9.67 / 14.37 | 1,033 / 1,033 |
| Definition | AST | 1/1 | 1 | 126.65 / 128.06 / 170.60 | 1,016 / 1,016 |
| Callers | `rg` | 15/15 | 19 | 12.77 / 11.60 / 12.77 | 7,719 / 7,717 |
| Callers | AST plus `rg` | 15/15 | 17 | 131.63 / 129.84 / 143.04 | 6,404 / 6,402 |
| Change surface | `rg` | 6/6 | 8 | 10.59 / 10.15 / 10.82 | 3,208 / 3,208 |
| Change surface | `rg` fallback | 6/6 | 8 | 10.03 / 9.74 / 11.36 | 3,208 / 3,208 |

AST alone found 10/15 callers and 0/6 Bash implementations. The mixed caller
path saved 1,315 bytes before charging the shared command contract. Across the
three tasks, the output was 11,960 bytes for `rg` and 10,701 bytes for the
pilot with one contract load. Searching for a definition by name was already
precise with `rg`. The candidate matched names and attributes syntactically
and could still confuse unrelated same-name functions.

## Freshness and fallback

- Adding two lines above the definition and one new caller in a disposable
  clone returned the shifted line and the new call without a refresh step.
  The old saved result then differed from the current result. Switching back
  to the pinned commit restored the original coordinates. A second worktree
  on the modified branch independently returned the shifted coordinates.
- With a malformed Python file or unavailable Python executable, the probe
  failed and the scoped `rg` query still found the corresponding line.
- Bash required `rg` for all six production implementations. A direct text
  search also recovered the wildcard permission in `global-settings.json`.
- The fixture staged synthetic credential and generated files in a disposable
  worktree. The shared allowlist excluded both before either search. It admits
  tracked shell and Python sources only, excludes credential-like names and
  common generated, fixture, and build directories, and skips symlink paths.
  Any broader pilot needs an explicit review of sensitive configuration and
  generated regions before widening that boundary.

## Recommendation and reproduction

Keep targeted `rg` and bounded reads as the default. Revisit an opt-in probe
only for a Python-heavy project with repeated cross-file queries. Load it per
task, pass the active worktree explicitly, parse current files, and verify
candidate locations with bounded reads. Keep a same-scope text fallback for
embedded code, config, runtime indirection, and parser failure. Compare
model-visible context including schemas and confirmations against equivalent
`rg` tasks before enabling it for that project.

The [Architectural Playbook](https://docs.google.com/document/d/17odVvQZv0t_ffIZNwyZ4CA3UdJ-VW50WoHrEO11WlBE/edit)
describes indexed symbol retrieval with jCodeMunch and language-server
navigation with Serena. This benchmark evaluates the installed Python AST
parser on this repository. The external tools and the playbook's overall
token savings claims remain unmeasured.

Run the fixture from a checkout containing the report and point it at a clean
checkout of the pinned commit. The optional empty scratch directory receives
the disposable clone and worktree used for the failure and freshness checks.

```sh
python3 .claude/scripts/tests/fixtures/symbol-nav-benchmark/benchmark.py \
  /path/to/pinned-checkout --scratch "$(mktemp -d)"
```
