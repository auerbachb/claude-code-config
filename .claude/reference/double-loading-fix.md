# Double-Loading Fix: CLAUDE.md + rules (issue #461)

Decision record for eliminating the double-injection of this repo's rule corpus
in `claude-code-config` sessions. Not auto-loaded; read on demand.

## Symptom

In sessions opened in this repo, the entire rule corpus (`CLAUDE.md` + all
`.claude/rules/*.md`) was injected into context **twice** — once under
`~/.claude/skills-worktree/...` paths and once under the project paths.

At ~10,981 words ≈ ~15K tokens per copy, that is ~30K tokens of rules per
session in this repo — more context than every historical word-cut combined ever
recovered (the #443/#239 budget effort fought over ~2-3K words).

## Mechanism (confirmed)

Claude Code builds session memory by concatenating **every** discovered
`CLAUDE.md` plus every `.claude/rules/*.md` it finds, across settings scopes
(user, project, local, managed). See the official docs:
[memory](https://code.claude.com/docs/en/memory) and
[large codebases](https://code.claude.com/docs/en/large-codebases).

This repo (`claude-code-config`) is the source of truth for global config. Its
`setup.sh` / `setup-skills-worktree.sh` create **symlinks** in `~/.claude/` that
point into a dedicated git worktree pinned to `main`:

- `~/.claude/CLAUDE.md`  → `~/.claude/skills-worktree/CLAUDE.md`
- `~/.claude/rules`      → `~/.claude/skills-worktree/.claude/rules`

So when a session opens **inside this repo**, Claude Code discovers two distinct
absolute paths carrying identical content:

1. **User scope (global):** `~/.claude/CLAUDE.md` + `~/.claude/rules/*.md`, which
   resolve through the symlinks to `~/.claude/skills-worktree/...` (the paths
   that show up in session context).
2. **Project scope:** the repo's own `CLAUDE.md` + `.claude/rules/*.md` at the
   working tree root.

Every other repo loads the global copy **once** (it has no competing project
copy of these files), so the duplication is unique to `claude-code-config`.

This is the same symlink topology root cause noted in
`.claude/rules/trust-dialog-fix.md` (external-includes detection) and
`.claude/rules/skill-symlinks.md` (worktree topology) — a different symptom of
the same mechanism.

### Why it matters beyond raw tokens

- **Version skew mid-PR.** The global copy tracks `main` (skills-worktree),
  while the project copy reflects the working branch. During any rules-editing
  PR the session receives **two different versions** of the same rule at once.
  Current models (Opus 4.8 / Fable 5) follow instructions literally —
  contradictory duplicates are worse than redundant ones.
- **Doubled cache-write cost.** Every byte changed in a rule invalidates the
  cached prefix for both copies.

## Approaches evaluated

| # | Approach | Token impact | Version-skew impact | Verdict |
|---|----------|--------------|---------------------|---------|
| 1 | **Claude Code mechanism (`claudeMdExcludes`)** — official setting that skips specific `CLAUDE.md`/rules by absolute-path glob | Removes one full copy (~15K tokens/session) in this repo only | Eliminates skew: only the project (branch-accurate) copy loads | **Chosen** |
| 2 | **Thin global core** — shrink global `~/.claude/CLAUDE.md` to a universal core, keep full corpus project-local | Partial; only helps repos that don't need the full corpus | Doesn't fix this repo's duplication; needs an audit of what other repos rely on | Rejected — more work, doesn't solve the in-repo dup |
| 3 | **Thin project side** — rely on the global (main-pinned) copy in-session, drop the project copy | Removes one copy | Loses live testing of feature-branch rule edits (the whole reason edits happen here) | Rejected — kills the dev loop |
| 4 | **Accept + document** | None | None | Rejected — ~30K tokens/session is the largest avoidable cost in the corpus |

## Chosen solution: `claudeMdExcludes` (approach 1)

`claudeMdExcludes` is the official, supported mechanism. It is purely subtractive
and skips matching `CLAUDE.md` **and** `.claude/rules/**` files at launch-time
discovery (per the large-codebases docs: `"**/packages/web/**"` "excludes
everything under the web package, including rules"). Patterns are matched against
**absolute file paths**; relative-style patterns start with `**/` for
portability across machines.

Committed at **project scope** so it applies to everyone working in this repo,
in `.claude/settings.json`:

```json
{
  "claudeMdExcludes": [
    "**/skills-worktree/CLAUDE.md",
    "**/skills-worktree/.claude/rules/**"
  ]
}
```

These patterns match the resolved symlink targets (the
`~/.claude/skills-worktree/...` paths observed in session context), suppressing
the **global** copy while leaving the **project** copy as the single
authoritative source.

### Why this is the right scope

- **Other repos unaffected.** The exclusion lives in *this* repo's project
  settings; it loads only for sessions started here. Elsewhere, the global copy
  still loads normally as the single source.
- **Feature-branch edits stay live.** The project copy is what survives, so rule
  edits on a working branch are reflected in-session immediately — preserving the
  ability to dogfood rule changes before merge.
- **Skew eliminated.** With the main-pinned global copy suppressed in this repo,
  only one (branch-accurate) version is in context.

### Caveats

- **Managed-policy CLAUDE.md cannot be excluded.** Not applicable here — this
  repo uses user/project scopes, not managed policy.
- **Trust gate.** Project-scope settings that affect memory may be honored only
  after the workspace trust dialog is accepted (the same gate as hooks). This
  repo already handles trust flags automatically (see `trust-dialog-fix.md`), so
  worktrees pick this up after the first response. A brand-new, never-trusted
  worktree could still double-load on its very first turn until trust is
  repaired — a transient, self-healing edge case.
- **Pattern drift.** If the skills-worktree location ever changes, update the
  globs to match the new resolved path.

## Verification

In a fresh session opened in this repo, confirm only the **project** copy is in
context (paths under the repo root, not under `~/.claude/skills-worktree/`):

```bash
# Resolved symlink targets that should now be excluded:
readlink -f ~/.claude/CLAUDE.md          # → .../skills-worktree/CLAUDE.md
readlink -f ~/.claude/rules              # → .../skills-worktree/.claude/rules

# The project settings carrying the exclusion:
cat .claude/settings.json
```

The skills-worktree paths must NOT appear among the loaded memory files; the
repo-root `CLAUDE.md` and `.claude/rules/*.md` must appear exactly once.

## References

- Issue #461
- `.claude/rules/skill-symlinks.md` — symlink/worktree topology (root cause)
- `.claude/rules/trust-dialog-fix.md` — sibling symptom of the same topology
- Claude Code docs: memory, large-codebases, settings (`claudeMdExcludes`)
