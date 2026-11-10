# desk/skill/

The `/desk` skill (issue #1779 onward). [The router](SKILL.md) lists the files
it loads for decisions, reviews, and other desk work. Add new components to
that table when wiring them into the router.

`.claude/skills/desk` is a symlink to this folder, so the skill publishes
through the skills worktree: `~/.claude/skills/desk` → the worktree's
`.claude/skills/desk` → here.

The skill resolves the desk folder from `$HUMAN_QUEUE_DESK_DIR` or
`~/.claude/skills-worktree/desk` only, never from the current checkout: the
desk runs in any directory. To try a branch's desk, set
`HUMAN_QUEUE_DESK_DIR` to that checkout's `desk/` folder.
