# Trust Dialog Re-Prompting — Background and Repair Detail

Expanded detail for `.claude/rules/trust-dialog-fix.md`. The binding rule and the repair commands are there; this file explains the mechanism.

## Why it happens

Claude Code stores approval state per *project path* in `~/.claude.json`. A path it has not seen before is a new project entry, created with `false` defaults — so the trust dialog and the external-includes approval can both re-prompt.

Worktree trust (verified 2026-11-14 against code.claude.com/docs/en/permissions): the docs say that in a worktree, "it uses the main checkout's root", and that the trust flag belongs on the repository root entry. So a new worktree should not need its own trust approval. That is documentation only; no live fresh-worktree run was made, and the docs say nothing about the two includes flags. `~/.claude.json` still holds one entry per worktree path (927 found, all with all three flags `true` at the time of the check), so per-path flags remain a real surface.

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

It cannot pre-empt a prompt for a path with no entry yet, because no entry exists until Claude Code creates one. Whether a new worktree path prompts at all now depends on the docs point above, which is unverified. If it does, the sequence is: prompt appears → user answers → response completes → hook repairs → no further prompts for that path.

## Decision (issue #2348)

Keep the hook and both repair scripts unchanged. The documented worktree rule covers only the trust flag. The two includes flags are undocumented, and the reference note says their prompts may come from the `~/.claude/` symlink topology rather than from worktree trust, so no script can be removed or shrunk on current evidence. A live fresh-worktree run (open a new worktree in the interactive app, record the dialog, compare flags) is still needed to close this.

## Related

The same symlink topology caused CLAUDE.md + rules double-loading, fixed separately via project-local `claudeMdExcludes` in `.claude/settings.json` — see `.claude/reference/double-loading-fix.md`.
