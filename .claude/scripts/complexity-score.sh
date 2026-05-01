#!/usr/bin/env bash
# complexity-score.sh — PR complexity score for issue #362 auto-triggers.
#
# Formula (documented in `.claude/rules/cr-github-review.md`):
#   score = additions + deletions + (file_weight × changedFiles)
#
# Default file_weight=5 matches calibration on this repo (merged PRs sample);
# override via `.claude/pm-config.md` section **Complexity triggers** (`FILE_WEIGHT=N`)
# or env `COMPLEXITY_FILE_WEIGHT`.
#
# Usage:
#   complexity-score.sh <pr_number> [--json]
#   complexity-score.sh --help | -h
#
# Exit: 0 OK, 2 usage, 3 PR not found, 4 gh/jq error

set -euo pipefail
printf '%s\t%s\t%s\n' "$(date -u +%FT%TZ)" "$(basename "$0")" "${*//$'\n'/ }" >> "$HOME/.claude/script-usage.log" 2>/dev/null || true

help() {
  sed -n '2,25p' "$0" | sed 's/^# \{0,1\}//'
}

PR_NUM=""
JSON_OUT=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help) help; exit 0 ;;
    --json) JSON_OUT=1; shift ;;
    -*)
      echo "complexity-score.sh: unknown flag: $1" >&2
      exit 2
      ;;
    *)
      if [[ -n "$PR_NUM" ]]; then
        echo "complexity-score.sh: unexpected argument: $1" >&2
        exit 2
      fi
      PR_NUM="$1"
      shift
      ;;
  esac
done

if [[ -z "$PR_NUM" ]] || ! [[ "$PR_NUM" =~ ^[1-9][0-9]*$ ]]; then
  echo "usage: complexity-score.sh <pr_number> [--json]" >&2
  exit 2
fi

if ! command -v gh >/dev/null 2>&1 || ! command -v jq >/dev/null 2>&1; then
  echo "complexity-score.sh: requires gh and jq" >&2
  exit 4
fi

FILE_WEIGHT=5

# Optional: read FILE_WEIGHT from repo .claude/pm-config.md (Complexity triggers section)
REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || true)"
PM_CFG=""
[[ -n "$REPO_ROOT" && -f "$REPO_ROOT/.claude/pm-config.md" ]] && PM_CFG="$REPO_ROOT/.claude/pm-config.md"
if [[ -n "$PM_CFG" ]]; then
  section=$(awk '/^## Complexity triggers/,/^## / { if (/^## Complexity triggers/) next; if (/^## /) exit; print }' "$PM_CFG" 2>/dev/null || true)
  if [[ -n "$section" ]]; then
    line=$(echo "$section" | grep -E '^[[:space:]]*FILE_WEIGHT[[:space:]]*=' | head -1 || true)
    if [[ -n "$line" ]]; then
      val="${line#*=}"
      val="${val// /}"
      val="${val//$'\t'/}"
      if [[ "$val" =~ ^[1-9][0-9]*$ ]]; then
        FILE_WEIGHT="$val"
      fi
    fi
  fi
fi

# Env wins when set (explicit override for CI / one-off tuning).
if [[ "${COMPLEXITY_FILE_WEIGHT+set}" == "set" ]] && [[ "${COMPLEXITY_FILE_WEIGHT}" =~ ^[1-9][0-9]*$ ]]; then
  FILE_WEIGHT="$COMPLEXITY_FILE_WEIGHT"
fi

STDERR_TMP="$(mktemp)"
if ! META="$(gh pr view "$PR_NUM" --json additions,deletions,changedFiles 2>"$STDERR_TMP")"; then
  if grep -qiE 'not.?found|could not resolve|no pull requests? found' "$STDERR_TMP"; then
    rm -f "$STDERR_TMP"
    echo "complexity-score.sh: PR #$PR_NUM not found" >&2
    exit 3
  fi
  cat "$STDERR_TMP" >&2
  rm -f "$STDERR_TMP"
  exit 4
fi
rm -f "$STDERR_TMP"

ADD=$(printf '%s' "$META" | jq -r '.additions')
DEL=$(printf '%s' "$META" | jq -r '.deletions')
FILES=$(printf '%s' "$META" | jq -r '.changedFiles')
SCORE=$(( ADD + DEL + FILE_WEIGHT * FILES ))

if (( JSON_OUT )); then
  jq -n \
    --argjson score "$SCORE" \
    --argjson additions "$ADD" \
    --argjson deletions "$DEL" \
    --argjson changedFiles "$FILES" \
    --argjson fileWeight "$FILE_WEIGHT" \
    '{
      score: $score,
      additions: $additions,
      deletions: $deletions,
      changedFiles: $changedFiles,
      file_weight: $fileWeight,
      formula: "additions + deletions + file_weight * changedFiles"
    }'
else
  printf '%s\n' "$SCORE"
fi
exit 0
