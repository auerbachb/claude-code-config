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
# protection. This script keeps that boundary intact: in its DEFAULT mode it only
# *prints* the exact bypass command for the user to run — it never modifies
# protection itself. The protection-modifying dance runs ONLY when the USER
# invokes the script with the explicit `--execute` flag (and even then a `trap`
# re-enables protection if anything fails mid-dance).
#
# The `/admin-merge` skill always invokes this script in `--print` (or
# `--launch-terminal`) mode — never `--execute`. See .claude/skills/admin-merge/.
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
#   --execute          USER-INVOKED ONLY. Run the toggle-merge-toggle dance with a
#                      trap that re-enables enforce_admins on any failure, then
#                      verify protection is restored and the PR merged.
#
# Options:
#   --repo-path <path>  Absolute path of the local clone to cd into (default:
#                       repo-root.sh / git toplevel of the cwd).
#   --branch <name>     Protected branch (default: the PR's base branch).
#   --force-solo        Skip the solo-owner heuristic (treat repo as solo-owned).
#   --reviewer cr|bugbot|greptile   Pass through to merge-gate.sh.
#   -h, --help          Print this header.
#
# Exit codes:
#   0 — bypass command printed (print/launch) OR dance completed (execute)
#   1 — refused: PR not merge-ready (hard blockers / human changes requested)
#   2 — usage error
#   3 — PR not found / not open
#   4 — gh / network / jq error
#   5 — refused: repo is not solo-owned (would skip a real review)
#   6 — refused: no enforce_admins protection block detected (nothing to bypass)
#   7 — execute-mode failure (merge failed; trap re-enabled protection)

set -uo pipefail
printf '%s\t%s\t%s\n' "$(date -u +%FT%TZ)" "$(basename "$0")" "${*//$'\n'/ }" >> "$HOME/.claude/script-usage.log" 2>/dev/null || true

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

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
# Resolve owner/repo + PR metadata
# --------------------------------------------------------------------------
OWNER_REPO=$(gh repo view --json nameWithOwner --jq '.nameWithOwner' 2>/dev/null || true)
if [[ -z "$OWNER_REPO" ]]; then
  echo "ERROR: 'gh repo view' failed — not in a git repo or no remote configured." >&2
  exit 4
fi
OWNER="${OWNER_REPO%/*}"
REPO="${OWNER_REPO#*/}"

PR_JSON=$(gh pr view "$PR_NUMBER" --json number,state,baseRefName,headRefName,merged 2>/dev/null || true)
if [[ -z "$PR_JSON" ]]; then
  echo "ERROR: PR #$PR_NUMBER not found in $OWNER_REPO." >&2
  exit 3
fi
PR_STATE=$(echo "$PR_JSON" | jq -r '.state // "UNKNOWN"')
PR_MERGED=$(echo "$PR_JSON" | jq -r '.merged // false')
BASE_REF=$(echo "$PR_JSON" | jq -r '.baseRefName // ""')

if [[ "$PR_MERGED" == "true" ]]; then
  echo "PR #$PR_NUMBER is already merged — nothing to do." >&2
  exit 3
fi
if [[ "$PR_STATE" != "OPEN" ]]; then
  echo "ERROR: PR #$PR_NUMBER is $PR_STATE — not open." >&2
  exit 3
fi

BRANCH="${BRANCH_OVERRIDE:-$BASE_REF}"
if [[ -z "$BRANCH" ]]; then
  echo "ERROR: could not determine the protected branch (pass --branch)." >&2
  exit 4
fi

# --------------------------------------------------------------------------
# Resolve absolute path of the local clone (for the cd-prefix)
# --------------------------------------------------------------------------
resolve_repo_path() {
  if [[ -n "$REPO_PATH_OVERRIDE" ]]; then
    echo "$REPO_PATH_OVERRIDE"; return
  fi
  local p=""
  if [[ -x "$SCRIPT_DIR/repo-root.sh" ]]; then
    p="$("$SCRIPT_DIR/repo-root.sh" 2>/dev/null || true)"
  fi
  if [[ -z "$p" ]]; then
    p="$(git rev-parse --show-toplevel 2>/dev/null || true)"
  fi
  if [[ -z "$p" ]]; then
    p="$PWD"
  fi
  echo "$p"
}
REPO_PATH="$(resolve_repo_path)"
REPO_PATH_NOTE=""
if [[ ! -d "$REPO_PATH" ]]; then
  REPO_PATH_NOTE="WARNING: resolved repo path '$REPO_PATH' is not a directory — pass --repo-path <abs-path>."
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
# set -e is intentionally off, so a non-zero merge-gate exit (e.g. 1 = gate not
# met) does not abort here — capture the real exit code, then inspect the JSON.
GATE_JSON="$("$MERGE_GATE" "${GATE_ARGS[@]}" 2>/dev/null)"
GATE_EXIT=$?
if [[ -z "$GATE_JSON" ]] || ! echo "$GATE_JSON" | jq -e . >/dev/null 2>&1; then
  echo "ERROR: merge-gate.sh produced no parseable JSON (exit $GATE_EXIT)." >&2
  exit 4
fi

# Hard blockers = every missing reason that is NOT the branch-protection
# reviewDecision note (which is exactly what the admin bypass exists to step over).
HARD_BLOCKERS=$(echo "$GATE_JSON" | jq -r '
  [.missing[]? | select(test("branch protection reviewDecision") | not)]
  | .[]')
HUMAN_CHANGES=$(echo "$GATE_JSON" | jq -r '[.human_changes_requested[]?] | join(", ")')

if [[ -n "$HUMAN_CHANGES" ]]; then
  echo "REFUSED: human reviewer(s) requested changes on HEAD: $HUMAN_CHANGES" >&2
  echo "Admin bypass must NOT skip a human change request. Address it first." >&2
  exit 1
fi
if [[ -n "$HARD_BLOCKERS" ]]; then
  echo "REFUSED: PR #$PR_NUMBER is not merge-ready apart from branch protection. Outstanding blockers:" >&2
  while IFS= read -r line; do [[ -n "$line" ]] && echo "  - $line" >&2; done <<< "$HARD_BLOCKERS"
  echo "Fix these (CI / approval / threads / rebase) before using /admin-merge." >&2
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

if [[ "$ENFORCE_ADMINS" != "true" ]]; then
  echo "REFUSED: enforce_admins is not enabled on $OWNER/$REPO@$BRANCH — no admin bypass needed." >&2
  echo "If the merge is still blocked, the blocker is something else; inspect:" >&2
  echo "  gh api repos/$OWNER/$REPO/branches/$BRANCH/protection" >&2
  exit 6
fi

# Surface adjacent (non-enforce_admins) protection settings as informational notes.
EXTRA_NOTES=()
[[ "$(echo "$PROTECTION_JSON" | jq -r '.required_signed_commits.enabled // false')" == "true" ]] && \
  EXTRA_NOTES+=("required_signed_commits is enabled — your merge commit must be signed")
[[ "$(echo "$PROTECTION_JSON" | jq -r '.required_linear_history.enabled // false')" == "true" ]] && \
  EXTRA_NOTES+=("required_linear_history is enabled — squash merge keeps this linear")

# --------------------------------------------------------------------------
# Build the bypass command (single source of truth for the command shape).
# NOTE: the re-enable POST is sent with NO body. GitHub returns HTTP 422
# ("enabled is not a permitted key") if a body is supplied (verified on PR #535).
# --------------------------------------------------------------------------
DELETE_CALL="gh api -X DELETE repos/$OWNER/$REPO/branches/$BRANCH/protection/enforce_admins"
MERGE_CALL="gh pr merge $PR_NUMBER --squash --admin"
REENABLE_CALL="gh api -X POST repos/$OWNER/$REPO/branches/$BRANCH/protection/enforce_admins"

BYPASS_CMD=$(printf 'cd %q && \\\n%s && \\\n%s && \\\n%s' \
  "$REPO_PATH" "$DELETE_CALL" "$MERGE_CALL" "$REENABLE_CALL")

print_warning_block() {
  echo "# ───────────────────────────────────────────────────────────────────"
  echo "# /admin-merge bypass for PR #$PR_NUMBER ($OWNER_REPO @ $BRANCH)"
  echo "# Claude CANNOT run this — modifying branch protection is prohibited by"
  echo "# Claude's safety rules. You (the repo admin) must run it yourself."
  echo "# It: (1) disables enforce_admins, (2) squash-merges with --admin,"
  echo "#     (3) re-enables enforce_admins (bare POST, no body)."
  echo "# WARNING: this is chained with '&&'. If the merge fails, the final"
  echo "# re-enable is skipped and enforce_admins stays OFF until you re-run:"
  echo "#   $REENABLE_CALL"
  echo "# (Use 'bash .claude/scripts/admin-merge.sh $PR_NUMBER --execute' instead"
  echo "#  to run a trap-protected version that always re-enables protection.)"
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
# Mode: execute (USER-INVOKED ONLY) — toggle-merge-toggle with safe re-enable.
# --------------------------------------------------------------------------
if [[ "$MODE" == "execute" ]]; then
  # Run from the resolved clone so `gh pr merge` (which infers owner/repo from
  # the cwd's git remote) targets the intended repo regardless of the invoker's
  # cwd — mirrors the cd-prefix baked into the --print one-liner. Fail before
  # touching protection if the path is bad.
  if ! cd "$REPO_PATH" 2>/dev/null; then
    echo "ERROR: cannot cd into repo path '$REPO_PATH' — pass --repo-path <abs-path>." >&2
    exit 7
  fi

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

  # Post-verify: protection restored + PR merged.
  FINAL_ENFORCE=$(gh api "repos/$OWNER/$REPO/branches/$BRANCH/protection/enforce_admins" --jq '.enabled' 2>/dev/null || echo "unknown")
  FINAL_MERGED=$(gh pr view "$PR_NUMBER" --json merged --jq '.merged' 2>/dev/null || echo "unknown")
  echo "[admin-merge] done: PR merged=$FINAL_MERGED, enforce_admins enabled=$FINAL_ENFORCE"
  if [[ "$FINAL_ENFORCE" != "true" ]]; then
    echo "WARNING: enforce_admins did not report enabled=true — verify manually." >&2
    exit 7
  fi
  exit 0
fi

echo "ERROR: unhandled mode: $MODE" >&2
exit 2
