#!/usr/bin/env bash
# Offline unit tests for reply-thread.sh (issue #772 — codeant reviewer mode).
# Covers: --reviewer validation (all four modes accepted; unknown rejected);
# @codeant-ai strip behavior (plain-text, no auto-mention); existing modes
# (cr/bugbot/greptile) unchanged; body-empty-after-strip guard.
#
# Strategy: stub `gh` on PATH to capture calls without any network I/O. The
# stub records the API endpoint and body arguments so tests can assert on
# what would have been POSTed. Requires bash 3.2+ (macOS-compatible — no
# mapfile/readarray). Run from repo root:
#   bash .claude/scripts/tests/reply-thread.test.sh
set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
SCRIPT="$REPO_ROOT/.claude/scripts/reply-thread.sh"

TMP="$(mktemp -d)"
TMP_HOME="$(mktemp -d)"
cleanup() { rm -rf "$TMP" "$TMP_HOME"; }
trap cleanup EXIT
export HOME="$TMP_HOME"
mkdir -p "$HOME/.claude"

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
check_contains() {
  local desc="$1" needle="$2" haystack="$3"
  if [[ "$haystack" == *"$needle"* ]]; then
    PASS=$((PASS + 1)); echo "ok   — $desc"
  else
    FAIL=$((FAIL + 1)); echo "FAIL — $desc (expected to contain '$needle', got '$haystack')"
  fi
}
check_not_contains() {
  local desc="$1" needle="$2" haystack="$3"
  if [[ "$haystack" != *"$needle"* ]]; then
    PASS=$((PASS + 1)); echo "ok   — $desc"
  else
    FAIL=$((FAIL + 1)); echo "FAIL — $desc (expected NOT to contain '$needle', got '$haystack')"
  fi
}

# ---- stub gh on PATH --------------------------------------------------------
# Driven by env vars the test scenarios set:
#   FAKE_INLINE_MODE  success (default) | 404 | error
# On success: writes the POSTed body to "$TMP/posted_body" (parsed from -f body=...)
# and prints a fake JSON response with html_url.
STUB_BIN="$TMP/bin"
mkdir -p "$STUB_BIN"
cat > "$STUB_BIN/gh" <<'STUB'
#!/usr/bin/env bash
set -uo pipefail
sub="${1:-}"
shift || true
case "$sub" in
  repo)
    # repo view --json owner,name
    printf '{"owner":{"login":"test-owner"},"name":"test-repo"}\n'
    ;;
  api)
    endpoint="${1:-}"
    shift || true
    # Parse -f body=<value> from remaining args; write to shared file
    while [[ $# -gt 0 ]]; do
      case "$1" in
        -f)
          val="${2:-}"
          shift 2 || shift
          if [[ "$val" == body=* ]]; then
            printf '%s' "${val#body=}" > "${TMP_DIR}/posted_body"
          fi
          ;;
        *)
          shift
          ;;
      esac
    done
    case "${FAKE_INLINE_MODE:-success}" in
      success)
        printf '{"html_url":"https://github.com/test-owner/test-repo/pull/1#pullrequestreview-1"}\n'
        ;;
      404)
        echo "HTTP 404: Not Found (https://api.github.com/$endpoint)" >&2
        exit 1
        ;;
      error)
        echo "HTTP 500: Internal Server Error" >&2
        exit 1
        ;;
    esac
    ;;
  *)
    echo "unexpected gh sub: $sub $*" >&2
    exit 99
    ;;
esac
STUB
chmod +x "$STUB_BIN/gh"
export PATH="$STUB_BIN:$PATH"
export TMP_DIR="$TMP"

# Helper: run the script, capturing stdout+stderr and exit code
run() {
  OUT="$(bash "$SCRIPT" "$@" 2>&1)"; RC=$?
}
# Helper: run and also read what was POSTed to gh api
run_and_capture() {
  rm -f "$TMP/posted_body"
  OUT="$(bash "$SCRIPT" "$@" 2>&1)"; RC=$?
  POSTED_BODY=""
  if [[ -f "$TMP/posted_body" ]]; then
    POSTED_BODY="$(cat "$TMP/posted_body")"
  fi
}

############################################################################
echo "== (1) --reviewer codeant accepted — reply posted (exit 0) =="
export FAKE_INLINE_MODE="success"
run_and_capture 1234567 --reviewer codeant --body "Fixed in abc1234."
check_eq "exit 0" 0 "$RC"
check_contains "stdout contains URL" "https://github.com/" "$OUT"

############################################################################
echo "== (2) @codeant-ai stripped from body =="
export FAKE_INLINE_MODE="success"
run_and_capture 1234567 --reviewer codeant \
  --body "Fixed in abc1234. @codeant-ai please re-review."
check_eq "exit 0" 0 "$RC"
check_not_contains "body does not contain @codeant-ai" "@codeant-ai" "$POSTED_BODY"
check_contains "body retains non-mention text" "Fixed in abc1234." "$POSTED_BODY"

############################################################################
echo "== (3) @CODEANT-AI (uppercase) stripped (case-insensitive) =="
export FAKE_INLINE_MODE="success"
run_and_capture 1234567 --reviewer codeant \
  --body "@CODEANT-AI issue addressed."
check_eq "exit 0" 0 "$RC"
check_not_contains "uppercase @CODEANT-AI stripped" "@CODEANT-AI" "$POSTED_BODY"
check_not_contains "lowercase variant also gone" "@codeant-ai" "$POSTED_BODY"
check_contains "body retains non-mention text" "issue addressed." "$POSTED_BODY"

############################################################################
echo "== (4) @CodeAnt-Ai (mixed case) stripped =="
export FAKE_INLINE_MODE="success"
run_and_capture 1234567 --reviewer codeant \
  --body "Good catch, @CodeAnt-Ai — fixed."
check_eq "exit 0" 0 "$RC"
check_not_contains "mixed-case variant stripped" "@CodeAnt-Ai" "$POSTED_BODY"
check_contains "body retains remaining text" "Good catch," "$POSTED_BODY"

############################################################################
echo "== (5) adjacent @codeant-ai @codeant-ai both stripped =="
export FAKE_INLINE_MODE="success"
run_and_capture 1234567 --reviewer codeant \
  --body "@codeant-ai @codeant-ai duplicate mention removed."
check_eq "exit 0" 0 "$RC"
check_not_contains "first @codeant-ai stripped" "@codeant-ai" "$POSTED_BODY"

############################################################################
echo "== (6) body-only @codeant-ai → empty after strip → exit 2 =="
run 1234567 --reviewer codeant --body "@codeant-ai"
check_eq "exit 2 on empty-after-strip" 2 "$RC"
check_contains "error message" "empty or whitespace-only" "$OUT"

############################################################################
echo "== (7) no @codeant-ai mention prepended when body is clean =="
export FAKE_INLINE_MODE="success"
run_and_capture 1234567 --reviewer codeant \
  --body "No mention in this reply."
check_eq "exit 0" 0 "$RC"
check_not_contains "no @codeant-ai prepended" "@codeant-ai" "$POSTED_BODY"
check_not_contains "no @coderabbitai prepended" "@coderabbitai" "$POSTED_BODY"

############################################################################
echo "== (8) unknown reviewer exits 2 =="
run 1234567 --reviewer unknown --body "test"
check_eq "exit 2 for unknown reviewer" 2 "$RC"
check_contains "error message lists all four modes" "cr, bugbot, greptile, codeant" "$OUT"

############################################################################
echo "== (9) missing --reviewer exits 2 =="
run 1234567 --body "test"
check_eq "exit 2 for missing --reviewer" 2 "$RC"
check_contains "error message lists all four modes" "cr|bugbot|greptile|codeant" "$OUT"

############################################################################
echo "== (10) CR mode still works — @coderabbitai prepended =="
export FAKE_INLINE_MODE="success"
run_and_capture 1234567 --reviewer cr \
  --body "Fixed per your suggestion."
check_eq "exit 0" 0 "$RC"
check_contains "@coderabbitai prepended" "@coderabbitai" "$POSTED_BODY"
check_not_contains "no @codeant-ai in CR body" "@codeant-ai" "$POSTED_BODY"

############################################################################
echo "== (11) bugbot mode still works — @cursor stripped =="
export FAKE_INLINE_MODE="success"
run_and_capture 1234567 --reviewer bugbot \
  --body "@cursor Fixed the issue."
check_eq "exit 0" 0 "$RC"
check_not_contains "@cursor stripped in bugbot mode" "@cursor" "$POSTED_BODY"

############################################################################
echo "== (12) greptile mode still works — @greptileai stripped =="
export FAKE_INLINE_MODE="success"
run_and_capture 1234567 --reviewer greptile \
  --body "@greptileai Fixed the issue."
check_eq "exit 0" 0 "$RC"
check_not_contains "@greptileai stripped in greptile mode" "@greptileai" "$POSTED_BODY"

############################################################################
echo "== (13) codeant: substring @codeant-ai-bot NOT stripped (word boundary) =="
# @codeant-ai-bot has extra text after 'ai' — NOT matched because the word-boundary
# guard requires a non-alnum/underscore char or end-of-string after 'i'.
# Note: '-' IS a non-alnum char, so @codeant-ai- WOULD be stripped (just like
# @cursor-thing strips @cursor). Here we test a clean non-strippable variant:
# use "x@codeant-ai" (alphanumeric prefix, no boundary before @).
export FAKE_INLINE_MODE="success"
run_and_capture 1234567 --reviewer codeant \
  --body "See x@codeant-ai for details."
check_eq "exit 0" 0 "$RC"
# The 'x' immediately before '@' is alnum, so the left boundary fails — not stripped.
check_contains "x@codeant-ai not stripped (no left boundary)" "x@codeant-ai" "$POSTED_BODY"

############################################################################
echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
