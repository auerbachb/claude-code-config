#!/usr/bin/env bash
# catalog: tests — Runs all quota-reader assertions in isolated fixture groups under a whole-suite deadline; missing fakes fail before reader launch
set -uo pipefail
unset BASH_ENV ENV
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
TEST_FILE="$ROOT/.claude/scripts/tests/ai-quotas.test.sh"
CASE_DIR="$ROOT/.claude/scripts/tests/lib/ai-quotas-cases"
GROUPS_LIST="core acceptance failure-isolation renewal renewal-files cursor cursor-identity codex codex-duration row-shape codex-cleanup overage credential-output history snapshot-footer nicknames table forecast forecast-failures forecast-types history-errors reset-credits outcomes outcomes-protocol outcomes-preflight layout fallback browser-resume recommendations notifications"
case "${1:-}" in
  --fixture-worker)
    FIXTURE_GROUP="${2:-}"
    case "$FIXTURE_GROUP" in core|acceptance|failure-isolation|renewal|renewal-files|cursor|cursor-identity|codex|codex-duration|row-shape|codex-cleanup|overage|credential-output|history|snapshot-footer|nicknames|table|forecast|forecast-failures|forecast-types|history-errors|reset-credits|outcomes|outcomes-protocol|outcomes-preflight|layout|fallback|browser-resume|recommendations|notifications) ;; *) echo 'FAIL — unknown quota fixture group' >&2; exit 2 ;; esac
    echo "== quota fixture group: $FIXTURE_GROUP =="
    # Every group sources the same fixture module before its original cases.
    load_fixture_group() {
      case "$FIXTURE_GROUP" in
        core)
          # shellcheck source=lib/ai-quotas-cases/core.bash
          source "$CASE_DIR/core.bash" ;;
        acceptance)
          # shellcheck source=lib/ai-quotas-cases/acceptance.bash
          source "$CASE_DIR/acceptance.bash" ;;
        failure-isolation)
          # shellcheck source=lib/ai-quotas-cases/failure-isolation.bash
          source "$CASE_DIR/failure-isolation.bash" ;;
        renewal)
          # shellcheck source=lib/ai-quotas-cases/renewal.bash
          source "$CASE_DIR/renewal.bash" ;;
        renewal-files)
          # shellcheck source=lib/ai-quotas-cases/renewal-files.bash
          source "$CASE_DIR/renewal-files.bash" ;;
        cursor)
          # shellcheck source=lib/ai-quotas-cases/cursor.bash
          source "$CASE_DIR/cursor.bash" ;;
        cursor-identity)
          # shellcheck source=lib/ai-quotas-cases/cursor-identity.bash
          source "$CASE_DIR/cursor-identity.bash" ;;
        codex)
          # shellcheck source=lib/ai-quotas-cases/codex.bash
          source "$CASE_DIR/codex.bash" ;;
        codex-duration)
          # shellcheck source=lib/ai-quotas-cases/codex-duration.bash
          source "$CASE_DIR/codex-duration.bash" ;;
        row-shape)
          # shellcheck source=lib/ai-quotas-cases/row-shape.bash
          source "$CASE_DIR/row-shape.bash" ;;
        codex-cleanup)
          # shellcheck source=lib/ai-quotas-cases/codex-cleanup.bash
          source "$CASE_DIR/codex-cleanup.bash" ;;
        overage)
          # shellcheck source=lib/ai-quotas-cases/overage.bash
          source "$CASE_DIR/overage.bash" ;;
        credential-output)
          # shellcheck source=lib/ai-quotas-cases/credential-output.bash
          source "$CASE_DIR/credential-output.bash" ;;
        history)
          # shellcheck source=lib/ai-quotas-cases/history.bash
          source "$CASE_DIR/history.bash" ;;
        snapshot-footer)
          # shellcheck source=lib/ai-quotas-cases/snapshot-footer.bash
          source "$CASE_DIR/snapshot-footer.bash" ;;
        nicknames)
          # shellcheck source=lib/ai-quotas-cases/nicknames.bash
          source "$CASE_DIR/nicknames.bash" ;;
        table)
          # shellcheck source=lib/ai-quotas-cases/table.bash
          source "$CASE_DIR/table.bash" ;;
        forecast)
          # shellcheck source=lib/ai-quotas-cases/forecast.bash
          source "$CASE_DIR/forecast.bash" ;;
        forecast-failures)
          # shellcheck source=lib/ai-quotas-cases/forecast-failures.bash
          source "$CASE_DIR/forecast-failures.bash" ;;
        forecast-types)
          # shellcheck source=lib/ai-quotas-cases/forecast-types.bash
          source "$CASE_DIR/forecast-types.bash" ;;
        history-errors)
          # shellcheck source=lib/ai-quotas-cases/history-errors.bash
          source "$CASE_DIR/history-errors.bash" ;;
        reset-credits)
          # shellcheck source=lib/ai-quotas-cases/reset-credits.bash
          source "$CASE_DIR/reset-credits.bash" ;;
        outcomes)
          # shellcheck source=lib/ai-quotas-cases/outcomes.bash
          source "$CASE_DIR/outcomes.bash" ;;
        outcomes-protocol)
          # shellcheck source=lib/ai-quotas-cases/outcomes-protocol.bash
          source "$CASE_DIR/outcomes-protocol.bash" ;;
        outcomes-preflight)
          # shellcheck source=lib/ai-quotas-cases/outcomes-preflight.bash
          source "$CASE_DIR/outcomes-preflight.bash" ;;
        layout)
          # shellcheck source=lib/ai-quotas-cases/layout.bash
          source "$CASE_DIR/layout.bash" ;;
        fallback)
          # shellcheck source=lib/ai-quotas-cases/fallback.bash
          source "$CASE_DIR/fallback.bash" ;;
        browser-resume)
          # shellcheck source=lib/ai-quotas-cases/browser-resume.bash
          source "$CASE_DIR/browser-resume.bash" ;;
        recommendations)
          # shellcheck source=lib/ai-quotas-cases/recommendations.bash
          source "$CASE_DIR/recommendations.bash" ;;
        notifications)
          # shellcheck source=lib/ai-quotas-cases/notifications.bash
          source "$CASE_DIR/notifications.bash" ;;
        *) return 2 ;;
      esac
    }
    if ! load_fixture_group; then
      echo "FAIL — quota fixture group could not run: $FIXTURE_GROUP" >&2; exit 1
    fi
    if (( PASS + FAILED == 0 )); then echo "FAIL — no assertions in $FIXTURE_GROUP" >&2; exit 1; fi
    printf 'AI_QUOTAS_RESULT:%s:%s\n' "$PASS" "$FAILED"
    [[ "$FAILED" -eq 0 ]]
    exit "$?" ;;
  --fixture-batch)
    BATCH_TMP=$(mktemp -d) || exit 1
    trap 'rm -rf -- "$BATCH_TMP"' EXIT
    PIDS=(); BATCH_RC=0; BATCH_PASS=0; BATCH_FAILED=0; COMPLETED=0
    dump_groups() {
      local group
      for group in $GROUPS_LIST; do
        [[ ! -f "$BATCH_TMP/$group.log" ]] || cat "$BATCH_TMP/$group.log"
      done
    }
    trap 'dump_groups; echo "FAIL — quota fixture groups interrupted" >&2; exit 143' TERM INT
    for FIXTURE_GROUP in $GROUPS_LIST; do
      echo "START quota fixture group: $FIXTURE_GROUP"
      "$BASH" "$TEST_FILE" --fixture-worker "$FIXTURE_GROUP" >"$BATCH_TMP/$FIXTURE_GROUP.log" 2>&1 &
      PIDS+=("$!")
    done
    for FIXTURE_PID in ${PIDS[@]+"${PIDS[@]}"}; do wait "$FIXTURE_PID" || BATCH_RC=1; done
    dump_groups
    for FIXTURE_GROUP in $GROUPS_LIST; do
      RESULT=$(tail -n 1 "$BATCH_TMP/$FIXTURE_GROUP.log")
      if [[ "$RESULT" =~ ^AI_QUOTAS_RESULT:([0-9]+):([0-9]+)$ ]]; then
        BATCH_PASS=$((BATCH_PASS + BASH_REMATCH[1])); BATCH_FAILED=$((BATCH_FAILED + BASH_REMATCH[2])); COMPLETED=$((COMPLETED + 1))
      else
        echo "FAIL — quota fixture group did not complete: $FIXTURE_GROUP" >&2
        BATCH_RC=1
      fi
    done
    echo "passed: $BATCH_PASS   failed: $BATCH_FAILED   completed groups: $COMPLETED/30"
    [[ "$BATCH_FAILED" -eq 0 && "$COMPLETED" -eq 30 ]] || BATCH_RC=1
    exit "$BATCH_RC" ;;
esac
SUITE_BOUND_LIB="$ROOT/.claude/scripts/lib/bounded-run.sh"
[[ -r "$SUITE_BOUND_LIB" ]] || { echo 'FAIL — quota suite bound helper missing' >&2; exit 1; }
# shellcheck source=../lib/bounded-run.sh
source "$SUITE_BOUND_LIB" || exit 1
SUITE_TMP=$(mktemp -d) || exit 1
CAPTURE="$SUITE_TMP/stdout"; CAPTURE_ERR="$SUITE_TMP/stderr"
trap 'rm -rf -- "$SUITE_TMP"' EXIT
# The requested sub-minute ceiling applies to native Bash 3.x. Current Bash
# CI runners may have fewer cores; retain every assertion with a finite bound.
SUITE_BUDGET=180
if (( BASH_VERSINFO[0] <= 3 )); then SUITE_BUDGET=52; fi
SUITE_RC=0
run_bounded "$SUITE_BUDGET" "$BASH" "$TEST_FILE" --fixture-batch || SUITE_RC=$?
cat "$CAPTURE"
cat "$CAPTURE_ERR" >&2
if [[ "${BOUNDED_CLOCK_UNREADABLE:-0}" == 1 ]]; then
  echo 'FAIL — quota fixture suite aborted: deadline clock unavailable' >&2; exit 1
elif [[ "${BOUNDED_TIMED_OUT:-0}" == 1 ]]; then
  echo "FAIL — quota fixture suite exceeded its ${SUITE_BUDGET}s budget" >&2; exit 1
fi
exit "$SUITE_RC"
