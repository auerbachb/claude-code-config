# Missing `--owner-repo` on a handoff write — warn, don't refuse (issue #1302)

Reference material for `.claude/scripts/handoff-state.sh`. Not auto-loaded; the
enforced behavior lives in the script and in
`.claude/scripts/tests/handoff-scoping.test.sh` §12–14.

## The situation

Handoff files are stored per repo (issue #655) so two repos at the same PR
number cannot share one record:

```text
~/.claude/handoffs/{owner}/{repo}/pr-{N}-handoff.json   # scoped   (--owner-repo)
~/.claude/handoffs/pr-{N}-handoff.json                  # flat     (no flag)
```

`--owner-repo` is optional. Omitting it is not an error, does not warn, and does
not fail — the write simply lands on the flat path and exits 0. That silence is
what the issue is about.

The Phase B agent's six `--set`/`--append` calls were missing the flag while
Phase A's `--create` and Phase C's `--path` both had it. So Phase B wrote the
flat file, Phase C read the scoped one, and Phase C saw a record that parsed
cleanly, validated cleanly, and was one entire phase out of date. It happened on
both PRs that reached Phase B in one session on 2026-08-23 (PR #1295 and
PR #1299) — not an occasional slip.

What made it dangerous rather than untidy is *which* fields go stale. On
PR #1295 Phase B had escalated to Greptile and recorded `reviewer: greptile`;
the scoped file still said `reviewer: cr` from Phase A. Phase C reads that field
to pick a merge gate. Uncorrected it would have hunted for a CodeRabbit or
CodeAnt approval on a PR whose gate is severity-based, and called a merge-ready
PR blocked. The stale record also loses `head_sha`, `findings_fixed`,
`threads_resolved`, and `local_review_coverage`.

Both occurrences were caught by hand. Nothing in the pipeline surfaced them.

## The rule

> A **write** mode (`--create`, `--init`, `--set`, `--append`, `--delete`) that
> omits `--owner-repo` **while standing in a checkout that resolves to
> `owner/repo`** prints a one-line warning to stderr naming both the flat path
> being written and the scoped path that would have been used, then **proceeds
> on the flat path and exits 0**.
>
> It warns. It does not refuse.

Three conditions narrow it so the warning stays meaningful:

- **Write modes only.** `--path` and `--get` return before the check. Path
  resolution is used everywhere, including by callers that are deliberately
  probing for the flat file; warning there would be pure noise.
- **Resolvable repo only.** Repo identity comes from `repo_identity "$PWD"` in
  `lib/pr-scope-resolver.sh`, the same helper the polling gate uses. A
  `gitdir:`/`path:` result — no `origin`, or not a git checkout at all — is a
  caller that genuinely has no repo to name, and stays silent. The library is
  treated as optional: a checkout without it keeps the pre-#1302 behavior rather
  than failing a write over a missing warning.
- **`CLAUDE_HANDOFF_FLAT_OK=1` silences it.** For a caller that means the flat
  path on purpose — `/wrap`'s flat-layout stale-handoff sweep, migration
  tooling. Scoped calls must never set it.

## Designs rejected

**Always refuse (exit non-zero) when a repo is resolvable.** Stricter, and
tempting because it makes the bug structurally impossible. Rejected: it breaks
callers the flat path exists for. `polling-state-gate.sh` deliberately refreshes
an already-existing flat handoff rather than moving it mid-poll; `/wrap` deletes
flat files during cleanup; any pre-migration state on disk is still read and
written flat. Every one of those runs from inside a resolvable checkout, so a
resolvability-gated refusal would break all of them. It would also convert a
silent staleness bug into a hard failure of the phase pipeline — a worse trade
than a loud warning, given the merge gate is verified live against GitHub in
every phase regardless.

**Stay silent (status quo).** Rejected: the silence *is* the defect. Two
occurrences in one session went undetected by the pipeline and were caught only
because someone was watching. The soft-warn precedent already exists in this
same script — §5 of `handoff-scoping.test.sh` pins the read-time `owner_repo`
mismatch warning, which likewise warns and returns the content rather than
failing. This is the write-time counterpart of that rule.

**A shared phase-order helper script.** Considered for the companion staleness
check (a phase reading a record older than the phase that should have written
it). Rejected in favor of inline instructions in the Phase B and Phase C agent
files: the pipeline's phase logic already lives as prompt instructions there, the
rank definition (`A=1, B=2, C=3`) is three lines, and a new script would be a
fourth place to keep in sync.

## Why this does not weaken the scoping guarantees

The scoping guarantee from #655 is that two repos at the same PR number never
share a file, and #704 added that a mixed-case slug never forks a second
directory. Neither depends on `--owner-repo` being mandatory — both are
properties of the path `--owner-repo` produces. This change adds a signal on the
path where no slug was supplied at all; it does not alter path construction,
locking, dedup, or the read-time mismatch assertion.

The warning is also not the primary defense. Every repo-aware caller now passes
`--owner-repo` (Phase A `--create`, Phase B's six writes, the `/subagent`
spawn templates, `dismiss-stale-bot-changes.sh` via `/fixpr`), and the phase-order
check in Phase B and Phase C catches a stale read from the other direction. The
warning exists for the *next* writer that forgets — including one added later,
by someone who never read this file.

## Is the migration finished?

Not declared finished. The flat path stays supported, and
`handoff-migrate.sh` remains the tool for moving stray flat files into the
scoped layout. What changed is that landing on it is no longer silent when the
caller could have named a repo. Retiring the flat path entirely is a separate
decision that needs the flat readers (`polling-state-gate.sh`'s fallback notice,
`/wrap`'s two-layout sweep, `phase-c-merger.md`'s migration-window fallback)
retired first.

## Scope

Applies to `handoff-state.sh` only. `session-state.json` scoping is governed
separately by `session-state.sh` (`--repo` / `$CLAUDE_SESSION_REPO` / cwd origin,
with an `_unknown` lane and `session-state-audit.sh --reattribute` for repair);
nothing here changes it.
