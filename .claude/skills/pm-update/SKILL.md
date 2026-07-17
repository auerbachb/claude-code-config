---
name: pm-update
description: Re-scan the current repo and update `.claude/pm-config.md` with fresh infrastructure and architecture detection while preserving user-edited sections (Role, OKRs, Team, Notes, Dependency Rules, Workflow Rules), then run a stale-cleanup pass to prune long-abandoned worktrees and branches. Use this after major milestones, new service integrations, or significant directory restructuring. Triggers on "pm update", "update pm config", "refresh pm config", "rescan repo".
---

Re-scan the current repo and update `.claude/pm-config.md`, then sweep stale worktrees and branches. Auto-generated config sections (Infrastructure, Architecture) are regenerated from the repo's current state; user-edited sections are preserved verbatim. After the config write, the stale-cleanup pass surfaces (and optionally removes) worktrees and branches that have aged past the threshold.

## Section classification

| Section | Type | Behavior on update |
|---------|------|--------------------|
| Role | User-edited | Preserved verbatim |
| OKRs | User-edited | Preserved verbatim |
| Workflow Rules | User-edited | Preserved verbatim |
| Dependency Rules | User-edited | Preserved verbatim |
| Team | User-edited | Preserved verbatim |
| Notes | User-edited | Preserved verbatim |
| Infrastructure | Auto-generated | Regenerated from repo scan |
| Architecture | Auto-generated | Regenerated from repo scan |
| Any other section name | Non-canonical | Preserved verbatim, repositioned next to its nearest canonical neighbor (see Step 6) |

## Step 1: Verify config exists

```bash
test -f .claude/pm-config.md || echo "NO_CONFIG"
```

If `.claude/pm-config.md` does not exist, tell the user: "No PM config found. Run `/pm` first to bootstrap it." Then stop.

## Step 2: Parse existing config into sections

Enumerate section names via the shared parser, then extract each body by name:

```bash
# List every `^## ` header in the config, in original file order.
mapfile -t SECTIONS < <(.claude/scripts/pm-config-get.sh --list 2>/dev/null)

# For each section, fetch the verbatim body.
for name in "${SECTIONS[@]}"; do
  body="$(.claude/scripts/pm-config-get.sh --section "$name" 2>/dev/null)"
  # store (name, body) — reuse body in Steps 3-7
done
```

`pm-config-get.sh` handles line-anchored `^## ` matching (no mid-line matches), preserves body content verbatim, and stops at the next `^## ` or EOF. Preserve the file's title line (`# PM Config — ...`) separately — it sits above all `## ` sections.

**Classify each section and record non-canonical anchors.** Compare every name in `SECTIONS` against the canonical list (Role, OKRs, Workflow Rules, Infrastructure, Architecture, Dependency Rules, Team, Notes — the fixed schema in Step 6):

- **Canonical** — one of the eight names above. Handled by Step 3 (preserved) or Steps 4-5 (regenerated).
- **Non-canonical** — any other name (e.g. `Complexity triggers`). Store its body verbatim, and record its **anchor**: the nearest canonical section name that precedes it in `SECTIONS`' original order. If no canonical section precedes it (it appears before the first canonical section in the file), anchor it to `TOP` (immediately below the title line, before Role).

Non-canonical sections are never dropped — Step 6 re-inserts each one immediately after its recorded anchor. Sections sharing the same anchor keep their original relative order. Order is **not** guaranteed across different anchors: Step 6 emits canonical sections in the fixed schema order regardless of how they appeared in the original file, so two non-canonical sections anchored to canonical sections that were themselves out of fixed order will follow their anchors' fixed-schema order, not their original file order.

## Step 3: Preserve user-edited sections

Store the content of these sections verbatim — do not modify them:
- Role
- OKRs
- Workflow Rules
- Dependency Rules
- Team
- Notes

**Non-canonical sections are preserved the same way.** Any section name not in the canonical list above (see Step 6) is treated exactly like a user-edited section: store its body content unmodified and never rewrite it. Do not ask the user to re-add it — Step 6 automatically re-inserts it at the anchor recorded in Step 2. (`pm-config-get.sh` trims trailing whitespace from every extracted body per its documented contract — this applies uniformly to canonical and non-canonical sections and isn't specific to this preservation rule.)

## Step 4: Re-scan infrastructure

Run the same infrastructure detection as `/pm` bootstrap:

| Signal file | Service |
|-------------|---------|
| `railway.toml` or `railway.json` | Railway |
| `vercel.json` or `.vercel/` | Vercel |
| `fly.toml` | Fly.io |
| `render.yaml` | Render |
| `docker-compose.yml` or `Dockerfile` | Docker |
| `supabase/` or `supabase.json` | Supabase |
| `.neon` or references to `neon.tech` in config | Neon DB |
| `netlify.toml` | Netlify |
| `package.json` | Node.js (extract key deps) |
| `requirements.txt` or `pyproject.toml` or `Pipfile` | Python (extract key deps) |
| `.env.example` | Environment variables (list key names, not values) |

Generate a new Infrastructure section from the scan results.

## Step 5: Re-scan architecture

Scan the directory structure (depth 2) and detect:
- Entry points, standard directories, database patterns, test patterns, CI workflows, config files

Same detection logic as `/pm` bootstrap Step 2c. Generate a new Architecture section.

## Step 5.5: Display diff for review

Before writing, show the user what will change:

1. Compare the current Infrastructure section against the newly scanned version
2. Compare the current Architecture section against the newly scanned version
3. Display changes in a clear format:
   ```
   ### Infrastructure changes
   - Added: Fly.io (detected fly.toml)
   - Removed: Heroku (heroku.yml no longer present)
   - Unchanged: Railway, Vercel, Docker

   ### Architecture changes
   - Added: api/ directory (new)
   - Updated: CI workflows (added deploy.yml)
   ```
4. If no changes detected in either section: skip to Step 7 with message "Infrastructure and Architecture are unchanged — config is up to date." Do not write the file.
5. If changes exist, ask the user: "Apply these updates to `.claude/pm-config.md`?" Wait for confirmation before proceeding.
6. If the user declines, stop without writing. Report: "Update cancelled — no changes written."
7. If the user confirms, proceed to Step 6 to apply them.

## Step 6: Reassemble and write config

Reconstruct `.claude/pm-config.md` using the fixed schema order below for the eight canonical sections (regardless of the order they appeared in the existing file):

1. Title line (preserved from original)
2. Role (preserved)
3. OKRs (preserved)
4. Workflow Rules (preserved)
5. Infrastructure (regenerated)
6. Architecture (regenerated)
7. Dependency Rules (preserved)
8. Team (preserved)
9. Notes (preserved)

Infrastructure and Architecture are always written — Steps 4-5 regenerate them unconditionally, regardless of whether they existed in the original file. For the six *preserved* canonical sections (Role, OKRs, Workflow Rules, Dependency Rules, Team, Notes), skip any that wasn't present in the original file — do not fabricate an empty one.

**Re-insert each non-canonical section at its recorded anchor** (from Step 2):
- A section anchored to `TOP` goes immediately after the title line, before Role.
- A section anchored to a canonical name goes immediately after that canonical section's body in the output — ahead of whatever canonical section is next in the fixed-order list, even if that next section is absent from the file entirely (e.g. `Workflow Rules` not existing doesn't push the anchored section past `Infrastructure`).
- Sections sharing the same anchor keep their original relative order (Step 2).
- An anchor can only ever be a canonical section that itself appeared in `SECTIONS`, so the "anchor absent from output" case should not occur; if it somehow does, fall back to `TOP`.

*Worked example — this repo's own `pm-config.md`:* the original order is Role, OKRs, **Complexity triggers**, Infrastructure, Architecture, Team, Notes. `Complexity triggers` is non-canonical and anchored to OKRs (its nearest preceding canonical section). `Workflow Rules` and `Dependency Rules` are both absent and skipped. Reassembly emits Role, OKRs, **Complexity triggers**, Infrastructure, Architecture, Team, Notes, in the same content and order as the original — `Complexity triggers` stays pinned immediately after OKRs regardless of which canonical sections around it are present. (Verified reproducing this repo's actual `pm-config.md` byte-for-byte, since it already uses the file's standard single-blank-line spacing between sections — see the PR's test plan.)

Write back to `.claude/pm-config.md`.

## Step 7: Report config changes

Output a summary showing what changed in the config:

```
## PM Config Updated

**Preserved (unchanged):**
- Role, OKRs, Workflow Rules, Dependency Rules, Team, Notes
- Non-canonical sections (if any), kept verbatim and reinserted at their recorded anchor — e.g. "Complexity triggers"

**Regenerated:**
- Infrastructure: {brief diff — e.g., "added Fly.io, removed Heroku"}
- Architecture: {brief diff — e.g., "detected new api/ directory"}
```

If nothing changed in the auto-generated sections, say so: "Infrastructure and Architecture are unchanged — config is up to date." Either way, proceed to Step 8 — config staleness and worktree/branch staleness are independent.

## Step 8: Stale worktree + branch cleanup

`/wrap` no longer self-removes the running worktree or deletes its branch (issue #338). Stale cleanup is `/pm-update`'s job — invoke `.claude/scripts/stale-cleanup.sh` to detect and (after user confirmation) prune long-abandoned refs.

### Step 8.1: Run the dry-run pass

Always run `--check` first. The script never deletes in this mode.

```bash
.claude/scripts/stale-cleanup.sh --check
RC=$?
```

`stale-cleanup.sh` reports three categories — stale worktrees, stale local branches, stale remote branches — plus a "Skipped (safety)" list with the reason each item was protected (main worktree, caller's current worktree, uncommitted changes, open PR, protected branch name, branch checked out in a worktree). See `.claude/scripts/stale-cleanup.sh --help` for the full safety-check contract.

Threshold defaults to 7 days; override with `STALE_DAYS=N` if the user requests a different cutoff.

### Step 8.2: Show the report and ask before deleting

Show the user the stdout from Step 8.1 verbatim. Then:

- **If `RC == 0`:** No stale items — say "No stale worktrees or branches detected." Done.
- **If `RC == 1`:** Stale items exist. Ask the user: "Apply the stale cleanup above? (worktrees removed, local + remote branches deleted)" Wait for confirmation. Never run `--apply` autonomously — every deletion is destructive and the dry-run is the user's only chance to spot a false positive.
- **If `RC == 3`:** Usage error (invalid flag, bad `STALE_DAYS`). Print the script's `--help` output and stop — this indicates a bug in this skill's invocation, not a real-state problem.
- **If `RC == 4`:** Environment error (no `gh`, no `jq`, can't resolve repo). Surface stderr to the user and stop.
- **Other non-zero exits:** Surface stderr and stop.

### Step 8.3: Apply (only on user confirmation)

If the user approves, run `--apply`:

```bash
.claude/scripts/stale-cleanup.sh --apply
APPLY_RC=$?
```

The script re-runs the same detection (in case the repo state changed between Steps 8.1 and 8.3), re-emits the report, and then attempts each deletion. Each successful deletion logs `removed: <thing>`; each failure logs `failed: <thing> — <reason>` and continues.

- **`APPLY_RC == 0`:** All deletions succeeded.
- **`APPLY_RC == 2`:** One or more deletions failed — surface the `failed:` lines from stdout. Do not retry automatically; some failures (e.g., network errors on remote-branch deletion) need user intervention.

### Step 8.4: Final report

Append a cleanup summary to the Step 7 report:

```
**Stale cleanup:**
- {N} worktrees removed
- {M} local branches deleted
- {K} remote branches deleted
- {F} failures (see log)
```

If the user declined `--apply`, report: "Stale cleanup: dry-run only — no changes applied."
