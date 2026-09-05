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
