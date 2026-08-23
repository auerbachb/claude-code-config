---
name: memory-clean
description: Audit the durable memory store (~/.claude/projects/*/memory/) and suggest prunes. Reports orphaned .md files, dangling index pointers, index size vs the context budget, and advisory superseded/duplicate entries — then, only on explicit confirmation, deletes the chosen files, rewrites MEMORY.md, and verifies integrity. Never auto-deletes. Sibling to /pm-clean. Triggers on "memory-clean", "clean memory", "prune memory", "stale memories", "orphaned memory files".
argument-hint: "[--dir PATH] [--budget-kb N] (optional — defaults to the current project's memory store, 24 KB budget)"
---

Audit this project's durable memory store and present prune recommendations. Same discipline as `/pm-clean`: evidence for every recommendation, conservative on "stale," and **nothing is removed without an explicit yes**. All detection and mutation lives in the shared, tested script `.claude/scripts/memory-audit.py` — this file is the recommend-then-confirm layer.

## Step 0: Locate the audit script

Prefer the global install; fall back to the in-repo copy when developing the skill itself.

```bash
SCRIPT=""
for candidate in \
  "$HOME/.claude/skills-worktree/.claude/scripts/memory-audit.py" \
  "$HOME/.claude/scripts/memory-audit.py" \
  ".claude/scripts/memory-audit.py"; do
  if [[ -f "$candidate" ]]; then SCRIPT="$candidate"; break; fi
done
if [[ -z "$SCRIPT" ]]; then
  echo "ERROR: memory-audit.py not found (checked ~/.claude/scripts/, skills-worktree, in-repo)" >&2
  exit 1
fi
```

Parse `$ARGUMENTS`: pass through an explicit `--dir PATH` (for a non-current project or a relocated store) and translate `--budget-kb N` to `--budget-bytes $((N*1024))`. With no arguments the script auto-detects the **current project's** memory dir — the ROOT project, not the worktree, since memory is pinned to the root project across worktree sessions.

## Step 1: Scan (read-only)

```bash
python3 "$SCRIPT" --check --json [--dir PATH] [--budget-bytes N]
```

Exit `0` = scanned (a clean store is a valid result). Exit `3` = memory dir not found — tell the user and offer to re-run with `--dir PATH`. The JSON has `memory_dir`, `index` (`bytes`, `entry_count`, `file_count`, `budget_bytes`, `over_budget`), `orphans`, `dangling`, and `advisory` (`duplicate_names`, `superseded`). Read `memory_dir` back to the user so they know exactly which store is in scope.

## Step 2: Present recommendations

Group findings into scannable sections. Omit any empty section. If nothing is flagged and the index is under budget, report "Memory store is clean — {entry_count} entries, {bytes} bytes, nothing to prune." and stop.

```
## Memory Cleanup Recommendations — {memory_dir}

Index: {entry_count} entries, {bytes} bytes (budget {budget_bytes}).{ over-budget note}

### Dangling index pointers (K) — recommend removing
The index points at files that no longer exist. Safe to drop (they resolve to nothing).

| Index target | Recommendation |
|--------------|----------------|
| gone.md | Drop line — no file on disk |

### Orphaned files (K) — report only, deletion opt-in
On disk but not referenced by MEMORY.md. Some orphans are intentionally unindexed — deletion is your call, never a default.

| File | Size | Note |
|------|------|------|
| foo.md | 1.2 KB | Unindexed — review before deleting |

### Index size
{Only when over budget:} Index is {bytes} > {budget_bytes}. The index loads every session; trimming entries reduces per-session token cost.

### Advisory — superseded / duplicate (needs your judgment)
Low-confidence; never auto-recommended. Each cites the entry it defers to.

| Entry | Signal | Cites |
|-------|--------|-------|
| stale.md | "superseded by" marker | new-thing |
| dupA.md, dupB.md | shared frontmatter name | each other |
```

## Step 3: Confirm — never delete without a yes

After presenting, stop and present the choice via **`AskUserQuestion`** when available (`multiSelect: true`; prose fallback in headless runs). Options map to finding types present in the report. **Always list the `(Recommended)` option first.**

- `"Drop dangling index pointers — safe (Recommended)"` (only when dangling pointers found; skip-wins if selected with others)
- `"Delete orphaned files"` (only when orphans found; user may name specific files via "Other")
- `"Act on advisory items"` (only when advisory findings found)
- `"Skip — leave the store untouched"` (mark `(Recommended)` and list first when only advisory or orphan-only findings remain; skip-wins)

Present only options for finding types that exist in the current report. See `ask-menu.md` for the full vehicle convention.

Prose fallback:
```
To prune, tell me which to remove. I can:
1. Drop all dangling index pointers (safe — they point at nothing)
2. Delete specific orphaned files (list names)
3. Act on a specific advisory item (I'll re-confirm the exact file)
4. Skip — leave the store untouched

Which items should I prune?
```

If the user declines, do nothing — the store stays byte-identical. **Never** infer deletion from silence, and never bundle advisory items into a "delete all."

## Step 4: Apply the confirmed prune

Translate the user's choices into one `--apply` call — orphaned/superseded/duplicate **files** to delete go in `--files`; **dangling** index targets to clear go in `--drop-index`.

```bash
python3 "$SCRIPT" --apply [--dir PATH] \
  --files "orphanA.md,staleB.md" \
  --drop-index "gone.md" --json
```

The script validates every target (bare `.md` basename, direct child of the memory dir, never `MEMORY.md`), deletes files, rewrites `MEMORY.md` atomically, and verifies integrity. Exit `4` = a safety refusal or an integrity failure — surface the message verbatim and do not retry blindly. On success, report the JSON's before/after `entry_count` and `bytes`, the deleted files, and the integrity result (`ok`, any `remaining_dangling`, any `remaining_orphans` kept by choice).

## Rules

- **NEVER delete a memory file or rewrite MEMORY.md without explicit confirmation** — mirrors `/pm-clean`'s "never auto-close."
- **Orphan deletion is opt-in, never a default recommendation.** Report orphans; let the user choose. Some are intentionally unindexed.
- **Be conservative on "stale."** Superseded/duplicate flags are advisory only and must cite the entry they defer to — never auto-recommend them.
- **Include rationale for every recommendation** so the user can judge without opening each file.
- **Honor CLAUDE.md "Memory System":** operate only inside the memory dir, never touch secrets/PII, preserve the one-file-per-fact + index shape.
- **Trust the integrity check.** If `--apply` exits `4`, report it and stop — do not hand-edit MEMORY.md to force a merge.
