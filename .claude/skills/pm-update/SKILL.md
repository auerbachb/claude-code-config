---
name: pm-update
description: Re-scan the current repo and update `.claude/pm-config.md` with fresh infrastructure and architecture detection while preserving user-edited sections (Role, OKRs, Team, Notes, Dependency Rules, Workflow Rules). Use this after major milestones, new service integrations, or significant directory restructuring. Triggers on "pm update", "update pm config", "refresh pm config", "rescan repo".
---

Re-scan the current repo and update `.claude/pm-config.md`. Auto-generated sections (Infrastructure, Architecture) are regenerated from the repo's current state. User-edited sections are preserved verbatim.

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

## Step 1: Verify config exists

```bash
test -f .claude/pm-config.md || echo "NO_CONFIG"
```

If `.claude/pm-config.md` does not exist, tell the user: "No PM config found. Run `/pm` first to bootstrap it." Then stop.

## Step 2: Parse existing config into sections

Enumerate section names via the shared parser, then extract each body by name:

```bash
# List every `^## ` header in the config (one name per line).
mapfile -t SECTIONS < <(.claude/scripts/pm-config-get.sh --list 2>/dev/null)

# For each section, fetch the verbatim body.
for name in "${SECTIONS[@]}"; do
  body="$(.claude/scripts/pm-config-get.sh --section "$name" 2>/dev/null)"
  # store (name, body) — reuse body in Steps 3-7
done
```

`pm-config-get.sh` handles line-anchored `^## ` matching (no mid-line matches), preserves body content verbatim, and stops at the next `^## ` or EOF. Preserve the file's title line (`# PM Config — ...`) separately — it sits above all `## ` sections.

## Step 3: Preserve user-edited sections

Store the content of these sections verbatim — do not modify them:
- Role
- OKRs
- Workflow Rules
- Dependency Rules
- Team
- Notes

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

Reconstruct `.claude/pm-config.md` using the fixed schema order below (regardless of the order in the existing file):

1. Title line (preserved from original)
2. Role (preserved)
3. OKRs (preserved)
4. Workflow Rules (preserved)
5. Infrastructure (regenerated)
6. Architecture (regenerated)
7. Dependency Rules (preserved)
8. Team (preserved)
9. Notes (preserved)

Write back to `.claude/pm-config.md`.

## Step 7: Report changes

Output a summary showing what changed:

```
## PM Config Updated

**Preserved (unchanged):**
- Role, OKRs, Workflow Rules, Dependency Rules, Team, Notes

**Regenerated:**
- Infrastructure: {brief diff — e.g., "added Fly.io, removed Heroku"}
- Architecture: {brief diff — e.g., "detected new api/ directory"}
```

If nothing changed in the auto-generated sections, say so: "Infrastructure and Architecture are unchanged — config is up to date."
