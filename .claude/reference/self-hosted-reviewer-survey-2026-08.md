# Self-Hosted AI Code Reviewer Survey — 2026-08

Issue: [#1287](https://github.com/auerbachb/claude-code-config/issues/1287)
Prior audit feeding this survey: [`local-review-cli-failure-modes.md`](./local-review-cli-failure-modes.md) (Issue #1286)
Incumbent baseline: [`ai-review-chain-roles-decision.md`](./ai-review-chain-roles-decision.md) (Issue #1199)
Prior `ocr` evaluation: [`skill-prune-audit-2026-07.md`](./skill-prune-audit-2026-07.md) §ocr CUT verdict (Issue #793, PR #822)

Date reviewed: **2026-08-23**
Evaluation window: **2026-08-23** (same-session, point-in-time)
Sample for comparison baseline: **PR #1292** — 2 modified `.md` files, 5 CodeRabbit inline findings, 0 CodeAnt inline findings (CodeAnt issued 3 APPROVEDs, no inline comments)

> **Measurement discipline.** This survey distinguishes between what was installed, what was
> exercised, and what was inferred from documentation. Each finding names its evidence type.
> No measurement was taken from any run that did not complete — partial-run absence findings
> are suppressed throughout. API-key-dependent runs were not possible in the original session
> (no `ANTHROPIC_API_KEY` in the agent environment); those three items are now completed in a
> follow-up measurements (Issue #1301, 2026-08-23–24) and recorded in §7 below.

---

## Executive summary

| Candidate | Category | Verdict | Limiting constraint |
|-----------|----------|---------|---------------------|
| `ocr` (alibaba/open-code-review) | Self-hosted | **CUT — confirmed** | Excludes `.md` files; 0 of 2 PR #1292 files reviewable; code-file run completed (§7): 2 findings on 2 `.sh` files, ~$0.79/review |
| Qodo PR-Agent | Self-hosted | **CUT — capability claim corrected** | `--stdin` local mode confirmed in v0.43.0 (contradicts prior survey); endpoint run completed (§7): 2 findings, ~$0.09/review; CUT reason updated — see §7 and decision record |
| CodeRabbit CLI | Hosted (incumbent) | **KEEP** | OSS pool: 3 reviews/~55-min window on this public repo |
| CodeAnt CLI | Hosted (incumbent) | **KEEP** | Daily cap applies; auth restored 2026-08-23 |

**Verdict in one sentence:** Neither self-hosted candidate is adopted for the local pre-push slot — `ocr` excludes every `.md` file it would encounter (confirmed; 0 coverage in this doc repo), and PR-Agent v0.43.0 has a `--stdin` local mode (correcting a prior survey claim) but produces only summary-level findings without line anchors, which reduces its value versus the incumbent CLIs — so the chain is unchanged, and the local pass continues under CodeRabbit + CodeAnt. **See §7 for the Issue #1301 endpoint run measurements.**

---

## 1. Candidate census

### 1.1 Self-hosted candidates

| Field | `ocr` (alibaba/open-code-review) | Qodo PR-Agent |
|---|---|---|
| **License** | Apache-2.0 | Apache-2.0 |
| **Upstream** | github.com/alibaba/open-code-review | github.com/qodo-ai/pr-agent |
| **Install path** | `npm install -g @alibaba-group/open-code-review` (verified) | `pip3 install pr-agent` (verified) |
| **Install verified** | Yes — v1.9.10 installs, binary resolves, `--version` succeeds | Yes — v0.43.0 installs, `python3 -m pr_agent.cli --help` succeeds |
| **Runs non-interactively** | Yes, with configured LLM endpoint; install is non-interactive | Yes in `--stdin` mode (Issue #1301 finding); `--pr_url` mode requires GitHub token |
| **Fully local (no vendor account)** | Yes — only an LLM API key is required | **Yes in `--stdin` mode** — no GitHub token required (confirmed 2026-08-23, Issue #1301) |
| **LLM providers accepted** | Anthropic, OpenAI, and any OpenAI-compatible endpoint via `OCR_LLM_URL`; configured via `ocr config set` | Anthropic, OpenAI, Azure OpenAI, Google Gemini, AWS Bedrock, and others via litellm |
| **Line-level findings** | Yes — the core design goal; line-level comments with file/range anchors | Yes — inline PR comments with line numbers |
| **Local diff mode** | Yes — `ocr review` reads git diff from working tree or a commit range | **Yes — `--stdin` mode** pipes a unified diff (confirmed v0.43.0); prior survey claim of "no local mode" was incorrect |
| **Cost per review** | Only LLM endpoint cost (model-dependent); no vendor quota metered | Only LLM endpoint cost; no vendor quota |
| **`.md` file support** | **No** — `.md` excluded as `unsupported_ext` (confirmed via `ocr delegate preview` on PR #1292 commit) | Yes — reads all file types accessible via GitHub PR diff |
| **Maintenance burden** | Binary from npm; major releases every few weeks in 2026 | Python package; active maintenance; self-host or Docker |
| **Notable limitation** | Extension exclusion of `.md` is built into the binary with no CLI override flag (`--exclude` only adds exclusions, does not un-exclude) | `--stdin` mode produces summary-level findings without line-number anchors; no per-file file/range in output |
| **Delegation mode** | **Yes** — `ocr delegate` outputs a review spec that the host agent (Claude Code) can execute; no API key required for delegation | N/A — single-shot model call in `--stdin` mode; no tool-use loop |

### 1.2 Hosted incumbent CLIs

| Field | CodeRabbit CLI | CodeAnt CLI |
|---|---|---|
| **Version** | 0.7.5 (at `~/.local/bin/coderabbit`) | 0.5.1 (at `/opt/homebrew/bin/codeant`) |
| **Auth state** | `Plan: Pro / Seat: assigned` (auerbachb, org: LocalMovers-dot-com) | Restored 2026-08-23 16:11 ET (`~/.codeant/config.json` with `apiKeyV2`) |
| **Cap on this public repo** | OSS pool: 3 reviews per ~55-min window (`isProUser: false`) | Daily cap (not per-review quota); exact limit undocumented |
| **Cost per review** | Vendor-metered (Pro seat, $48/mo after seat reduction) | Vendor-metered (Premium, ~$48/mo, 2 seats) |
| **`.md` file support** | Yes | Yes |
| **Line-level findings** | Yes | Yes |

---

## 2. Hands-on comparison — PR #1292

PR #1292 (`docs(#1286): record CLI failure investigation — CodeAnt unauthenticated, CR OSS routing`, merged 2026-08-23) was selected as the comparison baseline because:
- It was reviewed by CodeRabbit (5 inline findings)
- It was approved three times by CodeAnt (0 inline findings)
- Its diff is pure `.md` — the hardest case for `ocr` in this repo

### 2.1 Files in PR #1292

| File | Change | CodeRabbit findings | CodeAnt findings | `ocr` reviewable? | PR-Agent reviewable? |
|---|---|---|---|---|---|
| `.claude/reference/local-review-cli-failure-modes.md` | +169/-4 | 4 inline (3 Major, 1 Major security) | 0 | **No** (`unsupported_ext`) | Yes (via GitHub PR URL) |
| `.claude/reference/pricing-matrix.md` | +4/-2 | 1 inline (Minor) | 0 | **No** (`unsupported_ext`) | Yes (via GitHub PR URL) |

**`ocr` reviewable file count: 0 of 2 (0%).**

This is not a sampled result — `ocr delegate preview` on the exact commit was run directly and reported both files as `excluded: unsupported_ext`. This is not a partial-sample absence finding; it is a positive exclusion signal.

### 2.2 CodeRabbit findings on PR #1292 (verified from GitHub API)

| # | File | Line | Severity | Summary |
|---|---|---|---|---|
| 1 | `local-review-cli-failure-modes.md` | (no line anchor — conversation comment) | Major / Functional Correctness | CR cap discrepancy analysis (3 OSS vs rate-limit table) |
| 2 | `local-review-cli-failure-modes.md` | (no line anchor) | Major / Data Integrity | CLI measurement window completeness |
| 3 | `local-review-cli-failure-modes.md` | (no line anchor) | Major / Security | Credential file analysis |
| 4 | `local-review-cli-failure-modes.md` | line 411 | Major / Security | `~/.codeant/config.json` at `0644` — recommend `0600` before documenting restored auth |
| 5 | `pricing-matrix.md` | line 124 | Minor / Maintainability | Stale "struck-through" reference phrasing |

**CodeAnt:** 3 APPROVED reviews, 0 inline findings. CodeAnt's auto-approve behavior on this repo means its APPROVEDs are not evidence of quality; absence of inline findings from CodeAnt is unsurprising.

### 2.3 Self-hosted candidate comparison against PR #1292

**`ocr`:** 0 findings possible. Tool would not have touched either file. Finding 4 (credential file permissions, a real security observation) would have been missed. All 5 CodeRabbit findings would have been missed.

**PR-Agent:** Not run in this session. The `--pr_url` interface requires a GitHub token (`BoxKeyError: user_token` without one). The `--stdin` local mode discovered in Issue #1301 was not known at the time of the original survey. Absence claims suppressed. See §7 for the actual run.

### 2.4 Token cost methodology (original session — no runs completed)

No self-hosted review was completed in the original session due to absent API keys. Token cost cannot be measured here. The methodology for a future measurement:

- For `ocr`: run `ocr review --from <base> --to <head> --format json --audience agent`; capture the token counts from the JSON output (input/output tokens per file). Multiply by the model's published per-token price.
- For PR-Agent: similar — token counts logged to stdout; multiply by model price.
- Comparison basis: **cost-per-review-session**, not "free vs paid" (both tools are metered by the LLM endpoint, not by a vendor quota).

**This methodology was executed in Issue #1301. See §7 for actual measured results.**

---

## 3. `ocr` delegation mode — a partial path forward

`ocr delegate` is a new capability (not present at the time of Issue #793) that outputs a structured review spec, allowing the coding agent (Claude Code) to execute the review using its own LLM without `ocr` needing an API key configured. The delegation mode pipeline:

1. `ocr delegate preview` — lists reviewable files (applies the same extension filter; `.md` still excluded)
2. `ocr delegate rule <files>` — outputs the review rules to apply to those files
3. The host agent runs the review against those rules

**Implication for this repo:** The extension exclusion applies identically in delegation mode. In a repo where all changed files are `.md`, delegation mode produces 0 reviewable files just as the direct mode does. Delegation mode is a distribution innovation (removes the API key requirement from the `ocr` binary), not a coverage expansion.

---

## 4. Prior `ocr` CUT verdict reconciliation (Issue #793)

The 2026-07 skill prune audit (Issue #793, PR #822) recorded a **CUT** verdict for `ocr` on two grounds:
1. `ocr` excludes `.md` files — confirmed still true in v1.9.10 (2026-08-23)
2. Live side-by-side eval was blocked by absent Anthropic credential in the eval VM

**This survey addresses ground 2** (credential present in principle; no API key in session environment). It confirms ground 1 independently. The CUT verdict stands on ground 1 alone: in this repo, where every PR diff is predominantly `.md`, `ocr` would produce 0 findings on the large majority of PRs regardless of the LLM endpoint configured.

Ground 2 is now resolved: Issue #1301 ran `ocr review --commit 0b6ad100 --format json --audience agent` on the exact PR #1295 head reviewed by CodeRabbit and CodeAnt, which touches `.sh` files. The run produced 2 findings, including 1 confirmed overlap. See §7 for the complete output and analysis.

---

## 5. Install verification details

### `ocr` (alibaba/open-code-review)
```
$ npm install -g @alibaba-group/open-code-review
added 2 packages in 1s

$ ocr --version
open-code-review v1.9.10 (661202912) darwin/arm64
built at: 2026-08-23T07:14:12Z

$ ocr review
Error: resolve LLM endpoint: no valid LLM endpoint configured; one of OCR_LLM_URL/OCR_LLM_TOKEN/OCR_LLM_MODEL,
~/.opencodereview/config.json, or ANTHROPIC_BASE_URL/ANTHROPIC_AUTH_TOKEN/ANTHROPIC_MODEL must be set
```
Installation: clean, non-interactive. Runtime: blocked by absent API key — clean error message, non-zero exit.

### Qodo PR-Agent (`pr-agent`)
```
$ pip3 install pr-agent
Successfully installed ... pr-agent-0.43.0 ...

$ python3 -m pr_agent.cli --pr_url=https://github.com/auerbachb/claude-code-config/pull/1292 review
[ERROR] ... dynaconf.vendor.box.exceptions.BoxKeyError: 'DynaBox' object has no attribute 'user_token'
```
Installation: clean, non-interactive. Runtime: blocked by absent GitHub token — error on first use, does not fall back to local diff.

Follow-up correction (Issue #1301): v0.43.0 also exposes `--stdin`, which accepts a unified diff without a GitHub token. The original conclusion above describes only the `--pr_url` path and is superseded by the measured local run in §7.

---

## 6. Scope note — data flow

PR diffs sent to a self-configured LLM endpoint carry the same data-flow question as diffs sent to a hosted vendor.

**For the local pre-push workflow specifically** (the slot this survey evaluates): the diff is constructed from the developer's local working tree before it is pushed to GitHub. At this stage the diff is not yet public, even for a public repository. Required checks before routing any pre-push diff to a self-configured endpoint: (1) run `git diff` through a secret-scanning pass (`git secrets --scan` or equivalent) to confirm no accidentally staged credentials; (2) review the provider's data processing and retention terms for the model endpoint in use.

**For a diff that is already public** (e.g., re-reviewing PR #1292's merged commit): the diff content is already publicly readable on GitHub, which reduces but does not eliminate residual risks. Residual risks include: provider training and retention policies, metadata (file paths, commit messages, author identities) that may be logged beyond the diff content itself, and routing through the provider's infrastructure. The disclosure risk is lower than for a pre-push diff but is not zero.

This is noted as a structured check rather than a settled blanket statement, as the issue requested.

---

## 7. Issue #1301 follow-up measurements — 2026-08-23–24

### 7.1 Measurement setup

- Endpoint credential: `ANTHROPIC_API_KEY`, referenced by name only. The value is absent from the captured output and tracked files.
- Model: `claude-opus-4-5-20251101` (`ocr` reports the configured alias as `claude-opus-4-5`).
- Real diff: PR #1295 head `a659a81..0b6ad100`, containing `.claude/scripts/active-work-cap.sh` and `.claude/scripts/tests/active-work-cap.test.sh` plus one Markdown reference file. `ocr` selected the two supported `.sh` files; PR-Agent received the complete unified PR diff through stdin.
- Hosted comparison: the 2 CodeRabbit and 3 CodeAnt findings posted on that exact `0b6ad100` head. This is revision-matched and avoids absence claims from an incomplete or later fixed run: both self-hosted runs completed successfully.
- Price basis: [Anthropic's Claude Platform pricing](https://platform.claude.com/docs/en/about-claude/pricing) for Opus 4.5 — $5/MTok input, $25/MTok output, $6.25/MTok five-minute cache write, and $0.50/MTok cache read.

### 7.2 `ocr` result

Command: `ocr review --commit 0b6ad100 --format json --audience agent`. Version: v1.9.10. Terminal state: `complete`. Wall clock: **85.92 seconds** (the run manifest reports 84.83 seconds of reviewer execution).

| Metric | Measured value |
|---|---:|
| Files selected / completed | 2 / 2 |
| Findings | 2 |
| Input tokens | 380,400 total: 68 uncached, 71,557 cache-write, 308,775 cache-read |
| Output tokens | 7,412 |
| Endpoint cost | **$0.79/review**: $0.0003 uncached input + $0.4472 cache write + $0.1544 cache read + $0.1853 output |

The two line-anchored findings were:

1. `.claude/scripts/tests/active-work-cap.test.sh:85-90` — make the fake `gh` error message more explicit about the state patterns it expects.
2. `.claude/scripts/active-work-cap.sh:1241-1243` — exclude pipeline-owned issues from `REG_NUMS` before building `offered_issue_nums`.

Quality classification after checking the reviewed head:

| Finding | Hosted overlap | Classification |
|---|---|---|
| Fake-client error text | None | Non-actionable maintainability suggestion; the existing message already identifies the expected `open`/`merged` values and includes the received arguments. |
| Pipeline-owned `offered_issue_nums` | **Direct overlap with CodeAnt's minor logic-error finding on the same head** | Confirmed true positive. It identifies the same diagnostic leak and proposes the same set subtraction. CodeRabbit found the same defect on a later head after the first registry fix. |

**Result:** 1 confirmed true positive/hosted overlap, 0 unique true positives, and 1 unique non-actionable finding. `ocr` produced correctly structured line anchors and a real quality signal on supported files. Its Markdown exclusion remains independently disqualifying for this repository, and its measured cost is positive marginal spend versus the retained incumbent seats.

### 7.3 PR-Agent result

Command: `python3 -m pr_agent.cli --stdin review` with the same unified PR #1295 head diff. Version: v0.43.0. Terminal state: successful. Wall clock: **14.35 seconds**; the run details report **9.2 seconds** of model time.

| Metric | Measured value |
|---|---:|
| Diff tokens reported before the call | 12,933 |
| Billed input tokens | 15,650 |
| Billed output tokens | 362 |
| AI calls | 1 |
| Findings | 2 summary-level focus areas |
| Endpoint cost | **$0.09/review**: $0.0783 input + $0.0091 output |

This run corrects a material claim in the original survey: PR-Agent **does** have a local diff mode, and `--stdin` needs no GitHub token. The measured `review` command did not emit file/line anchors, however. Its two focus areas were:

1. "Duplicated Logic" — suggested extracting the shared filtering in `count_live_chips()` and `count_live_chips_numbers()` to prevent future drift.
2. "Extra API Call" — suggested refactoring the explicitly accepted extra `open_among` call out of JSON diagnostic mode.

| Finding | Hosted overlap | Classification |
|---|---|---|
| Duplicated filtering | None | Non-actionable refactor suggestion; it identifies future drift risk but no current defect. |
| Extra diagnostic API call | None | Non-actionable. The code explicitly documents and accepts this diagnostic-only tradeoff. |

**Result:** 0 confirmed true positives, 0 confirmed overlaps, 2 unique non-actionable findings, and no line anchors. The capability contradiction is called out explicitly: the CUT verdict can no longer rest on "no local diff mode"; it rests on the measured output quality and lack of line-level local findings.

### 7.4 Hosted-reviewer comparison

On the exact `0b6ad100` head, CodeRabbit found 2 major defects and CodeAnt found 1 major plus 2 minor defects. `ocr` reproduced CodeAnt's minor `offered_issue_nums` diagnostic leak with the same file/range and remedy; it did not find the other 4 hosted defects. PR-Agent did not reproduce a hosted defect. Because both self-hosted runs completed against the same revision, the zeroes below are comparable absence results rather than cross-revision inferences.

| Tool | Confirmed overlap | Unique true positives | False-positive / non-actionable findings | Line anchors in measured local output |
|---|---:|---:|---:|---|
| `ocr` v1.9.10 | 1 | 0 | 1 | Yes |
| PR-Agent v0.43.0 | 0 | 0 | 2 | No |

### 7.5 Raw output capture

The model-produced payloads below are reproduced verbatim apart from ANSI log coloring and the surrounding JSON/HTML presentation envelope. No credential value appears in them.

```text
ocr: Review complete: 2 finding(s) across 2 selected item(s).

[.claude/scripts/tests/active-work-cap.test.sh:85-90, low, maintainability]
The pattern matching relies on the state value (`open` or `merged`) being surrounded by spaces in the ARGS string. While this works correctly with the current implementation because `gh pr list --state open --author` generates ` open ` in the ARGS string, the catch-all error case doesn't provide specific guidance about what patterns it expects. Consider adding the expected patterns in the error message for debugging purposes.

[.claude/scripts/active-work-cap.sh:1241-1243, low, maintainability]
The `offered_issue_nums` JSON field includes `REG_NUMS` (all registry issue numbers) but `REG_NUMS` is never reduced to exclude pipeline-overlapping issues, even though `REG_CHIP_COUNT` is reduced. This creates a potential inconsistency: the field documentation says it shows "issue numbers that make up the offered-work term" to explain FREE=0, but it may include issues that are counted via `inline_pipelines` rather than `live_chips`. Consider filtering out pipeline issues from `REG_NUMS` when computing `OFFERED_ISSUE_NUMS_JSON` for strict consistency.
```

```text
PR-Agent: Recommended focus areas for review

Duplicated Logic
`count_live_chips_numbers()` duplicates the pipeline-exclusion and registry-exclusion logic from `count_live_chips()`. If the filtering logic changes in one function, the other must be updated in lockstep or they will diverge, causing inconsistent counts between the numeric output and the issue-number list. Consider extracting the shared filtering into a helper function.

Extra API Call
In `--json` mode, `count_live_chips_numbers()` is called after `count_live_chips()` has already run. The comment acknowledges this makes "one extra open_among GraphQL call" but dismisses it as acceptable. For repos with many issues, this doubles the GraphQL cost in diagnostic mode. Consider refactoring `count_live_chips()` to return both the count and the surviving issue numbers in a single pass.

Model: anthropic/claude-opus-4-5-20251101
Tokens: 15,650 in / 362 out / 16,012 total
Time cost: 9.2s
AI calls: 1
```

### 7.6 Completed follow-up checklist

- [x] Point a self-hosted candidate at the Anthropic endpoint and confirm line-level findings on a real repository diff — `ocr` completed with two line-anchored findings on two shell files.
- [x] Run the shortlist against a PR with existing CodeRabbit/CodeAnt findings and record overlap, unique findings, and false positives — both tools completed against the exact reviewed PR #1295 head; `ocr` reproduced 1 CodeAnt finding and PR-Agent reproduced none.
- [x] Measure wall-clock and token cost per review — `ocr`: 85.92 seconds and $0.79; PR-Agent: 14.35 seconds and $0.09, both against Claude Opus 4.5.
