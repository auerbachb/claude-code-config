#!/usr/bin/env bash
# repo-bootstrap.sh — Check (and optionally install) required repo configuration.
#
# Implements the contract from .claude/rules/repo-bootstrap.md:
#   1. Workflows: ensure .github/workflows/cr-plan-on-issue.yml exists.
#   2. Branch protection on main: report status only — never modified by this
#      script (the rule requires user confirmation, so the script defers).
#
# Usage:
#   repo-bootstrap.sh [--check]   # default: report status, no mutation
#   repo-bootstrap.sh --apply     # install missing workflows; never touches
#                                 # branch protection
#   repo-bootstrap.sh -h|--help   # print this usage and exit
#
# Exit codes:
#   0 — all checks pass (--check clean, or --apply succeeded with no remaining
#       gaps that the script is allowed to fix)
#   1 — gaps detected. In --check: workflow missing OR branch protection not
#       configured. In --apply: branch protection still requires user
#       confirmation (workflow gaps were applied successfully).
#   2 — usage error
#   3 — environment error (not in a git repo, no remote, cannot resolve
#       owner/repo)
#   4 — gh / network error
#   5 — write failure during --apply (mkdir or workflow file write failed)
#
# Safety:
#   - Never overwrites existing workflow files (idempotent-add-only).
#   - Never modifies branch protection — that requires user confirmation per
#     .claude/rules/repo-bootstrap.md. The script reports status only.
#   - Read-only gh API calls are used for the branch-protection check.

set -uo pipefail

MODE="check"
for arg in "$@"; do
  case "$arg" in
    --check)
      MODE="check"
      ;;
    --apply)
      MODE="apply"
      ;;
    -h|--help)
      sed -n '2,32p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *)
      echo "repo-bootstrap.sh: unknown argument: $arg" >&2
      echo "Run with --help for usage." >&2
      exit 2
      ;;
  esac
done

if ! command -v gh >/dev/null 2>&1; then
  echo "repo-bootstrap.sh: gh CLI not found on PATH" >&2
  exit 3
fi

# Resolve git toplevel — script writes into this dir's .github/workflows/.
if ! REPO_TOP=$(git rev-parse --show-toplevel 2>/dev/null); then
  echo "repo-bootstrap.sh: not in a git repository" >&2
  exit 3
fi

# Resolve owner/repo for the branch-protection API call.
OWNER_REPO_ERR=$(mktemp)
trap 'rm -f "$OWNER_REPO_ERR"' EXIT
if ! OWNER_REPO=$(gh repo view --json nameWithOwner --jq '.nameWithOwner' 2>"$OWNER_REPO_ERR"); then
  echo "repo-bootstrap.sh: could not resolve owner/repo via 'gh repo view':" >&2
  cat "$OWNER_REPO_ERR" >&2
  exit 3
fi
if [[ -z "$OWNER_REPO" ]]; then
  echo "repo-bootstrap.sh: 'gh repo view' returned empty owner/repo" >&2
  exit 3
fi

WORKFLOW_REL=".github/workflows/cr-plan-on-issue.yml"
WORKFLOW_PATH="$REPO_TOP/$WORKFLOW_REL"

# Canonical workflow content. Single-quoted heredoc so `${...}` and `$(...)`
# inside the YAML's GitHub Actions expressions are written literally.
read_workflow_content() {
  cat <<'WORKFLOW_EOF'
name: Trigger CodeRabbit Plan on New Issues

on:
  issues:
    types: [opened]

permissions:
  issues: write

jobs:
  trigger-cr-plan:
    runs-on: ubuntu-latest
    if: "!endsWith(github.event.issue.user.login, '[bot]')"
    steps:
      - name: Comment @coderabbitai plan
        uses: actions/github-script@v7
        with:
          script: |
            await github.rest.issues.createComment({
              owner: context.repo.owner,
              repo: context.repo.repo,
              issue_number: context.issue.number,
              body: '@coderabbitai plan'
            });
WORKFLOW_EOF
}

# --------------------------------------------------------------------------
# Workflow check
# --------------------------------------------------------------------------
WORKFLOW_PRESENT=0
WORKFLOW_INSTALLED=0
if [[ -f "$WORKFLOW_PATH" ]]; then
  WORKFLOW_PRESENT=1
fi

# --------------------------------------------------------------------------
# Branch protection check (read-only — never modified)
# --------------------------------------------------------------------------
# Capture the response and HTTP status separately. `gh api` returns non-zero on
# 4xx, but we need to distinguish 404 (not configured — actionable) from 403
# (no permission — skip with a note) from other gh failures (network, auth).
BP_BODY_FILE=$(mktemp)
BP_STDERR_FILE=$(mktemp)
trap 'rm -f "$OWNER_REPO_ERR" "$BP_BODY_FILE" "$BP_STDERR_FILE"' EXIT

BP_STATE="unknown"
BP_CHECKS=""
BP_NOTE=""
if gh api "repos/$OWNER_REPO/branches/main/protection/required_status_checks" \
    >"$BP_BODY_FILE" 2>"$BP_STDERR_FILE"; then
  # 200 — configured. Extract the contexts array (contexts is the legacy field;
  # checks[].context is the newer field — prefer checks[].context, fall back to
  # contexts).
  BP_STATE="configured"
  BP_CHECKS=$(jq -r '
    if (.checks | type) == "array" and (.checks | length) > 0 then
      [.checks[].context] | join(", ")
    elif (.contexts | type) == "array" then
      .contexts | join(", ")
    else "" end
  ' "$BP_BODY_FILE" 2>/dev/null || true)
else
  BP_STDERR=$(cat "$BP_STDERR_FILE")
  if printf '%s' "$BP_STDERR" | grep -qiE 'HTTP 404|Not Found|Branch not protected'; then
    BP_STATE="missing"
    BP_NOTE="404 — required status checks not configured."
  elif printf '%s' "$BP_STDERR" | grep -qiE 'HTTP 403|forbidden|must have admin'; then
    BP_STATE="no_permission"
    BP_NOTE="403 — token lacks permission to read branch protection."
  else
    echo "repo-bootstrap.sh: gh api failed for branch protection:" >&2
    printf '%s\n' "$BP_STDERR" >&2
    exit 4
  fi
fi

# --------------------------------------------------------------------------
# Apply mode — install missing workflow file (never overwrites)
# --------------------------------------------------------------------------
if [[ "$MODE" == "apply" ]] && [[ "$WORKFLOW_PRESENT" -eq 0 ]]; then
  WORKFLOW_DIR="$(dirname "$WORKFLOW_PATH")"
  if ! mkdir -p "$WORKFLOW_DIR"; then
    echo "repo-bootstrap.sh: failed to create $WORKFLOW_DIR" >&2
    exit 5
  fi
  if ! read_workflow_content >"$WORKFLOW_PATH"; then
    echo "repo-bootstrap.sh: failed to write $WORKFLOW_PATH" >&2
    exit 5
  fi
  WORKFLOW_INSTALLED=1
  WORKFLOW_PRESENT=1
fi

# --------------------------------------------------------------------------
# Report
# --------------------------------------------------------------------------
echo "Repo Bootstrap Report"
echo "====================="
echo "Repo: $OWNER_REPO"
echo "Mode: $MODE"
echo
echo "Workflows:"
if [[ "$WORKFLOW_PRESENT" -eq 1 ]]; then
  if [[ "$WORKFLOW_INSTALLED" -eq 1 ]]; then
    echo "  [INSTALLED] $WORKFLOW_REL"
  else
    echo "  [OK]        $WORKFLOW_REL"
  fi
else
  echo "  [MISSING]   $WORKFLOW_REL"
fi
echo
echo "Branch Protection (main):"
case "$BP_STATE" in
  configured)
    if [[ -n "$BP_CHECKS" ]]; then
      echo "  [OK]        Required status checks configured: $BP_CHECKS"
    else
      echo "  [OK]        Required status checks configured (no contexts listed)"
    fi
    ;;
  missing)
    echo "  [MISSING]   $BP_NOTE"
    echo "              User confirmation required to enable — see"
    echo "              .claude/rules/repo-bootstrap.md."
    ;;
  no_permission)
    echo "  [SKIP]      $BP_NOTE"
    ;;
  *)
    echo "  [UNKNOWN]   could not determine branch protection state"
    ;;
esac

# --------------------------------------------------------------------------
# Exit code
# --------------------------------------------------------------------------
GAPS=0
if [[ "$WORKFLOW_PRESENT" -eq 0 ]]; then
  GAPS=1
fi
if [[ "$BP_STATE" == "missing" ]]; then
  GAPS=1
fi

if [[ "$GAPS" -eq 1 ]]; then
  echo
  if [[ "$MODE" == "check" ]]; then
    echo "Gaps detected. Re-run with --apply to install missing workflows."
    echo "Branch protection (if missing) requires user confirmation."
  else
    # apply mode — only branch-protection gap can remain
    echo "Workflow gaps applied. Branch protection still requires user confirmation."
  fi
  exit 1
fi

exit 0
