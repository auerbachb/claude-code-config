#!/usr/bin/env bash
# pr-authorship.sh — Hard authorship gate for automated PR write actions (issue #733).
#
# PURPOSE
#   The single source of truth for the question every automated PR tool must
#   answer before it writes: "did the authenticated user author this PR?"
#   Merging, rebasing, force-pushing, closing, commenting, triggering reviews
#   (@coderabbitai / @cursor / @greptileai), resolving threads, and enrolling a
#   PR in babysit/polling are all WRITES — none may touch a PR the user did not
#   author unless the user names that PR explicitly in chat (a per-PR,
#   per-session override the agent applies; this script never infers it).
#
#   The guard is defined in .claude/rules/safety.md ("Authorship — Automated PR
#   Writes"). This script is the tooling half: skills call it to gate an explicit
#   PR argument, and write/enroll scripts (polling-state-gate.sh --ensure-session,
#   admin-merge.sh) call it as a fail-safe so the guard holds even if a skill's
#   prose is forgotten or context compacts (issue #733 AC3).
#
# FAIL-CLOSED (issue #733 AC4)
#   When authorship cannot be determined — gh/network error, empty author, or an
#   unresolvable viewer login — the verdict is "unknown", exit 4. Callers MUST
#   treat unknown exactly like not_mine: skip the PR with a visible note. The
#   only exit code that authorizes an automated write is 0.
#
# USAGE
#   pr-authorship.sh <pr_number> [--repo <owner/repo>] [--json]
#   pr-authorship.sh --help | -h
#
#   --repo <owner/repo>  Look the PR up in a named repo instead of the current
#                        checkout's repo (gh's {owner}/{repo} placeholder).
#   --json               Emit a machine-readable object on stdout instead of the
#                        one-word verdict (see OUTPUT).
#
# OUTPUT
#   Default: one word on stdout — mine | not_mine | unknown. A human-readable
#            refusal / fail-closed note goes to stderr for the not_mine / unknown
#            / not-found cases (so a caller that only reads the exit code and
#            stderr still surfaces a clear message).
#   --json:  {"pr":N,"repo":"owner/repo"|null,"viewer":"login"|null,
#             "author":"login"|null,"author_type":"User"|"Bot"|...|null,
#             "verdict":"mine"|"not_mine"|"unknown","reason":"..."} on stdout.
#
# EXIT STATUS
#   0  mine        — PR authored by the authenticated user; a write is authorized.
#   1  not_mine    — PR authored by someone else (a collaborator, or a bot such
#                    as dependabot/renovate). Refuse; naming the guard.
#   2  usage       — bad/missing PR number, unknown flag.
#   3  not_found   — no such PR (404). Authorship is moot; do not act.
#   4  unknown     — authorship undetermined (gh/network error, empty author, or
#                    viewer login unresolved). FAIL-CLOSED: treat as not_mine.
#
# DEPENDENCIES
#   - gh (authenticated)
#   - jq
#
# EXAMPLES
#   pr-authorship.sh 730            # -> mine     (exit 0)
#   pr-authorship.sh 42             # -> not_mine (exit 1; author on stderr)
#   pr-authorship.sh 9999           # -> (stderr: not found; exit 3)
#   pr-authorship.sh 730 --json     # -> {"pr":730,...,"verdict":"mine",...}

set -uo pipefail
printf '%s\t%s\t%s\n' "$(date -u +%FT%TZ)" "$(basename "$0")" "${*//$'\n'/ }" 2>/dev/null >> "$HOME/.claude/script-usage.log" || true

GUARD_REF="the authorship guard (.claude/rules/safety.md)"

print_help() {
  # Print the leading comment header (everything after the shebang up to the
  # first blank line), stripping the leading "# ".
  awk 'NR == 1 { next } /^$/ { exit } { print }' "$0" | sed 's/^# \{0,1\}//'
}

die_usage() {
  echo "pr-authorship.sh: $1" >&2
  echo "Run with --help for usage." >&2
  exit 2
}

# --- arg parsing ---
PR_NUMBER=""
REPO=""
JSON=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help)
      print_help
      exit 0
      ;;
    --json)
      JSON=1
      shift
      ;;
    --repo)
      if [[ $# -lt 2 || -z "${2-}" ]]; then
        die_usage "--repo requires a value (owner/repo)"
      fi
      REPO="$2"
      shift 2
      ;;
    --repo=*)
      REPO="${1#--repo=}"
      [[ -z "$REPO" ]] && die_usage "--repo requires a value (owner/repo)"
      shift
      ;;
    --)
      shift
      break
      ;;
    -*)
      die_usage "unknown flag: $1"
      ;;
    *)
      if [[ -n "$PR_NUMBER" ]]; then
        die_usage "unexpected positional argument: $1"
      fi
      PR_NUMBER="$1"
      shift
      ;;
  esac
done

if [[ -z "$PR_NUMBER" ]]; then
  die_usage "<pr_number> is required"
fi
if ! [[ "$PR_NUMBER" =~ ^[1-9][0-9]*$ ]]; then
  die_usage "<pr_number> must be a positive integer, got: $PR_NUMBER"
fi
if [[ -n "$REPO" ]] && ! [[ "$REPO" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]]; then
  die_usage "--repo must be owner/repo, got: $REPO"
fi

for dep in gh jq; do
  if ! command -v "$dep" >/dev/null 2>&1; then
    echo "pr-authorship.sh: '$dep' not found on PATH" >&2
    exit 2
  fi
done

# --- emit helper ---------------------------------------------------------------
# emit <verdict> <exit_code> <reason> [viewer] [author] [author_type]
emit() {
  local verdict="$1" code="$2" reason="$3" viewer="${4:-}" author="${5:-}" author_type="${6:-}"
  if [[ "$JSON" -eq 1 ]]; then
    jq -cn \
      --argjson pr "$PR_NUMBER" \
      --arg repo "$REPO" \
      --arg viewer "$viewer" \
      --arg author "$author" \
      --arg author_type "$author_type" \
      --arg verdict "$verdict" \
      --arg reason "$reason" \
      '{pr: $pr,
        repo: (if $repo == "" then null else $repo end),
        viewer: (if $viewer == "" then null else $viewer end),
        author: (if $author == "" then null else $author end),
        author_type: (if $author_type == "" then null else $author_type end),
        verdict: $verdict,
        reason: $reason}'
  else
    printf '%s\n' "$verdict"
  fi
  # The human-readable line always goes to stderr for the non-authorized cases,
  # so a caller reading only the exit code still surfaces a clear message.
  case "$verdict" in
    not_mine) echo "pr-authorship.sh: $reason" >&2 ;;
    unknown)  echo "pr-authorship.sh: $reason" >&2 ;;
  esac
  exit "$code"
}

# --- resolve the authenticated viewer login ------------------------------------
# Empty / failure -> fail-closed (unknown). We can't decide "mine" without a
# viewer to compare against, and guessing would defeat the guard.
VIEWER="$(gh api user --jq '.login' 2>/dev/null || true)"
if [[ -z "$VIEWER" || "$VIEWER" == "null" ]]; then
  emit unknown 4 "could not resolve the authenticated user (gh api user failed) — authorship undetermined; treating PR #$PR_NUMBER as not mine (fail-closed per $GUARD_REF)"
fi

# --- fetch the PR's author + state ---------------------------------------------
# `gh api repos/.../pulls/N` (not `gh pr view --json number`) so a nonexistent
# PR is a real 404 rather than a fabricated {"number":N} success (see
# reviewer-of.sh for the same quirk). {owner}/{repo} resolves from the current
# checkout unless --repo names one explicitly.
if [[ -n "$REPO" ]]; then
  API_PATH="repos/$REPO/pulls/$PR_NUMBER"
else
  API_PATH="repos/{owner}/{repo}/pulls/$PR_NUMBER"
fi

PR_ERR="$(mktemp)"
trap 'rm -f "$PR_ERR" 2>/dev/null' EXIT
if ! PR_JSON="$(gh api "$API_PATH" 2>"$PR_ERR")"; then
  # ERE for BSD/macOS grep portability (reviewer-of.sh lesson).
  if grep -qiE "http 404|not found|could not resolve|no pull request|no such" "$PR_ERR"; then
    emit unknown 3 "PR #$PR_NUMBER not found${REPO:+ in $REPO} — cannot act" "$VIEWER"
  fi
  emit unknown 4 "gh api failed reading PR #$PR_NUMBER author ($(tr '\n' ' ' < "$PR_ERR")) — authorship undetermined; treating as not mine (fail-closed per $GUARD_REF)" "$VIEWER"
fi

AUTHOR="$(printf '%s' "$PR_JSON" | jq -r '.user.login // ""' 2>/dev/null || true)"
AUTHOR_TYPE="$(printf '%s' "$PR_JSON" | jq -r '.user.type // ""' 2>/dev/null || true)"

if [[ -z "$AUTHOR" || "$AUTHOR" == "null" ]]; then
  emit unknown 4 "PR #$PR_NUMBER has no readable author — authorship undetermined; treating as not mine (fail-closed per $GUARD_REF)" "$VIEWER"
fi

# --- verdict -------------------------------------------------------------------
if [[ "$AUTHOR" == "$VIEWER" ]]; then
  emit mine 0 "PR #$PR_NUMBER authored by $AUTHOR (the authenticated user)" "$VIEWER" "$AUTHOR" "$AUTHOR_TYPE"
fi

emit not_mine 1 "PR #$PR_NUMBER is authored by $AUTHOR${AUTHOR_TYPE:+ ($AUTHOR_TYPE)}, not you ($VIEWER) — automated write actions are blocked by $GUARD_REF. Only an explicit per-PR, per-session override (you naming this PR in chat) authorizes acting on it." "$VIEWER" "$AUTHOR" "$AUTHOR_TYPE"
