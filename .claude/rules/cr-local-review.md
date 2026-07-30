# Local Review Loop — CodeRabbit + CodeAnt CLIs (Primary)

> **Always:** Run both local CLI reviews (CodeRabbit + CodeAnt) before push; verify findings; exit after one clean pass on each available CLI (Timeout & fallback below governs dropping one).
> **Ask first:** Never — review, fix, push, PR creation are automatic.
> **Never:** Push before local review; treat local review as the merge gate; skip a healthy CLI because the other came back clean.

Primary review workflow — catches issues before PR noise/quota; does not replace the GitHub merge gate.

### Prerequisites

- CodeRabbit CLI installed/authenticated (`coderabbit --version`); `.coderabbit.yaml` if the repo uses CR. `CODERABBIT_API_KEY` may live in shell config — never print or commit.
- CodeAnt CLI installed/authenticated (`codeant --version`); never print or commit its key.

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
5. Repeat until **each available CLI** returns a verified-successful run with no findings

### A "clean" result may be a failed run (NON-NEGOTIABLE)

**Both CLIs exit `0` on total failure**, each hiding the error on a different stream — CodeAnt on **stderr**, CodeRabbit as a stdout NDJSON `type: "error"` record. Capture both streams and check before trusting any "no findings":

```bash
codeant review --all --headless >ca.json 2>ca.err
grep -qE 'API Error|\[error\]|40[13]' ca.err && echo "FAILED RUN"
coderabbit review --agent >cr.out 2>cr.err
jq -e 'select(.type=="error")' cr.out >/dev/null && echo "FAILED RUN"
```

A hit is a **failed run** (Timeout & fallback below), never a clean pass. An empty result is clean **only** when its error check is clean and, for CodeAnt, `meta.capped` is `false`. Failure shapes, 403 triage, 15-file cap: `.claude/reference/local-review-cli-failure-modes.md`.

> **Never run `codeant logout`/`login` to clear a 403** — the cause is an undocumented daily cap (~10 agent reviews), not auth. On a CodeAnt 403: one retry, then drop for the session and note it in the PR body. The CodeAnt GitHub App is unaffected and satisfies the merge gate alone.

### Never Suppress Linter Errors (NON-NEGOTIABLE)

Never add `eslint-disable`, `@ts-ignore`, `@ts-expect-error`, `noqa`, or equivalent just to pass CI. Read the lint/type errors and fix the code, even in a file you did not modify. Suppression is allowed only when the linter is provably wrong and the comment explains why.

### Timeout & fallback

- Per CLI: hangs for more than **2 minutes** or errors out twice → drop that CLI for the session and note it in the PR body. Preserve any findings it already emitted — the remaining CLI gates only after those are resolved or explicitly waived in the PR body. Do not retry a failed CLI more than once.
- If both CLIs are down, run a **self-review** instead (see self-review fallback rules).

### Exit criteria

- **One verified-successful clean pass on both CLIs** (or on the surviving CLI + PR-body note; one clean self-review if both are unavailable). "No findings" alone is not a clean pass.
- Once clean, **immediately** commit, push, create/update the PR (`Closes #N` + Test Plan checkboxes), and enter `cr-github-review.md`. Local review never satisfies `cr-merge-gate.md`.
