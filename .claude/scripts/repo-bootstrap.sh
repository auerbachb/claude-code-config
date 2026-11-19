#!/usr/bin/env bash
# repo-bootstrap.sh — Check (and optionally install) required repo configuration.
# catalog: trust-worktree-repo — Check and optionally install required repo configuration (provisioned file set, branch protection)
#
# Implements the contract from .claude/rules/repo-bootstrap.md:
#   1. Provisioned files: ensures a set of required files exist in the repo.
#      Run with --apply to install any that are missing (add-only; never
#      overwrites). See .claude/reference/repo-bootstrap-workflows.md for the
#      file-set design, per-file modes, and the one-list guarantee.
#   2. Agent issue-claim block (issue #2285): installs one provider-neutral
#      marked section into AGENTS.md at the repo root, so Codex, Cursor,
#      Antigravity and other non-Claude agents follow the same claim rule. The
#      text lives in .claude/reference/agent-issue-claims-block.md (found next
#      to this script, else under ~/.claude). --apply creates AGENTS.md when
#      absent, appends the block to an existing file (every byte already there
#      is kept), and rewrites only its own marked block when that drifts from
#      the source. A second run changes nothing.
#   3. Branch protection on main: report status only — never modified by this
#      script (the rule requires user confirmation, so the script defers).
#
# Usage:
#   repo-bootstrap.sh [--check]   # default: report status, no mutation
#   repo-bootstrap.sh --apply     # install missing files; never overwrites
#                                 # branch protection
#   repo-bootstrap.sh -h|--help   # print this usage and exit
#
# Exit codes:
#   0 — all checks pass (--check clean, or --apply succeeded with no remaining
#       gaps that the script is allowed to fix)
#   1 — gaps detected. In --check: a required file is missing OR branch
#       protection not configured. In --apply: branch protection still requires
#       user confirmation (file gaps were applied successfully).
#   2 — usage error
#   3 — environment error (not in a git repo, no remote, cannot resolve
#       owner/repo)
#   4 — gh / network error, or jq parse failure on the gh response
#   5 — write failure during --apply (mkdir or file write failed)
#
# Safety:
#   - Never overwrites existing files (idempotent-add-only per file).
#   - Never modifies branch protection — that requires user confirmation per
#     .claude/rules/repo-bootstrap.md. The script reports status only.
#   - Read-only gh API calls are used for the branch-protection check.

set -euo pipefail
# Best-effort usage telemetry — must never change this script's exit contract
# (issue #1430); stderr muted BEFORE the append per issue #1406's ordering.
if [[ -n "${HOME:-}" ]]; then
  printf '%s\t%s\t%s\n' "$(date -u +%FT%TZ)" "$(basename "$0")" "${*//$'\n'/ }" 2>/dev/null >> "$HOME/.claude/script-usage.log" || true
fi

MODE=""
for arg in "$@"; do
  case "$arg" in
    --check)
      if [[ -n "$MODE" && "$MODE" != "check" ]]; then
        echo "repo-bootstrap.sh: choose only one of --check or --apply" >&2
        exit 2
      fi
      MODE="check"
      ;;
    --apply)
      if [[ -n "$MODE" && "$MODE" != "apply" ]]; then
        echo "repo-bootstrap.sh: choose only one of --check or --apply" >&2
        exit 2
      fi
      MODE="apply"
      ;;
    -h|--help)
      # Sentinel-based extraction: print the leading comment block (from the
      # script-name banner through the last consecutive `#` line) so adding or
      # removing header lines doesn't silently truncate or pollute --help.
      sed -n '/^# repo-bootstrap\.sh/,/^[^#]/{/^[^#]/d; s/^# \{0,1\}//; p;}' "$0"
      exit 0
      ;;
    *)
      echo "repo-bootstrap.sh: unknown argument: $arg" >&2
      echo "Run with --help for usage." >&2
      exit 2
      ;;
  esac
done
[[ -z "$MODE" ]] && MODE="check"

if ! command -v gh >/dev/null 2>&1; then
  echo "repo-bootstrap.sh: gh CLI not found on PATH" >&2
  exit 3
fi
if ! command -v jq >/dev/null 2>&1; then
  echo "repo-bootstrap.sh: jq not found on PATH" >&2
  exit 3
fi

# --------------------------------------------------------------------------
# File set — the ONE list read by every code path (check, apply, report).
# Format: "relative-path|file-mode" (mode as chmod octal, e.g. 644 or 755).
# DO NOT add a second enumerated list anywhere else. To provision a new file,
# add one entry here and one heredoc arm in get_file_content() below.
# --------------------------------------------------------------------------
BOOTSTRAP_FILES=(
  ".github/workflows/cr-plan-on-issue.yml|644"
  ".github/workflows/ac-gate.yml|644"
  ".claude/scripts/ac-gate.sh|644"
  ".claude/scripts/lib/ac-checkbox-markers.sh|644"
  ".claude/scripts/pr-issue-ref.sh|755"
  ".github/workflows/pr-claim-check.yml|644"
  ".claude/scripts/pr-claim-check.sh|644"
  ".claude/scripts/issue-claim.sh|755"
  ".claude/scripts/pr-claim-line.sh|755"
)

# Return the canonical content for a given relative path on stdout.
# Uses single-quoted heredocs so ${{ }} and ${...} are written literally
# (GitHub Actions expressions and shell variables in the provisioned scripts
# must not be expanded by this outer shell).
get_file_content() {
  local rel_path="$1"
  case "$rel_path" in
    ".github/workflows/cr-plan-on-issue.yml")
      cat <<'REPO_BOOTSTRAP_FILE_EOF'
name: Trigger CodeRabbit Plan on New Issues

on:
  issues:
    types: [opened]

permissions:
  issues: write

jobs:
  trigger-cr-plan:
    runs-on: ubuntu-latest
    # Skip bot-filed issues and the owner's `human-tasks` list issue (#2539):
    # neither is agent work, so neither gets a coding plan.
    if: "!endsWith(github.event.issue.user.login, '[bot]') && !contains(github.event.issue.labels.*.name, 'human-tasks')"
    steps:
      - name: Comment @coderabbitai plan
        uses: actions/github-script@3a2844b7e9c422d3c10d287c895573f7108da1b3 # v9.0.0
        with:
          script: |
            await github.rest.issues.createComment({
              owner: context.repo.owner,
              repo: context.repo.repo,
              issue_number: context.issue.number,
              body: '@coderabbitai plan'
            });
REPO_BOOTSTRAP_FILE_EOF
      ;;
    ".github/workflows/ac-gate.yml")
      cat <<'REPO_BOOTSTRAP_FILE_EOF'
on:
  pull_request:
    # The gate reads the PR body, so checking AC boxes must rerun it.
    types: [opened, synchronize, reopened, edited]

permissions:
  contents: read
  pull-requests: read
  issues: read

jobs:
  # The job id `ac-gate` is the branch-protection status-check name.
  # Do NOT rename this job and do NOT add a `name:` field — either change
  # silently drops the check from branch protection, blocking every PR.
  ac-gate:
    runs-on: ubuntu-latest
    steps:
      - name: Checkout
        uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1
        with:
          # Check out the base-branch commit so the gate implementation is trusted
          # code that the PR cannot modify. The PR body is read via the API below.
          ref: ${{ github.event.pull_request.base.sha }}
          persist-credentials: false

      - name: Run AC gate
        env:
          GH_TOKEN: ${{ github.token }}
        run: |
          # If ac-gate.sh is not yet on the base branch (bootstrap PR introducing it),
          # skip gracefully so the gate can merge and become available to future PRs.
          if [[ ! -f .claude/scripts/ac-gate.sh ]]; then
            echo "AC gate: PASS (bootstrap — script not yet on base branch)"
            exit 0
          fi
          bash .claude/scripts/ac-gate.sh ${{ github.event.pull_request.number }}
REPO_BOOTSTRAP_FILE_EOF
      ;;
    ".claude/scripts/lib/ac-checkbox-markers.sh")
      cat <<'REPO_BOOTSTRAP_FILE_EOF'
# Shared list-marker alternation for POSIX ERE and Python re consumers.
# Keep this group-free so each caller controls its own capture groups.
# CommonMark ordered markers contain one to nine digits, followed by . or ).
AC_LIST_MARKER_RE='[-*+]|[0-9]{1,9}[.)]'
AC_FENCE_RE='^ {0,3}(`{3,}|~{3,})(.*)$'
AC_FENCE_CHAR=""
AC_FENCE_LENGTH=0

# Return success for fence boundaries and contents, without inspecting them as
# criteria. Root fences follow CommonMark 4.5: same kind, long-enough closing
# run and whitespace-only closer; a backtick info string cannot contain `.
ac_skip_fenced_line() {
  local ac__line="$1" ac__mark ac__rest
  if [[ -n "$AC_FENCE_CHAR" ]]; then
    if [[ "$ac__line" =~ $AC_FENCE_RE ]]; then
      ac__mark="${BASH_REMATCH[1]}"; ac__rest="${BASH_REMATCH[2]}"
      ac__rest="${ac__rest// /}"; ac__rest="${ac__rest//$'\t'/}"
      if [[ "${ac__mark:0:1}" == "$AC_FENCE_CHAR" && "${#ac__mark}" -ge "$AC_FENCE_LENGTH" && -z "$ac__rest" ]]; then
        AC_FENCE_CHAR=""; AC_FENCE_LENGTH=0
      fi
    fi
    return 0
  fi
  if [[ "$ac__line" =~ $AC_FENCE_RE ]]; then
    ac__mark="${BASH_REMATCH[1]}"; ac__rest="${BASH_REMATCH[2]}"
    if [[ "${ac__mark:0:1}" == '`' && "$ac__rest" == *'`'* ]]; then return 1; fi
    AC_FENCE_CHAR="${ac__mark:0:1}"; AC_FENCE_LENGTH=${#ac__mark}
    return 0
  fi
  return 1
}
REPO_BOOTSTRAP_FILE_EOF
      ;;
    ".claude/scripts/ac-gate.sh")
      cat <<'REPO_BOOTSTRAP_FILE_EOF'
#!/usr/bin/env bash
# ac-gate.sh — CI gate: fail a PR that has unchecked acceptance-criteria boxes.
# catalog: merge-gate-sequencing — CI gate: require checked AC lists and enforce the Post-merge verification exemption
#
# Reads the PR body and applies a two-stage check:
#
#   Stage 1 — unchecked boxes in scope
#     Scans the `## Acceptance Criteria` and `## Test plan` / `## Test Plan`
#     sections (case-insensitive, matching the ac-checkboxes.sh convention).
#     Any unchecked supported checkbox outside the exemption is a hard failure.
#     Every AC/Test Plan section must contain a recognized checkbox item.
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
# Empty bodies and bodies without AC/Test Plan sections retain their pass.
# Supported markers are -, *, +, N. and N), with one-to-nine digits and a
# whitespace separator; checked markers may use x or X.
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
#   1    unchecked box outside exemption, or checkbox-free AC/Test Plan section
#   2    usage error (missing/invalid args, unknown flag)
#   3    PR not found
#   4    gh / GitHub API error, or required helper/library unavailable
#   5    exemption section has no Tracking issue: #N line
#   6    tracking issue is one this PR closes (self-referential — PR #588 case)
#   7    tracking issue is CLOSED
#
# DEPENDENCIES:
#   - gh (authenticated)
#   - pr-issue-ref.sh and lib/ac-checkbox-markers.sh (sibling payload)
#
# EXAMPLES:
#   ac-gate.sh 1234    # exits 0 (pass) or non-zero (fail, message on stderr)

set -euo pipefail
printf '%s\t%s\t%s\n' "$(date -u +%FT%TZ)" "$(basename "$0")" "${*//$'\n'/ }" 2>/dev/null >> "$HOME/.claude/script-usage.log" || true

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PR_ISSUE_REF_SH="$SCRIPT_DIR/pr-issue-ref.sh"
AC_LIST_MARKER_RE=""
AC_FENCE_RE=""
if [[ ! -r "$SCRIPT_DIR/lib/ac-checkbox-markers.sh" ]] ||
   ! source "$SCRIPT_DIR/lib/ac-checkbox-markers.sh" || [[ -z "$AC_LIST_MARKER_RE" || -z "$AC_FENCE_RE" ]] ||
   ! declare -F ac_skip_fenced_line >/dev/null; then
  echo "Error: shared checkbox marker library unavailable: $SCRIPT_DIR/lib/ac-checkbox-markers.sh" >&2
  exit 4
fi
CHECKBOX_RE="^[[:space:]]*(${AC_LIST_MARKER_RE})[[:space:]]+\[([ xX])\]"

print_usage() {
  cat <<'EOF'
Usage: ac-gate.sh <pr_number>
       ac-gate.sh --help | -h

Gate a PR on unchecked acceptance-criteria boxes. Scans the Acceptance
Criteria and Test Plan sections for unchecked list items, and rejects
sections with no recognized checkboxes. Markers: -, *, +, N. or N)
(one-to-nine digits; whitespace before [ ]; x/X means checked). Unchecked
items under `## Post-merge verification` (exact heading) may be deferred
when a valid open tracking issue is named inside the section.

Exit codes:
  0  gate passed
  1  unchecked box outside exemption, or checkbox-free AC/Test Plan section
  2  usage error
  3  PR not found
  4  gh / API error, or required helper/library unavailable
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
HAS_EMPTY_INSCOPE=0
SECTION_CHECKBOXES=0
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

_commit_inscope() {
  if [[ ( "$STATE" == "ac" || "$STATE" == "testplan" ) && "$SECTION_CHECKBOXES" -eq 0 ]]; then
    HAS_EMPTY_INSCOPE=1
  fi
}

while IFS= read -r raw_line || [[ -n "$raw_line" ]]; do
  # Strip CRLF (defensive: body from gh may carry Windows line endings)
  line="${raw_line%$'\r'}"
  if ac_skip_fenced_line "$line"; then continue; fi

  # --- level-2 heading detection ---
  # Markdown allows up to three leading spaces before the marker and arbitrary
  # whitespace after it. Accepting only '^## ' let an indented '## Test Plan'
  # go unrecognised, so its unchecked boxes bypassed the gate entirely — and it
  # diverged from ac-checkboxes.sh, which accepts the indented forms.
  if grep -qE '^[[:space:]]{0,3}##[[:space:]]' <<<"$line"; then
    _commit_inscope
    SECTION_CHECKBOXES=0
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

  # Count checked and unchecked items with the same shared marker predicate.
  if [[ "$line" =~ $CHECKBOX_RE ]]; then
    checked="${BASH_REMATCH[2]}"
    case "$STATE" in
      ac|testplan)
        SECTION_CHECKBOXES=$((SECTION_CHECKBOXES + 1))
        [[ "$checked" != " " ]] || HAS_UNCHECKED_INSCOPE=1
        ;;
      malformed_postmerge)
        [[ "$checked" != " " ]] || HAS_UNCHECKED_INSCOPE=1
        ;;
      postmerge)
        [[ "$checked" != " " ]] || HAS_UNCHECKED_EXEMPT=1
        ;;
    esac
  fi

  # --- tracking issue line (only counts inside the exemption section) ---
  if [[ "$STATE" == "postmerge" ]]; then
    if grep -qE '^[[:space:]]*Tracking issue:[[:space:]]*#[0-9]+' <<<"$line"; then
      TRACKING_ISSUE="$(printf '%s' "$line" | grep -oE '#[0-9]+' | head -1 | grep -oE '[0-9]+')"
    fi
  fi
done <<< "$BODY"

# Validate the final postmerge section (if any) after all lines are consumed.
_commit_postmerge
_commit_inscope

# --- Stage 1: unchecked boxes in scope ---
if [[ "$HAS_UNCHECKED_INSCOPE" -eq 1 ]]; then
  echo "AC gate: FAIL — PR #$PR_NUM has unchecked acceptance-criteria box(es) outside the Post-merge verification section." >&2
  echo "Fix: check off every item in the Acceptance Criteria / Test Plan sections before merging, or move deferred work under '## Post-merge verification' with a Tracking issue: #N line." >&2
  exit 1
fi

if [[ "$HAS_EMPTY_INSCOPE" -eq 1 ]]; then
  echo "AC gate: FAIL — PR #$PR_NUM has an Acceptance Criteria / Test Plan section with no recognized checkbox items." >&2
  echo "Fix: add verifiable checkbox items to each section, or remove an unintended empty section." >&2
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

    if [[ -n "$CLOSED_REFS" ]] && grep -qxF -- "$SECTION_TRACKING" <<<"$CLOSED_REFS"; then
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
REPO_BOOTSTRAP_FILE_EOF
      ;;
    ".claude/scripts/pr-issue-ref.sh")
      cat <<'REPO_BOOTSTRAP_FILE_EOF'
#!/usr/bin/env bash
# pr-issue-ref.sh — Extract the linked issue number(s) from a PR body.
# catalog: pr-state-polling — Extract every linked issue number from a PR body via GitHub's issue-closing keywords (one per line; `--first` for a single primary)
#
# Scans the PR body for any of GitHub's nine supported issue-closing keywords
# (`close`, `closes`, `closed`, `fix`, `fixes`, `fixed`, `resolve`, `resolves`,
# `resolved` — case-insensitive, optional whitespace between keyword and `#`)
# and prints the issue number(s) it closes, one per line.
#
# SELECTION (default and --first) — tiered, then set-valued (issue #1492):
#   Tier 1, "standalone": the line, trimmed of whitespace and of any Markdown
#     blockquote/list marker, is ONLY a closing keyword + `#N` (one optional
#     trailing `.`/`,`/`;`/`:`). This is the canonical trailer shape.
#   Tier 2, "embedded": any other closing reference — one sitting inside prose.
#   If any tier-1 reference exists, EVERY tier-1 number is printed and tier 2 is
#   ignored; otherwise EVERY tier-2 number is printed. Document order, deduped.
#
#   A single-pick selector was wrong in both directions observed live: on PR #1489
#   a prose `closed #1356` outranked the trailing `Closes #1407` (tier 1 fixes it),
#   and on PR #1546 a body with two `Closes` trailers released only the first claim
#   and stranded the second (set-valued output fixes it). GitHub closes every
#   closing reference a PR carries, so a set is the honest shape.
#
# With --all, prints every closing reference in BOTH tiers (numerically sorted,
# deduplicated) and additionally matches the cross-repo `owner/repo#N` form.
#
# USAGE:
#   pr-issue-ref.sh <pr_number>
#   pr-issue-ref.sh --first <pr_number>
#   pr-issue-ref.sh --all <pr_number>
#   pr-issue-ref.sh --help | -h
#
# OUTPUT:
#   Default: every bare-#N issue number in the winning tier, one per line, in
#            document order, deduplicated. A PR closing one issue — the common
#            case — emits exactly one line, as before.
#   --first: the first line of the default output and nothing else. For callers
#            that need a single primary issue (attribution, a URL, one API
#            lookup) rather than the full set. Mutually exclusive with --all.
#   --all:   every issue number, one per line, sorted and deduplicated, with no
#            tier filtering. Both the bare `#N` and `owner/repo#N` forms are
#            matched. Only the numeric portion is printed in every mode.
#
#   DELIBERATE SUBSET: default and --first match the bare `#N` form only. The
#   cross-repo `owner/repo#N` form stays --all-only, so the "cannot resolve the
#   current repository" refusal and its guards are reached from --all alone.
#
# EXIT CODES:
#   0    issue reference found (number(s) on stdout)
#   1    no issue reference found (stdout empty)
#   2    usage error (missing/invalid args, unknown flag, --first with --all)
#   3    PR not found
#   4    gh / GitHub API error
#
# DEPENDENCIES:
#   - gh (authenticated)
#   - awk
#
# EXAMPLES:
#   pr-issue-ref.sh 290           # → "271" (or "271\n345" for a two-issue PR)
#   pr-issue-ref.sh --first 290   # → "271" — exactly one line, for single-value callers
#   ISSUE=$(pr-issue-ref.sh --first "$PR" || true)
#   pr-issue-ref.sh "$PR" | while IFS= read -r I; do issue-claim.sh "$I" --release; done
#   pr-issue-ref.sh --all 290     # → one issue number per line (e.g. "271\n345")

set -euo pipefail
printf '%s\t%s\t%s\n' "$(date -u +%FT%TZ)" "$(basename "$0")" "${*//$'\n'/ }" 2>/dev/null >> "$HOME/.claude/script-usage.log" || true

print_usage() {
  cat <<'EOF'
Usage: pr-issue-ref.sh [--first | --all] <pr_number>
       pr-issue-ref.sh --help | -h

Extract linked issue number(s) from a PR body. Matches any of GitHub's nine
supported closing keywords — `close`, `closes`, `closed`, `fix`, `fixes`,
`fixed`, `resolve`, `resolves`, `resolved` (case-insensitive, optional
whitespace between keyword and `#`).

Default: prints EVERY issue this PR closes, one per line, in document order.
         References standing alone on their own line — the canonical
         `Closes #N` trailer, optionally behind a `-`/`>` Markdown marker and
         with one trailing `.`/`,`/`;`/`:` — win outright: when any exist, the
         references buried in prose are ignored. When none exist, every prose
         reference is emitted instead. A PR closing one issue emits one line.
--first: the first line of the default output, and nothing else. Use it when a
         caller needs a single primary issue — attribution, an issue URL, one
         `gh issue view` — instead of the full set. Not valid with --all.
--all:   prints every closing reference with NO tier filtering (one per line,
         sorted, deduplicated). Matches both the bare `#N` and the
         `owner/repo#N` cross-repo forms.

Only the numeric portion is emitted in every mode.

DELIBERATE SUBSET: default and --first match the bare `#N` form only. The
cross-repo `owner/repo#N` form is matched by --all alone, so only --all can
reach the "cannot resolve the current repository" refusal.

Exit codes:
  0  issue reference found (number(s) on stdout)
  1  no issue reference found (stdout empty)
  2  usage error (including --first together with --all)
  3  PR not found
  4  gh / GitHub API error
EOF
}

# --- arg parsing ---
PR_NUM=""
ALL_MODE=0
FIRST_MODE=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help)
      print_usage
      exit 0
      ;;
    --all)
      ALL_MODE=1
      shift
      ;;
    --first)
      FIRST_MODE=1
      shift
      ;;
    --)
      # Truly stop option parsing: drain remaining args as positional so
      # dash-prefixed args (e.g. `-- -h`) don't re-match the option arms.
      # Plain `continue` here would re-enter the `case`, defeating `--`.
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

if [[ "$ALL_MODE" -eq 1 && "$FIRST_MODE" -eq 1 ]]; then
  # --all is the unfiltered set and --first is a single tiered pick; there is no
  # coherent combination. Refuse rather than silently letting one win.
  echo "Error: --first and --all are mutually exclusive" >&2
  print_usage >&2
  exit 2
fi

if [[ -z "$PR_NUM" ]]; then
  echo "Error: <pr_number> is required" >&2
  print_usage >&2
  exit 2
fi

if ! [[ "$PR_NUM" =~ ^[1-9][0-9]*$ ]]; then
  echo "Error: <pr_number> must be a positive integer, got: $PR_NUM" >&2
  exit 2
fi

# --- dependency check ---
if ! command -v gh >/dev/null 2>&1; then
  echo "Error: 'gh' CLI not found on PATH" >&2
  exit 4
fi

# --- fetch PR body ---
# Distinguish "PR not found" (exit 3) from generic gh errors (exit 4) by
# inspecting stderr, matching the convention in cycle-count.sh and friends.
GH_STDERR="$(mktemp)"
trap 'rm -f "$GH_STDERR"' EXIT

if ! BODY="$(gh pr view "$PR_NUM" --json body --jq '.body // ""' 2>"$GH_STDERR")"; then
  if grep -qiE 'not.?found|could not resolve|no pull requests? found' "$GH_STDERR"; then
    echo "Error: PR #$PR_NUM not found" >&2
    exit 3
  fi
  sed 's/^/gh: /' "$GH_STDERR" >&2
  echo "Error: gh pr view failed for PR #$PR_NUM" >&2
  exit 4
fi

# --- extract issue number(s) ---
if [[ "$ALL_MODE" -eq 1 ]]; then
  # --all mode: collect every closing reference that targets the current repository.
  #
  # Pass 1: bare `#N` form. The leading `(^|[^[:alnum:]_])` is a left word-boundary.
  BARE="$(printf '%s\n' "$BODY" | grep -oiE '(^|[^[:alnum:]_])(close|closes|closed|fix|fixes|fixed|resolve|resolves|resolved)[[:space:]]*#[0-9]+' | grep -oE '#[0-9]+' | grep -oE '[0-9]+' || true)"

  # Pass 2: cross-repo `owner/repo#N` form. Requires at least one space between
  # the keyword and the owner slug (bare `closes#N` is valid but `closesowner/` is not).
  # The leading left-boundary prevents matching inside larger words.
  # Only include references targeting the CURRENT repository — a `Closes other/repo#99`
  # closes issue #99 in `other/repo`, not in this repo, and must not false-collide with
  # a local tracking issue #99. Compare with == (not a regex) to avoid dot-in-slug
  # injection (`api.v2` would match `apiXv2` in a regex).
  CURRENT_REPO_LOWER=""
  if [[ -n "${GITHUB_REPOSITORY:-}" ]]; then
    # In GitHub Actions CI, GITHUB_REPOSITORY is always set (e.g. "owner/repo").
    CURRENT_REPO_LOWER="$(printf '%s' "${GITHUB_REPOSITORY}" | tr 'A-Z' 'a-z')"
  else
    # Outside CI: try gh repo view; failure is non-fatal (fall back to no filtering).
    # Single call; if it fails or returns empty, CURRENT_REPO_LOWER stays "".
    _REPO_OUT=""
    if _REPO_OUT="$(gh repo view --json nameWithOwner --jq '.nameWithOwner' 2>/dev/null)" && [[ -n "$_REPO_OUT" ]]; then
      CURRENT_REPO_LOWER="$(printf '%s' "$_REPO_OUT" | tr 'A-Z' 'a-z')"
    fi
  fi

  if [[ -n "$CURRENT_REPO_LOWER" ]]; then
    # Filter cross-repo refs: only include those whose owner/repo matches this repo.
    # Use string equality (==) after lowercasing — never interpolate repo slug into a regex.
    CROSS="$(printf '%s\n' "$BODY" \
      | grep -oiE '(^|[^[:alnum:]_])(close|closes|closed|fix|fixes|fixed|resolve|resolves|resolved)[[:space:]]+[a-zA-Z0-9_.-]+/[a-zA-Z0-9_.-]+#[0-9]+' \
      | grep -oE '[a-zA-Z0-9_.-]+/[a-zA-Z0-9_.-]+#[0-9]+' \
      | while IFS= read -r _ref; do
          _repo_part="$(printf '%s' "${_ref%#*}" | tr 'A-Z' 'a-z')"
          _issue_part="${_ref##*#}"
          if [[ "$_repo_part" == "$CURRENT_REPO_LOWER" ]]; then
            printf '%s\n' "$_issue_part"
          fi
        done || true)"
  elif grep -qiE '(^|[^[:alnum:]_])(close|closes|closed|fix|fixes|fixed|resolve|resolves|resolved)[[:space:]]+[a-zA-Z0-9_.-]+/[a-zA-Z0-9_.-]+#[0-9]+' <<<"$BODY"; then
    # Current repo unknown AND the body carries qualified refs: refuse rather
    # than guess. Including them lets `Closes other/repo#99` false-collide with
    # a local tracking issue #99 (a wrong rejection); excluding them lets a
    # genuinely self-referential `Closes this/repo#N` slip past (a wrong pass).
    # Both are wrong answers, so emit neither — the caller must supply context.
    echo "Error: cannot resolve the current repository, and PR #$PR_NUM has qualified owner/repo#N closing references." >&2
    echo "Fix: set GITHUB_REPOSITORY=owner/repo, or run where 'gh repo view' can resolve the repository." >&2
    exit 4
  else
    # Current repo unknown, but no qualified refs exist — nothing to filter.
    CROSS=""
  fi

  # Combine, filter to pure-numeric lines, sort and deduplicate.
  ALL="$(printf '%s\n%s\n' "$BARE" "$CROSS" | grep -E '^[0-9]+$' | sort -u || true)"
  if [[ -z "$ALL" ]]; then
    exit 1
  fi
  printf '%s\n' "$ALL"
  exit 0
fi

# --- default / --first mode: every bare #N in the winning tier (issue #1492) ---
#
# One awk pass classifies each body line into one of two tiers, then emits the
# whole winning tier rather than a single positional pick:
#
#   tier 1 "standalone" — the line, once trimmed and stripped of a leading
#     Markdown blockquote/list marker, is nothing but a closing keyword and
#     `#N`. That is the canonical trailer shape a PR author writes deliberately.
#   tier 2 "embedded"  — every other closing reference, i.e. one sitting inside
#     a sentence.
#
# Tier 1 wins outright when non-empty. That is what stops PR #1489's prose
# `closed #1356` from outranking its trailing `Closes #1407`. Emitting the whole
# tier rather than its first element is what stops PR #1546's second trailer
# (`Closes #1541`, after `Closes #1531`) from being dropped — GitHub closes both,
# so a caller releasing claims must see both. Falling back to tier 2 keeps bodies
# whose only reference is prose working exactly as before.
#
# The `(^|[^[:alnum:]_])` left word-boundary is carried over verbatim: without it
# `prefixes #34` would match `fixes #34` and `enclosed #56` would match
# `closed #56`. The anchored tier-1 pattern gives the same protection via `^`.
SELECTED="$(printf '%s\n' "$BODY" | awk '
  BEGIN { kw = "close|closes|closed|fix|fixes|fixed|resolve|resolves|resolved" }
  {
    line = $0
    sub(/\r$/, "", line)   # a body edited in the GitHub web UI is stored CRLF;
                           # an unstripped CR fails the tier-1 `$` anchor and
                           # would silently demote a real trailer to prose.
    t = line
    sub(/^[[:space:]]+/, "", t)
    sub(/[[:space:]]+$/, "", t)
    while (t ~ /^>/) { sub(/^>[[:space:]]*/, "", t) }
    sub(/^[-*+][[:space:]]+/, "", t)

    lt = tolower(t)
    if (lt ~ ("^(" kw ")[[:space:]]*#[0-9]+[.,;:]?$")) {
      n = lt
      sub(/^.*#/, "", n)
      sub(/[^0-9].*$/, "", n)
      standalone[++ns] = n
      next
    }

    s = tolower(line)
    while (match(s, "(^|[^[:alnum:]_])(" kw ")[[:space:]]*#[0-9]+")) {
      m = substr(s, RSTART, RLENGTH)
      sub(/^.*#/, "", m)
      embedded[++ne] = m
      # Resume ONE character early, keeping the final digit of the match as
      # leading context. Resuming at RSTART+RLENGTH would put the scan at
      # string position 1, where the ^ alternative in the pattern matches
      # again and manufactures a word boundary the line does not contain:
      # "fixes #1closed #56" would then yield 56, which the grep guard in the
      # pre-fix selector rejects because the character before "closed" is a
      # digit. Keeping that digit reproduces the same boundary semantics.
      s = substr(s, RSTART + RLENGTH - 1)
    }
  }
  END {
    if (ns > 0) { cnt = ns; for (i = 1; i <= ns; i++) out[i] = standalone[i] }
    else        { cnt = ne; for (i = 1; i <= ne; i++) out[i] = embedded[i] }
    for (i = 1; i <= cnt; i++) {
      if (!(out[i] in seen)) { seen[out[i]] = 1; print out[i] }
    }
  }
')"

if [[ -z "$SELECTED" ]]; then
  exit 1
fi

if [[ "$FIRST_MODE" -eq 1 ]]; then
  # Single primary issue: the first line of the tiered set. An explicit flag at
  # the call site, rather than a hidden `head -1` inside the helper — that hidden
  # pick is what stranded the claims this fix exists to stop stranding.
  printf '%s\n' "${SELECTED%%$'\n'*}"
else
  printf '%s\n' "$SELECTED"
fi
REPO_BOOTSTRAP_FILE_EOF
      ;;
    ".github/workflows/pr-claim-check.yml")
      cat <<'REPO_BOOTSTRAP_FILE_EOF'
on:
  pull_request:
    # The checker re-reads the PR body through the API on every run (never from
    # the event payload), so each of these events can change the verdict.
    types: [opened, reopened, edited, synchronize]

# One run at a time per PR (issue #2412): the checker lists the PR's comments
# and then posts its advisory comment, so two overlapping runs could both miss
# the other's comment and post twice. Serialized runs cannot overlap; GitHub
# replaces an older pending run with the newest. Not cancel-in-progress, which
# could stop a run mid-POST. A local --report call or another writer can still
# race a run, so the comment dedupe stays best effort.
concurrency:
  group: ${{ github.workflow }}-pr-${{ github.event.pull_request.number || github.run_id }}
  cancel-in-progress: false

permissions:
  contents: read
  issues: read
  pull-requests: write

jobs:
  # Informational until promoted: this check is NOT a required status check.
  # Do not add it to branch protection until it has a track record.
  pr-claim-check:
    runs-on: ubuntu-latest
    steps:
      - name: Checkout
        uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1
        with:
          # Check out the base-branch commit so the claim gate is trusted code
          # that the PR cannot modify. The PR body is read via the API below.
          ref: ${{ github.event.pull_request.base.sha }}
          persist-credentials: false

      - name: Check PR claim
        env:
          GH_TOKEN: ${{ github.token }}
          REPO: ${{ github.repository }}
          PR_NUMBER: ${{ github.event.pull_request.number }}
        run: |
          # If the gate or the issue-claim helper it reads is not on the base
          # branch yet (the bootstrap PR that installs them reads the base SHA),
          # print a notice and pass. The check is advisory either way.
          if [[ ! -f .claude/scripts/pr-claim-check.sh ]]; then
            echo "::notice::pr-claim-check: PASS (bootstrap - script not yet on base branch)"
            exit 0
          fi
          if [[ ! -f .claude/scripts/issue-claim.sh ]]; then
            echo "::notice::pr-claim-check: PASS (issue-claim.sh not on base branch; ownership not checked here)"
            exit 0
          fi
          bash .claude/scripts/pr-claim-check.sh "$PR_NUMBER" --repo "$REPO" --report
REPO_BOOTSTRAP_FILE_EOF
      ;;
    ".claude/scripts/pr-claim-check.sh")
      cat <<'REPO_BOOTSTRAP_FILE_EOF'
#!/usr/bin/env bash
# pr-claim-check.sh — Compare a PR's claim-holder line with each linked issue's winning claim (issue #2288).
# catalog: merge-gate-sequencing — PR-side claim gate: flags a PR opened on an issue another agent holds, or a PR that names no claim (CI runs it via pr-claim-check.yml)
#
# PURPOSE
#   Every pull request passes through GitHub, whichever agent wrote it. This
#   script answers one question for a PR: does the holder it names match the
#   holder of each issue it closes? It prints ONE JSON object and exits 0 for
#   every verdict. Only a usage error exits 2.
#
# VERDICTS (worst per-issue outcome wins, in this order)
#   foreign > unverifiable > no_claim_line > match > pass_unclaimed > skipped
#
#   Per-issue outcome (from the real issue-claim.sh --check --json):
#     unclaimed | stale         -> pass_unclaimed
#     claimed, holder digest == the PR's claim-holder line -> match
#     claimed, PR has no claim-holder line                 -> no_claim_line
#     claimed, digests differ                              -> foreign
#     unknown, not_found, closed issue, unreadable claim or PR line -> unverifiable
#     two different claim-holder lines in the PR body -> unverifiable (fails closed)
#   A claim-holder line counts only when it stands alone on its line, outside
#   fenced code blocks; a mention inside a sentence is ignored. Fences follow
#   GFM: an opener or closer is indented at most three spaces (a tab or four
#   spaces is not a fence), and a backtick opener whose info string holds a
#   backtick is not a fence.
#   Overall skipped: a PR that is not open (pr_not_open: merged or closed, so
#   finished work never draws a comment), a bot author (bot_author), no closing
#   keyword (no_linked_issue), or closing keywords that all name another
#   repository (cross_repo_issue).
#   PR state policy: closed -> skipped/pr_not_open; open -> continue; a missing
#   or unexpected state -> unverifiable/pr_read_failed (never a silent skip).
#
# CROSS-REPOSITORY KEYWORDS
#   A keyword such as `Closes owner/name#12` that names another repository is
#   NOT verified: the workflow token may not read that repository. It is listed
#   in `skipped_references` ({repo, issue, reason: cross_repo_issue}). It never
#   hides a local outcome: with local issues present the local verdict stands.
#
# NEVER PRINTS THE RAW HOLDER
#   A foreign result names the holder's provider, device and label only. The
#   raw holder token can carry a hostname and a path, so it never leaves this
#   script, not even on stderr.
#
# --report MODE (used by pr-claim-check.yml)
#   Also maps the verdict to CI: match, pass_unclaimed and skipped pass
#   silently; no_claim_line and unverifiable pass with a ::warning::; foreign
#   fails (exit 1) with a ::error::. no_claim_line, unverifiable and foreign
#   post one PR comment, and only when a comment with the same hidden marker
#   (<!-- pr-claim-check:<verdict>:<issues> -->) is not already on the PR.
#
# USAGE
#   pr-claim-check.sh <PR> [--repo OWNER/NAME] [--report]
#   pr-claim-check.sh --help | -h
#
# DEPENDENCIES
#   gh (authenticated), jq, issue-claim.sh (same directory), and shasum or
#   sha256sum. Reads only; --report also writes one PR comment per new outcome.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ISSUE_CLAIM="$SCRIPT_DIR/issue-claim.sh"

usage() {
  cat <<'USAGE'
Usage: pr-claim-check.sh <PR> [--repo OWNER/NAME] [--report]
       pr-claim-check.sh --help | -h

Prints one JSON object describing the PR's claim verdict. Exit 0 for every
verdict; exit 2 for a usage error.

--repo OWNER/NAME  Act on this repository (default: the current checkout).
--report           CI mode: map the verdict to annotations, a step summary,
                   one deduplicated PR comment, and an exit status (foreign
                   exits 1, every other verdict exits 0).
USAGE
}

usage_err() {
  echo "pr-claim-check.sh: $1" >&2
  usage >&2
  exit 2
}

PR=""
REPO=""
REPORT=0
# Linked issues; set before any exit path so report_outcome never reads an
# unset (set -u abort) or an inherited environment value.
LINKED=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --repo)
      [[ $# -ge 2 ]] || usage_err "--repo needs a value"
      REPO="$2"; shift 2 ;;
    --repo=*) REPO="${1#--repo=}"; shift ;;
    --report) REPORT=1; shift ;;
    -*) usage_err "unknown flag: $1" ;;
    *)
      [[ -z "$PR" ]] || usage_err "unexpected extra argument: $1"
      PR="$1"; shift ;;
  esac
done

[[ -n "$PR" ]] || usage_err "missing PR number"
[[ "$PR" =~ ^[1-9][0-9]*$ ]] || usage_err "PR number must be a positive integer"
if [[ -n "$REPO" ]]; then
  [[ "$REPO" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || usage_err "--repo must be OWNER/NAME"
fi

TMPD="$(mktemp -d 2>/dev/null)" || {
  # Never a silent clean pass: in CI mode say ownership is unverified.
  if [[ "$REPORT" -eq 1 ]]; then
    echo "::warning::pr-claim-check: could not verify ownership (temporary directory unavailable); this check passes with a warning, not as a match"
  fi
  echo '{"verdict":"unverifiable","reason":"tempdir_unavailable","claim_line":false,"issues":[]}'
  exit 0
}
trap 'rm -rf "$TMPD"' EXIT

# digest_hex <text> <n>: first n hex chars of a SHA-256. Fails closed.
digest_hex() {
  local d=""
  if command -v shasum >/dev/null 2>&1; then
    d="$(printf '%s' "$1" | shasum -a 256 2>/dev/null | cut -c1-64)"
  elif command -v sha256sum >/dev/null 2>&1; then
    d="$(printf '%s' "$1" | sha256sum 2>/dev/null | cut -c1-64)"
  fi
  [[ -n "$d" ]] || return 1
  printf '%s' "${d:0:$2}"
}

# canonical_holder <raw>: the claim-holder value for a raw holder (see pr-claim-line.sh).
canonical_holder() {
  if [[ "$1" =~ ^h-[0-9a-f]{12}$ ]]; then
    printf '%s' "$1"
    return 0
  fi
  local d
  d="$(digest_hex "$1" 12)" || return 1
  printf 'h-%s' "$d"
}

# rank <verdict>: higher is worse. Used to pick the overall verdict.
rank() {
  case "$1" in
    foreign) echo 5 ;;
    unverifiable) echo 4 ;;
    no_claim_line) echo 3 ;;
    match) echo 2 ;;
    pass_unclaimed) echo 1 ;;
    *) echo 0 ;;
  esac
}

# finish <verdict> <reason> <claim_line true|false> <issues-json-array> : print the result object.
RESULT_REPO="${REPO:-unknown}"
finish() {
  OVERALL="$1"; OVERALL_REASON="$2"
  jq -cn \
    --argjson skipped "$(skipped_refs_json)" \
    --argjson pr "$PR" \
    --arg repo "$RESULT_REPO" \
    --arg verdict "$1" \
    --arg reason "$2" \
    --argjson claim_line "$3" \
    --argjson issues "$4" \
    '{pr: $pr, repo: $repo, verdict: $verdict, reason: $reason, claim_line: $claim_line, issues: $issues, skipped_references: $skipped}'
  # Every exit path (including unverifiable early exits) goes through the CI
  # mapping, so a failed read warns in --report mode instead of passing silently.
  if [[ "$REPORT" -eq 1 ]]; then
    report_outcome
  fi
  exit 0
}

# Cross-repository closing keywords collect here as "repo#N" (lowercase repo).
SKIPPED_REFS=()
LINKED=""
skipped_refs_json() {
  if [[ "${#SKIPPED_REFS[@]}" -eq 0 ]]; then
    printf '[]'
    return 0
  fi
  printf '%s\n' "${SKIPPED_REFS[@]}" | jq -R -s -c \
    'split("\n") | map(select(length > 0) | capture("^(?<repo>.+)#(?<issue>[0-9]+)$")
       | {repo: .repo, issue: (.issue | tonumber), reason: "cross_repo_issue"})' 2>/dev/null || printf '[]'
}

# Issue objects accumulate here as JSON texts, joined into an array at the end.
ISSUE_OBJS=()
issues_json() {
  if [[ "${#ISSUE_OBJS[@]}" -eq 0 ]]; then
    printf '[]'
  else
    local IFS=','
    printf '[%s]' "${ISSUE_OBJS[*]}"
  fi
}

# add_issue <issue> <outcome> <reason> [provider device label]
add_issue() {
  local obj
  obj="$(jq -cn --argjson n "$1" --arg o "$2" --arg r "$3" \
    --arg p "${4:-}" --arg d "${5:-}" --arg l "${6:-}" \
    '{issue: $n, outcome: $o, reason: $r}
     + (if $o == "foreign" then {provider: (if $p == "" then null else $p end),
                                  device: (if $d == "" then null else $d end),
                                  label: (if $l == "" then null else $l end)} else {} end)')"
  ISSUE_OBJS+=("$obj")
}

main() {
# ---- 1. Resolve the repository ------------------------------------------------
if [[ -z "$REPO" ]]; then
  REPO="$(gh repo view --json nameWithOwner 2>/dev/null | jq -r '.nameWithOwner // ""' 2>/dev/null)" || REPO=""
  RESULT_REPO="${REPO:-unknown}"
  if [[ -z "$REPO" ]]; then
    finish unverifiable repo_unresolved false '[]'
    exit 0
  fi
fi
RESULT_REPO="$REPO"

# ---- 2. Read the PR -----------------------------------------------------------
if ! gh api "repos/$REPO/pulls/$PR" >"$TMPD/pr.json" 2>"$TMPD/err"; then
  finish unverifiable pr_read_failed false '[]'
  exit 0
fi
# A merged or closed PR is finished work: stop before anything else so an edit
# to its description can never post a comment. The API reports both merged and
# unmerged PRs as "closed". Anything but open/closed is an unreadable state.
PR_STATE="$(jq -r '.state // ""' "$TMPD/pr.json" 2>/dev/null)" || PR_STATE=""
case "$PR_STATE" in
  closed) finish skipped pr_not_open false '[]'; exit 0 ;;
  open) ;;
  *) finish unverifiable pr_read_failed false '[]'; exit 0 ;;
esac
AUTHOR="$(jq -r '.user.login // ""' "$TMPD/pr.json" 2>/dev/null)" || AUTHOR=""
AUTHOR_TYPE="$(jq -r '.user.type // ""' "$TMPD/pr.json" 2>/dev/null)" || AUTHOR_TYPE=""
if [[ -z "$AUTHOR" ]] || ! jq -e '.body == null or (.body | type == "string")' "$TMPD/pr.json" >/dev/null 2>&1; then
  finish unverifiable pr_read_failed false '[]'
  exit 0
fi
case "$AUTHOR" in
  *'[bot]') AUTHOR_TYPE="Bot" ;;
esac
if [[ "$AUTHOR_TYPE" == "Bot" ]]; then
  finish skipped bot_author false '[]'
  exit 0
fi

jq -r '.body // ""' "$TMPD/pr.json" >"$TMPD/body.md"

# strip_body <keep_comments 0|1> <infile> <outfile>: drop fenced code blocks
# (and, when keep_comments is 0, HTML comments) so neither can carry a keyword
# or a claim line the author did not mean.
strip_body() {
  awk -v keep="$1" '
    # GFM fences (the rules review-tier.sh strip_hidden uses): a fence opens
    # with 3+ backticks or tildes indented at most three spaces (a tab or four
    # spaces is indented code, not a fence); a backtick opener whose info
    # string holds a backtick is inline code, not a fence. It closes only on
    # the same character, at least as long, indented at most three spaces,
    # with nothing but spaces or tabs after it. An unclosed fence hides the rest.
    BEGIN { fence = 0; fch = ""; flen = 0; com = 0 }
    # A CRLF body ends lines in "\r\n"; drop the CR so a closing fence still closes.
    { sub(/\r$/, "") }
    {
      if (fence) {
        if ($0 ~ /^ ? ? ?[`~]/) {
          t = $0; sub(/^ */, "", t)
          n = 0
          while (substr(t, n + 1, 1) == fch) n++
          if (n >= flen && substr(t, n + 1) ~ /^[ \t]*$/) fence = 0
        }
        next
      }
      if (match($0, /^ ? ? ?(```+|~~~+)/)) {
        t = substr($0, RSTART, RLENGTH); sub(/^ */, "", t)
        info = substr($0, RSTART + RLENGTH)
        if (!(substr(t, 1, 1) == "`" && index(info, "`") > 0)) {
          fence = 1; fch = substr(t, 1, 1); flen = length(t); next
        }
      }
    }
    fence { next }
    {
      line = $0
      if (keep == "1") { print line; next }
      out = ""
      while (length(line) > 0) {
        if (com) {
          p = index(line, "-->")
          if (p == 0) { line = "" } else { line = substr(line, p + 3); com = 0 }
        } else {
          p = index(line, "<!--")
          if (p == 0) { out = out line; line = "" }
          else { out = out substr(line, 1, p - 1); line = substr(line, p + 4); com = 1 }
        }
      }
      print out
    }' "$2" >"$3"
}

# ---- 3. Read the PR's claim-holder line ---------------------------------------
strip_body 1 "$TMPD/body.md" "$TMPD/body_fenced_only.md"
# Only a marker standing on its own line counts. A mention inside a sentence
# (for example a backticked example in the Decisions text) is prose, not a claim.
CLAIM_LINES="$(LC_ALL=C grep -E '^[[:space:]]*<!-- claim-holder:.*-->[[:space:]]*$' "$TMPD/body_fenced_only.md" 2>/dev/null || true)"
CLAIM_LINE_PRESENT=false
PR_HOLDER=""
MALFORMED=0
AMBIGUOUS=0
if [[ -n "$CLAIM_LINES" ]]; then
  CLAIM_LINE_PRESENT=true
  FIRST_LINE="$(printf '%s\n' "$CLAIM_LINES" | head -n 1)"
  if LC_ALL=C grep -qE '^[[:space:]]*<!-- claim-holder: h-[0-9a-f]{12} -->[[:space:]]*$' <<<"$FIRST_LINE"; then
    PR_HOLDER="$(printf '%s' "$FIRST_LINE" | LC_ALL=C grep -oE 'h-[0-9a-f]{12}')"
  else
    MALFORMED=1
  fi
  # Two different markers cannot say which holder this PR is for, so the check
  # fails closed (unverifiable) instead of guessing the first one.
  if [[ "$(printf '%s\n' "$CLAIM_LINES" | LC_ALL=C sort -u | wc -l | tr -d ' ')" -gt 1 ]]; then
    AMBIGUOUS=1
  fi
fi

# ---- 4. Linked issues from closing keywords -----------------------------------
strip_body 0 "$TMPD/body.md" "$TMPD/body_text.md"
KEYWORD_RE='(^|[^[:alnum:]_])(close[sd]?|fix(e[sd])?|resolve[sd]?)[[:space:]]*:?[[:space:]]*([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+)?#[0-9]+'
REFS="$(LC_ALL=C grep -oiE "$KEYWORD_RE" "$TMPD/body_text.md" 2>/dev/null)" || REFS=""
REPO_LC="$(printf '%s' "$REPO" | tr '[:upper:]' '[:lower:]')"
NUMS=""
while IFS= read -r REF; do
  [[ -n "$REF" ]] || continue
  # The reference is the last space- or colon-separated token: #N or owner/name#N.
  # The match ends in [owner/name]#N; whatever keyword or separator precedes it is ignored.
  [[ "$REF" =~ ([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+)?#([0-9]+)$ ]] || continue
  QUAL="${BASH_REMATCH[1]}"
  QUAL_LC="$(printf '%s' "$QUAL" | tr '[:upper:]' '[:lower:]')"
  # A reference qualified to another repository names an issue this check cannot
  # read: record it as skipped (cross_repo_issue) instead of dropping it silently.
  if [[ -n "$QUAL" && "$QUAL_LC" != "$REPO_LC" ]]; then
    XREF="$QUAL_LC#${BASH_REMATCH[2]}"
    case " ${SKIPPED_REFS[*]:-} " in
      *" $XREF "*) ;;
      *) SKIPPED_REFS+=("$XREF") ;;
    esac
    continue
  fi
  NUMS="$NUMS${BASH_REMATCH[2]}
"
done <<<"$REFS"
LINKED="$(printf '%s' "$NUMS" | LC_ALL=C grep -E '^[0-9]+$' | LC_ALL=C sort -n -u)" || LINKED=""

if [[ -z "$LINKED" && "${#SKIPPED_REFS[@]}" -gt 0 ]]; then
  finish skipped cross_repo_issue "$CLAIM_LINE_PRESENT" '[]'
  exit 0
fi
if [[ -z "$LINKED" ]]; then
  finish skipped no_linked_issue "$CLAIM_LINE_PRESENT" '[]'
  exit 0
fi

# ---- 5. Compare each linked issue ---------------------------------------------
for N in $LINKED; do
  # The issue must exist and be open; anything else cannot be verified.
  if ! gh api "repos/$REPO/issues/$N" >"$TMPD/issue.json" 2>/dev/null; then
    add_issue "$N" unverifiable issue_read_failed
    continue
  fi
  ISSUE_STATE="$(jq -r '.state // ""' "$TMPD/issue.json" 2>/dev/null)" || ISSUE_STATE=""
  if [[ "$ISSUE_STATE" != "open" ]]; then
    add_issue "$N" unverifiable issue_not_open
    continue
  fi
  if [[ "$MALFORMED" -eq 1 ]]; then
    add_issue "$N" unverifiable pr_claim_line_malformed
    continue
  fi
  if [[ "$AMBIGUOUS" -eq 1 ]]; then
    add_issue "$N" unverifiable pr_claim_line_ambiguous
    continue
  fi
  if [[ ! -f "$ISSUE_CLAIM" ]]; then
    add_issue "$N" unverifiable claim_helper_missing
    continue
  fi

  # The throwaway holder is unguessable per run, so it can never equal a real
  # claim holder. Even so, `mine` and `claimed` both carry the winning holder
  # and are compared by digest below; only unclaimed/stale skip the comparison.
  # --no-viewer: the Actions installation token cannot call GET /user, and the
  # comparison below needs only the winning holder (issue #2412). An older
  # installed helper rejects the flag and prints no JSON, which lands in the
  # unverifiable/claim_state_unreadable arm: a warning and exit 0, never a match.
  CLAIM_OUT="$(bash "$ISSUE_CLAIM" "$N" --check --json --no-viewer --repo "$REPO" --holder "pr-claim-check-$$-$RANDOM" 2>/dev/null)" || true
  VERDICT="$(printf '%s' "$CLAIM_OUT" | jq -r '.verdict // ""' 2>/dev/null)" || VERDICT=""
  case "$VERDICT" in
    unclaimed|stale)
      add_issue "$N" pass_unclaimed "$VERDICT" ;;
    claimed|mine)
      RAW_HOLDER="$(printf '%s' "$CLAIM_OUT" | jq -r '.claimant_holder // ""' 2>/dev/null)" || RAW_HOLDER=""
      if [[ -z "$RAW_HOLDER" ]]; then
        add_issue "$N" unverifiable claim_holder_unreadable
        continue
      fi
      WANT="$(canonical_holder "$RAW_HOLDER")" || { add_issue "$N" unverifiable digest_unavailable; continue; }
      if [[ "$CLAIM_LINE_PRESENT" != "true" ]]; then
        add_issue "$N" no_claim_line claimed_pr_has_no_claim_line
      elif [[ "$WANT" == "$PR_HOLDER" ]]; then
        add_issue "$N" match holder_matches
      else
        P="$(printf '%s' "$CLAIM_OUT" | jq -r '.provider // ""' 2>/dev/null)" || P=""
        D="$(printf '%s' "$CLAIM_OUT" | jq -r '.device // ""' 2>/dev/null)" || D=""
        L="$(printf '%s' "$CLAIM_OUT" | jq -r '.label // ""' 2>/dev/null)" || L=""
        add_issue "$N" foreign other_holder "$P" "$D" "$L"
      fi ;;
    *)
      add_issue "$N" unverifiable "claim_state_${VERDICT:-unreadable}" ;;
  esac
done

# ---- 6. Overall verdict -------------------------------------------------------
OVERALL="skipped"
OVERALL_REASON="no_decision"
for OBJ in ${ISSUE_OBJS[@]+"${ISSUE_OBJS[@]}"}; do
  O="$(printf '%s' "$OBJ" | jq -r '.outcome')"
  if [[ "$(rank "$O")" -gt "$(rank "$OVERALL")" ]]; then
    OVERALL="$O"
    OVERALL_REASON="$(printf '%s' "$OBJ" | jq -r '.reason')"
  fi
done
[[ "${#ISSUE_OBJS[@]}" -gt 0 ]] || { OVERALL="skipped"; OVERALL_REASON="no_linked_issue"; }

finish "$OVERALL" "$OVERALL_REASON" "$CLAIM_LINE_PRESENT" "$(issues_json)"

}

# ---- 7. --report: CI mapping, deduplicated comment ----------------------------
# Called only from finish(), so it always sees the final OVERALL and issue list.
report_outcome() {
  # Cross-repository keywords are never verified: say so, whatever the verdict.
  SKIP_TEXT="$(skipped_refs_json | jq -r 'map("\(.repo)#\(.issue) (\(.reason))") | join(", ")' 2>/dev/null)" || SKIP_TEXT=""
  if [[ -n "$SKIP_TEXT" ]]; then
    echo "::notice::pr-claim-check: not verified, closing keyword names another repository: $SKIP_TEXT"
    if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
      printf 'pr-claim-check: not verified, closing keyword names another repository: %s\n' "$SKIP_TEXT" >>"$GITHUB_STEP_SUMMARY"
    fi
  fi
  if [[ "$OVERALL" == "skipped" || "$OVERALL" == "match" || "$OVERALL" == "pass_unclaimed" ]]; then
    LINE="pr-claim-check: $OVERALL ($OVERALL_REASON) on PR #$PR"
    echo "$LINE"
    if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then printf '%s\n' "$LINE" >>"$GITHUB_STEP_SUMMARY"; fi
    exit 0
  fi

  # The marker lists the issues that drove the verdict, so a changed set posts anew.
  ISSUE_LIST="$(printf '%s\n' "$LINKED" | LC_ALL=C sort -n -u | paste -sd, -)"
  MARKER="<!-- pr-claim-check:$OVERALL:$ISSUE_LIST -->"

  case "$OVERALL" in
    foreign)
      SEV="error"
      BODY_TEXT="**Claim check failed.** This PR closes an issue that another agent holds."
      for OBJ in ${ISSUE_OBJS[@]+"${ISSUE_OBJS[@]}"}; do
        O="$(printf '%s' "$OBJ" | jq -r '.outcome')"
        [[ "$O" == "foreign" ]] || continue
        N="$(printf '%s' "$OBJ" | jq -r '.issue')"
        P="$(printf '%s' "$OBJ" | jq -r '.provider // "unknown"')"
        D="$(printf '%s' "$OBJ" | jq -r '.device // "unknown"')"
        L="$(printf '%s' "$OBJ" | jq -r '.label // "none"')"
        BODY_TEXT="$BODY_TEXT
- Issue #$N is claimed by provider \`$P\` on device \`$D\` (label: \`$L\`)."
      done
      BODY_TEXT="$BODY_TEXT

Stop this work, or if that claim is stale, take it over first with \`issue-claim.sh <N> --claim\`, then update this PR body's \`claim-holder\` line to match." ;;
    no_claim_line)
      SEV="warning"
      BODY_TEXT="**Claim check: no claim line.** This PR closes a claimed issue but its body has no \`claim-holder\` line. Add the line that \`.claude/scripts/pr-claim-line.sh <ISSUE>\` prints. This is a warning, not a failure." ;;
    unverifiable)
      SEV="warning"
      BODY_TEXT="**Claim check: could not verify ownership.** The issue claim or this PR's claim line could not be read, so this check passes with a warning, not as a match. Confirm the claim by hand, or re-run the check once the cause clears." ;;
  esac

  echo "::$SEV::pr-claim-check $OVERALL on PR #$PR (issues: $ISSUE_LIST): $OVERALL_REASON"
  if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
    printf 'pr-claim-check: %s on PR #%s\n' "$OVERALL" "$PR" >>"$GITHUB_STEP_SUMMARY"
  fi

  # Dedupe: one comment per PR per outcome and issue set. Best effort: GitHub
  # has no compare-and-set, so two writers can still race between the list and
  # the POST; pr-claim-check.yml serializes its own runs per PR.
  # With no resolved repository there is nowhere to read or post; the warning,
  # the step summary and the JSON above still stand.
  if [[ -z "$REPO" || -z "$PR" ]]; then
    echo "pr-claim-check: repository or PR unresolved; not posting" >&2
  elif ! gh api --paginate "repos/$REPO/issues/$PR/comments?per_page=100" >"$TMPD/comments.json" 2>/dev/null; then
    echo "pr-claim-check: could not list PR comments; not posting" >&2
  else
    EXISTING="$(jq -s --arg m "$MARKER" '[ (add // [])[] | select(((.body // "") | startswith($m))) ] | length' "$TMPD/comments.json" 2>/dev/null)" || EXISTING=""
    if [[ "$EXISTING" == "0" ]]; then
      FULL_BODY="$MARKER
$BODY_TEXT"
      if ! gh api -X POST "repos/$REPO/issues/$PR/comments" -f body="$FULL_BODY" >/dev/null 2>"$TMPD/post.err"; then
        echo "pr-claim-check: could not post the PR comment" >&2
      fi
    elif [[ -n "$EXISTING" ]]; then
      echo "pr-claim-check: comment for this outcome already on the PR; not posting again" >&2
    fi
  fi

  [[ "$OVERALL" == "foreign" ]] && exit 1
  exit 0
}

main "$@"
REPO_BOOTSTRAP_FILE_EOF
      ;;
    ".claude/scripts/issue-claim.sh")
      cat <<'REPO_BOOTSTRAP_FILE_EOF'
#!/usr/bin/env bash
# issue-claim.sh — Claim an issue at PICK time so two threads can't work it at once (issue #873).
# catalog: backlog-pm — Claim an issue at pick time so two threads cannot work the same issue at once
#
# PURPOSE
#   Every entry path that starts work on an issue (/start-issue, /subagent Step
#   6.0, a chip-launched coding thread, an ad-hoc "work on #N") used to guard
#   itself by asking "is there an open PR for this issue?" — but a PR is the LAST
#   artifact a thread produces. For the whole plan-and-code window (routinely
#   30+ minutes) that check comes back clean, so a second thread picks the same
#   issue in good faith. This script stakes the claim when work STARTS.
#
#   GitHub is the only source of truth. There is no local claim state — a
#   local file by definition cannot see a sibling thread, let alone another
#   machine. The claim is written as three GitHub artifacts:
#
#     1. the `in-progress` label   — the coarse "someone is working this" bit,
#                                    visible in every issue list at a glance
#     2. the `@me` assignee        — ownership at ACCOUNT level (issue #732)
#     3. a claim comment carrying  — HOLDER identity + the "claimed at" timestamp
#        <!-- claude-claim: {...} -->
#
# WHY A HOLDER, NOT JUST A LOGIN
#   The failure this script exists to prevent is two Claude threads belonging to
#   the SAME human. Both authenticate as the same GitHub login, so "is the
#   assignee me?" answers "yes" in both tabs and blocks nothing. The claim
#   comment therefore records a holder token, and `mine` means *this thread*,
#   not *this account*.
#
#   Holder resolution order:
#     --holder ID  ->  $CLAUDE_CLAIM_HOLDER  ->  $CLAUDE_SESSION_ID
#                  ->  h-<12 hex>   (default: a digest of <hostname>:<git toplevel>)
#   The default is honest about its granularity: two threads sharing one
#   checkout resolve to one holder. That is acceptable because CLAUDE.md
#   mandates a worktree per thread, so the mandated workflow always yields
#   distinct holders — but a caller that has a real session id should pass it.
#   The digest keeps the hostname and checkout path out of a public comment
#   (issue #2284). Claims written with the OLD default (<hostname>:<toplevel>)
#   are still recognized as `mine` by a defaulted holder: the legacy token is
#   computed locally and matched as an alias, never published. A renewal of
#   such a claim writes the new token (migrates it).
#
# WHO HOLDS IT (issue #2284)
#   A claim also records PROVIDER (which tool), DEVICE (a machine nickname) and
#   LABEL (a short run label) in the marker payload and names all three in the
#   visible sentence, so a person or another agent can tell who holds it.
#     provider: --provider -> $AGENT_CLAIM_PROVIDER -> detected agent env -> unknown
#     device:   --device   -> $AGENT_CLAIM_DEVICE   -> ~/.claude/device-nickname
#                          -> device-<6 hex> digest of the hostname
#     label:    --label    -> $AGENT_CLAIM_LABEL    -> none
#   Neither provider nor device ever falls back to the raw hostname or a path.
#   Older markers lack the fields; they read back as null and behave as before.
#
# BLOCK AT HOLDER LEVEL, RELEASE AT ACCOUNT LEVEL (deliberate asymmetry)
#   --check/--claim compare HOLDERS, so a sibling thread of yours is blocked.
#   --release compares LOGINS, so a terminal state reached by a different thread
#   of yours (a Phase C merger, a /wrap in another worktree) still clears the
#   claim instead of leaking it. Releasing your own account's claim is always
#   safe; #732 only protects a *collaborator's* claim, and that is still never
#   touched by any action here.
#
# STALE IS A WARNING, NEVER A PERMANENT BLOCK
#   A thread that dies mid-task must not poison the issue forever. A claim older
#   than CLAIM_STALE_HOURS (default 4) reports `stale` and exits 0 — startable.
#   The caller surfaces the warning and proceeds; --claim takes it over.
#
# RENEWAL — HOW LIVE WORK OUTLASTS THE STALE WINDOW (issue #1914)
#   Age is measured from the newest claim comment's GitHub `created_at`, so a
#   holder keeps a long-running claim fresh by RENEWING it: post a new marker,
#   re-read to verify it wins, then delete only this holder's older markers
#   authored by this account. The label and the old marker stay until the new
#   marker exists, so there is never an unclaimed interval.
#   - Renewal is due only once the marker is older than CLAIM_RENEW_MINUTES
#     (default: half the stale window). Inside that, a same-holder call writes
#     nothing — routine resumes cause no comment spam.
#   - --claim by the same holder renews when due (else the old no-op).
#     --renew renews when due and NEVER acquires or takes over: any verdict
#     other than `mine` exits 5 with nothing written.
#   - Renewal needs the marker's payload login AND its comment author to be the
#     viewer; a same holder token from another account is never renewed
#     (--claim warns `renew-not-authorized`, --renew exits 5).
#   - The new marker carries `since` (the original pickup time), so
#     `claimed_since` survives renewals; staleness still uses `created_at`.
#   - CLAIM_RENEW_MINUTES at or past the stale window is rejected (stderr
#     warning) in favour of the default half-window. Exception: with
#     CLAIM_STALE_HOURS=0 there is no window to compare against, so the clamp
#     does not apply (issue #1933 documents this as accepted).
#   - A renewal that loses to a newer foreign marker deletes its own new marker
#     and exits 5 (`superseded`). One that finds its replaced marker gone or the
#     issue closed on re-read (a concurrent --release) withdraws its new marker,
#     never re-adds the label, and exits 5 (`released`); a closed issue is never
#     renewed, due or not. The label/assignee is re-asserted only after
#     verification. A renewal of an already-stale own claim
#     succeeds with reason `renewed-after-expiry` and a stderr warning.
#   - After cleanup, one final re-read (issue #1933) catches a release that
#     landed after verification: no marker of this holder left, or the issue
#     closed -> withdraw, roll back what this run re-added, exit 5 `released`.
#     A surviving marker whose label was removed under it gets the label back.
#   - A not-due same-holder call on an open issue re-adds a missing label or
#     assignee (best effort), so a marker never stays invisible to label-
#     filtering readers (/wave) after a failed or raced re-assert.
#   - Residual race: a takeover that read the claim as stale BEFORE the renewal
#     can still post after verification. Renewing well inside the stale window
#     (the default threshold) is what keeps that window closed in practice.
#     The other residual windows: .claude/reference/issue-claim.md.
#
# FAIL-CLOSED
#   Any indeterminate `gh` result (viewer lookup, issue fetch, comment fetch,
#   timeline fetch) resolves to verdict `unknown`, exit 4. Callers MUST treat
#   `unknown` exactly like `claimed`: skip with a visible note. An `unknown`
#   verdict NEVER reads as permission.
#
# OVERRIDE
#   --allow-claimed proceeds past a fresh foreign claim and SAYS SO in its
#   output. It is only ever an explicit per-issue, per-session chat override
#   from the user ("start it anyway") — never a config default, never inferred
#   from context, never carried forward to the next issue.
#
# USAGE
#   issue-claim.sh <issue_number> --check   [--repo owner/repo] [--holder ID] [--json] [--no-viewer]
#   issue-claim.sh <issue_number> --claim   [--repo owner/repo] [--holder ID] [--json] [--allow-claimed]
#                    [--provider NAME] [--device NAME] [--label TEXT]
#                    [--batch LABEL --batch-size N]
#   issue-claim.sh <issue_number> --release [--repo owner/repo] [--holder ID] [--json]
#                    [--expect-claim-id ID|none]
#   issue-claim.sh <issue_number> --renew   [--repo owner/repo] [--holder ID] [--json]
#                    [--provider NAME] [--device NAME] [--label TEXT]
#                    [--batch LABEL --batch-size N]
#   issue-claim.sh --help | -h
#
#   --check          Report the verdict without writing anything.
#   --claim          Take the claim (no-op when already yours; renews when due).
#   --release        Drop your own claim (idempotent; never a collaborator's).
#   --renew          Renew this holder's own claim when due; never acquires.
#   --repo           Act on a named repo instead of the current checkout's.
#   --holder ID      Override the holder token (see above).
#   --expect-claim-id ID|none  Release only the observed winner (exit 5 if changed).
#                    --check --json exposes claim_comment_id; none means no marker.
#   --json           Machine-readable object on stdout instead of the verdict word.
#   --no-viewer      Check-only (exit 2 with any other action): skip the
#                    `gh api user` viewer lookup, for automated read-only
#                    consumers whose token cannot call it, such as the PR claim
#                    checker under an Actions installation token (issue #2412).
#                    The verdict, the holder comparison and every other
#                    fail-closed path are unchanged; --json reports
#                    viewer: null and omits the claimant_* evidence fields.
#                    Without it, a failed viewer lookup is still unknown/4.
#   --allow-claimed  Explicit user override; only valid with --claim.
#   --provider/--device/--label  Who-holds-it facts (see above); only valid with
#                    --claim or --renew. A renewal carries the old marker's
#                    values forward and fills missing ones from these.
#   --batch LABEL --batch-size N  Mark this claim as one of N taken together
#                    (issue #2286): recorded in the marker as batch/batch_size
#                    and named in the visible sentence. Only valid with --claim
#                    or --renew, and only as a pair. issue-claim-batch.sh passes
#                    them; --check --json then reports batch/batch_size (only
#                    when the winning marker has them - other output is
#                    unchanged).
#
# ENVIRONMENT
#   CLAIM_STALE_HOURS     Stale window in hours (default 4).
#   CLAIM_RENEW_MINUTES   Renewal threshold in minutes (default: half the stale
#                         window). A same-holder marker older than this renews.
#   CLAUDE_CLAIM_HOLDER   Holder token, when no --holder is passed.
#   CLAUDE_SESSION_ID     Fallback holder token.
#   AGENT_CLAIM_PROVIDER / AGENT_CLAIM_DEVICE / AGENT_CLAIM_LABEL
#                         Provider, machine nickname and run label defaults.
#
# OUTPUT
#   Default: one word on stdout — unclaimed | mine | claimed | stale | unknown.
#            Human-readable refusal / warning / override lines go to stderr, so a
#            caller reading only the exit code still surfaces a clear message.
#   --json:  {"issue":N,"repo":...,"viewer":...,"holder":...,"verdict":...,
#             "claimant":...,"claimant_holder":...,"provider":...,"device":...,
#             "label":...,"claim_comment_id":...,"claimed_at":...,
#             "claimed_since":...,"previous_claimed_at":...,"renewed":true|false,
#             "stale":true|false,"overridden":true|false,"reason":"..."}
#            claimed_at is the GitHub created_at of the live marker (after a
#            renewal, the new one); claimed_since is the original pickup time
#            (payload `since`, else claimed_at); previous_claimed_at is the
#            replaced marker's created_at when renewed is true. provider,
#            device and label describe the winning claim (null for a marker
#            written before issue #2284).
#            repo is the repository read: --repo, else the issue's
#            repository_url (no extra API call); null when neither resolves
#            (issue #2366).
#            --check on a claimed/stale verdict with a readable marker holder
#            adds claimant evidence (issue #2366) — never a verdict change:
#              claimant_is_viewer        marker login and author are the viewer
#              claimant_device_is_local  marker device equals this device's id
#              claimant_checkout         a local worktree of this repository
#                                        whose checkout-default holder is the
#                                        marker holder (viewer's claims only)
#              claimant_checkout_holder_form  "digest" (h-…) or "legacy"
#              claimant_checkout_holder  that default, derived locally from the
#                                        worktree path (not copied from GitHub)
#
# EXIT STATUS
#   0  startable / authorized — unclaimed, mine, stale, or an --allow-claimed
#      override; also every successful --claim / --release.
#   1  blocked   — a fresh claim held by another thread or person, or (--check
#                  / --claim) the issue carries the `human-tasks` label: the
#                  owner's own to-do list, never agent work (issue #2539).
#                  Verdict `claimed`; --allow-claimed does not lift it.
#   2  usage     — bad/missing issue number, unknown or conflicting flags.
#   3  not_found — no such issue.
#   4  unknown   — claim state undetermined. FAIL-CLOSED: treat as claimed.
#                  Includes a renewal that could not be written or verified.
#   5  not held  — --renew found no claim held by this holder (`not-held`,
#                  `renew-not-authorized`), or a renewal was superseded by a
#                  newer foreign marker (`superseded`) or released under it /
#                  the issue closed (`released`). Stop and report lost
#                  ownership; nothing of anyone else's was touched.
#                  Also: --release --expect-claim-id observed a changed winner
#                  or remaining markers; their metadata is retained.
#   70  --help header extraction produced no output (internal defect).
#
# DEPENDENCIES
#   - gh (authenticated)
#   - jq
#
# EXAMPLES
#   issue-claim.sh 873 --check                 # -> unclaimed (exit 0)
#   issue-claim.sh 873 --claim                 # -> mine      (exit 0)
#   issue-claim.sh 873 --check                 # -> claimed   (exit 1, in another thread)
#   issue-claim.sh 873 --claim --allow-claimed # -> mine      (exit 0, override stated)
#   issue-claim.sh 873 --renew --holder "$H"   # -> mine      (exit 0; renewed when due)
#   issue-claim.sh 873 --release               # -> unclaimed (exit 0)
#   issue-claim.sh --pickup-time MERGED_AT < comments.json  # pure pickup-time lookup

set -uo pipefail

CLAIM_MARKER="claude-claim"

# Classify the two protocol envelopes, not arbitrary Markdown. The writer has
# always used the claim notice, a blank line, then the hidden marker; a bare
# marker comment is also accepted. Quoted examples cannot enter either form.
# No output means "not a record". A null line is a recognized but damaged
# envelope and must remain a candidate so the newest unreadable record blocks.
filter_claim_comments() {
  jq -s --arg m "$CLAIM_MARKER" '
    def marker_start($prefix): test("^[ ]{0,3}" + $prefix);
    def record_line($prefix):
      (gsub("\r\n"; "\n") | sub("^\n+"; "") | sub("\n+$"; "") | split("\n")) as $lines
      | if ($lines[0] | test("^🔒 Claimed by `[^`]+` for active work[.]")) then
          if ($lines | length) == 3 and $lines[1] == ""
             and ($lines[2] | marker_start($prefix))
          then $lines[2] else null end
        elif ($lines[0] | marker_start($prefix)) then
          if ($lines | length) == 1 then $lines[0] else null end
        else empty end;
    def decode($line; $prefix):
      if $line == null then null
      else
        (try ($line | capture("^[ ]{0,3}" + $prefix + " *(?<p>.*)-->[ \t]*$") | .p | fromjson)
         catch null) // null
      end
      | if type == "object" then . else null end;
    ("<!-- " + $m + ":") as $prefix
    | [ .[] | .[]? | select(.body != null and (.body | contains($prefix) or contains("🔒 Claimed by ")))
        | (.body | record_line($prefix)) as $line
        | ._claim_payload = decode($line; $prefix) ]'
}

# Pure input mode for estimate logging. Take paginated GitHub comment arrays
# on stdin. It does not resolve a repository, log usage, or change ownership.
estimate_pickup_time() {
  [[ $# == 1 ]] || { printf '%s\n' 'Usage: issue-claim.sh --pickup-time MERGED_AT < comments.json' >&2; return 2; }
  local records result
  records="$(filter_claim_comments)" || return 4
  result="$(printf '%s' "$records" | jq -r --arg bound "$1" '
    def utc:
      . as $text
      | type == "string" and test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$")
        and ((try (fromdateiso8601 | strftime("%Y-%m-%dT%H:%M:%SZ")) catch null) == $text);
    def holder_ok: type == "string" and length > 0 and all(explode[]; . >= 32 and . != 127);
    if ($bound != "" and ($bound | utc | not)) or any(.[]; (.created_at | utc | not)) then
      empty
    else
      [.[] | select($bound == "" or .created_at <= $bound)]
      | sort_by(.created_at, .id) | last as $record
      | $record._claim_payload as $payload
      | select($payload.holder | holder_ok)
      | ($payload.since | select(utc and . <= $record.created_at)) // $record.created_at
    end')" || return 4
  [[ -n "$result" ]] || return 3
  printf '%s\n' "$result"
}

if [[ "${1:-}" == --pickup-time ]]; then
  shift
  estimate_pickup_time "$@"
  exit $?
fi

# The usage ledger is advisory; an unset HOME must not block ownership checks.
if [[ -n "${HOME:-}" ]]; then
  printf '%s\t%s\t%s\n' "$(date -u +%FT%TZ)" "$(basename "$0")" "${*//$'\n'/ }" 2>/dev/null >> "$HOME/.claude/script-usage.log" || true
fi

CLAIM_LABEL="in-progress"
# The owner's own to-do list issue (#2539): never startable.
HUMAN_TASKS_LABEL="human-tasks"
GUARD_REF="the issue-claim guard (.claude/rules/issue-planning.md)"

print_help() {
  # Print the leading comment header (everything after the shebang up to the
  # first blank line), stripping the leading "# ".
  awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; n = 1; next } { exit } END { exit(n ? 0 : 1) }' "$0" ||
    { printf '%s: --help header extraction produced no output\n' "$0" >&2; exit 70; }
}

die_usage() {
  echo "issue-claim.sh: $1" >&2
  echo "Run with --help for usage." >&2
  exit 2
}

# --- arg parsing ---------------------------------------------------------------
ISSUE_NUMBER=""
REPO=""
ACTION=""
HOLDER_ARG=""
JSON=0
ALLOW_CLAIMED=0
EXPECT_CLAIM_ID_SET=0
EXPECTED_CLAIM_ID=""
PROVIDER_ARG=""
DEVICE_ARG=""
LABEL_ARG=""
BATCH_ARG=""
BATCH_SIZE_ARG=""
NO_VIEWER=0

set_action() {
  [[ -n "$ACTION" ]] && die_usage "only one of --check / --claim / --release / --renew may be given (got --$ACTION and $1)"
  ACTION="${1#--}"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help)      print_help; exit 0 ;;
    --check|--claim|--release|--renew) set_action "$1"; shift ;;
    --json)         JSON=1; shift ;;
    --allow-claimed) ALLOW_CLAIMED=1; shift ;;
    --no-viewer)    NO_VIEWER=1; shift ;;
    --repo)
      [[ $# -lt 2 || -z "${2-}" ]] && die_usage "--repo requires a value (owner/repo)"
      REPO="$2"; shift 2 ;;
    --repo=*)
      REPO="${1#--repo=}"
      [[ -z "$REPO" ]] && die_usage "--repo requires a value (owner/repo)"
      shift ;;
    --expect-claim-id)
      [[ $# -ge 2 ]] || die_usage "--expect-claim-id requires an ID or none"
      EXPECTED_CLAIM_ID="$2"; EXPECT_CLAIM_ID_SET=1; shift 2 ;;
    --expect-claim-id=*)
      EXPECTED_CLAIM_ID="${1#--expect-claim-id=}"; EXPECT_CLAIM_ID_SET=1; shift ;;
    --holder)
      [[ $# -lt 2 || -z "${2-}" ]] && die_usage "--holder requires a value"
      HOLDER_ARG="$2"; shift 2 ;;
    --holder=*)
      HOLDER_ARG="${1#--holder=}"
      [[ -z "$HOLDER_ARG" ]] && die_usage "--holder requires a value"
      shift ;;
    --provider|--device|--label)
      # A following option is a missing value; use --flag=VALUE for a literal.
      [[ $# -lt 2 || -z "${2-}" || "${2-}" == --* ]] && die_usage "$1 requires a value"
      case "$1" in
        --provider) PROVIDER_ARG="$2" ;;
        --device)   DEVICE_ARG="$2" ;;
        --label)    LABEL_ARG="$2" ;;
      esac
      shift 2 ;;
    --provider=*|--device=*|--label=*)
      [[ -z "${1#*=}" ]] && die_usage "${1%%=*} requires a value"
      case "$1" in
        --provider=*) PROVIDER_ARG="${1#*=}" ;;
        --device=*)   DEVICE_ARG="${1#*=}" ;;
        --label=*)    LABEL_ARG="${1#*=}" ;;
      esac
      shift ;;
    --batch|--batch-size)
      [[ $# -lt 2 || -z "${2-}" || "${2-}" == --* ]] && die_usage "$1 requires a value"
      case "$1" in
        --batch)      BATCH_ARG="$2" ;;
        --batch-size) BATCH_SIZE_ARG="$2" ;;
      esac
      shift 2 ;;
    --batch=*|--batch-size=*)
      [[ -z "${1#*=}" ]] && die_usage "${1%%=*} requires a value"
      case "$1" in
        --batch=*)      BATCH_ARG="${1#*=}" ;;
        --batch-size=*) BATCH_SIZE_ARG="${1#*=}" ;;
      esac
      shift ;;
    --) shift; break ;;
    -*) die_usage "unknown flag: $1" ;;
    *)
      [[ -n "$ISSUE_NUMBER" ]] && die_usage "unexpected positional argument: $1"
      ISSUE_NUMBER="$1"; shift ;;
  esac
done

[[ -z "$ISSUE_NUMBER" ]] && die_usage "<issue_number> is required"
[[ "$ISSUE_NUMBER" =~ ^[1-9][0-9]*$ ]] || die_usage "<issue_number> must be a positive integer, got: $ISSUE_NUMBER"
[[ -z "$ACTION" ]] && die_usage "one of --check / --claim / --release / --renew is required"
if (( EXPECT_CLAIM_ID_SET )); then
  [[ "$ACTION" == release ]] || die_usage "--expect-claim-id is release-only"
  [[ "$EXPECTED_CLAIM_ID" == none || "$EXPECTED_CLAIM_ID" =~ ^[1-9][0-9]*$ ]] || die_usage "--expect-claim-id requires a positive ID or none"
fi
if [[ -n "$REPO" ]] && ! [[ "$REPO" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]]; then
  die_usage "--repo must be owner/repo, got: $REPO"
fi
# --allow-claimed is a write-time override; on --check or --release it would be
# silently inert, and a silently-inert override flag is how an override leaks
# into a config default. Reject it outright instead.
if (( ALLOW_CLAIMED )) && [[ "$ACTION" != "claim" ]]; then
  die_usage "--allow-claimed is only valid with --claim"
fi

# --no-viewer drops the account lookup that every write authorizes against, so
# it is a read-only mode: rejected outright with any action that writes.
if (( NO_VIEWER )) && [[ "$ACTION" != "check" ]]; then
  die_usage "--no-viewer is only valid with --check"
fi

if [[ -n "$PROVIDER_ARG$DEVICE_ARG$LABEL_ARG" && "$ACTION" != claim && "$ACTION" != renew ]]; then
  die_usage "--provider / --device / --label are only valid with --claim or --renew"
fi

if [[ -n "$BATCH_ARG$BATCH_SIZE_ARG" ]]; then
  [[ "$ACTION" == claim || "$ACTION" == renew ]] || die_usage "--batch / --batch-size are only valid with --claim or --renew"
  [[ -n "$BATCH_ARG" && -n "$BATCH_SIZE_ARG" ]] || die_usage "--batch and --batch-size must be given together"
  [[ "$BATCH_SIZE_ARG" =~ ^[1-9][0-9]{0,3}$ ]] || die_usage "--batch-size must be a positive integer up to 9999, got: $BATCH_SIZE_ARG"
fi

for dep in gh jq; do
  command -v "$dep" >/dev/null 2>&1 || { echo "issue-claim.sh: '$dep' not found on PATH" >&2; exit 2; }
done

STALE_HOURS="${CLAIM_STALE_HOURS:-4}"
if ! [[ "$STALE_HOURS" =~ ^[0-9]+$ ]]; then
  die_usage "CLAIM_STALE_HOURS must be a non-negative integer, got: $STALE_HOURS"
fi
# Force base 10: a leading zero (`08`) passes the digit check but is invalid
# octal in shell arithmetic.
STALE_HOURS=$(( 10#$STALE_HOURS ))
# Renewal threshold: half the stale window by default, so live work renews well
# before any other holder can read its claim as stale.
RENEW_MINUTES="${CLAIM_RENEW_MINUTES:-$(( STALE_HOURS * 30 ))}"
if ! [[ "$RENEW_MINUTES" =~ ^[0-9]+$ ]]; then
  die_usage "CLAIM_RENEW_MINUTES must be a non-negative integer, got: $RENEW_MINUTES"
fi
RENEW_MINUTES=$(( 10#$RENEW_MINUTES ))
# A threshold at or past the stale window would let another holder read live
# work as stale (and take it over) before renewal is ever due. Fall back to the
# default half-window instead of honouring it. STALE_HOURS=0 is exempt on
# purpose: every claim is stale at once there, so no threshold can keep it
# fresh, and rejecting it would turn --check/--release into usage errors too
# (accepted residual, issue #1933).
if [[ -n "${CLAIM_RENEW_MINUTES:-}" ]] && (( STALE_HOURS > 0 && RENEW_MINUTES * 60 >= STALE_HOURS * 3600 )); then
  echo "issue-claim.sh: warning — CLAIM_RENEW_MINUTES=$RENEW_MINUTES is not below the ${STALE_HOURS}h stale window; using the default $(( STALE_HOURS * 30 ))m instead" >&2
  RENEW_MINUTES=$(( STALE_HOURS * 30 ))
fi

# --- holder resolution ---------------------------------------------------------
resolve_holder() {
  [[ -n "$HOLDER_ARG" ]] && { printf '%s' "$HOLDER_ARG"; return; }
  [[ -n "${CLAUDE_CLAIM_HOLDER:-}" ]] && { printf '%s' "$CLAUDE_CLAIM_HOLDER"; return; }
  [[ -n "${CLAUDE_SESSION_ID:-}" ]] && { printf '%s' "$CLAUDE_SESSION_ID"; return; }
  local d
  d="$(digest_hex "$(legacy_holder)" 12)" || return 1
  printf 'h-%s' "$d"
}
# legacy_holder [toplevel]: the pre-#2284 default token. Computed only to be
# hashed or to be matched against older markers; it is never written to GitHub.
# The optional argument names another checkout's top level (claimant evidence,
# issue #2366); without it the current checkout is used.
legacy_holder() {
  local host top
  host="$(hostname -s 2>/dev/null || hostname 2>/dev/null || echo unknown-host)"
  top="${1:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
  printf '%s:%s' "$host" "$top"
}
# digest_hex <text> <n>: first n hex chars of a SHA-256 (cksum as a last resort).
digest_hex() {
  local d=""
  if command -v shasum >/dev/null 2>&1; then
    d="$(printf '%s' "$1" | shasum -a 256 2>/dev/null | cut -c1-64)"
  elif command -v sha256sum >/dev/null 2>&1; then
    d="$(printf '%s' "$1" | sha256sum 2>/dev/null | cut -c1-64)"
  fi
  # No SHA-256 tool: fail closed. A 32-bit checksum could collide and let
  # another checkout read as the same holder, bypassing the claim block.
  if [[ -z "$d" ]]; then
    echo "issue-claim.sh: no shasum or sha256sum found; cannot derive a default holder/device id; pass --holder/--device or set CLAUDE_CLAIM_HOLDER/AGENT_CLAIM_DEVICE" >&2
    return 1
  fi
  printf '%s' "${d:0:$2}"
}
# Append a sentinel so command substitution cannot silently trim a malformed
# holder into the identity of a different thread.
HOLDER="$(resolve_holder && printf '.')"
[[ -n "$HOLDER" ]] || die_usage "could not resolve a holder token"
HOLDER="${HOLDER%.}"
[[ "$HOLDER" =~ [[:cntrl:]] ]] && die_usage "holder must not contain control characters"

# A defaulted holder also answers to the legacy default token, so claims written
# before the digest default stay `mine` (issue #2284). An explicit holder never
# gets an alias.
HOLDER_LEGACY=""
if [[ -z "$HOLDER_ARG" && -z "${CLAUDE_CLAIM_HOLDER:-}" && -z "${CLAUDE_SESSION_ID:-}" ]]; then
  HOLDER_LEGACY="$(legacy_holder)"
fi
# holder_is_mine <token>: true when the token is this holder (or its legacy alias).
holder_is_mine() {
  [[ -n "$1" && ( "$1" == "$HOLDER" || ( -n "$HOLDER_LEGACY" && "$1" == "$HOLDER_LEGACY" ) ) ]]
}

# --- provider / device / label (issue #2284) -----------------------------------
# Values are published in a public comment, so they are restricted to a small
# safe alphabet: no path separators, no markup, no control characters.
FACT_RE='^[A-Za-z0-9._:+@#-][A-Za-z0-9 ._:+@#-]{0,63}$'
valid_fact() { [[ "$1" =~ $FACT_RE ]]; }

resolve_provider() {
  local v="${PROVIDER_ARG:-${AGENT_CLAIM_PROVIDER:-}}"
  if [[ -z "$v" ]]; then
    if [[ -n "${CLAUDECODE:-}" || -n "${CLAUDE_CODE_ENTRYPOINT:-}" || -n "${CLAUDE_SESSION_ID:-}" ]]; then
      v="claude-code"
    elif [[ -n "${CODEX_SANDBOX:-}" || -n "${CODEX_THREAD_ID:-}" || -n "${CODEX_HOME:-}" ]]; then
      v="codex"
    elif [[ -n "${CURSOR_AGENT:-}" || -n "${CURSOR_TRACE_ID:-}" ]]; then
      v="cursor"
    else
      v="unknown"
    fi
  fi
  printf '%s' "$v" | tr '[:upper:]' '[:lower:]'
}
resolve_device() {
  local v="${DEVICE_ARG:-${AGENT_CLAIM_DEVICE:-}}"
  if [[ -z "$v" && -n "${HOME:-}" && -r "$HOME/.claude/device-nickname" ]]; then
    v="$(head -n 1 "$HOME/.claude/device-nickname" 2>/dev/null || true)"
    v="${v%$'\r'}"
    # A free-form nickname file must never block claiming: only this file-sourced
    # value falls back to the hostname-derived id; explicit values stay strict.
    valid_fact "$v" || v=""
  fi
  [[ -n "$v" ]] || v="device-$(digest_hex "$(hostname -s 2>/dev/null || hostname 2>/dev/null || echo unknown-host)" 6)" || return 1
  printf '%s' "$v"
}
RES_PROVIDER=""; RES_DEVICE=""; RES_LABEL=""; RES_BATCH=""; RES_BATCH_SIZE=""
if [[ "$ACTION" == claim || "$ACTION" == renew ]]; then
  RES_PROVIDER="$(resolve_provider)"
  RES_DEVICE="$(resolve_device)" || die_usage "could not resolve a device id"
  RES_LABEL="${LABEL_ARG:-${AGENT_CLAIM_LABEL:-}}"
  RES_BATCH="$BATCH_ARG"; RES_BATCH_SIZE="$BATCH_SIZE_ARG"
  valid_fact "$RES_PROVIDER" || die_usage "provider must be 1-64 chars of letters, digits, space or . _ : + @ # - (got: $RES_PROVIDER)"
  valid_fact "$RES_DEVICE" || die_usage "device must be 1-64 chars of letters, digits, space or . _ : + @ # - (got: $RES_DEVICE)"
  if [[ -n "$RES_LABEL" ]]; then
    valid_fact "$RES_LABEL" || die_usage "label must be 1-64 chars of letters, digits, space or . _ : + @ # - (got: $RES_LABEL)"
  fi
  if [[ -n "$RES_BATCH" ]]; then
    valid_fact "$RES_BATCH" || die_usage "batch must be 1-64 chars of letters, digits, space or . _ : + @ # - (got: $RES_BATCH)"
  fi
fi

# --- API path helpers ----------------------------------------------------------
# {owner}/{repo} resolves from the current checkout unless --repo names one.
REPO_PREFIX="repos/{owner}/{repo}"
[[ -n "$REPO" ]] && REPO_PREFIX="repos/$REPO"

# Select the repo via GH_REPO rather than a `--repo` argument array: an empty
# array expanded under `set -u` is an unbound-variable error in bash 3.2, which
# is the shell macOS ships. GH_REPO is read natively by every `gh` subcommand
# and by the {owner}/{repo} placeholder, so one export covers all of them.
[[ -n "$REPO" ]] && export GH_REPO="$REPO"

# --- emit helper ---------------------------------------------------------------
# Populated as the state is read; emit() serializes whatever is known.
VIEWER=""
VERDICT=""
CLAIMANT=""
CLAIMANT_HOLDER=""
CLAIMED_AT=""
CLAIMED_SINCE=""
PREVIOUS_CLAIMED_AT=""
RENEWED="false"
MARKER_ID=""
MARKER_AUTHOR=""
MARKER_SINCE=""
CLAIM_PROVIDER=""
CLAIM_DEVICE=""
CLAIM_LABEL_TEXT=""
CLAIM_BATCH=""
CLAIM_BATCH_SIZE=""
IS_STALE="false"
OVERRIDDEN="false"
# The repository actually read: --repo, else the issue's repository_url (#2366).
RESOLVED_REPO="$REPO"
# Claimant evidence for --check (issue #2366). Empty = not computed (null).
EV_IS_VIEWER=""
EV_DEVICE_LOCAL=""
EV_CHECKOUT=""
EV_FORM=""
EV_CHECKOUT_HOLDER=""

# emit <verdict> <exit_code> <reason>
emit() {
  local verdict="$1" code="$2" reason="$3" observed_claim_id=null
  if [[ "$ACTION" == check && "${W_ID:-}" =~ ^[1-9][0-9]*$ ]]; then
    observed_claim_id="$W_ID"
  fi
  if [[ "$JSON" -eq 1 ]]; then
    jq -cn \
      --argjson issue "$ISSUE_NUMBER" \
      --arg repo "${RESOLVED_REPO:-$REPO}" \
      --arg civ "$EV_IS_VIEWER" \
      --arg cdl "$EV_DEVICE_LOCAL" \
      --arg cco "$EV_CHECKOUT" \
      --arg cform "$EV_FORM" \
      --arg cch "$EV_CHECKOUT_HOLDER" \
      --arg viewer "$VIEWER" \
      --arg holder "$HOLDER" \
      --arg verdict "$verdict" \
      --arg claimant "$CLAIMANT" \
      --arg claimant_holder "$CLAIMANT_HOLDER" \
      --arg provider "$CLAIM_PROVIDER" \
      --arg device "$CLAIM_DEVICE" \
      --arg label "$CLAIM_LABEL_TEXT" \
      --arg batch "$CLAIM_BATCH" \
      --arg batch_size "$CLAIM_BATCH_SIZE" \
      --argjson claim_comment_id "$observed_claim_id" \
      --arg claimed_at "$CLAIMED_AT" \
      --arg claimed_since "$CLAIMED_SINCE" \
      --arg previous_claimed_at "$PREVIOUS_CLAIMED_AT" \
      --argjson renewed "$RENEWED" \
      --argjson stale "$IS_STALE" \
      --argjson overridden "$OVERRIDDEN" \
      --arg reason "$reason" \
      '{issue: $issue,
        repo: (if $repo == "" then null else $repo end),
        viewer: (if $viewer == "" then null else $viewer end),
        holder: $holder,
        verdict: $verdict,
        claimant: (if $claimant == "" then null else $claimant end),
        claimant_holder: (if $claimant_holder == "" then null else $claimant_holder end),
        provider: (if $provider == "" then null else $provider end),
        device: (if $device == "" then null else $device end),
        label: (if $label == "" then null else $label end),
        claim_comment_id: $claim_comment_id,
        claimed_at: (if $claimed_at == "" then null else $claimed_at end),
        claimed_since: (if $claimed_since == "" then null else $claimed_since end),
        previous_claimed_at: (if $previous_claimed_at == "" then null else $previous_claimed_at end),
        renewed: $renewed,
        stale: $stale,
        overridden: $overridden,
        reason: $reason}
       | if $batch == "" then . else . + {batch: $batch, batch_size: ($batch_size | tonumber)} end
       | if $civ == "" then . else . + {
           claimant_is_viewer: ($civ == "true"),
           claimant_device_is_local: ($cdl == "true"),
           claimant_checkout: (if $cco == "" then null else $cco end),
           claimant_checkout_holder_form: (if $cform == "" then null else $cform end),
           claimant_checkout_holder: (if $cch == "" then null else $cch end)} end'
  else
    printf '%s\n' "$verdict"
  fi
  # Non-startable verdicts, the stale warning, and the override statement all go
  # to stderr so a caller reading only the exit code still surfaces a message.
  case "$verdict" in
    claimed|unknown) echo "issue-claim.sh: $reason" >&2 ;;
    stale)           echo "issue-claim.sh: $reason" >&2 ;;
    *)               [[ "$code" -eq 5 ]] && echo "issue-claim.sh: $reason" >&2 ;;
  esac
  [[ "$OVERRIDDEN" == "true" ]] && echo "issue-claim.sh: OVERRIDE — proceeding past a live claim on issue #$ISSUE_NUMBER because --allow-claimed was passed. This is only valid as an explicit per-issue instruction from the user; it is never a default." >&2
  exit "$code"
}

fail_closed() {
  emit unknown 4 "$1 — claim state undetermined; treat issue #$ISSUE_NUMBER as claimed (fail-closed per $GUARD_REF)"
}

# --- resolve the authenticated viewer ------------------------------------------
# --no-viewer (check-only) skips it: VIEWER stays empty and --json says null.
if (( ! NO_VIEWER )); then
  VIEWER="$(gh api user --jq '.login' 2>/dev/null || true)"
  if [[ -z "$VIEWER" || "$VIEWER" == "null" ]]; then
    fail_closed "could not resolve the authenticated user (gh api user failed)"
  fi
fi

# --- read the issue ------------------------------------------------------------
ERR_FILE="$(mktemp)"
trap 'rm -f "$ERR_FILE" 2>/dev/null' EXIT

if ! ISSUE_JSON="$(gh api "$REPO_PREFIX/issues/$ISSUE_NUMBER" 2>"$ERR_FILE")"; then
  # ERE for BSD/macOS grep portability (pr-authorship.sh lesson).
  if grep -qiE "http 404|not found|could not resolve|no such" "$ERR_FILE"; then
    emit unknown 3 "issue #$ISSUE_NUMBER not found${REPO:+ in $REPO} — cannot act"
  fi
  fail_closed "gh api failed reading issue #$ISSUE_NUMBER ($(tr '\n' ' ' < "$ERR_FILE"))"
fi

# Report which repository was read even without --repo (issue #2366), from data
# already fetched. Never changes a verdict; an unreadable value stays null.
REPO_RE='^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$'
if [[ -z "$RESOLVED_REPO" ]]; then
  RESOLVED_REPO="$(printf '%s' "$ISSUE_JSON" | jq -r '(.repository_url // "") | if type == "string" then (capture("/repos/(?<r>[^/]+/[^/]+)$").r // "") else "" end' 2>/dev/null || true)"
  [[ "$RESOLVED_REPO" =~ $REPO_RE ]] || RESOLVED_REPO=""
fi

HAS_LABEL="$(printf '%s' "$ISSUE_JSON" | jq -r --arg l "$CLAIM_LABEL" '[.labels[]?.name] | index($l) != null' 2>/dev/null || echo "ERR")"
[[ "$HAS_LABEL" == "ERR" ]] && fail_closed "could not parse issue #$ISSUE_NUMBER labels"
ASSIGNEES="$(printf '%s' "$ISSUE_JSON" | jq -r '[.assignees[]?.login] | join(" ")' 2>/dev/null || echo "ERR")"
[[ "$ASSIGNEES" == "ERR" ]] && fail_closed "could not parse issue #$ISSUE_NUMBER assignees"

# The owner's `human-tasks` list issue (#2539) holds the owner's own to-dos: it is never
# agent work, so --check and --claim report it as not startable (verdict
# `claimed`, exit 1 — the existing "skip it" contract every caller already
# honours). --allow-claimed does not lift it; --release and --renew are unaffected.
if [[ "$ACTION" == check || "$ACTION" == claim ]]; then
  IS_HUMAN_TASKS="$(printf '%s' "$ISSUE_JSON" | jq -r --arg l "$HUMAN_TASKS_LABEL" '[.labels[]?.name | ascii_downcase] | index($l) != null' 2>/dev/null || echo "ERR")"
  [[ "$IS_HUMAN_TASKS" == "ERR" ]] && fail_closed "could not parse issue #$ISSUE_NUMBER labels"
  if [[ "$IS_HUMAN_TASKS" == "true" ]]; then
    emit claimed 1 "issue #$ISSUE_NUMBER is the owner's $HUMAN_TASKS_LABEL list — the owner's own to-dos, never agent work; not startable, and --allow-claimed does not override it"
  fi
fi

# --- read the claim comment ----------------------------------------------------
# The marker is an HTML comment so it renders invisibly, and carries the holder
# token + claimant login as JSON. Newest matching comment wins.
if ! COMMENTS_JSON="$(gh api --paginate "$REPO_PREFIX/issues/$ISSUE_NUMBER/comments?per_page=100" 2>"$ERR_FILE")"; then
  fail_closed "gh api failed reading issue #$ISSUE_NUMBER comments ($(tr '\n' ' ' < "$ERR_FILE"))"
fi

# --paginate concatenates one JSON array per page; -s flattens them into one.
CLAIM_COMMENTS="$(printf '%s' "$COMMENTS_JSON" | filter_claim_comments 2>/dev/null || echo "ERR")"
[[ "$CLAIM_COMMENTS" == "ERR" ]] && fail_closed "could not parse issue #$ISSUE_NUMBER comments"

# Select the winning (newest) claim comment and parse its payload. The payload
# is the JSON object between the marker prefix and the closing " -->". Ties on
# created_at break on the comment id, so "which marker wins" is deterministic —
# renewal verification compares winners by id. One jq pass emits the winner's
# fields separated by US (0x1f): a non-whitespace IFS keeps empty fields
# positional, which a tab would not. Reject control bytes before serialization:
# a payload separator or NUL can shift or truncate a holder in Bash. A present
# but unreadable winner is not an empty marker list.
#
# parse_winner <claim-comments-json> -> sets W_ID W_AUTHOR W_HOLDER W_LOGIN W_SINCE W_AT
#   plus W_PROVIDER W_DEVICE W_LABEL (empty for a marker older than issue #2284)
# An empty array is a successful read of absence; any unreadable winner is nonzero.
parse_winner() {
  W_ID=""; W_AUTHOR=""; W_HOLDER=""; W_LOGIN=""; W_SINCE=""; W_AT=""
  W_PROVIDER=""; W_DEVICE=""; W_LABEL=""; W_BATCH=""; W_BATCH_SIZE=""
  [[ "$1" == '[]' ]] && return 0
  local rec
  rec="$(printf '%s' "$1" | jq -r '
    (sort_by(.created_at, .id) | last) as $c
    | $c._claim_payload as $p
    | select(($p.holder | type) == "string" and ($p.holder | length) > 0)
    | [($c.id // ""), ($c.user.login // ""), ($p.holder // ""), ($p.login // ""),
       ($p.since // ""), ($c.created_at // ""),
       (if ($p.provider | type) == "string" then $p.provider else "" end),
       (if ($p.device | type) == "string" then $p.device else "" end),
       (if ($p.label | type) == "string" then $p.label else "" end),
       (if ($p.batch | type) == "string" and ($p.batch_size | type) == "number" and ($p.batch_size | floor) >= 1 and ($p.batch_size | floor) <= 9999 then $p.batch else "" end),
       (if ($p.batch | type) == "string" and ($p.batch_size | type) == "number" and ($p.batch_size | floor) >= 1 and ($p.batch_size | floor) <= 9999 then ($p.batch_size | floor) else "" end)]
    | map(tostring)
    | select(all(.[]; all(explode[]; . >= 32 and . != 127)))
    | join("\u001f")' 2>/dev/null)" || return 1
  [[ -n "$rec" ]] || return 1
  IFS=$'\x1f' read -r W_ID W_AUTHOR W_HOLDER W_LOGIN W_SINCE W_AT W_PROVIDER W_DEVICE W_LABEL W_BATCH W_BATCH_SIZE <<<"$rec"
}

# read_claim_comments -> stdout: the claim-marker comments as one JSON array.
# Returns non-zero on any read or parse failure (callers fail closed). Used for
# the renewal's verification re-read; the initial read above keeps its own
# distinct error messages.
read_claim_comments() {
  local raw
  raw="$(gh api --paginate "$REPO_PREFIX/issues/$ISSUE_NUMBER/comments?per_page=100" 2>"$ERR_FILE")" || return 1
  printf '%s' "$raw" | filter_claim_comments 2>/dev/null
}

parse_winner "$CLAIM_COMMENTS" || fail_closed "newest claim marker for issue #$ISSUE_NUMBER is unreadable"
MARKER_ID="$W_ID"
MARKER_AUTHOR="$W_AUTHOR"
CLAIMANT_HOLDER="$W_HOLDER"
CLAIMANT="$W_LOGIN"
CLAIMED_AT="$W_AT"
MARKER_SINCE="$W_SINCE"
CLAIM_PROVIDER="$W_PROVIDER"
CLAIM_DEVICE="$W_DEVICE"
CLAIM_LABEL_TEXT="$W_LABEL"
CLAIM_BATCH="$W_BATCH"; CLAIM_BATCH_SIZE="$W_BATCH_SIZE"

HAS_CLAIM_COMMENT=0
[[ -n "$CLAIMANT_HOLDER" ]] && HAS_CLAIM_COMMENT=1

# --- fallback timestamp: the label's most recent `labeled` timeline event ------
# Only needed when the label was applied without a claim comment (a human
# labelling the issue by hand). Skipped otherwise so the common path stays at
# three API reads.
if [[ "$HAS_LABEL" == "true" && "$HAS_CLAIM_COMMENT" -eq 0 ]]; then
  if ! TIMELINE_JSON="$(gh api --paginate "$REPO_PREFIX/issues/$ISSUE_NUMBER/timeline?per_page=100" 2>"$ERR_FILE")"; then
    fail_closed "gh api failed reading issue #$ISSUE_NUMBER timeline ($(tr '\n' ' ' < "$ERR_FILE"))"
  fi
  CLAIMED_AT="$(printf '%s' "$TIMELINE_JSON" | jq -rs --arg l "$CLAIM_LABEL" '
    [ .[] | .[]? | select(.event == "labeled" and .label.name == $l) ]
    | if length == 0 then "" else (sort_by(.created_at) | last | .created_at) end' 2>/dev/null || printf '')"
fi

# --- staleness -----------------------------------------------------------------
# Portable epoch conversion: GNU date and BSD date disagree on -d/-j, so parse
# the ISO-8601 timestamp arithmetically instead of shelling out to either.
iso_to_epoch() {
  local ts="$1"
  [[ -z "$ts" ]] && { printf ''; return; }
  printf '%s' "$ts" | awk '
    match($0, /^([0-9]{4})-([0-9]{2})-([0-9]{2})T([0-9]{2}):([0-9]{2}):([0-9]{2})/) {
      y = substr($0,1,4)+0; mo = substr($0,6,2)+0; d = substr($0,9,2)+0
      h = substr($0,12,2)+0; mi = substr($0,15,2)+0; s = substr($0,18,2)+0
      # Days since the Unix epoch via the civil-from-days algorithm.
      yy = y - (mo <= 2 ? 1 : 0)
      era = int((yy >= 0 ? yy : yy - 399) / 400)
      yoe = yy - era * 400
      doy = int((153 * (mo + (mo > 2 ? -3 : 9)) + 2) / 5) + d - 1
      doe = yoe * 365 + int(yoe/4) - int(yoe/100) + doy
      days = era * 146097 + doe - 719468
      print days * 86400 + h * 3600 + mi * 60 + s
    }'
}

# claimed_since: the original pickup time. A renewed marker carries it as the
# payload `since`; an unparseable or absent `since` falls back to created_at.
CLAIMED_SINCE="$CLAIMED_AT"
if [[ -n "$MARKER_SINCE" && -n "$(iso_to_epoch "$MARKER_SINCE")" ]]; then
  CLAIMED_SINCE="$MARKER_SINCE"
fi

NOW_EPOCH="$(date -u +%s)"
CLAIMED_EPOCH="$(iso_to_epoch "$CLAIMED_AT")"
AGE_SECONDS=""
if [[ -n "$CLAIMED_EPOCH" ]]; then
  AGE_SECONDS=$(( NOW_EPOCH - CLAIMED_EPOCH ))
fi

is_stale() {
  # A claim with no readable timestamp cannot be aged out. Fail closed: it stays
  # a live claim rather than expiring instantly into "startable".
  [[ -z "$AGE_SECONDS" ]] && return 1
  (( AGE_SECONDS > STALE_HOURS * 3600 ))
}

# --- verdict -------------------------------------------------------------------
# A claim exists when EITHER artifact is present: the comment (written by this
# script) or the label (which a human may apply by hand). Requiring both would
# let a half-written claim read as unclaimed.
CLAIM_EXISTS=0
[[ "$HAS_LABEL" == "true" || "$HAS_CLAIM_COMMENT" -eq 1 ]] && CLAIM_EXISTS=1

if (( ! CLAIM_EXISTS )); then
  VERDICT="unclaimed"
elif [[ "$HAS_CLAIM_COMMENT" -eq 1 ]] && holder_is_mine "$CLAIMANT_HOLDER"; then
  VERDICT="mine"
elif is_stale; then
  VERDICT="stale"
  IS_STALE="true"
else
  VERDICT="claimed"
fi

viewer_owns_claim() {
  # Account-level ownership, for --release only (see the header's asymmetry
  # note). True when the claim comment is the viewer's, or when there is no
  # claim comment but the viewer is assigned alongside the label.
  if [[ "$HAS_CLAIM_COMMENT" -eq 1 ]]; then
    [[ "$CLAIMANT" == "$VIEWER" ]]
  else
    [[ " $ASSIGNEES " == *" $VIEWER "* ]]
  fi
}

describe_claim() {
  local who="${CLAIMANT:-an unknown account}"
  local when="${CLAIMED_AT:-an unrecorded time}"
  local facts=""
  [[ -n "$CLAIM_PROVIDER" ]] && facts+=", provider $CLAIM_PROVIDER"
  [[ -n "$CLAIM_DEVICE" ]] && facts+=", device $CLAIM_DEVICE"
  [[ -n "$CLAIM_LABEL_TEXT" ]] && facts+=", label $CLAIM_LABEL_TEXT"
  [[ -n "$CLAIM_BATCH" ]] && facts+=", batch $CLAIM_BATCH (one of $CLAIM_BATCH_SIZE)"
  printf 'issue #%s is already being worked — claimed by %s (holder %s%s) at %s' \
    "$ISSUE_NUMBER" "$who" "${CLAIMANT_HOLDER:-unknown}" "$facts" "$when"
}

# compute_claimant_evidence: for a claimed/stale verdict with a readable marker
# holder, report whether the claim is this account's, from this device, and
# from which local worktree's checkout-default holder (issue #2366). Evidence
# only: it never changes the verdict, the exit code or holder precedence, and a
# sibling worktree's default never counts as `mine`. The reported checkout
# holder is derived locally from that worktree's path with the same formula as
# the default holder; it is never copied from the marker.
compute_claimant_evidence() {
  [[ "$VERDICT" == claimed || "$VERDICT" == stale ]] || return 0
  [[ -n "$CLAIMANT_HOLDER" ]] || return 0
  # Without a viewer there is no account to compare against; report no evidence.
  (( NO_VIEWER )) && return 0
  if [[ "$CLAIMANT" == "$VIEWER" && "$MARKER_AUTHOR" == "$VIEWER" ]]; then
    EV_IS_VIEWER=true
  else
    EV_IS_VIEWER=false
  fi
  local dev
  dev="$(resolve_device 2>/dev/null)" || dev=""
  if [[ -n "$CLAIM_DEVICE" && "$CLAIM_DEVICE" == "$dev" ]]; then
    EV_DEVICE_LOCAL=true
  else
    EV_DEVICE_LOCAL=false
  fi
  [[ "$EV_IS_VIEWER" == true ]] || return 0
  local line path top legacy d
  while IFS= read -r line; do
    [[ "$line" == "worktree "* ]] || continue
    path="${line#worktree }"
    top="$(git -C "$path" rev-parse --show-toplevel 2>/dev/null)" || top="$path"
    legacy="$(legacy_holder "$top")"
    if [[ "$CLAIMANT_HOLDER" == "$legacy" ]]; then
      EV_CHECKOUT="$top"; EV_FORM=legacy; EV_CHECKOUT_HOLDER="$legacy"; return 0
    fi
    d="$(digest_hex "$legacy" 12 2>/dev/null)" || continue
    if [[ "$CLAIMANT_HOLDER" == "h-$d" ]]; then
      EV_CHECKOUT="$top"; EV_FORM=digest; EV_CHECKOUT_HOLDER="h-$d"; return 0
    fi
  done < <(git worktree list --porcelain 2>/dev/null)
  return 0
}

# --- action: --check -----------------------------------------------------------
if [[ "$ACTION" == "check" ]]; then
  compute_claimant_evidence
  case "$VERDICT" in
    unclaimed) emit unclaimed 0 "issue #$ISSUE_NUMBER is unclaimed — startable" ;;
    mine)      emit mine 0 "issue #$ISSUE_NUMBER is already claimed by this thread (holder $HOLDER) — startable" ;;
    stale)     emit stale 0 "$(describe_claim), which is older than the ${STALE_HOURS}h stale window — proceeding is allowed; surface this as a warning, not a block" ;;
    claimed)   emit claimed 1 "$(describe_claim). Skipping. Only an explicit per-issue instruction from the user (\"start it anyway\") authorizes starting it, per $GUARD_REF." ;;
  esac
fi

# --- action: --release ---------------------------------------------------------
if [[ "$ACTION" == "release" ]]; then
  if (( ! CLAIM_EXISTS )); then
    emit unclaimed 0 "issue #$ISSUE_NUMBER holds no claim — nothing to release"
  fi
  if (( EXPECT_CLAIM_ID_SET )); then
    if [[ ( "$EXPECTED_CLAIM_ID" == none && "$HAS_CLAIM_COMMENT" -ne 0 ) \
          || ( "$EXPECTED_CLAIM_ID" != none && "${W_ID:-}" != "$EXPECTED_CLAIM_ID" ) ]]; then
      emit "$VERDICT" 5 "claim identity changed on issue #$ISSUE_NUMBER — observed claim $EXPECTED_CLAIM_ID is no longer current; nothing released"
    fi
  fi
  if ! viewer_owns_claim; then
    # Never touch a collaborator's claim (issue #732). Not an error: releasing
    # what isn't yours was never the job.
    emit "$VERDICT" 0 "issue #$ISSUE_NUMBER is claimed by ${CLAIMANT:-another account}, not you ($VIEWER) — left untouched"
  fi

  RELEASE_ERRORS=0

  # ORDER MATTERS: comments first, label last.
  #
  # A release can fail part-way, and the two possible half-states are not
  # equally safe. The `in-progress` label is the cheap index every batch reader
  # uses to narrow a backlog before calling --check at all (`/wave` Step 2), so
  # a claim comment left WITHOUT the label is invisible to those readers and
  # reads as unclaimed. The reverse — label without comment — still shows up in
  # every batch scan and still blocks. Removing the label last makes the label a
  # superset of the claim at every intermediate point, so a partial failure
  # degrades toward over-blocking (which expires on its own) rather than toward
  # a missed claim (which does not).
  while IFS= read -r cid; do
    [[ -z "$cid" ]] && continue
    gh api -X DELETE "$REPO_PREFIX/issues/comments/$cid" >/dev/null 2>"$ERR_FILE" || RELEASE_ERRORS=1
  done < <(printf '%s' "$CLAIM_COMMENTS" | jq -r --arg v "$VIEWER" \
    '.[] | select((.user.login // "") == $v) | .id' 2>/dev/null || true)

  # A scoped cleanup deletes only the IDs captured above. If a later marker
  # appeared meanwhile, retain the index metadata for its owner.
  if (( EXPECT_CLAIM_ID_SET && ! RELEASE_ERRORS )); then
    REMAINING_CLAIMS=$(read_claim_comments) || fail_closed "could not verify scoped release on issue #$ISSUE_NUMBER; metadata retained"
    if ! printf '%s' "$REMAINING_CLAIMS" | jq -e 'length == 0' >/dev/null 2>&1; then
      emit unknown 5 "claim markers remain after scoped release on issue #$ISSUE_NUMBER; metadata retained"
    fi
  fi

  # Ordering alone is not enough — the label must also be WITHHELD when a comment
  # delete failed. Dropping it anyway would produce exactly the comment-without-
  # label state the ordering exists to prevent, just one step later.
  if (( ! RELEASE_ERRORS )); then
    EDIT_ARGS=()
    [[ "$HAS_LABEL" == "true" ]] && EDIT_ARGS+=(--remove-label "$CLAIM_LABEL")
    [[ " $ASSIGNEES " == *" $VIEWER "* ]] && EDIT_ARGS+=(--remove-assignee "$VIEWER")
    if (( ${#EDIT_ARGS[@]} > 0 )); then
      gh issue edit "$ISSUE_NUMBER" "${EDIT_ARGS[@]}" >/dev/null 2>"$ERR_FILE" || RELEASE_ERRORS=1
    fi
  fi

  if (( RELEASE_ERRORS )); then
    fail_closed "release of issue #$ISSUE_NUMBER partially failed ($(tr '\n' ' ' < "$ERR_FILE"))"
  fi
  CLAIMANT=""; CLAIMANT_HOLDER=""; CLAIMED_AT=""; CLAIMED_SINCE=""; IS_STALE="false"
  CLAIM_PROVIDER=""; CLAIM_DEVICE=""; CLAIM_LABEL_TEXT=""; CLAIM_BATCH=""; CLAIM_BATCH_SIZE=""
  emit unclaimed 0 "released the claim on issue #$ISSUE_NUMBER"
fi

# --- shared write helpers ------------------------------------------------------
# Create the label idempotently. An existing label is reused, never recreated —
# `gh label create` on an existing name is an error, not a no-op.
# `gh --jq` takes a bare expression — it has no `--arg` passthrough — so the
# label name is matched by jq reading it from the environment instead.
ensure_label() {
  local exists
  exists="$(CLAIM_LABEL="$CLAIM_LABEL" gh label list --limit 200 --json name \
    --jq '[.[].name] | index(env.CLAIM_LABEL) != null' 2>/dev/null || echo "")"
  if [[ "$exists" != "true" ]]; then
    gh label create "$CLAIM_LABEL" \
      --color FBCA04 \
      --description "A thread is actively working this issue (issue-claim.sh)" \
      >/dev/null 2>&1 || true
  fi
}

# claim_body <payload-json> <provider> <device> [label] [batch] [batch-size] ->
# the visible claim comment, marker included. The sentence names who holds the
# claim (#2284) and, for a batch claim, that it is one of N taken together
# (#2286). It stays ONE line: the marker classifier accepts only that shape.
claim_body() {
  printf '%s\n\n%s\n' \
    "🔒 Claimed by \`$VIEWER\` for active work. Held by $2 on device $3${4:+ (run: $4)}.${5:+ One of ${6:-several} claimed together (batch $5).} It will be released when this issue's PR merges or when the issue closes; it becomes stale if not renewed within ${STALE_HOURS}h." \
    "<!-- $CLAIM_MARKER: $1 -->"
}

# --- renewal (issue #1914) -----------------------------------------------------
renew_due() {
  [[ -n "$AGE_SECONDS" ]] && (( AGE_SECONDS > RENEW_MINUTES * 60 ))
}

# Issue-snapshot predicates (take the issue JSON as $1).
issue_is_closed()  { [[ "$(printf '%s' "$1" | jq -r '.state // ""' 2>/dev/null)" == "closed" ]]; }
issue_has_label()  { [[ "$(printf '%s' "$1" | jq -r --arg l "$CLAIM_LABEL" '[.labels[]?.name] | index($l) != null' 2>/dev/null)" == "true" ]]; }
issue_has_viewer() { [[ "$(printf '%s' "$1" | jq -r --arg v "$VIEWER" '[.assignees[]?.login] | index($v) != null' 2>/dev/null)" == "true" ]]; }

# repair_claim_metadata (issue #1933): a not-due, authorized, same-holder call
# on an open issue re-adds a missing label and/or viewer assignee. The marker is
# the claim; the label is the index batch readers (/wave) filter on, so a fresh
# marker without it reads as unclaimed to them. Reaches that state: a failed
# label re-assert after a renewal POST (exit 4), or a release that removed the
# label after a renewal's final re-read. Best effort — a failed repair warns and
# leaves the verdict alone; the next call tries again.
#
# Why this cannot resurrect a release in flight: the issue is read before the
# comments, and --release deletes markers before it removes the label. So
# "label gone, marker present" here means the label went first — never the
# middle of a release of this marker.
repair_claim_metadata() {
  local args=()
  [[ "$HAS_LABEL" != "true" ]] && args+=(--add-label "$CLAIM_LABEL")
  [[ " $ASSIGNEES " != *" $VIEWER "* ]] && args+=(--add-assignee "@me")
  (( ${#args[@]} == 0 )) && return 0
  # The caller's open check used the startup snapshot; an issue closed since
  # then must not be re-labelled. Re-read right before the edit, and once
  # more after it to roll back a close that landed in between (narrows the
  # window; no compare-and-set exists on GitHub).
  local fresh=""
  if ! fresh="$(gh api "$REPO_PREFIX/issues/$ISSUE_NUMBER" 2>/dev/null)" || issue_is_closed "$fresh"; then
    return 0
  fi
  [[ "$HAS_LABEL" != "true" ]] && ensure_label
  if gh issue edit "$ISSUE_NUMBER" "${args[@]}" >/dev/null 2>"$ERR_FILE"; then
    REPAIR_NOTE="; re-asserted the missing label/assignee"
    if fresh="$(gh api "$REPO_PREFIX/issues/$ISSUE_NUMBER" 2>/dev/null)" && issue_is_closed "$fresh"; then
      local undo=()
      [[ "$HAS_LABEL" != "true" ]] && undo+=(--remove-label "$CLAIM_LABEL")
      [[ " $ASSIGNEES " != *" $VIEWER "* ]] && undo+=(--remove-assignee "$VIEWER")
      if gh issue edit "$ISSUE_NUMBER" "${undo[@]}" >/dev/null 2>&1; then
        REPAIR_NOTE="; the issue closed during the label/assignee repair, which was rolled back"
      else
        REPAIR_NOTE="; the issue closed during the label/assignee repair and rolling it back failed — clear it with: issue-claim.sh $ISSUE_NUMBER --release"
      fi
    fi
  else
    echo "issue-claim.sh: warning — issue #$ISSUE_NUMBER carries this holder's marker but lacks the in-progress label or assignee, and re-adding them failed ($(tr '\n' ' ' < "$ERR_FILE")); label-filtering readers (/wave) may not see the claim until the next --renew or --claim repairs it" >&2
  fi
}
REPAIR_NOTE=""

# withdraw_markers <ids-newline> <context>: best-effort delete of this run's
# own markers. Each id must come from this run (the POST or its nonce).
withdraw_markers() {
  local rid
  while IFS= read -r rid; do
    [[ -z "$rid" ]] && continue
    gh api -X DELETE "$REPO_PREFIX/issues/comments/$rid" >/dev/null 2>&1 \
      || echo "issue-claim.sh: warning — could not withdraw this run's renewal marker $rid on issue #$ISSUE_NUMBER $2; clear it with: issue-claim.sh $ISSUE_NUMBER --release" >&2
  done <<<"$1"
}

# emit_renew_released <label-note>: exit 5 `released`, reporting the parsed
# winner (W_*) as the current claimant when it is not this holder's.
emit_renew_released() {
  local v="unclaimed"
  CLAIM_PROVIDER="$W_PROVIDER"; CLAIM_DEVICE="$W_DEVICE"; CLAIM_LABEL_TEXT="$W_LABEL"
  CLAIM_BATCH="$W_BATCH"; CLAIM_BATCH_SIZE="$W_BATCH_SIZE"
  if [[ -n "$W_ID" ]] && ! { holder_is_mine "$W_HOLDER" && [[ "$W_AUTHOR" == "$VIEWER" ]]; }; then
    v="claimed"; CLAIMANT="$W_LOGIN"; CLAIMANT_HOLDER="$W_HOLDER"; CLAIMED_AT="$W_AT"; CLAIMED_SINCE="$W_AT"
  else
    CLAIMANT=""; CLAIMANT_HOLDER=""; CLAIMED_AT=""; CLAIMED_SINCE=""
    CLAIM_PROVIDER=""; CLAIM_DEVICE=""; CLAIM_LABEL_TEXT=""; CLAIM_BATCH=""; CLAIM_BATCH_SIZE=""
  fi
  IS_STALE="false"
  emit "$v" 5 "released — the claim on issue #$ISSUE_NUMBER was released (or the issue closed) while this renewal was in flight; this run's marker was withdrawn and $1 — ownership is lost, stop and report"
}

# emit_renew_superseded: exit 5 `superseded`, reporting the parsed foreign
# winner (W_*). The caller has already withdrawn this run's own markers.
emit_renew_superseded() {
  CLAIMANT="$W_LOGIN"; CLAIMANT_HOLDER="$W_HOLDER"; CLAIMED_AT="$W_AT"
  CLAIMED_SINCE="$W_AT"; MARKER_ID="$W_ID"; MARKER_AUTHOR="$W_AUTHOR"
  CLAIM_PROVIDER="$W_PROVIDER"; CLAIM_DEVICE="$W_DEVICE"; CLAIM_LABEL_TEXT="$W_LABEL"
  CLAIM_BATCH="$W_BATCH"; CLAIM_BATCH_SIZE="$W_BATCH_SIZE"
  # A renewed winner carries its original pickup time as `since`.
  if [[ -n "$W_SINCE" && -n "$(iso_to_epoch "$W_SINCE")" ]]; then
    CLAIMED_SINCE="$W_SINCE"
  fi
  local v="claimed" w_epoch
  w_epoch="$(iso_to_epoch "$W_AT")"
  if [[ -n "$w_epoch" ]] && (( $(date -u +%s) - w_epoch > STALE_HOURS * 3600 )); then
    v="stale"; IS_STALE="true"
  else
    IS_STALE="false"
  fi
  emit "$v" 5 "superseded — a newer claim by ${W_LOGIN:-an unknown account} (holder ${W_HOLDER:-unknown}) won issue #$ISSUE_NUMBER while this renewal was in flight; ownership is lost — stop and report"
}

# The holder token alone is not proof of ownership: another account could pass
# the same string. Renewal additionally needs the marker's payload login and
# its comment author to be the viewer — the account whose own comments the
# cleanup step is allowed to delete.
renew_authorized() {
  [[ "$CLAIMANT" == "$VIEWER" && "$MARKER_AUTHOR" == "$VIEWER" ]]
}

# winner_is_ours: the parsed winner (W_*) is a viewer-authored marker for this
# holder other than the one being replaced.
winner_is_ours() {
  [[ -n "$W_ID" && "$W_ID" != "$1" ]] && holder_is_mine "$W_HOLDER" \
    && [[ "$W_AUTHOR" == "$VIEWER" && "$W_LOGIN" == "$VIEWER" ]]
}

# own_run_markers <claim-comments-json> -> ids (one per line) of the
# viewer-authored markers carrying this run's nonce (payload `run`). The nonce
# is the only proof a marker is this run's own: a sibling same-holder renewal's
# marker is otherwise indistinguishable, so nothing is ever reconciled or
# withdrawn by holder or by id order.
own_run_markers() {
  printf '%s' "$1" | jq -r --arg v "$VIEWER" --arg r "$RUN_NONCE" '
    .[] | select((.user.login // "") == $v and ._claim_payload.run == $r)
    | .id' 2>/dev/null || true
}

# do_renew: create a new marker, verify it wins, then delete this holder's older
# viewer-authored markers. Always exits via emit. The order is what keeps the
# claim continuously held: the label and the old marker stay in place until the
# new marker is verified, and a failure at any step leaves at least one live
# marker of ours behind (over-blocking, which expires) rather than none.
do_renew() {
  local old_id="$MARKER_ID" old_at="$CLAIMED_AT" since="$CLAIMED_SINCE"
  local was_stale=0 new_id="" post_out="" post_err="" verify="" payload issue_now="" post_id=""
  is_stale && was_stale=1

  # A closed issue is terminal: its claim is being (or was) released, so a
  # renewal must not resurrect it.
  if [[ "$(printf '%s' "$ISSUE_JSON" | jq -r '.state // ""' 2>/dev/null)" == "closed" ]]; then
    emit "$VERDICT" 5 "not-held — issue #$ISSUE_NUMBER is closed; its claim is not renewed — nothing written"
  fi

  # Per-run nonce: identifies this run's own marker on re-read (own_run_markers).
  RUN_NONCE="$(date -u +%s)-$$-$RANDOM$RANDOM"
  # Carry the old marker's who-holds-it facts forward; fill missing ones (an
  # older marker) from this run's resolved values.
  local r_provider="${CLAIM_PROVIDER:-$RES_PROVIDER}" r_device="${CLAIM_DEVICE:-$RES_DEVICE}" r_label="${CLAIM_LABEL_TEXT:-$RES_LABEL}"
  # Batch membership is carried forward too; an older marker without it takes
  # the values this run was given (if any).
  local r_batch="${CLAIM_BATCH:-$RES_BATCH}" r_batch_size="${CLAIM_BATCH_SIZE:-$RES_BATCH_SIZE}"
  payload="$(jq -cn --arg h "$HOLDER" --arg l "$VIEWER" --arg s "$since" --arg r "$RUN_NONCE" \
    --arg p "$r_provider" --arg d "$r_device" --arg lb "$r_label" \
    --arg bt "$r_batch" --arg bn "$r_batch_size" \
    '{holder: $h, login: $l, since: $s, run: $r, provider: $p, device: $d, label: (if $lb == "" then null else $lb end)}
     | if $bt == "" or $bn == "" then . else . + {batch: $bt, batch_size: ($bn | tonumber)} end')"
  # `gh api` POST (not `gh issue comment`) so the response carries the new
  # comment's id — the identity verification compares.
  if post_out="$(gh api -X POST "$REPO_PREFIX/issues/$ISSUE_NUMBER/comments" \
       -f "body=$(claim_body "$payload" "$r_provider" "$r_device" "$r_label" "$r_batch" "$r_batch_size")" 2>"$ERR_FILE")"; then
    new_id="$(printf '%s' "$post_out" | jq -r '.id // empty' 2>/dev/null || true)"
    post_id="$new_id"
  else
    post_err="$(tr '\n' ' ' < "$ERR_FILE")"
  fi

  # Verification re-read. A failed POST may still have landed (a timeout after
  # the write), so it is re-read too and reconciled rather than assumed lost.
  if ! verify="$(read_claim_comments)"; then
    if [[ -z "$new_id" ]]; then
      fail_closed "renew-failed — could not post the renewal marker on issue #$ISSUE_NUMBER (${post_err:-no comment id returned}) and could not re-read to reconcile; the existing marker was left in place"
    fi
    fail_closed "renew-unverified — posted renewal marker $new_id on issue #$ISSUE_NUMBER but could not re-read to verify it; no older marker was deleted"
  fi
  parse_winner "$verify" || fail_closed "renew-unverified — newest claim marker on issue #$ISSUE_NUMBER is unreadable after posting; no marker was deleted"

  if [[ -z "$new_id" ]]; then
    # The POST reported failure but may have landed. Reconcile ONLY by this
    # run's nonce — never by holder or id order, which cannot tell this run's
    # marker from a sibling renewal's. Not found: nothing of ours landed.
    new_id="$(own_run_markers "$verify" | tail -n 1)"
    if [[ -z "$new_id" ]]; then
      fail_closed "renew-failed — could not post the renewal marker on issue #$ISSUE_NUMBER (${post_err:-no comment id returned}) and no marker of this run is on the re-read; nothing was deleted — retry"
    fi
  fi
  post_id="$new_id"

  # Concurrent release (e.g. /wrap after merge): it deletes the replaced marker
  # and then the label. If the replaced marker is gone or the issue closed, the
  # claim was released under us — withdraw this run's marker(s), leave the
  # label alone, and report lost ownership rather than resurrect the claim.
  if ! issue_now="$(gh api "$REPO_PREFIX/issues/$ISSUE_NUMBER" 2>"$ERR_FILE")"; then
    fail_closed "renew-unverified — posted the renewal marker${new_id:+ $new_id} on issue #$ISSUE_NUMBER but could not re-read the issue to confirm it is still open ($(tr '\n' ' ' < "$ERR_FILE")); no older marker was deleted"
  fi
  local issue_closed=0 old_gone=0 concurrent_own=0
  [[ "$(printf '%s' "$issue_now" | jq -r '.state // ""' 2>/dev/null)" == "closed" ]] && issue_closed=1
  [[ "$(printf '%s' "$verify" | jq -r --arg old "$old_id" \
        'any(.[]; (.id | tostring) == $old)' 2>/dev/null)" == "false" ]] && old_gone=1
  # A missing replaced marker is NOT a release when another renewal of this
  # same holder (a heartbeat --renew racing a resume --claim) already won: the
  # winner is a newer viewer-authored marker of ours that this run did not post,
  # and the label that renewal re-asserted is still present. Withdrawing then
  # would delete the sibling's live marker and leave the issue unclaimed.
  # post_id is the id this run created (from the POST, or reconciled by this
  # run's nonce from an errored-but-landed POST), so it never names a sibling's.
  if (( old_gone && ! issue_closed )) && winner_is_ours "$old_id" \
     && [[ -n "$post_id" && "$W_ID" != "$post_id" ]] \
     && [[ "$(printf '%s' "$issue_now" | jq -r --arg l "$CLAIM_LABEL" \
           '[.labels[]?.name] | index($l) != null' 2>/dev/null)" == "true" ]]; then
    concurrent_own=1
  fi
  if (( issue_closed || (old_gone && ! concurrent_own) )); then
    withdraw_markers "$({ printf '%s\n' "$new_id"; own_run_markers "$verify"; } | sort -u)" "after a concurrent release"
    emit_renew_released "the label left as found"
  fi

  if [[ -n "$new_id" ]] && { [[ "$W_ID" == "$new_id" ]] || winner_is_ours "$old_id"; }; then
    # Re-assert the label/assignee only now, once the claim is confirmed still
    # held — doing it before the POST would re-add a label a concurrent release
    # had just removed.
    ensure_label
    if ! gh issue edit "$ISSUE_NUMBER" \
         --add-label "$CLAIM_LABEL" --add-assignee "@me" >/dev/null 2>"$ERR_FILE"; then
      fail_closed "renew-failed — could not re-assert the label/assignee on issue #$ISSUE_NUMBER ($(tr '\n' ' ' < "$ERR_FILE")); the renewal marker was left in place and the next --renew or --claim re-adds the label"
    fi
    # Verified: a marker of ours, newer than the one replaced, wins. Clean up
    # every OTHER viewer-authored marker for this holder — never a different
    # holder's, never a collaborator's.
    new_id="$W_ID"
    local cleanup_failed=0 cid
    while IFS= read -r cid; do
      [[ -z "$cid" ]] && continue
      gh api -X DELETE "$REPO_PREFIX/issues/comments/$cid" >/dev/null 2>&1 || cleanup_failed=1
    done < <(printf '%s' "$verify" | jq -r --arg v "$VIEWER" --arg h "$HOLDER" --arg hl "$HOLDER_LEGACY" \
      --arg keep "$new_id" '
      .[] | select((.user.login // "") == $v and ((.id | tostring) != $keep))
      | select(._claim_payload.holder == $h or ($hl != "" and ._claim_payload.holder == $hl))
      | .id' 2>/dev/null || true)
    (( cleanup_failed )) && echo "issue-claim.sh: warning — renewed issue #$ISSUE_NUMBER but could not delete an older marker of this holder; the duplicate is inert (the newest marker wins) and the next renewal or release removes it" >&2

    # Final consistency re-read (issue #1933). The verification snapshot can be
    # stale by now: a --release that ran after it deleted the markers and the
    # label, and the re-assert above would have put a label back on a released
    # claim. Re-read once and judge on the fresh state. The replaced marker is
    # deliberately not consulted here — cleanup just deleted it. This narrows
    # the window; it cannot close it (no compare-and-set on GitHub), and a
    # failed re-read keeps the already-verified renewal.
    local final="" final_issue="" final_ok=1 kept_id="$new_id"
    if ! final="$(read_claim_comments)"; then
      final_ok=0
    elif ! final_issue="$(gh api "$REPO_PREFIX/issues/$ISSUE_NUMBER" 2>"$ERR_FILE")"; then
      final_ok=0
    fi
    if (( ! final_ok )); then
      echo "issue-claim.sh: warning — renewed issue #$ISSUE_NUMBER but the final consistency re-read failed; the renewal was already verified, so it stands" >&2
    else
      parse_winner "$final" || fail_closed "renew-unverified — newest claim marker on issue #$ISSUE_NUMBER is unreadable on the final re-read; no further marker or metadata cleanup attempted"
      local f_closed=0 f_ours=0 kept_present=0
      issue_is_closed "$final_issue" && f_closed=1
      [[ -n "$W_ID" && "$W_AUTHOR" == "$VIEWER" && "$W_LOGIN" == "$VIEWER" ]] \
        && holder_is_mine "$W_HOLDER" && f_ours=1
      [[ "$(printf '%s' "$final" | jq -r --arg k "$kept_id" \
            'any(.[]; (.id | tostring) == $k)' 2>/dev/null)" == "true" ]] && kept_present=1
      if (( ! f_closed && f_ours )); then
        # Still held (this run's marker, or a sibling renewal of this holder).
        # The label follows the marker: put back whatever a racing release
        # removed after the re-assert above.
        local fix=()
        issue_has_label "$final_issue" || fix+=(--add-label "$CLAIM_LABEL")
        issue_has_viewer "$final_issue" || fix+=(--add-assignee "@me")
        if (( ${#fix[@]} > 0 )); then
          if ! gh issue edit "$ISSUE_NUMBER" "${fix[@]}" >/dev/null 2>"$ERR_FILE"; then
            fail_closed "renew-failed — the label/assignee on issue #$ISSUE_NUMBER was removed after this renewal re-asserted it, and re-adding it failed ($(tr '\n' ' ' < "$ERR_FILE")); the renewal marker was left in place and the next --renew or --claim re-adds the label"
          fi
        fi
        new_id="$W_ID"
      else
        local mine_ids
        mine_ids="$(own_run_markers "$final")"
        withdraw_markers "$mine_ids" "after a concurrent release"
        if (( ! f_closed && kept_present )); then
          # This run's marker is still there but a newer foreign one wins.
          emit_renew_superseded
        fi
        # Released under us (or closed). Roll back only what this run added —
        # the label/assignee absent before the re-assert — and only when no
        # marker at all is left, so a newer claim's label is never stripped.
        local rest
        rest="$(printf '%s' "$final" | jq -c --arg ids "$mine_ids" \
          '($ids | split("\n")) as $w | [ .[] | select(((.id | tostring) as $i | $w | index($i)) | not) ]' 2>/dev/null || printf '')"
        parse_winner "$rest" || fail_closed "renew-unverified — remaining claim markers on issue #$ISSUE_NUMBER could not be interpreted; label and assignee retained"
        local note="the label left as found"
        local undo=()
        if [[ -n "$rest" && -z "$W_ID" ]]; then
          issue_has_label "$issue_now" || { issue_has_label "$final_issue" && undo+=(--remove-label "$CLAIM_LABEL"); }
          issue_has_viewer "$issue_now" || { issue_has_viewer "$final_issue" && undo+=(--remove-assignee "$VIEWER"); }
        fi
        if (( ${#undo[@]} > 0 )); then
          if gh issue edit "$ISSUE_NUMBER" "${undo[@]}" >/dev/null 2>"$ERR_FILE"; then
            note="the label/assignee this run re-added were rolled back"
          else
            note="the label/assignee this run re-added could NOT be rolled back — clear them with: issue-claim.sh $ISSUE_NUMBER --release"
          fi
        fi
        emit_renew_released "$note"
      fi
    fi

    MARKER_ID="$new_id"; MARKER_AUTHOR="$VIEWER"
    CLAIMANT="$VIEWER"; CLAIMANT_HOLDER="$HOLDER"
    # Report the winning marker's facts (W_* is the verified winner, which may
    # be a sibling renewal's marker); empty fields stay empty and emit as null.
    CLAIM_PROVIDER="$W_PROVIDER"; CLAIM_DEVICE="$W_DEVICE"; CLAIM_LABEL_TEXT="$W_LABEL"
    CLAIM_BATCH="$W_BATCH"; CLAIM_BATCH_SIZE="$W_BATCH_SIZE"
    PREVIOUS_CLAIMED_AT="$old_at"; CLAIMED_AT="$W_AT"; CLAIMED_SINCE="$since"
    IS_STALE="false"; RENEWED="true"
    if (( was_stale )); then
      echo "issue-claim.sh: warning — the claim on issue #$ISSUE_NUMBER had already aged past the ${STALE_HOURS}h stale window before this renewal; another holder could have taken it over in that gap" >&2
      emit mine 0 "renewed-after-expiry — renewed the expired claim on issue #$ISSUE_NUMBER for holder $HOLDER (previous marker $old_at)"
    fi
    emit mine 0 "renewed — renewed the claim on issue #$ISSUE_NUMBER for holder $HOLDER (previous marker $old_at)"
  fi

  if [[ -n "$W_ID" && "$W_ID" != "$old_id" && "$W_ID" != "$new_id" ]]; then
    # A newer marker that is not ours won the race. Remove our own new marker
    # (best effort) so it can never resurface as the winner later, and report
    # the winner. Nothing of the winner's is touched.
    # new_id is this run's marker (from the POST or reconciled by nonce).
    withdraw_markers "$({ printf '%s\n' "$new_id"; own_run_markers "$verify"; } | sort -u)" "after it was superseded"
    emit_renew_superseded
  fi

  fail_closed "renew-unverified — the renewal marker${new_id:+ $new_id} on issue #$ISSUE_NUMBER was not found on re-read; no older marker was deleted"
}

# --- action: --renew -----------------------------------------------------------
# Renew-only: a heartbeat caller must never acquire or take over an issue, so
# anything but this holder's own claim exits 5 with nothing written.
if [[ "$ACTION" == "renew" ]]; then
  if [[ "$VERDICT" != "mine" ]]; then
    emit "$VERDICT" 5 "not-held — issue #$ISSUE_NUMBER is not claimed by this thread (holder $HOLDER; verdict $VERDICT); --renew never acquires or takes over a claim — nothing written"
  fi
  if ! renew_authorized; then
    emit claimed 5 "renew-not-authorized — the claim marker on issue #$ISSUE_NUMBER carries holder $HOLDER but was written by ${MARKER_AUTHOR:-an unknown account} for ${CLAIMANT:-an unknown account}, not $VIEWER — nothing written"
  fi
  # A closed issue is terminal whether or not renewal is due (issue #1933): a
  # heartbeat on a closed issue must hear "stop", not `mine`/0. Same output as
  # do_renew's own closed check.
  if issue_is_closed "$ISSUE_JSON"; then
    emit "$VERDICT" 5 "not-held — issue #$ISSUE_NUMBER is closed; its claim is not renewed — nothing written"
  fi
  if ! renew_due; then
    repair_claim_metadata
    emit mine 0 "issue #$ISSUE_NUMBER is claimed by this thread (holder $HOLDER); renewal not due (threshold ${RENEW_MINUTES}m) — no-op$REPAIR_NOTE"
  fi
  do_renew
fi

# --- action: --claim -----------------------------------------------------------
# Already ours: a genuine no-op. A resumed thread or a post-compaction recovery
# re-claims constantly; writing a second marker each time would turn recovery
# into comment spam and break the "one live claim" read.
#
# Renewal (issue #1914): once the marker is older than the renewal threshold, a
# same-holder --claim renews it instead, so a resumed long-running thread keeps
# its claim fresh. Inside the threshold it stays the old silent no-op.
if [[ "$VERDICT" == "mine" ]]; then
  if renew_due; then
    if renew_authorized; then
      do_renew
    fi
    echo "issue-claim.sh: warning — renew-not-authorized: the claim marker on issue #$ISSUE_NUMBER carries holder $HOLDER but was written by ${MARKER_AUTHOR:-an unknown account} for ${CLAIMANT:-an unknown account}, not $VIEWER; it was not renewed" >&2
  elif renew_authorized && ! issue_is_closed "$ISSUE_JSON"; then
    # Not due: the same label/assignee repair --renew does (issue #1933). A
    # closed issue keeps the old silent no-op — never re-label a closed issue.
    repair_claim_metadata
  fi
  emit mine 0 "issue #$ISSUE_NUMBER is already claimed by this thread (holder $HOLDER) — no-op$REPAIR_NOTE"
fi

if [[ "$VERDICT" == "claimed" ]]; then
  if (( ! ALLOW_CLAIMED )); then
    emit claimed 1 "$(describe_claim). Refusing to claim it. Only an explicit per-issue instruction from the user (\"start it anyway\") authorizes taking it, per $GUARD_REF."
  fi
  OVERRIDDEN="true"
fi

PRIOR_HOLDER="$CLAIMANT_HOLDER"
PRIOR_CLAIMANT="$CLAIMANT"

ensure_label

if ! gh issue edit "$ISSUE_NUMBER" \
     --add-label "$CLAIM_LABEL" --add-assignee "@me" >/dev/null 2>"$ERR_FILE"; then
  fail_closed "could not write the claim on issue #$ISSUE_NUMBER ($(tr '\n' ' ' < "$ERR_FILE"))"
fi

# Stale takeover / override: drop our OWN stale markers so exactly one live
# claim comment of ours remains and staleness is measured from the new claim.
#
# A collaborator's claim comment is deliberately left in place even here (#732):
# deleting another person's comment is a write to their content, and an
# --allow-claimed override authorizes starting the work, not editing someone
# else's writing. Leaving it is safe — every read takes the newest claim
# comment, which is the one written just below.
if (( HAS_CLAIM_COMMENT )); then
  while IFS= read -r cid; do
    [[ -z "$cid" ]] && continue
    gh api -X DELETE "$REPO_PREFIX/issues/comments/$cid" >/dev/null 2>&1 || true
  done < <(printf '%s' "$CLAIM_COMMENTS" | jq -r --arg v "$VIEWER" \
    '.[] | select((.user.login // "") == $v) | .id' 2>/dev/null || true)
fi

CLAIM_BODY="$(claim_body "$(jq -cn --arg h "$HOLDER" --arg l "$VIEWER" --arg p "$RES_PROVIDER" --arg d "$RES_DEVICE" --arg lb "$RES_LABEL" \
  --arg bt "$RES_BATCH" --arg bn "$RES_BATCH_SIZE" \
  '{holder: $h, login: $l, provider: $p, device: $d, label: (if $lb == "" then null else $lb end)}
   | if $bt == "" then . else . + {batch: $bt, batch_size: ($bn | tonumber)} end')" "$RES_PROVIDER" "$RES_DEVICE" "$RES_LABEL" "$RES_BATCH" "$RES_BATCH_SIZE")"

if ! gh issue comment "$ISSUE_NUMBER" --body "$CLAIM_BODY" >/dev/null 2>"$ERR_FILE"; then
  # ROLL BACK the label + assignee this run added. A half-written claim (marker
  # present, holder absent) is worse than no claim: `mine` requires a parsed
  # claim comment, so the very thread that wrote the label reads its own claim
  # back as a foreign `claimed` and cannot re-claim without --allow-claimed —
  # while every other thread stays blocked too. Leave the issue as we found it.
  COMMENT_ERR="$(tr '\n' ' ' < "$ERR_FILE")"
  ROLLBACK_ARGS=()
  [[ "$HAS_LABEL" != "true" ]] && ROLLBACK_ARGS+=(--remove-label "$CLAIM_LABEL")
  [[ " $ASSIGNEES " != *" $VIEWER "* ]] && ROLLBACK_ARGS+=(--remove-assignee "$VIEWER")
  if (( ${#ROLLBACK_ARGS[@]} == 0 )); then
    fail_closed "could not post the claim comment on issue #$ISSUE_NUMBER ($COMMENT_ERR); this run added no marker of its own, so nothing was left behind"
  fi
  if gh issue edit "$ISSUE_NUMBER" "${ROLLBACK_ARGS[@]}" >/dev/null 2>&1; then
    fail_closed "could not post the claim comment on issue #$ISSUE_NUMBER ($COMMENT_ERR); the label/assignee this run added were rolled back, so the issue is unclaimed — retry"
  fi
  fail_closed "could not post the claim comment on issue #$ISSUE_NUMBER ($COMMENT_ERR) AND could not roll the label/assignee back; the issue carries a holderless marker that expires in ${STALE_HOURS}h — clear it with: issue-claim.sh $ISSUE_NUMBER --release"
fi

CLAIMANT="$VIEWER"
CLAIMANT_HOLDER="$HOLDER"
CLAIM_PROVIDER="$RES_PROVIDER"; CLAIM_DEVICE="$RES_DEVICE"; CLAIM_LABEL_TEXT="$RES_LABEL"
CLAIM_BATCH="$RES_BATCH"; CLAIM_BATCH_SIZE="$RES_BATCH_SIZE"
CLAIMED_AT="$(date -u +%FT%TZ)"
# Prefer the marker's GitHub created_at — the timestamp every later --check
# reads — over the local clock. Best effort: a failed re-read keeps the clock.
if POSTED_COMMENTS="$(read_claim_comments)"; then
  parse_winner "$POSTED_COMMENTS" || fail_closed "claim-unverified — newest claim marker on issue #$ISSUE_NUMBER is unreadable after posting; marker and metadata retained"
  if [[ "$W_AUTHOR" == "$VIEWER" && "$W_HOLDER" == "$HOLDER" && -n "$(iso_to_epoch "$W_AT")" ]]; then
    CLAIMED_AT="$W_AT"
    # The re-read may have selected a newer marker of this same holder (a
    # concurrent run with different facts); report the winner's facts.
    CLAIM_PROVIDER="$W_PROVIDER"; CLAIM_DEVICE="$W_DEVICE"; CLAIM_LABEL_TEXT="$W_LABEL"
    CLAIM_BATCH="$W_BATCH"; CLAIM_BATCH_SIZE="$W_BATCH_SIZE"
  fi
fi
CLAIMED_SINCE="$CLAIMED_AT"
IS_STALE="false"

if [[ "$OVERRIDDEN" == "true" ]]; then
  emit mine 0 "claimed issue #$ISSUE_NUMBER for holder $HOLDER, overriding a live claim held by ${PRIOR_CLAIMANT:-another account} (holder ${PRIOR_HOLDER:-unknown})"
elif [[ "$VERDICT" == "stale" ]]; then
  emit mine 0 "took over the stale claim on issue #$ISSUE_NUMBER (previously ${PRIOR_CLAIMANT:-an unknown account}, holder ${PRIOR_HOLDER:-unknown}) for holder $HOLDER"
fi
emit mine 0 "claimed issue #$ISSUE_NUMBER for holder $HOLDER"
REPO_BOOTSTRAP_FILE_EOF
      ;;
    ".claude/scripts/pr-claim-line.sh")
      cat <<'REPO_BOOTSTRAP_FILE_EOF'
#!/usr/bin/env bash
# pr-claim-line.sh — Print the hidden claim-holder line a PR body carries (issue #2288).
# catalog: pr-state-polling — Print the hidden `claim-holder` line that ties a PR body to the issue claim it was built under (pr-claim-check.sh compares it)
#
# PURPOSE
#   pr-claim-check.sh (the PR-side gate) compares the holder of each linked
#   issue's winning claim with the holder a PR body names. This script prints
#   that one line so every PR-creation path writes the same shape:
#
#       <!-- claim-holder: h-<12 lowercase hex> -->
#
#   The value is NOT the raw holder token. Older tokens embed a hostname and a
#   checkout path, and a PR body is public. The value is the first 12 hex
#   characters of the SHA-256 of the raw holder string, prefixed `h-`. A raw
#   holder already shaped `h-<12 hex>` (the issue #2284 default) passes through
#   unchanged, so both forms agree with issue-claim.sh.
#
# HOLDER SOURCE ORDER
#   --holder TOKEN  ->  $CLAUDE_CLAIM_HOLDER  ->  the session-state record
#   .repos["<repo key>"].pipelines["<ISSUE>"].claim_holder (null, empty or
#   "_unknown" means absent)  ->  $CLAUDE_SESSION_ID  ->  the default holder
#   issue-claim.sh computes
#   (h-<digest of hostname:git toplevel>, the same formula as issue-claim.sh's
#   resolve_holder).
#
# FAIL-CLOSED
#   No SHA-256 tool (shasum or sha256sum) -> exit 1 with a message. A weak hash
#   is never substituted: a collision would let one checkout read as another.
#
# USAGE
#   pr-claim-line.sh <ISSUE> [--holder TOKEN]
#   pr-claim-line.sh --help | -h
#
# EXIT STATUS
#   0  line printed          1  no SHA-256 tool / holder unresolvable
#   2  usage error
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  cat <<'USAGE'
Usage: pr-claim-line.sh <ISSUE> [--holder TOKEN]
       pr-claim-line.sh --help | -h

Prints one line for a PR body:
  <!-- claim-holder: h-<12 hex> -->

--holder TOKEN   Raw holder token to hash (overrides the environment and the
                 session-state record). Passed through unhashed only when it is
                 already shaped h-<12 lowercase hex>.
USAGE
}

usage_err() {
  echo "pr-claim-line.sh: $1" >&2
  usage >&2
  exit 2
}

ISSUE=""
HOLDER_ARG=""
HOLDER_GIVEN=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --holder)
      [[ $# -ge 2 ]] || usage_err "--holder needs a value"
      HOLDER_ARG="$2"; HOLDER_GIVEN=1; shift 2 ;;
    --holder=*) HOLDER_ARG="${1#--holder=}"; HOLDER_GIVEN=1; shift ;;
    -*) usage_err "unknown flag: $1" ;;
    *)
      [[ -z "$ISSUE" ]] || usage_err "unexpected extra argument: $1"
      ISSUE="$1"; shift ;;
  esac
done

[[ -n "$ISSUE" ]] || usage_err "missing issue number"
[[ "$ISSUE" =~ ^[1-9][0-9]*$ ]] || usage_err "issue number must be a positive integer"
if [[ "$HOLDER_GIVEN" -eq 1 && -z "$HOLDER_ARG" ]]; then
  usage_err "--holder must not be empty"
fi

# digest_hex <text> <n>: first n hex chars of a SHA-256. Fails closed (see header).
digest_hex() {
  local d=""
  if command -v shasum >/dev/null 2>&1; then
    d="$(printf '%s' "$1" | shasum -a 256 2>/dev/null | cut -c1-64)"
  elif command -v sha256sum >/dev/null 2>&1; then
    d="$(printf '%s' "$1" | sha256sum 2>/dev/null | cut -c1-64)"
  fi
  if [[ -z "$d" ]]; then
    echo "pr-claim-line.sh: no shasum or sha256sum found; cannot derive a claim-holder value (pass --holder with a value already shaped h-<12 hex>)" >&2
    return 1
  fi
  printf '%s' "${d:0:$2}"
}

# session_holder: the raw holder recorded for this issue by /subagent, or nothing.
session_holder() {
  local ss="$SCRIPT_DIR/session-state.sh" key v
  [[ -x "$ss" ]] || return 0
  key="$("$ss" --repo-key 2>/dev/null)" || return 0
  key="$(printf '%s' "$key" | tr '[:upper:]' '[:lower:]')"
  [[ -n "$key" ]] || return 0
  v="$("$ss" --get ".repos[\"$key\"].pipelines[\"$ISSUE\"].claim_holder" 2>/dev/null)" || return 0
  case "$v" in
    ""|null|_unknown) return 0 ;;
  esac
  printf '%s' "$v"
}

# default_raw_holder: the same default issue-claim.sh's resolve_holder computes.
default_raw_holder() {
  local host top
  host="$(hostname -s 2>/dev/null || hostname 2>/dev/null || echo unknown-host)"
  top="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
  printf '%s:%s' "$host" "$top"
}

RAW=""
if [[ "$HOLDER_GIVEN" -eq 1 ]]; then
  RAW="$HOLDER_ARG"
elif [[ -n "${CLAUDE_CLAIM_HOLDER:-}" ]]; then
  RAW="$CLAUDE_CLAIM_HOLDER"
else
  RAW="$(session_holder)"
  # The session-state record above is what a claim was actually taken with.
  # CLAUDE_SESSION_ID is the next holder issue-claim.sh itself would use.
  if [[ -z "$RAW" && -n "${CLAUDE_SESSION_ID:-}" ]]; then
    RAW="$CLAUDE_SESSION_ID"
  fi
fi

if [[ -n "$RAW" ]]; then
  if [[ "$RAW" =~ ^h-[0-9a-f]{12}$ ]]; then
    VALUE="$RAW"
  else
    d="$(digest_hex "$RAW" 12)" || exit 1
    VALUE="h-$d"
  fi
else
  # The default is a digest of the checkout's host and path (issue #2284). Its
  # result is already shaped h-<12 hex>, so it is never hashed a second time.
  d="$(digest_hex "$(default_raw_holder)" 12)" || exit 1
  VALUE="h-$d"
fi

printf '<!-- claim-holder: %s -->\n' "$VALUE"
REPO_BOOTSTRAP_FILE_EOF
      ;;
    *)
      echo "repo-bootstrap.sh: no content defined for: $rel_path" >&2
      return 1
      ;;
  esac
}

# --------------------------------------------------------------------------
# Single EXIT trap — clean up every temp file we may create. Variables are
# initialized empty so the trap is safe to install before any mktemp call.
# --------------------------------------------------------------------------
OWNER_REPO_ERR=""
BP_BODY_FILE=""
BP_STDERR_FILE=""
TMP_FILE=""
cleanup() {
  [[ -n "${OWNER_REPO_ERR:-}" ]] && rm -f "$OWNER_REPO_ERR"
  [[ -n "${BP_BODY_FILE:-}"   ]] && rm -f "$BP_BODY_FILE"
  [[ -n "${BP_STDERR_FILE:-}" ]] && rm -f "$BP_STDERR_FILE"
  [[ -n "${TMP_FILE:-}"       ]] && rm -f "$TMP_FILE"
  return 0
}
trap cleanup EXIT

# Resolve git toplevel — script writes into this dir's subdirectories.
if ! REPO_TOP=$(git rev-parse --show-toplevel 2>/dev/null); then
  echo "repo-bootstrap.sh: not in a git repository" >&2
  exit 3
fi

# Resolve owner/repo for the branch-protection API call.
OWNER_REPO_ERR=$(mktemp)
if ! OWNER_REPO=$(gh repo view --json nameWithOwner --jq '.nameWithOwner' 2>"$OWNER_REPO_ERR"); then
  echo "repo-bootstrap.sh: could not resolve owner/repo via 'gh repo view':" >&2
  cat "$OWNER_REPO_ERR" >&2
  exit 3
fi
if [[ -z "$OWNER_REPO" ]]; then
  echo "repo-bootstrap.sh: 'gh repo view' returned empty owner/repo" >&2
  exit 3
fi

# --------------------------------------------------------------------------
# Per-file state — indexed arrays parallel to BOOTSTRAP_FILES.
# FILE_STATE[i] tracks the state for BOOTSTRAP_FILES[i]:
#   "missing"   — file not in the repo
#   "present"   — file exists (was already there)
#   "installed" — this run's --apply wrote it (implies present)
#   "symlink"   — a symlink exists at the target path; not provisioned,
#                 reported as [SYMLINK], treated as a gap (exit 1)
# State is set only after a confirmed successful operation, never on failure.
# --------------------------------------------------------------------------
FILE_STATE=()

# Check which files are present (populate FILE_STATE).
# -L is tested before -f because -f follows symlinks: a symlink to an external
# regular file satisfies -f, causing --apply to report [OK] without installing
# the canonical file and leaving an out-of-repo target in place.
for _i in "${!BOOTSTRAP_FILES[@]}"; do
  _rel="${BOOTSTRAP_FILES[$_i]%%|*}"
  if [[ -L "$REPO_TOP/$_rel" ]]; then
    FILE_STATE[$_i]="symlink"
  elif [[ -f "$REPO_TOP/$_rel" ]]; then
    FILE_STATE[$_i]="present"
  else
    FILE_STATE[$_i]="missing"
  fi
done

# --------------------------------------------------------------------------
# Agent issue-claim block in AGENTS.md (issue #2285).
# The marked block is the only part of AGENTS.md this script owns; it never
# touches a byte outside the BEGIN/END marker lines.
# AGENTS_STATE: missing | present | differs | malformed | symlink
# --------------------------------------------------------------------------
AGENTS_REL="AGENTS.md"
AGENTS_BEGIN_PREFIX="<!-- BEGIN agent-issue-claims"
AGENTS_END_LINE="<!-- END agent-issue-claims -->"
_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AGENTS_SRC=""
for _cand in "$_script_dir/../reference/agent-issue-claims-block.md" \
             "${HOME:+$HOME/.claude/skills-worktree/.claude/reference/agent-issue-claims-block.md}" \
             "${HOME:+$HOME/.claude/reference/agent-issue-claims-block.md}"; do
  if [[ -n "$_cand" && -r "$_cand" ]]; then AGENTS_SRC="$_cand"; break; fi
done
if [[ -z "$AGENTS_SRC" ]]; then
  echo "ERROR: agent-issue-claims-block.md not found (checked next to this script, ~/.claude/skills-worktree, ~/.claude) — cannot check or install the AGENTS.md claim block" >&2
  exit 3
fi

agents_compute_state() {
  local f="$REPO_TOP/$AGENTS_REL" nb ne bl el cur
  if [[ -L "$f" ]]; then AGENTS_STATE="symlink"; return; fi
  if [[ ! -f "$f" ]]; then AGENTS_STATE="missing"; return; fi
  nb=$(grep -c -F -x -e "$AGENTS_END_LINE" "$f" || true)
  ne=$(grep -c -F -e "$AGENTS_BEGIN_PREFIX" "$f" || true)
  if [[ "$nb" -eq 0 && "$ne" -eq 0 ]]; then AGENTS_STATE="missing"; return; fi
  if [[ "$nb" -ne 1 || "$ne" -ne 1 ]]; then AGENTS_STATE="malformed"; return; fi
  bl=$(grep -n -F -e "$AGENTS_BEGIN_PREFIX" "$f" | head -n 1 | cut -d: -f1)
  el=$(grep -n -F -x -e "$AGENTS_END_LINE" "$f" | head -n 1 | cut -d: -f1)
  if [[ "$bl" -ge "$el" ]]; then AGENTS_STATE="malformed"; return; fi
  cur="$(sed -n "${bl},${el}p" "$f")"
  if [[ "$cur" == "$(cat "$AGENTS_SRC")" ]]; then AGENTS_STATE="present"; else AGENTS_STATE="differs"; fi
}

# Write the new AGENTS.md content into $1 (a temp file), per current state.
agents_build() {
  local out="$1" f="$REPO_TOP/$AGENTS_REL" bl el
  case "$AGENTS_STATE" in
    missing)
      if [[ -f "$f" && -s "$f" ]]; then
        cat "$f" >"$out" || return 1
        # Keep every existing byte; add only the separator needed before the block.
        [[ -z "$(tail -c 1 "$f")" ]] || printf '\n' >>"$out" || return 1
        printf '\n' >>"$out" || return 1
      else
        : >"$out" || return 1
      fi
      cat "$AGENTS_SRC" >>"$out" || return 1
      ;;
    differs)
      bl=$(grep -n -F -e "$AGENTS_BEGIN_PREFIX" "$f" | head -n 1 | cut -d: -f1)
      el=$(grep -n -F -x -e "$AGENTS_END_LINE" "$f" | head -n 1 | cut -d: -f1)
      # sed -n "1,0p" prints line 1 on GNU sed, so skip the prefix when the block starts the file.
      { if [[ "$bl" -gt 1 ]]; then sed -n "1,$((bl - 1))p" "$f"; fi; cat "$AGENTS_SRC"; sed -n "$((el + 1)),\$p" "$f"; } >"$out" || return 1
      ;;
  esac
}

agents_compute_state
AGENTS_INSTALLED=0
if [[ "$MODE" == "apply" && ( "$AGENTS_STATE" == "missing" || "$AGENTS_STATE" == "differs" ) ]]; then
  _ag_tmp="$(mktemp "$REPO_TOP/.repo-bootstrap-agents.XXXXXX" 2>/dev/null)" || { echo "repo-bootstrap.sh: failed to create temp file for $AGENTS_REL" >&2; exit 5; }
  TMP_FILE="$_ag_tmp"
  # Mode: keep the existing file's (cp -p), else the usual 644 for a new file.
  if [[ -f "$REPO_TOP/$AGENTS_REL" ]]; then
    cp -p "$REPO_TOP/$AGENTS_REL" "$_ag_tmp" || { echo "repo-bootstrap.sh: failed to stage $AGENTS_REL" >&2; exit 5; }
  else
    chmod 644 "$_ag_tmp" || { echo "repo-bootstrap.sh: failed to chmod temp file for $AGENTS_REL" >&2; exit 5; }
  fi
  if ! agents_build "$_ag_tmp"; then
    echo "repo-bootstrap.sh: failed to build $AGENTS_REL" >&2
    exit 5
  fi
  # Publish by rename: a failed write leaves the original AGENTS.md intact.
  if ! mv -f "$_ag_tmp" "$REPO_TOP/$AGENTS_REL"; then
    echo "repo-bootstrap.sh: failed to write $AGENTS_REL" >&2
    exit 5
  fi
  TMP_FILE=""
  AGENTS_INSTALLED=1
  agents_compute_state
fi

# --------------------------------------------------------------------------
# Branch protection check (read-only — never modified)
# --------------------------------------------------------------------------
# Capture the response and HTTP status separately. `gh api` returns non-zero on
# 4xx, but we need to distinguish 404 (not configured — actionable) from 403
# (no permission — skip with a note) from other gh failures (network, auth).
BP_BODY_FILE=$(mktemp)
BP_STDERR_FILE=$(mktemp)

BP_STATE="unknown"
BP_CHECKS=""
BP_NOTE=""
# Deferred-exit code: when set non-zero, the report still prints (so the user
# sees the [UNKNOWN] line + note) and the script exits with this value at the
# end. Keeps the exit-4 contract intact while making the documented [UNKNOWN]
# state actually reachable.
BP_ERROR_EXIT=0
if gh api "repos/$OWNER_REPO/branches/main/protection/required_status_checks" \
    >"$BP_BODY_FILE" 2>"$BP_STDERR_FILE"; then
  # 200 — configured. Extract the contexts array (contexts is the legacy field;
  # checks[].context is the newer field — prefer checks[].context, fall back to
  # contexts).
  BP_STATE="configured"
  if ! BP_CHECKS=$(jq -r '
    if (.checks | type) == "array" and (.checks | length) > 0 then
      [.checks[].context] | join(", ")
    elif (.contexts | type) == "array" then
      .contexts | join(", ")
    else "" end
  ' "$BP_BODY_FILE" 2>/dev/null); then
    echo "repo-bootstrap.sh: failed to parse branch-protection response with jq" >&2
    BP_STATE="unknown"
    BP_NOTE="jq parse failure on branch-protection response — see stderr."
    BP_ERROR_EXIT=4
  fi
else
  BP_STDERR=$(cat "$BP_STDERR_FILE")
  if grep -qiE 'HTTP 404|Not Found|Branch not protected' <<<"$BP_STDERR"; then
    BP_STATE="missing"
    BP_NOTE="404 — required status checks not configured."
  elif grep -qiE 'HTTP 403|forbidden|must have admin' <<<"$BP_STDERR"; then
    BP_STATE="no_permission"
    BP_NOTE="403 — token lacks permission to read branch protection."
  else
    echo "repo-bootstrap.sh: gh api failed for branch protection:" >&2
    printf '%s\n' "$BP_STDERR" >&2
    BP_STATE="unknown"
    BP_NOTE="gh api failed for branch protection — see stderr."
    BP_ERROR_EXIT=4
  fi
fi

# --------------------------------------------------------------------------
# Apply mode — install each missing file (never overwrites an existing one).
# Write failure on any file exits 5 immediately, before any clean report,
# so a mid-set failure cannot make other files or the run appear clean.
# --------------------------------------------------------------------------
if [[ "$MODE" == "apply" ]]; then
  for _i in "${!BOOTSTRAP_FILES[@]}"; do
    _entry="${BOOTSTRAP_FILES[$_i]}"
    _rel="${_entry%%|*}"
    _mode="${_entry##*|}"
    _abs="$REPO_TOP/$_rel"

    [[ "${FILE_STATE[$_i]}" != "missing" ]] && continue  # already present or symlink — skip

    _dir="$(dirname "$_abs")"
    # Symlink safety: resolve the nearest existing ancestor of the target path
    # and verify it sits within REPO_TOP.  A malicious repository may symlink
    # .github or .claude to an external directory; cd -P gives the physical
    # path without requiring platform-specific tools (realpath -m is GNU-only).
    _chk_path="$_abs"
    while [[ ! -e "$_chk_path" && "$_chk_path" != "/" ]]; do
      _chk_path="$(dirname "$_chk_path")"
    done
    _chk_phys="$(cd -P "$_chk_path" 2>/dev/null && pwd)" || _chk_phys=""
    _repo_phys="$(cd -P "$REPO_TOP" 2>/dev/null && pwd)" || _repo_phys="$REPO_TOP"
    if [[ -n "$_chk_phys" && "$_chk_phys" != "$_repo_phys" && "$_chk_phys" != "$_repo_phys/"* ]]; then
      echo "repo-bootstrap.sh: target $_abs escapes repo root via symlink (resolved: $_chk_phys)" >&2
      exit 5
    fi
    if ! mkdir -p "$_dir"; then
      echo "repo-bootstrap.sh: failed to create $_dir" >&2
      exit 5
    fi
    # Write to a temp file in the same directory (same filesystem, so the
    # hard-link rename is atomic), then publish via `ln` which fails if the
    # destination already exists. This closes the TOCTOU window: a concurrent
    # writer that creates $_abs first causes `ln` to fail, and we treat that as
    # "already present" instead of overwriting. The temp file is removed on
    # success or via the EXIT trap on failure.
    if ! TMP_FILE="$(mktemp "$_dir/.repo-bootstrap.XXXXXX" 2>/dev/null)"; then
      echo "repo-bootstrap.sh: failed to create temp file in $_dir" >&2
      exit 5
    fi
    if ! get_file_content "$_rel" >"$TMP_FILE"; then
      echo "repo-bootstrap.sh: failed to write temp file for $_rel" >&2
      exit 5
    fi
    # Set the canonical file mode before publishing. mktemp creates files at
    # mode 600; the canonical mode may differ (e.g. 755 for shell scripts).
    if ! chmod "$_mode" "$TMP_FILE"; then
      echo "repo-bootstrap.sh: failed to chmod $_mode temp file for $_rel" >&2
      exit 5
    fi
    if [[ -d "$_abs" ]]; then
      echo "repo-bootstrap.sh: target path is a directory, cannot install $_abs" >&2
      exit 5
    fi
    if ln "$TMP_FILE" "$_abs" 2>/dev/null; then
      rm -f "$TMP_FILE"
      TMP_FILE=""   # avoid double-cleanup in EXIT trap
      FILE_STATE[$_i]="installed"
    elif [[ -e "$_abs" ]]; then
      # Concurrent writer beat us — honor the no-overwrite contract.
      rm -f "$TMP_FILE"
      TMP_FILE=""
      FILE_STATE[$_i]="present"
    else
      echo "repo-bootstrap.sh: failed to publish $_abs" >&2
      exit 5
    fi
  done
fi

# --------------------------------------------------------------------------
# Report
# --------------------------------------------------------------------------
echo "Repo Bootstrap Report"
echo "====================="
echo "Repo: $OWNER_REPO"
echo "Mode: $MODE"
echo
echo "Provisioned Files:"
for _i in "${!BOOTSTRAP_FILES[@]}"; do
  _rel="${BOOTSTRAP_FILES[$_i]%%|*}"
  case "${FILE_STATE[$_i]}" in
    installed) printf '  [INSTALLED] %s\n' "$_rel" ;;
    present)   printf '  [OK]        %s\n' "$_rel" ;;
    symlink)   printf '  [SYMLINK]   %s — symlink at target; remove it to provision the canonical file\n' "$_rel" ;;
    *)         printf '  [MISSING]   %s\n' "$_rel" ;;
  esac
done
echo
echo "Agent Instructions (AGENTS.md):"
case "$AGENTS_STATE" in
  present)
    if [[ "$AGENTS_INSTALLED" -eq 1 ]]; then
      printf '  [INSTALLED] %s — issue-claim block\n' "$AGENTS_REL"
    else
      printf '  [OK]        %s — issue-claim block\n' "$AGENTS_REL"
    fi ;;
  differs)   printf '  [MISSING]   %s — issue-claim block differs from the source; --apply rewrites only the marked block\n' "$AGENTS_REL" ;;
  malformed) printf '  [MISSING]   %s — unbalanced issue-claim markers; fix by hand (never auto-edited)\n' "$AGENTS_REL" ;;
  symlink)   printf '  [SYMLINK]   %s — symlink at target; remove it to install the block\n' "$AGENTS_REL" ;;
  *)         printf '  [MISSING]   %s — issue-claim block not installed\n' "$AGENTS_REL" ;;
esac
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
    if [[ -n "$BP_NOTE" ]]; then
      echo "  [UNKNOWN]   $BP_NOTE"
    else
      echo "  [UNKNOWN]   could not determine branch protection state"
    fi
    ;;
esac

# --------------------------------------------------------------------------
# Exit code
# --------------------------------------------------------------------------
# Deferred error from the BP-check section (jq parse failure or unrecognized
# gh failure) takes precedence over GAPS — the report has been printed so the
# user sees the [UNKNOWN] line; now surface the original exit-4 contract.
if [[ "$BP_ERROR_EXIT" -ne 0 ]]; then
  exit "$BP_ERROR_EXIT"
fi

GAPS=0
for _i in "${!BOOTSTRAP_FILES[@]}"; do
  if [[ "${FILE_STATE[$_i]}" == "missing" || "${FILE_STATE[$_i]}" == "symlink" ]]; then
    GAPS=1
    break
  fi
done
if [[ "$BP_STATE" == "missing" ]]; then
  GAPS=1
fi
if [[ "$AGENTS_STATE" != "present" ]]; then
  GAPS=1
fi

if [[ "$GAPS" -eq 1 ]]; then
  echo

  # Identify which categories have gaps to print specific messages.
  FILE_GAP=0
  SYM_GAP=0
  for _i in "${!BOOTSTRAP_FILES[@]}"; do
    if [[ "${FILE_STATE[$_i]}" == "missing" ]]; then
      FILE_GAP=1
    elif [[ "${FILE_STATE[$_i]}" == "symlink" ]]; then
      SYM_GAP=1
    fi
  done
  BP_GAP=0
  [[ "$BP_STATE" == "missing" ]] && BP_GAP=1
  if [[ "$AGENTS_STATE" != "present" ]]; then
    if [[ "$MODE" == "check" && ( "$AGENTS_STATE" == "missing" || "$AGENTS_STATE" == "differs" ) ]]; then
      echo "AGENTS.md claim block gap detected. Re-run with --apply to install or refresh it."
    else
      echo "AGENTS.md claim block needs attention (see report); --apply will not edit a symlink or unbalanced markers."
    fi
  fi

  if [[ "$MODE" == "check" ]]; then
    if [[ "$FILE_GAP" -eq 1 ]]; then
      echo "File gaps detected. Re-run with --apply to install missing files."
    fi
    if [[ "$SYM_GAP" -eq 1 ]]; then
      echo "Symlink at provisioned target path; remove it and re-run."
    fi
    if [[ "$BP_GAP" -eq 1 ]]; then
      echo "Branch protection gap detected. Requires user confirmation — see"
      echo ".claude/rules/repo-bootstrap.md (--apply does not modify branch protection)."
    fi
  else
    # apply mode — "missing" file gaps are resolved before this point (or exit 5).
    # Remaining GAPS=1 is from symlinks at target paths or branch protection.
    if [[ "$SYM_GAP" -eq 1 ]]; then
      echo "Symlink at provisioned target path; remove it and re-run."
    fi
    if [[ "$BP_GAP" -eq 1 ]]; then
      echo "Branch protection gap remains. Requires user confirmation — see"
      echo ".claude/rules/repo-bootstrap.md (--apply does not modify branch protection)."
    fi
  fi
  exit 1
fi

exit 0
