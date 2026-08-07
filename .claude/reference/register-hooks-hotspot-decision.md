# Register-Hooks Hotspot Decision

Reference for Issue #1067 (`.claude/hooks/register-hooks.py` churn hotspot). Not auto-loaded.

<!-- churn-hotspot: .claude/hooks/register-hooks.py -->

**File:** `.claude/hooks/register-hooks.py`
**Issue:** #1067
**Verdict:** KEEP — documentation-only, no operative change

---

## Churn summary

3 distinct merged PRs touched `.claude/hooks/register-hooks.py` since 2026-07-30:
PRs #811, #931, and #1027.

---

## Per-function churn attribution

### `is_placeholder()` (line 56)

Untouched by all three PRs. Predates the hotspot window.

### `command_argv0()` (lines 60–75) — added by PR #1027

**PR #1027** (`docs(#1019): record global-settings-hotspot-decision; retire HOOKS_MANIFEST`)
- Introduced `command_argv0()` to extract the executable path (argv0) from a hook command
  string that may carry arguments (e.g. `foo.sh --check`).
- Driver: the retired `HOOKS_MANIFEST` inline Python used raw command strings for basename
  comparison; `find_existing()` would match `foo.sh --check` against `foo.sh` only after
  argv0 extraction was added.

### `find_existing()` (lines 76–123) — extended by PR #1027

**PR #1027** (same)
- Added `target_cmd` and `managed_roots` parameters.
- Extended matching logic: exact canonical path (skip), placeholder (repair), managed-legacy
  path at wrong location (migrate), unmanaged user path sharing a basename (leave alone).
- Driver: retiring `HOOKS_MANIFEST` required the registrar to handle legacy root-repo hook
  paths left by pre-worktree installs, not just placeholder paths.

### `build_manifest()` (lines 124–159)

Untouched by all three PRs. Predates the hotspot window.

### `sync_statusline()` (lines 160–227) — added by PR #931

**PR #931** (`feat(#779): statusline — ET time · branch · active agents/watchers`)
- Introduced `sync_statusline()`, an ~68-line function that seeds or path-repairs
  `settings["statusLine"]` from the template.
- Ownership model: matches only by `.claude/scripts/<script>` layout suffix, not basename
  alone, so a user's own `~/bin/statusline.sh` is never claimed.
- Added `--statusline-only` flag to `main()` and `scripts_dir` argument derivation in
  `main()` for the `sync_statusline()` call.
- Driver: statusLine is a separate top-level settings surface whose `command` needs the
  identical placeholder-to-worktree resolution as the hook entries; `register-hooks.py`
  is the one implementation that does this resolution at session start.

### `main()` (lines 228–466) — extended by PRs #811 and #1027

**PR #811** (`fix(#792): move session-start-sync.sh to the SessionStart hook event`)
- Added a ~38-line stale-event-registration pruning loop inside `main()`.
- When a hook script moves from one event type to another in the template (e.g.
  PostToolUse → SessionStart), the live `settings.json` retains the old entry without
  this cleanup. The pruning loop removes stale registrations by cross-referencing each
  live hook's script basename against the manifest's canonical event.
- Driver: without this cleanup, `session-start-sync.sh` would fire on both PostToolUse
  (stale) and SessionStart (new) after the event migration — a behavioral correctness
  requirement.

**PR #1027** (same as above)
- Extended `main()` to build and thread the `managed_hook_roots` set into `find_existing()`
  and the pruning loop.
- Added decommissioned-hook pruning: hooks absent from the manifest, resident in a managed
  directory, and whose script file no longer exists are removed from `settings.json`.
- Restricted both forms of pruning to managed roots so third-party hook registrations are
  never touched.
- Added `shlex` import (used for argv0-aware command parsing in `command_argv0()` and the pruning loop).
- Driver: full install-time parity with the retired `HOOKS_MANIFEST` inline Python required
  legacy-path migration and decommissioned-hook pruning, which the inline Python performed.

---

## Churn drivers classification

| PR | Section(s) changed | Driver |
|----|--------------------|--------|
| #811 | `main()` — stale-event pruning loop | Hook event migration: stale registrations must be cleaned up when scripts move events |
| #931 | `sync_statusline()` (new) + `--statusline-only` flag + docstring | New settings surface: statusLine resolution added to the single registrar |
| #1027 | `command_argv0()` (new) + `find_existing()` extension + `main()` managed-roots + decommissioned pruning | HOOKS_MANIFEST remediation: argv0-aware matching, legacy-path migration, managed-roots pruning |

There are no merge conflicts in the hotspot window. There are no competing-concern edits
to the same function across PRs. The churn is sequential and non-conflicting: each PR
added a distinct new capability to the registrar.

---

## Verdict: KEEP — no operative change

The file is the single code path every hook and settings-surface change must pass through.
Both install-time (`setup-skills-worktree.sh`) and session-start (`session-start-sync.sh`)
registration route through `register-hooks.py`. This junction nature is by construction:
a split would multiply the coordinated-edit surface without eliminating the root cause.

The three PRs do not represent independently-owned sub-concerns:
- PR #811's stale-event pruning is a correctness invariant of the same hook-registration
  loop that all other PRs extend.
- PR #931's `sync_statusline()` expands the registrar's contract to a new settings surface;
  it is invoked from the same `main()` entry point under the same caller conventions.
- PR #1027's argv0 and managed-roots additions are the implementation substrate that makes
  the entire registration loop safe for the post-HOOKS_MANIFEST world.

This fails the `fixpr` extraction bar, which requires independently-owned, deterministic
sub-concerns that change on distinct cadences and would not require coordinated edits
after extraction.

---

## Options considered

| Option | Verdict | Rationale |
|--------|---------|-----------|
| Documentation-only KEEP (this decision) | **Chosen** | Churn is contract growth through the single canonical registrar, not independently-owned sub-concerns |
| In-file extraction: move stale-event pruning loop into a named function `prune_stale_hooks()` | Rejected | Would not reduce the churn signal — the pruning loop and the rest of `main()` change on the same cadence (both are touched by PR #1027); extraction adds indirection without benefit |
| Split into separate scripts (e.g. separate hook-pruner and statusLine-syncer) | Rejected | Blocks change on a shared cadence; both callers need the combined atomic write; the `--statusline-only` flag already provides the single use-case where partial behavior is needed |

---

## Preserved invariants

- Runtime behavior, exit codes, and stderr summary text stay unchanged.
- `register-hooks.py` remains the sole install-time and session-start registrar.
- The `--statusline-only` flag interface is preserved for any caller needing statusLine
  sync without full hook registration.
- Third-party hook registrations (unmanaged paths) are never touched by the pruning logic.

---

## Future edits and reconsideration

Adding a new hook: edit `global-settings.json` and add the script to `.claude/hooks/`.
`register-hooks.py` picks it up at session start with no code change needed.

Reconsider this KEEP verdict only if:
- The stale-event pruning, statusLine sync, and decommissioned-hook pruning concerns begin
  changing on independent cadences and cause merge conflicts between PRs.
- A distinct owner begins iterating one block in isolation across multiple PRs without
  touching the others.

---

## Related precedent

- `.claude/reference/global-settings-hotspot-decision.md` — the companion decision for
  `global-settings.json`; established `register-hooks.py` as the single implementation
  for both install-time and session-start registration (Issue #1019).
- `.claude/reference/setup-skills-worktree-hotspot-decision.md` — shares PRs #811, #931,
  #1027 in its hotspot window; all 4 of that file's churn PRs map to the same hook/statusLine
  registration concern (Issue #1063).
- `.claude/reference/fixpr-hotspot-decision.md` — extraction is justified when independently
  changing deterministic blocks drive the churn; that bar is not met here.
- `.claude/reference/start-issue-hotspot-decision.md` — KEEP/no-operative-change when churn
  is required propagation rather than independent growth.
