#!/usr/bin/env bash
# local-review.test.sh — Offline unit tests for local-review.sh (issue #782).
#
# Fully offline: every CLI is a stub script driven through --bin, so no network, no
# real coderabbit/codeant invocation, and no dependence on which CLIs are installed
# on the runner. Stubs never forward through `command -v` (that self-recurses when a
# stub shadows the real name on PATH — memory: subagent-ops / test-stub recursion).
#
# Run from repo root: bash .claude/scripts/tests/local-review.test.sh
set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
SUT="$REPO_ROOT/.claude/scripts/local-review.sh"

TMP="$(mktemp -d)"
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

# The script appends to $HOME/.claude/script-usage.log; point it at the sandbox.
export HOME="$TMP/home"; mkdir -p "$HOME/.claude"
LOGS="$TMP/logs"; mkdir -p "$LOGS"
STUBS="$TMP/stubs"; mkdir -p "$STUBS"

PASS=0
FAIL=0
ok()  { echo "PASS: $1"; PASS=$((PASS + 1)); }
bad() { echo "FAIL: $1" >&2; FAIL=$((FAIL + 1)); }

check_eq() { # expected actual label
  if [[ "$1" == "$2" ]]; then ok "$3"; else bad "$3 (expected: $1, got: $2)"; fi
}

# make_stub <name> <stdout-heredoc-file-or-empty> <stderr-text> <exit-code>
make_stub() { # name stdout_payload stderr_payload exit_code
  local name="$1" out="$2" err="$3" rc="$4"
  local path="$STUBS/$name"
  {
    echo '#!/usr/bin/env bash'
    printf 'cat <<%s\n%s\n%s\n' "'STUB_STDOUT_EOF'" "$out" "STUB_STDOUT_EOF"
    printf 'cat >&2 <<%s\n%s\n%s\n' "'STUB_STDERR_EOF'" "$err" "STUB_STDERR_EOF"
    printf 'exit %s\n' "$rc"
  } > "$path"
  chmod +x "$path"
  echo "$path"
}

OUT=""
RC=0
run() { OUT="$("$SUT" "$@" --log-dir "$LOGS" 2>/dev/null)"; RC=$?; }
field() { printf '%s' "$OUT" | jq -r "$1"; }

# --------------------------------------------------------------------------
# 1. Usage errors — exit 2, nothing runs.
# --------------------------------------------------------------------------
"$SUT" >/dev/null 2>&1; check_eq 2 "$?" "no --tool exits 2"
"$SUT" --tool nope >/dev/null 2>&1; check_eq 2 "$?" "unknown tool exits 2"
"$SUT" --tool coderabbit --scope sideways >/dev/null 2>&1; check_eq 2 "$?" "unknown scope exits 2"
"$SUT" --tool coderabbit --format yaml >/dev/null 2>&1; check_eq 2 "$?" "unknown format exits 2"
"$SUT" --tool coderabbit --timeout abc >/dev/null 2>&1; check_eq 2 "$?" "non-integer timeout exits 2"

# --------------------------------------------------------------------------
# 2. Command construction — the scope flags differ per CLI.
# --------------------------------------------------------------------------
check_eq "coderabbit review --agent --type all" \
  "$("$SUT" --tool coderabbit --print-cmd)" "CR default scope maps to --type all"
check_eq "coderabbit review --agent --type uncommitted --base develop" \
  "$("$SUT" --tool coderabbit --scope uncommitted --base develop --print-cmd)" "CR scope + base pass through"
check_eq "codeant review --all --headless" \
  "$("$SUT" --tool codeant --print-cmd)" "CodeAnt default scope maps to --all"
check_eq "codeant review --committed --headless" \
  "$("$SUT" --tool codeant --scope committed --print-cmd)" "CodeAnt committed scope"

# --------------------------------------------------------------------------
# 3. Binary absent — the #819 not-installed state.
# --------------------------------------------------------------------------
run --tool codeant --bin "$STUBS/definitely-not-here"
check_eq 5 "$RC" "missing binary exits 5"
check_eq "not_installed" "$(field .failure_mode)" "missing binary reports not_installed"
check_eq "false" "$(field .verified_run)" "missing binary is not a verified run"

# --------------------------------------------------------------------------
# 4. CodeAnt — the false-clean family. Every one of these exits 0 from the CLI
#    with a clean-looking stdout; none may be read as a clean pass.
# --------------------------------------------------------------------------
CA_CLEAN='{"issues": [], "meta": {"capped": false, "skipped": [], "reviewed_files": ["a.sh"]}, "error": null, "noFiles": false}'

# 4a. stderr API error, stdout says {"issues":[]} — the canonical #642 false-clean.
BIN="$(make_stub codeant-403 "$CA_CLEAN" 'API Error: Access denied (403). Please run `codeant logout`...' 0)"
run --tool codeant --bin "$BIN"
check_eq 3 "$RC" "CodeAnt stderr API Error exits 3"
check_eq "stderr_error" "$(field .failure_mode)" "CodeAnt 403 reports stderr_error"
check_eq "false" "$(field .ok)" "CodeAnt 403 is not ok"
check_eq "false" "$(field .verified_run)" "CodeAnt 403 is not a verified run"
if printf '%s' "$OUT" | jq -e '.relevant_error | test("403")' >/dev/null; then
  ok "CodeAnt 403 relevant_error carries the decisive line"
else bad "CodeAnt 403 relevant_error missing the 403 text"; fi

# 4b. noFiles — reviewed nothing. Usually a wrong-directory tell.
BIN="$(make_stub codeant-nofiles '{"issues": [], "meta": null, "error": null, "noFiles": true}' '' 0)"
run --tool codeant --bin "$BIN"
check_eq 3 "$RC" "CodeAnt noFiles exits 3"
check_eq "no_changes_reviewed" "$(field .failure_mode)" "CodeAnt noFiles reports no_changes_reviewed"

# 4c. 15-file cap — partial coverage is not coverage.
BIN="$(make_stub codeant-capped \
  '{"issues": [], "meta": {"capped": true, "skipped": ["x.sh","y.sh"], "max_files": 15}, "error": null, "noFiles": false}' '' 0)"
run --tool codeant --bin "$BIN"
check_eq 3 "$RC" "CodeAnt capped run exits 3"
check_eq "capped" "$(field .failure_mode)" "CodeAnt capped reports capped"

# 4d. The result object's own error field.
BIN="$(make_stub codeant-errfield '{"issues": [], "meta": null, "error": "socket hang up", "noFiles": false}' '' 0)"
run --tool codeant --bin "$BIN"
check_eq 3 "$RC" "CodeAnt error field exits 3"
check_eq "stderr_error" "$(field .failure_mode)" "CodeAnt error field reports stderr_error"

# 4e. Unparseable stdout — the run died before printing its result object.
BIN="$(make_stub codeant-garbage 'Segmentation fault' 'boom' 1)"
run --tool codeant --bin "$BIN"
check_eq 3 "$RC" "CodeAnt unparseable stdout exits 3"
check_eq "no_review_records" "$(field .failure_mode)" "CodeAnt unparseable stdout reports no_review_records"

# 4f. Genuinely clean.
BIN="$(make_stub codeant-clean "$CA_CLEAN" '[files] Reviewing 1 file(s)' 0)"
run --tool codeant --bin "$BIN"
check_eq 0 "$RC" "CodeAnt clean run exits 0"
check_eq "true" "$(field .ok)" "CodeAnt clean run is ok"
check_eq "true" "$(field .verified_run)" "CodeAnt clean run is verified"
check_eq "null" "$(field .failure_mode)" "CodeAnt clean run has no failure_mode"
check_eq "null" "$(field .relevant_error)" "CodeAnt clean run has null relevant_error"
check_eq "0" "$(field .findings)" "CodeAnt clean run reports 0 findings"
check_eq "[]" "$(field '.failed_tests | tojson')" "non-test pipeline reports empty failed_tests"

# 4g. Findings present — a verified run, but not a clean pass.
BIN="$(make_stub codeant-findings \
  '{"issues": [{"label":"MAJOR"},{"label":"MINOR"}], "meta": {"capped": false, "skipped": []}, "error": null, "noFiles": false}' '' 0)"
run --tool codeant --bin "$BIN"
check_eq 1 "$RC" "CodeAnt findings exits 1"
check_eq "false" "$(field .ok)" "CodeAnt findings is not ok"
check_eq "true" "$(field .verified_run)" "CodeAnt findings is still a verified run"
check_eq "2" "$(field .findings)" "CodeAnt findings counts .issues"

# --------------------------------------------------------------------------
# 5. CodeRabbit — failure hides in the stdout NDJSON stream, stderr stays clean.
# --------------------------------------------------------------------------
CR_CTX='{"type":"review_context","reviewType":"all"}'
CR_DONE='{"type":"complete","status":"review_completed","findings":0,"reviewedFiles":["a.sh"]}'

# 5a. Rate-limit error record with exit 0 and clean stderr.
BIN="$(make_stub coderabbit-rl "$CR_CTX
{\"type\":\"error\",\"errorType\":\"rate_limit\",\"message\":\"Rate limit exceeded\"}" '' 0)"
run --tool coderabbit --bin "$BIN"
check_eq 3 "$RC" "CR error record exits 3"
check_eq "error_record" "$(field .failure_mode)" "CR error record reports error_record"
if printf '%s' "$OUT" | jq -e '.relevant_error | test("rate_limit")' >/dev/null; then
  ok "CR relevant_error names the errorType"
else bad "CR relevant_error missing errorType"; fi

# 5b. No terminal complete record — the run died mid-flight. Not "no findings".
BIN="$(make_stub coderabbit-truncated "$CR_CTX
{\"type\":\"status\",\"phase\":\"analyzing\",\"status\":\"analyzing_files\"}" '' 0)"
run --tool coderabbit --bin "$BIN"
check_eq 3 "$RC" "CR missing complete record exits 3"
check_eq "no_review_records" "$(field .failure_mode)" "CR missing complete record reports no_review_records"

# 5c. review_skipped — nothing to review. A wrong-directory tell, not a pass.
BIN="$(make_stub coderabbit-skipped "$CR_CTX
{\"type\":\"complete\",\"status\":\"review_skipped\",\"findings\":0,\"message\":\"No changes detected\"}" '' 0)"
run --tool coderabbit --bin "$BIN"
check_eq 3 "$RC" "CR review_skipped exits 3"
check_eq "no_changes_reviewed" "$(field .failure_mode)" "CR review_skipped reports no_changes_reviewed"

# 5d. Genuinely clean.
BIN="$(make_stub coderabbit-clean "$CR_CTX
$CR_DONE" '' 0)"
run --tool coderabbit --bin "$BIN"
check_eq 0 "$RC" "CR clean run exits 0"
check_eq "true" "$(field .ok)" "CR clean run is ok"
check_eq "coderabbit" "$(field .tool)" "contract names the tool"

# 5e. Findings.
BIN="$(make_stub coderabbit-findings "$CR_CTX
{\"type\":\"complete\",\"status\":\"review_completed\",\"findings\":3,\"reviewedFiles\":[\"a.sh\"]}" '' 0)"
run --tool coderabbit --bin "$BIN"
check_eq 1 "$RC" "CR findings exits 1"
check_eq "3" "$(field .findings)" "CR findings count comes from the complete record"
check_eq "true" "$(field .verified_run)" "CR findings is a verified run"

# 5f. An error record outranks a later clean complete record — an explicit failure
#     always beats an empty result, because an empty result IS what failure looks like.
BIN="$(make_stub coderabbit-err-then-done "$CR_CTX
{\"type\":\"error\",\"errorType\":\"auth\",\"message\":\"not logged in\"}
$CR_DONE" '' 0)"
run --tool coderabbit --bin "$BIN"
check_eq 3 "$RC" "CR error record wins over a later complete record"

# --------------------------------------------------------------------------
# 6. Raw output always persists — compaction moves bulk out of context, never
#    destroys it. log_path and stderr_path must both exist on every path.
# --------------------------------------------------------------------------
BIN="$(make_stub codeant-persist "$CA_CLEAN" 'some stderr noise' 0)"
run --tool codeant --bin "$BIN"
LOG_PATH="$(field .log_path)"
ERR_PATH="$(field .stderr_path)"
[[ -f "$LOG_PATH" ]] && ok "log_path exists on a clean run" || bad "log_path missing: $LOG_PATH"
[[ -f "$ERR_PATH" ]] && ok "stderr_path exists on a clean run" || bad "stderr_path missing: $ERR_PATH"
if grep -q 'some stderr noise' "$ERR_PATH" 2>/dev/null; then
  ok "raw stderr is preserved verbatim at stderr_path"
else bad "stderr capture did not reach stderr_path"; fi
case "$LOG_PATH" in *//*) bad "log_path contains a doubled slash: $LOG_PATH" ;; *) ok "log_path has no doubled slash" ;; esac

# --------------------------------------------------------------------------
# 7. --format summary — one human line, and NOT JSON.
# --------------------------------------------------------------------------
BIN="$(make_stub codeant-summary "$CA_CLEAN" '' 0)"
SUMMARY="$("$SUT" --tool codeant --bin "$BIN" --log-dir "$LOGS" --format summary 2>/dev/null)"
if printf '%s' "$SUMMARY" | grep -q '^codeant: ok=true findings=0 verified=true'; then
  ok "--format summary emits the one-line human shape"
else bad "--format summary shape wrong: $SUMMARY"; fi
check_eq 1 "$(printf '%s\n' "$SUMMARY" | wc -l | tr -d ' ')" "--format summary is a single line"

# --------------------------------------------------------------------------
# 8. Timeout — a hung CLI is bounded, never waited on forever (CodeAnt v0.5.1
#    can hang with ZERO output, so silence is not progress).
# --------------------------------------------------------------------------
HANG="$STUBS/codeant-hang"
{ echo '#!/usr/bin/env bash'; echo 'sleep 60'; } > "$HANG"
chmod +x "$HANG"
START="$(date -u +%s)"
run --tool codeant --bin "$HANG" --timeout 1
ELAPSED=$(( $(date -u +%s) - START ))
check_eq 4 "$RC" "hung CLI exits 4"
check_eq "timeout" "$(field .failure_mode)" "hung CLI reports timeout"
if (( ELAPSED < 20 )); then ok "hung CLI is killed promptly (${ELAPSED}s)"; else bad "timeout took ${ELAPSED}s"; fi

# --------------------------------------------------------------------------
# 9. stdout carries ONLY the contract — the whole point of the compact shape is
#    that `$(local-review.sh ...)` is directly parseable.
# --------------------------------------------------------------------------
BIN="$(make_stub codeant-chatty "$CA_CLEAN" 'lots
of
stderr
chatter' 0)"
RAW="$("$SUT" --tool codeant --bin "$BIN" --log-dir "$LOGS" 2>/dev/null)"
check_eq 1 "$(printf '%s\n' "$RAW" | wc -l | tr -d ' ')" "json mode emits exactly one line on stdout"
if printf '%s' "$RAW" | jq -e 'has("ok") and has("failed_tests") and has("relevant_error") and has("log_path")' >/dev/null; then
  ok "contract carries all four required fields"
else bad "contract is missing a required field"; fi

# --------------------------------------------------------------------------
echo "----"
echo "local-review.test.sh: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
