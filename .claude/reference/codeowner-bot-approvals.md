# Code-Owner Bot Approvals (CODEOWNERS)

Full detail extracted from `.claude/rules/cr-merge-gate.md` (the rule file keeps a summary + pointer to here). Loaded on demand, not every turn.

Some repos list CR (`@coderabbitai`) or Greptile (`@greptile-apps`) in `CODEOWNERS`. When branch protection has `require_code_owner_reviews`, that bot's `APPROVED` review on the current HEAD SHA satisfies the code-owner approval requirement. Do not ask the PR author to self-approve; the bot approval is the terminal unblock when fresh.

Because `CODEOWNERS` varies by repo, this is a runtime check. `.claude/scripts/merge-gate.sh` reads `CODEOWNERS`, `.github/CODEOWNERS`, or `docs/CODEOWNERS`; when CR, Greptile, or **CodeAnt** (`@codeant-ai`) is a code owner it also requires GitHub `reviewDecision == "APPROVED"` on the current PR head. If branch protection is `BLOCKED` and a prior bot approval is stale/dismissed after a push, trigger that bot again (`@coderabbitai full review` for CR, `@greptileai` for Greptile, `@codeant-ai review` for CodeAnt) and keep polling. Human escalation is only for an actual human-authored `CHANGES_REQUESTED`, not stale bot approval.
