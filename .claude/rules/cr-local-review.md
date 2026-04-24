## Local CodeRabbit Review Loop (Primary)

> **Always:** Run local CR review before pushing. Verify findings against code before fixing. One clean pass to exit.
> **Ask first:** Never — fix all findings autonomously. Never ask "should I run the review?", "should I push?", or "should I create a PR?" — these transitions are automatic.
> **Never:** Push code without running local review. Fall back to GitHub polling when CLI works. Ask permission at any step in this workflow. Treat local review as satisfying the merge gate — only the GitHub review loop (CR + BugBot + Greptile) satisfies the merge requirement.

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

### Never Suppress Linter Errors (NON-NEGOTIABLE)

**NEVER add `eslint-disable`, `@ts-ignore`, `@ts-expect-error`, `noqa`, or any linter suppression comment** to work around CI failures. These hide bugs instead of fixing them.

When CI lint/typecheck fails:
1. Read the error messages
2. Fix the actual code — unused vars, missing types, incorrect imports, etc.
3. If the error is in a file you didn't modify, fix it anyway — broken lint blocks the entire pipeline

The only acceptable use of suppression comments is when the linter is provably wrong about a specific line AND you add a comment explaining why.

### Timeout & fallback
- If `coderabbit review` hangs for more than **2 minutes** or errors out, skip it and run a **self-review** instead (see self-review fallback rules).
- Do not retry more than once. If CR CLI fails twice, it's down — move on with self-review.

### Exit criteria
- **One clean local review** with no findings (or one clean self-review if CR CLI is unavailable)
- Once clean, commit all changes and push the branch
- **This transition is automatic.** After a clean pass, IMMEDIATELY commit and push — do not ask "should I push now?" or "ready to create a PR?"

### Post-Clean: Push, PR, and GitHub Review (AUTOMATIC — do not ask)

After a clean local review, execute this checklist immediately:

> **STOP — Local review does NOT satisfy the merge gate.** The GitHub review loop (CR + BugBot + Greptile) is mandatory: 1 clean CR approval on the current HEAD SHA, 1 clean BugBot pass, or a clean Greptile severity gate (see `cr-merge-gate.md`). Proceed immediately — do not ask.

1. **Commit all changes** in a single commit.
2. **Push the branch** to the remote.
3. **Create the PR** via `gh pr create` with `Closes #N` in the body and a Test Plan section with acceptance criteria checkboxes.
4. **Enter the GitHub CodeRabbit Review Loop** (see `cr-github-review.md` "Polling" section). CR and BugBot both auto-review on push — poll for both immediately, do not wait. BugBot is second-tier fallback if CR fails (see `bugbot.md`). Greptile is last-resort: triggered only when both CR and BugBot have failed (see `greptile.md` "When to Trigger Greptile"). Never trigger Greptile proactively while CR or BugBot is still expected to respond.
