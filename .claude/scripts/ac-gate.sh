#!/usr/bin/env bash
# ac-gate.sh — CI gate: fail a PR that has unchecked acceptance-criteria boxes.
#
# Reads the PR body and applies a two-stage check:
#
#   Stage 1 — unchecked boxes in scope
#     Scans the `## Acceptance Criteria` and `## Test plan` / `## Test Plan`
#     sections (case-insensitive, matching the ac-checkboxes.sh convention).
#     Any unchecked `- [ ]` outside the exemption section is a hard failure.
#
#   Stage 2 — exemption region (`## Post-merge verification`)
#     The heading must match EXACTLY (spelling and case). A differently-cased
#     or misspelled heading is not treated as an exemption region.
#     Unchecked boxes inside the exemption section pass only when all three
#     ordered checks succeed:
#       1. A `Tracking issue: #N` line exists inside the section.
#       2. Issue #N is NOT one of the issues this PR closes
#          (the PR #588 self-referential case — the tracking issue closes with
#          the PR and the deferred work is sealed inside a closed issue).
#       3. Issue #N is OPEN (not CLOSED).
#     A `Tracking issue:` line outside the section grants no exemption.
#
# A PR with no unchecked boxes in scope, or with an empty body, passes.
#
# USAGE:
#   ac-gate.sh <pr_number>
#   ac-gate.sh --help | -h
#
# OUTPUT:
#   Single status line on stdout: "AC gate: PASS" or failure detail on stderr.
#
# EXIT CODES:
#   0    gate passed (no unchecked in-scope boxes, or exemption checks passed)
#   1    unchecked box outside Post-merge verification section
#   2    usage error (missing/invalid args, unknown flag)
#   3    PR not found
#   4    gh / GitHub API error, or pr-issue-ref.sh not found
#   5    exemption section has no Tracking issue: #N line
#   6    tracking issue is one this PR closes (self-referential — PR #588 case)
#   7    tracking issue is CLOSED
#
# DEPENDENCIES:
#   - gh (authenticated)
#   - pr-issue-ref.sh (sibling script; resolved from same directory)
#
# EXAMPLES:
#   ac-gate.sh 1234    # exits 0 (pass) or non-zero (fail, message on stderr)

set -euo pipefail
printf '%s\t%s\t%s\n' "$(date -u +%FT%TZ)" "$(basename "$0")" "${*//$'\n'/ }" >> "$HOME/.claude/script-usage.log" 2>/dev/null || true

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PR_ISSUE_REF_SH="$SCRIPT_DIR/pr-issue-ref.sh"

print_usage() {
  cat <<'EOF'
Usage: ac-gate.sh <pr_number>
       ac-gate.sh --help | -h

Gate a PR on unchecked acceptance-criteria boxes. Scans the Acceptance
Criteria and Test Plan sections for unchecked `- [ ]` items. Unchecked
items under `## Post-merge verification` (exact heading) may be deferred
when a valid open tracking issue is named inside the section.

Exit codes:
  0  gate passed
  1  unchecked box outside Post-merge verification section
  2  usage error
  3  PR not found
  4  gh / API error, or pr-issue-ref.sh not found
  5  exemption section missing Tracking issue: #N line
  6  tracking issue is one this PR closes (self-referential)
  7  tracking issue is CLOSED
EOF
}

# --- arg parsing ---
PR_NUM=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help)
      print_usage
      exit 0
      ;;
    --)
      shift
      while [[ $# -gt 0 ]]; do
        if [[ -n "$PR_NUM" ]]; then
          echo "Error: unexpected positional argument: $1" >&2
          print_usage >&2
          exit 2
        fi
        PR_NUM="$1"
        shift
      done
      break
      ;;
    -*)
      echo "Error: unknown flag: $1" >&2
      print_usage >&2
      exit 2
      ;;
    *)
      if [[ -n "$PR_NUM" ]]; then
        echo "Error: unexpected positional argument: $1" >&2
        print_usage >&2
        exit 2
      fi
      PR_NUM="$1"
      shift
      ;;
  esac
done

if [[ -z "$PR_NUM" ]]; then
  echo "Error: <pr_number> is required" >&2
  print_usage >&2
  exit 2
fi

if ! [[ "$PR_NUM" =~ ^[1-9][0-9]*$ ]]; then
  echo "Error: <pr_number> must be a positive integer, got: $PR_NUM" >&2
  exit 2
fi

# --- dependency checks ---
if ! command -v gh >/dev/null 2>&1; then
  echo "Error: 'gh' CLI not found on PATH" >&2
  exit 4
fi

if [[ ! -f "$PR_ISSUE_REF_SH" ]]; then
  echo "Error: pr-issue-ref.sh not found at '$PR_ISSUE_REF_SH'" >&2
  exit 4
fi

# --- fetch PR body ---
GH_STDERR="$(mktemp)"
GH_ISSUE_STDERR="$(mktemp)"
trap 'rm -f "$GH_STDERR" "$GH_ISSUE_STDERR"' EXIT

if ! BODY="$(gh pr view "$PR_NUM" --json body --jq '.body // ""' 2>"$GH_STDERR")"; then
  if grep -qiE 'not.?found|could not resolve|no pull requests? found' "$GH_STDERR"; then
    echo "Error: PR #$PR_NUM not found" >&2
    exit 3
  fi
  sed 's/^/gh: /' "$GH_STDERR" >&2
  echo "Error: gh pr view failed for PR #$PR_NUM" >&2
  exit 4
fi

# --- parse body sections ---
# State machine: other | ac | testplan | postmerge
# In-scope sections (AC/Test Plan): case-insensitive heading match.
# Exemption section (Post-merge verification): EXACT heading match only.
#
# Variables collected during parsing:
#   HAS_UNCHECKED_INSCOPE  1 if any unchecked box in ac or testplan
#   HAS_UNCHECKED_EXEMPT   1 if any unchecked box in postmerge
#   TRACKING_ISSUE         issue number from "Tracking issue: #N" inside postmerge

STATE="other"
HAS_UNCHECKED_INSCOPE=0
HAS_UNCHECKED_EXEMPT=0
TRACKING_ISSUE=""

while IFS= read -r raw_line || [[ -n "$raw_line" ]]; do
  # Strip CRLF (defensive: body from gh may carry Windows line endings)
  line="${raw_line%$'\r'}"

  # --- level-2 heading detection ---
  if printf '%s' "$line" | grep -qE '^## '; then
    # Extract heading text: strip "## " prefix and trailing whitespace
    heading_raw="${line#\#\# }"
    heading="$(printf '%s' "$heading_raw" | sed 's/[[:space:]]*$//')"

    # Case-insensitive match for in-scope sections
    heading_lower="$(printf '%s' "$heading" | tr 'A-Z' 'a-z')"

    case "$heading_lower" in
      "acceptance criteria")
        STATE="ac"
        ;;
      "test plan")
        STATE="testplan"
        ;;
      *)
        # EXACT case match for exemption section (any other casing does NOT grant exemption)
        if [[ "$heading" == "Post-merge verification" ]]; then
          STATE="postmerge"
          TRACKING_ISSUE=""  # reset: each Post-merge section is independent
        else
          STATE="other"
        fi
        ;;
    esac
    continue
  fi

  # --- unchecked box detection (`- [ ]` with optional leading whitespace) ---
  if printf '%s' "$line" | grep -qE '^[[:space:]]*-[[:space:]]\[ \]'; then
    case "$STATE" in
      ac|testplan)
        HAS_UNCHECKED_INSCOPE=1
        ;;
      postmerge)
        HAS_UNCHECKED_EXEMPT=1
        ;;
    esac
  fi

  # --- tracking issue line (only counts inside the exemption section) ---
  if [[ "$STATE" == "postmerge" ]]; then
    if printf '%s' "$line" | grep -qE '^[[:space:]]*Tracking issue:[[:space:]]*#[0-9]+'; then
      TRACKING_ISSUE="$(printf '%s' "$line" | grep -oE '#[0-9]+' | head -1 | grep -oE '[0-9]+')"
    fi
  fi
done <<< "$BODY"

# --- Stage 1: unchecked boxes in scope ---
if [[ "$HAS_UNCHECKED_INSCOPE" -eq 1 ]]; then
  echo "AC gate: FAIL — PR #$PR_NUM has unchecked acceptance-criteria box(es) outside the Post-merge verification section." >&2
  echo "Fix: check off every item in the Acceptance Criteria / Test Plan sections before merging, or move deferred work under '## Post-merge verification' with a Tracking issue: #N line." >&2
  exit 1
fi

# --- Stage 2: unchecked boxes in exemption section ---
if [[ "$HAS_UNCHECKED_EXEMPT" -eq 1 ]]; then

  # Check 1: Tracking issue line must exist inside the section
  if [[ -z "$TRACKING_ISSUE" ]]; then
    echo "AC gate: FAIL — PR #$PR_NUM has unchecked box(es) under '## Post-merge verification' but no 'Tracking issue: #N' line inside the section." >&2
    echo "Fix: add a line 'Tracking issue: #N' (where N is an open issue) inside the section, or check off all items." >&2
    exit 5
  fi

  # Check 2: Tracking issue must NOT be one this PR closes (PR #588 pattern)
  CLOSED_BY_THIS_PR=0
  PR_ISSUE_RC=0
  CLOSED_REFS="$(bash "$PR_ISSUE_REF_SH" --all "$PR_NUM" 2>/dev/null)" || PR_ISSUE_RC=$?
  # pr-issue-ref.sh exits 1 when no closing refs found (normal); 2+ is a genuine error
  if [[ "$PR_ISSUE_RC" -gt 1 ]]; then
    echo "AC gate: FAIL — could not look up closing refs via pr-issue-ref.sh (exit $PR_ISSUE_RC)." >&2
    exit 4
  fi
  if [[ -n "$CLOSED_REFS" ]] && printf '%s\n' "$CLOSED_REFS" | grep -qxF -- "$TRACKING_ISSUE"; then
    CLOSED_BY_THIS_PR=1
  fi

  if [[ "$CLOSED_BY_THIS_PR" -eq 1 ]]; then
    echo "AC gate: FAIL — PR #$PR_NUM tracking issue #$TRACKING_ISSUE is an issue this PR closes." >&2
    echo "This is the PR #588 pattern: when this PR merges, issue #$TRACKING_ISSUE closes automatically" >&2
    echo "and the deferred work is sealed inside a closed issue." >&2
    echo "Fix: use a separate open tracking issue that this PR does not close." >&2
    exit 6
  fi

  # Check 3: Tracking issue must be OPEN
  ISSUE_STATE=""
  if ! ISSUE_STATE="$(gh issue view "$TRACKING_ISSUE" --json state --jq '.state' 2>"$GH_ISSUE_STDERR")"; then
    sed 's/^/gh: /' "$GH_ISSUE_STDERR" >&2
    echo "AC gate: FAIL — could not look up state of tracking issue #$TRACKING_ISSUE." >&2
    echo "Fix: verify the tracking issue exists and is accessible, then re-run the gate." >&2
    exit 4
  fi

  if [[ "$ISSUE_STATE" == "CLOSED" ]]; then
    echo "AC gate: FAIL — PR #$PR_NUM tracking issue #$TRACKING_ISSUE is CLOSED." >&2
    echo "Fix: reopen issue #$TRACKING_ISSUE or use a different open tracking issue." >&2
    exit 7
  fi
fi

echo "AC gate: PASS"
exit 0
