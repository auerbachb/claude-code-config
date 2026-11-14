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
    if: "!endsWith(github.event.issue.user.login, '[bot]')"
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
    # The claim holder named in the PR body is read from the event payload and
    # the body is re-read on every edit, so each of these events can change the verdict.
    types: [opened, reopened, edited, synchronize]

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
          # branch (the bootstrap PR introducing it, or a repo without the claim
          # helpers), print a notice and pass. The check is advisory either way.
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
#   Overall skipped: bot author (bot_author), or no closing keyword (no_linked_issue).
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

TMPD="$(mktemp -d 2>/dev/null)" || { echo '{"verdict":"unverifiable","reason":"tempdir_unavailable","claim_line":false,"issues":[]}'; exit 0; }
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
    --argjson pr "$PR" \
    --arg repo "$RESULT_REPO" \
    --arg verdict "$1" \
    --arg reason "$2" \
    --argjson claim_line "$3" \
    --argjson issues "$4" \
    '{pr: $pr, repo: $repo, verdict: $verdict, reason: $reason, claim_line: $claim_line, issues: $issues}'
  # Every exit path (including unverifiable early exits) goes through the CI
  # mapping, so a failed read warns in --report mode instead of passing silently.
  if [[ "$REPORT" -eq 1 ]]; then
    report_outcome
  fi
  exit 0
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
    # A fence opens with 3+ backticks or tildes and closes only with the same
    # character, at least as long, and nothing else on the line.
    BEGIN { fence = 0; fch = ""; flen = 0; com = 0 }
    {
      t = $0; sub(/^[[:space:]]*/, "", t)
      ch = substr(t, 1, 1)
      n = 0
      if (ch == "`" || ch == "~") { while (substr(t, n + 1, 1) == ch) n++ }
      if (fence) {
        if (n >= flen && ch == fch && substr(t, n + 1) ~ /^[[:space:]]*$/) fence = 0
        next
      }
      if (n >= 3) { fence = 1; fch = ch; flen = n; next }
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
CLAIM_LINES="$(LC_ALL=C grep -F '<!-- claim-holder:' "$TMPD/body_fenced_only.md" 2>/dev/null || true)"
CLAIM_LINE_PRESENT=false
PR_HOLDER=""
MALFORMED=0
if [[ -n "$CLAIM_LINES" ]]; then
  CLAIM_LINE_PRESENT=true
  FIRST_LINE="$(printf '%s\n' "$CLAIM_LINES" | head -n 1)"
  if LC_ALL=C grep -qE '^[[:space:]]*<!-- claim-holder: h-[0-9a-f]{12} -->[[:space:]]*$' <<<"$FIRST_LINE"; then
    PR_HOLDER="$(printf '%s' "$FIRST_LINE" | LC_ALL=C grep -oE 'h-[0-9a-f]{12}')"
  else
    MALFORMED=1
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
  # A reference qualified to another repository names an issue this check cannot read.
  if [[ -n "$QUAL" && "$QUAL_LC" != "$REPO_LC" ]]; then continue; fi
  NUMS="$NUMS${BASH_REMATCH[2]}
"
done <<<"$REFS"
LINKED="$(printf '%s' "$NUMS" | LC_ALL=C grep -E '^[0-9]+$' | LC_ALL=C sort -n -u)" || LINKED=""

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
  if [[ ! -f "$ISSUE_CLAIM" ]]; then
    add_issue "$N" unverifiable claim_helper_missing
    continue
  fi

  CLAIM_OUT="$(bash "$ISSUE_CLAIM" "$N" --check --json --repo "$REPO" --holder pr-claim-check 2>/dev/null)" || true
  VERDICT="$(printf '%s' "$CLAIM_OUT" | jq -r '.verdict // ""' 2>/dev/null)" || VERDICT=""
  case "$VERDICT" in
    unclaimed|stale)
      add_issue "$N" pass_unclaimed "$VERDICT" ;;
    claimed)
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
  if [[ "$OVERALL" == "skipped" || "$OVERALL" == "match" || "$OVERALL" == "pass_unclaimed" ]]; then
    LINE="pr-claim-check: $OVERALL on PR #$PR"
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

  # Dedupe: one comment per PR per outcome and issue set.
  if ! gh api --paginate "repos/$REPO/issues/$PR/comments?per_page=100" >"$TMPD/comments.json" 2>/dev/null; then
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
