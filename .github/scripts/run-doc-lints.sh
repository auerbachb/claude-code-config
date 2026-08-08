#!/usr/bin/env bash
#
# Discover and run every standalone doc-lint script in the repo. Adding a lint
# needs NO workflow edit: drop a `*-lint.sh` file into .github/scripts/ and it
# runs automatically. This retired the per-lint step list in
# .github/workflows/rule-lint.yml that made that file a recurring
# merge-conflict hotspot (issue #1138; precedent: issue #681).
#
# Discovery:
#   .github/scripts/*-lint.sh  — standalone doc lints (minus exclusions below)
#   .claude/scripts/reference-catalog-lint.sh — lives in a separate dir by
#                                                history; included explicitly
#
# EXCLUDED from .github/scripts/ auto-discovery:
#   chip-model-guard-lint.sh       — already invoked inside rule-lint.sh
#                                    section 4; running standalone would
#                                    double-enforce the check (issue #731)
#   env-template-allowlist-lint.sh — CI wiring via hook-scripts.yml tests
#                                    (run-hook-tests.sh auto-discovery #877);
#                                    a standalone step here would double-run it
#   merge-authority-lint.sh        — CI wiring via hook-scripts.yml tests
#                                    (run-hook-tests.sh auto-discovery #753);
#                                    same reason
#
# Lint contract: exit 0 on pass / non-zero on fail; invoked via `bash` so the
# executable bit is NOT required; no positional args needed.
#
# Usage (CI or local, runnable from anywhere):
#   bash .github/scripts/run-doc-lints.sh            # human/CI folds (default)
#   bash .github/scripts/run-doc-lints.sh --json     # compact result contract
#   bash .github/scripts/run-doc-lints.sh --help
#
# --json (mirrors issue #782): emits the compact result contract from
# .claude/reference/compact-result-contract.md as the ONLY thing on stdout:
#
#   {"ok":false,"failed_tests":[".github/scripts/skill-catalog-lint.sh"],
#    "relevant_error":"skill-catalog-lint: 1 error(s) found","log_path":"/tmp/run-doc-lints-....log",
#    "total":5,"failed":1}
#
# Compact mode silences PASSING lints — that is where the savings are. Failing
# lints still print their captured output IN FULL, on stderr, because a failing
# lint must never be compacted down to a status line
# (token-efficiency-audit-2026-07.md §"What NOT to change"). The complete
# capture of every lint, pass or fail, is always written to `log_path`.
#
# Log location: $RUN_TESTS_LOG_DIR, else $RUNNER_TEMP (GitHub Actions),
# else $TMPDIR, else /tmp.
#
# Exit codes:
#   0  every discovered lint passed
#   1  one or more lints failed
#   2  usage error (unknown flag)
#   3  discovery found no lints — a glob is broken; never a silent green

# Not `set -e`: the loop deliberately runs every lint and aggregates failures
# so one red lint does not hide the rest. The final check is the exit gate.
set -uo pipefail
shopt -s nullglob

JSON=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --json) JSON=1; shift ;;
    -h|--help)
      awk 'NR == 1 { next } /^$/ { exit } { print }' "$0"
      exit 0
      ;;
    *)
      echo "::error::run-doc-lints.sh: unknown argument: $1" >&2
      exit 2
      ;;
  esac
done

# Resolve to the repo root regardless of caller cwd so the globs below resolve.
cd "$(dirname "${BASH_SOURCE[0]}")/../.." || {
  echo "::error::run-doc-lints.sh: cannot cd to repo root" >&2
  exit 1
}

LOG_DIR="${RUN_TESTS_LOG_DIR:-${RUNNER_TEMP:-${TMPDIR:-/tmp}}}"
LOG_DIR="${LOG_DIR%/}"   # $TMPDIR usually ends in / — keep log_path free of a doubled slash
mkdir -p "$LOG_DIR" 2>/dev/null || LOG_DIR="/tmp"
LOG="$LOG_DIR/run-doc-lints-$(date -u +%s)-$$.log"
: > "$LOG"

# Every human-facing line goes to stderr in --json mode so stdout stays parseable.
say() { if [ "$JSON" -eq 1 ]; then printf '%s\n' "$1" >&2; else printf '%s\n' "$1"; fi; }

LINT_OUT="$(mktemp "${TMPDIR:-/tmp}/run-doc-lints-lint-XXXXXX")"
cleanup() { rm -f "$LINT_OUT"; }
trap cleanup EXIT

# Scripts that match the *-lint.sh glob but are NOT standalone doc-lint steps.
# Each entry is a basename.  Pipe-delimited so the containment check below is
# immune to substring matches (e.g. "merge-authority" can't accidentally match
# a future "x-merge-authority-lint.sh").
EXCLUDED_BASENAMES=(
  chip-model-guard-lint.sh        # embedded in rule-lint.sh section 4 (#731)
  env-template-allowlist-lint.sh  # CI via hook-scripts.yml tests (#877)
  merge-authority-lint.sh         # CI via hook-scripts.yml tests (#753)
)

is_excluded() {
  local base="$1"
  for ex in "${EXCLUDED_BASENAMES[@]}"; do
    [[ "$base" == "$ex" ]] && return 0
  done
  return 1
}

# Collect lints: glob .github/scripts/ then add the explicit extra path.
lints=()
for f in .github/scripts/*-lint.sh; do
  base="$(basename "$f")"
  is_excluded "$base" && continue
  lints+=("$f")
done

# .claude/scripts/reference-catalog-lint.sh lives in a different directory by
# history (Issue #950).  Include it explicitly so it remains auto-run without
# needing a step in the workflow.
EXTRA=".claude/scripts/reference-catalog-lint.sh"
if [[ -f "$EXTRA" ]]; then
  lints+=("$EXTRA")
fi

# Stable lexicographic order so the CI log is reproducible.
# Use ${lints[@]+"${lints[@]}"} to handle empty array under set -u.
if [ "${#lints[@]}" -gt 0 ]; then
  IFS=$'\n' lints=($(printf '%s\n' "${lints[@]}" | LC_ALL=C sort -u))
  unset IFS
fi

failed=0
total="${#lints[@]}"
FAILED_LIST=""
RELEVANT=""

for lint in ${lints[@]+"${lints[@]}"}; do
  rc=0
  bash "$lint" >"$LINT_OUT" 2>&1 || rc=$?

  # Full capture always reaches the log, pass or fail, in both modes.
  {
    printf '===== %s (rc=%s) =====\n' "$lint" "$rc"
    cat "$LINT_OUT"
    printf '\n'
  } >> "$LOG"

  if [ "$rc" -eq 0 ]; then
    if [ "$JSON" -eq 0 ]; then
      printf '::group::%s\n' "$lint"
      cat "$LINT_OUT"
      printf 'PASS: %s\n' "$lint"
      printf '::endgroup::\n'
    fi
  else
    # Failures print in full in BOTH modes — compaction never hides a red lint.
    if [ "$JSON" -eq 0 ]; then
      printf '::group::%s\n' "$lint"
      cat "$LINT_OUT"
      printf '::endgroup::\n'
      printf '::error::FAIL (rc=%s): %s\n' "$rc" "$lint"
    else
      {
        printf '::group::FAIL %s (rc=%s)\n' "$lint" "$rc"
        cat "$LINT_OUT"
        printf '::endgroup::\n'
      } >&2
    fi
    failed=$((failed + 1))
    FAILED_LIST="${FAILED_LIST}${lint}"$'\n'
    # relevant_error: decisive line(s) from THIS lint's capture only.
    RELEVANT="${RELEVANT}$(awk -v s="$lint" '
        /^::error::/ || /^(FAIL|ERROR)[: ]/ || /[0-9]+ error\(s\) found/ || / error(s) found$/ {
          print s ": " $0
          if (++n >= 3) exit
        }' "$LINT_OUT" 2>/dev/null)"$'\n'
  fi
done

say "$(printf '\nDiscovered and ran %s doc-lint script(s); %s failed.\nFull output: %s' \
  "$total" "$failed" "$LOG")"

# Fail loud if discovery found nothing — a silently-empty run must never pass
# green and masquerade as "all lints passed" (precedent: issue #681).
if [ "$total" -eq 0 ]; then
  if [ "$JSON" -eq 1 ]; then
    jq -cn --arg log "$LOG" \
      '{ok: false, failed_tests: [], relevant_error: "run-doc-lints.sh discovered no lint scripts — a glob is broken", log_path: $log, total: 0, failed: 0}'
  fi
  echo "::error::run-doc-lints.sh discovered no lint scripts — a glob is broken" >&2
  exit 3
fi

if [ "$JSON" -eq 1 ]; then
  # Cap per the contract — relevant_error indexes the failure, log_path holds it all.
  RELEVANT="$(printf '%s' "$RELEVANT" | sed '/^$/d' \
    | awk 'NR <= 20 { print } NR == 21 { print "… (truncated; see log_path)"; exit }' | cut -c1-2000)"
  # A lint can fail without printing any recognized marker (e.g. a bare non-zero
  # exit). Naming it is still better than a null error.
  [ -n "$RELEVANT" ] || RELEVANT="$(printf '%s' "$FAILED_LIST" | sed '/^$/d' | sed 's/^/failed lint: /' | head -n 20)"
  jq -cn \
    --argjson ok "$( [ "$failed" -eq 0 ] && echo true || echo false )" \
    --arg failed_list "$FAILED_LIST" \
    --arg relevant "$RELEVANT" \
    --arg log "$LOG" \
    --argjson total "$total" \
    --argjson failed "$failed" \
    '{ok: $ok,
      failed_tests: ($failed_list | split("\n") | map(select(length > 0))),
      relevant_error: (if $relevant == "" then null else $relevant end),
      log_path: $log, total: $total, failed: $failed}'
fi

[ "$failed" -eq 0 ]
