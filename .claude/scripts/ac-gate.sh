#!/usr/bin/env bash
# ac-gate.sh — CI gate: fail a PR that has unchecked acceptance-criteria boxes.
# catalog: merge-gate-sequencing — CI gate: fail a PR with unchecked AC boxes; enforce the Post-merge verification exemption
#
# Reads the PR body and applies a two-stage check:
#
#   Stage 1 — unchecked boxes in scope
#     Scans the `## Acceptance Criteria` and `## Test plan` / `## Test Plan`
#     sections (case-insensitive, matching the ac-checkboxes.sh convention).
#     Any unchecked `- [ ]` outside the exemption section is a hard failure.
#     Near-miss headings (case-insensitive match to "post-merge verification"
#     but wrong case) are NOT treated as exemption regions — their unchecked
#     boxes are in-scope failures, not invisible.
#
#   Stage 2 — exemption region (`## Post-merge verification`)
#     The heading must match EXACTLY (spelling and case). A differently-cased
#     or misspelled heading is not treated as an exemption region.
#     Each Post-merge verification section is validated independently.
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
printf '%s\t%s\t%s\n' "$(date -u +%FT%TZ)" "$(basename "$0")" "${*//$'\n'/ }" 2>/dev/null >> "$HOME/.claude/script-usage.log" || true

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
# State machine: other | ac | testplan | postmerge | malformed_postmerge
#
# In-scope sections (AC/Test Plan): case-insensitive heading match.
# Exemption section (Post-merge verification): EXACT heading match only.
# Near-miss headings (same text, wrong case): malformed_postmerge state;
#   unchecked boxes there count as in-scope failures, not exemptions.
#
# Variables collected during parsing:
#   HAS_UNCHECKED_INSCOPE  1 if any unchecked box in ac, testplan, or malformed_postmerge
#   HAS_UNCHECKED_EXEMPT   1 if any unchecked box in the current postmerge section
#   TRACKING_ISSUE         issue number from "Tracking issue: #N" inside postmerge
#   PENDING_SECTIONS       one line per exemption section that had unchecked boxes:
#                          its tracking issue number, or "-" if it had none. EVERY
#                          such section is validated in Stage 2 -- validating only
#                          the last section's variables let an earlier bad section
#                          be discarded when a later one began (fail-open).

STATE="other"
HAS_UNCHECKED_INSCOPE=0
HAS_UNCHECKED_EXEMPT=0
TRACKING_ISSUE=""
PENDING_SECTIONS=""

# Records a completed postmerge section that carried unchecked boxes, so Stage 2
# can validate it. Called before any state transition away from "postmerge", and
# once more at EOF, so every section is captured -- not just the last one.
#
# Recording rather than validating in place is deliberate: Stage 1 (unchecked
# boxes outside the exemption, exit 1) must keep taking precedence over the
# exemption failures, and it cannot be decided until the whole body is parsed.
_commit_postmerge() {
  if [[ "$STATE" == "postmerge" && "$HAS_UNCHECKED_EXEMPT" -eq 1 ]]; then
    PENDING_SECTIONS="${PENDING_SECTIONS}${TRACKING_ISSUE:--}
"
  fi
}

while IFS= read -r raw_line || [[ -n "$raw_line" ]]; do
  # Strip CRLF (defensive: body from gh may carry Windows line endings)
  line="${raw_line%$'\r'}"

  # --- level-2 heading detection ---
  # Markdown allows up to three leading spaces before the marker and arbitrary
  # whitespace after it. Accepting only '^## ' let an indented '## Test Plan'
  # go unrecognised, so its unchecked boxes bypassed the gate entirely — and it
  # diverged from ac-checkboxes.sh, which accepts the indented forms.
  if printf '%s' "$line" | grep -qE '^[[:space:]]{0,3}##[[:space:]]'; then
    # Strip leading indent, the '##' marker, surrounding whitespace. Case is
    # preserved: the exemption heading is matched case-sensitively below.
    heading="$(printf '%s' "$line" | sed -E 's/^[[:space:]]{0,3}##[[:space:]]+//; s/[[:space:]]*$//')"

    # Case-insensitive match for in-scope sections
    heading_lower="$(printf '%s' "$heading" | tr 'A-Z' 'a-z')"

    case "$heading_lower" in
      "acceptance criteria")
        _commit_postmerge
        STATE="ac"
        ;;
      "test plan")
        _commit_postmerge
        STATE="testplan"
        ;;
      "post-merge verification")
        # Validate any previously completed postmerge section before entering a new one.
        _commit_postmerge
        # EXACT case match for exemption; wrong-case heading is a near-miss → in-scope.
        if [[ "$heading" == "Post-merge verification" ]]; then
          STATE="postmerge"
          TRACKING_ISSUE=""       # reset: each section is independent
          HAS_UNCHECKED_EXEMPT=0  # reset: each section is independent
        else
          # Near-match (wrong case/spelling) does NOT grant exemption.
          # Unchecked boxes here count as in-scope failures (exit 1).
          STATE="malformed_postmerge"
        fi
        ;;
      *)
        _commit_postmerge
        STATE="other"
        ;;
    esac
    continue
  fi

  # --- unchecked box detection (`- [ ]` with optional leading whitespace) ---
  if printf '%s' "$line" | grep -qE '^[[:space:]]*-[[:space:]]\[ \]'; then
    case "$STATE" in
      ac|testplan|malformed_postmerge)
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

# Validate the final postmerge section (if any) after all lines are consumed.
_commit_postmerge

# --- Stage 1: unchecked boxes in scope ---
if [[ "$HAS_UNCHECKED_INSCOPE" -eq 1 ]]; then
  echo "AC gate: FAIL — PR #$PR_NUM has unchecked acceptance-criteria box(es) outside the Post-merge verification section." >&2
  echo "Fix: check off every item in the Acceptance Criteria / Test Plan sections before merging, or move deferred work under '## Post-merge verification' with a Tracking issue: #N line." >&2
  exit 1
fi

# --- Stage 2: unchecked boxes in exemption section ---
# Validate EVERY exemption section that carried unchecked boxes, not only the
# last one. A body may hold several "## Post-merge verification" sections; if an
# earlier one is self-referential or names a closed issue, a later clean section
# must not launder it.
if [[ -n "$PENDING_SECTIONS" ]]; then

  # Closing refs are the same for every section, so look them up at most once.
  CLOSED_REFS=""
  CLOSED_REFS_LOADED=0

  while IFS= read -r SECTION_TRACKING; do
    [[ -z "$SECTION_TRACKING" ]] && continue

    # Check 1: Tracking issue line must exist inside the section.
    # "-" is the recorded sentinel for a section that had none.
    if [[ "$SECTION_TRACKING" == "-" ]]; then
      echo "AC gate: FAIL — PR #$PR_NUM has unchecked box(es) under '## Post-merge verification' but no 'Tracking issue: #N' line inside the section." >&2
      echo "Fix: add a line 'Tracking issue: #N' (where N is an open issue) inside the section, or check off all items." >&2
      exit 5
    fi

    # Check 2: Tracking issue must NOT be one this PR closes (PR #588 pattern)
    if [[ "$CLOSED_REFS_LOADED" -eq 0 ]]; then
      PR_ISSUE_RC=0
      CLOSED_REFS="$(bash "$PR_ISSUE_REF_SH" --all "$PR_NUM")" || PR_ISSUE_RC=$?
      # pr-issue-ref.sh exits 1 when no closing refs found (normal); 2+ is a genuine error
      if [[ "$PR_ISSUE_RC" -gt 1 ]]; then
        echo "AC gate: FAIL — could not look up closing refs via pr-issue-ref.sh (exit $PR_ISSUE_RC)." >&2
        exit 4
      fi
      CLOSED_REFS_LOADED=1
    fi

    if [[ -n "$CLOSED_REFS" ]] && printf '%s\n' "$CLOSED_REFS" | grep -qxF -- "$SECTION_TRACKING"; then
      echo "AC gate: FAIL — PR #$PR_NUM tracking issue #$SECTION_TRACKING is an issue this PR closes." >&2
      echo "This is the PR #588 pattern: when this PR merges, issue #$SECTION_TRACKING closes automatically" >&2
      echo "and the deferred work is sealed inside a closed issue." >&2
      echo "Fix: use a separate open tracking issue that this PR does not close." >&2
      exit 6
    fi

    # Check 3: Tracking issue must be OPEN
    ISSUE_STATE=""
    if ! ISSUE_STATE="$(gh issue view "$SECTION_TRACKING" --json state --jq '.state' 2>"$GH_ISSUE_STDERR")"; then
      sed 's/^/gh: /' "$GH_ISSUE_STDERR" >&2
      echo "AC gate: FAIL — could not look up state of tracking issue #$SECTION_TRACKING." >&2
      echo "Fix: verify the tracking issue exists and is accessible, then re-run the gate." >&2
      exit 4
    fi

    if [[ "$ISSUE_STATE" == "CLOSED" ]]; then
      echo "AC gate: FAIL — PR #$PR_NUM tracking issue #$SECTION_TRACKING is CLOSED." >&2
      echo "Fix: reopen issue #$SECTION_TRACKING or use a different open tracking issue." >&2
      exit 7
    fi
  done <<< "$PENDING_SECTIONS"
fi


echo "AC gate: PASS"
exit 0
