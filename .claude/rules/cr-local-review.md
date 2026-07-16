## Local Review Loop — CodeRabbit + CodeAnt CLIs (Primary)

> **Always:** Run both local CLI reviews (CodeRabbit + CodeAnt) before push; verify findings; exit after one clean pass on each available CLI (Timeout & fallback below governs dropping one).
> **Ask first:** Never — review, fix, push, PR creation are automatic.
> **Never:** Push before local review; treat local review as the merge gate; skip a healthy CLI because the other came back clean.

Primary review workflow — catches issues before PR noise/quota; does not replace the GitHub merge gate.

### Anti–rate-limit pre-flight (local-first)

**~8 CR reviews/hour** (hidden cap, tier-dependent). **Batch locally:** run the Fix loop below to a clean pass, then **one commit, one push**. `/fixpr` matches: all threads + CI, **one** commit/push; cap + session tracking: `cr-github-review.md` and `cr-review-hourly.sh`.

### Prerequisites

- CodeRabbit CLI installed/authenticated (`coderabbit --version`); `.coderabbit.yaml` if the repo uses CR. `CODERABBIT_API_KEY` may live in shell config — never print or commit.
- CodeAnt CLI installed/authenticated (`codeant --version`); `codeant login` stores the key in `~/.codeant/config.json` — never print or commit it.

### When/how to run

After implementation, before push. Optional mid-development. Run from repo root:

- `coderabbit review --agent` — all changes (`--agent` emits structured NDJSON findings, optimized for agent parsing)
- `codeant review --all --headless` — all changes, committed + uncommitted (`--headless` emits clean JSON for agents)
- Scoping: CR `--type uncommitted` / `--type committed`; CodeAnt `--uncommitted` / `--committed`
- If base-branch detection fails (fresh clone, no remote), pass `--base <branch>` — both CLIs support it

### Fix loop
1. Run both CLIs on the change set
2. Union the findings — verify each against the actual code before fixing
3. Fix **all valid findings**
4. Run both CLIs again
5. Repeat until **each available CLI** returns no findings

### Never Suppress Linter Errors (NON-NEGOTIABLE)

Never add `eslint-disable`, `@ts-ignore`, `@ts-expect-error`, `noqa`, or equivalent just to pass CI. Read the lint/type errors and fix the code, even in a file you did not modify. Suppression is allowed only when the linter is provably wrong and the comment explains why.

### Timeout & fallback
- Per CLI: hangs for more than **2 minutes** or errors out twice → drop that CLI for the session and note it in the PR body. Preserve any findings it already emitted — the remaining CLI gates only after those are resolved or explicitly waived in the PR body. Do not retry a failed CLI more than once.
- If both CLIs are down, run a **self-review** instead (see self-review fallback rules).

### Exit criteria
- **One clean pass on both CLIs** (or on the surviving CLI + PR-body note; one clean self-review if both are unavailable)
- Once clean, commit all changes and push the branch
- **This transition is automatic.** After a clean pass, IMMEDIATELY commit and push — do not ask "should I push now?" or "ready to create a PR?"

### Post-Clean: Push, PR, GitHub Review

After a clean local review: commit, push, create/update PR with `Closes #N` and Test Plan checkboxes, then enter `cr-github-review.md` immediately. Local review never satisfies `cr-merge-gate.md`.
