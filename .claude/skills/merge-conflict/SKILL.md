---
name: merge-conflict
description: Classify merge/rebase conflicts against main, auto-resolve safe (simple) hunks and stage clean files, and report complex hunks for human judgment. Does not commit.
---

Resolve **local** merge conflicts while reconciling with **latest `origin/main`**. Safe to run **mid-merge** (`git merge` in progress) or **mid-rebase** (`git rebase` stopped on a conflict): the script only reads unmerged paths and the working tree.

## When to use

- After `git merge origin/main` or `git rebase origin/main` stops on conflicts.
- From **`/fixpr`** when `mergeStateStatus` / `mergeable` indicates conflicts — run this skill **before** hand-editing every file (see cross-link in `.claude/skills/fixpr/SKILL.md` Step 6).

## Hard rules

1. **`git fetch origin main` first** — always refresh main before inspecting conflicts (the helper does this unless `--skip-fetch`).
2. **Do not `git commit`** — only **`git add`** paths that are fully marker-free after simple resolution. The caller continues merge/rebase or commits separately.
3. **When in doubt, complex** — the resolver is intentionally conservative; anything ambiguous stays in the file with conflict markers and appears in the report.

## Mechanical step (script)

Locate and run the resolver (skills worktree, home copy, or in-repo):

```bash
SCRIPT=""
for candidate in \
  "$HOME/.claude/skills-worktree/.claude/skills/merge-conflict/resolve_merge_conflicts.py" \
  ".claude/skills/merge-conflict/resolve_merge_conflicts.py"; do
  if [[ -f "$candidate" ]]; then
    SCRIPT="$candidate"
    break
  fi
done
if [[ -z "$SCRIPT" ]]; then
  echo "ERROR: resolve_merge_conflicts.py not found" >&2
  exit 1
fi

python3 "$SCRIPT" --repo "$(git rev-parse --show-toplevel)"
EXIT=$?
# Optional: machine-readable summary for automation
# python3 "$SCRIPT" --repo "$(git rev-parse --show-toplevel)" --json
```

- Exit **0** — no complex hunks reported **and** every unmerged path became fully resolved and staged (rare on first pass if conflicts were only simple).
- Exit **1** — complex hunks, parse/binary skips, or partial resolution; read stdout/stderr and the optional `--json` payload.
- Exit **2** — not a git repository.

## What the script does

1. `git fetch origin main` (unless `--skip-fetch`).
2. Lists conflicted files: `git diff --name-only --diff-filter=U`.
3. For each **text** file, parses `<<<<<<<` / `=======` / `>>>>>>>` hunks and classifies each hunk (see Simple / Complex below).

**Unmerged but no markers:** Some conflicts (e.g. modify/delete) leave the path unmerged without injecting `<<<<<<<` lines. Those paths are listed in **`complex_report`** with an explicit reason so they are not silent skips.

**Encoding:** Files are read with UTF-8 + `surrogateescape` so non-UTF-8 bytes do not crash parsing; writes use the same so simple resolutions do not raise `UnicodeEncodeError`.

### Simple (auto-resolved)

Applied in the working tree and, if **all** hunks in that file are simple, the file is **`git add`**’d:

- Whole hunk identical after trimming trailing whitespace on each line (`_rstrip_lines`).
- Same number of non-blank lines in order with only **per-line trailing** whitespace differences.
- Identical non-blank line sequences (`o_nb == t_nb`) after the stricter checks above.
- **One-sided empty** + other side is **only** import lines matching conservative `import` / `from … import` (Python) or `import … from '…'` (JS/TS) heuristics.
- Both sides empty.

### Complex (report only — markers preserved)

- Any differing **non-blank** semantics (different line counts or content where rules above do not apply).
- **Incoming empty, current non-empty** (deletion vs keep — risky).
- **Nested conflict markers** inside a hunk body.
- **Binary** files (detected via NUL in early bytes).
- Non-regular paths (missing file, submodule quirks) — reported, not edited.

For **mixed** files (some simple, some complex): simple hunks are written into the working tree; **complex hunks stay**. Those files are **not** staged (Git still sees conflicts until you finish the rest manually).

## AI layer after the script

1. Print the **human summary** from the script (or pretty-print `--json`).
2. For each **complex** entry: confirm **file path**, **line range / labels**, and **why** (use the script’s `reason` verbatim; add context only if you open the file and can cite the two sides briefly).
3. **Do not edit** complex hunks in this pass unless the user explicitly asks for a proposal-only suggestion — the skill’s contract is report-first.
4. Tell the user the exact **next git commands** based on state:
   - Mid-merge: `git status` → if all conflicts cleared, `git commit` (merge) or continue as their workflow dictates.
   - Mid-rebase: fix remaining files → `git add` each → `git rebase --continue`.

## Global symlink (after the skill is on `main`)

See `.claude/rules/skill-symlinks.md` or run `setup-skills-worktree.sh` from the repo root — it symlinks all skills automatically.

## Smoke test (for PR / manual verification)

In a throwaway branch:

```bash
git fetch origin main
git checkout -B mc-smoke-test "origin/main"
echo base > /tmp/mc-a.txt && cp /tmp/mc-a.txt conflict-demo.txt && git add conflict-demo.txt && git commit -m "base"
git checkout -B mc-smoke-side HEAD~0 2>/dev/null || true
# create parallel commits that conflict trivially (whitespace) then merge --no-commit
# … or paste conflict markers and `git add` then mark unmerged via merge state
```

Minimal local simulation: create `demo.txt` with a single **simple** conflict (identical text with trailing space on one side), run `git add -N` / merge plumbing is heavy — easier: use two branches and `git merge --no-ff` with edits. **Practical smoke:** run `python3 .claude/skills/merge-conflict/resolve_merge_conflicts.py --skip-fetch --json` in a repo with `git diff --name-only --diff-filter=U` non-empty after a deliberate conflict; confirm `staged` lists files with only simple hunks.
