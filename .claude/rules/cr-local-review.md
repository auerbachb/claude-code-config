## Local CodeRabbit Review Loop (Primary)

> **Always:** Run local CR review before pushing. Verify findings against code before fixing. Two clean passes to exit.
> **Ask first:** Never — fix all findings autonomously.
> **Never:** Push code without running local review. Fall back to GitHub polling when CLI works.

This is the **primary** review workflow. Run CodeRabbit locally in your terminal to catch issues **before** pushing or creating a PR. This is faster than GitHub-based reviews (instant feedback, no polling), produces no noise on the PR, and doesn't consume your GitHub-based CR review quota.

### Prerequisites
- **CodeRabbit CLI** installed and authenticated:
  ```
  curl -fsSL https://cli.coderabbit.ai/install.sh | sh
  coderabbit auth login
  ```
- **Config:** `.coderabbit.yaml` in repo root (if the repo uses CodeRabbit)
- **Verify installation:** `coderabbit --version` or `which coderabbit`
- **Default install location:** `~/.local/bin/coderabbit`
- If `coderabbit` is not in PATH, use the full path: `~/.local/bin/coderabbit`
- **API key:** `CODERABBIT_API_KEY` is set in `~/.zshrc` — this links CLI reviews to the paid Pro plan with usage-based credits. Do NOT hardcode or commit this key anywhere.
- **Always prefer local** `coderabbit review --prompt-only` over GitHub CR polling. Do NOT fall back to the GitHub CR polling loop unless local review explicitly fails.

### When to run
- After finishing implementation on a feature branch, **before pushing or creating a PR**
- After making any significant changes during development (optional — use judgment on whether a local review pass is worthwhile mid-development)

### How to run
Run the CLI directly via Bash from the repo root:
- `coderabbit review --prompt-only` — review all changes (prompt-only mode is optimized for AI agent parsing)
- `coderabbit review --prompt-only --type uncommitted` — review only uncommitted changes
- `coderabbit review --prompt-only --type committed` — review only committed changes

### Fix loop
1. Run `coderabbit review --prompt-only` to review changes
2. Parse the findings — verify each against the actual code before fixing
3. Fix **all valid findings**
4. Run `coderabbit review --prompt-only` again
5. Repeat until CR returns no findings

### Timeout & fallback
- If `coderabbit review` hangs for more than **2 minutes** or errors out, skip it and run a **self-review** instead (see self-review fallback rules).
- Do not retry more than once. If CR CLI fails twice, it's down — move on with self-review.

### Exit criteria
- **Two consecutive clean local reviews** with no findings (or two clean self-reviews if CR CLI is unavailable)
- Once clean, commit all changes and push the branch

### Then: push and create the PR
- After the local review loop passes, push the branch and create the PR
- CodeRabbit will still auto-review on GitHub — enter the **GitHub CodeRabbit Review Loop** as a safety net
- Because you already cleaned up locally, the GitHub review should find nothing or very little
