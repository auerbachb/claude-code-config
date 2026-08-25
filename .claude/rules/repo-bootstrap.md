# Repo Bootstrap — Auto-Provision Configuration

> **Always:** Check for required workflows and branch protection at session start. Add missing workflows before any code work. Report missing branch protection to the user.
> **Ask first:** Branch protection changes — always ask the user before modifying repo-level settings.
> **Never:** Skip the checks. Modify workflows that already exist. Change branch protection without user confirmation.

## Session Start: Required Configuration Checks

Run at session start — after worktree creation, before code work. Idempotent; safe to repeat.

### Run the bootstrap check

`.claude/scripts/repo-bootstrap.sh --check` reports workflow + branch-protection state without mutating. Exit `0` clean, `1` gaps. Full contract: `repo-bootstrap.sh --help`.

If it reports any `[MISSING]` files, install them with `.claude/scripts/repo-bootstrap.sh --apply` as part of the first feature PR — do not open a bootstrap-only PR. `--apply` installs only missing files, never overwrites existing ones, and never modifies branch protection. File-set design: `.claude/reference/repo-bootstrap-workflows.md`.

### Branch protection — required status checks

The script reports state as `[OK]` / `[MISSING]` / `[SKIP]` (token lacks read perm) / `[UNKNOWN]` (investigate stderr). Without required status checks on `main`, PRs can merge with red CI. The script never changes branch protection — user confirmation required.

**Remediation:** discover the CI check names, then **ask the user** before touching protection, naming the checks found. If approved, read the existing protection and PUT it back changing only `required_status_checks` — never a blind PUT. If declined, move on and do not ask again in the same session. Discovery sources and the exact payload: `.claude/reference/repo-bootstrap-protection.md`.

### Rules

- **Do not downgrade existing protection.** Preserve required reviews, admin enforcement, etc. when adding status checks.
- **Prefer installed CLI tools** (`vercel`, `neonctl`, `railway`, `cloudinary`) over web dashboards — commands: `.claude/reference/cli-tool-defaults.md`.
