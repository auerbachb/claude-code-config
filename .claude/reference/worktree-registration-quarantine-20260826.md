# Worktree-registration quarantine, 2026-08-26 — disposition

Companion to issue #1402 (`stale-cleanup.sh` prunes orphaned worktree
registrations). Records what the quarantine at
`~/Documents/develop/wt-quarantine-20260826/` actually contains and whether it
can be deleted now that the pruning pass has landed.

**Recommendation only. Nothing here deletes anything, and the disposition below
is deliberately "not yet".**

## What happened

On 2026-08-26 git froze in this repo. `git worktree list --porcelain` read the
`gitdir`/`HEAD` files of 62 stale `.git/worktrees/<id>` registrations, many of
them iCloud-evicted (`dataless`), and those reads never returned. PR #1386
(issue #1363) bounded `repo-root.sh` and removed the enumeration from its happy
path, converting the freeze into a bounded failure. Issue #1402 — this change —
removes the debris that caused it.

The immediate mitigation was to **rename the registration directories aside**,
not delete them: `.git/worktrees/<id>` → `wt-quarantine-20260826/<id>`.

## What the quarantine holds (measured 2026-08-27, bounded reads)

| Property | Count |
|---|---|
| Registration directories | 63 |
| Carrying a `locked` marker (written by the agent harness) | 22 |
| `HEAD` readable within a 1 s bound | 44 |
| **`HEAD` still unreadable within a 1 s bound** | **19** |
| Readable ones whose branch still exists in the repo | 32 |
| Readable ones on a detached HEAD | 12 |
| Readable ones whose branch has since been deleted | 0 |
| Total size | 2.1 MB |

Two of those rows drive everything below.

**19 entries are still unreadable a day later.** This is the direct evidence
that `git worktree prune` alone could never have cleaned this up: prune reads
the same `gitdir` files, so it would have hung on exactly these. It is why
`stale-cleanup.sh` carries a targeted-removal path alongside the prune path.
(The first, unbounded version of the probe that produced this table hung on
these files and had to be killed — the failure reproduces on demand.)

**0 entries point at a deleted branch.** Every readable registration names a
branch that still exists in the repo, so no branch-shaped work is reachable
*only* through the quarantine. The 12 detached-HEAD entries are the one
theoretical exception; in an agent worktree a detached HEAD is transient
(mid-rebase, `checkout --detach`), and their objects remain in the shared object
database until a `gc` prunes unreachable ones.

## Why it is not deletable yet

These registrations are not free-standing debris — they are the other half of
**59 orphaned checkouts** still sitting in
`.claude/worktrees/` with no registration behind them (43 `agent-*` directories
matching quarantined ids, plus 16 older named ones that predate the incident).
Each still carries a `.git` file pointing at its quarantined registration:

```console
$ cat .claude/worktrees/agent-a09c43b85b9eabc18/.git
gitdir: …/claude-code-config/.git/worktrees/agent-a09c43b85b9eabc18
```

While the quarantine exists, re-linking one of those checkouts is cheap —
move the registration back, or `git worktree repair <path>`. Delete the
quarantine first and the cheap path is gone: recovering uncommitted work from an
orphaned checkout then means reconstructing it by hand.

**Disposition: keep the quarantine until the orphaned checkouts under
`.claude/worktrees/` are triaged and removed. Delete it in the same pass, not
before.** It costs 2.1 MB, so there is no pressure to act early.

## Scope boundary — what issue #1402 does and does not cover

`stale-cleanup.sh` now prunes **registrations with no worktree** (and
registrations whose metadata cannot be read). The 59 orphaned checkouts are the
**inverse** case — worktrees with no registration — and this change deliberately
does not touch them. They hold real working-tree files and possibly uncommitted
edits, so removing them is a different decision with a different safety
argument. Worth its own issue.

## If you do delete it

Delete the directory itself; do not feed it back to git. Nothing in a
registration directory is a working-tree file, so no source is lost — `index`
costs a staging area, `logs/HEAD` costs a reflog. Expect some entries to be slow
or impossible to `stat` while evicted; a plain recursive remove unlinks without
materialising content and should not stall.
