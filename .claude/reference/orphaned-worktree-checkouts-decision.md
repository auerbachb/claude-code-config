# Orphaned worktree checkouts — decision (issue #1417)

Companion to `.claude/reference/worktree-registration-quarantine-20260826.md`
(issue #1402, the *registration* half). Records the three-part decision taken on
2026-09-02 for the inverse class: checkout directories on disk whose
registration is gone.

Context that shapes all three parts: the repo's canonical home moved to
`~/develop/claude-code-config` on 2026-09-02. The `~/Documents` checkout is
retired — stale since 2026-08-31 and unreadable under the macOS TCC block — and
every artifact the incident left behind lives in that retired tree.

## 1. Triage of the 59 legacy orphans — out of scope

The 59 orphaned checkouts under the old `.claude/worktrees/`, and the
`wt-quarantine-20260826/` registrations they belong to, are retired along with
the `~/Documents` checkout. Any uncommitted 2026-08-26-era work in them is
superseded by the ~90 merges since; disposal happens when the user archives or
deletes that tree.

Nothing in this repo reads or touches anything under `~/Documents`.

If access to that tree is ever restored *before* it is deleted, the recovery
path is `git worktree repair <path>` on each checkout — which relinks it to its
registration and makes `git status` work again — followed by a status sweep.
Documented here as recovery, not as planned work.

## 2. Reporting — yes; removal — behind its own flag

`stale-cleanup.sh` gained a fifth, **report-only** class: a directory under
`.claude/worktrees/` whose `.git` file names a `gitdir:` target that is
provably missing. It prints the same per-item evidence line the existing
classes print, and appears in `--json` as `orphaned_checkouts[]` /
`skipped_checkouts[]` alongside a `checkout_scan` state.

Removal is **never** part of plain `--apply`. It requires
`--remove-orphaned-checkouts` *in addition to* `--apply`, and that flag removes
nothing else.

The reason for the separate gate is what is being deleted. Everything else
`--apply` removes is recreatable from the repo — a registration is a few KB of
bookkeeping, a branch is a ref. An orphaned checkout is a working tree: real
source files, possibly holding uncommitted edits that exist nowhere else, and
unreadable by `git status` until repaired. Folding that into `--apply` would
silently widen a flag whose whole contract is "deletes git bookkeeping", which
is the scope drift issue #1402 deliberately avoided.

Two consequences worth knowing before reading a sweep:

- **This class does not move the exit code.** Exit 1 means "incomplete — re-run
  me"; plain `--apply` can never clear an orphaned checkout, so letting the
  class raise it would pin the status high forever and invert that meaning for
  `/pm-clean` and `/pm-update`. Removal *failures* under the flag do count
  (exit 2), like every other deletion.
- **It fails closed, unlike the registration class.** There, a stalled metadata
  probe keeps an entry a removal candidate, because a stalled read *is* the
  debris being cleaned. Here anything short of proven absence — an unreadable
  `.git`, a stalled probe, a non-searchable parent, a path git still lists — is
  a skip. "Could not verify" must never authorize deleting source.

Full classification table, guards, and the pre-`rm` re-check:
`stale-cleanup.sh --help`.

## 3. Harness self-cleanup — stays in the orchestration layer

Reaping abandoned agent worktrees remains the orchestration layer's job:
`phase-protocols.md` Phase A step 4 removes the worktree when a phase
completes, and `/wrap` deliberately leaves the running worktree in place for
out-of-band cleanup. No autonomous deletion is added to the harness itself.

The new report class is the **backstop**: it makes any future leak visible in
the new home, in the same sweep `/pm-clean` and `/pm-update` already run, so
the next accumulation is caught as a finding rather than discovered as a
60-directory pile after an incident.

## 4. Registration-path audit — issue #1592

The four guard classes above were written for the checkout-removal path. Issue
#1592 audited `remove_registration`, its pre-`rm` re-check `registration_is_live`,
and the `scan_registrations` classification that feeds them against the same
four. Outcome:

| Guard class | Verdict for the registration path |
|-------------|-----------------------------------|
| Symlink-following via `-f` / `test -e` | **Partly present, rest applied.** `remove_registration` already refused a symlinked `$target`. Added: `-L` before the `-d` on each registry entry (a dangling entry symlink used to be dropped silently, and a resolving one used to classify and then hard-fail at the `rm` as "not a plain directory", raising exit 2 on a sweep that had done nothing wrong), and a `-L` refusal on `$reg/gitdir` before the read that follows it. The `-d` itself stays **unbounded**: `stale-cleanup.sh`'s BOUNDED READS header records why these stat probes need no wrapper (local `.git` metadata is never `dataless`, and the enclosing glob would stay unbounded anyway); `scan_checkouts` bounds its own because those entries are arbitrary working trees. |
| Size-capped reads | **Applied.** `$reg/gitdir` and `$reg/locked` are capped at 4 KiB, the same headroom a checkout's `.git` gets. `read_bounded_line` gained a `BOUNDED_OVERFLOW` out-flag so "present but over the cap" is distinguishable from "did not read" — the registration pass needs that split, because *unreadable metadata is itself a removal candidate* there and an unexplained oversized file must not inherit that. |
| Dangling link components, ancestors included | **Applied**, at the scan and again in `registration_is_live`. A `worktrees -> /Volumes/<unmounted>/…` ancestor reads as absent for **every** entry beneath it, so a leaf-only `-L` would clear a whole shelf of live registrations in one sweep. |
| Unresolved base dirs / the `/`-or-repo-root width guard | **Not applicable.** `STALE_CLEANUP_CHECKOUT_DIR` is operator-supplied and may be spelled through a symlink; `$WORKTREE_REG_DIR` is git's own `<git-common-dir>/worktrees`, always at least one segment below the common dir (so never `/`), and `$target` is the enumerating glob's own spelling of `"$WORKTREE_REG_DIR/$id"` — the containment test compares two strings built from the same value, and clears something two segments below it. An unresolvable common dir already degrades to `REG_SCAN_STATE=unavailable` with nothing classified, and an empty `$WORKTREE_REG_DIR` is already refused inside `remove_registration`. |

Two narrower sub-cases were also judged not applicable:

- **`$reg/locked` as a symlink.** `[[ -f "$reg/locked" ]]` follows links, so a
  dangling `locked` link reads as "not locked". That marker gates only the
  `--include-locked` opt-in, never the absence determination — a malformed
  marker cannot make a live worktree look absent — so it is not a
  deletion-path guard.
- **Exit-code semantics.** Unchanged. The new refusals are *skips*
  (`remove_registration` rc 2), the non-failure the live re-check already used,
  matching `remove_checkout`'s decline.

**Known boundary, shared with the pre-existing "parent not searchable" skip:**
`git worktree prune` is all-or-nothing across the registry, so a run that
prunes for some *other* entry still applies git's own rule — a bare stat, which
follows symlinks — to a refused one. What this script owns is what it reports
and what it deletes itself; `registration_is_live` closes the hole on that
path. Narrowing git's prune is out of scope and would block legitimate cleanup.
