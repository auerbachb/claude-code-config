#!/usr/bin/env bash
# local-review.sh — Run a local review CLI and emit the compact result contract.
#
# One wrapper for the CodeRabbit / CodeAnt local-review invocations that were
# copy-pasted inline across .claude/rules/cr-local-review.md and several skills,
# each redirecting streams to ad-hoc files and grepping for errors by hand.
# Implements the `ok`/`failed_tests`/`relevant_error`/`log_path` shape defined in
# .claude/reference/compact-result-contract.md (FU-7 of the token-efficiency audit).
#
# The point is NOT convenience. Both CLIs exit 0 on total failure and each hides the
# error on a different stream, so "exit 0 with no findings" is not a clean pass — see
# .claude/reference/local-review-cli-failure-modes.md. This script applies every
# documented false-clean check in one place so no call site can forget one.
#
# Usage:
#   local-review.sh --tool coderabbit|codeant [options]
#   local-review.sh --help
#
# Options:
#   --tool <name>       Required. `coderabbit` or `codeant`.
#   --scope <scope>     all (default) | uncommitted | committed
#                       Mapped per CLI: CR `--type <scope>`; CodeAnt `--all`/`--uncommitted`/`--committed`.
#   --base <branch>     Pass a base branch through (both CLIs support --base).
#   --timeout <sec>     Hang bound, default 120 (the 2-minute rule in cr-local-review.md).
#                       CodeAnt v0.5.1 can hang with ZERO output, so silence is never progress.
#   --log-dir <dir>     Where to persist raw output. Default: $TMPDIR or /tmp.
#   --format json|summary   Output shape. Default json (the contract).
#   --print-cmd         Print the exact CLI command to stdout and exit 0. Runs nothing.
#   --bin <path>        Run this executable instead of discovering the CLI. For a
#                       non-standard install, and how the offline tests drive stubs.
#
# Output (JSON, default) — one line, stdout only:
#   {"ok":true,"failed_tests":[],"relevant_error":null,
#    "log_path":"/tmp/local-review-coderabbit-1754107200-a1b2c3.out",
#    "stderr_path":"/tmp/local-review-coderabbit-1754107200-a1b2c3.err",
#    "tool":"coderabbit","findings":0,"verified_run":true,"failure_mode":null,"duration_s":37}
#
#   ok            true only for a VERIFIED clean run: the CLI actually reviewed the change
#                 set, emitted no error, and reported zero findings.
#   verified_run  the run is trustworthy (it really reviewed something and did not error).
#                 A run with findings is still a verified run — ok is false, verified_run true.
#   failure_mode  null | stderr_error | error_record | no_review_records | no_changes_reviewed
#                 | capped | timeout | not_installed   (maps 1:1 onto the failure-modes reference)
#   failed_tests  always [] — this is not a test pipeline; present for contract uniformity.
#   relevant_error  the CLI's own decisive error text, capped. Never the whole log.
#
# Coverage classification (cr-local-review.md): this CLI counts toward coverage only on
# `verified_run == true && ok == true`. Anything else is NOT covered for that CLI.
#
# --format summary emits one human line instead:
#   coderabbit: ok=true findings=0 verified=true mode=- log=/tmp/...
#
# Exit codes:
#   0  verified clean pass (no findings, no error)
#   1  verified run WITH findings (fix them and re-run)
#   2  usage error
#   3  failed run — false-clean detected (stderr error, error record, no review records,
#      nothing reviewed, or a capped partial run). NOT a clean pass, NOT coverage.
#   4  timed out (exceeded --timeout)
#   5  CLI binary not installed
#
# Notes:
#   - Raw stdout and stderr are ALWAYS persisted, on every path including timeout, so the
#     full output survives even though only the verdict reaches an agent's context.
#   - Never runs `codeant logout`/`login` on a 403 — the cause is an undocumented daily cap,
#     not auth (issue #643). Retry policy stays with the caller: one retry, then drop.
set -uo pipefail

printf '%s\t%s\t%s\n' "$(date -u +%FT%TZ)" "$(basename "$0")" "${*//$'\n'/ }" \
  >> "$HOME/.claude/script-usage.log" 2>/dev/null || true

TOOL=""
SCOPE="all"
BASE=""
TIMEOUT=120
LOG_DIR="${TMPDIR:-/tmp}"
FORMAT="json"
PRINT_CMD=0
BIN_OVERRIDE=""

usage() { awk 'NR == 1 { next } /^$/ { exit } { print }' "$0"; }

die() { echo "ERROR: $1" >&2; exit 2; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --tool)    TOOL="${2:-}"; [[ -z "$TOOL" || "$TOOL" == -* ]] && die "--tool requires a value"; shift 2 ;;
    --scope)   SCOPE="${2:-}"; [[ -z "$SCOPE" || "$SCOPE" == -* ]] && die "--scope requires a value"; shift 2 ;;
    --base)    BASE="${2:-}"; [[ -z "$BASE" || "$BASE" == -* ]] && die "--base requires a branch"; shift 2 ;;
    --timeout) TIMEOUT="${2:-}"; [[ "$TIMEOUT" =~ ^[0-9]+$ ]] || die "--timeout requires an integer (seconds)"; shift 2 ;;
    --log-dir) LOG_DIR="${2:-}"; [[ -z "$LOG_DIR" || "$LOG_DIR" == -* ]] && die "--log-dir requires a directory"; shift 2 ;;
    --format)  FORMAT="${2:-}"; [[ "$FORMAT" == "json" || "$FORMAT" == "summary" ]] || die "--format must be json or summary"; shift 2 ;;
    --bin)     BIN_OVERRIDE="${2:-}"; [[ -z "$BIN_OVERRIDE" || "$BIN_OVERRIDE" == -* ]] && die "--bin requires a path"; shift 2 ;;
    --print-cmd) PRINT_CMD=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

[[ -n "$TOOL" ]] || die "--tool is required (coderabbit or codeant)"
case "$TOOL" in coderabbit|codeant) ;; *) die "--tool must be coderabbit or codeant (got: $TOOL)" ;; esac
case "$SCOPE" in all|uncommitted|committed) ;; *) die "--scope must be all, uncommitted, or committed (got: $SCOPE)" ;; esac

# ----------------------------------------------------------------------
# Build the CLI argv. Scope flags differ between the two CLIs.
# ----------------------------------------------------------------------
ARGS=()
case "$TOOL" in
  coderabbit)
    ARGS=(review --agent --type "$SCOPE")
    [[ -n "$BASE" ]] && ARGS+=(--base "$BASE")
    ;;
  codeant)
    case "$SCOPE" in
      all)         ARGS=(review --all --headless) ;;
      uncommitted) ARGS=(review --uncommitted --headless) ;;
      committed)   ARGS=(review --committed --headless) ;;
    esac
    [[ -n "$BASE" ]] && ARGS+=(--base "$BASE")
    ;;
esac

if [[ "$PRINT_CMD" -eq 1 ]]; then
  echo "$TOOL ${ARGS[*]}"
  exit 0
fi

# Resolve the binary by absolute path first: the Bash tool's minimal PATH makes a bare
# `command -v` under-report (safety.md rung 1, and the #819 not-installed failure mode).
BIN=""
if [[ -n "$BIN_OVERRIDE" ]]; then
  [[ -x "$BIN_OVERRIDE" ]] && BIN="$BIN_OVERRIDE"
else
  for cand in "/opt/homebrew/bin/$TOOL" "$HOME/.local/bin/$TOOL" "$HOME/bin/$TOOL" "/usr/local/bin/$TOOL"; do
    [[ -x "$cand" ]] && { BIN="$cand"; break; }
  done
  [[ -z "$BIN" ]] && BIN="$(command -v "$TOOL" 2>/dev/null || true)"
fi

LOG_DIR="${LOG_DIR%/}"   # $TMPDIR usually ends in / — keep log_path free of a doubled slash
mkdir -p "$LOG_DIR" 2>/dev/null || true
STAMP="$(date -u +%s)-$$"
OUT="$LOG_DIR/local-review-$TOOL-$STAMP.out"
ERR="$LOG_DIR/local-review-$TOOL-$STAMP.err"
: > "$OUT"
: > "$ERR"

# ----------------------------------------------------------------------
# Emitter — every exit path goes through here so the contract shape is
# identical no matter which failure fired.
# ----------------------------------------------------------------------
emit() { # ok verified_run failure_mode findings relevant_error duration exit_code
  local ok="$1" verified="$2" mode="$3" findings="$4" err_txt="$5" dur="$6" rc="$7"
  if [[ "$FORMAT" == "summary" ]]; then
    printf '%s: ok=%s findings=%s verified=%s mode=%s log=%s\n' \
      "$TOOL" "$ok" "$findings" "$verified" "${mode:--}" "$OUT"
  else
    jq -cn \
      --argjson ok "$ok" \
      --argjson verified "$verified" \
      --arg mode "$mode" \
      --argjson findings "$findings" \
      --arg err "$err_txt" \
      --arg log "$OUT" \
      --arg errlog "$ERR" \
      --arg tool "$TOOL" \
      --argjson dur "$dur" \
      '{ok: $ok, failed_tests: [], relevant_error: (if $err == "" then null else $err end),
        log_path: $log, stderr_path: $errlog, tool: $tool, findings: $findings,
        verified_run: $verified, failure_mode: (if $mode == "" then null else $mode end),
        duration_s: $dur}'
  fi
  exit "$rc"
}

# Cap the decisive error text so it stays an index into the log, never a copy of it
# (compact-result-contract.md "Extraction rules"). Deduped first: a CodeAnt 403
# repeats the identical "API Error: Access denied (403)…" line once per file batch,
# which would spend the whole budget restating one fact.
cap_error() {
  awk '!seen[$0]++' \
    | awk 'NR <= 20 { print } NR == 21 { print "… (truncated; see log_path)"; exit }' \
    | cut -c1-2000
}

if [[ -z "$BIN" ]]; then
  emit false false not_installed 0 "$TOOL: command not found (checked /opt/homebrew/bin, ~/.local/bin, ~/bin, /usr/local/bin, PATH)" 0 5
fi

# ----------------------------------------------------------------------
# Run with a hang bound. No `timeout(1)` on stock macOS, so poll the child.
# ----------------------------------------------------------------------
START="$(date -u +%s)"
"$BIN" "${ARGS[@]}" >"$OUT" 2>"$ERR" &
CLI_PID=$!

TIMED_OUT=0
ELAPSED=0
while kill -0 "$CLI_PID" 2>/dev/null; do
  if (( ELAPSED >= TIMEOUT )); then
    TIMED_OUT=1
    kill -TERM "$CLI_PID" 2>/dev/null || true
    # Give it a moment to flush, then make sure it is gone.
    sleep 2
    kill -KILL "$CLI_PID" 2>/dev/null || true
    break
  fi
  sleep 1
  ELAPSED=$((ELAPSED + 1))
done
CLI_RC=0
wait "$CLI_PID" 2>/dev/null || CLI_RC=$?
DURATION=$(( $(date -u +%s) - START ))

if [[ "$TIMED_OUT" -eq 1 ]]; then
  emit false false timeout 0 "$TOOL exceeded --timeout ${TIMEOUT}s and was killed (partial output preserved)" "$DURATION" 4
fi

# ----------------------------------------------------------------------
# Verdict. Order matters: an explicit error always outranks an empty result,
# because an empty result is exactly what a failed run looks like.
# ----------------------------------------------------------------------
ERR_TEXT=""
FINDINGS=0

if [[ "$TOOL" == "codeant" ]]; then
  # 1. stderr is CodeAnt's ONLY reliable failure signal (issue #642).
  if grep -qE 'API Error|\[error\]|40[13]' "$ERR" 2>/dev/null; then
    ERR_TEXT="$(grep -E 'API Error|\[error\]|40[13]' "$ERR" | cap_error)"
    emit false false stderr_error 0 "$ERR_TEXT" "$DURATION" 3
  fi
  # 2. The headless object also carries its own `error` field.
  CA_ERR="$(jq -r '.error // empty' "$OUT" 2>/dev/null || true)"
  if [[ -n "$CA_ERR" ]]; then
    emit false false stderr_error 0 "$(printf '%s' "$CA_ERR" | cap_error)" "$DURATION" 3
  fi
  # 3. Unparseable stdout means the run died before printing its result object.
  if ! jq -e . "$OUT" >/dev/null 2>&1; then
    ERR_TEXT="$(tail -n 20 "$ERR" | cap_error)"
    [[ -z "$ERR_TEXT" ]] && ERR_TEXT="codeant produced no parseable JSON on stdout (exit $CLI_RC)"
    emit false false no_review_records 0 "$ERR_TEXT" "$DURATION" 3
  fi
  # 4. noFiles: nothing was reviewed. Often a wrong-directory tell, never a clean pass.
  if [[ "$(jq -r '.noFiles // false' "$OUT" 2>/dev/null)" == "true" ]]; then
    emit false false no_changes_reviewed 0 "codeant reviewed 0 files (noFiles=true) — nothing was analysed; check the working directory and diff scope" "$DURATION" 3
  fi
  # 5. The 15-file cap: partial coverage is not full coverage.
  if [[ "$(jq -r '.meta.capped // false' "$OUT" 2>/dev/null)" == "true" ]]; then
    SKIPPED="$(jq -r '(.meta.skipped // []) | length' "$OUT" 2>/dev/null || echo 0)"
    FINDINGS="$(jq -r '(.issues // []) | length' "$OUT" 2>/dev/null || echo 0)"
    emit false false capped "$FINDINGS" "codeant hit the 15-file cap (meta.capped=true, ${SKIPPED} file(s) skipped) — scope the run with --include and re-run" "$DURATION" 3
  fi
  FINDINGS="$(jq -r '(.issues // []) | length' "$OUT" 2>/dev/null || echo 0)"
else
  # CodeRabbit hides failure as a stdout NDJSON record, with a clean stderr.
  # 1. Any `type:"error"` record is a failed run regardless of exit code.
  CR_ERR="$(jq -rs '[.[] | select(.type == "error")]
                    | map(((.errorType // "error") + ": " + (.message // "")))
                    | join("\n")' "$OUT" 2>/dev/null || true)"
  if [[ -n "$CR_ERR" ]]; then
    emit false false error_record 0 "$(printf '%s' "$CR_ERR" | cap_error)" "$DURATION" 3
  fi
  # 2. The terminal `complete` record is the authoritative verdict + finding count.
  #    Its absence means the run died mid-flight — never read that as "no findings".
  CR_COMPLETE="$(jq -rs '[.[] | select(.type == "complete" and (.findings != null))] | last // empty' "$OUT" 2>/dev/null || true)"
  if [[ -z "$CR_COMPLETE" ]]; then
    ERR_TEXT="$(tail -n 20 "$ERR" | cap_error)"
    [[ -z "$ERR_TEXT" ]] && ERR_TEXT="coderabbit emitted no terminal complete record (exit $CLI_RC) — the review did not finish"
    emit false false no_review_records 0 "$ERR_TEXT" "$DURATION" 3
  fi
  CR_STATUS="$(printf '%s' "$CR_COMPLETE" | jq -r '.status // ""' 2>/dev/null || true)"
  if [[ "$CR_STATUS" == "review_skipped" ]]; then
    emit false false no_changes_reviewed 0 "coderabbit skipped the review (status=review_skipped) — no changes were detected; check the working directory and --scope" "$DURATION" 3
  fi
  FINDINGS="$(printf '%s' "$CR_COMPLETE" | jq -r '.findings // 0' 2>/dev/null || echo 0)"
fi

[[ "$FINDINGS" =~ ^[0-9]+$ ]] || FINDINGS=0

if (( FINDINGS > 0 )); then
  emit false true "" "$FINDINGS" "" "$DURATION" 1
fi

emit true true "" 0 "" "$DURATION" 0
