#!/usr/bin/env bash
# repo-root.sh — Resolve the absolute path of the main (root) worktree.
#
# PURPOSE
#   Centralizes the "first-entry-in-`git worktree list`" pattern used across
#   rules, skills, agents, hooks, and scripts. The main worktree root is the
#   path returned as the first `worktree ` stanza by `git worktree list
#   --porcelain` — it is stable regardless of which worktree the caller is in.
#
#   Hardens the historic one-liner (`git worktree list | head -1 | awk '{print
#   $1}'`) against two silent-failure modes:
#     1. Not inside a git repo — old one-liner prints an empty string and
#        returns exit 0; callers would assign "" to ROOT_REPO and proceed.
#     2. Path contains whitespace — the space-splitting awk breaks; porcelain
#        format preserves the full path on its own line.
#
#   RESOLUTION ORDER (issue #1363)
#     1. `git rev-parse --git-common-dir` — reads the ONE `.git` pointer of the
#        current worktree. When the common dir's basename is `.git`, its parent
#        is the main worktree root.
#     2. `git worktree list --porcelain` — fallback for layouts step 1 cannot
#        answer (bare repos, `--separate-git-dir`, submodules), where the
#        historic first-stanza answer is still the contract.
#
#   Step 1 exists because step 2 opens `.git/worktrees/<name>/{gitdir,HEAD}`
#   for EVERY registered worktree. With dozens registered on a filesystem that
#   can stall per-file (iCloud-evicted `dataless` files, a dead network mount),
#   that enumeration blocked for 20+ minutes with no output and took the whole
#   merge path — `admin-merge.sh`, `/wrap`, `/merge`, Phase C — down with it.
#
#   BOUNDED, NEVER SILENT
#   Every git call runs under a wall-clock bound (`REPO_ROOT_TIMEOUT_SECS`).
#   On expiry the child process group is killed and the script exits 3 with a
#   one-line diagnostic naming the bound and the command — so callers fail
#   closed and loudly instead of hanging indistinguishably from slow work.
#   A run makes at most two bounded git calls, so the worst case is bounded
#   too. There is no `timeout(1)` on stock macOS, hence the background-and-poll
#   shape below rather than a wrapper binary.
#
# USAGE
#   repo-root.sh [path]
#   repo-root.sh --help | -h
#
#   path   Optional directory to resolve from (equivalent to `git -C <path>`).
#          Defaults to the current working directory.
#
# ENVIRONMENT
#   REPO_ROOT_TIMEOUT_SECS   Wall-clock bound, in whole seconds, applied to
#                            each git call (default 10). Empty, non-numeric,
#                            or zero values fall back to the default rather
#                            than disabling the bound. The clock has
#                            whole-second resolution, so a bound of N trips
#                            somewhere in (N-1, N] — immaterial at the default,
#                            worth knowing if you set it to 1.
#
# OUTPUT
#   stdout: absolute path of the main-worktree root (no trailing newline beyond
#           the usual `echo`).
#   stderr: one-line error message on failure.
#
# EXIT STATUS
#   0  Success — path printed on stdout.
#   1  Not inside a git repo / no worktrees found / resolved path missing.
#   2  Usage error (unknown flag or extra argument).
#   3  Timed out — a git call exceeded REPO_ROOT_TIMEOUT_SECS and was killed.
#
# EXAMPLES
#   ROOT_REPO=$(.claude/scripts/repo-root.sh)            # from anywhere in repo
#   ROOT_REPO=$(.claude/scripts/repo-root.sh "$SOME_WT") # from another worktree
#   REPO_ROOT_TIMEOUT_SECS=2 .claude/scripts/repo-root.sh   # tighter bound

set -euo pipefail
printf '%s\t%s\t%s\n' "$(date -u +%FT%TZ)" "$(basename "$0")" "${*//$'\n'/ }" >> "$HOME/.claude/script-usage.log"

# Self-extract the header block between BEGIN/END markers for --help.
print_help() {
  sed -n '/^# PURPOSE$/,/^# EXAMPLES$/p' "$0" | sed 's/^# \{0,1\}//'
}

TARGET=""
STOP_PARSING=0
for arg in "$@"; do
  if [[ "$STOP_PARSING" -eq 1 ]]; then
    # After --, treat everything as a positional argument.
    if [[ -n "$TARGET" ]]; then
      echo "repo-root.sh: only one path argument is allowed" >&2
      exit 2
    fi
    TARGET="$arg"
    continue
  fi
  case "$arg" in
    -h|--help)
      print_help
      exit 0
      ;;
    --)
      STOP_PARSING=1
      ;;
    -*)
      echo "repo-root.sh: unknown flag: $arg" >&2
      echo "Run with --help for usage." >&2
      exit 2
      ;;
    *)
      if [[ -n "$TARGET" ]]; then
        echo "repo-root.sh: only one path argument is allowed" >&2
        exit 2
      fi
      TARGET="$arg"
      ;;
  esac
done

# A bad override must not silently disable the bound — that is the exact
# failure this script exists to prevent. Anything non-numeric or zero falls
# back to the default instead.
TIMEOUT_SECS="${REPO_ROOT_TIMEOUT_SECS:-10}"
case "$TIMEOUT_SECS" in ''|*[!0-9]*) TIMEOUT_SECS=10 ;; esac
[ "$TIMEOUT_SECS" -gt 0 ] 2>/dev/null || TIMEOUT_SECS=10

# Created after arg parsing so --help and usage errors leave nothing behind.
CAPTURE="$(mktemp "${TMPDIR:-/tmp}/repo-root.XXXXXX")"
cleanup() {
  if [[ -n "${CAPTURE:-}" ]]; then rm -f "$CAPTURE"; fi
}
trap cleanup EXIT

# Always at least one element, so `"${GIT_CMD[@]}"` is safe under `set -u` on
# Bash 3.2 (macOS default), which errors on expanding an empty array.
GIT_CMD=(git)
if [[ -n "$TARGET" ]]; then
  GIT_CMD=(git -C "$TARGET")
fi

BOUNDED_TIMED_OUT=0
BOUNDED_CLOCK_UNREADABLE=0

# Seconds since the epoch, or a non-zero return when the answer is unusable.
# Callers must not accept a blank or non-numeric result: inside `(( ))` an empty
# variable is 0, so `now - start` would go negative and the bound below would
# never trip — the bound would vanish without a word, which is the exact class
# of failure this script exists to remove.
now_epoch() {
  local t
  t="$(date -u +%s 2>/dev/null || true)"
  case "$t" in ''|*[!0-9]*) return 1 ;; esac
  printf '%s' "$t"
}

run_bounded() {
  # Run "$@" with a wall-clock bound. stdout lands in $CAPTURE; stderr is
  # dropped because this script emits its own one-line diagnostics. Returns the
  # child's real exit status and sets BOUNDED_TIMED_OUT=1 when the bound tripped.
  BOUNDED_TIMED_OUT=0
  BOUNDED_CLOCK_UNREADABLE=0
  : > "$CAPTURE"

  # Job control puts the child in its OWN process group, so the kill below
  # reaches anything git spawned (pager, credential helper, alias) instead of
  # only the direct pid — a survivor would keep the stalled fd open while we
  # reported the call as stopped. stdin is /dev/null because a job-controlled
  # background job that reads the terminal takes SIGTTIN and stops, which looks
  # exactly like the hang we are trying to detect.
  set -m 2>/dev/null || true
  "$@" >"$CAPTURE" 2>/dev/null </dev/null &
  local pid=$!
  set +m 2>/dev/null || true

  local start now rc=0
  start="$(now_epoch)" || start=""
  # The bound reads the clock every pass, never a tick count: a tick is a sleep
  # plus a fork, so counting iterations drifts past the requested bound under
  # load — unbounded drift on the one path that is supposed to be bounded.
  while kill -0 "$pid" 2>/dev/null; do
    now="$(now_epoch)" || now=""
    # An unreadable clock cannot be allowed to mean "no bound". Fail closed:
    # stop the call and say why, rather than running it unbounded.
    if [[ -z "$start" || -z "$now" ]]; then
      BOUNDED_CLOCK_UNREADABLE=1
    fi
    if [[ "$BOUNDED_CLOCK_UNREADABLE" -eq 1 ]] || (( now - start >= TIMEOUT_SECS )); then
      BOUNDED_TIMED_OUT=1
      kill -TERM -"$pid" 2>/dev/null || kill -TERM "$pid" 2>/dev/null || true
      # Polled grace so a child that dies at once does not hold the wrapper
      # past the bound it was just held to.
      for _ in 1 2; do
        kill -0 "$pid" 2>/dev/null || break
        sleep 1
      done
      kill -KILL -"$pid" 2>/dev/null || kill -KILL "$pid" 2>/dev/null || true
      break
    fi
    # Sub-second polling keeps the healthy path (a few milliseconds) fast; this
    # script runs on every hook. A `sleep` without fractional support fails
    # instantly and the whole-second form takes over.
    sleep 0.05 2>/dev/null || sleep 1
  done

  # Always reap: `wait` is what turns the child into a real exit status instead
  # of a zombie plus a guess.
  wait "$pid" 2>/dev/null || rc=$?
  return "$rc"
}

timeout_die() {
  if [[ "$BOUNDED_CLOCK_UNREADABLE" -eq 1 ]]; then
    # Say which of the two it was. Reporting a clock failure as an elapsed-time
    # timeout is the same misdiagnosis this change removes from the callers.
    echo "repo-root.sh: could not read the clock (date -u +%s), so the ${TIMEOUT_SECS}s bound on '$1' could not be enforced — killed the call rather than running it unbounded" >&2
  else
    echo "repo-root.sh: timed out after ${TIMEOUT_SECS}s running '$1' — killed it rather than blocking the caller (raise REPO_ROOT_TIMEOUT_SECS if the repo is genuinely this slow)" >&2
  fi
  exit 3
}

# ---------------------------------------------------------------------------
# Step 1 — resolve through the shared git dir, touching no worktree entries.
# Sets ROOT and returns 0 on success; returns non-zero when this layout needs
# step 2. Deliberately NOT called in a command substitution: `timeout_die` has
# to exit the script, and inside `$( )` it would only exit the subshell — the
# caller would then fall through to the enumeration this script exists to
# avoid, turning a bounded failure back into a silent one.
# ---------------------------------------------------------------------------
ROOT=""
resolve_via_common_dir() {
  local rc=0 common base parent

  run_bounded "${GIT_CMD[@]}" rev-parse --path-format=absolute --git-common-dir || rc=$?
  if [[ "$BOUNDED_TIMED_OUT" -eq 1 ]]; then
    # git rev-parse is the cheapest call this script can make. If it cannot
    # finish inside the bound, git is wedged and the heavier enumeration below
    # would only double the outage — fail now.
    timeout_die "git rev-parse --git-common-dir"
  fi
  if [[ "$rc" -ne 0 ]]; then
    # git < 2.31 has no --path-format; its plain form may answer with a path
    # relative to the directory the call ran in.
    rc=0
    run_bounded "${GIT_CMD[@]}" rev-parse --git-common-dir || rc=$?
    if [[ "$BOUNDED_TIMED_OUT" -eq 1 ]]; then
      timeout_die "git rev-parse --git-common-dir"
    fi
    [[ "$rc" -eq 0 ]] || return 1
  fi

  common="$(head -n 1 "$CAPTURE")"
  [[ -n "$common" ]] || return 1

  # Only a common dir literally named `.git` has the main worktree as its
  # parent. A bare repo (`repo.git`), `--separate-git-dir`, and a submodule's
  # `.git/modules/<name>` all fail this test and belong to step 2, which still
  # answers them exactly as this script always has.
  base="$(basename "$common")"
  [[ "$base" == ".git" ]] || return 1

  parent="$(dirname "$common")"
  if [[ "$parent" != /* ]]; then
    parent="${TARGET:-$PWD}/$parent"
  fi
  # Physical path: `git worktree list` records symlink-resolved paths, so the
  # logical form would differ from the historic answer wherever the repo sits
  # behind a symlink (macOS $TMPDIR, /var -> /private/var).
  parent="$(cd "$parent" 2>/dev/null && pwd -P)" || return 1
  [[ -n "$parent" && -d "$parent" ]] || return 1

  ROOT="$parent"
  return 0
}

if ! resolve_via_common_dir; then
  ROOT=""
fi

if [[ -z "$ROOT" ]]; then
  # Porcelain parsing: first `worktree <path>` line is the main worktree root.
  # A non-zero status here says nothing the empty-output branch below does not
  # already report ("not a git repo"); the one status that IS distinct — the
  # bound tripping — is carried by BOUNDED_TIMED_OUT and handled first.
  run_bounded "${GIT_CMD[@]}" worktree list --porcelain || true
  if [[ "$BOUNDED_TIMED_OUT" -eq 1 ]]; then
    timeout_die "git worktree list --porcelain"
  fi
  ROOT="$(awk '/^worktree /{sub(/^worktree /, ""); print; exit}' "$CAPTURE")" || ROOT=""
fi

if [[ -z "$ROOT" ]]; then
  if [[ -n "$TARGET" ]]; then
    echo "repo-root.sh: could not resolve main worktree root (not a git repo: $TARGET)" >&2
  else
    echo "repo-root.sh: could not resolve main worktree root (not inside a git repo)" >&2
  fi
  exit 1
fi

if [[ ! -d "$ROOT" ]]; then
  echo "repo-root.sh: resolved path does not exist: $ROOT" >&2
  exit 1
fi

echo "$ROOT"
