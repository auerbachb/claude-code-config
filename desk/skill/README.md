# desk/skill/

The `/desk` skill (issue #1779 onward). `.claude/skills/desk` is a symlink to
this folder, so the skill publishes through the skills worktree like every
other skill (`~/.claude/skills/desk` → the worktree's `.claude/skills/desk` →
here).

| File | What it is |
|------|------------|
| `SKILL.md` | The router: starting the desk, its Monitor, Monitor events, and the end-of-turn gate |
| `decisions.md` | Simple Decisions: sets, menus, replies, answers, wake-ups (#1779) |
| `longform.md` | Long-form and multipart Decisions: one text prompt at a time, answers stored word for word (#1780) |
| `discuss.md` | `discuss <n\|D-id>`: one item talked through with its context loaded, then presented again (#1780) |
| `interrupts.md` | `desk/policy.json`, the interrupt rule (`away`, `available`, `focus until …`, `focus off`, `interrupts?`), and feedback tags (`2: not important`, …) (#1783) |
| `desk.jq` | jq functions the files above call (`jq -L "$DESK/skill" 'include "desk"; …'`): `desk_split`, `menu_shaped`, `longform_prompt`, `discuss_card` (#1779, #1780); `reviews_view`, `reviews_missing_l1`, `review_header` (#1782); `desk_batch`, `desk_sets`, `desk_feedback` (#1783) |
| `wakeups.md` | Wake-up retries on the next three ticks, then `answer-parked`, shown once (#1781) |
| `history.md` | `show D-<n>` (an item's sub-thread) and `history` (today's answered items), with no state line (#1781) |
| `reviews.md` | The Reviews view: `reviews`, `open R-<n>` (level 2, cached), `diff R-<n> [path]` (level 3, live), `reviewed`, `reviewed all today`, `flag`, `follow up`; its rendering is `reviews_view` and `review_header` in `desk.jq` (#1782) |
| `ideas.md` | `idea:` / `file:` files an issue through `/issue-maker`'s one-shot entry without capture mode; `repo:` sets where ideas go (#1766) |

Later desk issues add a file here and a row to `SKILL.md`'s table rather than
growing one file.

The skill resolves the desk folder from `$HUMAN_QUEUE_DESK_DIR` or
`~/.claude/skills-worktree/desk` only, never from the current checkout: the
desk runs in any directory. To try a branch's desk, set
`HUMAN_QUEUE_DESK_DIR` to that checkout's `desk/` folder.
