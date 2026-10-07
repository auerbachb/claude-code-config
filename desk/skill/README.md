# desk/skill/

The `/desk` skill (issue #1779 onward). `.claude/skills/desk` is a symlink to
this folder, so the skill publishes through the skills worktree like every
other skill (`~/.claude/skills/desk` → the worktree's `.claude/skills/desk` →
here).

| File | What it is |
|------|------------|
| `SKILL.md` | The router: starting the desk, its Monitor, Monitor events, and the end-of-turn gate |
| `decisions.md` | Simple Decisions: sets, menus, replies, answers, wake-ups (#1779) |

Later desk issues add a file here and a row to `SKILL.md`'s table rather than
growing one file: long-form, multipart, and `discuss` (#1780); wake-up
retries, `answer-parked`, `show`, and `history` (#1781).

The skill resolves the desk folder from `$HUMAN_QUEUE_DESK_DIR` or
`~/.claude/skills-worktree/desk` only, never from the current checkout: the
desk runs in any directory. To try a branch's desk, set
`HUMAN_QUEUE_DESK_DIR` to that checkout's `desk/` folder.
