# Trust Dialog Re-Prompting — Background and Repair Detail

Expanded detail for `.claude/rules/trust-dialog-fix.md`. The binding rule and the repair commands are there; this file explains the mechanism.

## Why it happens

Claude Code stores approval state per *project path* in `~/.claude.json`. A path it has not seen before is a new project entry, created with `false` defaults — so the trust dialog and the external-includes approval both re-prompt.

Every new worktree is a new path, so a workflow built on worktrees hits this constantly.

This repo amplifies it: `~/.claude/CLAUDE.md` and `~/.claude/rules` are symlinks into `~/.claude/skills-worktree/` (see `.claude/rules/skill-symlinks.md`). Claude Code's external-includes detection sees the rule corpus resolving outside the project directory and asks for approval on top of the trust prompt.

## The three flags

All three must be `true` for a given project entry:

| Flag | Suppresses |
|------|-----------|
| `hasTrustDialogAccepted` | the trust dialog |
| `hasClaudeMdExternalIncludesApproved` | external-includes re-approval |
| `hasClaudeMdExternalIncludesWarningShown` | the external-includes warning |

Setting only the first still leaves the includes prompts, which is the usual reason a partial hand-repair appears not to work.

## Repair scripts

- `.claude/scripts/repair-trust-single.sh /path/to/project` — one project entry
- `.claude/scripts/repair-trust-all.sh` — every entry in the file

Both write atomically (`tempfile` + `os.replace`) so an interrupted run cannot truncate `~/.claude.json`. Never delete the file to "reset" it: Claude Code recreates it with `false` defaults for every project, which reintroduces the prompt everywhere at once.

## Automatic repair

The `trust-flag-repair.sh` Stop hook (registered in `global-settings.json`) repairs all flags after every response.

It cannot pre-empt the *first* prompt in a brand-new worktree, because no project entry exists until Claude Code creates one. The sequence is: first prompt appears → user answers → response completes → hook repairs → no further prompts for that path.

## Related

The same symlink topology caused CLAUDE.md + rules double-loading, fixed separately via project-local `claudeMdExcludes` in `.claude/settings.json` — see `.claude/reference/double-loading-fix.md`.
