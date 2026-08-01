---
name: Review CLIs down ≠ App reviewers down
description: When both local CLIs are unavailable, GitHub App reviewers are unaffected — but the zero-coverage state must be surfaced loudly, not silently
type: feedback
---

# Review CLIs down ≠ App reviewers down

During PR #763, both local review CLIs were unavailable simultaneously: CodeRabbit CLI returned `{"type":"error","errorType":"rate_limit"}` (OSS quota exhausted) and CodeAnt CLI was not installed (`codeant: command not found`). The both-CLIs-down → self-review fallback ran correctly per `cr-local-review.md`, but the push proceeded with the only signal being a freeform line in the PR body — invisible unless a human happened to read it. GitHub App reviewers then caught a High-severity bug the local layer would plausibly have caught.

**Durable lessons:**

1. **CLI quotas are independent of App reviewer quotas.** A rate-limited or absent CodeRabbit/CodeAnt CLI has zero effect on the CodeRabbit GitHub App or CodeAnt GitHub App. Both Apps continue reviewing PRs normally while their CLIs are dark. A capped CLI never blocks a merge — the App still gates it.

2. **Zero-coverage is a distinct state that must be surfaced loudly.** When both CLIs are unavailable (`coverage: none`), the local review layer contributed nothing while reporting "handled". The fix (Issue #769): classify coverage as `both | cr-only | codeant-only | none` and print `[COVERAGE] none — both CLIs unavailable, self-review only` in-thread before the push decision, plus a labeled line in the PR body. This is never a merge blocker — it is visibility only.

3. **Self-review is risk-reduction, not coverage.** A self-review exits the local loop correctly per the rules but never satisfies the GitHub merge gate. It should be surfaced in-thread, not only as a footnote in the PR body.

**Provenance:** Issue #769, PR #763 incident; related issues #642 (CodeAnt false-clean on API failure), #643 (403 entitlement), #663 (CodeAnt 403 re-auth advice).

**Standing state update (2026-07-30, Issue #819):** CodeAnt CLI binary is now installed (`npm install -g codeant-cli` ran during PR #819, v0.5.1 at `/opt/homebrew/bin/codeant`). Auth (`codeant login`) is a rung-5 wall — CLI-initiated browser OAuth only, no non-interactive path, and no MCP browser surface can drive it. Coverage remains `cr-only` until a human runs `codeant login` or `codeant set-codeant-api-key <key>`. Merge gate is unaffected — CodeAnt GitHub App still approves independently. Restore runbook: `.claude/reference/codeant-graphite-supplemental.md` §Install state.
