---
name: open-code-review
description: Run Alibaba's self-hosted Open Code Review (`ocr`) CLI on Git changes to produce line-level review comments. Use as a self-hosted supplemental/manual reviewer alongside the CR -> BugBot -> Greptile chain. Not part of the merge gate.
triggers:
  - ocr run
  - open code review
  - ocr review
  - self-hosted review
  - review with ocr
model: sonnet
allowed-tools:
  - Read
  - Glob
  - Grep
  - Bash
  - WebFetch
---

Invoke [open-code-review](https://github.com/alibaba/open-code-review) (`ocr`) — Alibaba's open-source, Apache-2.0, self-hosted AI code-review CLI — as a supplemental reviewer. `ocr` reads a Git diff, selects/bundles files deterministically, runs an LLM agent against a configurable endpoint, and emits structured line-level comments.

This skill adapts the upstream `skills/open-code-review/SKILL.md` (Apache-2.0, author: alibaba) to this repo's conventions. Source of truth for flags: `ocr review -h`.

> **Scope:** OCR is a **manual / advisory** reviewer here. It is **not** in the merge gate (`cr-merge-gate.md`) and does **not** satisfy review requirements. Promotion into the chain is a separate, deferred decision — see `.claude/reference/ocr-eval.md`.
> **Cost:** OCR runs against the same Anthropic key as everything else, so its tokens count toward the daily quota. Big `ocr review` runs on large PRs can be expensive — prefer `--from/--to` or `--commit` over whole-repo `scan`.

## Step 1: Prerequisites check

```bash
which ocr || echo "NOT INSTALLED"   # install: npm install -g @alibaba-group/open-code-review
ocr version
ocr llm test                         # must return connectivity OK before a real review
```

If `ocr llm test` fails, OCR has no usable LLM credential. **Never invent, hardcode, or commit an API key.** OCR reuses the existing Anthropic credential — guide the user to provide it via env var (preferred) rather than writing it to the config file:

```bash
# Provider mode (config has provider: anthropic) + standard sk-ant-* key:
export ANTHROPIC_API_KEY=<existing-key>     # satisfies the x-api-key header path
```

Persistent (non-secret) config lives in `~/.opencodereview/config.json`. The vetted setup for this fleet is:

```bash
ocr config set provider anthropic
ocr config set providers.anthropic.model claude-opus-5      # current lineup (Opus 5)
ocr config set providers.anthropic.auth_header x-api-key    # required for sk-ant-* keys
```

Config-mode gotcha (OCR 1.6.1): when `provider` is set, OCR uses the **provider-scoped** resolver (`providers.<name>.*` + `ANTHROPIC_API_KEY`) and ignores the legacy `llm.*` / `OCR_LLM_*` keys and `ANTHROPIC_AUTH_TOKEN`. The provider model must be set via `providers.anthropic.model` (or `--model`); `ANTHROPIC_MODEL` env is not read in this mode.

## Step 2: Gather business context

Summarize the intent of the change (issue link, what it enables) into one or two sentences. Pass it via `--background` to improve review quality.

## Step 3: Run the review

Always use `--audience agent` (summary only, no progress UI):

| User says | Command |
|-----------|---------|
| "review my changes" / working copy | `ocr review --audience agent -b "<context>"` |
| "review this PR" / feature branch | `ocr review --audience agent -b "<context>" --from main --to <branch>` |
| "review commit abc123" | `ocr review --audience agent -b "<context>" --commit abc123` |
| "what would be reviewed?" (dry run) | `ocr review --preview` |

Useful flags: `--format json` (machine-readable), `--concurrency <n>` (lower if rate-limited), `--timeout <min>`, `--model <id>` (override, e.g. a Sonnet-tier model for cheaper bulk passes), `--rule <file.json>` (custom rules).

**Markdown/config-repo caveat:** OCR's deterministic pipeline excludes files with unsupported extensions (e.g. `.md`) as `unsupported_ext`. In doc/config-heavy repos like this one, `ocr review --preview` will show most files excluded — OCR adds little here without a custom rule/tools config. It is most valuable on code-heavy (TS/Python/Go) repos.

## Step 4: Classify and report

Group every OCR comment by priority and report to the user:

- **High** — clear bugs, security issues, well-founded fixes with precise proposals.
- **Medium** — context-dependent concerns, style/perf suggestions, manual-fix items.
- **Low** — likely false positives, nitpicks, low-context guesses.

## Step 5: Fix (only on request)

If the user asked to "review and fix", apply fixes. If they asked only to "review", ask before changing anything.

## Privacy

OCR contacts only the configured provider endpoint (Anthropic API by default). It does not send code to any third-party review service. Verify with `ocr review --preview` (no network) and by confirming the provider config (`providers.<name>` base URL) in `~/.opencodereview/config.json`.
