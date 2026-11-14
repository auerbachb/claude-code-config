#!/usr/bin/env bash
# required-checks.sh — Read base required contexts for after-CI requests (Issue 2316).
# catalog: merge-gate-sequencing — Read required contexts without interpreting an unreadable requirement as empty
# Usage: required-checks.sh --base branch [--repo owner/name]
# This preserves merge-gate.sh's branch/protection fallback semantics. Read only.
set -uo pipefail
BASE_REF="" OWNER='{owner}' REPO='{repo}'
while [[ $# -gt 0 ]]; do
  [[ $# -ge 2 ]] || exit 2
  case "$1" in
    --base) BASE_REF="$2" ;;
    --repo) OWNER="${2%%/*}"; REPO="${2#*/}" ;;
    *) exit 2 ;;
  esac
  shift 2
done
# Ref names can contain slashes and URL-reserved characters such as # and %.
BASE_PATH=$(jq -rn --arg ref "$BASE_REF" '$ref | @uri') || exit 5
REQUIRED_CONTEXTS_JSON='[]'
REQUIRED_APPS_JSON='{}'
REQUIRED_SOURCE="none"
REQUIRED_ERROR=""

# Extract the context list from either shape. Both carry `contexts`; the
# protection endpoint additionally carries `checks[].context` (the newer
# app-scoped form, which is what the UI writes today), so union them. `contexts`
# alone would miss nothing observed so far, but the union costs one line and
# fails toward listing MORE required checks, never fewer.
REQ_CTX_FILTER='
  if type == "object"
  then ((( .contexts // [] ) + [ ( .checks // [] )[]? | .context // empty ])
        | map(select(type == "string" and length > 0)) | unique)
  else [] end'

# The publisher half of the same answer (issue #1383 review). `checks[]` entries
# carry an `app_id` alongside the context, and GitHub itself will only accept a
# check from THAT app for that context — this repo pins `rule-lint` to app_id
# 15368. Matching on name alone would let a same-named check from any other
# publisher satisfy a required context, so the gate could report a pass that
# GitHub would refuse: the required app never verified HEAD. That is the same
# vacuous pass #1361 exists to close, one axis over.
#
# Kept as a SEPARATE {context: app_id} map rather than folded into the context
# list so the emitted `required_contexts.contexts` stays a plain string array.
# A null `app_id` means "any app" in GitHub's own semantics, and a context that
# arrives only via the legacy `contexts` array has no publisher to pin, so both
# are simply absent from this map and stay name-only.
REQ_APPS_FILTER='
  if type == "object"
  then ([ ( .checks // [] )[]?
          | select((.context | type) == "string" and (.context | length) > 0)
          | select(.app_id != null)
          | {key: .context, value: .app_id} ] | from_entries)
  else {} end'

BRANCH_READABLE=false
BRANCH_PROTECTED=""
BRANCH_CONTEXTS='[]'
BRANCH_APPS='{}'
if [[ -n "$BASE_REF" ]]; then
  BRANCH_JSON=$(gh api "repos/$OWNER/$REPO/branches/$BASE_PATH" 2>/dev/null || true)
  # `has("name")` is the readability sentinel: a 404/403 body is a `{message:…}`
  # object that would otherwise parse fine and read as an unprotected branch.
  if [[ -n "$BRANCH_JSON" ]] && echo "$BRANCH_JSON" | jq -e 'type == "object" and has("name")' >/dev/null 2>&1; then
    BRANCH_READABLE=true
    BRANCH_PROTECTED=$(echo "$BRANCH_JSON" | jq -r '(.protected // false) | tostring' 2>/dev/null || echo "")
    BRANCH_CONTEXTS=$(echo "$BRANCH_JSON" | jq -c ".protection.required_status_checks | $REQ_CTX_FILTER" 2>/dev/null || echo '[]')
    if [[ -z "$BRANCH_CONTEXTS" ]]; then BRANCH_CONTEXTS='[]'; fi
    BRANCH_APPS=$(echo "$BRANCH_JSON" | jq -c ".protection.required_status_checks | $REQ_APPS_FILTER" 2>/dev/null || echo '{}')
    if [[ -z "$BRANCH_APPS" ]]; then BRANCH_APPS='{}'; fi
  fi
fi

if [[ -z "$BASE_REF" ]]; then
  # No base branch name means no protection to look up. Report it rather than
  # silently skipping — this is the same class of gap #1361 is about.
  REQUIRED_SOURCE="unavailable"
  REQUIRED_ERROR="PR base branch name unavailable"
elif [[ "$BRANCH_READABLE" == true && "$BRANCH_PROTECTED" == "false" ]]; then
  # Unprotected base — there is nothing to require. Pre-#1361 behaviour, and the
  # cheap path: no protection call at all.
  REQUIRED_SOURCE="none"
else
  # stdout and stderr are captured together deliberately: on success gh writes
  # only JSON, on failure only a message, so one capture plus the exit code
  # classifies both without a temp file.
  if RSC_RAW=$(gh api "repos/$OWNER/$REPO/branches/$BASE_PATH/protection/required_status_checks" 2>&1); then
    RSC_CONTEXTS=$(printf '%s' "$RSC_RAW" | jq -c "$REQ_CTX_FILTER" 2>/dev/null || true)
    RSC_APPS=$(printf '%s' "$RSC_RAW" | jq -c "$REQ_APPS_FILTER" 2>/dev/null || true)
  else
    RSC_CONTEXTS=""
    RSC_APPS=""
  fi
  if [[ -n "$RSC_CONTEXTS" ]]; then
    REQUIRED_CONTEXTS_JSON="$RSC_CONTEXTS"
    if [[ -n "$RSC_APPS" ]]; then REQUIRED_APPS_JSON="$RSC_APPS"; else REQUIRED_APPS_JSON='{}'; fi
    REQUIRED_SOURCE="branch_protection"
  elif [[ "$BRANCH_READABLE" == true ]]; then
    # The protection endpoint refused (403, or a 404 meaning "required status
    # checks not enabled"), but the branch object answered. An empty list here
    # is a real answer, not a shrug: the branch is protected by rules that do
    # not require any status check, which is a common configuration (review-only
    # protection) and must not wedge every merge in such a repo.
    REQUIRED_CONTEXTS_JSON="$BRANCH_CONTEXTS"
    REQUIRED_APPS_JSON="$BRANCH_APPS"
    if [[ "$(echo "$REQUIRED_CONTEXTS_JSON" | jq 'length' 2>/dev/null || echo 0)" -gt 0 ]]; then
      REQUIRED_SOURCE="branch_object"
    else
      REQUIRED_SOURCE="none"
      # Protected branch + refused protection endpoint + an empty fallback list.
      # Almost always review-only protection, which genuinely requires no status
      # check — but it is the one shape where "no requirement" and "the
      # requirement is hidden from this token" look identical, so say so rather
      # than resolve it silently. Not a blocker: treating it as one would wedge
      # every merge in a review-only-protected repo, a far larger and more
      # common cost than the narrow ambiguity it would close.
      if [[ "$BRANCH_PROTECTED" == "true" ]]; then
        echo "[merge-gate] base $BASE_REF is protected but exposes no required status checks to this token (protection endpoint refused; branch object lists none). Proceeding as 'no required checks' — if this repo does require checks, the token lacks administration:read and required-context verification is not actually running (issue #1361)." >&2
      fi
    fi
  else
    REQUIRED_SOURCE="unavailable"
    REQUIRED_ERROR=$(printf '%s' "${RSC_RAW:-no response}" | tr '\n\r\t' '   ' | cut -c1-200)
  fi
fi

jq -cn --arg source "$REQUIRED_SOURCE" --arg error "$REQUIRED_ERROR" \
  --argjson contexts "$REQUIRED_CONTEXTS_JSON" --argjson apps "$REQUIRED_APPS_JSON" \
  '{source:$source,error:$error,contexts:$contexts,apps:$apps}'
