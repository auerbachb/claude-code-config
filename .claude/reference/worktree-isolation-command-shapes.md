# Worktree-Isolation Command Shapes

Canonical catalog of the Bash command shapes the harness's **worktree-isolation guard** refuses for a worktree-isolated agent, and the non-refused equivalent for each. Referenced by `wrap/SKILL.md` Step 2.5, `fixpr/SKILL.md` Step 4d, and `reference/dirty-main-guard.md`; opened on demand, never auto-loaded (issue #1470).

## The refusal

A worktree-isolated agent — every Phase A/B/C subagent on the normal pipeline — that submits a command the guard cannot verify gets this back, verbatim:

> This agent is isolated in the worktree `<path>`, but this command is too complex to verify that it stays inside the worktree. Refusing to run it — a worktree-isolated agent's git operations must target its own worktree.

**The message names git operations that are frequently not there.** Two of the three shapes catalogued below contain no `git` at all. Do not go hunting for the git call: the guard classifies by command **shape**, not by content, and the sentence about git operations is the guard's stated *rationale*, not a description of what it found in your command. If you are reading this because a refusal named a git operation you cannot find, that is the expected experience and not a sign that you misread your own command.

**The guard is external to this repository.** It is part of the Claude Code harness. The only in-repo worktree guard is `.claude/hooks/worktree-guard.sh`, which inspects `Write`/`Edit`/`NotebookEdit` **file targets** and never reads a Bash command string — so no change in this repo can loosen the classifier or correct its wording. What this repo owns is the other half: making sure every recurring refused shape has an equivalent that *is* allowed.

## Refused shapes (measured, issue #1470)

All three were observed live in a single Phase C run on PR #1466.

| # | Shape | Example |
|---|-------|---------|
| 1 | Two `;`-separated commands, **even when both pin `-C <the agent's own worktree>`** | `git -C <wt> rev-parse HEAD; git -C <wt> branch --show-current` |
| 2 | A raw `until … do sleep … done` loop, **even with no git in it** | `until [ "$(gh run view <id> --json status --jq .status)" = "completed" ]; do sleep 10; done; gh run view <id> --json status,conclusion` |
| 3 | `cd <dir> && … \| …` — a `cd` plus a pipe, **even when `<dir>` is the session scratchpad and there is no git** | `cd <scratchpad> && bash …/admin-merge.sh … \| head -5; echo "RC=${PIPESTATUS[0]}"` |

Shape 1 is the sharpest inversion of intent: `git -C <own worktree>` is *more* verifiable than a bare `git`, and refusing it pushes agents toward the less explicit form. Shape 2 is a guard-vs-guard contradiction — the `sleep` blocker's own remediation text recommends the `until <check>; do sleep <n>; done` shape verbatim, and this guard refuses it.

## The allowed shape

**One plain call to one script or binary, with every path passed as a flag.** A script's own `cd`, `git -C`, pipes, and loops all run in child processes the guard does not gate, so all the complexity is legal once it lives one level down.

Two corollaries:

- **Never wrap a helper in a `cd`.** Pass the target path instead: `dirty-main-guard.sh --repo`, `main-sync.sh --repo`, `polling-state-gate.sh --root-repo`, `admin-merge.sh --repo-path`, `worktree-status.sh --repo`. Every one of those flags exists for this reason.
- **A genuinely multi-line block is run as a file, not as a paste.** Write it to the session scratchpad and invoke `bash <file>` — a single command. This is the general escape for anything the table below does not already cover, including the stateful wait loop in `fixpr/SKILL.md` Step 4d.
  - **A file is a child process, so state does not cross in either direction.** Plain shell variables set in earlier steps arrive empty, and assignments the file makes never reach the caller. Write the values the block needs into the top of the file (or pass them as `NAME=value bash <file>`), and hand results back on stdout for the caller to capture — never by assignment. A block that silently reads empty inputs still runs, and reports a verdict it never measured.

## Case-by-case map

| Refused | Run this instead |
|---------|------------------|
| `git -C <wt> rev-parse HEAD; git -C <wt> branch --show-current` | `.claude/scripts/worktree-status.sh --repo <wt>` — prints `HEAD=`, `BRANCH=`, `DETACHED=`, `ROOT=` for that worktree (`--json` for an object). Read one field with `sed -n 's/^HEAD=//p'`. |
| `until [ "$(gh run view <id> … )" = "completed" ]; do sleep 10; done` | `gh run watch <id> --exit-status` — **preferred** for a CI run; it is already one command. For any other condition: `.claude/scripts/wait-until.sh --interval 10 --timeout 900 --expect completed -- gh run view <id> --json status --jq .status`. |
| `cd <dir> && bash …/admin-merge.sh … \| head -5` | `.claude/scripts/admin-merge.sh --repo-path <dir> …` — it enters the path itself. No repo call site wraps it in a `cd`; do not add one. |
| `(cd "$ROOT_REPO" && dirty-main-guard.sh --check)` | `.claude/scripts/dirty-main-guard.sh --check --repo "$ROOT_REPO"` (issue #1411). |
| Any other multi-command block | Write it to the scratchpad, then `bash <file>`. |

## Boundaries

- `wait-until.sh` blocks the **calling turn**, capped by `--timeout`. It is not a scheduler. Recurring or between-turn polling stays with a persistent `Monitor` — `.claude/rules/scheduling-reliability.md` is unchanged by this doc, and raising `--timeout` is never the fix for a poll that belongs to a Monitor.
- `worktree-status.sh` answers for the worktree you point it at. `repo-root.sh` answers for the **main** worktree root. They are not interchangeable: an isolated agent asking about "my HEAD" wants the former, and the latter would return a plausible-looking wrong answer.
- Adding a `--repo`-style flag is only worthwhile for a script that actually runs a local git command or a `cd`. `ci-status.sh` and `pr-state.sh` are `gh`-driven and keyed by PR number or SHA, so such a flag would be inert there.

## Why this file exists rather than more prose per call site

Issue #1411 fixed one instance by adding `--repo` flags so `/wrap` Step 2.5 stopped needing a `cd`, and left a paragraph in `wrap/SKILL.md` warning future editors not to reintroduce it. That does not scale: each new call site would grow its own paragraph, and the underlying classifier is not ours to fix. The convention lives here once; call sites link to it.
