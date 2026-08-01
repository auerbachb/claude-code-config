---
name: BugBot auto-trigger unreliable
description: Why we always post @cursor review on every PR push via CI and /fixpr — and why it requires a PAT
type: feedback
---

# BugBot auto-trigger unreliable

BugBot's GitHub "auto-trigger on push" is unreliable on later pushes even when settings suggest it should run every time. Agents used to post `@cursor review` only when no BugBot activity appeared on the new SHA after a wait; that detection frequently missed real gaps.

**Root cause (discovered issue #892):** BugBot silently ignores `@cursor review` comments authored by `github-actions[bot]`. The trigger comment must be authored by a human/non-bot identity. Measured on PR #891 in `auerbachb/claude-code-config` (three bot-authored triggers over 30 minutes: no BugBot response; one human trigger: check-run started in 5 seconds) and independently on `auerbachb/meeting_insights_and_actions` PR #172. The CI workflow `cursor-review-pr-comment.yml` now authenticates with `CURSOR_REVIEW_PAT` (fine-grained PAT, repository owner identity, `Pull requests: Read and write`) instead of `GITHUB_TOKEN`. When the secret is absent the workflow posts nothing and emits a warning — a bot-authored inert comment is worse than silence.

**Open vs push distinction:** BugBot auto-reviews a PR natively when it is first opened (this is a Cursor-side behavior, not triggered by the workflow). It does NOT re-review on subsequent pushes. The workflow exists solely to provide the push re-review. Every agent-posted manual `@cursor review` since the workflow landed has been doing the job the workflow was supposed to do automatically.

**Durable lesson:** BugBot's auto-trigger gap is not random unreliability — it is a structural bot-author filter. Keep the operational procedure (PAT secret, `CURSOR_REVIEW_PAT`) in `bugbot.md`; this memory captures the root cause and the open-vs-push distinction.
