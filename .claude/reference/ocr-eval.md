# OCR (open-code-review) Self-Host Evaluation

Issue: [#470](https://github.com/auerbachb/claude-code-config/issues/470)

Tool: [`alibaba/open-code-review`](https://github.com/alibaba/open-code-review) (`ocr`) — Apache-2.0, Go, hybrid architecture (deterministic pipeline + LLM agent).

Status: **Partial — local stand-up complete and verified; live side-by-side evaluation BLOCKED** (see [Blockers](#blockers)).

Last updated: 2026-06-25 (cloud agent VM).

## TL;DR

- `ocr` **v1.6.1** is installed and functional locally; CLI, config, deterministic file-selection pipeline, endpoint resolution, and the `x-api-key` auth path are all verified.
- OCR is configured for **Anthropic**, model **`claude-opus-4-8`** (current lineup), `auth_header=x-api-key`, **no credential written to disk** — the key is supplied at runtime via `ANTHROPIC_API_KEY`.
- `ocr llm test` cannot return a green result **in this environment** because there is **no Anthropic credential available** here and the issue forbids creating a new one. A fake-key run proved the request reaches `https://api.anthropic.com/v1/messages` and is rejected with `401 invalid x-api-key` — i.e. everything except the live key works.
- The OCR skill is installed in **this repo** (config-heavy). The second, product-heavy repo (`skingod`) and the 5+ PR side-by-side runs are **not reachable from this VM** and are deferred.
- **Preliminary recommendation:** keep OCR as a **manual / advisory** reviewer, **not** in the merge gate, and re-evaluate for the chain only on a code-heavy repo once a live key is available. Rationale below.

## Confirmed facts (safety checkpoint)

- npm package name confirmed against the npm registry before install: **`@alibaba-group/open-code-review`**, version `1.6.1`, homepage `https://github.com/alibaba/open-code-review`. Installed via `npm install -g` (vendor package — **not** a piped installer). Per `.claude/rules/safety.md` checkpoint "confirm package name before install".
- Installed to a user-local prefix (`~/.npm-global`) rather than a root prefix; no `sudo`-into-untrusted-PATH and no `curl | sh`.

## Config decision

| Item | Value | Notes |
|------|-------|-------|
| Provider | `anthropic` | Built-in provider; base URL `https://api.anthropic.com` |
| Model | `claude-opus-4-8` | Current lineup (Opus 4.8) per `.claude/agents/README.md`; supersedes the upstream docs' `claude-opus-4-6` example |
| Auth header | `x-api-key` | **Required** for standard `sk-ant-*` keys. Default would be `authorization` (Bearer) |
| Credential source | env `ANTHROPIC_API_KEY` at runtime | **Never written to `~/.opencodereview/config.json`** — no secret on disk |
| Config file | `~/.opencodereview/config.json` (perms `600`) | |
| Endpoint contacted | `https://api.anthropic.com/v1/messages` only | Verified — no third-party host |

Final `~/.opencodereview/config.json` (no secret):

```json
{
    "provider": "anthropic",
    "providers": {
        "anthropic": {
            "model": "claude-opus-4-8",
            "auth_header": "x-api-key"
        }
    },
    "llm": {
        "url": "https://api.anthropic.com",
        "auth_header": "x-api-key",
        "model": "claude-opus-4-8",
        "use_anthropic": true
    }
}
```

### Auth / env-var behavior (verified empirically on 1.6.1)

The issue assumed OCR reuses `ANTHROPIC_AUTH_TOKEN` / `ANTHROPIC_MODEL`. On 1.6.1 the behavior is more nuanced and worth recording:

- When `provider` is set, OCR uses a **provider-scoped resolver** (`providers.<name>.*`). Its credential env fallback is **`ANTHROPIC_API_KEY`** (matching `auth_header=x-api-key`). `ANTHROPIC_AUTH_TOKEN`, `OCR_LLM_TOKEN`, and `llm.auth_token` are **ignored** in this mode.
- The provider model must come from `providers.anthropic.model` (or `--model`). **`ANTHROPIC_MODEL` env is not read** in provider mode (it errors `no model configured`).
- The legacy `llm.*` block and the OCR-native env vars (`OCR_LLM_URL`/`OCR_LLM_TOKEN`/`OCR_LLM_MODEL`/`OCR_USE_ANTHROPIC`, README "highest priority") apply only to the **legacy** (no-`provider`) resolution path. Mixing `provider` + `llm.*` in one file (as the upstream `ocr config set llm.*` commands produce) is a config smell — the `llm.*` half is dead in provider mode.
- Claude-Code env compatibility (`ANTHROPIC_BASE_URL`/`ANTHROPIC_AUTH_TOKEN`/`ANTHROPIC_MODEL`, plus `~/.zshrc`/`~/.bashrc` parsing) is documented for the legacy path; not exercised here because we standardized on provider mode + `ANTHROPIC_API_KEY`.

## Installation

Prerequisites: Node (tested v22), npm (tested 10.9.7), network egress to `registry.npmjs.org` and `api.anthropic.com`.

Local CLI (verified):

```bash
npm install -g @alibaba-group/open-code-review        # -> `ocr` on PATH
ocr version                                           # open-code-review v1.6.1 ... linux/amd64
ocr config set provider anthropic
ocr config set providers.anthropic.model claude-opus-4-8
ocr config set providers.anthropic.auth_header x-api-key
export ANTHROPIC_API_KEY=<existing-key>               # runtime only — do not commit
ocr llm test                                          # expect connectivity OK with a valid key
```

Per-repo skill, two equivalent options:

- **Upstream-native (other repos):** `npx skills add alibaba/open-code-review` (`skills` = `vercel-labs/skills`). Pulls the upstream `skills/open-code-review/SKILL.md`.
- **Repo-native (this repo):** a vetted adaptation lives at `.claude/skills/open-code-review/SKILL.md`, matching this repo's frontmatter (`triggers`, `model`, `allowed-tools`) and distributed through the skills-worktree symlink mechanism. Chosen here for consistency with the existing skill family; it corrects the model id to `claude-opus-4-8` and documents the config-mode gotcha above.

Repos with OCR installed: **`claude-code-config` (this repo)**. Pending: **`skingod`** (product-heavy) — not reachable from this VM.

## What was verified

| Check | Result | Evidence |
|-------|--------|----------|
| Package name in npm registry | PASS | `@alibaba-group/open-code-review@1.6.1` |
| Global install + `ocr` on PATH | PASS | `ocr version` -> `v1.6.1 (034d512) linux/amd64` |
| CLI surface (`review`/`scan`/`config`/`llm`/`rules`/`viewer`) | PASS | `ocr --help` |
| Built-in providers incl. `anthropic` | PASS | `ocr llm providers` |
| Config written to `~/.opencodereview/config.json` (perms 600) | PASS | `cat` of file above |
| Model id = `claude-opus-4-8` | PASS | config + `.claude/agents/README.md` lineup note |
| Deterministic file-selection pipeline (no LLM) | PASS | `ocr review --commit HEAD --preview` |
| Endpoint resolution + `x-api-key` header | PASS | fake key -> `POST https://api.anthropic.com/v1/messages` -> `401 invalid x-api-key` (real Anthropic Request-ID) |
| No third-party leakage (only `llm.url` contacted) | PASS | same 401 trace; `--preview` is offline |
| `ocr llm test` green (live connectivity) | **BLOCKED** | no Anthropic key in this VM; issue forbids a new credential |

Notable real finding: on `ocr review --preview` of a markdown commit, **both `.md` files were excluded as `unsupported_ext`**. OCR's deterministic pipeline skips markdown by default, so on a doc/config-heavy repo like this one OCR reviews almost nothing without a custom `--rule`/`--tools` config. This materially shapes the recommendation.

## Blockers

1. **No Anthropic credential in this environment.** `env` exposes only `CURSOR_AGENT_IDENTITY_BROKER_TOKEN` (Cursor-internal, not an Anthropic key); `api.anthropic.com` returns 401 unauthenticated. The issue explicitly requires reusing an *existing* key with *no new credential*, so this agent must not mint or fetch one. → `ocr llm test` green and all live `ocr review` runs are blocked here. **To unblock:** add the existing Anthropic key as a Cloud Agent secret (`ANTHROPIC_API_KEY`) via the Cursor dashboard, or run the eval on a host where the key is already present.
2. **Single repo reachable.** Only `claude-code-config` is checked out in this VM (no access to `skingod` or other product repos). The "≥2 repos" and "5+ PR side-by-side" ACs require a multi-repo host.

## Side-by-side evaluation methodology (ready to execute once unblocked)

Run on a code-heavy repo (e.g. `skingod`) where OCR's ruleset (NPE, thread-safety, XSS, SQL injection) and TS/Python/Go file selection actually apply.

For 5+ recent PRs spanning sizes/languages and a mix of known-buggy and known-clean:

1. `ocr review --audience agent -b "<context>" --from main --to <branch>` (or `--commit <SHA>`); also a `ocr review` workspace run.
2. Run at least one pass with a Sonnet-tier `--model` for the cost comparison.
3. Monitor token spend on one medium PR (10–20 files); reconcile against the `/quota` tracker from #459 once it lands.
4. Capture results in the table below.

| PR | Files | OCR findings (H/M/L) | CR findings | BugBot | Greptile | OCR unique TPs | OCR false positives | Token cost | Notes |
|----|-------|----------------------|-------------|--------|----------|----------------|---------------------|------------|-------|
| TBD | TBD | TBD | TBD | TBD | TBD | TBD | TBD | TBD | TBD |

Test Plan items to confirm during execution: staged/unstaged review; `--from/--to` branch range; `--commit` single commit; known-buggy PR catches the same set; known-clean PR low false positives; token cost acceptable; one non-default (Sonnet-tier) model works; only `llm.url` contacted.

## Preliminary recommendation

Pending the live runs, the evidence so far supports **option (d): keep OCR as a manual / advisory, self-hosted fallback reviewer — invoked via the skill, not wired into the merge gate.** Specifically:

- **Do not** add OCR to `cr-github-review.md` / `cr-merge-gate.md` / `escalate-review.sh` yet. The merge gate must stay deterministic and reviewer-verified; promoting an unmeasured tool would weaken it. (The issue itself flags chain promotion as "likely defer to a follow-up.")
- **For this repo (config/markdown-heavy):** OCR is **low value** as-is — its pipeline excludes `.md` by default, which is ~all of this repo. CodeRabbit's path-instruction review of `CLAUDE.md`/`.claude/rules/**` remains the right primary here.
- **For product/code-heavy repos:** OCR is **promising** — self-hosted (no per-seat/per-review fee, no rate-limit quota), reuses the existing Anthropic key, and its deterministic file selection should scale better than pure-LLM reviewers on large changesets. This is exactly where the side-by-side should run before any chain decision.
- **Cost caveat:** OCR spends against the same Anthropic quota as everything else (#459). Large `ocr review` runs are not free in tokens even though the tool is free; treat it as budget-aware.

Revisit this recommendation after the blocked live runs complete. If, on a code-heavy repo, OCR produces unique true positives that CR/BugBot miss at acceptable token cost, the strongest candidate placement is as a **replacement for Greptile** (the paid last-resort tier), not as an additional always-on reviewer.

## Reproduction (this VM)

```bash
# install (user-local prefix; avoids root npm prefix)
npm install -g --prefix "$HOME/.npm-global" @alibaba-group/open-code-review@1.6.1
export PATH="$HOME/.npm-global/bin:$PATH"
ocr version

# configure (provider mode, no secret on disk)
ocr config set provider anthropic
ocr config set providers.anthropic.model claude-opus-4-8
ocr config set providers.anthropic.auth_header x-api-key

# offline checks (no key needed)
ocr llm providers
ocr review --commit HEAD --preview

# live check (needs a real key)
export ANTHROPIC_API_KEY=<existing-key>
ocr llm test
```
