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

The four guard classes above were written for the checkout-removal path.
Issue #1592 audited `remove_registration`, its pre-`rm` re-check
`registration_is_live`, and the `scan_registrations` classification that feeds
them against the same four. Outcome:

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

### 4a. Two more "absence" holes, found in review

CodeAnt's review of PR #1597 flagged two further routes to the same outcome the
guard classes exist to prevent — a **live** worktree's registration reaching the
deletion path — neither involving a symlink. Both were verified reachable and
fixed on the branch; the pattern in both is the one the table above keeps
hitting, *a probe that cannot distinguish "absent" from "unreadable"*.

- **An unsearchable ancestor more than one level up.** `path_absence_provable`
  tested the immediate parent only. `test -e` reports no errno, so it is false
  on a worktree behind a mode-000 ancestor *and* false on that worktree's
  parent — and the second false was read as "the parent is gone, so absence
  holds". A live worktree two or more levels under an unsearchable directory
  was therefore classified as an orphan. The probe now climbs to the nearest
  ancestor that actually answers, which is what its own header and the caller's
  "nearest existing parent" skip message already claimed. The one-level case was
  always caught; only the deeper one was not.

  Worth recording, because CodeAnt's *stated* mechanism was different and does
  not hold: it read the bug as `test -L` errors being taken for "not a symlink"
  in `path_has_dangling_link_component`. `test` cannot report that distinction —
  it returns 1 for EACCES and ENOENT alike (verified on both the bash builtin and
  `/bin/test`), so there is no error status to branch on and hardening that
  function would have changed nothing. The finding's *conclusion* was correct and
  the root cause sat one call earlier, in a helper this PR had not touched.

- **A relative `gitdir` left unanchored.** `read_registration_gitdir` used a
  relative registration `gitdir` as-is, so it was probed against whatever
  directory the caller happened to be in. That is not a hypothetical shape:
  `git worktree add --relative-paths` (git ≥ 2.48) writes exactly it, and such a
  registration read as absent — a live worktree queued for removal, with the
  verdict depending on the invoking cwd. Now anchored to the registration
  directory, mirroring what `read_checkout_gitdir` already did for a checkout's
  `.git`.

### 4b. The guard that blocked the removal it was added to protect

BugBot flagged a third one, and this is the most important of the three because
it is a **regression introduced by this PR**, not a pre-existing hole: the new
whole-path dangling-link walk in `registration_is_live` ran *before*
`path_exists_bounded` and refused on a **stalled** probe as well as an observed
dangling link.

Those are not the same thing here. A readable `gitdir` naming a still-stalled
worktree path is the *targeted-removal* case — the scan classifies it
"unreadable — prunable with warning", and `path_exists_bounded` deliberately
lets a stalled probe through as rc 2, "the very symptom being cleaned". By
refusing first, the new guard left exactly those entries in place for the
`git worktree prune` that follows to hang on: the 2026-08-26 incident this
script was written for.

`path_has_dangling_link_component` now reports the stalled way of returning 0
out-of-band in `DANGLING_PROBE_INCONCLUSIVE`, the same shape (and for the same
reason) as `BOUNDED_OVERFLOW`: callers asking *"does absence hold?"* still want
the two merged, and the caller asking *"may I remove this?"* must not. Only an
observed dangling component refuses at the pre-`rm` gate; a stalled walk falls
through to the probe, which reaches the same stall and answers on its own terms.
`checkout_still_orphaned` needed no change — it removes only on proven absence
(rc 1), so a stall stops it there regardless, which is the deliberate asymmetry
already documented above it.

**Coverage, stated honestly:** the observed-dangling half is pinned by T20's
mid-run ancestor break and T19's checkout equivalent, both of which still pass
and would fail if the refusal had simply been dropped. The *stalled* half has no
test, because this suite has no way to stall an `lstat`: its stall harness is a
FIFO `gitdir` (`mkfifo`), which blocks the read and returns before the walk is
ever reached, `test` is a shell builtin so no PATH stub intercepts it, and
`normalize_bound` rejects a zero bound. That gap is why the regression reached
review in the first place, and it is recorded here rather than papered over with
a test that would pass without the fix.

Both of the §4a fixes are pinned by T21 in `stale-cleanup.test.sh`, whose assertions were
confirmed to fail against the pre-fix script while its two positive controls
(the genuinely-gone relative registration, the targeted bait) kept passing. T21's
`--apply` case runs in a repo carrying only *targeted* candidates, so no
`git worktree prune` is issued and the survival it asserts is this script's own
decision rather than git's — the same scoping repoK uses around the boundary
described just above.
