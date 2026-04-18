#!/usr/bin/env bash
# reply-thread.sh — Post a reviewer-aware reply to a PR review thread.
#
# Tries the inline reply endpoint first (pulls/comments/{id}/replies); on 404
# falls back to a PR-level comment. Applies reviewer-specific @mention rules:
#   - cr        : prepends `@coderabbitai ` to the body if not already present
#   - bugbot    : strips any `@cursor` tokens from the body (may trigger re-review)
#   - greptile  : strips any `@greptileai` tokens from the body (paid re-review)
#
# The strip rules are case-insensitive and match the literal @token only — they
# do NOT mangle surrounding text. Both strip and prepend are idempotent.
#
# Usage:
#   reply-thread.sh <comment_id> --reviewer cr|bugbot|greptile --body "<text>" [--pr N]
#   reply-thread.sh --help
#
# Arguments:
#   <comment_id>     Numeric databaseId of the review comment to reply to.
#   --reviewer X     One of: cr, bugbot, greptile. Controls @mention handling.
#   --body "<text>"  Reply body (after transformation rules are applied).
#   --pr N           PR number. Required only for the PR-comment fallback path;
#                    optional for inline. If omitted and inline returns 404,
#                    the script cannot fall back — exits 3.
#
# Exit codes:
#   0  Inline reply posted (posted comment URL printed to stdout)
#   1  Fallback PR-level reply posted (still a successful reply; URL on stdout)
#   2  Usage error
#   3  Inline returned 404 and no --pr provided OR both endpoints returned 404
#   4  Inline succeeded in posting but fallback failed — or both endpoints errored non-404
#   5  gh / network error (unexpected)
#
# Examples:
#   reply-thread.sh 2345678901 --reviewer cr \
#     --body "Fixed in \`abc1234\`: renamed the helper per your suggestion." \
#     --pr 317
#
#   reply-thread.sh 2345678901 --reviewer greptile \
#     --body "Addressed in prior commit — current code no longer has this issue." \
#     --pr 317
#
# See .claude/rules/cr-github-review.md "Processing CR Feedback" step 3 and
# .claude/rules/greptile.md / .claude/rules/bugbot.md for the reply conventions
# this script enforces.

set -uo pipefail

REVIEWER=""
BODY=""
PR_NUMBER=""
COMMENT_ID=""

print_help() {
  awk 'NR == 1 { next } /^$/ { exit } { sub(/^# ?/, ""); print }' "$0"
}

# --------------------------------------------------------------------------
# Argument parsing
# --------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help)
      print_help
      exit 0
      ;;
    --reviewer)
      if [[ -z "${2:-}" ]]; then
        echo "ERROR: --reviewer requires a value (cr|bugbot|greptile)" >&2
        exit 2
      fi
      REVIEWER="$2"
      shift 2
      ;;
    --body)
      if [[ -z "${2:-}" ]]; then
        echo "ERROR: --body requires a value" >&2
        exit 2
      fi
      BODY="$2"
      shift 2
      ;;
    --pr)
      if [[ -z "${2:-}" ]]; then
        echo "ERROR: --pr requires a value" >&2
        exit 2
      fi
      PR_NUMBER="$2"
      shift 2
      ;;
    --*)
      echo "ERROR: unknown flag: $1" >&2
      exit 2
      ;;
    *)
      if [[ -n "$COMMENT_ID" ]]; then
        echo "ERROR: unexpected positional argument: $1" >&2
        exit 2
      fi
      COMMENT_ID="$1"
      shift
      ;;
  esac
done

if [[ -z "$COMMENT_ID" ]]; then
  echo "ERROR: <comment_id> is required" >&2
  echo "Usage: $(basename "$0") <comment_id> --reviewer cr|bugbot|greptile --body \"<text>\" [--pr N]" >&2
  exit 2
fi

if [[ ! "$COMMENT_ID" =~ ^[1-9][0-9]*$ ]]; then
  echo "ERROR: <comment_id> must be a positive integer (got: $COMMENT_ID)" >&2
  exit 2
fi

case "$REVIEWER" in
  cr|bugbot|greptile) ;;
  "")
    echo "ERROR: --reviewer is required (cr|bugbot|greptile)" >&2
    exit 2
    ;;
  *)
    echo "ERROR: --reviewer must be one of: cr, bugbot, greptile (got: $REVIEWER)" >&2
    exit 2
    ;;
esac

if [[ -z "$BODY" ]]; then
  echo "ERROR: --body is required" >&2
  exit 2
fi

if [[ -n "$PR_NUMBER" ]] && [[ ! "$PR_NUMBER" =~ ^[1-9][0-9]*$ ]]; then
  echo "ERROR: --pr must be a positive integer (got: $PR_NUMBER)" >&2
  exit 2
fi

# --------------------------------------------------------------------------
# Body transformation — reviewer-specific @mention rules
# --------------------------------------------------------------------------
case "$REVIEWER" in
  cr)
    # Prepend @coderabbitai if not already present (case-insensitive).
    # CR needs the @mention so it reads the reply — especially in PR-comment
    # fallback, but we keep it consistent on inline too.
    if ! printf '%s' "$BODY" | grep -qi '@coderabbitai'; then
      BODY="@coderabbitai $BODY"
    fi
    ;;
  bugbot)
    # Strip any @cursor tokens (may trigger a re-review on PR-level comments).
    # Case-insensitive literal match; does not touch surrounding text beyond
    # collapsing the now-empty slot.
    BODY=$(printf '%s' "$BODY" | sed -E 's/@[Cc][Uu][Rr][Ss][Oo][Rr]//g')
    ;;
  greptile)
    # Strip any @greptileai tokens (every mention triggers a paid re-review).
    BODY=$(printf '%s' "$BODY" | sed -E 's/@[Gg][Rr][Ee][Pp][Tt][Ii][Ll][Ee][Aa][Ii]//g')
    ;;
esac

# Collapse any runs of whitespace introduced by token removal, and trim ends.
# Only applies to bugbot/greptile where we actually stripped something.
if [[ "$REVIEWER" == "bugbot" || "$REVIEWER" == "greptile" ]]; then
  BODY=$(printf '%s' "$BODY" | sed -E 's/[[:space:]]+/ /g; s/^ //; s/ $//')
fi

if [[ -z "$BODY" ]]; then
  echo "ERROR: --body is empty after reviewer transformation" >&2
  exit 2
fi

# --------------------------------------------------------------------------
# Resolve owner/repo from the current checkout.
# --------------------------------------------------------------------------
REPO_ERR=$(mktemp -t reply-thread-repo.XXXXXX)
# shellcheck disable=SC2064
trap "rm -f '$REPO_ERR'" EXIT
if ! REPO_JSON=$(gh repo view --json owner,name 2>"$REPO_ERR"); then
  echo "ERROR: gh repo view failed: $(cat "$REPO_ERR")" >&2
  exit 5
fi
# jq -e exits non-zero if the result is null/false/missing, so we detect
# malformed JSON or missing fields rather than silently carrying empty values.
if ! OWNER=$(printf '%s' "$REPO_JSON" | jq -er '.owner.login') \
  || ! REPO=$(printf '%s' "$REPO_JSON" | jq -er '.name') \
  || [[ -z "$OWNER" || -z "$REPO" ]]; then
  echo "ERROR: could not determine owner/repo from current checkout" >&2
  exit 5
fi

# --------------------------------------------------------------------------
# Inline reply attempt — pulls/comments/{id}/replies
#
# Capture stdout (JSON response body) and stderr (gh error messages) into
# separate streams. gh api emits the HTTP-error text to stderr — mixing it
# into stdout would break jq parsing of the success-path JSON.
# --------------------------------------------------------------------------
INLINE_ERR=$(mktemp -t reply-thread-inline-err.XXXXXX)
# shellcheck disable=SC2064
trap "rm -f '$REPO_ERR' '$INLINE_ERR'" EXIT

INLINE_RC=0
INLINE_RESP=$(gh api "repos/$OWNER/$REPO/pulls/comments/$COMMENT_ID/replies" \
  -f body="$BODY" 2>"$INLINE_ERR") || INLINE_RC=$?

if [[ $INLINE_RC -eq 0 ]]; then
  # Success path: stdout contains the POST response JSON. Parse html_url.
  URL=$(printf '%s' "$INLINE_RESP" | jq -r '.html_url // empty' 2>/dev/null || true)
  if [[ -n "$URL" ]]; then
    printf '%s\n' "$URL"
  fi
  exit 0
fi

# Failure path: classify via stderr. gh prints HTTP errors like
# "HTTP 404: Not Found (...)". stdout may be empty or contain a partial body.
INLINE_ERR_TEXT=$(cat "$INLINE_ERR")
IS_404=0
if printf '%s' "$INLINE_ERR_TEXT" | grep -qE 'HTTP 404|404:.*Not Found|Not Found \(HTTP 404\)'; then
  IS_404=1
fi

if [[ $IS_404 -eq 0 ]]; then
  # Unexpected inline error (5xx, auth, network) — do NOT fall back. Emit diag.
  echo "ERROR: inline reply failed (non-404): $INLINE_ERR_TEXT" >&2
  exit 5
fi

# --------------------------------------------------------------------------
# 404 on inline — try PR-comment fallback if --pr was provided.
# --------------------------------------------------------------------------
if [[ -z "$PR_NUMBER" ]]; then
  echo "ERROR: inline returned 404 and --pr not provided — cannot fall back" >&2
  echo "       Comment $COMMENT_ID is not an inline review comment (or does not exist)." >&2
  exit 3
fi

FALLBACK_ERR=$(mktemp -t reply-thread-fallback-err.XXXXXX)
# shellcheck disable=SC2064
trap "rm -f '$REPO_ERR' '$INLINE_ERR' '$FALLBACK_ERR'" EXIT

FALLBACK_RC=0
FALLBACK_RESP=$(gh pr comment "$PR_NUMBER" --body "$BODY" 2>"$FALLBACK_ERR") || FALLBACK_RC=$?

if [[ $FALLBACK_RC -eq 0 ]]; then
  # `gh pr comment` prints the posted comment URL on stdout.
  printf '%s\n' "$FALLBACK_RESP"
  exit 1
fi

# Fallback failed — classify via stderr.
FALLBACK_ERR_TEXT=$(cat "$FALLBACK_ERR")
if printf '%s' "$FALLBACK_ERR_TEXT" | grep -qE 'HTTP 404|404:.*Not Found|Not Found \(HTTP 404\)'; then
  echo "ERROR: both inline and fallback returned 404 — PR $PR_NUMBER or comment $COMMENT_ID not found" >&2
  exit 3
fi

echo "ERROR: inline returned 404 and fallback failed: $FALLBACK_ERR_TEXT" >&2
exit 4
