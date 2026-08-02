# Local Review Loop — CodeRabbit + CodeAnt CLIs (Primary)

> **Always:** Run both local CLI reviews (CodeRabbit + CodeAnt) before push; verify findings; exit after one clean pass on each available CLI (Timeout & fallback below governs dropping one).
> **Ask first:** Never — review, fix, push, PR creation are automatic.
> **Never:** Push before local review; treat local review as the merge gate; skip a healthy CLI because the other came back clean.

Primary review workflow — catches issues before PR noise/quota; does not replace the GitHub merge gate.

### Prerequisites

- CodeRabbit CLI installed/authenticated (`coderabbit --version`); `.coderabbit.yaml` if the repo uses CR. `CODERABBIT_API_KEY` may live in shell config — never print or commit.
- CodeAnt CLI installed/authenticated (`codeant --version`); never print or commit its key.

### When/how to run

After implementation, before push. Run from repo root via `.claude/scripts/local-review.sh` — it invokes the CLI, applies every false-clean check below, and returns one line:

- `.claude/scripts/local-review.sh --tool coderabbit` → `coderabbit review --agent`
- `.claude/scripts/local-review.sh --tool codeant` → `codeant review --all --headless`
- Scoping: `--scope uncommitted|committed`. Base branch: `--base <branch>`. Hang bound: `--timeout` (default 120s).

### Fix loop

1. Run both CLIs on the change set
2. Union the findings — verify each against the actual code before fixing
3. Fix **all valid findings**
4. Run both CLIs again
5. Repeat until **each available CLI** returns a verified-successful run with no findings

### A "clean" result may be a failed run (NON-NEGOTIABLE)

**Both CLIs exit `0` on total failure**, each hiding the error on a different stream — CodeAnt on **stderr**, CodeRabbit as a stdout NDJSON `type: "error"` record. Do not hand-roll the capture-and-grep: `local-review.sh` applies every documented check (stderr error, error record, missing terminal record, nothing-reviewed, 15-file cap, 2-min hang) and emits

`{"ok":…,"findings":N,"verified_run":…,"failure_mode":…,"relevant_error":…,"log_path":…}`

with the raw capture at `log_path`. Exit `0` clean · `1` findings · `3` failed run · `4` timeout · `5` not installed. A CLI counts as covered **only** on `verified_run == true && ok == true`; every other result is a **failed run** (Timeout & fallback below), never a clean pass. Failure shapes, 403 triage, 15-file cap: `.claude/reference/local-review-cli-failure-modes.md`.

> **Never run `codeant logout`/`login` to clear a 403** — the cause is an undocumented daily cap (~10 agent reviews), not auth. On a CodeAnt 403: one retry, then drop for the session and note it in the PR body. The CodeAnt GitHub App is unaffected and satisfies the merge gate alone.

### Never Suppress Linter Errors (NON-NEGOTIABLE)

Never add `eslint-disable`, `@ts-ignore`, `@ts-expect-error`, `noqa`, or equivalent just to pass CI. Read the lint/type errors and fix the code, even in a file you did not modify. Suppression is allowed only when the linter is provably wrong and the comment explains why.

### Timeout & fallback

- Per CLI: hangs for more than **2 minutes** or errors out twice → drop that CLI for the session and note it in the PR body. Preserve any findings it already emitted — the remaining CLI gates only after those are resolved or explicitly waived in the PR body. Do not retry a failed CLI more than once.
- If both CLIs are down, run a **self-review** instead (see self-review fallback rules).

**Coverage classification (determine before every push):** Based on which CLIs produced a verified-successful clean pass (not merely exit 0, applying the false-clean checks above), classify as one of: `both` (both passed) | `cr-only` | `codeant-only` | `none` (both unavailable — self-review only). A rate-limited, stderr-erroring, binary-absent, or no-review-records CLI counts as **not covered** for that CLI. Coverage is visibility-only and never feeds the merge gate (`cr-merge-gate.md`). Failure-state-to-enum mapping: `.claude/reference/local-review-cli-failure-modes.md`.

### Exit criteria

- **One verified-successful clean pass on both CLIs** (or on the surviving CLI + PR-body note; one clean self-review if both are unavailable). "No findings" alone is not a clean pass.
- **Determine and record coverage** (see Timeout & fallback above) before committing/pushing. Surface any degraded state (`none`, `cr-only`, or `codeant-only`) in-thread and in the PR body.
- Once clean, **immediately** commit, push, create/update the PR (`Closes #N` + Test Plan checkboxes), and enter `cr-github-review.md`. Local review never satisfies `cr-merge-gate.md`.
