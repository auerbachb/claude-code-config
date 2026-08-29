#!/usr/bin/env bash
# unset-home-contract.test.sh — the shared unset-HOME contract (issue #1434).
#
# Issue #1430 (PR #1433) guarded the usage-telemetry append so it could never
# abort a script. In four scripts the NEXT unconditional ${HOME} expansion still
# aborted a HOME-less invocation under `set -u`, before any cheap path could
# answer. The contract those four now share:
#
#   1. --help answers without HOME       — exit 0, empty stderr.
#   2. A run that genuinely needs ~/.claude fails NAMED — exit 8, exactly one
#      stderr line, never a bash `unbound variable` trace.
#   3. No ${HOME:-<default>} fallback fabricates a path. Defaulting to empty
#      would produce root-anchored /.claude/... paths — the stray-file hazard
#      issue #1430 removed — so every load-bearing site fails fast instead.
#
# Covered here for all four scripts. session-state.sh's own suite carries the
# deeper per-mode probes (--repo-key, --set, usage errors) that PR #1433 had
# pinned to the OLD behavior and issue #1434 deliberately rewrote.
#
# Requires jq (reviewer-of.sh and silence-watchdog.sh check for it). Run from
# anywhere: bash .claude/scripts/tests/unset-home-contract.test.sh
#
# Discovered by CI auto-detection (hook-scripts.yml) — no workflow edits needed.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPTS="${SCRIPT_DIR}/.."

REVIEWER_OF="${SCRIPTS}/reviewer-of.sh"
SESSION_STATE="${SCRIPTS}/session-state.sh"
WATCHDOG="${SCRIPTS}/silence-watchdog.sh"
USAGE_REPORT="${SCRIPTS}/script-usage-report.sh"

TMP_ROOT="$(mktemp -d)"
cleanup() { rm -rf "$TMP_ROOT"; }
trap cleanup EXIT

PASS=0
FAIL=0
check_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [[ "$actual" == "$expected" ]]; then
    PASS=$((PASS + 1)); echo "ok   — $desc"
  else
    FAIL=$((FAIL + 1)); echo "FAIL — $desc (expected '$expected', got '$actual')"
  fi
}

# Fail closed rather than skipping: a precondition that quietly removes
# assertions is a guard that passes by not running.
if ! command -v jq >/dev/null 2>&1; then
  echo "FAILURE: jq is required by this suite but was not found on PATH"
  exit 1
fi

# Count non-empty lines. `printf` (not echo) so a leading dash in the captured
# text is never read as an option.
line_count() { printf '%s\n' "$1" | grep -c .; }

# --- assertion 1: --help answers with no HOME at all -------------------------
# `env -u HOME` removes the variable entirely, which is what makes `set -u`
# fire — distinct from HOME set to a nonexistent directory (covered for
# session-state.sh in its own suite).
assert_help_answers() {
  local label="$1"; shift
  local rc=0 err out
  err="$(env -u HOME bash "$@" --help 2>&1 >/dev/null)" || rc=$?
  check_eq "$label: --help exits 0 without HOME" "0" "$rc"
  check_eq "$label: --help writes nothing to stderr" "" "$err"
  rc=0
  out="$(env -u HOME bash "$@" --help 2>/dev/null)" || rc=$?
  check_eq "$label: --help actually prints usage text" "1" \
    "$([[ -n "$out" ]] && echo 1 || echo 0)"
}

# --- assertion 2: a HOME-requiring run fails named, with exit 8 --------------
assert_named_home_failure() {
  local label="$1" pattern="$2"; shift 2
  local rc=0 err
  err="$(env -u HOME "$@" 2>&1 >/dev/null)" || rc=$?
  check_eq "$label: exits 8 (documented HOME-unset code)" "8" "$rc"
  check_eq "$label: emits the named error line" "1" \
    "$(grep -c -- "$pattern" <<<"$err")"
  check_eq "$label: emits exactly one stderr line" "1" "$(line_count "$err")"
  check_eq "$label: no bash unbound-variable trace" "0" \
    "$(grep -c 'unbound variable' <<<"$err")"
}

echo "== AC1: env -u HOME <script> --help exits 0 with empty stderr =="
assert_help_answers "reviewer-of.sh"        "$REVIEWER_OF"
assert_help_answers "session-state.sh"      "$SESSION_STATE"
assert_help_answers "silence-watchdog.sh"   "$WATCHDOG"
assert_help_answers "script-usage-report.sh" "$USAGE_REPORT"

echo
echo "== AC2: HOME-requiring runs fail with a documented code and one named line =="
# reviewer-of.sh: any PR lookup opens ~/.claude/session-state.json. The guard
# sits above every network call, so this never reaches gh.
assert_named_home_failure "reviewer-of.sh 123" \
  'reviewer-of.sh: HOME is unset; cannot resolve ~/.claude/session-state.json' \
  bash "$REVIEWER_OF" 123

assert_named_home_failure "session-state.sh --get" \
  'session-state.sh: HOME is unset; cannot resolve ~/.claude/session-state.json' \
  bash "$SESSION_STATE" --get '.active_agents'

# script-usage-report.sh: the guard sits above the python3 heredoc that reads
# the two ~/.claude logs, so this needs no python3 either.
assert_named_home_failure "script-usage-report.sh (full run)" \
  'script-usage-report.sh: HOME is unset; cannot read ~/.claude logs' \
  bash "$USAGE_REPORT"

# silence-watchdog.sh: only when the explicit override is absent too.
# CLAUDE_WATCHDOG_FORCE_RUN=1 bypasses the Darwin-only guard, which now sits
# ABOVE this one so a non-Darwin host keeps its documented exit-0 no-op with
# no HOME. Without the override this assertion would pass vacuously on Linux.
assert_named_home_failure "silence-watchdog.sh (no LOG_DIR override)" \
  'HOME is unset and CLAUDE_WATCHDOG_LOG_DIR is not set; cannot resolve ~/.claude/logs' \
  env CLAUDE_WATCHDOG_FORCE_RUN=1 bash "$WATCHDOG"

echo
echo "== silence-watchdog.sh: CLAUDE_WATCHDOG_LOG_DIR makes HOME unnecessary =="
# The override is the whole point of the guard's two-condition shape: with a log
# dir supplied, a full sweep must complete with no HOME at all. Bounded by an
# empty marker directory — no heartbeat files, so the loop body never runs and
# notify() (osascript) is never reached.
WD_LOG_DIR="$TMP_ROOT/wd-logs"
WD_MARKERS="$TMP_ROOT/wd-markers"
mkdir -p "$WD_MARKERS"
WD_RC=0
WD_ERR="$(env -u HOME \
  CLAUDE_WATCHDOG_LOG_DIR="$WD_LOG_DIR" \
  CLAUDE_BGWORK_MARKER_DIR="$WD_MARKERS" \
  CLAUDE_WATCHDOG_FORCE_RUN=1 \
  bash "$WATCHDOG" 2>&1 >/dev/null)" || WD_RC=$?
check_eq "sweep with LOG_DIR override exits 0 without HOME" "0" "$WD_RC"
check_eq "sweep with LOG_DIR override never hits unbound HOME" "0" \
  "$(grep -c 'unbound variable' <<<"$WD_ERR")"
check_eq "sweep with LOG_DIR override wrote its state file" "1" \
  "$([[ -f "$WD_LOG_DIR/watchdog-state.json" ]] && echo 1 || echo 0)"

echo
echo "== AC3: no \${HOME:-...} fallback fabricates a root-anchored path =="
# Two banned shapes, both of which would put real files under /.claude/:
#   ${HOME:-/tmp}/...  — any non-empty default silently relocates state
#   ${HOME:-}/...      — an empty default yields a root-anchored /.claude/...
# The bare `${HOME:-}` used INSIDE a [[ -n ]] / [[ -z ]] test builds no path and
# stays allowed; that is what the trailing-slash half of this check permits.
GUARDED_SCRIPTS=("$REVIEWER_OF" "$SESSION_STATE" "$WATCHDOG" "$USAGE_REPORT")
for f in "${GUARDED_SCRIPTS[@]}"; do
  base="$(basename "$f")"
  check_eq "$base: no \${HOME:-<default>} anywhere" "0" \
    "$(grep -c '\${HOME:-[^}]' "$f")"
  check_eq "$base: no \${HOME:-} used as a path prefix" "0" \
    "$(grep -c '\${HOME:-}/' "$f")"
done

echo
echo "== summary: $PASS passed, $FAIL failed =="
if [[ "$FAIL" -eq 0 ]]; then
  echo "OK: unset-HOME contract tests passed"
  exit 0
else
  echo "FAILURE: $FAIL unset-HOME contract test(s) failed"
  exit 1
fi
