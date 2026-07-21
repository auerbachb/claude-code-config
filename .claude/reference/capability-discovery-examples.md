# Capability Discovery — False Walls vs Real Walls

Extracted from `.claude/rules/safety.md` "Capability Discovery — Try CLI Before Handoff". The rule file keeps the operative rule and the verbatim `MINDSET:` block; this file holds the worked catalog. **Extend the false-walls list as new ones are observed.**

## Common false walls (usually doable)

- Manual Actions run → `gh workflow run <workflow> --ref <branch>`
- Review approve/reject → `gh pr review --approve|--request-changes`
- Admin-bypass merge → `gh pr merge --admin`
- workflow_dispatch → `gh api repos/{owner}/{repo}/actions/workflows/{id}/dispatches -f ref=<branch>`
- Release create → `gh release create`
- Comment → `gh pr comment` / `gh issue comment`
- Label/assign → `gh issue edit` / `gh pr edit`

An agent's own explicit prohibitions still win (e.g. `phase-c-merger` uses `/wrap`, never `gh pr merge` directly).

## Real walls (handoff is correct, but structured)

A token-scope 403 with no workaround, a branch-protection change, a `.env` edit, or anything in `safety.md`'s "Never" lists. Use the `/admin-merge` (#451) pattern: exact copy-paste command, a one-line reason, optional terminal staging — never just a description.

## Anti-pattern

Typing "agents can't do X" where X sounds like something `gh` or `git` handles — stop and verify; the default answer is you probably CAN. This doesn't loosen any prohibition: check `safety.md`'s "Never" lists before assuming a capability is off-limits.
