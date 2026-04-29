## Local CodeRabbit Review Loop (Primary)

> **Always:** Run local CR review before push; verify findings; exit after one clean pass.
> **Ask first:** Never — review, fix, push, PR creation are automatic.
> **Never:** Push before local review; treat local review as the merge gate.

This is the **primary** review workflow. It catches issues before PR noise/quota and does not replace the GitHub merge gate.

### Prerequisites

- CLI installed/authenticated (`coderabbit --version` or `~/.local/bin/coderabbit`).
- Repo has `.coderabbit.yaml` if it uses CR.
- `CODERABBIT_API_KEY` may live in shell config; never print or commit it.
- Prefer local `coderabbit review --prompt-only`; use GitHub polling only after push or CLI failure.

### When/how to run

After implementation on a feature branch, before push/PR. Optional mid-development when risk warrants. Run from repo root:

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

Never add `eslint-disable`, `@ts-ignore`, `@ts-expect-error`, `noqa`, or equivalent just to pass CI. Read the lint/type errors and fix the code, even in a file you did not modify. Suppression is allowed only when the linter is provably wrong and the comment explains why.

### Timeout & fallback
- If `coderabbit review` hangs for more than **2 minutes** or errors out, skip it and run a **self-review** instead (see self-review fallback rules).
- Do not retry more than once. If CR CLI fails twice, it's down — move on with self-review.

### Exit criteria
- **One clean local review** with no findings (or one clean self-review if CR CLI is unavailable)
- Once clean, commit all changes and push the branch
- **This transition is automatic.** After a clean pass, IMMEDIATELY commit and push — do not ask "should I push now?" or "ready to create a PR?"

### Post-Clean: Push, PR, GitHub Review

After a clean local review: commit, push, create/update PR with `Closes #N` and Test Plan checkboxes, then enter `cr-github-review.md` immediately. Local review never satisfies `cr-merge-gate.md`.
