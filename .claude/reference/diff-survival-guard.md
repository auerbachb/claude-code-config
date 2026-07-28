# Diff-Survival Guard (issue #757)

Mechanism and rationale behind `.claude/scripts/diff-survival-check.sh`. Not auto-loaded — the enforceable rules live at the call sites (`/fixpr` Step 6a, `/merge-conflict` hard rule 2 + AI-layer step 4, `/go-on` Step 1).

## The hole it closes

Git accepts **any** conflict resolution that contains no markers — including one that simply kept the other side. The motivating incident: an interrupted rebase left a file with zero conflict markers that was byte-identical to `main`; the entire fix the PR existed to deliver had been silently dropped. Every existing gate passed it — clean `git status`, no markers, green CI, a review of a PR that no longer contained its own change. It was caught only because a fresh session happened to diff the tree against main before continuing.

The exposure grows as resolution gets more automated: `/babysit-pr --auto-resolve-conflicts` (#683) rebases and force-pushes unattended, so nobody is watching those at all.

## Contract

```
diff-survival-check.sh snapshot [--base <ref>] [--head <ref>] [--if-absent] [--json]
diff-survival-check.sh verify   [--base <ref>] [--json]
diff-survival-check.sh status   [--json]
diff-survival-check.sh clear
```

| Exit | Verdict | Meaning |
|------|---------|---------|
| `0` | `intact` / `deferred` | every pre-op substantive file still carries a change; `deferred` = rebase mid-replay |
| `1` | `vanished` | nothing substantive survives against the base |
| `2` | `files_lost` | named files (stdout, one per line) lost their substantive change |
| `3` | — | usage error |
| `4` | — | git/tooling error, snapshot-vs-branch mismatch, unresolved conflicts still present, or `unverifiable` (the baseline commit *is* the commit being verified) |
| `5` | — | `verify` with no snapshot on disk |

Verdicts own `0/1/2` because issue #757 names them; usage/tooling therefore move to `3/4` instead of the repo's more usual "2 = usage". `--help` is the authoritative contract.

## Design decisions

**`git diff -w --name-only` is a trap.** It still lists whitespace-only files — git builds the name list from the tree filepair, not from the whitespace-aware textual diff — so using it would silently void the whitespace-awareness requirement. The script instead probes each changed path with `git diff -w --quiet -- <path>` (exit 0 = whitespace-only, 1 = substantive). A file whose pre-op change was real but whose post-op change survives only as re-indentation is therefore correctly reported **lost**, which is what keeps indent-heavy PRs from false-passing.

**`--no-renames` everywhere.** Both sides of the comparison then represent a rename as delete-old + add-new, so a resolution that legitimately moves a file keeps the old path in the post-op set and is never misreported as a loss. This replaces the more fragile "collect rename sources via `-M`" approach.

**Snapshot home: the worktree's git dir.** `git rev-parse --git-path claude-diff-survival.json` resolves to `.git/claude-diff-survival.json` in the main worktree and `.git/worktrees/<name>/claude-diff-survival.json` in a linked one. That location survives session interruption (the incident scenario), travels with the worktree, is never tracked, is per-worktree rather than shared, and sits deliberately outside the session-state/handoff mechanisms — it is transient and safe to delete at any time. Writes are atomic (`mktemp` + `mv`).

**Baseline resolution is `orig-head`-first mid-rebase.** When a rebase is already in progress, HEAD is the *partially replayed* tree — precisely the poisoned state being tested for. Using it as the baseline would compare the damage against itself. The script reads `rebase-merge/orig-head` (or `rebase-apply/orig-head`) instead, which is what makes `/go-on`'s resume path work on a rebase some earlier session started. Branch identity is likewise recovered from `rebase-merge/head-name`, since mid-rebase HEAD is detached and the snapshot-vs-branch guard would otherwise misfire on every resumed rebase.

**Post-op state selection.** Unmerged paths → exit 4 (nothing to judge yet). Rebase in progress → base is `onto`, diff is the index (`--cached`). Merge in progress → base is `MERGE_HEAD`, diff is the index. Clean tree → base is `merge-base(HEAD, base_ref)`, diff vs `HEAD`.

**A baseline cannot be reconstructed after the fact** (BugBot, PR #763). `snapshot --if-absent` recovers a real pre-operation baseline **only while the operation is still in progress**, where `orig-head` is available. Run on a clean tree after a rebase has already finished, it records the *post-resolution* state as its own baseline — every later comparison is then `X vs X` and returns `intact`, including through the `pre_diff_empty` short-circuit, so a fully vaporized branch would sail through the very guard meant to catch it. `verify` therefore refuses outright when the snapshot's `pre_head` equals the commit being verified: verdict `unverifiable`, exit 4. The message names both readings — a post-hoc snapshot (treat the resolution as unverified and unresolved) and a genuinely no-op operation (nothing changed; `clear` and re-snapshot before the real operation). `snapshot` also warns at capture time when it is writing a pre-operation-only baseline. The resume call sites (`/fixpr` Step 6a exit-5, `/go-on` Step 1) say the same thing: a resolution that finished without a snapshot is **unverifiable**, never clean.

**`deferred` exists to avoid a false-positive machine.** Mid-rebase, files whose changes live in a not-yet-replayed commit are legitimately absent. Rather than weakening the gate, the script detects queued commits (`git-rebase-todo`, or `next`/`last` for the am-based backend) and declines to render a verdict. Call sites run the real gate after `git rebase --continue` completes and *before* the force-push, where nothing is pending.

## False-positive shapes

- **The PR is genuinely empty.** `main` independently gained the identical change, so the rebase drops the commit and the diff is legitimately gone. Exit 1's message names this case explicitly and points at **closing the PR** — force-pushing an empty branch is the wrong repair. The guard still blocks; the human decides.
- **Whitespace-only PRs.** A branch whose pre-op diff was entirely whitespace has no substantive files to lose, so it cannot trip exit 2. A snapshot taken on a branch with no diff at all records `pre_diff_empty` and short-circuits `verify` to `intact` with a note.
- **Stale snapshot** from an abandoned operation: `captured_at` older than 24h sets `stale_snapshot` in the output and adds an advisory line. It never blocks on its own — an old snapshot is still the best evidence of what the branch used to change. `clear` retires it.

## Never repairs

The guard reads and compares only; it never stages, commits, pushes, or edits the working tree. A failing check is an **unresolved conflict**, never a success, and recovery (`git rebase --abort`, resetting to `ORIG_HEAD`, redoing the resolution) stays a deliberate human step. In `/fixpr`'s safe-only mode (`BABYSIT_SAFE_CONFLICT_MODE=1`) a non-zero verify is surfaced upstream exactly like a complex hunk — `CONFLICT_COMPLEX_REPORT_JSON:` plus `FIXPR_WRAP_STATUS: CONFLICTS` — so `/babysit-pr` T4 terminates `hard-blocked` with the lost-file report instead of counting a vaporized push as forward progress.

## Tests

`.claude/scripts/tests/diff-survival-check.test.sh` — fully offline (throwaway repos under `mktemp -d`, `--base` pointed at a local ref, no network and no `gh`), auto-discovered by `.github/scripts/run-hook-tests.sh` (#681). Covers: faithful resolution, a resolution that drops one file, whitespace-only survival, clean no-conflict rebase, absorbed-by-main vanishing, interruption + `orig-head` reconstruction, deferred mid-replay, missing snapshot, branch mismatch, usage errors, and per-worktree snapshot scoping.

## Related

`#683` (automated conflict resolution — this guard covers its output too) · `#756` (same incident; that one reduces how often conflict rounds happen, this one makes the remaining rounds safe).
