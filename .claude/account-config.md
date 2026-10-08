# Account Config

Account-level settings that span every repo this harness works in, as opposed to
`.claude/pm-config.md`, which is per-repo. The AI review vendors bill one account
across every repo they review, so their costs and caps belong here (issue #1747).

Tracked in this repo so changes are reviewable, and published to
`~/.claude/account-config.md` through the skills worktree, as `CLAUDE.md` and the
rules are (`.claude/rules/skill-symlinks.md`). Sections are read with
`pm-config-get.sh --file "${CLAUDE_ACCOUNT_CONFIG:-$HOME/.claude/account-config.md}" --section "<name>"`.

## Review repos

<!-- The repos whose PRs the AI reviewers bill against this account. Read by
     review-repos.sh, which /review-stack-audit uses for its multi-repo roll-up
     (`measure.sh --all-repos`). This explicit list is the record: when it is
     empty, review-repos.sh falls back to discovering every non-archived repo
     under `owner` whose default branch carries .github/workflows/<discovery_marker>.
     Add a repo by hand when we review it without running the harness there —
     it still draws down the account caps, and discovery cannot see it.
     One Markdown bullet per repo; the first token is owner/name. Every
     bullet outside a comment is read as a repo, so keep notes in comments. -->

```ini
owner = auerbachb
discovery_marker = ac-gate.yml
```

- auerbachb/claude-code-config
- auerbachb/meeting_insights_and_actions
- auerbachb/sales-kit
- auerbachb/still-point
