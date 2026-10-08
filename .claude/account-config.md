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

## Review daily caps

<!-- One soft cap per paid reviewer, in USD per America/New_York day, for the
     whole account: review-daily-cap.sh sums today's spend for a platform across
     every repo in `## Review repos` and skips a paid trigger that would pass it
     (issue #1812). Soft: an unreadable tally reads `unknown` and the trigger
     still posts — the vendors' own caps stay the hard stop. Each key can be
     overridden by an environment variable of the same name; a value that is not
     a non-negative decimal warns and falls back to 10. Policy:
     .claude/reference/review-policy.md "Account-level daily cap". -->

```ini
REVIEW_DAILY_CAP_USD_BUGBOT = 10
REVIEW_DAILY_CAP_USD_CODERABBIT = 10
REVIEW_DAILY_CAP_USD_GREPTILE = 10
```
