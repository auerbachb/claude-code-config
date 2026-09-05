#!/usr/bin/env bash
# repo-bootstrap.sh — Check (and optionally install) required repo configuration.
# catalog: trust-worktree-repo — Check and optionally install required repo configuration (provisioned file set, branch protection)
#
# Implements the contract from .claude/rules/repo-bootstrap.md:
#   1. Provisioned files: ensures a set of required files exist in the repo.
#      Run with --apply to install any that are missing (add-only; never
#      overwrites). See .claude/reference/repo-bootstrap-workflows.md for the
#      file-set design, per-file modes, and the one-list guarantee.
#   2. Branch protection on main: report status only — never modified by this
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
  ".claude/scripts/pr-issue-ref.sh|755"
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
  pull_request: {}

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
    ".claude/scripts/ac-gate.sh")
      cat <<'REPO_BOOTSTRAP_FILE_EOF'
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
  elif printf '%s\n' "$BODY" | grep -qiE '(^|[^[:alnum:]_])(close|closes|closed|fix|fixes|fixed|resolve|resolves|resolved)[[:space:]]+[a-zA-Z0-9_.-]+/[a-zA-Z0-9_.-]+#[0-9]+'; then
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
  if printf '%s' "$BP_STDERR" | grep -qiE 'HTTP 404|Not Found|Branch not protected'; then
    BP_STATE="missing"
    BP_NOTE="404 — required status checks not configured."
  elif printf '%s' "$BP_STDERR" | grep -qiE 'HTTP 403|forbidden|must have admin'; then
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
