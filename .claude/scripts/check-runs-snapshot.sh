#!/usr/bin/env bash
# check-runs-snapshot.sh — Exact-HEAD checks plus workflow inventory (Issue 2316).
# catalog: merge-gate-sequencing — Read workflow-scoped check evidence without masking queued workflows
# Usage: check-runs-snapshot.sh --head SHA [--repo owner/name]
# Output: enriched check-run array; errors fail closed. No mutations or reviews.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HEAD_SHA="" REPO='{owner}/{repo}'
while [[ $# -gt 0 ]]; do
  [[ $# -ge 2 ]] || { echo 'snapshot argument requires a value' >&2; exit 2; }
  case "$1" in
    --head) HEAD_SHA="$2" ;;
    --repo) REPO="$2" ;;
    *) echo 'unknown snapshot argument' >&2; exit 2 ;;
  esac
  shift 2
done
[[ -n "$HEAD_SHA" ]] || { echo 'snapshot HEAD is required' >&2; exit 2; }
if [[ ! "$HEAD_SHA" =~ ^[0-9a-fA-F]{40}$ ]]; then
  HEAD_SHA="$(gh api "repos/$REPO/commits/$HEAD_SHA" --jq '.sha' 2>/dev/null)" || { echo 'snapshot HEAD unavailable' >&2; exit 5; }
fi
[[ "$HEAD_SHA" =~ ^[0-9a-fA-F]{40}$ ]] || { echo 'invalid snapshot HEAD' >&2; exit 5; }
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
# Inventory is fetched after jobs: a newly queued workflow is represented even
# when its downstream aggregate check has not been created yet.
if ! gh api --paginate "repos/$REPO/commits/$HEAD_SHA/check-runs?per_page=100" >"$TMP/checks.json" 2>"$TMP/checks.err"; then
  if grep -qiE 'HTTP 404|Not Found|No commit found for SHA' "$TMP/checks.err"; then
    echo 'commit checks unavailable (HTTP 404)' >&2; exit 4
  fi
  echo 'check snapshot unavailable' >&2; exit 5
fi
if ! gh api --paginate "repos/$REPO/actions/runs?head_sha=$HEAD_SHA&per_page=100" >"$TMP/workflows.json" 2>/dev/null; then
  echo 'workflow snapshot unavailable' >&2; exit 5
fi
python3 "$SCRIPT_DIR/lib/check_run_workflows.py" "$TMP/checks.json" "$TMP/workflows.json" "$HEAD_SHA" |
  "$SCRIPT_DIR/check-runs-dedup.sh"
