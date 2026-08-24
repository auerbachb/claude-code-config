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
> are suppressed throughout. API-key-dependent runs were not possible in this session (no
> `ANTHROPIC_API_KEY` or `OPENAI_API_KEY` in the agent environment); this is stated per
> candidate rather than asserted once and forgotten.

---

## Executive summary

| Candidate | Category | Verdict | Limiting constraint |
|-----------|----------|---------|---------------------|
| `ocr` (alibaba/open-code-review) | Self-hosted | **CUT — confirmed** | Excludes `.md` files; 0 of 2 PR #1292 files reviewable; no API key available for code-file test |
| Qodo PR-Agent | Self-hosted | **CUT** | GitHub-PR-URL interface only; no local diff mode; no API key available |
| CodeRabbit CLI | Hosted (incumbent) | **KEEP** | OSS pool: 3 reviews/~55-min window on this public repo |
| CodeAnt CLI | Hosted (incumbent) | **KEEP** | Daily cap applies; auth restored 2026-08-23 |

**Verdict in one sentence:** Neither self-hosted candidate is viable for the local pre-push slot in this doc-heavy repo — `ocr` excludes every `.md` file it would encounter, and PR-Agent has no local-diff mode — so the chain is unchanged, and the local pass continues under CodeRabbit + CodeAnt.

---

## 1. Candidate census

### 1.1 Self-hosted candidates

| Field | `ocr` (alibaba/open-code-review) | Qodo PR-Agent |
|---|---|---|
| **License** | Apache-2.0 | Apache-2.0 |
| **Upstream** | github.com/alibaba/open-code-review | github.com/qodo-ai/pr-agent |
| **Install path** | `npm install -g @alibaba-group/open-code-review` (verified) | `pip3 install pr-agent` (verified) |
| **Install verified** | Yes — v1.9.10 installs, binary resolves, `--version` succeeds | Yes — v0.43.0 installs, `python3 -m pr_agent.cli --help` succeeds |
| **Runs non-interactively** | Yes, with configured LLM endpoint; install is non-interactive | Partial — install is non-interactive; review requires `--pr_url` and GitHub token |
| **Fully local (no vendor account)** | Yes — only an LLM API key is required | No — requires GitHub API token to fetch PR data |
| **LLM providers accepted** | Anthropic, OpenAI, and any OpenAI-compatible endpoint via `OCR_LLM_URL`; configured via `ocr config set` | Anthropic, OpenAI, Azure OpenAI, Google Gemini, AWS Bedrock, and others via litellm |
| **Line-level findings** | Yes — the core design goal; line-level comments with file/range anchors | Yes — inline PR comments with line numbers |
| **Local diff mode** | Yes — `ocr review` reads git diff from working tree or a commit range | No — `--pr_url` only; fetches diff from GitHub API |
| **Cost per review** | Only LLM endpoint cost (model-dependent); no vendor quota metered | Only LLM endpoint cost; no vendor quota |
| **`.md` file support** | **No** — `.md` excluded as `unsupported_ext` (confirmed via `ocr delegate preview` on PR #1292 commit) | Yes — reads all file types accessible via GitHub PR diff |
| **Maintenance burden** | Binary from npm; major releases every few weeks in 2026 | Python package; active maintenance; self-host or Docker |
| **Notable limitation** | Extension exclusion of `.md` is built into the binary with no CLI override flag (`--exclude` only adds exclusions, does not un-exclude) | GitHub-centric; no equivalent to `ocr review` for pre-push local diff |
| **Delegation mode** | **Yes** — `ocr delegate` outputs a review spec that the host agent (Claude Code) can execute; no API key required for delegation | No — LLM key and GitHub token both required |

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

**PR-Agent:** Not run. PR-Agent requires a GitHub token and an LLM key. Neither was available in the session environment. Evidence limitation: `python3 -m pr_agent.cli --pr_url=https://github.com/auerbachb/claude-code-config/pull/1292 review` confirmed the error shape (`BoxKeyError: user_token`) but no review output was produced. Absence claims are suppressed for PR-Agent; the PR-URL-based interface would likely produce findings on the `.md` content if credentials were configured.

### 2.4 Token cost methodology

No self-hosted review was completed in this session due to absent API keys. Token cost cannot be measured. The methodology for a future measurement:

- For `ocr`: run `ocr review --from <base> --to <head> --format json --audience agent`; capture the token counts from the JSON output (input/output tokens per file). Multiply by the model's published per-token price.
- For PR-Agent: similar — token counts logged to stdout; multiply by model price.
- Comparison basis: **cost-per-review-session**, not "free vs paid" (both tools are metered by the LLM endpoint, not by a vendor quota).

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

Ground 2 remains unresolved: a session with `ANTHROPIC_API_KEY` or `OPENAI_API_KEY` configured could run `ocr review` on a diff containing `.sh`, `.go`, `.json`, or other supported extensions to verify finding quality. This survey does not supply that evidence.

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

---

## 6. Scope note — data flow

PR diffs sent to a self-configured LLM endpoint carry the same data-flow question as diffs sent to a hosted vendor.

**For the local pre-push workflow specifically** (the slot this survey evaluates): the diff is constructed from the developer's local working tree before it is pushed to GitHub. At this stage the diff is not yet public, even for a public repository. Required checks before routing any pre-push diff to a self-configured endpoint: (1) run `git diff` through a secret-scanning pass (`git secrets --scan` or equivalent) to confirm no accidentally staged credentials; (2) review the provider's data processing and retention terms for the model endpoint in use.

**For a diff that is already public** (e.g., re-reviewing PR #1292's merged commit): the diff content is already publicly readable on GitHub, which reduces but does not eliminate residual risks. Residual risks include: provider training and retention policies, metadata (file paths, commit messages, author identities) that may be logged beyond the diff content itself, and routing through the provider's infrastructure. The disclosure risk is lower than for a pre-push diff but is not zero.

This is noted as a structured check rather than a settled blanket statement, as the issue requested.
