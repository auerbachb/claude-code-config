#!/usr/bin/env bash
# stale-cleanup.sh — Detect and optionally remove stale worktrees and branches.
#
# PURPOSE
#   Replaces the self-cleanup that /wrap used to do (worktree removal + branch
#   deletion in the running session). Runs out-of-band so the active session
#   never deletes itself. /pm-clean (workspace sweep) is the sole skill caller,
#   and this script is the single source of truth for stale worktree/branch
#   detection and safety, so no second implementation can diverge from it
#   (issue #618). Detects five classes of stale state on the target repo's root:
#     1. Local worktrees whose HEAD commit is older than STALE_DAYS.
#     2. Local branches whose tip commit is older than STALE_DAYS.
#     3. Remote branches (refs/remotes/origin/*) whose tip commit is older
#        than STALE_DAYS.
#     4. Orphaned worktree *registrations* — `<git-common-dir>/worktrees/<id>`
#        entries with no live worktree behind them (issue #1402).
#     5. Orphaned worktree *checkouts* — directories under `.claude/worktrees/`
#        whose `.git` gitdir target is gone: the inverse of class 4, and
#        REPORT-ONLY unless --remove-orphaned-checkouts is passed (issue #1417).
#
#   TARGET REPO RESOLUTION (invoking-repo scope — issues #687/#697): the swept
#   repo is resolved from the CALLER's current directory (or an explicit
#   --root <path>), never from this script's own location. The script is
#   routinely invoked from other projects via the ~/.claude/skills-worktree
#   checkout; resolving from its own path would sweep claude-code-config's
#   workspace no matter where the caller was standing. The open-PR safety
#   check runs inside the resolved root for the same reason — the PR set must
#   describe the repo actually being swept.
#
#   Default mode is --check (dry-run). --apply performs the deletions only
#   for items that pass every safety check below. Nothing is ever deleted in
#   --check mode.
#
# SAFETY CHECKS (always applied; cannot be bypassed)
#   Worktrees:
#     - Skip the main worktree (root repo).
#     - Skip the worktree the caller is currently inside (resolved from $PWD).
#     - Skip if the worktree has uncommitted tracked changes (git diff).
#     - Skip if the worktree's branch has an open PR.
#   Local branches:
#     - Skip protected names: main, master, develop.
#     - Skip the current branch in any worktree (git refuses anyway).
#     - Skip branches checked out in any worktree.
#     - Skip branches with an open PR.
#   Remote branches:
#     - Skip protected names: main, master, develop, HEAD.
#     - Skip branches with an open PR.
#   Worktree registrations:
#     - Skip any registration whose worktree directory still exists AND whose
#       metadata reads cleanly — a live entry is never touched.
#     - Skip the registration belonging to the caller's own worktree.
#     - Skip `locked` registrations unless --include-locked is passed, and even
#       then only when the worktree directory is gone or its metadata is
#       unreadable (a lock on a live worktree is always honoured).
#     - Skip a registration ENTRY that is itself a symlink, dangling or not.
#     - Skip an entry whose `gitdir` is a symlink or exceeds 4 KiB: that is not
#       one of these files, so nothing about the entry can be established.
#     - Skip an entry whose worktree path is, or sits UNDER, a dangling
#       symlink. `test -e` follows links, so such a path reads as provably
#       absent — but the name is a present entry whose target may return, and
#       one dangling ancestor covers every entry beneath it.
#   Worktree checkouts:
#     - Never removed at all without --remove-orphaned-checkouts, which plain
#       --apply does NOT imply.
#     - Skip anything whose `.git` gitdir target could not be PROVEN missing —
#       an unreadable `.git`, a stalled probe, or a non-searchable parent all
#       skip. Only proven absence classifies.
#     - Skip the caller's own worktree, symlinks, and any path git still
#       reports in `git worktree list`.
#
# ORPHANED WORKTREE REGISTRATIONS (issue #1402)
#   Every linked worktree has a registration directory at
#   `<git-common-dir>/worktrees/<id>` holding `gitdir`, `HEAD`, `index`, and
#   optionally `locked`. Removing a worktree directory without going through
#   `git worktree remove` leaves that registration behind, and every later
#   `git worktree list` pays to read it. Enough of them and git stalls — the
#   2026-08-26 incident that motivated issue #1363 / PR #1386, where 62 stale
#   registrations pointed at iCloud-evicted (`dataless`) files whose reads
#   never returned. PR #1386 bounded `repo-root.sh` so the stall could not
#   freeze the merge path; this script removes the debris that caused it.
#
#   Classification (staleness-independent — STALE_DAYS does NOT apply here;
#   a missing worktree directory is a definitive signal, not an age heuristic,
#   and this matches `git worktree prune`'s own semantics):
#     live       — `gitdir` read cleanly and the worktree directory exists.
#                  Never reported, never touched.
#     orphaned   — `gitdir` read cleanly and the worktree directory is gone.
#     unreadable — `gitdir` (or the existence probe on its target) did not
#                  finish inside the read bound. Reported as
#                  "unreadable — prunable with warning": we cannot prove the
#                  worktree is gone, only that git cannot read the entry
#                  either. Recovery if such a worktree does still exist is
#                  `git worktree repair <path>`.
#
#   Removal paths under --apply (which path handles which case):
#     `git worktree prune`  — the plain orphaned, unlocked case. Preferred:
#           git applies its own safety rules and the call is cheap and bounded
#           once the unreadable entries are out of the way.
#     targeted removal      — unreadable entries, and locked entries cleared
#           via --include-locked. `git worktree prune` reads the same `gitdir`
#           we could not read, so it would hang on exactly these; and it
#           refuses locked entries by design. The registration directory is
#           removed directly, under path guards that allow only a single-
#           segment id directly beneath `<git-common-dir>/worktrees`, never a
#           symlink, always under the bound. Targeted removals run FIRST so
#           the subsequent `git worktree prune` cannot stall.
#
#   Locks: this repo's agent harness writes a `locked` marker into every
#   worktree it creates, so abandoned agent worktrees leave *locked* orphans
#   that `git worktree prune` will not touch. They are reported as skipped and
#   cleared only with the explicit --include-locked opt-in.
#
# ORPHANED WORKTREE CHECKOUTS (issue #1417)
#   The inverse of class 4: a checkout directory on disk whose registration is
#   gone. Class 4 is bookkeeping with no worktree; this is a worktree with no
#   bookkeeping. The 2026-08-26 incident left both — 59 checkouts under
#   `.claude/worktrees/` against 11 registrations — and the same repair
#   (`git worktree repair <path>`) is what makes one usable by git again.
#
#   Classification (staleness-independent, exactly like class 4):
#     orphaned  — the entry is a directory holding a `.git` FILE whose
#                 `gitdir:` line reads and names a path PROVEN absent.
#     skipped   — every other outcome that is not plainly "live": a `.git`
#                 that did not read or carried no `gitdir:` prefix, a stalled
#                 existence probe, a non-searchable parent, a symlinked entry
#                 or a symlinked `.git` (both `-d` and `-f` follow links, so
#                 each is refused explicitly, and again at the pre-rm
#                 re-check), the caller's own worktree, or a path git lists.
#     ignored   — a `.git` DIRECTORY (a nested standalone clone, not a linked
#                 checkout) or no `.git` at all. Neither is this class, and
#                 neither is reported: `.claude/worktrees/` is an ordinary
#                 directory that may hold ordinary things.
#
#   Enumeration deliberately does NOT include dot-prefixed entries — the same
#   plain glob the registration pass uses. Neither git nor this harness ever
#   names one that way (ids are `issue-*`, `agent-*`, or a worktree basename),
#   and the omission fails safe: an entry never scanned is never reported and
#   never removed. Widening the glob would widen what a working-tree deletion
#   can reach, which is the wrong direction for this class.
#
#   WHY REMOVAL HAS ITS OWN FLAG. Everything else --apply deletes is
#   recreatable from the repo: a registration is a few KB of bookkeeping, a
#   branch is a ref. An orphaned checkout is a working tree — real source
#   files, possibly carrying uncommitted edits that exist nowhere else, and
#   unreadable by `git status` until repaired. Letting --apply gain that reach
#   would silently widen a flag whose entire contract is "deletes git
#   bookkeeping". So removal requires --remove-orphaned-checkouts *in
#   addition to* --apply, and that flag removes nothing else.
#
#   WHY THIS CLASS DOES NOT AFFECT THE EXIT CODE. Exit 1 in this script means
#   "incomplete — re-run me" (see EXIT STATUS). Plain --apply can never clear
#   an orphaned checkout, so letting the class raise exit 1 would pin the
#   status high forever and invert that meaning for every caller. The class is
#   surfaced where its consumers actually read — the text report and the
#   `orphaned_checkouts` JSON array (/pm-clean). Removal FAILURES
#   under the flag do count, exactly like every other deletion: exit 2.
#
#   Fail-closed asymmetry against class 4, deliberate and worth stating: for a
#   registration, a stalled metadata probe is itself the symptom being cleaned,
#   so it stays a removal candidate. Here it does not. "Could not verify" must
#   never authorize deleting source, so both the classification pass and the
#   pre-rm re-check treat anything short of proven absence as a skip.
#
# BOUNDED READS (NON-NEGOTIABLE)
#   EVERY git call this script makes, and every *content* read that can touch a
#   worktree registration, runs under a wall-clock bound and is killed on
#   expiry — the sweep must never hang on evicted files, which is the failure it
#   exists to clean up. macOS ships no `timeout(1)`, hence the
#   background-and-poll wrapper, now shared with repo-root.sh as
#   `lib/bounded-run.sh` (issue #1404).
#
#   What a bound does on expiry is decided per call, and never by going quiet:
#     * Classification (`worktree list --porcelain`, `log -1`, both
#       `for-each-ref` passes, the per-worktree dirty checks) DEGRADES: the
#       affected pass reports "not classified" on stderr and in the JSON, the
#       run continues — the registration sweep is the pass that fixes the
#       cause, so it must still run — and the exit status is 1 (incomplete
#       sweep), never a 0 that would read as a clean bill of health. A dirty
#       check that could not finish skips its worktree: "could not verify"
#       must never mean "safe to delete".
#     * Deletion under --apply (`worktree remove`, `show-ref`, `branch -D`,
#       `push origin --delete`, the targeted registration `rm`) is reported as
#       a per-item `failed: … exceeded Ns and was killed` and counts toward
#       exit 2, exactly like any other deletion failure. Aborting the whole
#       run on one wedged item would strand every item after it.
#
#   Where the bound stops, stated exactly because "every filesystem call"
#   would overclaim: the enumeration glob over <common>/worktrees and the
#   `-d`/`-f` probes on entries inside it are readdir/stat against the local
#   repo's own .git — which this script has already read, under a bound, to
#   resolve that path at all. Metadata is never `dataless`; only file
#   *content* is evicted, so those probes cannot block on the incident these
#   bounds exist for, and forking twice per probe per entry to wrap them
#   would still leave the parent's own glob unbounded. What does get bounded
#   is everything that comes *out* of a registration and is therefore
#   arbitrary: the `gitdir` and `locked` contents (read_bounded_line, capped at
#   4 KiB since issue #1592 — a file past that is not one of these and is
#   refused rather than copied whole into a shell variable by the pass that
#   decides whether to delete the entry) and the worktree path they name, which
#   may sit on the evicted volume (path_exists_bounded, and the whole-path
#   dangling-link walk that qualifies it). Resolving the common dir is bounded for the same
#   reason — it is a git call — and degrades to registration_scan
#   "unavailable" rather than proceeding on an unverified path.
#
#   The bound does NOT stop at the open-PR query any more (issue #1509).
#   `gh pr list` (fetch_open_prs) runs under STALE_CLEANUP_GH_TIMEOUT_SECS and
#   fails CLOSED: an expired bound exits 4, "refusing to run with an unverified
#   open-PR set", rather than continuing with an empty PR set — which would
#   make every branch look PR-free and eligible for deletion, the silent
#   failure that check exists to prevent. It runs on every invocation before
#   any classification, so leaving it unwrapped let a wedged forge or a hung
#   TLS handshake stall the whole sweep there with nothing to kill it. Bounding
#   it took rewiring both command substitutions off that path, since
#   run_bounded returns its child's stdout through $CAPTURE and must never be
#   used inside `$( )`: gh_pr_page now leaves the page in $CAPTURE, and
#   fetch_open_prs reports through the OPEN_PR_BRANCHES global instead of
#   stdout — the same shape, for the same reason, as read_bounded_line.
#   (Local helpers like jq and date are unbounded still, but they cannot block
#   on a remote, which is what these bounds are for.)
#
# CONFIGURATION
#   STALE_DAYS — env var, default 7. Tip commits older than this are stale.
#   STALE_CLEANUP_TIMEOUT_SECS — env var, default 10. Wall-clock bound on each
#       LOCAL git call: worktree enumeration, prune, git-dir resolution, and
#       (since issue #1404) every sweep and apply call — `log -1`, both
#       `for-each-ref` passes, the per-worktree dirty checks, `worktree
#       remove`, `show-ref`, and `branch -D`.
#   STALE_CLEANUP_NET_TIMEOUT_SECS — env var, default 60. Wall-clock bound on
#       the network DELETION, `git push origin --delete`. Separate and much
#       larger on purpose: the bound exists to stop an unbounded hang, not to
#       impose a local-read SLA on a round trip to the forge. It is NOT the
#       only network call in the script and does not cover the other one —
#       the open-PR query has its own bound, below.
#   STALE_CLEANUP_GH_TIMEOUT_SECS — env var, default 60. Wall-clock bound on
#       the open-PR query, `gh pr list` (fetch_open_prs). Network-range like
#       the deletion bound and separate from it on purpose: this query runs on
#       EVERY invocation, before any classification, so tightening it to fail
#       fast on a wedged forge must not also shorten the bound on a legitimate
#       `push --delete` over a slow link. Expiry is fail-closed — exit 4, never
#       an empty PR set (issue #1509).
#   STALE_CLEANUP_READ_TIMEOUT_SECS — env var, default 2. Wall-clock bound on
#       each per-registration metadata read, existence probe, and targeted
#       removal. Whole-second resolution, so a bound of N trips between N-1
#       and N seconds. Worst case is this bound times the registration count,
#       which is why it is much tighter than the git bound. A non-numeric or
#       zero value falls back to the default rather than disabling the bound.
#   STALE_CLEANUP_CHECKOUT_DIR — env var, default `<root>/.claude/worktrees`.
#       The directory scanned for orphaned checkouts (class 5). Repos whose
#       worktree parent differs point this at theirs; the default is the
#       location issue #1417 measured. The path is RESOLVED first (symlinks
#       and all), and a value resolving to `/` or to the repo root itself is
#       refused (exit 3) — a scan dir that wide would make every top-level
#       directory a candidate for a flag that deletes working trees.
#
# USAGE
#   stale-cleanup.sh --check                    # dry-run (default)
#   stale-cleanup.sh --apply                    # delete stale items
#   stale-cleanup.sh --check --json             # machine-readable output
#   stale-cleanup.sh --check --root <path>      # sweep a specific repo
#   stale-cleanup.sh --apply --include-locked   # also clear locked orphans
#   stale-cleanup.sh --apply --remove-orphaned-checkouts   # also delete
#                                               # orphaned working trees
#   stale-cleanup.sh --help | -h
#
#   --check    Report stale items without deleting. Exit 0 if none, 1 if any.
#   --apply    Delete stale items that pass safety checks. Exit 0 when every
#              category was swept with no failures, 1 when the sweep was
#              incomplete (a bound expired, so a category was skipped — what
#              it did reach was still applied), 2 on partial failure.
#   --json     Emit a JSON object instead of human-readable text. Includes a
#              top-level "root" (the resolved main-worktree root being swept)
#              plus the stale_*/skipped_* arrays (issue #707), the
#              orphaned_registrations/skipped_registrations arrays,
#              "worktree_enumeration" ("ok", "timed_out", or "failed"),
#              "registration_scan" ("ok", "none" when the repo has never had a
#              linked worktree, or "unavailable" when the git common dir did
#              not resolve inside the bound), and "ref_scan" ("ok",
#              "timed_out", or "failed" — the two `for-each-ref` passes that
#              classify branches). Anything other than worktree_enumeration
#              "ok", a registration_scan of "unavailable", and anything other
#              than ref_scan "ok" each make --check exit 1 on their own: the
#              sweep could not classify, which is a finding, not a clean bill
#              of health. registration_scan "none" is a clean state and does
#              not. Also includes the orphaned_checkouts/skipped_checkouts
#              arrays and "checkout_scan": "ok"; "none" when the scan directory
#              is PROVABLY absent; or "unreadable" when it could not be
#              inspected, resolved, or entered inside the bound — a state that
#              is deliberately NOT collapsed into "none", since "we could not
#              look" must never be reported as "there is nothing there".
#              orphaned_checkouts[] is empty under "unreadable" because nothing
#              was classified, not because nothing is orphaned; the reason rides
#              in skipped_checkouts[]. None of these affect the exit code (see
#              ORPHANED WORKTREE CHECKOUTS above), so callers must read
#              checkout_scan and orphaned_checkouts REGARDLESS of exit status.
#   --remove-orphaned-checkouts
#              Delete the reported orphaned checkouts. THIS DELETES WORKING-TREE
#              FILES — real source, possibly holding uncommitted edits that
#              exist nowhere else — which is why it is a separate gate and not
#              part of --apply, whose other deletions only ever remove git
#              bookkeeping. Requires --apply; passing it in --check mode is a
#              usage error, since --check never deletes anything. Removes
#              nothing but directories classified as orphaned checkouts, and
#              re-verifies each one is still orphaned immediately before the rm.
#   --include-locked
#              Also clear orphaned registrations carrying a `locked` marker.
#              Only ever applies when the worktree directory is gone or its
#              metadata is unreadable — a lock on a live worktree is always
#              honoured. Without this flag such entries are reported and left
#              alone.
#   --root     Path to (or inside) the repo to sweep. Defaults to the caller's
#              current directory, so the sweep targets the invoking repo even
#              when the script runs from another checkout (issues #687/#697).
#              Also accepts --root=<path>. An empty or flag-like value (e.g.
#              `--root --json`) is a usage error (exit 3).
#
# OUTPUT (human-readable, default)
#   Stale worktrees (older than 7 days):
#     <path> (branch <branch>, last commit <YYYY-MM-DD>)
#     ...
#   Stale local branches (older than 7 days):
#     <branch> (last commit <YYYY-MM-DD>)
#   Stale remote branches (older than 7 days):
#     origin/<branch> (last commit <YYYY-MM-DD>)
#   Orphaned worktree registrations:
#     <id> — <reason>
#   Orphaned worktree checkouts (report-only):
#     <path> — <reason>
#   Skipped (with reason):
#     <name> — <reason>
#
#   On --apply, each successful deletion is logged as "removed: <thing>" and
#   each failure as "failed: <thing> — <reason>".
#
# EXIT STATUS
#   0  No stale items, or --apply swept every category with no failures.
#   1  Incomplete sweep — the same meaning in both modes. --check found one or
#      more stale items, including orphaned worktree registrations; or, in
#      either mode, a worktree enumeration, ref enumeration, or registration
#      scan that did not finish inside its bound. An --apply that skipped a
#      whole category is reported here rather than as success: a caller that
#      reads 0 as "done" would otherwise never re-run it. Orphaned CHECKOUTS
#      are the one reported class that never reaches this code — see ORPHANED
#      WORKTREE CHECKOUTS above for why.
#   2  --apply hit one or more deletion failures (other items may have
#      succeeded — see output), including a deletion killed at its bound and
#      a failed --remove-orphaned-checkouts removal.
#      Takes precedence over 1. A registration the re-check declined to remove
#      — because its worktree reappeared, or because absence could not be
#      re-established (anomalous `gitdir`, or a worktree path that is or sits
#      under a dangling symlink) — is NOT a failure and does not reach this
#      code. Neither is a registration entry declined for being a symlink.
#   3  Usage error.
#   4  Environment error (cannot resolve repo, gh missing, lib/bounded-run.sh
#      missing, etc.).
#   70  --help header extraction produced no output (internal defect).

set -euo pipefail
# Best-effort usage telemetry — must never change this script's exit contract
# (issue #1430); stderr muted BEFORE the append per issue #1406's ordering.
if [[ -n "${HOME:-}" ]]; then
  printf '%s\t%s\t%s\n' "$(date -u +%FT%TZ)" "$(basename "$0")" "${*//$'\n'/ }" 2>/dev/null >> "$HOME/.claude/script-usage.log" || true
fi

print_help() {
  awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; n = 1; next } { exit } END { exit(n ? 0 : 1) }' "$0" ||
    { printf '%s: --help header extraction produced no output\n' "$0" >&2; exit 70; }
}

usage_error() {
  echo "stale-cleanup.sh: $1" >&2
  echo "Run with --help for usage." >&2
  exit 3
}

MODE="check"
JSON=0
MODE_SET=0
ROOT_OVERRIDE=""
INCLUDE_LOCKED=0
REMOVE_ORPHANED_CHECKOUTS=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help)
      print_help
      exit 0
      ;;
    --check|--apply)
      if (( MODE_SET == 1 )); then
        usage_error "--check and --apply are mutually exclusive"
      fi
      MODE="${1#--}"
      MODE_SET=1
      shift
      ;;
    --json)
      JSON=1
      shift
      ;;
    --include-locked)
      INCLUDE_LOCKED=1
      shift
      ;;
    --remove-orphaned-checkouts)
      REMOVE_ORPHANED_CHECKOUTS=1
      shift
      ;;
    --root)
      # Flag-like values (e.g. `--root --json`) are a usage error too —
      # letting them through would fail later at repo resolution with exit 4,
      # misreporting an argument mistake as an environment error (issue #707).
      if [[ $# -lt 2 || -z "$2" || "$2" == -* ]]; then
        usage_error "--root requires a non-empty path argument"
      fi
      ROOT_OVERRIDE="$2"
      shift 2
      ;;
    --root=*)
      ROOT_OVERRIDE="${1#--root=}"
      # Same rejection as the two-arg form. A path that genuinely starts with
      # '-' can be written as --root=./-name.
      if [[ -z "$ROOT_OVERRIDE" || "$ROOT_OVERRIDE" == -* ]]; then
        usage_error "--root requires a non-empty path argument"
      fi
      shift
      ;;
    --)
      shift
      break
      ;;
    -*)
      usage_error "unknown flag: $1"
      ;;
    *)
      usage_error "unexpected positional argument: $1"
      ;;
  esac
done

# The one flag that can delete source is never usable in the mode that promises
# to delete nothing. Silently ignoring it in --check would teach the habit of
# passing it everywhere, which is exactly how it ends up on the run that means
# it; refusing loudly keeps the gate deliberate.
if (( REMOVE_ORPHANED_CHECKOUTS == 1 )) && [[ "$MODE" != "apply" ]]; then
  usage_error "--remove-orphaned-checkouts requires --apply (it deletes working-tree files, and --check never deletes anything)"
fi

STALE_DAYS="${STALE_DAYS:-7}"
if ! [[ "$STALE_DAYS" =~ ^[0-9]+$ ]] || (( STALE_DAYS < 1 )); then
  echo "error: STALE_DAYS must be a positive integer (got: $STALE_DAYS)" >&2
  exit 3
fi

NOW="$(date +%s)"
THRESHOLD=$(( NOW - STALE_DAYS * 86400 ))

# --- Bounded execution -------------------------------------------------------
# macOS ships no `timeout(1)`, so every call that can touch a worktree
# registration goes through run_bounded: start the child in its own process
# group, poll the wall clock, kill the group on expiry. That wrapper lived here
# as a second copy of repo-root.sh's (issue #1363); issue #1404 moved the one
# definition both scripts use into lib/bounded-run.sh, which also supplies
# normalize_bound. Sourced, never executed — it is a library, not a script.
#
# SCRIPT_DIR is used ONLY to locate the helpers that ship beside this script —
# never to pick the repo to sweep (see TARGET REPO RESOLUTION above).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BOUNDED_RUN_LIB="$SCRIPT_DIR/lib/bounded-run.sh"
if [[ ! -r "$BOUNDED_RUN_LIB" ]]; then
  echo "error: bounded-run library not found at $BOUNDED_RUN_LIB — refusing to sweep with unbounded reads" >&2
  exit 4
fi
# shellcheck source=lib/bounded-run.sh
source "$BOUNDED_RUN_LIB"

GIT_BOUND_SECS="$(normalize_bound "${STALE_CLEANUP_TIMEOUT_SECS:-10}" 10)"
READ_BOUND_SECS="$(normalize_bound "${STALE_CLEANUP_READ_TIMEOUT_SECS:-2}" 2)"
# The network deletion gets its own, much larger bound. These bounds exist to
# stop an UNBOUNDED hang, not to impose a local-read SLA on a round trip to the
# forge: a `git push --delete` that legitimately takes 20s over a slow link is
# not the failure being prevented, and killing it would be a regression.
NET_BOUND_SECS="$(normalize_bound "${STALE_CLEANUP_NET_TIMEOUT_SECS:-60}" 60)"
# The open-PR query is network too, so it sits in the same range — but it gets
# its OWN knob rather than sharing the deletion's (issue #1509). The two calls
# fail differently: `push --delete` runs per item under --apply, while
# `gh pr list` runs on every invocation before any classification and gates the
# whole sweep. An operator tightening this one to fail fast on a wedged forge
# must not thereby shorten the bound on a legitimate push over a slow link.
GH_BOUND_SECS="$(normalize_bound "${STALE_CLEANUP_GH_TIMEOUT_SECS:-60}" 60)"

# Created after arg parsing so --help and usage errors leave nothing behind.
# All five are unconditional — no empty-variable arguments to guard against,
# and no early exit path that could leave one behind. CAPTURE/CAPTURE_ERR can
# be replaced mid-run (see run_bounded's orphan handover), so cleanup is a
# function over the current values plus any handed-over ones rather than a
# fixed command list.
CAPTURE="$(mktemp "${TMPDIR:-/tmp}/stale-cleanup.XXXXXX")"
CAPTURE_ERR="$(mktemp "${TMPDIR:-/tmp}/stale-cleanup-err.XXXXXX")"
WT_LIST_FILE="$(mktemp "${TMPDIR:-/tmp}/stale-cleanup-wt.XXXXXX")"
REF_LIST_FILE="$(mktemp "${TMPDIR:-/tmp}/stale-cleanup-refs.XXXXXX")"
GH_TMPERR="$(mktemp "${TMPDIR:-/tmp}/stale-cleanup-gh-stderr.XXXXXX")"
ORPHANED_CAPTURES=()
# Opt into the library's orphan handover: this script keeps running after a
# wedged call, so an unkillable child must not be left writing into files a
# later call has truncated. (repo-root.sh exits moments later and opts out.)
BOUNDED_CAPTURE_TEMPLATE="${TMPDIR:-/tmp}/stale-cleanup.XXXXXX"
BOUNDED_CAPTURE_ERR_TEMPLATE="${TMPDIR:-/tmp}/stale-cleanup-err.XXXXXX"
# The trap stays a single command rather than a function so it reads as the
# fixed cleanup list it is. It expands at EXIT, so it removes whatever
# CAPTURE/CAPTURE_ERR point at by then plus any handed-over pair. The
# `[@]+` guard is the portable empty-array expansion — a bare "${arr[@]}" is
# an unbound-variable error under `set -u` on macOS's bash 3.2.
trap 'rm -f "$CAPTURE" "$CAPTURE_ERR" "$WT_LIST_FILE" "$REF_LIST_FILE" "$GH_TMPERR" ${ORPHANED_CAPTURES[@]+"${ORPHANED_CAPTURES[@]}"}' EXIT

# read_bounded_line's out-parameters. See that function for why the answer comes
# back through globals instead of stdout.
BOUNDED_LINE=""
# 1 when the last capped read found the file PRESENT but over its cap, as
# distinct from not reading at all. Both return 1, and for the checkout pass
# that distinction never mattered — it refuses either way. The registration
# pass needs it: there, "metadata did not read" is the ordinary orphan state
# and IS a removal candidate, while "this file is far too large to be one of
# these" is an anomaly that must never clear an entry for deletion (#1592).
BOUNDED_OVERFLOW=0

# Run one git call against $ROOT under the git bound. Returns git's real exit
# status, or 124 with BOUNDED_TIMED_OUT=1 on expiry — the CALLER decides between
# degrading (a classification pass that reports "not classified") and a
# `failed:` line, per BOUNDED READS above. Never wrap this in `$( )`: the
# subshell would discard BOUNDED_TIMED_OUT and the library's orphan handover.
git_bounded() { # git args...
  local rc=0
  run_bounded "$GIT_BOUND_SECS" "${GIT[@]}" "$@" || rc=$?
  return "$rc"
}

# git's own last words for a `failed:` line: stderr first, then stdout, then a
# bare status so the message never ends in a dangling dash.
git_error_text() { # rc
  local msg=""
  msg="$(head -n 1 "$CAPTURE_ERR" 2>/dev/null || true)"
  [[ -n "$msg" ]] || msg="$(head -n 1 "$CAPTURE" 2>/dev/null || true)"
  [[ -n "$msg" ]] || msg="exit $1"
  printf '%s' "$msg"
}

# Bounded tracked-only dirty probe on one worktree, used by both the
# classification pass and the --apply re-check.
#   0 = clean
#   1 = dirty, or git refused to say (either way: do not delete)
#   2 = a bound expired — an evicted worktree is exactly what stalls here, and
#       "could not verify" must never read as "clean enough to remove"
# Statement form only, never `$( )` — see git_bounded.
worktree_dirty_state() { # worktree path
  local wt="$1" rc=0
  run_bounded "$GIT_BOUND_SECS" git -C "$wt" diff --quiet || rc=$?
  if [[ "$BOUNDED_TIMED_OUT" -eq 1 ]]; then return 2; fi
  if (( rc != 0 )); then return 1; fi
  rc=0
  run_bounded "$GIT_BOUND_SECS" git -C "$wt" diff --cached --quiet || rc=$?
  if [[ "$BOUNDED_TIMED_OUT" -eq 1 ]]; then return 2; fi
  if (( rc != 0 )); then return 1; fi
  return 0
}

# Read the first line of a small metadata file under the read bound. On success
# the line lands in BOUNDED_LINE and the return is 0; a non-zero return means
# the read failed or tripped the bound, and BOUNDED_LINE is left empty.
# `cat` is forked deliberately — a builtin `$(<file)` read cannot be killed.
#
# The answer comes back through a global rather than stdout ON PURPOSE, and the
# callers must never wrap this in `$(...)`. Command substitution runs the whole
# function — run_bounded included — in a subshell, and run_bounded's orphan
# handover is a mutation of the PARENT's state: it appends the wedged call's
# capture paths to ORPHANED_CAPTURES and points CAPTURE/CAPTURE_ERR at fresh
# ones. Lose that to a subshell and the parent keeps reading and truncating
# files an unkillable orphan still holds open — precisely the contamination the
# handover exists to prevent. `read_bounded_line` is the only run_bounded
# wrapper that ever returned data, so it was the only one exposed to this.
#
# An optional byte cap (issue #1417) refuses a file that is implausibly large
# for the one short line these metadata files hold, rather than copying it
# whole into $CAPTURE and then into a shell variable. It reads cap+1 bytes so
# an overflow is DETECTED rather than silently truncated: a truncated
# `gitdir:` path would name a registration that does not exist, which is
# exactly the shape that classifies a live checkout as orphaned. Omitting the
# cap keeps the original unlimited behaviour, which is what the registration
# pass still uses.
read_bounded_line() { # path [max_bytes]
  local rc=0 cap="${2:-}" got=0
  BOUNDED_LINE=""
  BOUNDED_OVERFLOW=0
  if [[ -n "$cap" ]]; then
    run_bounded "$READ_BOUND_SECS" head -c "$(( cap + 1 ))" "$1" || rc=$?
  else
    run_bounded "$READ_BOUND_SECS" cat "$1" || rc=$?
  fi
  if (( rc != 0 )); then return 1; fi
  if [[ -n "$cap" ]]; then
    got="$(wc -c < "$CAPTURE" 2>/dev/null || echo 0)"
    # Arithmetic context tolerates wc's leading whitespace. Over the cap means
    # the content did not fit, so nothing here is trustworthy — fail closed,
    # flagging WHY so a caller that treats an unreadable file as ordinary
    # debris can tell this apart from one.
    if (( got > cap )); then BOUNDED_OVERFLOW=1; return 1; fi
  fi
  # This substitution is safe where the one around run_bounded was not: the
  # handover has already happened in the parent, and $CAPTURE is our own temp
  # file, never the possibly-wedged path being probed.
  BOUNDED_LINE="$(head -n 1 "$CAPTURE")" || { BOUNDED_LINE=""; return 1; }
  return 0
}

# Is the path's absence actually established, or merely not observed? `test -e`
# reports no errno: it is false for a path that does not exist AND for one
# whose parent cannot be searched (EACCES on an unreadable directory, a stale
# or half-mounted mountpoint). Absence only counts as proven when the nearest
# ancestor that does exist is a directory we can search — walk up to it, since
# the whole parent tree being gone is an ordinary orphan, not an anomaly. The
# walk runs inside one bounded child so it stays under the same bound.
#
# The walk CLIMBS; testing the immediate parent alone was not enough (#1597).
# A parent that itself sits behind an unsearchable directory is unreadable for
# the same reason its child was, so `test -e` on it is false too — and reading
# that as "the parent is gone, so absence holds" hands a live worktree two or
# more levels under a mode-000 ancestor to the deletion path. Only a component
# that actually answers ends the walk, which is what the paragraph above always
# claimed and what the caller's own "nearest existing parent" skip message
# promises. Reaching `/` means nothing along the way refused us: ordinary
# orphan, absence holds.
#
#   0 = absence is established
#   1 = not established (an ancestor exists but refuses search, or the walk did
#       not finish inside the bound) — the caller must not treat this as missing
path_absence_provable() { # path
  local rc=0
  run_bounded "$READ_BOUND_SECS" sh -c '
    p=$(dirname -- "$1")
    prev=
    while [ -n "$p" ] && [ "$p" != "$prev" ]; do
      # Searchable: the lookup below it really happened and really missed.
      [ -x "$p" ] && exit 0
      # Present but refusing search — the case we must not read as "missing".
      [ -e "$p" ] && exit 1
      # Neither: this level is unreadable too, so it settles nothing. Climb.
      [ "$p" = "/" ] && exit 0
      prev=$p
      p=$(dirname -- "$p")
    done
    exit 0
  ' _ "$1" || rc=$?
  if [[ "$BOUNDED_TIMED_OUT" -eq 1 ]]; then return 1; fi
  if (( rc == 0 )); then return 0; fi
  return 1
}

# Bounded existence probe.
#   0 = exists
#   1 = absent, and provably so
#   2 = could not be determined inside the bound (a stalled stat is itself the
#       symptom we are cleaning up, so this stays a removal candidate)
#   3 = indeterminate — not observed, but absence could not be established.
#       Distinct from 1 on purpose: collapsing it into "missing" would classify
#       a live worktree behind an unsearchable parent as an orphan and delete
#       its registration. This probe gates deletion, so it fails closed.
path_exists_bounded() { # path
  local rc=0
  run_bounded "$READ_BOUND_SECS" test -e "$1" || rc=$?
  if [[ "$BOUNDED_TIMED_OUT" -eq 1 ]]; then return 2; fi
  if (( rc == 0 )); then return 0; fi
  rc=0
  path_absence_provable "$1" || rc=$?
  if [[ "$BOUNDED_TIMED_OUT" -eq 1 ]] || (( rc != 0 )); then return 3; fi
  return 1
}

# Is any component of this path a symlink, or uninspectable?
#
# The companion to path_exists_bounded, and the reason both passes need one:
# `test -e` FOLLOWS symlinks, so a dangling link probes as "provably absent"
# even though the name is a present entry somebody put there, whose target can
# come back. Defined here, beside the probe it qualifies, because BOTH deletion
# paths gate on it — the registration pass (#1592) runs long before the
# checkout pass that first needed it (#1417).
#
# `-L` on the final component alone is not enough. The "a present entry whose
# target may return" argument that guards a dangling final link applies just as
# well to every parent: with `worktrees -> /Volumes/archive/...` on an unmounted
# volume, lstat cannot see the final component at all, so `-L "$target"` is
# FALSE while `test -e` still reports absent — the same quarantine-on-a-
# detachable-volume case, one level up, landing in "provably absent" and
# clearing a working tree, or a whole shelf of registrations, for deletion.
#
# Only a link that does not RESOLVE counts. A resolving one is not a hazard:
# the lookup genuinely traversed it and genuinely missed, so absence below it is
# real. Requiring merely "is a symlink" would refuse almost everything on macOS,
# where /var -> /private/var puts a symlink above every path under $TMPDIR.
#
#   0 = a dangling symlink component was found, or the chain could not be
#       inspected inside the bound. Either way absence is NOT established.
#   1 = every component was inspected and any symlink among them resolves.
#
# Those two ways of returning 0 are NOT interchangeable for every caller, so the
# stalled one is also reported out-of-band in DANGLING_PROBE_INCONCLUSIVE (#1597
# review). A caller deciding whether absence holds wants them merged — neither
# establishes it. A caller deciding whether to REMOVE does not: a stalled lstat
# is the debris this script exists to clear, and treating it as an observed
# dangling link is what let the pre-`rm` gate refuse the very entries the scan
# had classified for targeted removal. Same out-flag shape as BOUNDED_OVERFLOW,
# and for the same reason — "could not read" must stay distinguishable from
# "read, and here is what it says".
#
# Bounded like every other probe here: an lstat on a stalled mount hangs too.
DANGLING_PROBE_INCONCLUSIVE=0
path_has_dangling_link_component() { # path
  local p="$1" prev="" l_rc e_rc
  DANGLING_PROBE_INCONCLUSIVE=0
  while [[ -n "$p" && "$p" != "/" && "$p" != "." && "$p" != "$prev" ]]; do
    l_rc=0
    run_bounded "$READ_BOUND_SECS" test -L "$p" || l_rc=$?
    if [[ "$BOUNDED_TIMED_OUT" -eq 1 ]]; then DANGLING_PROBE_INCONCLUSIVE=1; return 0; fi
    if (( l_rc == 0 )); then
      e_rc=0
      run_bounded "$READ_BOUND_SECS" test -e "$p" || e_rc=$?
      if [[ "$BOUNDED_TIMED_OUT" -eq 1 ]]; then DANGLING_PROBE_INCONCLUSIVE=1; return 0; fi
      if (( e_rc != 0 )); then return 0; fi
    fi
    prev="$p"
    p="$(dirname -- "$p")"
  done
  return 1
}

# SCRIPT_DIR (resolved with the bounded-run library above) locates the
# repo-root.sh helper next to this script — never the repo to sweep (see TARGET
# REPO RESOLUTION above).
REPO_ROOT_SH="$SCRIPT_DIR/repo-root.sh"
if [[ ! -x "$REPO_ROOT_SH" ]]; then
  echo "error: repo-root.sh not found or not executable at $REPO_ROOT_SH" >&2
  exit 4
fi

# Resolve the repo to sweep from the caller's context — cwd by default, or an
# explicit --root override. Passing "$SCRIPT_DIR" here was the issue-#697 bug:
# invoked via ~/.claude/skills-worktree from another project, it swept
# claude-code-config's workspace instead of the invoking repo's.
#
# repo-root.sh's own diagnostic rides along on failure: since issue #1363 it can
# also exit 3 because a git call was killed at its wall-clock bound, and the
# "run from inside the repo" advice below would be wrong for that case.
ROOT=""
ROOT_RC=0
ROOT_ERR_FILE="$(mktemp)"
if [[ -n "$ROOT_OVERRIDE" ]]; then
  ROOT="$("$REPO_ROOT_SH" "$ROOT_OVERRIDE" 2>"$ROOT_ERR_FILE")" || ROOT_RC=$?
else
  ROOT="$("$REPO_ROOT_SH" 2>"$ROOT_ERR_FILE")" || ROOT_RC=$?
fi
ROOT_ERR="$(head -n 1 "$ROOT_ERR_FILE" 2>/dev/null || true)"
rm -f "$ROOT_ERR_FILE"
if [[ "$ROOT_RC" -ne 0 ]]; then
  if [[ -n "$ROOT_OVERRIDE" ]]; then
    echo "error: could not resolve a git repo from --root: $ROOT_OVERRIDE (repo-root.sh exit $ROOT_RC)${ROOT_ERR:+ — $ROOT_ERR}" >&2
  else
    echo "error: could not resolve a git repo from the current directory — run from inside the repo to sweep, or pass --root <path> (repo-root.sh exit $ROOT_RC)${ROOT_ERR:+ — $ROOT_ERR}" >&2
  fi
  exit 4
fi
if [[ -z "$ROOT" || ! -d "$ROOT" ]]; then
  echo "error: resolved root repo is empty or missing" >&2
  exit 4
fi

GIT=(git -C "$ROOT")

if ! command -v gh >/dev/null 2>&1; then
  echo "error: gh CLI not found — open-PR safety check requires it" >&2
  exit 4
fi
if ! command -v jq >/dev/null 2>&1; then
  echo "error: jq not found — required for parsing gh JSON output and emit_json" >&2
  exit 4
fi

# skill-telemetry is the data-only usage-snapshot branch (issue #572). It is
# updated at most weekly and must survive long gaps — a laptop that dies after
# weeks offline is exactly the window the snapshot exists for — so it must
# never age into the remote-stale prune set. The default name stays protected
# even when SKILL_TELEMETRY_BRANCH points snapshots at an override branch;
# the override (when set) is protected additionally.
PROTECTED_BRANCHES=("main" "master" "develop" "skill-telemetry")
if [[ -n "${SKILL_TELEMETRY_BRANCH:-}" ]]; then
  PROTECTED_BRANCHES+=("$SKILL_TELEMETRY_BRANCH")
fi
is_protected() {
  local b="$1"
  for p in "${PROTECTED_BRANCHES[@]}"; do
    [[ "$b" == "$p" ]] && return 0
  done
  return 1
}

# Cache open-PR head refs once. `gh pr list --json headRefName` caps at 1000
# per call (gh's hard limit), so we paginate via `--search "is:open"` with
# created-time pagination by walking pages until we get a short page back.
# For typical repos (dozens to low-hundreds of open PRs) this is one round
# trip; for a repo with thousands of open PRs it stays correct without
# silently dropping entries.
OPEN_PR_BRANCHES=""
# GH_TMPERR is created with the other capture files above and removed by the
# shared EXIT trap installed there.

# Fetch one page of open PRs under the network bound (issue #1509). The page is
# left in $CAPTURE for the CALLER to read; the return is gh's real status, or
# 124 with BOUNDED_TIMED_OUT=1 on expiry. Statement form only, never `$( )` —
# a subshell would discard BOUNDED_TIMED_OUT and the library's orphan handover,
# turning a bounded failure back into the silent one this path must never have.
gh_pr_page() {
  # gh pr list with --json forces non-interactive mode; --limit 1000 is the
  # max gh accepts per call. We use the search API via --search to enable
  # cursor-style pagination through `created:<timestamp` filters.
  # Stderr is captured (not silenced) so fetch_open_prs can distinguish
  # "no PRs" from "gh failed" — silently swallowing errors here would
  # let the open-PR safety check return false for every branch and
  # delete branches that actually have open PRs.
  local cursor="$1" rc=0
  local query="state:open"
  if [[ -n "$cursor" ]]; then
    query="$query created:<$cursor"
  fi
  # Run gh from the resolved root: gh derives the repo from its cwd, and the
  # PR set must describe the repo being swept — not the caller's cwd repo,
  # which differs under --root (and differed under the pre-#697 scope bug,
  # silently voiding the open-PR safety check).
  #
  # `bash -c '… && exec gh …'` rather than a cd in THIS shell: exec replaces the
  # wrapper, so gh is the process run_bounded tracks and its process-group kill
  # reaches gh and anything it spawns (a credential helper, a pager). `env -C`
  # would be shorter but is GNU-only, and moving this shell's cwd would follow
  # into CALLER_PWD below, which decides whether we are standing in a worktree
  # we must not delete. A failing cd short-circuits before exec, so a bad $ROOT
  # returns non-zero rather than an empty page.
  run_bounded "$GH_BOUND_SECS" "${BASH:-bash}" -c \
    'cd "$1" && exec gh pr list --search "$2" --limit 1000 --json headRefName,createdAt' \
    stale-cleanup-gh "$ROOT" "$query" || rc=$?
  # Land gh's stderr on the script-owned path the failure reporting below reads:
  # $CAPTURE_ERR can be re-pointed at a fresh file by the orphan handover, and a
  # later page must not surface an earlier page's stderr either. Truncate first
  # so a failed copy leaves an empty file rather than the previous page's words,
  # and never let this bookkeeping decide the run's exit status.
  : >"$GH_TMPERR" || true
  cat "$CAPTURE_ERR" >>"$GH_TMPERR" 2>/dev/null || true
  return "$rc"
}
# Fills OPEN_PR_BRANCHES with the open PRs' head refs, one per line.
#
# The answer comes back through that global rather than stdout ON PURPOSE, and
# the call site must never wrap this in `$( )` — the same reasoning as
# read_bounded_line: the bounded call inside reports expiry through
# BOUNDED_TIMED_OUT and hands its captures over by mutating THIS shell's state,
# and command substitution discards both.
fetch_open_prs() {
  local cursor=""
  local prev_cursor=""
  local accumulated=""
  OPEN_PR_BRANCHES=""
  while :; do
    local page rc=0
    gh_pr_page "$cursor" || rc=$?
    # Every failure shape fails CLOSED. An unverified PR set must never be read
    # as an EMPTY one: that would make every branch look PR-free, and this check
    # is the only thing standing between the sweep and a branch with an open PR.
    if [[ "$BOUNDED_TIMED_OUT" -eq 1 ]]; then
      if [[ "$BOUNDED_CLOCK_UNREADABLE" -eq 1 ]]; then
        echo "error: could not read the clock, so the ${GH_BOUND_SECS}s bound on 'gh pr list' could not be enforced — killed the call rather than running it unbounded, and refusing to run with an unverified open-PR set" >&2
      else
        echo "error: 'gh pr list' exceeded ${GH_BOUND_SECS}s and was killed — refusing to run with an unverified open-PR set (raise STALE_CLEANUP_GH_TIMEOUT_SECS if the forge is genuinely this slow)" >&2
      fi
      sed 's/^/  gh: /' "$GH_TMPERR" >&2 || true
      exit 4
    fi
    if (( rc != 0 )); then
      echo "error: gh pr list failed — refusing to run with an unverified open-PR set" >&2
      sed 's/^/  gh: /' "$GH_TMPERR" >&2 || true
      exit 4
    fi
    # Safe where the substitution around run_bounded was not: $CAPTURE is our
    # own temp file, and any handover has already happened in this shell.
    page="$(cat "$CAPTURE")"
    [[ -z "$page" ]] && break
    local count
    if ! count="$(printf '%s' "$page" | jq 'length')"; then
      echo "error: gh pr list returned non-JSON output — refusing to proceed" >&2
      exit 4
    fi
    (( count == 0 )) && break
    local refs
    refs="$(printf '%s' "$page" | jq -r '.[].headRefName')"
    if [[ -n "$refs" ]]; then
      if [[ -z "$accumulated" ]]; then
        accumulated="$refs"
      else
        accumulated="$accumulated"$'\n'"$refs"
      fi
    fi
    # Page < 1000 entries means no more results.
    (( count < 1000 )) && break
    # Advance cursor to the oldest createdAt we just saw.
    prev_cursor="$cursor"
    cursor="$(printf '%s' "$page" | jq -r '[.[].createdAt] | min')"
    [[ -z "$cursor" || "$cursor" == "null" ]] && break
    # Guard against pathological case where 1000+ PRs share the same
    # createdAt timestamp — without this check we'd refetch the same page
    # forever. In practice 1000 collisions is impossible (timestamps have
    # second resolution and PR creation is rate-limited), but the bound
    # makes the loop demonstrably terminating.
    if [[ "$cursor" == "$prev_cursor" ]]; then
      break
    fi
  done
  OPEN_PR_BRANCHES="$accumulated"
  return 0
}
fetch_open_prs
has_open_pr() {
  local b="$1"
  [[ -z "$OPEN_PR_BRANCHES" ]] && return 1
  printf '%s\n' "$OPEN_PR_BRANCHES" | grep -Fxq "$b"
}

# Resolve "where am I right now?" so we never delete the caller's own worktree
# even if its HEAD commit happens to be older than STALE_DAYS (e.g., long-lived
# branch the user is actively working on).
CALLER_PWD="$(pwd -P 2>/dev/null || pwd)"
caller_in_worktree() {
  local wt="$1"
  # Resolve symlinks in both paths so we compare canonicalized forms.
  local wt_real
  wt_real="$(cd "$wt" 2>/dev/null && pwd -P || echo "$wt")"
  [[ "$CALLER_PWD" == "$wt_real" || "$CALLER_PWD" == "$wt_real"/* ]]
}

# Compatibility note: macOS ships bash 3.2, which has no associative arrays.
# Worktree records are stored as one delimited line per worktree in WORKTREES,
# and CHECKED_OUT_BRANCHES is a newline-joined string of branch names. We look
# up by linear scan / grep — fine for the dozens-of-worktrees scale we expect.
#
# Records use the ASCII unit separator (US, 0x1f) as the field delimiter
# instead of `|` — git refnames and filesystem paths can both contain `|`
# but never US, so parsing stays unambiguous regardless of input shape.
US=$'\x1f'
WORKTREES=()           # each entry: "is_main<US>path<US>branch<US>head_ts"
CHECKED_OUT_BRANCHES="" # newline-separated list of branches checked out anywhere

# `git worktree list --porcelain` emits records separated by blank lines:
#   worktree <path>
#   HEAD <sha>
#   branch refs/heads/<name>      (or `detached`)
parse_worktrees() {
  local cur_path="" cur_branch="" cur_head=""
  # `first` is intentionally accessible to the nested flush() below via bash's
  # dynamic scoping — flush() flips it to 0 after recording the first record
  # so subsequent records are tagged as non-main worktrees. Don't promote
  # `first` to global without also updating flush().
  local first=1
  flush() {
    if [[ -n "$cur_path" ]]; then
      local is_main=0
      if (( first == 1 )); then is_main=1; first=0; fi
      WORKTREES+=("${is_main}${US}${cur_path}${US}${cur_branch}${US}${cur_head}")
      if [[ -n "$cur_branch" ]]; then
        if [[ -z "$CHECKED_OUT_BRANCHES" ]]; then
          CHECKED_OUT_BRANCHES="$cur_branch"
        else
          CHECKED_OUT_BRANCHES="$CHECKED_OUT_BRANCHES"$'\n'"$cur_branch"
        fi
      fi
    fi
    cur_path=""; cur_branch=""; cur_head=""
  }
  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ -z "$line" ]]; then
      flush
      continue
    fi
    case "$line" in
      "worktree "*) cur_path="${line#worktree }" ;;
      "HEAD "*)
        local sha="${line#HEAD }"
        # Empty fallback (NOT 0) — 0 would compare as "ancient" against
        # THRESHOLD and force the worktree to be classified stale even
        # though we couldn't read its HEAD. Classification skips entries
        # with empty/non-numeric ts and logs the worktree.
        #
        # Bounded (issue #1404): this reads an object out of the store one
        # commit at a time, so an evicted pack stalls here per worktree. A
        # timeout degrades exactly like an unreadable HEAD — the worktree is
        # skipped rather than deleted — and says so instead of going quiet.
        cur_head=""
        if git_bounded log -1 --format=%ct "$sha"; then
          cur_head="$(head -n 1 "$CAPTURE")"
        elif [[ "$BOUNDED_TIMED_OUT" -eq 1 ]]; then
          echo "warning: 'git log -1 --format=%ct $sha' exceeded ${GIT_BOUND_SECS}s and was killed — worktree $cur_path is reported as HEAD-unreadable rather than classified" >&2
        fi
        ;;
      "branch refs/heads/"*) cur_branch="${line#branch refs/heads/}" ;;
      "detached") cur_branch="" ;;
    esac
  done < "$WT_LIST_FILE"
  flush
}

# Enumeration is bounded: this is the exact call that froze on the 2026-08-26
# incident's evicted registrations. On expiry we degrade instead of blocking —
# the registration sweep below is the pass that actually clears the cause, and
# it must still run.
WORKTREE_ENUM_STATE="ok"
enumerate_worktrees() {
  local rc=0
  run_bounded "$GIT_BOUND_SECS" "${GIT[@]}" worktree list --porcelain || rc=$?
  if [[ "$BOUNDED_TIMED_OUT" -eq 1 ]]; then
    if [[ "$BOUNDED_CLOCK_UNREADABLE" -eq 1 ]]; then
      echo "warning: could not read the clock, so the ${GIT_BOUND_SECS}s bound on 'git worktree list --porcelain' could not be enforced — killed the call rather than running it unbounded" >&2
    else
      echo "warning: 'git worktree list --porcelain' exceeded ${GIT_BOUND_SECS}s and was killed — worktrees and local branches are NOT classified in this run (raise STALE_CLEANUP_TIMEOUT_SECS if the repo is genuinely this slow)" >&2
    fi
    WORKTREE_ENUM_STATE="timed_out"
    return 1
  fi
  if (( rc != 0 )); then
    echo "warning: 'git worktree list --porcelain' failed (exit $rc) — worktrees and local branches are NOT classified in this run" >&2
    sed 's/^/  git: /' "$CAPTURE_ERR" >&2 || true
    WORKTREE_ENUM_STATE="failed"
    return 1
  fi
  cat "$CAPTURE" > "$WT_LIST_FILE"
  return 0
}

if enumerate_worktrees; then
  parse_worktrees
fi

is_branch_checked_out() {
  local b="$1"
  [[ -z "$CHECKED_OUT_BRANCHES" ]] && return 1
  printf '%s\n' "$CHECKED_OUT_BRANCHES" | grep -Fxq "$b"
}

# Classify each worktree. Stale ⇔ not main, not the caller's, no uncommitted
# tracked changes, branch has no open PR, HEAD older than threshold.
STALE_WORKTREES=()
SKIPPED_WORKTREES=()
# Empty-array guard, same pattern as the --apply loops and emit_json: under
# `set -u`, expanding "${ARR[@]}" on an empty array is an `unbound variable`
# error on bash 3.2 (macOS system bash). WORKTREES is empty exactly when
# enumerate_worktrees failed — the degraded run whose whole point is to reach
# the registration sweep that clears the cause — so an abort here would defeat
# the fallback rather than merely skipping a loop with nothing in it.
if (( ${#WORKTREES[@]} > 0 )); then
for record in "${WORKTREES[@]}"; do
  IFS="$US" read -r is_main wt branch ts <<<"$record"
  if (( is_main == 1 )); then
    SKIPPED_WORKTREES+=("${wt}${US}main worktree")
    continue
  fi
  if caller_in_worktree "$wt"; then
    SKIPPED_WORKTREES+=("${wt}${US}caller's current worktree")
    continue
  fi
  if [[ ! -d "$wt" ]]; then
    SKIPPED_WORKTREES+=("${wt}${US}directory missing — its registration is listed under orphaned registrations; clear it with --apply")
    continue
  fi
  # Tracked-only dirty detection inside the worktree, bounded (issue #1404).
  dirty_rc=0
  worktree_dirty_state "$wt" || dirty_rc=$?
  if (( dirty_rc == 2 )); then
    SKIPPED_WORKTREES+=("${wt}${US}dirty check exceeded ${GIT_BOUND_SECS}s and was killed — cannot confirm it is safe to remove")
    continue
  fi
  if (( dirty_rc != 0 )); then
    SKIPPED_WORKTREES+=("${wt}${US}uncommitted tracked changes")
    continue
  fi
  if [[ -n "$branch" ]] && has_open_pr "$branch"; then
    SKIPPED_WORKTREES+=("${wt}${US}open PR on branch $branch")
    continue
  fi
  # Unreadable HEAD (`git log -1 --format=%ct` failed): conservatively
  # skip rather than treating as ancient and deleting.
  if [[ -z "$ts" ]] || ! [[ "$ts" =~ ^[0-9]+$ ]]; then
    SKIPPED_WORKTREES+=("${wt}${US}HEAD unreadable — cannot determine staleness")
    continue
  fi
  if (( ts > THRESHOLD )); then
    continue  # fresh — not stale, not skipped (just normal)
  fi
  STALE_WORKTREES+=("${wt}${US}${branch}${US}${ts}")
done
fi

# Local branches: any refs/heads entry whose tip is older than threshold.
#
# Skipped wholesale when the worktree enumeration did not complete:
# CHECKED_OUT_BRANCHES would be empty, so every branch held by a worktree would
# read as unheld. `git branch -D` refuses a checked-out branch on its own, but
# that refusal costs git another worktree-registry read — the very call that
# just timed out. Classifying nothing is the honest answer; the caller sees
# `worktree_enumeration` and re-runs after the registration sweep.
STALE_LOCAL_BRANCHES=()
SKIPPED_LOCAL_BRANCHES=()

# Both ref passes are bounded (issue #1404) and degrade the same way the
# worktree enumeration does: a pass that cannot complete classifies nothing and
# says so, rather than blocking the registration sweep that clears the cause.
# The result is copied out of $CAPTURE before the loop runs, so a bounded call
# made from inside the loop cannot truncate the list being read — the same
# reason the enumeration writes $WT_LIST_FILE.
REF_SCAN_STATE="ok"
list_refs_bounded() { # refs prefix, human label
  local rc=0
  : > "$REF_LIST_FILE"
  git_bounded for-each-ref --format="%(refname:short)${US}%(committerdate:unix)" "$1" || rc=$?
  if [[ "$BOUNDED_TIMED_OUT" -eq 1 ]]; then
    if [[ "$BOUNDED_CLOCK_UNREADABLE" -eq 1 ]]; then
      echo "warning: could not read the clock, so the ${GIT_BOUND_SECS}s bound on 'git for-each-ref $1' could not be enforced — killed the call rather than running it unbounded" >&2
    else
      echo "warning: 'git for-each-ref $1' exceeded ${GIT_BOUND_SECS}s and was killed — $2 are NOT classified in this run (raise STALE_CLEANUP_TIMEOUT_SECS if the repo is genuinely this slow)" >&2
    fi
    REF_SCAN_STATE="timed_out"
    return 1
  fi
  if (( rc != 0 )); then
    echo "warning: 'git for-each-ref $1' failed (exit $rc) — $2 are NOT classified in this run" >&2
    sed 's/^/  git: /' "$CAPTURE_ERR" >&2 || true
    REF_SCAN_STATE="failed"
    return 1
  fi
  cat "$CAPTURE" > "$REF_LIST_FILE"
  return 0
}

if [[ "$WORKTREE_ENUM_STATE" == "ok" ]] && list_refs_bounded refs/heads/ "local branches"; then
while IFS="$US" read -r branch ts; do
  [[ -z "$branch" ]] && continue
  if is_protected "$branch"; then
    SKIPPED_LOCAL_BRANCHES+=("${branch}${US}protected")
    continue
  fi
  if is_branch_checked_out "$branch"; then
    SKIPPED_LOCAL_BRANCHES+=("${branch}${US}checked out in a worktree")
    continue
  fi
  if has_open_pr "$branch"; then
    SKIPPED_LOCAL_BRANCHES+=("${branch}${US}open PR")
    continue
  fi
  if (( ts > THRESHOLD )); then
    continue
  fi
  STALE_LOCAL_BRANCHES+=("${branch}${US}${ts}")
done < "$REF_LIST_FILE"
fi

# Remote branches under origin/. Skip the symbolic origin/HEAD and protected
# names. We do NOT auto-fetch — that's a network operation the caller can run
# explicitly before invoking this script. Stale state on a stale fetch is
# still real signal.
STALE_REMOTE_BRANCHES=()
SKIPPED_REMOTE_BRANCHES=()
if list_refs_bounded refs/remotes/origin/ "remote branches"; then
while IFS="$US" read -r ref ts; do
  [[ -z "$ref" ]] && continue
  # ref is e.g. "origin/feature-x"; strip leading origin/.
  case "$ref" in
    origin/HEAD) continue ;;
    origin/*) branch="${ref#origin/}" ;;
    *) continue ;;
  esac
  if is_protected "$branch"; then
    SKIPPED_REMOTE_BRANCHES+=("${ref}${US}protected")
    continue
  fi
  if has_open_pr "$branch"; then
    SKIPPED_REMOTE_BRANCHES+=("${ref}${US}open PR")
    continue
  fi
  if (( ts > THRESHOLD )); then
    continue
  fi
  STALE_REMOTE_BRANCHES+=("${ref}${US}${ts}")
done < "$REF_LIST_FILE"
fi

# --- Orphaned worktree registrations (issue #1402) ---------------------------
# Enumerated by listing <git-common-dir>/worktrees/, which is a directory read
# and never blocks. Only the per-entry metadata reads can stall, and those are
# individually bounded, so a wedged entry costs one bound instead of the run.

# The git common dir is resolved separately from ROOT: --separate-git-dir and
# bare layouts put it somewhere other than "$ROOT/.git". This is the cheapest
# call git offers and it touches no worktree entries.
GIT_COMMON_DIR=""
WORKTREE_REG_DIR=""
REG_SCAN_STATE="ok"   # ok | unavailable | none
resolve_common_dir() {
  local rc=0 out=""
  run_bounded "$GIT_BOUND_SECS" "${GIT[@]}" rev-parse --path-format=absolute --git-common-dir || rc=$?
  if [[ "$BOUNDED_TIMED_OUT" -eq 1 ]]; then return 1; fi
  if (( rc != 0 )); then
    # git < 2.31 has no --path-format; its plain form may answer relative to
    # the directory the call ran in, which is "$ROOT" here.
    rc=0
    run_bounded "$GIT_BOUND_SECS" "${GIT[@]}" rev-parse --git-common-dir || rc=$?
    if [[ "$BOUNDED_TIMED_OUT" -eq 1 || "$rc" -ne 0 ]]; then return 1; fi
  fi
  out="$(head -n 1 "$CAPTURE")"
  [[ -n "$out" ]] || return 1
  case "$out" in
    /*) ;;
    *) out="$ROOT/$out" ;;
  esac
  GIT_COMMON_DIR="$out"
  return 0
}

# The caller's own registration is never a removal candidate, mirroring the
# "caller's current worktree" skip the worktree pass already applies. In a
# linked worktree `rev-parse --git-dir` answers <common>/worktrees/<id>; in the
# main worktree it answers the common dir itself and matches no id.
CALLER_REG_ID=""
resolve_caller_reg_id() {
  local rc=0 out=""
  run_bounded "$GIT_BOUND_SECS" git -C "$CALLER_PWD" rev-parse --path-format=absolute --git-dir || rc=$?
  if [[ "$BOUNDED_TIMED_OUT" -eq 1 || "$rc" -ne 0 ]]; then return 1; fi
  out="$(head -n 1 "$CAPTURE")"
  # Match against THIS repo's registration directory, not any path containing
  # "/worktrees/". Under --root the caller can be standing in an unrelated
  # repo, and two repos can hold same-named entries (ids are worktree
  # basenames) — matching on the bare id would then skip a genuinely orphaned
  # entry here because of a live worktree somewhere else.
  case "$out" in
    "$WORKTREE_REG_DIR"/*) CALLER_REG_ID="${out#"$WORKTREE_REG_DIR"/}" ;;
    *) CALLER_REG_ID="" ;;
  esac
  # Only a single-segment id is meaningful; anything else is not an entry name.
  case "$CALLER_REG_ID" in */*) CALLER_REG_ID="" ;; esac
  return 0
}

# A registration's `gitdir` holds one absolute path and `locked` one short
# reason line — both a few dozen bytes as git writes them. 4 KiB is the same
# headroom read_checkout_gitdir allows a checkout's `.git`, and anything past it
# is not one of these files.
REG_META_MAX_BYTES=4096

# Read a registration's `gitdir` file and report the worktree path it names.
# The registration-pass counterpart of read_checkout_gitdir, capped and
# symlink-refusing for the same reasons (#1592): this content is what decides
# whether an entry is an orphan, and that verdict ends in an `rm -rf`.
#
# Answer comes back in REGISTRATION_WORKTREE. Statement form only, never `$( )`
# — see read_bounded_line.
#
#   0 = read; REGISTRATION_WORKTREE holds the worktree path it names
#   1 = did not read inside the bound, or held nothing. This is the ordinary
#       unreadable-metadata orphan — precisely what stalls `git worktree list`
#       — and it stays a removal candidate, exactly as before.
#   2 = ANOMALOUS: `gitdir` is a symlink, or is far too large to be one of
#       these files. Neither is debris this pass cleans, and neither is a shape
#       we can vouch for, so it is never classified and never removed. Kept
#       distinct from 1 on purpose: collapsing it there would hand an entry we
#       cannot read for an unexplained reason straight to the deletion path.
REGISTRATION_WORKTREE=""
read_registration_gitdir() { # registration path
  local line=""
  REGISTRATION_WORKTREE=""
  # Refused BEFORE the read, which follows links: git writes `gitdir` as a
  # plain file, and we cannot vouch for what a link planted here points at.
  # Same order, and same argument, as read_checkout_gitdir's `.git` test.
  [[ -L "$1/gitdir" ]] && return 2
  if ! read_bounded_line "$1/gitdir" "$REG_META_MAX_BYTES"; then
    if (( BOUNDED_OVERFLOW == 1 )); then return 2; fi
    return 1
  fi
  line="$BOUNDED_LINE"
  [[ -n "$line" ]] || return 1
  # git writes an absolute path by default, but `worktree add --relative-paths`
  # (git >= 2.48) writes one relative to THIS registration directory. Anchor it
  # here, exactly as read_checkout_gitdir anchors a checkout's (#1597): left
  # relative, the path is probed against whatever cwd the caller happened to
  # have, so a live `--relative-paths` worktree reads as absent and its
  # registration goes to the deletion path — and the same content classifies
  # differently from one invocation to the next. Anchoring also keeps content
  # we cannot vouch for inside the registry instead of resolving it against an
  # unrelated tree.
  case "$line" in
    /*) ;;
    *) line="$1/$line" ;;
  esac
  # `gitdir` holds the path of the worktree's own .git file.
  REGISTRATION_WORKTREE="${line%/.git}"
  [[ -n "$REGISTRATION_WORKTREE" ]] || return 1
  return 0
}

# Each entry: id US reg_path US worktree_path US reason US method
#   method: prune    — `git worktree prune` can and should remove it
#           targeted — git would hang or refuse; remove the directory directly
ORPHANED_REGISTRATIONS=()
SKIPPED_REGISTRATIONS=()   # id US reason

scan_registrations() {
  if ! resolve_common_dir; then
    REG_SCAN_STATE="unavailable"
    echo "warning: could not resolve the git common dir within ${GIT_BOUND_SECS}s — worktree registrations were not scanned" >&2
    return
  fi
  WORKTREE_REG_DIR="$GIT_COMMON_DIR/worktrees"
  if [[ ! -d "$WORKTREE_REG_DIR" ]]; then
    REG_SCAN_STATE="none"   # no linked worktree has ever been created here
    return
  fi
  resolve_caller_reg_id || true

  local reg id locked_marker=0 lock_reason="" wt="" reason="" method=""
  local gd_rc=0 probe_rc=0
  for reg in "$WORKTREE_REG_DIR"/*; do
    id="${reg##*/}"
    if [[ -n "$CALLER_REG_ID" && "$id" == "$CALLER_REG_ID" ]]; then
      SKIPPED_REGISTRATIONS+=("${id}${US}caller's own worktree registration")
      continue
    fi
    # `-L` FIRST, before anything that follows links — the same order
    # scan_checkouts uses on its entries (#1592). `-d` traverses, so testing it
    # first both walks a link into a stalled or evicted volume and silently
    # DROPS a dangling registration symlink, whose `-d` is false, instead of
    # recording it. A RESOLVING one is no better off classified: it is exactly
    # what remove_registration refuses at the rm as "not a plain directory", so
    # classifying it here only to hard-fail there — raising exit 2 on a sweep
    # that removed everything it could — is worse than declining it now.
    if [[ -L "$reg" ]]; then
      SKIPPED_REGISTRATIONS+=("${id}${US}registration entry is a symlink — never classified, never removed")
      continue
    fi
    # Left UNBOUNDED on purpose, unlike the matching test in scan_checkouts:
    # BOUNDED READS above records why these particular stat probes need no
    # wrapper — they hit the local repo's own .git, whose metadata is never
    # `dataless`, and forking twice per entry would still leave the enclosing
    # glob unbounded. scan_checkouts bounds its own because those entries are
    # arbitrary working trees that really can sit on a stalled mount.
    [[ -d "$reg" ]] || continue

    # Presence of `locked` is pure metadata — no content read, so it cannot
    # stall. The reason text is a bounded read and may legitimately be empty.
    locked_marker=0
    lock_reason=""
    if [[ -f "$reg/locked" ]]; then
      locked_marker=1
      # Never READ through a symlinked marker (#1597 review). The cap below
      # bounds how much of a file reaches stdout; it does not bound WHICH file,
      # and read_bounded_line follows links. This text is echoed into the report
      # and into --json, so `locked -> ~/.ssh/id_rsa` would publish that file's
      # first line. Refused here rather than in read_bounded_line, which has
      # legitimate callers that do resolve links, and matching the `-L` refusal
      # read_registration_gitdir already applies to `gitdir` for the same
      # can-not-vouch-for-it reason.
      #
      # Deliberately narrower than that one: `gitdir` returns rc 2 and declines
      # the entry, because its CONTENT decides whether the entry is an orphan.
      # This marker's PRESENCE is what gates the skip and its text is only ever
      # displayed, so the entry stays locked and merely goes unnamed. The `-f`
      # test still gates the marker, so a dangling `locked` link continues to
      # read as "not locked" exactly as before — that case is unchanged.
      if [[ -L "$reg/locked" ]]; then
        lock_reason="reason not shown — the locked marker is a symlink and was not read through"
      else
        # Called as a statement, never inside `$(...)` — see read_bounded_line.
        # Capped like `gitdir` (#1592): an implausibly large `locked` would be
        # copied whole into a temp file and then a shell variable on its way to
        # stdout. On overflow BOUNDED_LINE is empty and the reason simply goes
        # unnamed — again, never a removal decision.
        read_bounded_line "$reg/locked" "$REG_META_MAX_BYTES" 2>/dev/null || true
        lock_reason="$BOUNDED_LINE"
      fi
    fi

    reason=""
    method=""
    wt=""
    gd_rc=0
    read_registration_gitdir "$reg" || gd_rc=$?
    if (( gd_rc == 2 )); then
      # Anomalous metadata is not the unreadable-orphan state below: we cannot
      # say what this entry is, so we do not offer it for deletion.
      SKIPPED_REGISTRATIONS+=("${id}${US}gitdir metadata is a symlink or larger than ${REG_META_MAX_BYTES} bytes — not one of these files; absence not established, leaving the registration alone")
      continue
    fi
    if (( gd_rc != 0 )); then
      # We cannot prove the worktree is gone — only that git cannot read this
      # entry either, which is precisely what stalls `git worktree list`.
      reason="unreadable — prunable with warning (metadata did not read within ${READ_BOUND_SECS}s)"
      method="targeted"
    else
      wt="$REGISTRATION_WORKTREE"
      probe_rc=0
      path_exists_bounded "$wt" || probe_rc=$?
      if (( probe_rc == 0 )); then
        continue   # live entry — never reported, never touched
      elif (( probe_rc == 2 )); then
        reason="unreadable — prunable with warning (existence probe on $wt did not finish within ${READ_BOUND_SECS}s)"
        method="targeted"
      elif (( probe_rc == 3 )); then
        # Not observed, but absence was not established — the parent could not
        # be searched. A live worktree behind an unreadable directory looks
        # exactly like a missing one here, so this is the one probe outcome
        # that must not become a removal candidate.
        SKIPPED_REGISTRATIONS+=("${id}${US}worktree path $wt could not be inspected (its nearest existing parent is not searchable) — absence not established, leaving the registration alone")
        continue
      else
        # probe_rc == 1, "provably absent" — but `test -e` FOLLOWS symlinks, so
        # a dangling link lands here too, and a link is a present entry
        # somebody put there. Checked over every component, not just the leaf
        # (#1592): a `worktrees -> /Volumes/archive/...` ancestor on an
        # unmounted volume reads as absent for EVERY entry beneath it, so a
        # leaf-only test would clear a whole shelf of live registrations at
        # once. Refused here rather than inside path_exists_bounded, which the
        # checkout pass shares and where a missing target legitimately IS the
        # debris being cleaned.
        #
        # Scope, shared with the "parent not searchable" skip above and with it
        # predating this change: `git worktree prune` is all-or-nothing across
        # the registry, so a run that prunes for some OTHER entry still applies
        # git's own rule — a bare stat, which follows symlinks — to this one.
        # What this script owns is what it reports and what it deletes itself,
        # and on that path registration_is_live closes the same hole
        # immediately before the rm.
        # Either way the entry is left alone — but say WHICH, because the two
        # ask different things of an operator (#1597 review). A dangling link is
        # something to look at; a walk that stalled inside the bound is the
        # unreadable-metadata case, and reporting it as an ordinary symlink skip
        # would describe a path state this run never established.
        if path_has_dangling_link_component "$wt"; then
          if (( DANGLING_PROBE_INCONCLUSIVE == 1 )); then
            SKIPPED_REGISTRATIONS+=("${id}${US}worktree path $wt could not be inspected (a symlink probe along it did not finish within ${READ_BOUND_SECS}s) — absence not established, leaving the registration alone")
          else
            SKIPPED_REGISTRATIONS+=("${id}${US}worktree path $wt is or sits under a dangling symlink — a present entry whose target may return; absence not established, leaving the registration alone")
          fi
          continue
        fi
        reason="worktree directory missing ($wt)"
        method="prune"
      fi
    fi

    if (( locked_marker == 1 )); then
      # A lock on an entry whose worktree is gone protects nothing real, but
      # clearing it is still an explicit opt-in: `locked` is the operator's own
      # "do not prune" marker, and `git worktree prune` refuses it by design.
      if (( INCLUDE_LOCKED == 0 )); then
        SKIPPED_REGISTRATIONS+=("${id}${US}locked${lock_reason:+ ($lock_reason)} — pass --include-locked to clear it")
        continue
      fi
      reason="$reason; locked${lock_reason:+ ($lock_reason)}, cleared via --include-locked"
      method="targeted"   # git worktree prune refuses locked entries
    fi

    ORPHANED_REGISTRATIONS+=("${id}${US}${reg}${US}${wt}${US}${reason}${US}${method}")
  done
}

scan_registrations

# --- Orphaned worktree checkouts (issue #1417) -------------------------------
# The inverse of the pass above: a checkout on disk whose registration is gone.
# Enumerated by listing the checkout directory — a readdir against the local
# repo, which never blocks, for the same reason the registration glob does not
# (see BOUNDED READS). Everything that comes OUT of an entry and is therefore
# arbitrary — the `.git` file's content and the path it names — is bounded.
#
# This pass classifies only; removal lives behind --remove-orphaned-checkouts,
# well after --apply's other deletions. See ORPHANED WORKTREE CHECKOUTS above
# for why the gate is separate and why this class never moves the exit code.

CHECKOUT_DIR=""
CHECKOUT_SCAN_STATE="ok"       # ok | none | unreadable
ORPHANED_CHECKOUTS=()          # path US gitdir_target US reason
SKIPPED_CHECKOUTS=()           # path US reason

# Canonicalize for comparison, resolving symlinks the way caller_in_worktree
# does — /tmp vs /private/tmp on macOS is enough to make two spellings of one
# directory look like two directories.
#
# The `cd` runs through run_bounded rather than plainly: this pass calls it on
# every registered worktree path, and a single stalled mount among them would
# hang the whole sweep — the exact failure lib/bounded-run.sh exists to prevent
# (issues #1363, #1404). A plain `cd` here would have been the one unbounded
# filesystem call left in the sweep.
#
# Answer comes back in CANONICAL_PATH. Return 1 means the path could not be
# resolved inside the bound, and CANONICAL_PATH then holds the input unchanged
# (the same fallback the plain form had) — callers that gate a deletion on the
# resolved spelling must treat that as "could not verify", not as an answer.
# Statement form only, never `$( )`: run_bounded returns its child's stdout
# through $CAPTURE (see read_bounded_line).
_canonical_path_probe() { cd -- "$1" 2>/dev/null && pwd -P; }
CANONICAL_PATH=""
canonical_path() { # path
  local rc=0 out=""
  CANONICAL_PATH="$1"
  run_bounded "$READ_BOUND_SECS" _canonical_path_probe "$1" || rc=$?
  if [[ "$BOUNDED_TIMED_OUT" -eq 1 ]] || (( rc != 0 )); then return 1; fi
  out="$(head -n 1 "$CAPTURE" 2>/dev/null || true)"
  [[ -n "$out" ]] || return 1
  CANONICAL_PATH="$out"
  return 0
}

# Read a checkout's `.git` file and report the registration path it names.
# Answer comes back in CHECKOUT_GITDIR; return 1 means the file did not read
# inside the bound, carried no `gitdir:` line, or is a symlink — none of which
# is ever classified. Statement form only, never `$( )` — see read_bounded_line.
CHECKOUT_GITDIR=""
read_checkout_gitdir() { # checkout dir
  local line=""
  CHECKOUT_GITDIR=""
  # A symlinked `.git` is refused HERE rather than only at the scan, so the
  # pre-rm re-check inherits the refusal: `-f` follows symlinks, so without
  # this a `.git` swapped for a link to an arbitrary file would read as an
  # ordinary checkout. We cannot vouch for what such a link points at, and
  # this path gates deleting a working tree.
  [[ -L "$1/.git" ]] && return 1
  # Capped: a worktree's `.git` is a single ~100-byte line, so 4 KiB is ample
  # headroom, and anything past it is not one of these files. Uncapped, a
  # planted `.git` would be copied whole into a temp file and a shell variable
  # by a pass that then decides whether to delete a working tree.
  read_bounded_line "$1/.git" 4096 || return 1
  line="$BOUNDED_LINE"
  case "$line" in
    "gitdir: "*) line="${line#gitdir: }" ;;
    *) return 1 ;;
  esac
  [[ -n "$line" ]] || return 1
  # git writes an absolute path by default, but `worktree add --relative-paths`
  # (git >= 2.48) writes one relative to the checkout itself.
  case "$line" in
    /*) ;;
    *) line="$1/$line" ;;
  esac
  CHECKOUT_GITDIR="$line"
  return 0
}

scan_checkouts() {
  # Resolved BEFORE the wide-path guard below, and kept in resolved form: the
  # guard has to reject what the path RESOLVES to, not how it was spelled. A
  # symlink pointing at `/` sails straight past a literal "/" comparison and
  # would hand every top-level directory to remove_checkout. Canonicalizing
  # here also keeps every path this pass reports, compares, and removes in one
  # spelling — /tmp and /private/var are the same directory on macOS, and the
  # `$CHECKOUT_DIR/$name` containment check in remove_checkout is exact.
  local raw_dir="${STALE_CLEANUP_CHECKOUT_DIR:-$ROOT/.claude/worktrees}"
  local scan_rc=0 root_canon=""

  # Existence is settled BEFORE canonicalizing, because the two failures look
  # identical from `cd`: a directory that is not there and a directory we were
  # not allowed to enter both fail. Only the first is "this repo keeps no
  # worktrees here".
  path_exists_bounded "$raw_dir" || scan_rc=$?
  case "$scan_rc" in
    1) # `test -e` follows links, so a DANGLING scan directory lands here too.
       # The name is still a present entry whose target may return — the same
       # detachable-volume argument this pass already applies to gitdir targets
       # — so it is "could not look", not "there is nothing there".
       if path_has_dangling_link_component "$raw_dir"; then
         CHECKOUT_SCAN_STATE="unreadable"
         SKIPPED_CHECKOUTS+=("${raw_dir}${US}scan directory is or sits under a dangling symlink — a present entry whose target may return; absence not established")
         return
       fi
       CHECKOUT_SCAN_STATE="none"   # provably absent
       return ;;
    0) : ;;
    *) # Probe stalled (2) or absence was not provable (3) — e.g. an
       # unsearchable parent, or the macOS TCC block that retired the old
       # checkout. Reporting "none" here would be a positive claim of absence
       # drawn from a lookup that never happened, which is the one thing a pass
       # that deletes working trees must never do.
       CHECKOUT_SCAN_STATE="unreadable"
       SKIPPED_CHECKOUTS+=("${raw_dir}${US}scan directory could not be inspected (existence probe rc=$scan_rc) — nothing was classified; absence not established")
       return ;;
  esac

  if ! canonical_path "$raw_dir"; then
    # The wide-path guard below has to reject what the path RESOLVES to, so an
    # unresolved path cannot be cleared for this pass at all.
    CHECKOUT_SCAN_STATE="unreadable"
    SKIPPED_CHECKOUTS+=("${raw_dir}${US}scan directory could not be resolved within ${READ_BOUND_SECS}s — nothing was classified; absence not established")
    return
  fi
  CHECKOUT_DIR="$CANONICAL_PATH"

  # Applied to the default too, not just the override: `.claude/worktrees`
  # could itself be a symlink. A scan dir this wide would make every top-level
  # directory a candidate for the one flag that deletes working trees, so
  # refuse rather than narrow silently.
  canonical_path "$ROOT" || true
  root_canon="$CANONICAL_PATH"
  if [[ "$CHECKOUT_DIR" == "/" || "$CHECKOUT_DIR" == "$root_canon" ]]; then
    usage_error "the orphaned-checkout scan directory must not resolve to / or the repo root itself (resolved: $CHECKOUT_DIR${STALE_CLEANUP_CHECKOUT_DIR:+, from STALE_CLEANUP_CHECKOUT_DIR=$STALE_CLEANUP_CHECKOUT_DIR})"
  fi

  # Present, resolved, and now confirmed enterable. A path that exists but is
  # not a searchable directory would make the glob below expand to nothing,
  # which is indistinguishable from an empty directory.
  local dir_rc=0
  run_bounded "$READ_BOUND_SECS" test -d "$CHECKOUT_DIR" || dir_rc=$?
  if [[ "$BOUNDED_TIMED_OUT" -eq 1 ]] || (( dir_rc != 0 )); then
    CHECKOUT_SCAN_STATE="unreadable"
    SKIPPED_CHECKOUTS+=("${CHECKOUT_DIR}${US}scan directory is not a readable directory — nothing was classified; absence not established")
    return
  fi

  # Paths git still reports. Belt-and-braces only: a registered worktree's
  # gitdir target exists, so the probe below already declines it. This can
  # only ever REMOVE a candidate, never add one — and it is empty when the
  # enumeration degraded, which the probe then covers on its own.
  local registered="" record wtp
  if (( ${#WORKTREES[@]} > 0 )); then
    for record in "${WORKTREES[@]}"; do
      IFS="$US" read -r _ wtp _ _ <<<"$record"
      [[ -n "$wtp" ]] || continue
      canonical_path "$wtp" || true
      registered="${registered}${CANONICAL_PATH}"$'\n'
    done
  fi

  local dir target probe_rc canon dir_rc
  for dir in "$CHECKOUT_DIR"/*; do
    # `-L` FIRST, before anything that follows links — the same order
    # read_checkout_gitdir uses on `.git`, and for the same reason. `-d`
    # traverses, so testing it first walks a link into a stalled or evicted
    # volume (the hang this sweep exists to avoid) and silently DROPS a
    # dangling directory symlink, whose `-d` is false, instead of recording it.
    if [[ -L "$dir" ]]; then
      SKIPPED_CHECKOUTS+=("${dir}${US}symlink — never classified as a checkout, never removed")
      continue
    fi
    # Bounded: a directory entry can still be a mountpoint, and this one runs
    # before every guard that decides whether a working tree may be deleted.
    dir_rc=0
    run_bounded "$READ_BOUND_SECS" test -d "$dir" || dir_rc=$?
    if [[ "$BOUNDED_TIMED_OUT" -eq 1 ]]; then
      SKIPPED_CHECKOUTS+=("${dir}${US}could not be inspected within ${READ_BOUND_SECS}s — absence not established")
      continue
    fi
    (( dir_rc == 0 )) || continue
    if caller_in_worktree "$dir"; then
      SKIPPED_CHECKOUTS+=("${dir}${US}caller's current worktree")
      continue
    fi
    # Probed BEFORE the -d/-f tests, which both follow symlinks: a `.git`
    # symlink would otherwise read as an ordinary checkout file. Reported
    # rather than skipped silently — it is anomalous enough to want seen.
    if [[ -L "$dir/.git" ]]; then
      SKIPPED_CHECKOUTS+=("${dir}${US}.git is a symlink — never classified as a checkout, never removed")
      continue
    fi
    # A `.git` DIRECTORY is a nested standalone clone; no `.git` at all is not
    # a checkout. Neither is this class, and this directory may legitimately
    # hold either, so neither is reported.
    [[ -d "$dir/.git" ]] && continue
    [[ -f "$dir/.git" ]] || continue

    if ! read_checkout_gitdir "$dir"; then
      SKIPPED_CHECKOUTS+=("${dir}${US}.git yielded no gitdir target within ${READ_BOUND_SECS}s — cannot establish that its registration is missing")
      continue
    fi
    target="$CHECKOUT_GITDIR"

    probe_rc=0
    path_exists_bounded "$target" || probe_rc=$?
    if (( probe_rc == 0 )); then
      continue   # registration present — an ordinary linked checkout
    elif (( probe_rc == 2 )); then
      SKIPPED_CHECKOUTS+=("${dir}${US}existence probe on $target did not finish within ${READ_BOUND_SECS}s — absence not established")
      continue
    elif (( probe_rc == 3 )); then
      SKIPPED_CHECKOUTS+=("${dir}${US}registration path $target could not be inspected (its nearest existing parent is not searchable) — absence not established")
      continue
    fi
    # probe_rc == 1, "provably absent" — but `test -e` FOLLOWS symlinks, so a
    # dangling link lands here too, and a link is a present entry somebody put
    # there. The 2026-08-26 mitigation moved registrations aside; a link into a
    # quarantine on an unmounted volume dangles exactly like this, and its
    # target can come back. For a pass that deletes working trees that reads as
    # "could not verify", not "gone". Refused here rather than inside
    # path_exists_bounded, which the registration pass shares and where a
    # missing target legitimately IS the debris being cleaned.
    #
    # Checked over every component, not just the final one: under a
    # `worktrees -> /Volumes/archive/...` link on an unmounted volume, lstat
    # cannot see the final component at all, so a final-component-only `-L`
    # reads FALSE and hands the checkout to removal — the same detachable-
    # volume case, one level up.
    if path_has_dangling_link_component "$target"; then
      SKIPPED_CHECKOUTS+=("${dir}${US}registration $target is or sits under a dangling symlink — a present entry whose target may return; absence not established")
      continue
    fi

    canonical_path "$dir" || true
    canon="$CANONICAL_PATH"
    if [[ -n "$registered" ]] && grep -Fxq "$canon" <<<"$registered"; then
      SKIPPED_CHECKOUTS+=("${dir}${US}still listed by 'git worktree list' despite a missing gitdir target — repair with 'git worktree repair', never remove")
      continue
    fi

    ORPHANED_CHECKOUTS+=("${dir}${US}${target}${US}registration missing ($target) — repair with 'git worktree repair' or remove with --remove-orphaned-checkouts")
  done
}

scan_checkouts

ts_to_date() {
  # Portable across BSD/GNU date: read a unix ts, emit YYYY-MM-DD.
  #
  # GNU is tried FIRST deliberately, and the order is load-bearing: GNU `date -r`
  # reads its argument as a FILE and prints that file's mtime, so a BSD-first chain
  # silently renders the wrong date whenever a file happens to be named for the
  # epoch. Both arms stay — GNU alone strands macOS, BSD alone strands GNU
  # (issue #1587; same class as issue #1529).
  local ts="$1"
  if date -d "@$ts" +%Y-%m-%d 2>/dev/null; then return; fi
  date -r "$ts" +%Y-%m-%d 2>/dev/null || echo "?"
}

emit_text() {
  echo "Stale threshold: ${STALE_DAYS} days (commits before $(ts_to_date "$THRESHOLD"))"
  echo
  if (( ${#STALE_WORKTREES[@]} == 0 )); then
    echo "Stale worktrees: none"
  else
    echo "Stale worktrees:"
    for entry in "${STALE_WORKTREES[@]}"; do
      IFS="$US" read -r p b t <<<"$entry"
      printf '  %s (branch %s, last commit %s)\n' "$p" "${b:-detached}" "$(ts_to_date "$t")"
    done
  fi
  if (( ${#STALE_LOCAL_BRANCHES[@]} == 0 )); then
    echo "Stale local branches: none"
  else
    echo "Stale local branches:"
    for entry in "${STALE_LOCAL_BRANCHES[@]}"; do
      IFS="$US" read -r b t <<<"$entry"
      printf '  %s (last commit %s)\n' "$b" "$(ts_to_date "$t")"
    done
  fi
  if (( ${#STALE_REMOTE_BRANCHES[@]} == 0 )); then
    echo "Stale remote branches: none"
  else
    echo "Stale remote branches:"
    for entry in "${STALE_REMOTE_BRANCHES[@]}"; do
      IFS="$US" read -r r t <<<"$entry"
      printf '  %s (last commit %s)\n' "$r" "$(ts_to_date "$t")"
    done
  fi
  if (( ${#ORPHANED_REGISTRATIONS[@]} == 0 )); then
    echo "Orphaned worktree registrations: none"
  else
    echo "Orphaned worktree registrations:"
    for entry in "${ORPHANED_REGISTRATIONS[@]}"; do
      IFS="$US" read -r rid _ _ rreason rmethod <<<"$entry"
      printf '  %s — %s [%s]\n' "$rid" "$rreason" "$rmethod"
    done
  fi
  if (( ${#ORPHANED_CHECKOUTS[@]} == 0 )); then
    echo "Orphaned worktree checkouts: none"
  else
    echo "Orphaned worktree checkouts (report-only — needs --remove-orphaned-checkouts):"
    for entry in "${ORPHANED_CHECKOUTS[@]}"; do
      IFS="$US" read -r cpath _ creason <<<"$entry"
      printf '  %s — %s\n' "$cpath" "$creason"
    done
  fi
  if [[ "$WORKTREE_ENUM_STATE" != "ok" ]]; then
    echo
    echo "WARNING: worktree enumeration $WORKTREE_ENUM_STATE — worktrees and local branches were NOT classified in this run."
    echo "         Clear the registrations above with --apply, then re-run."
  fi
  if [[ "$REG_SCAN_STATE" == "unavailable" ]]; then
    echo
    echo "WARNING: worktree registrations were not scanned (git common dir unresolved within ${GIT_BOUND_SECS}s)."
  fi
  if [[ "$REF_SCAN_STATE" != "ok" ]]; then
    echo
    echo "WARNING: ref enumeration $REF_SCAN_STATE — branches were NOT classified in this run."
  fi
  if [[ "$CHECKOUT_SCAN_STATE" == "unreadable" ]]; then
    echo
    echo "WARNING: the orphaned-checkout scan directory could not be read — checkouts were NOT classified in this run."
    echo "         'Orphaned worktree checkouts: none' above means nothing was classified, not that nothing is orphaned."
  fi
  local skipped_total=$(( ${#SKIPPED_WORKTREES[@]} + ${#SKIPPED_LOCAL_BRANCHES[@]} + ${#SKIPPED_REMOTE_BRANCHES[@]} + ${#SKIPPED_REGISTRATIONS[@]} + ${#SKIPPED_CHECKOUTS[@]} ))
  if (( skipped_total > 0 )); then
    echo
    echo "Skipped (safety):"
    # Per-array guards: under bash 3.2 + set -u, expanding "${ARR[@]}" on
    # an empty array crashes — even when at least one of the three has
    # items. Same pattern used by --apply and emit_json.
    if (( ${#SKIPPED_WORKTREES[@]} > 0 )); then
      for entry in "${SKIPPED_WORKTREES[@]}"; do
        IFS="$US" read -r p reason <<<"$entry"
        printf '  worktree %s — %s\n' "$p" "$reason"
      done
    fi
    if (( ${#SKIPPED_LOCAL_BRANCHES[@]} > 0 )); then
      for entry in "${SKIPPED_LOCAL_BRANCHES[@]}"; do
        IFS="$US" read -r b reason <<<"$entry"
        printf '  branch %s — %s\n' "$b" "$reason"
      done
    fi
    if (( ${#SKIPPED_REMOTE_BRANCHES[@]} > 0 )); then
      for entry in "${SKIPPED_REMOTE_BRANCHES[@]}"; do
        IFS="$US" read -r r reason <<<"$entry"
        printf '  remote %s — %s\n' "$r" "$reason"
      done
    fi
    if (( ${#SKIPPED_REGISTRATIONS[@]} > 0 )); then
      for entry in "${SKIPPED_REGISTRATIONS[@]}"; do
        IFS="$US" read -r rid reason <<<"$entry"
        printf '  registration %s — %s\n' "$rid" "$reason"
      done
    fi
    if (( ${#SKIPPED_CHECKOUTS[@]} > 0 )); then
      for entry in "${SKIPPED_CHECKOUTS[@]}"; do
        IFS="$US" read -r cpath reason <<<"$entry"
        printf '  checkout %s — %s\n' "$cpath" "$reason"
      done
    fi
  fi
}

emit_json() {
  local wt_json="[]" lb_json="[]" rb_json="[]"
  local sw_json="[]" sl_json="[]" sr_json="[]"
  if (( ${#STALE_WORKTREES[@]} > 0 )); then
    wt_json="$(printf '%s\n' "${STALE_WORKTREES[@]}" \
      | jq -Rn --arg D "$US" '[inputs | split($D) | {path:.[0], branch:.[1], last_commit_ts:(.[2]|tonumber)}]')"
  fi
  if (( ${#STALE_LOCAL_BRANCHES[@]} > 0 )); then
    lb_json="$(printf '%s\n' "${STALE_LOCAL_BRANCHES[@]}" \
      | jq -Rn --arg D "$US" '[inputs | split($D) | {branch:.[0], last_commit_ts:(.[1]|tonumber)}]')"
  fi
  if (( ${#STALE_REMOTE_BRANCHES[@]} > 0 )); then
    rb_json="$(printf '%s\n' "${STALE_REMOTE_BRANCHES[@]}" \
      | jq -Rn --arg D "$US" '[inputs | split($D) | {ref:.[0], last_commit_ts:(.[1]|tonumber)}]')"
  fi
  if (( ${#SKIPPED_WORKTREES[@]} > 0 )); then
    sw_json="$(printf '%s\n' "${SKIPPED_WORKTREES[@]}" \
      | jq -Rn --arg D "$US" '[inputs | split($D) | {path:.[0], reason:.[1]}]')"
  fi
  if (( ${#SKIPPED_LOCAL_BRANCHES[@]} > 0 )); then
    sl_json="$(printf '%s\n' "${SKIPPED_LOCAL_BRANCHES[@]}" \
      | jq -Rn --arg D "$US" '[inputs | split($D) | {branch:.[0], reason:.[1]}]')"
  fi
  if (( ${#SKIPPED_REMOTE_BRANCHES[@]} > 0 )); then
    sr_json="$(printf '%s\n' "${SKIPPED_REMOTE_BRANCHES[@]}" \
      | jq -Rn --arg D "$US" '[inputs | split($D) | {ref:.[0], reason:.[1]}]')"
  fi
  local or_json="[]" sg_json="[]"
  if (( ${#ORPHANED_REGISTRATIONS[@]} > 0 )); then
    or_json="$(printf '%s\n' "${ORPHANED_REGISTRATIONS[@]}" \
      | jq -Rn --arg D "$US" '[inputs | split($D)
          | {id:.[0], registration_path:.[1], worktree_path:.[2], reason:.[3], method:.[4]}]')"
  fi
  if (( ${#SKIPPED_REGISTRATIONS[@]} > 0 )); then
    sg_json="$(printf '%s\n' "${SKIPPED_REGISTRATIONS[@]}" \
      | jq -Rn --arg D "$US" '[inputs | split($D) | {id:.[0], reason:.[1]}]')"
  fi
  local oc_json="[]" sc_json="[]"
  if (( ${#ORPHANED_CHECKOUTS[@]} > 0 )); then
    oc_json="$(printf '%s\n' "${ORPHANED_CHECKOUTS[@]}" \
      | jq -Rn --arg D "$US" '[inputs | split($D) | {path:.[0], gitdir:.[1], reason:.[2]}]')"
  fi
  if (( ${#SKIPPED_CHECKOUTS[@]} > 0 )); then
    sc_json="$(printf '%s\n' "${SKIPPED_CHECKOUTS[@]}" \
      | jq -Rn --arg D "$US" '[inputs | split($D) | {path:.[0], reason:.[1]}]')"
  fi
  jq -n --argjson wt "$wt_json" --argjson lb "$lb_json" --argjson rb "$rb_json" \
        --argjson sw "$sw_json" --argjson sl "$sl_json" --argjson sr "$sr_json" \
        --argjson or "$or_json" --argjson sg "$sg_json" \
        --argjson oc "$oc_json" --argjson sc "$sc_json" \
        --arg threshold_days "$STALE_DAYS" \
        --arg threshold_ts "$THRESHOLD" \
        --arg root "$ROOT" \
        --arg enum_state "$WORKTREE_ENUM_STATE" \
        --arg reg_scan "$REG_SCAN_STATE" \
        --arg ref_scan "$REF_SCAN_STATE" \
        --arg checkout_scan "$CHECKOUT_SCAN_STATE" \
        '{root:$root,
          stale_days:($threshold_days|tonumber),
          threshold_ts:($threshold_ts|tonumber),
          stale_worktrees:$wt,
          stale_local_branches:$lb,
          stale_remote_branches:$rb,
          skipped_worktrees:$sw,
          skipped_local_branches:$sl,
          skipped_remote_branches:$sr,
          orphaned_registrations:$or,
          skipped_registrations:$sg,
          orphaned_checkouts:$oc,
          skipped_checkouts:$sc,
          worktree_enumeration:$enum_state,
          registration_scan:$reg_scan,
          ref_scan:$ref_scan,
          checkout_scan:$checkout_scan}'
}

if [[ "$MODE" == "check" ]]; then
  if (( JSON == 1 )); then emit_json; else emit_text; fi
  total=$(( ${#STALE_WORKTREES[@]} + ${#STALE_LOCAL_BRANCHES[@]} + ${#STALE_REMOTE_BRANCHES[@]} \
            + ${#ORPHANED_REGISTRATIONS[@]} ))
  if (( total > 0 )); then exit 1; fi
  # A sweep that could not classify is a finding, not a clean bill of health:
  # exiting 0 here would tell the caller "nothing stale" about a repo we never
  # managed to read.
  if [[ "$WORKTREE_ENUM_STATE" != "ok" || "$REG_SCAN_STATE" == "unavailable" \
        || "$REF_SCAN_STATE" != "ok" ]]; then exit 1; fi
  exit 0
fi

# --apply: delete each stale item, recording outcomes.
FAILURES=0
emit_text
echo

# Registrations go first. Targeted removals clear the entries `git worktree
# prune` would stall on, so the prune that follows — and every `git worktree
# remove` in the worktree loop below — reads a registry it can actually parse.
# Does a live worktree stand behind this registration *right now*? Answers the
# question scan_registrations asked, but at removal time. Only the affirmative
# is trusted: a gitdir that reads AND names a path that exists. An unreadable
# gitdir and a still-missing worktree both answer "not live", because those are
# exactly the states that made the entry an orphan in the first place.
#
#   0 = live — the worktree is back, or was never provably gone
#   1 = not live — the orphan state that permits removal
#   3 = neither (#1592). The entry's own metadata is anomalous, or its worktree
#       path is (or sits under) a dangling symlink. Not "live", but absence is
#       not established either, so the removal must not proceed. Distinct from
#       0 only so the caller can say which of the two it is; the post-`prune`
#       reporting caller that reads this as a boolean sees "not reappeared" for
#       it, which is what that branch already reported for these entries.
registration_is_live() { # registration path
  local wt="" probe_rc=0 gd_rc=0
  # Statement form, not `$(...)` — see read_bounded_line.
  read_registration_gitdir "$1" || gd_rc=$?
  if (( gd_rc == 2 )); then return 3; fi
  if (( gd_rc != 0 )); then return 1; fi
  wt="$REGISTRATION_WORKTREE"
  path_exists_bounded "$wt" || probe_rc=$?
  # Fail closed, unlike the classification pass: this gate stands immediately
  # before an rm, so "exists" (0) and "cannot establish absence" (3) both stop
  # it. Only proven absence (1) and the stalled probe (2) — the very symptom
  # being cleaned — let the removal through.
  case "$probe_rc" in
    0|3) return 0 ;;
    2)   return 1 ;;
  esac
  # probe_rc == 1, provably absent — but `test -e` FOLLOWS symlinks, so the same
  # whole-path dangling-link refusal the scan applies runs here too, over every
  # component rather than the leaf.
  #
  # Ordered probe-then-walk, matching scan_registrations and
  # checkout_still_orphaned (#1597 review). The walk was first, which left a
  # wider window than necessary: a component that RESOLVED during the walk and
  # dangled before the probe was read as proven absence and removed. Running the
  # walk last puts it as close to the `rm` as this script can get, so a link that
  # dangles late is still caught — which is what this re-check exists for, the
  # scan having run at start-up. The window is narrowed, not closed: any
  # check-then-act in shell has one, and no atomic "verify and remove" primitive
  # is available. What is at stake on losing the race is the registration
  # directory, not the worktree, and `git worktree repair <path>` restores it.
  #
  # Only an OBSERVED dangling component refuses. A walk that merely stalled
  # returns 0 too, and reading that as a refusal broke the targeted-removal case
  # this script was written for (#1597 review): a readable `gitdir` naming a
  # still-stalled worktree path is classified "unreadable — prunable with
  # warning" by the scan, and rc 2 above deliberately lets that through as "the
  # very symptom being cleaned". A stall here, after the probe already proved
  # absence, is that same symptom and stays removable.
  if path_has_dangling_link_component "$wt" && (( DANGLING_PROBE_INCONCLUSIVE == 0 )); then
    return 3
  fi
  return 1
}

# Returns 0 removed, 1 failed, 2 skipped by the re-check (not a failure).
remove_registration() { # id, registration path
  local id="$1" target="$2" rc=0 live_rc=0
  # Path guards: only a single-segment id directly beneath the resolved
  # <git-common-dir>/worktrees, a real directory, never a symlink. Anything
  # else is refused rather than removed.
  #
  # The checkout path's "must not resolve to / or the repo root" width guard
  # has no analogue here (#1592 audit). $WORKTREE_REG_DIR is git's own answer
  # for <git-common-dir>/worktrees — never operator-supplied the way
  # STALE_CLEANUP_CHECKOUT_DIR is, and always at least one segment below the
  # common dir, so it cannot resolve to `/`. $target is the enumerating glob's
  # own spelling of "$WORKTREE_REG_DIR/$id", so the containment test below
  # compares two strings built from the same value and no alternative spelling
  # can slip past it; what it clears for removal is two segments below that.
  case "$id" in
    ''|.|..|*/*)
      echo "failed: worktree registration '$id' — refusing to remove: not a single-segment entry name"
      return 1
      ;;
  esac
  if [[ -z "$WORKTREE_REG_DIR" || "$target" != "$WORKTREE_REG_DIR/$id" ]]; then
    echo "failed: worktree registration $id — refusing to remove: $target is not directly beneath $WORKTREE_REG_DIR"
    return 1
  fi
  if [[ -L "$target" || ! -d "$target" ]]; then
    echo "failed: worktree registration $id — refusing to remove: not a plain directory"
    return 1
  fi
  # TOCTOU re-check, the same shape the remote-branch deletion below uses. The
  # scan that classified this entry ran before --apply, and callers dry-run
  # --check first and only then decide, so the gap is human-scale, not
  # instantaneous: an operator can re-materialize a quarantined checkout in
  # between — the documented recovery path in
  # .claude/reference/worktree-registration-quarantine-20260826.md. `git
  # worktree prune` re-reads the registry itself and so needs no equivalent;
  # this is the path that bypasses git, so it re-validates for itself.
  registration_is_live "$target" || live_rc=$?
  if (( live_rc == 0 )); then
    echo "skipped: worktree registration $id — its worktree reappeared after the scan; not removing"
    return 2
  fi
  if (( live_rc == 3 )); then
    # Neither live nor provably gone. Declined the same way — a skip, not a
    # failure — because refusing to delete something we cannot vouch for is the
    # guard working, exactly as remove_checkout treats its own re-check (#1592).
    echo "skipped: worktree registration $id — absence could not be re-established after the scan (its gitdir metadata is anomalous, or its worktree path is or sits under a dangling symlink); not removing"
    return 2
  fi
  run_bounded "$READ_BOUND_SECS" rm -rf -- "$target" || rc=$?
  if [[ "$BOUNDED_TIMED_OUT" -eq 1 ]]; then
    echo "failed: worktree registration $id — removal exceeded ${READ_BOUND_SECS}s and was killed"
    return 1
  fi
  if (( rc != 0 )) || [[ -e "$target" ]]; then
    echo "failed: worktree registration $id — $(head -n 1 "$CAPTURE_ERR" 2>/dev/null || echo "rm exited $rc")"
    return 1
  fi
  return 0
}

if (( ${#ORPHANED_REGISTRATIONS[@]} > 0 )); then
  PRUNE_WANTED=0
  for entry in "${ORPHANED_REGISTRATIONS[@]}"; do
    IFS="$US" read -r rid rpath _ _ rmethod <<<"$entry"
    if [[ "$rmethod" == "targeted" ]]; then
      RM_RC=0
      remove_registration "$rid" "$rpath" || RM_RC=$?
      if (( RM_RC == 0 )); then
        echo "removed: worktree registration $rid (targeted — git could not read or would refuse it)"
      elif (( RM_RC != 2 )); then
        # 2 is the re-check declining to remove a resurrected entry, which is
        # the guard working — it already said so, and it is not a failure.
        FAILURES=$(( FAILURES + 1 ))
      fi
    else
      PRUNE_WANTED=1
    fi
  done

  if (( PRUNE_WANTED == 1 )); then
    PRUNE_RC=0
    run_bounded "$GIT_BOUND_SECS" "${GIT[@]}" worktree prune || PRUNE_RC=$?
    if [[ "$BOUNDED_TIMED_OUT" -eq 1 ]]; then
      echo "failed: git worktree prune — exceeded ${GIT_BOUND_SECS}s and was killed"
    elif (( PRUNE_RC != 0 )); then
      echo "failed: git worktree prune — $(head -n 1 "$CAPTURE_ERR" 2>/dev/null || echo "exit $PRUNE_RC")"
    fi
    # Report per entry from the filesystem rather than from prune's exit code:
    # prune is all-or-nothing across the registry, so its status cannot say
    # which entries it actually cleared.
    for entry in "${ORPHANED_REGISTRATIONS[@]}"; do
      IFS="$US" read -r rid rpath _ _ rmethod <<<"$entry"
      [[ "$rmethod" == "prune" ]] || continue
      if [[ -e "$rpath" ]]; then
        if registration_is_live "$rpath"; then
          # prune did its job: the worktree came back between the scan and
          # here, so git correctly refused. Same non-failure as the targeted
          # re-check above — reporting it as a deletion failure would be wrong.
          echo "skipped: worktree registration $rid — its worktree reappeared after the scan; git worktree prune left it in place"
          continue
        fi
        echo "failed: worktree registration $rid — still present after git worktree prune"
        FAILURES=$(( FAILURES + 1 ))
      else
        echo "removed: worktree registration $rid (git worktree prune)"
      fi
    done
  fi
fi

# Empty-array guard: under `set -u`, expanding "${ARR[@]}" on an empty
# array errors with `unbound variable` on bash 3.2 (macOS system bash).
# Skip the loop entirely when the category has no stale items.
if (( ${#STALE_WORKTREES[@]} > 0 )); then
for entry in "${STALE_WORKTREES[@]}"; do
  IFS="$US" read -r p b _ <<<"$entry"
  # TOCTOU re-check: between classification (Phase --check) and apply, the
  # user may have started editing the worktree or opened a PR on its
  # branch. Re-run the same safety checks used during classification and
  # skip if anything has changed — losing user work to a stale dry-run is
  # a much bigger problem than skipping a deletion.
  if [[ -d "$p" ]]; then
    dirty_rc=0
    worktree_dirty_state "$p" || dirty_rc=$?
    if (( dirty_rc == 2 )); then
      echo "skipped: worktree $p (dirty re-check exceeded ${GIT_BOUND_SECS}s and was killed — not removing what we could not verify)"
      continue
    fi
    if (( dirty_rc != 0 )); then
      echo "skipped: worktree $p (became dirty after dry-run)"
      continue
    fi
  fi
  if [[ -n "$b" ]] && has_open_pr "$b"; then
    echo "skipped: worktree $p (open PR on branch $b appeared after dry-run)"
    continue
  fi
  wt_rm_rc=0
  git_bounded worktree remove "$p" || wt_rm_rc=$?
  if [[ "$BOUNDED_TIMED_OUT" -eq 1 ]]; then
    echo "failed: worktree $p — 'git worktree remove' exceeded ${GIT_BOUND_SECS}s and was killed"
    FAILURES=$(( FAILURES + 1 ))
  elif (( wt_rm_rc == 0 )); then
    echo "removed: worktree $p"
    # The branch this worktree was holding was NOT classified as a stale
    # local branch (parse_worktrees adds every worktree's branch to
    # CHECKED_OUT_BRANCHES, so during classification stale-worktree
    # branches were skipped as "checked out"). Now that the worktree is
    # gone, attempt to delete the branch too — gated by the same safety
    # checks the local-branch loop uses (protected names, open PR).
    # `git branch -D` is non-fatal on unknown branches, so failures here
    # don't abort the script; we surface them via the FAILURES counter
    # only when the branch actually exists and refuses deletion.
    if [[ -n "$b" ]] && ! is_protected "$b" && ! has_open_pr "$b"; then
      ref_rc=0
      git_bounded show-ref --verify --quiet "refs/heads/$b" || ref_rc=$?
      if [[ "$BOUNDED_TIMED_OUT" -eq 1 ]]; then
        echo "failed: local branch $b (after worktree $p removed) — 'git show-ref' exceeded ${GIT_BOUND_SECS}s and was killed"
        FAILURES=$(( FAILURES + 1 ))
      elif (( ref_rc == 0 )); then
        del_rc=0
        git_bounded branch -D "$b" || del_rc=$?
        if [[ "$BOUNDED_TIMED_OUT" -eq 1 ]]; then
          echo "failed: local branch $b (after worktree $p removed) — 'git branch -D' exceeded ${GIT_BOUND_SECS}s and was killed"
          FAILURES=$(( FAILURES + 1 ))
        elif (( del_rc == 0 )); then
          echo "removed: local branch $b (was on stale worktree $p)"
        else
          echo "failed: local branch $b (after worktree $p removed) — $(git_error_text "$del_rc")"
          FAILURES=$(( FAILURES + 1 ))
        fi
      fi
    fi
  else
    echo "failed: worktree $p — $(git_error_text "$wt_rm_rc")"
    FAILURES=$(( FAILURES + 1 ))
  fi
done
fi

if (( ${#STALE_LOCAL_BRANCHES[@]} > 0 )); then
for entry in "${STALE_LOCAL_BRANCHES[@]}"; do
  IFS="$US" read -r b _ <<<"$entry"
  # TOCTOU re-check: same defense as worktrees — a PR opened between
  # dry-run and apply must not lose its branch.
  if has_open_pr "$b"; then
    echo "skipped: local branch $b (open PR appeared after dry-run)"
    continue
  fi
  del_rc=0
  git_bounded branch -D "$b" || del_rc=$?
  if [[ "$BOUNDED_TIMED_OUT" -eq 1 ]]; then
    echo "failed: local branch $b — 'git branch -D' exceeded ${GIT_BOUND_SECS}s and was killed"
    FAILURES=$(( FAILURES + 1 ))
  elif (( del_rc == 0 )); then
    echo "removed: local branch $b"
  else
    echo "failed: local branch $b — $(git_error_text "$del_rc")"
    FAILURES=$(( FAILURES + 1 ))
  fi
done
fi

if (( ${#STALE_REMOTE_BRANCHES[@]} > 0 )); then
for entry in "${STALE_REMOTE_BRANCHES[@]}"; do
  IFS="$US" read -r ref _ <<<"$entry"
  branch="${ref#origin/}"
  # TOCTOU re-check for remote-branch deletion.
  if has_open_pr "$branch"; then
    echo "skipped: remote branch $branch (open PR appeared after dry-run)"
    continue
  fi
  # The one network call in the sweep, on its own much larger bound (see
  # NET_BOUND_SECS): it is the highest-risk call here — an unbounded push
  # against a black-holed remote hangs with no diagnostic at all — but it is
  # also the one call for which seconds of latency are normal.
  push_rc=0
  run_bounded "$NET_BOUND_SECS" "${GIT[@]}" push origin --delete "$branch" || push_rc=$?
  if [[ "$BOUNDED_TIMED_OUT" -eq 1 ]]; then
    echo "failed: remote branch $branch — 'git push origin --delete' exceeded ${NET_BOUND_SECS}s and was killed (raise STALE_CLEANUP_NET_TIMEOUT_SECS if the remote is genuinely this slow)"
    FAILURES=$(( FAILURES + 1 ))
  elif (( push_rc == 0 )); then
    echo "removed: remote branch $branch"
  else
    echo "failed: remote branch $branch — $(git_error_text "$push_rc")"
    FAILURES=$(( FAILURES + 1 ))
  fi
done
fi

# --- Orphaned checkouts: only ever under --remove-orphaned-checkouts ---------
# Last on purpose. This is the one deletion in the script that destroys working
# -tree files rather than git bookkeeping, so it runs after every reversible
# thing has been done and is the last output the operator reads.

# Is this checkout still orphaned RIGHT NOW? Same question scan_checkouts
# asked, re-asked immediately before the rm — the scan runs before --apply, and
# operators dry-run --check first, so the gap is human-scale: someone can
# `git worktree repair` an entry in between.
#
# Note the deliberate asymmetry with registration_is_live: there, a probe that
# stalled kept the entry a removal candidate, because a stalled read WAS the
# debris being cleaned. Here only PROVEN absence (1) lets the removal through —
# "exists" (0), a stalled probe (2), and "absence not established" (3) all stop
# it. Deleting source on a probe we could not complete is not a trade this
# script makes.
checkout_still_orphaned() { # checkout dir
  local probe_rc=0
  read_checkout_gitdir "$1" || return 1
  path_exists_bounded "$CHECKOUT_GITDIR" || probe_rc=$?
  # The same whole-path dangling-link refusal the scan applies — every
  # component, not just the leaf. Parity matters most HERE: the scan runs at
  # start-up and this gate runs immediately before the rm, so a dangling
  # ancestor appearing in that window is precisely the state change this
  # re-check exists to catch, and a leaf-only test reads false for it while
  # `test -e` still reports absent.
  #
  # This single call replaces a standalone `[[ -L "$CHECKOUT_GITDIR" ]]`: the
  # walk starts at the path itself, so the leaf is still covered, and the plain
  # form was the one unbounded lstat left on the deletion path. A leaf link that
  # RESOLVES needs no refusal here — `test -e` follows it, so probe_rc is 0 and
  # the check below already declines.
  if path_has_dangling_link_component "$CHECKOUT_GITDIR"; then return 1; fi
  (( probe_rc == 1 ))
}

# Returns 0 removed, 1 failed, 2 skipped by the re-check (not a failure).
remove_checkout() { # checkout dir
  local target="$1" name rc=0
  name="${target##*/}"
  # Path guards, mirroring remove_registration: only a single-segment name
  # directly beneath the resolved checkout dir, a real directory, never a
  # symlink. Anything else is refused rather than removed.
  case "$name" in
    ''|.|..|*/*)
      echo "failed: orphaned checkout '$target' — refusing to remove: not a single-segment entry name"
      return 1
      ;;
  esac
  if [[ -z "$CHECKOUT_DIR" || "$target" != "$CHECKOUT_DIR/$name" ]]; then
    echo "failed: orphaned checkout $target — refusing to remove: not directly beneath $CHECKOUT_DIR"
    return 1
  fi
  if [[ -L "$target" || ! -d "$target" ]]; then
    echo "failed: orphaned checkout $target — refusing to remove: not a plain directory"
    return 1
  fi
  if caller_in_worktree "$target"; then
    echo "skipped: orphaned checkout $target — the caller is standing inside it"
    return 2
  fi
  if ! checkout_still_orphaned "$target"; then
    echo "skipped: orphaned checkout $target — no longer provably orphaned (its registration reappeared, or absence could not be re-established); not removing"
    return 2
  fi
  # The git bound, not the read bound the registrations use: a registration is
  # four small files, a checkout is a whole source tree, and 2s is not a
  # meaningful wall-clock bound on deleting one.
  run_bounded "$GIT_BOUND_SECS" rm -rf -- "$target" || rc=$?
  if [[ "$BOUNDED_TIMED_OUT" -eq 1 ]]; then
    echo "failed: orphaned checkout $target — removal exceeded ${GIT_BOUND_SECS}s and was killed"
    return 1
  fi
  if (( rc != 0 )) || [[ -e "$target" ]]; then
    echo "failed: orphaned checkout $target — $(head -n 1 "$CAPTURE_ERR" 2>/dev/null || echo "rm exited $rc")"
    return 1
  fi
  return 0
}

if (( ${#ORPHANED_CHECKOUTS[@]} > 0 )); then
  if (( REMOVE_ORPHANED_CHECKOUTS == 1 )); then
    for entry in "${ORPHANED_CHECKOUTS[@]}"; do
      IFS="$US" read -r cpath _ _ <<<"$entry"
      CO_RC=0
      remove_checkout "$cpath" || CO_RC=$?
      if (( CO_RC == 0 )); then
        echo "removed: orphaned checkout $cpath (working tree deleted via --remove-orphaned-checkouts)"
      elif (( CO_RC != 2 )); then
        # 2 is the re-check declining, which is the guard working — it already
        # said so, and it is not a failure.
        FAILURES=$(( FAILURES + 1 ))
      fi
    done
  else
    # Say why nothing happened. Silence here reads as "the sweep handled it".
    echo
    echo "note: ${#ORPHANED_CHECKOUTS[@]} orphaned checkout(s) reported above were NOT removed."
    echo "      Plain --apply never deletes working-tree files. Inspect them first"
    echo "      (git worktree repair <path> makes one readable again), then pass"
    echo "      --remove-orphaned-checkouts alongside --apply to delete them."
  fi
fi

INCOMPLETE_SWEEP=0
if [[ "$WORKTREE_ENUM_STATE" != "ok" ]]; then
  INCOMPLETE_SWEEP=1
  echo
  echo "note: worktree enumeration $WORKTREE_ENUM_STATE, so worktrees and local branches were not swept."
  echo "      Re-run --apply now that the registrations above are cleared."
fi
if [[ "$REG_SCAN_STATE" == "unavailable" ]]; then
  INCOMPLETE_SWEEP=1
  echo
  echo "note: registration scan unavailable (git common dir unresolved), so orphaned registrations were not swept."
  echo "      Re-run --apply once the repo responds inside the bound."
fi
if [[ "$REF_SCAN_STATE" != "ok" ]]; then
  INCOMPLETE_SWEEP=1
  echo
  echo "note: ref enumeration $REF_SCAN_STATE, so stale branches were not classified or swept."
  echo "      Re-run --apply once the repo responds inside the bound."
fi

if (( FAILURES > 0 )); then exit 2; fi
# An apply that skipped whole categories is not a clean sweep. Saying so with
# exit 1 matches --check, which already reports both of these states that way;
# exiting 0 here let a caller record a partial sweep as done and never re-run.
if (( INCOMPLETE_SWEEP == 1 )); then exit 1; fi
exit 0
