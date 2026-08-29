#!/usr/bin/env bash
# admin-merge.sh — Generate (and, only when the USER opts in, run) the
# toggle-merge-toggle bypass for a protected branch on a SOLO-OWNER repo.
#
# Background (issue #451): on a solo-owner repo where the user is the sole admin
# and CodeRabbit / CodeAnt are the only required reviewers, a merge can stall on
# branch protection — typically `enforce_admins: true` combined with a code-owner
# review requirement that an AI reviewer auto-skipped. The only path forward is:
#   1. Disable enforce_admins
#   2. gh pr merge --squash --admin
#   3. Re-enable enforce_admins
#
# Claude's safety rules permanently prohibit Claude from modifying branch
# protection. This script keeps that boundary intact, and issue #754 draws it
# precisely where the prohibition actually applies — at *protection modification*,
# not at the `--admin` merge flag:
#
#   * TOGGLE shape (enforce_admins: true) — needs disable → merge → re-enable.
#     Print-only for Claude. It runs ONLY when the USER invokes `--execute`
#     (and even then a `trap` re-enables protection if the dance fails).
#   * PLAIN shape (enforce_admins: false + required_status_checks.strict + a
#     verified clean-BEHIND) — a bare `gh pr merge --squash --admin` that touches
#     no protection setting at all. Claude MAY execute this via `--auto-plain`,
#     a mode that is structurally incapable of the toggle shape.
#
# The `/admin-merge` skill invokes this script in `--print`, `--launch-terminal`,
# or `--auto-plain` mode — never `--execute`. See .claude/skills/admin-merge/ and
# .claude/reference/admin-merge-auto-plain.md.
#
# Usage:
#   admin-merge.sh <pr_number> [mode] [options]
#
# Modes (mutually exclusive; default --print):
#   --print            Read-only. Verify merge-readiness + solo-owner + diagnose
#                      the protection blocker, then print the bypass one-liner.
#                      Never modifies branch protection. (DEFAULT)
#   --launch-terminal  Same pre-flight as --print, then (macOS only) open a new
#                      iTerm2/Terminal.app window at the repo, copy the command to
#                      the clipboard (pbcopy), and echo a marker line in the new
#                      terminal. Never auto-executes the command. Falls back to
#                      --print behaviour on Linux/Windows with a clear message.
#   --auto-plain       CLAUDE-INVOCABLE (issue #754). Executes the PLAIN shape and
#                      ONLY the plain shape: re-validates the clean-BEHIND state,
#                      runs a bare `gh pr merge --squash --admin`, verifies the
#                      merge, and prints an evidence report. Contains no
#                      protection-modifying call. Any other diagnosed shape is a
#                      hard refusal (exit 8) that falls back to printing, as does a
#                      second attempt on the same PR (repeat guard) and a missing
#                      --ac-verified attestation. REQUIRES --ac-verified.
#   --execute          USER-INVOKED ONLY. Toggle shape: run the toggle-merge-toggle
#                      dance with a trap that re-enables enforce_admins on any
#                      failure, then verify protection is restored and the PR merged.
#                      Plain shape (enforce_admins=false + strict=true + clean-BEHIND):
#                      run a bare `gh pr merge --squash --admin` with no protection
#                      changes. Both shapes revalidate the clean-BEHIND state (#631)
#                      just before executing.
#
# Options:
#   --repo-path <path>  Absolute path of the local clone to cd into (default:
#                       repo-root.sh / git toplevel of the cwd). AUTHORITATIVE
#                       over the invoker's cwd (issue #1439): the script enters
#                       this path BEFORE it resolves owner/repo, so gh's cwd
#                       inference and every cwd-scoped helper (pr-authorship.sh,
#                       merge-gate.sh, clean-behind-check.sh) target it too — a
#                       cross-repo invocation no longer needs the caller to cd
#                       first. A value that cannot be entered is a hard error
#                       (exit 7) in every mode, never a silent cwd fallback.
#   --branch <name>     Protected branch (default: the PR's base branch).
#   --ac-verified       REQUIRED by --auto-plain. Caller attests it has completed
#                       cr-merge-gate.md Step 2 — per-criterion Test Plan
#                       verification against the code at the CURRENT SHA — for this
#                       PR. clean-behind-check.sh only confirms the checkboxes are
#                       ticked, which is a mechanical proxy, not verification; an
#                       unattended merge must not rest on the proxy alone. Without
#                       this flag --auto-plain refuses (exit 8) and prints instead.
#                       Ignored by every other mode.
#   --force-solo        Skip the solo-owner heuristic (treat repo as solo-owned).
#   --reviewer cr|bugbot|greptile   Pass through to merge-gate.sh.
#   --allow-nonauthor   Bypass the issue #733 authorship guard (see below). Pass
#                       ONLY under an explicit per-PR user override — the default
#                       refuses a bypass merge on a PR you did not author.
#                       REFUSED (exit 2) when combined with --auto-plain: that
#                       mode runs unattended, and skipping the authorship guard
#                       unattended is never allowed. Works normally with
#                       --print, --launch-terminal, and --execute — a human is
#                       always in the loop for those.
#   -h, --help          Print this header.
#
# Authorship guard (issue #733): before any pre-flight, this refuses when the
# authenticated user did not author the PR (delegated to pr-authorship.sh;
# fail-closed). A bypass merge is a write, so it is restricted to your own PRs.
# --allow-nonauthor is forwarded to every downstream consumer that runs its own
# independent authorship check, so none of them re-adds the blocker this
# script's own guard just cleared: merge-gate.sh directly (issue #1251), and
# clean-behind-check.sh — whose NESTED merge-gate.sh call kept the override
# unreachable for BEHIND non-author PRs, refusing them with a misleading "not
# safe to skip a rebase" (issue #1257).
#
# Exit codes:
#   0 — bypass command printed (print/launch) OR dance completed (execute)
#        OR the plain shape was auto-merged (auto-plain)
#   1 — refused: PR not merge-ready (hard blockers / human changes requested),
#        OR refused by the issue #733 authorship guard (non-author PR, no override),
#        OR (auto-plain) the clean-BEHIND state no longer holds at merge time
#   2 — usage error, INCLUDING --auto-plain combined with --allow-nonauthor
#        (issue #1251 — that combination is refused before any pre-flight runs)
#   3 — PR not found / not open
#   4 — gh / git / network / jq error, including repo-root.sh timing out (its
#        exit 3, issue #1363) or being unable to run git at all (its exit 4,
#        issue #1403) while resolving the repo path. Both are absorbed here
#        because neither is a determinate answer — the path is refused, not
#        guessed. A determinate "not a git repo" still takes the fallback chain.
#   5 — refused: repo is not solo-owned (would skip a real review)
#   6 — refused: enforce_admins is disabled and strict+clean-BEHIND bypass does
#        not apply — no bypass path detected (inspect branch protection for the
#        actual blocker)
#   7 — unusable repo path, or an execute/auto-plain failure (merge failed, or
#        the PR never reported state=MERGED; in execute's toggle shape the trap
#        re-enabled protection). The repo-path refusal fires right after argument
#        parsing, before any gh call, whenever the resolved path cannot be
#        entered AND acting on the invoker's cwd instead would be wrong: an
#        explicit --repo-path (any mode — honouring it is the flag's purpose), or
#        --auto-plain/--execute with any resolved path (an irreversible merge).
#        A read-only mode with an auto-resolved bad path keeps warning and
#        continuing in the cwd it derived that path from.
#   8 — refused by --auto-plain: the diagnosed shape is not `plain` (protection
#        modification is prohibited for Claude), --ac-verified was not passed, an
#        auto attempt already ran for this PR, or the repeat-guard marker could not
#        be written. The bypass command is printed; nothing was executed.

set -uo pipefail
printf '%s\t%s\t%s\n' "$(date -u +%FT%TZ)" "$(basename "$0")" "${*//$'\n'/ }" 2>/dev/null >> "$HOME/.claude/script-usage.log" || true

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# release_issue_claim — drop the pick-time claim on the PR's linked issue once
# the merge is confirmed (issue #873). A merged PR is a terminal state, so the
# issue becomes startable again.
#
# BEST-EFFORT BY DESIGN: this only ever runs AFTER a merge has already landed,
# so it must never change the exit status. An unreleased claim ages out on its
# own within CLAIM_STALE_HOURS; failing an already-completed merge would be the
# far worse outcome. Every failure path here is a warning.
release_issue_claim() {
  local issue
  [[ -x "$SCRIPT_DIR/pr-issue-ref.sh" && -x "$SCRIPT_DIR/issue-claim.sh" ]] || return 0
  issue="$("$SCRIPT_DIR/pr-issue-ref.sh" "$PR_NUMBER" 2>/dev/null || true)"
  [[ -n "$issue" ]] || return 0
  if ! "$SCRIPT_DIR/issue-claim.sh" "$issue" --release >/dev/null 2>&1; then
    echo "WARNING: could not release the claim on issue #$issue — it will expire on its own. Clear it early with: $SCRIPT_DIR/issue-claim.sh $issue --release" >&2
  fi
  return 0
}

print_usage() {
  awk 'NR == 1 { next } /^$/ { exit } { print }' "$0" | sed 's/^# \{0,1\}//'
}

# --------------------------------------------------------------------------
# Arg parsing
# --------------------------------------------------------------------------
PR_NUMBER=""
MODE="print"
MODE_EXPLICIT=""
REPO_PATH_OVERRIDE=""
BRANCH_OVERRIDE=""
FORCE_SOLO=false
REVIEWER_OVERRIDE=""
# AC attestation (issue #754 review): --auto-plain merges unattended, so it must
# not rest on clean-behind-check.sh's ticked-checkbox proxy alone. The caller
# asserts it ran cr-merge-gate.md Step 2 against the code at the current SHA.
AC_VERIFIED=false
# Authorship guard (issue #733): a bypass merge is the most consequential PR
# write. Refuse non-author PRs unless the caller passes --allow-nonauthor under
# an explicit per-PR user override.
ALLOW_NONAUTHOR=false

set_mode() {
  if [[ -n "$MODE_EXPLICIT" && "$MODE_EXPLICIT" != "$1" ]]; then
    echo "ERROR: modes are mutually exclusive (already set --$MODE_EXPLICIT, got --$1)" >&2
    exit 2
  fi
  MODE="$1"
  MODE_EXPLICIT="$1"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help) print_usage; exit 0 ;;
    --print) set_mode print; shift ;;
    --launch-terminal) set_mode launch-terminal; shift ;;
    --auto-plain) set_mode auto-plain; shift ;;
    --execute|--run) set_mode execute; shift ;;
    --repo-path)
      REPO_PATH_OVERRIDE="${2:-}"
      [[ -z "$REPO_PATH_OVERRIDE" ]] && { echo "ERROR: --repo-path requires a value" >&2; exit 2; }
      shift 2 ;;
    --branch)
      BRANCH_OVERRIDE="${2:-}"
      [[ -z "$BRANCH_OVERRIDE" ]] && { echo "ERROR: --branch requires a value" >&2; exit 2; }
      shift 2 ;;
    --force-solo) FORCE_SOLO=true; shift ;;
    --ac-verified) AC_VERIFIED=true; shift ;;
    --allow-nonauthor) ALLOW_NONAUTHOR=true; shift ;;
    --reviewer)
      REVIEWER_OVERRIDE="${2:-}"
      case "$REVIEWER_OVERRIDE" in
        cr|bugbot|greptile) ;;
        *) echo "ERROR: --reviewer must be one of: cr, bugbot, greptile (got: ${REVIEWER_OVERRIDE:-})" >&2; exit 2 ;;
      esac
      shift 2 ;;
    -*) echo "ERROR: unknown flag: $1" >&2; exit 2 ;;
    *)
      if [[ -n "$PR_NUMBER" ]]; then
        echo "ERROR: unexpected argument: $1 (PR number already set to $PR_NUMBER)" >&2
        exit 2
      fi
      PR_NUMBER="$1"; shift ;;
  esac
done

# --auto-plain + --allow-nonauthor hard refusal (issue #1251 review round).
# --auto-plain is the one mode Claude may run UNATTENDED — no human confirms
# the actual merge — so skipping the issue #733 authorship guard here is never
# allowed.
#
# THIS CHECK IS LOAD-BEARING, NOT BELT-AND-BRACES. When issue #1251 added it,
# a second, accidental protection also happened to block the combination:
# clean-behind-check.sh's internal merge-gate.sh call could not receive
# --allow-nonauthor, so CLEAN_BEHIND_OK could never become true for a
# non-author PR and BYPASS_MODE could never reach "plain". Issue #1257 closed
# that gap on purpose (the override now propagates through CBC_ARGS below), so
# the accidental protection is GONE. This explicit refusal is now the only
# thing standing between `--auto-plain --allow-nonauthor` and an unattended
# merge of a foreign-authored PR. Do not remove or weaken it, and do not
# reintroduce the combination through a new mode without re-deciding this.
#
# --print, --launch-terminal, and --execute are unaffected: a human is always
# in the loop for those (--execute is documented USER-INVOKED ONLY; Claude
# never runs it), so --allow-nonauthor keeps working for them as intended.
if [[ "$MODE" == "auto-plain" && "$ALLOW_NONAUTHOR" == true ]]; then
  echo "ERROR: --auto-plain does not accept --allow-nonauthor. --auto-plain runs UNATTENDED (no human confirms the merge), so skipping the issue #733 authorship guard in this mode is never allowed. Use --print (or --launch-terminal) with --allow-nonauthor instead — it only prints the bypass command for a human to review and run themselves." >&2
  exit 2
fi

if [[ -z "$PR_NUMBER" ]]; then
  echo "ERROR: <pr_number> is required" >&2
  print_usage >&2
  exit 2
fi
if ! [[ "$PR_NUMBER" =~ ^[0-9]+$ ]]; then
  echo "ERROR: <pr_number> must be a positive integer (got: $PR_NUMBER)" >&2
  exit 2
fi

# --------------------------------------------------------------------------
# Resolve the local clone FIRST, then scope the whole process to it (issue #1439)
# --------------------------------------------------------------------------
# --repo-path exists so a caller can point this script at a clone OTHER than the
# invoker's cwd. It used to fail at that: repo identity was resolved from the cwd
# (`gh repo view`, which infers owner/repo from the cwd's git remote) long before
# REPO_PATH was computed, so a cross-repo invocation resolved the WRONG repo and
# exited 3 ("PR not found") even when the flag named the right clone — observed
# live on PR #1423's Phase C from an unrelated repo's checkout.
#
# Resolving the path here — before the first repo-identity call — and entering it
# once makes --repo-path authoritative for every cwd-sensitive consumer at the
# same time, without threading an explicit repo scope through each of them:
# `gh repo view` / `gh pr view`, the pr-authorship.sh / merge-gate.sh /
# clean-behind-check.sh pre-flight subprocesses (all cwd-scoped), the AUTO_MARKER
# dedup key, and the final `gh pr merge`. It runs before the mode branches
# diverge, so all four modes (--print, --launch-terminal, --auto-plain,
# --execute) get it. The printed BYPASS_CMD keeps its own `cd %q` prefix so the
# emitted one-liner stays portable for a human pasting it elsewhere.
#
# resolve_repo_path() itself still reads the cwd (repo-root.sh / git toplevel /
# $PWD) when no override is given — that fallback chain, and its precedence, are
# unchanged; only the moment it runs moved.
resolve_repo_path() {
  if [[ -n "$REPO_PATH_OVERRIDE" ]]; then
    echo "$REPO_PATH_OVERRIDE"; return
  fi
  local p="" rc=0 errfile="" err=""
  if [[ -x "$SCRIPT_DIR/repo-root.sh" ]]; then
    # This script runs without `set -e`, so a bare `mktemp` failure would leave
    # errfile empty and turn the redirect below into `2>""`. Name a fallback
    # path instead — still safe to `rm -f`, unlike /dev/null.
    errfile="$(mktemp 2>/dev/null)" || errfile="${TMPDIR:-/tmp}/admin-merge-reporoot.$$"
    p="$("$SCRIPT_DIR/repo-root.sh" 2>"$errfile")" || rc=$?
    err="$(head -n 1 "$errfile" 2>/dev/null || true)"
    rm -f "$errfile"
    # Two repo-root.sh codes mean "git itself is unusable", and NEITHER may fall
    # through: exit 3, a git call killed at its wall-clock bound (issue #1363),
    # and exit 4, git never launching at all (issue #1403). The next statement
    # is an UNBOUNDED `git rev-parse` against that same broken git — for the
    # timeout it moves the 20-minute freeze rather than removing it, and for a
    # missing binary it just fails again — and the `$PWD` after it would
    # silently substitute the invoker's cwd for the root repo on the one path
    # whose action is irreversible. Refuse, like dirty-main-guard.sh and
    # stale-cleanup.sh already do. Both land in this script's exit 4 bucket
    # ("gh / git / network / jq error") via the caller below.
    if [[ "$rc" -eq 3 ]]; then
      echo "ERROR: repo-root.sh timed out resolving the root repo${err:+ — $err}" >&2
      echo "ERROR: refusing to guess the repo path for a merge; pass --repo-path <abs-path> once git responds." >&2
      return 3
    fi
    if [[ "$rc" -eq 4 ]]; then
      echo "ERROR: repo-root.sh could not run git at all while resolving the root repo${err:+ — $err}" >&2
      echo "ERROR: refusing to guess the repo path for a merge; repair git (or pass --repo-path <abs-path>) and retry." >&2
      return 4
    fi
    if [[ "$rc" -ne 0 ]]; then
      # What is left is a determinate answer ("not a git repo"), so the historic
      # fallback chain still applies — it just no longer runs silently.
      p=""
      echo "WARNING: repo-root.sh could not resolve the root repo (exit $rc)${err:+ — $err}" >&2
      echo "WARNING: falling back to the current checkout; pass --repo-path <abs-path> to pin it." >&2
    fi
  fi
  if [[ -z "$p" ]]; then
    p="$(git rev-parse --show-toplevel 2>/dev/null || true)"
  fi
  if [[ -z "$p" ]]; then
    p="$PWD"
  fi
  echo "$p"
}
# `|| rc` rather than a bare assignment: resolve_repo_path returns non-zero (3
# timed out, 4 git could not run) when the root is genuinely unknown, and an
# `exit` inside it would only leave the command substitution's subshell.
REPO_PATH=""
RESOLVE_RC=0
REPO_PATH="$(resolve_repo_path)" || RESOLVE_RC=$?
if [[ "$RESOLVE_RC" -ne 0 ]]; then
  exit 4
fi

# Enter the resolved clone ONCE, before any repo-identity resolution, so cwd,
# gh's repo inference, and every helper subprocess below agree on one repo.
REPO_PATH_NOTE=""
if ! cd "$REPO_PATH" 2>/dev/null; then
  # Refuse whenever continuing could act on a DIFFERENT repo than the one asked
  # for:
  #   * an explicit --repo-path names a target we cannot honour — falling back
  #     to the invoker's cwd is precisely issue #1439's bug, and would print (or
  #     run) a bypass against whatever repo the cwd happens to be, which may
  #     well have a PR at this number;
  #   * --auto-plain / --execute merge for real, so a wrong cwd is irreversible.
  #     This preserves the refusal those two branches carried before #1439.
  # A read-only mode with an AUTO-RESOLVED path keeps the historic
  # warn-and-continue: that path was derived from this very cwd, so the cwd is a
  # coherent fallback, and the note tells the operator to pin it.
  if [[ -n "$REPO_PATH_OVERRIDE" || "$MODE" == "auto-plain" || "$MODE" == "execute" ]]; then
    echo "ERROR: cannot cd into repo path '$REPO_PATH' — pass --repo-path <abs-path> naming an existing local clone." >&2
    exit 7
  fi
  REPO_PATH_NOTE="WARNING: resolved repo path '$REPO_PATH' could not be entered — pass --repo-path <abs-path>."
fi

# --------------------------------------------------------------------------
# Resolve owner/repo + PR metadata
# --------------------------------------------------------------------------
OWNER_REPO=$(gh repo view --json nameWithOwner --jq '.nameWithOwner' 2>/dev/null || true)
if [[ -z "$OWNER_REPO" ]]; then
  echo "ERROR: 'gh repo view' failed — not in a git repo or no remote configured." >&2
  exit 4
fi
OWNER="${OWNER_REPO%/*}"
REPO="${OWNER_REPO#*/}"

PR_JSON=$(gh pr view "$PR_NUMBER" --json number,state,baseRefName,headRefName 2>/dev/null || true)
if [[ -z "$PR_JSON" ]]; then
  echo "ERROR: PR #$PR_NUMBER not found in $OWNER_REPO." >&2
  exit 3
fi
PR_STATE=$(echo "$PR_JSON" | jq -r '.state // "UNKNOWN"')
PR_MERGED=$(echo "$PR_JSON" | jq -r '(.state == "MERGED")')
BASE_REF=$(echo "$PR_JSON" | jq -r '.baseRefName // ""')

if [[ "$PR_MERGED" == "true" ]]; then
  echo "PR #$PR_NUMBER is already merged — nothing to do." >&2
  exit 3
fi
if [[ "$PR_STATE" != "OPEN" ]]; then
  echo "ERROR: PR #$PR_NUMBER is $PR_STATE — not open." >&2
  exit 3
fi

# --------------------------------------------------------------------------
# Authorship guard (issue #733) — refuse a bypass merge on a PR the
# authenticated user did not author. Delegated to pr-authorship.sh (single
# source of truth); fail-closed on any non-zero (not_mine / unknown / not_found).
# --allow-nonauthor bypasses ONLY under an explicit per-PR user override.
# --------------------------------------------------------------------------
if [[ "$ALLOW_NONAUTHOR" != true ]]; then
  PR_AUTHORSHIP=""
  for candidate in \
    "$SCRIPT_DIR/pr-authorship.sh" \
    "$HOME/.claude/skills-worktree/.claude/scripts/pr-authorship.sh" \
    "$HOME/.claude/scripts/pr-authorship.sh"; do
    if [[ -x "$candidate" ]]; then PR_AUTHORSHIP="$candidate"; break; fi
  done
  if [[ -z "$PR_AUTHORSHIP" ]]; then
    echo "REFUSED: pr-authorship.sh not found — cannot verify PR authorship (issue #733 guard); refusing fail-closed." >&2
    exit 1
  fi
  AUTH_OUT="$("$PR_AUTHORSHIP" "$PR_NUMBER" 2>&1)"; AUTH_RC=$?
  if [[ "$AUTH_RC" -ne 0 ]]; then
    echo "REFUSED: admin-merge will not act on PR #$PR_NUMBER — authorship guard (.claude/rules/safety.md): ${AUTH_OUT}" >&2
    echo "Pass --allow-nonauthor ONLY under an explicit per-PR user override." >&2
    exit 1
  fi
fi

BRANCH="${BRANCH_OVERRIDE:-$BASE_REF}"
if [[ -z "$BRANCH" ]]; then
  echo "ERROR: could not determine the protected branch (pass --branch)." >&2
  exit 4
fi

# --------------------------------------------------------------------------
# Pre-flight 1: merge-readiness (CI green, approved, threads resolved)
# --------------------------------------------------------------------------
# The only protection-related blocker the bypass is allowed to step over is the
# branch-protection reviewDecision (e.g. a code-owner review an AI reviewer
# auto-skipped). Any OTHER missing reason — failing/incomplete CI, no primary
# approval, unresolved threads, BEHIND/CONFLICTING — is a HARD blocker: refuse.
MERGE_GATE=""
for candidate in \
  "$SCRIPT_DIR/merge-gate.sh" \
  "$HOME/.claude/skills-worktree/.claude/scripts/merge-gate.sh" \
  "$HOME/.claude/scripts/merge-gate.sh"; do
  if [[ -x "$candidate" ]]; then MERGE_GATE="$candidate"; break; fi
done
if [[ -z "$MERGE_GATE" ]]; then
  echo "ERROR: merge-gate.sh not found — cannot verify merge-readiness." >&2
  exit 4
fi

GATE_ARGS=("$PR_NUMBER")
[[ -n "$REVIEWER_OVERRIDE" ]] && GATE_ARGS+=(--reviewer "$REVIEWER_OVERRIDE")
# Forward the authorship override (issue #733) so merge-gate.sh's own
# authorship check — independent of the pre-flight above — doesn't re-add the
# blocker this script's caller already asked to bypass (issue #1251).
[[ "$ALLOW_NONAUTHOR" == true ]] && GATE_ARGS+=(--allow-nonauthor)
# set -e is intentionally off, so a non-zero merge-gate exit (e.g. 1 = gate not
# met) does not abort here — capture the real exit code, then inspect the JSON.
GATE_JSON="$("$MERGE_GATE" "${GATE_ARGS[@]}" 2>/dev/null)"
GATE_EXIT=$?
if [[ -z "$GATE_JSON" ]] || ! echo "$GATE_JSON" | jq -e . >/dev/null 2>&1; then
  echo "ERROR: merge-gate.sh produced no parseable JSON (exit $GATE_EXIT)." >&2
  exit 4
fi

# Clean-BEHIND allowance (issue #631): a `mergeStateStatus: BEHIND` is normally a
# hard blocker (rebase first). But when the base delta does NOT touch the PR's
# files, rebasing is pure churn and an admin squash-merge is safe — `gh pr merge
# --admin` merges a BEHIND branch regardless of the "require up to date" rule.
# Step over BEHIND ONLY when clean-behind-check.sh confirms its mechanical axes
# are safe (not CONFLICTING, AC checked, no base-delta↔PR-file overlap). The
# helper may still exit 1 when its bundled merge-gate run reports only the branch-
# protection reviewDecision note that admin-merge is independently allowed to
# bypass. Keep that note separate from the mechanical clean-BEHIND verdict so the
# two gate filters cannot make --auto-plain unreachable (issue #947).
REVIEW_DECISION_BLOCKER_RE='^branch protection reviewDecision is [A-Z_]+, not APPROVED, with (CodeRabbit in CODEOWNERS — if the prior CR approval was dismissed as stale, trigger @coderabbitai full review|Greptile in CODEOWNERS — if the prior Greptile approval was dismissed as stale, trigger @greptileai|CodeAnt in CODEOWNERS — if the prior CodeAnt approval was dismissed as stale, trigger @codeant-ai review)$'

clean_behind_evidence_allows_admin() {
  local json="$1" rc="$2"

  # Preserve clean-behind-check.sh's primary contract: exit 0 is authoritative.
  [[ "$rc" -eq 0 ]] && return 0
  # Exit 1 means "not safe to offer" and carries inspectable JSON. Recover only
  # the known gate-filter asymmetry; helper errors remain fail-closed.
  [[ "$rc" -eq 1 ]] || return 1

  printf '%s' "$json" | jq -e --arg review_blocker_re "$REVIEW_DECISION_BLOCKER_RE" '
    type == "object"
    and .merge_state == "BEHIND"
    and .mergeable == "MERGEABLE"
    and ((.file_overlap.count | type) == "number")
    and .file_overlap.count == 0
    and .ac.all_checked == true
    and ((.residual_blockers | type) == "array")
    and all(.residual_blockers[];
      type == "string" and test($review_blocker_re))
  ' >/dev/null 2>&1
}

CLEAN_BEHIND_OK=false
CBC_JSON=""
CBC_RC=4
BEHIND_PRESENT=$(echo "$GATE_JSON" | jq -r '[.missing[]? | select(test("BEHIND base"; "i"))] | length')
if [[ "${BEHIND_PRESENT:-0}" -gt 0 ]]; then
  CBC=""
  for candidate in \
    "$SCRIPT_DIR/clean-behind-check.sh" \
    "$HOME/.claude/skills-worktree/.claude/scripts/clean-behind-check.sh" \
    "$HOME/.claude/scripts/clean-behind-check.sh"; do
    if [[ -x "$candidate" ]]; then CBC="$candidate"; break; fi
  done
  if [[ -n "$CBC" ]]; then
    CBC_ARGS=("$PR_NUMBER")
    [[ -n "$REVIEWER_OVERRIDE" ]] && CBC_ARGS+=(--reviewer "$REVIEWER_OVERRIDE")
    # Forward the authorship override into clean-behind-check.sh's own NESTED
    # merge-gate.sh call (issue #1257). Without it that nested gate re-adds the
    # non-author blocker to its `missing[]`, which lands in the helper's
    # `residual_blockers`, fails clean_behind_evidence_allows_admin()'s
    # reviewDecision-only match, and refuses a BEHIND non-author PR with a
    # misleading "not safe to skip a rebase". CBC_ARGS is built once and reused
    # by both pre-merge re-validation call sites, so this covers all three.
    [[ "$ALLOW_NONAUTHOR" == true ]] && CBC_ARGS+=(--allow-nonauthor)
    CBC_JSON="$("$CBC" "${CBC_ARGS[@]}" 2>/dev/null)"
    CBC_RC=$?
    if clean_behind_evidence_allows_admin "$CBC_JSON" "$CBC_RC"; then
      CLEAN_BEHIND_OK=true
    fi
  fi
fi

# Hard blockers = every missing reason that is NOT one of the two protection-
# mechanical blockers the admin bypass is allowed to step over: (1) the branch-
# protection reviewDecision note, and (2) a *clean* BEHIND (only when CLEAN_BEHIND_OK).
HARD_BLOCKERS=$(echo "$GATE_JSON" | jq -r \
  --argjson cbo "$CLEAN_BEHIND_OK" \
  --arg review_blocker_re "$REVIEW_DECISION_BLOCKER_RE" '
  [.missing[]?
    | select(test($review_blocker_re) | not)
    | select(($cbo | not) or (test("BEHIND base"; "i") | not))]
  | .[]')
NON_BEHIND_HARD_BLOCKERS=$(echo "$GATE_JSON" | jq -r \
  --arg review_blocker_re "$REVIEW_DECISION_BLOCKER_RE" '
  [.missing[]?
    | select(test($review_blocker_re) | not)
    | select(test("BEHIND base"; "i") | not)]
  | .[]')
HUMAN_CHANGES=$(echo "$GATE_JSON" | jq -r '[.human_changes_requested[]?] | join(", ")')

if [[ -n "$HUMAN_CHANGES" ]]; then
  echo "REFUSED: human reviewer(s) requested changes on HEAD: $HUMAN_CHANGES" >&2
  echo "Admin bypass must NOT skip a human change request. Address it first." >&2
  exit 1
fi
if [[ -n "$HARD_BLOCKERS" ]]; then
  if [[ -z "$NON_BEHIND_HARD_BLOCKERS" && "${BEHIND_PRESENT:-0}" -gt 0 && "$CLEAN_BEHIND_OK" != true ]]; then
    echo "REFUSED: PR #$PR_NUMBER is BEHIND and is not safe to skip a rebase." >&2
    if printf '%s' "$CBC_JSON" | jq -e '.reasons_not_safe | type == "array" and length > 0' >/dev/null 2>&1; then
      while IFS= read -r line; do [[ -n "$line" ]] && echo "  - $line" >&2; done \
        < <(printf '%s' "$CBC_JSON" | jq -r '.reasons_not_safe[]')
    elif [[ -z "${CBC:-}" ]]; then
      echo "  - clean-behind-check.sh is unavailable; mechanical safety could not be verified" >&2
    else
      echo "  - clean-behind-check.sh did not provide usable clean-BEHIND evidence (exit $CBC_RC)" >&2
    fi
    echo "Rebase and re-run the normal review flow before using /admin-merge." >&2
  else
    echo "REFUSED: PR #$PR_NUMBER is not merge-ready apart from branch protection. Outstanding blockers:" >&2
    while IFS= read -r line; do [[ -n "$line" ]] && echo "  - $line" >&2; done <<< "$HARD_BLOCKERS"
    echo "Fix these (CI / approval / threads / rebase) before using /admin-merge." >&2
  fi
  exit 1
fi

# --------------------------------------------------------------------------
# Pre-flight 2: solo-owner heuristic
# --------------------------------------------------------------------------
# Solo = exactly one human admin (the current user) AND zero/one human code
# owner that, when present, is also the current user. Review bots in CODEOWNERS
# do not count as human owners. Override with --force-solo.
SOLO_NOTE=""
if [[ "$FORCE_SOLO" != true ]]; then
  CURRENT_USER=$(gh api user --jq '.login' 2>/dev/null || true)
  if [[ -z "$CURRENT_USER" ]]; then
    echo "ERROR: could not determine the current GitHub user ('gh api user')." >&2
    exit 4
  fi

  HUMAN_ADMINS=$(gh api --paginate "repos/$OWNER/$REPO/collaborators?permission=admin&per_page=100" \
    --jq '.[] | select(.type == "User") | .login' 2>/dev/null \
    | grep -ivE '\[bot\]$' | sort -u || true)
  HUMAN_ADMIN_COUNT=$(printf '%s\n' "$HUMAN_ADMINS" | grep -cve '^$' || true)

  # Parse CODEOWNERS for human owner handles (drop comments, teams, and review bots).
  CODEOWNERS_TEXT=""
  for codeowners_path in CODEOWNERS .github/CODEOWNERS docs/CODEOWNERS; do
    CO_JSON=$(gh api --method GET "repos/$OWNER/$REPO/contents/$codeowners_path" -f ref="$BRANCH" 2>/dev/null || true)
    if [[ -n "$CO_JSON" ]]; then
      CODEOWNERS_TEXT=$(echo "$CO_JSON" | jq -r '.content // ""' | base64 --decode 2>/dev/null || true)
      [[ -n "$CODEOWNERS_TEXT" ]] && break
    fi
  done

  HUMAN_OWNERS=$(printf '%s\n' "$CODEOWNERS_TEXT" \
    | sed 's/#.*$//' \
    | grep -oE '@[A-Za-z0-9/_-]+' \
    | sed 's/^@//' \
    | grep -v '/' \
    | grep -ivE '^(coderabbitai|coderabbit|greptileai|greptile-apps|greptile|codeant-ai|codeant|cursor|graphite-app|github-actions)$' \
    | grep -ivE '\[bot\]$' \
    | sort -u || true)
  HUMAN_OWNER_COUNT=$(printf '%s\n' "$HUMAN_OWNERS" | grep -cve '^$' || true)

  IS_SOLO=true
  if [[ "$HUMAN_ADMIN_COUNT" -ne 1 ]] || [[ "$(printf '%s' "$HUMAN_ADMINS")" != "$CURRENT_USER" ]]; then
    IS_SOLO=false
  fi
  if [[ "$HUMAN_OWNER_COUNT" -gt 1 ]]; then
    IS_SOLO=false
  fi
  if [[ "$HUMAN_OWNER_COUNT" -eq 1 ]] && [[ "$(printf '%s' "$HUMAN_OWNERS")" != "$CURRENT_USER" ]]; then
    IS_SOLO=false
  fi

  if [[ "$IS_SOLO" != true ]]; then
    echo "REFUSED: $OWNER_REPO does not look solo-owned — admin bypass would skip a real review." >&2
    echo "  human admins ($HUMAN_ADMIN_COUNT): $(printf '%s' "${HUMAN_ADMINS:-none}" | tr '\n' ' ')" >&2
    echo "  human code owners ($HUMAN_OWNER_COUNT): $(printf '%s' "${HUMAN_OWNERS:-none}" | tr '\n' ' ')" >&2
    echo "  current user: $CURRENT_USER" >&2
    echo "Use the standard review flow, or pass --force-solo if you are certain this is solo-owned." >&2
    exit 5
  fi
  SOLO_NOTE="solo-owner verified: 1 human admin ($CURRENT_USER), $HUMAN_OWNER_COUNT human code owner(s)"
else
  SOLO_NOTE="solo-owner check skipped (--force-solo)"
fi

# --------------------------------------------------------------------------
# Pre-flight 3: diagnose the specific protection blocker (enforce_admins)
# --------------------------------------------------------------------------
PROTECTION_JSON=$(gh api "repos/$OWNER/$REPO/branches/$BRANCH/protection" 2>/dev/null || true)
if [[ -z "$PROTECTION_JSON" ]] || ! echo "$PROTECTION_JSON" | jq -e . >/dev/null 2>&1; then
  echo "ERROR: could not read branch protection for $OWNER/$REPO@$BRANCH (need admin token)." >&2
  exit 4
fi
ENFORCE_ADMINS=$(echo "$PROTECTION_JSON" | jq -r '.enforce_admins.enabled // false')
STRICT=$(echo "$PROTECTION_JSON" | jq -r '.required_status_checks.strict // false')

# Default bypass shape: the existing disable→merge→re-enable toggle chain.
BYPASS_MODE=toggle

if [[ "$ENFORCE_ADMINS" != "true" ]]; then
  # enforce_admins is off — still a legitimate admin bypass when the branch is
  # clean-BEHIND and required_status_checks.strict blocks a normal merge.
  # gh pr merge --squash --admin bypasses the strict up-to-date constraint
  # without touching any protection settings.
  if [[ "$STRICT" == "true" && "$CLEAN_BEHIND_OK" == "true" ]]; then
    BYPASS_MODE=plain
  else
    echo "REFUSED: enforce_admins is not enabled on $OWNER/$REPO@$BRANCH — no admin bypass needed." >&2
    echo "If the merge is still blocked, the blocker is something else; inspect:" >&2
    echo "  gh api repos/$OWNER/$REPO/branches/$BRANCH/protection" >&2
    exit 6
  fi
fi

# Surface adjacent (non-enforce_admins) protection settings as informational notes.
EXTRA_NOTES=()
[[ "$(echo "$PROTECTION_JSON" | jq -r '.required_signed_commits.enabled // false')" == "true" ]] && \
  EXTRA_NOTES+=("required_signed_commits is enabled — your merge commit must be signed")
[[ "$(echo "$PROTECTION_JSON" | jq -r '.required_linear_history.enabled // false')" == "true" ]] && \
  EXTRA_NOTES+=("required_linear_history is enabled — squash merge keeps this linear")

# --------------------------------------------------------------------------
# Build the bypass command (single source of truth for the command shape).
# Toggle shape: the re-enable POST is sent with NO body. GitHub returns HTTP 422
# ("enabled is not a permitted key") if a body is supplied (verified on PR #535).
# Plain shape: no protection calls at all — just gh pr merge --squash --admin.
# --------------------------------------------------------------------------
DELETE_CALL="gh api -X DELETE repos/$OWNER/$REPO/branches/$BRANCH/protection/enforce_admins"
MERGE_CALL="gh pr merge $PR_NUMBER --squash --admin"
REENABLE_CALL="gh api -X POST repos/$OWNER/$REPO/branches/$BRANCH/protection/enforce_admins"

if [[ "$BYPASS_MODE" == "plain" ]]; then
  # Plain shape: ordinary --admin merge, no protection toggles.
  BYPASS_CMD=$(printf 'cd %q && \\\n%s' "$REPO_PATH" "$MERGE_CALL")
else
  # Toggle shape: disable enforce_admins → merge → re-enable.
  BYPASS_CMD=$(printf 'cd %q && \\\n%s && \\\n%s && \\\n%s' \
    "$REPO_PATH" "$DELETE_CALL" "$MERGE_CALL" "$REENABLE_CALL")
fi

print_warning_block() {
  echo "# ───────────────────────────────────────────────────────────────────"
  echo "# /admin-merge bypass for PR #$PR_NUMBER ($OWNER_REPO @ $BRANCH)"
  if [[ "$BYPASS_MODE" == "plain" ]]; then
    echo "# Ordinary --admin squash-merge: the PR is clean-BEHIND and"
    echo "# required_status_checks.strict prevents a normal merge — --admin"
    echo "# bypasses that constraint. No protection settings are modified."
  else
    echo "# Claude CANNOT run this — modifying branch protection is prohibited by"
    echo "# Claude's safety rules. You (the repo admin) must run it yourself."
    echo "# It: (1) disables enforce_admins, (2) squash-merges with --admin,"
    echo "#     (3) re-enables enforce_admins (bare POST, no body)."
    echo "# WARNING: this is chained with '&&'. If the merge fails, the final"
    echo "# re-enable is skipped and enforce_admins stays OFF until you re-run:"
    echo "#   $REENABLE_CALL"
    echo "# (Use 'bash .claude/scripts/admin-merge.sh $PR_NUMBER --execute' instead"
    echo "#  to run a trap-protected version that always re-enables protection.)"
  fi
  echo "# $SOLO_NOTE"
  [[ -n "$REPO_PATH_NOTE" ]] && echo "# $REPO_PATH_NOTE"
  for n in "${EXTRA_NOTES[@]:-}"; do [[ -n "$n" ]] && echo "# note: $n"; done
  echo "# ───────────────────────────────────────────────────────────────────"
}

# --------------------------------------------------------------------------
# Mode: print
# --------------------------------------------------------------------------
if [[ "$MODE" == "print" ]]; then
  print_warning_block
  echo "$BYPASS_CMD"
  exit 0
fi

# --------------------------------------------------------------------------
# Mode: launch-terminal (macOS only; never auto-executes the bypass)
# --------------------------------------------------------------------------
if [[ "$MODE" == "launch-terminal" ]]; then
  if [[ "$(uname)" != "Darwin" ]]; then
    echo "NOTE: --launch-terminal is macOS-only. Falling back to inline copy-paste." >&2
    print_warning_block
    echo "$BYPASS_CMD"
    exit 0
  fi

  MARKER="# /admin-merge: command for PR #$PR_NUMBER is in your clipboard — paste (Cmd+V) and Enter to run"
  if ! printf '%s' "$BYPASS_CMD" | pbcopy 2>/dev/null; then
    echo "WARNING: pbcopy failed — printing the command instead." >&2
    print_warning_block
    echo "$BYPASS_CMD"
    exit 0
  fi

  # Prefer iTerm2 when installed; fall back to Terminal.app. Only a safe
  # cd + echo runs in the new terminal — the bypass itself stays in the
  # clipboard and is NEVER auto-executed.
  launched=""
  if [[ -d "/Applications/iTerm.app" ]] || osascript -e 'id of application "iTerm"' >/dev/null 2>&1; then
    if osascript >/dev/null 2>&1 <<OSA
tell application "iTerm"
  activate
  set newWindow to (create window with default profile)
  tell current session of newWindow
    write text "cd " & quoted form of "$REPO_PATH" & " && clear && echo " & quoted form of "$MARKER"
  end tell
end tell
OSA
    then launched="iTerm2"; fi
  fi
  if [[ -z "$launched" ]]; then
    if osascript >/dev/null 2>&1 <<OSA
tell application "Terminal"
  activate
  do script "cd " & quoted form of "$REPO_PATH" & " && clear && echo " & quoted form of "$MARKER"
end tell
OSA
    then launched="Terminal.app"; fi
  fi

  if [[ -z "$launched" ]]; then
    echo "WARNING: could not open iTerm2 or Terminal.app — printing the command instead." >&2
    print_warning_block
    echo "$BYPASS_CMD"
    exit 0
  fi

  print_warning_block
  echo "Opened a new $launched window at: $REPO_PATH"
  echo "The bypass command is in your clipboard — paste (Cmd+V) and Enter to run it."
  exit 0
fi

# --------------------------------------------------------------------------
# Mode: auto-plain (CLAUDE-INVOCABLE, issue #754) — execute the PLAIN shape only.
#
# This branch contains no protection-modifying call, and a non-plain BYPASS_MODE
# refuses before any write — so Claude cannot reach protection modification
# through it even under a degraded context or an injected instruction. The
# structure is the guarantee; the refusal below is a hard gate, not a warning.
# Mechanism + rationale: .claude/reference/admin-merge-auto-plain.md
# --------------------------------------------------------------------------
if [[ "$MODE" == "auto-plain" ]]; then
  # Hard shape gate — anything other than `plain` falls back to printing.
  if [[ "$BYPASS_MODE" != "plain" ]]; then
    echo "AUTO_PLAIN_REFUSED: shape=$BYPASS_MODE — only the plain (no-protection-change) shape may be auto-run; this one modifies branch protection, which Claude must never do. Printing the command for the user instead." >&2
    print_warning_block
    echo "$BYPASS_CMD"
    exit 8
  fi

  # AC gate — clean-behind-check.sh only confirms the Test Plan checkboxes are
  # ticked, which is a mechanical proxy; cr-merge-gate.md Step 2's per-criterion
  # verification against the code at the current SHA is a separate, NON-NEGOTIABLE
  # step. With a human pasting the command, Step 2 had a second chance to happen;
  # unattended it does not, so the caller must attest it ran.
  if [[ "$AC_VERIFIED" != true ]]; then
    echo "AUTO_PLAIN_REFUSED: reason=ac-unverified — pass --ac-verified only after completing cr-merge-gate.md Step 2 (per-criterion Test Plan verification against the code at this SHA). Ticked checkboxes alone are a proxy, not verification. Printing the command instead." >&2
    print_warning_block
    echo "$BYPASS_CMD"
    exit 8
  fi

  # Repeat guard — one auto attempt per PR. A successful merge is terminal, so a
  # second attempt can only follow a failure the pre-flight could not see;
  # retrying it on every /babysit-pr tick would hammer the API and mask the real
  # blocker. The marker is written BEFORE the merge call, so a crash mid-merge
  # disarms the auto path too.
  AUTO_MARKER_DIR="$HOME/.claude/admin-merge-auto"
  AUTO_MARKER="$AUTO_MARKER_DIR/${OWNER}__${REPO}__${PR_NUMBER}"
  if [[ -e "$AUTO_MARKER" ]]; then
    echo "AUTO_PLAIN_REFUSED: reason=repeat — an auto-plain attempt already ran for PR #$PR_NUMBER ($(tr '\n' ' ' < "$AUTO_MARKER" 2>/dev/null)). Printing the command instead; re-arm with: rm \"$AUTO_MARKER\"" >&2
    print_warning_block
    echo "$BYPASS_CMD"
    exit 8
  fi

  # NOTE: the process is already inside $REPO_PATH — it was entered right after
  # argument parsing (issue #1439), so `gh pr merge` below (which infers
  # owner/repo from the cwd's git remote) targets the intended repo regardless of
  # the invoker's cwd, and an unusable path already refused with exit 7 there.
  # Do not re-add a cd here: one early cd is the single source of truth.

  # Mandatory re-validation (TOCTOU): CLEAN_BEHIND_OK above is a snapshot, and
  # main may have advanced since — turning a clean BEHIND into one whose base
  # delta now overlaps this PR's lines. Capture the JSON this time: the evidence
  # report must describe the state that actually authorized the merge, not the
  # stale pre-flight snapshot. Reaching `plain` at all requires CLEAN_BEHIND_OK,
  # which requires CBC to have been found and to have supplied accepted evidence
  # (exit 0, or the narrowly recovered exit-1 reviewDecision asymmetry) — so this
  # check can never be skipped by a missing helper, but verify rather than assume.
  if [[ -z "${CBC:-}" ]]; then
    echo "REFUSED: clean-behind-check.sh unavailable — cannot re-validate the clean-BEHIND state before an auto merge." >&2
    exit 1
  fi
  CBC_JSON="$("$CBC" "${CBC_ARGS[@]}" 2>/dev/null)"
  CBC_RC=$?
  if ! clean_behind_evidence_allows_admin "$CBC_JSON" "$CBC_RC"; then
    echo "REFUSED: the clean-BEHIND state no longer holds (main advanced, or a new blocker appeared) — rebase and re-run instead of bypassing." >&2
    exit 1
  fi

  # Evidence field extractor: tolerate missing/unparseable JSON rather than
  # aborting a verified-safe merge over a cosmetic report field.
  ev() {
    local v
    v=$(printf '%s' "$CBC_JSON" | jq -r "$1" 2>/dev/null || true)
    if [[ -z "$v" || "$v" == "null" ]]; then v="?"; fi
    printf '%s' "$v"
  }
  AUTO_HEAD_SHA="$(ev '.head_sha')"

  # Arm the repeat guard BEFORE merging, and fail closed if it cannot be armed —
  # merging with a silently-disarmed guard is exactly the unbounded-retry scenario
  # the guard exists to prevent (an unwritable $HOME would otherwise let every
  # /babysit-pr tick re-attempt an --admin merge).
  if ! mkdir -p "$AUTO_MARKER_DIR" 2>/dev/null ||
     ! printf '%s\tpr=%s\thead=%s\n' "$(date -u +%FT%TZ)" "$PR_NUMBER" "$AUTO_HEAD_SHA" > "$AUTO_MARKER" 2>/dev/null; then
    echo "AUTO_PLAIN_REFUSED: reason=guard-unwritable — could not write the repeat-guard marker ($AUTO_MARKER); refusing rather than merging with the retry guard disarmed. Fix the path (or its permissions) and re-run. Printing the command instead." >&2
    print_warning_block
    echo "$BYPASS_CMD"
    exit 8
  fi

  print_warning_block
  echo "[admin-merge] auto-plain: squash-merging PR #$PR_NUMBER with --admin (strict up-to-date + re-validated clean-BEHIND) ..."
  if ! $MERGE_CALL; then
    echo "ERROR: 'gh pr merge --admin' failed." >&2
    exit 7
  fi

  # A successful `gh pr merge --admin` does not guarantee an immediately
  # consistent read of PR state (read-after-write lag, or a queued/deferred merge
  # on repos with a merge queue) — retry before concluding it did not complete.
  FINAL_MERGED="unknown"
  for _attempt in 1 2 3; do
    FINAL_MERGED=$(gh pr view "$PR_NUMBER" --json state --jq '(.state == "MERGED")' 2>/dev/null || echo "unknown")
    [[ "$FINAL_MERGED" == "true" ]] && break
    (( _attempt < 3 )) && sleep 2
  done
  if [[ "$FINAL_MERGED" != "true" ]]; then
    echo "[admin-merge] auto-plain: PR merged=$FINAL_MERGED"
    echo "WARNING: PR does not report state=MERGED after retrying — the merge may not have completed (e.g. a queued/deferred merge). Verify manually: gh pr view $PR_NUMBER --json state,mergedAt" >&2
    exit 7
  fi
  release_issue_claim

  # After-the-fact report (issue #754): which PR, which shape, and the
  # clean-BEHIND evidence that authorized the bypass. Relay this to the user.
  echo "# ───────────────────────────────────────────────────────────────────"
  echo "# AUTO_PLAIN_MERGED: PR #$PR_NUMBER ($OWNER_REPO @ $BRANCH)"
  echo "# shape:      plain — bare 'gh pr merge --squash --admin'; NO branch-protection call"
  echo "# head SHA:   $AUTO_HEAD_SHA"
  echo "# authorized by clean-behind-check.sh, re-validated immediately before the merge:"
  echo "#   base ahead by:  $(ev '.churn.base_ahead_by') commit(s)"
  echo "#   file overlap:   $(ev '.file_overlap.count') ($(ev '.file_overlap.granularity') granularity)"
  echo "#   AC checkboxes:  $(ev '.ac.checked')/$(ev '.ac.total') checked"
  echo "# $SOLO_NOTE"
  echo "# ───────────────────────────────────────────────────────────────────"
  exit 0
fi

# --------------------------------------------------------------------------
# Mode: execute (USER-INVOKED ONLY) — toggle-merge-toggle with safe re-enable.
# --------------------------------------------------------------------------
if [[ "$MODE" == "execute" ]]; then
  # NOTE: the process is already inside $REPO_PATH — it was entered right after
  # argument parsing (issue #1439), mirroring the cd-prefix baked into the
  # --print one-liner, so `gh pr merge` targets the intended repo regardless of
  # the invoker's cwd. An unusable path refused with exit 7 there, well before
  # any protection call. Do not re-add a cd here.

  # Safety-critical revalidation (issue #631): the pre-flight above computed
  # CLEAN_BEHIND_OK from a snapshot. When this bypass is proceeding over a clean
  # BEHIND, re-run clean-behind-check.sh right before touching protection — main
  # may have advanced since the pre-flight, turning a clean BEHIND into one whose
  # base delta now overlaps the PR's files. Refuse if it no longer holds. (This
  # runs before enforce_admins is disabled, so a refusal leaves protection intact.)
  if [[ "$CLEAN_BEHIND_OK" == true && -n "${CBC:-}" ]]; then
    CBC_JSON="$("$CBC" "${CBC_ARGS[@]}" 2>/dev/null)"
    CBC_RC=$?
    if ! clean_behind_evidence_allows_admin "$CBC_JSON" "$CBC_RC"; then
      echo "REFUSED: the clean-BEHIND state no longer holds (main advanced, or a new blocker appeared) — rebase and re-run instead of bypassing." >&2
      exit 1
    fi
  fi

  # Plain shape (no protection toggles): just run the admin merge directly.
  if [[ "$BYPASS_MODE" == "plain" ]]; then
    print_warning_block
    echo "[admin-merge] squash-merging PR #$PR_NUMBER with --admin (strict up-to-date + clean-BEHIND) ..."
    if ! $MERGE_CALL; then
      echo "ERROR: 'gh pr merge --admin' failed." >&2
      exit 7
    fi
    FINAL_MERGED="unknown"
    for _attempt in 1 2 3; do
      FINAL_MERGED=$(gh pr view "$PR_NUMBER" --json state --jq '(.state == "MERGED")' 2>/dev/null || echo "unknown")
      [[ "$FINAL_MERGED" == "true" ]] && break
      (( _attempt < 3 )) && sleep 2
    done
    echo "[admin-merge] done: PR merged=$FINAL_MERGED"
    if [[ "$FINAL_MERGED" != "true" ]]; then
      echo "WARNING: PR does not report state=MERGED after retrying — verify manually: gh pr view $PR_NUMBER --json state,mergedAt" >&2
      exit 7
    fi
    release_issue_claim
    exit 0
  fi

  # Toggle shape (enforce_admins=true): disable → merge → re-enable.
  ENFORCE_DISABLED=0
  ENFORCE_REENABLED=0

  reenable_protection() {
    if [[ "$ENFORCE_DISABLED" == "1" && "$ENFORCE_REENABLED" != "1" ]]; then
      echo "[admin-merge] trap: re-enabling enforce_admins on $OWNER/$REPO@$BRANCH ..." >&2
      if $REENABLE_CALL >/dev/null 2>&1; then
        ENFORCE_REENABLED=1
        echo "[admin-merge] trap: enforce_admins re-enabled." >&2
      else
        echo "[admin-merge] trap: FAILED to re-enable enforce_admins — re-run manually:" >&2
        echo "  $REENABLE_CALL" >&2
      fi
    fi
  }
  trap reenable_protection EXIT

  print_warning_block
  echo "[admin-merge] disabling enforce_admins ..."
  if ! $DELETE_CALL >/dev/null 2>&1; then
    echo "ERROR: failed to disable enforce_admins (need admin token)." >&2
    exit 7
  fi
  ENFORCE_DISABLED=1

  echo "[admin-merge] squash-merging PR #$PR_NUMBER with --admin ..."
  if ! $MERGE_CALL; then
    echo "ERROR: 'gh pr merge --admin' failed — trap will re-enable enforce_admins." >&2
    exit 7
  fi

  # Explicit normal-flow re-enable (also keeps reenable_protection reachable for
  # static analysis; the EXIT trap is the failure-path safety net).
  echo "[admin-merge] re-enabling enforce_admins ..."
  reenable_protection
  if [[ "$ENFORCE_REENABLED" != "1" ]]; then
    echo "ERROR: failed to re-enable enforce_admins — re-run manually:" >&2
    echo "  $REENABLE_CALL" >&2
    exit 7
  fi

  # Post-verify: protection restored + PR merged. Retry the merge-state read a
  # few times — a successful `gh pr merge --admin` does not guarantee an
  # immediately-consistent read of PR state (read-after-write lag, or a
  # queued/deferred merge on repos with a merge queue enabled) — before
  # concluding the merge did not complete.
  FINAL_ENFORCE=$(gh api "repos/$OWNER/$REPO/branches/$BRANCH/protection/enforce_admins" --jq '.enabled' 2>/dev/null || echo "unknown")
  FINAL_MERGED="unknown"
  for _attempt in 1 2 3; do
    FINAL_MERGED=$(gh pr view "$PR_NUMBER" --json state --jq '(.state == "MERGED")' 2>/dev/null || echo "unknown")
    [[ "$FINAL_MERGED" == "true" ]] && break
    (( _attempt < 3 )) && sleep 2
  done
  echo "[admin-merge] done: PR merged=$FINAL_MERGED, enforce_admins enabled=$FINAL_ENFORCE"
  if [[ "$FINAL_MERGED" != "true" ]]; then
    echo "WARNING: PR does not report state=MERGED after retrying — the merge may not have completed (e.g. a queued/deferred merge). Verify manually: gh pr view $PR_NUMBER --json state,mergedAt" >&2
    exit 7
  fi
  if [[ "$FINAL_ENFORCE" != "true" ]]; then
    echo "WARNING: enforce_admins did not report enabled=true — verify manually." >&2
    exit 7
  fi
  release_issue_claim
  exit 0
fi

echo "ERROR: unhandled mode: $MODE" >&2
exit 2
