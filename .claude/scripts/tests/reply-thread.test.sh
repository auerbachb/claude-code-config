#!/usr/bin/env bash
# Offline unit tests for reply-thread.sh (issue #772 — codeant reviewer mode;
# issue #1374 — graphite reviewer mode).
# Covers: --reviewer validation (all five modes accepted; unknown rejected);
# @codeant-ai and @graphite-app strip behavior (plain-text, no auto-mention);
# per-reviewer strip-rule independence (neither token is eaten by the other
# reviewer's rule); existing modes (cr/bugbot/greptile) unchanged;
# body-empty-after-strip guard.
# catalog: tests — Tests for `reply-thread.sh`
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
#   FAKE_INLINE_MODE    success (default) | 404 | error
#   FAKE_FALLBACK_MODE  success (default) | 404 | error
#   FAKE_RESOLVE_MODE   success (default) | 404 | error | nourl | nonnumeric
#   FAKE_RESOLVED_PR    PR number the comment-lookup GET resolves to (default 42)
#
# `gh api` calls are dispatched on the ENDPOINT SHAPE, not on call order, so
# the comment-lookup GET and the inline reply POST stay independently drivable:
#   .../pulls/{pr}/comments/{id}/replies  -> inline reply POST (FAKE_INLINE_MODE)
#   .../pulls/comments/{id}               -> comment lookup GET (FAKE_RESOLVE_MODE)
#   anything else                         -> exit 99 (unexpected route)
# Note the old PR-less reply route (.../pulls/comments/{id}/replies) also ends
# in /replies, so it matches the replies branch rather than the 99 branch — the
# 99 branch only catches a route of neither shape. What actually detects the
# issue #1446 regression is the POSTED_ENDPOINT equality assertion in case (21).
#
# Recorded artifacts (each reset per run by reset_recorded):
#   $TMP/posted_body      body POSTed inline, or the fallback comment body
#   $TMP/posted_endpoint  endpoint of the inline reply POST
#   $TMP/resolve_endpoint endpoint of the comment-lookup GET (absent if skipped)
#   $TMP/fallback_pr      PR number passed to `gh pr comment`
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
    case "$endpoint" in
      */replies)
        # Inline reply POST — record the exact route so tests can pin its shape.
        printf '%s' "$endpoint" > "${TMP_DIR}/posted_endpoint"
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
      */pulls/comments/*)
        # Comment-lookup GET used to resolve the PR number when --pr is omitted.
        printf '%s' "$endpoint" > "${TMP_DIR}/resolve_endpoint"
        case "${FAKE_RESOLVE_MODE:-success}" in
          success)
            printf '{"id":1234567,"pull_request_url":"https://api.github.com/repos/test-owner/test-repo/pulls/%s"}\n' \
              "${FAKE_RESOLVED_PR:-42}"
            ;;
          nourl)
            # 200 with the field missing — exercises the jq -er leg.
            printf '{"id":1234567}\n'
            ;;
          nonnumeric)
            # 200 with a pull_request_url whose trailing segment is not a PR number.
            printf '{"id":1234567,"pull_request_url":"https://api.github.com/repos/test-owner/test-repo/pulls/not-a-number"}\n'
            ;;
          404)
            # Comment genuinely missing — a permanent condition (exit 3).
            echo "HTTP 404: Not Found (https://api.github.com/$endpoint)" >&2
            exit 1
            ;;
          error)
            # Transport / server failure — the PR is unknown, not absent (exit 5).
            echo "HTTP 500: Internal Server Error" >&2
            exit 1
            ;;
        esac
        ;;
      *)
        echo "unexpected gh api endpoint: $endpoint" >&2
        exit 99
        ;;
    esac
    ;;
  pr)
    pr_action="${1:-}"
    shift || true
    case "$pr_action" in
      comment)
        # gh pr comment N --body "text" — capture the target PR and the body.
        while [[ $# -gt 0 ]]; do
          case "$1" in
            --body)
              printf '%s' "${2:-}" > "${TMP_DIR}/posted_body"
              shift 2 || shift
              ;;
            --*) shift ;;
            *)
              # First positional is the PR number the fallback targets.
              if [[ ! -f "${TMP_DIR}/fallback_pr" ]]; then
                printf '%s' "$1" > "${TMP_DIR}/fallback_pr"
              fi
              shift
              ;;
          esac
        done
        case "${FAKE_FALLBACK_MODE:-success}" in
          success)
            printf 'https://github.com/test-owner/test-repo/pull/1#issuecomment-123456\n'
            ;;
          404)
            echo "Not Found (HTTP 404)" >&2
            exit 1
            ;;
          error)
            echo "HTTP 500: Internal Server Error" >&2
            exit 1
            ;;
        esac
        ;;
      *)
        echo "unexpected gh pr action: $pr_action $*" >&2
        exit 99
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

# Helper: clear the stub's recorded artifacts before a run. Absence is
# meaningful (e.g. no resolve_endpoint = the lookup was correctly skipped), so
# every capturing helper must reset first or a prior run's file reads as this
# run's evidence.
reset_recorded() {
  rm -f "$TMP/posted_body" "$TMP/posted_endpoint" \
        "$TMP/resolve_endpoint" "$TMP/fallback_pr"
}
# Helper: read the stub's recorded artifacts back into vars. An unwritten
# artifact reads as the empty string.
read_recorded() {
  POSTED_BODY=""; POSTED_ENDPOINT=""; RESOLVE_ENDPOINT=""; FALLBACK_PR=""
  [[ -f "$TMP/posted_body" ]] && POSTED_BODY="$(cat "$TMP/posted_body")"
  [[ -f "$TMP/posted_endpoint" ]] && POSTED_ENDPOINT="$(cat "$TMP/posted_endpoint")"
  [[ -f "$TMP/resolve_endpoint" ]] && RESOLVE_ENDPOINT="$(cat "$TMP/resolve_endpoint")"
  [[ -f "$TMP/fallback_pr" ]] && FALLBACK_PR="$(cat "$TMP/fallback_pr")"
  return 0
}
# Helper: run the script, capturing stdout+stderr and exit code
run() {
  OUT="$(bash "$SCRIPT" "$@" 2>&1)"; RC=$?
}
# Helper: run and also read what was POSTed to gh api
run_and_capture() {
  reset_recorded
  OUT="$(bash "$SCRIPT" "$@" 2>&1)"; RC=$?
  read_recorded
}
# Helper: run capturing stdout and stderr into separate vars
# STDOUT_OUT, STDERR_OUT, RC; also sets OUT = merged (for check_contains compat).
# Also reads the stub's recorded artifacts, so a single run can assert on both
# stream separation and endpoint shape.
run_split() {
  local stderr_file="$TMP/run_split_stderr"
  reset_recorded
  STDOUT_OUT="$(bash "$SCRIPT" "$@" 2>"$stderr_file")"; RC=$?
  STDERR_OUT="$(cat "$stderr_file")"
  OUT="${STDOUT_OUT}${STDERR_OUT}"
  read_recorded
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
# The expected string must carry the FULL enumeration including the newest
# value: a shorter prefix would still substring-match the widened message and
# pass vacuously, so this assertion would stop guarding the accept-list.
run 1234567 --reviewer unknown --body "test"
check_eq "exit 2 for unknown reviewer" 2 "$RC"
check_contains "error message lists all five modes" \
  "cr, bugbot, greptile, codeant, graphite" "$OUT"

############################################################################
echo "== (9) missing --reviewer exits 2 =="
run 1234567 --body "test"
check_eq "exit 2 for missing --reviewer" 2 "$RC"
check_contains "error message lists all five modes" \
  "cr|bugbot|greptile|codeant|graphite" "$OUT"

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
# Graphite reviewer mode (issue #1374). Graphite (`graphite-app[bot]`) is a
# supplemental CR-path reviewer that posts real findings, but `--reviewer
# graphite` was rejected, forcing callers to pass `--reviewer codeant` instead.
# That substitution happened to be harmless only because the bodies involved
# carried no `@codeant-ai` token — a coincidence, not a contract. Cases (13i)
# and (13j) below pin the contract that made it a coincidence.
############################################################################
echo "== (13a) --reviewer graphite accepted — reply posted (exit 0) =="
export FAKE_INLINE_MODE="success"
run_and_capture 1234567 --reviewer graphite --body "Fixed in abc1234."
check_eq "exit 0" 0 "$RC"
check_contains "stdout contains URL" "https://github.com/" "$OUT"

############################################################################
echo "== (13b) @graphite-app stripped from body =="
export FAKE_INLINE_MODE="success"
run_and_capture 1234567 --reviewer graphite \
  --body "Fixed in abc1234. @graphite-app re-review please."
check_eq "exit 0" 0 "$RC"
check_not_contains "body does not contain @graphite-app" "@graphite-app" "$POSTED_BODY"
check_contains "body retains non-mention text" "Fixed in abc1234." "$POSTED_BODY"

############################################################################
echo "== (13c) @GRAPHITE-APP (uppercase) stripped (case-insensitive) =="
export FAKE_INLINE_MODE="success"
run_and_capture 1234567 --reviewer graphite \
  --body "@GRAPHITE-APP issue addressed."
check_eq "exit 0" 0 "$RC"
check_not_contains "uppercase @GRAPHITE-APP stripped" "@GRAPHITE-APP" "$POSTED_BODY"
check_not_contains "lowercase variant also gone" "@graphite-app" "$POSTED_BODY"
check_contains "body retains non-mention text" "issue addressed." "$POSTED_BODY"

############################################################################
echo "== (13d) @Graphite-App (mixed case) stripped =="
export FAKE_INLINE_MODE="success"
run_and_capture 1234567 --reviewer graphite \
  --body "Good catch, @Graphite-App — fixed."
check_eq "exit 0" 0 "$RC"
check_not_contains "mixed-case variant stripped" "@Graphite-App" "$POSTED_BODY"
check_contains "body retains remaining text" "Good catch," "$POSTED_BODY"

############################################################################
echo "== (13e) adjacent @graphite-app @graphite-app both stripped =="
export FAKE_INLINE_MODE="success"
run_and_capture 1234567 --reviewer graphite \
  --body "@graphite-app @graphite-app duplicate mention removed."
check_eq "exit 0" 0 "$RC"
check_not_contains "both adjacent @graphite-app tokens stripped" "@graphite-app" "$POSTED_BODY"
check_contains "body retains remaining text" "duplicate mention removed." "$POSTED_BODY"

############################################################################
echo "== (13f) body-only @graphite-app → empty after strip → exit 2 =="
run 1234567 --reviewer graphite --body "@graphite-app"
check_eq "exit 2 on empty-after-strip" 2 "$RC"
check_contains "error message" "empty or whitespace-only" "$OUT"

############################################################################
echo "== (13g) no mention prepended when graphite body is clean =="
export FAKE_INLINE_MODE="success"
run_and_capture 1234567 --reviewer graphite \
  --body "No mention in this reply."
check_eq "exit 0" 0 "$RC"
check_not_contains "no @graphite-app prepended" "@graphite-app" "$POSTED_BODY"
check_not_contains "no @coderabbitai prepended" "@coderabbitai" "$POSTED_BODY"
check_contains "body posted unchanged" "No mention in this reply." "$POSTED_BODY"

############################################################################
echo "== (13h) graphite: x@graphite-app NOT stripped (word boundary) =="
# The 'x' immediately before '@' is alnum, so the left boundary guard fails and
# the token is left alone — same semantics as case (13) for codeant.
export FAKE_INLINE_MODE="success"
run_and_capture 1234567 --reviewer graphite \
  --body "See x@graphite-app for details."
check_eq "exit 0" 0 "$RC"
check_contains "x@graphite-app not stripped (no left boundary)" \
  "x@graphite-app" "$POSTED_BODY"

############################################################################
echo "== (13i) NEGATIVE CONTROL: graphite mode leaves @codeant-ai intact =="
# The exact defect issue #1374 names. Replying to a Graphite finding used to
# require `--reviewer codeant`; had the body legitimately mentioned CodeAnt,
# the wrong strip rule would have silently eaten it. Each reviewer strips only
# its OWN token — so a body carrying both loses exactly one of them here.
export FAKE_INLINE_MODE="success"
run_and_capture 1234567 --reviewer graphite \
  --body "Confirmed by @codeant-ai too. @graphite-app re-review."
check_eq "exit 0" 0 "$RC"
check_contains "@codeant-ai preserved under --reviewer graphite" \
  "@codeant-ai" "$POSTED_BODY"
check_not_contains "own @graphite-app token still stripped" "@graphite-app" "$POSTED_BODY"

############################################################################
echo "== (13j) NEGATIVE CONTROL (converse): codeant mode leaves @graphite-app intact =="
# Pins rule independence in the other direction, so neither branch can later be
# widened into a shared pattern without a test failing.
export FAKE_INLINE_MODE="success"
run_and_capture 1234567 --reviewer codeant \
  --body "Confirmed by @graphite-app too. @codeant-ai please re-review."
check_eq "exit 0" 0 "$RC"
check_contains "@graphite-app preserved under --reviewer codeant" \
  "@graphite-app" "$POSTED_BODY"
check_not_contains "own @codeant-ai token still stripped" "@codeant-ai" "$POSTED_BODY"

############################################################################
echo "== (13k) graphite: right-hyphen boundary strips, matching the other modes =="
# Pins INTENTIONAL shared-helper semantics, not an accident: '-' is a non-alnum
# char, so it satisfies the right-hand boundary guard and @graphite-app is
# stripped out of @graphite-app-helper. Identical to @cursor-thing -> -thing and
# @codeant-ai-bot -> -bot (see case (13)'s note); graphite deliberately does not
# diverge. Narrowing this belongs in a cross-reviewer change to
# strip_standalone_token, not in the graphite branch alone.
export FAKE_INLINE_MODE="success"
run_and_capture 1234567 --reviewer graphite \
  --body "Ping @graphite-app-helper about it."
check_eq "exit 0" 0 "$RC"
check_not_contains "@graphite-app prefix stripped at a hyphen boundary" \
  "@graphite-app" "$POSTED_BODY"
check_contains "trailing text after the hyphen survives" "-helper about it." "$POSTED_BODY"

############################################################################
echo "== (13l) --help documents the graphite reviewer value =="
run --help
check_eq "exit 0" 0 "$RC"
check_contains "usage line lists graphite" \
  "--reviewer cr|bugbot|greptile|codeant|graphite" "$OUT"
check_contains "argument list names graphite" \
  "One of: cr, bugbot, greptile, codeant, graphite" "$OUT"
check_contains "help describes the graphite strip rule" \
  "strips any \`@graphite-app\` tokens" "$OUT"

############################################################################
echo "== (14) REGRESSION: fallback success exits 0 (inline 404, pr-level comment succeeds) =="
# This is the exact scenario from issue #884: inline 404s, fallback posts OK.
# Before the fix, exit 1 (non-zero) was returned even though the reply posted.
export FAKE_INLINE_MODE="404"
export FAKE_FALLBACK_MODE="success"
run 1234567 --reviewer bugbot --body "Fixed." --pr 1
check_eq "fallback success exits 0" 0 "$RC"
check_contains "URL on stdout or stderr" "https://github.com/" "$OUT"

############################################################################
echo "== (15) fallback path emits a distinguishing stderr note =="
export FAKE_INLINE_MODE="404"
export FAKE_FALLBACK_MODE="success"
run_split 1234567 --reviewer bugbot --body "Fixed." --pr 1
check_eq "exit 0" 0 "$RC"
check_contains "URL on stdout" "https://github.com/" "$STDOUT_OUT"
check_contains "stderr note mentions fallback" "fallback" "$STDERR_OUT"

############################################################################
echo "== (16) cmd && echo ok prints ok on fallback path (incident pattern from #884) =="
export FAKE_INLINE_MODE="404"
export FAKE_FALLBACK_MODE="success"
CHAIN_OK=0
bash "$SCRIPT" 1234567 --reviewer bugbot --body "Fixed." --pr 1 >/dev/null 2>/dev/null \
  && CHAIN_OK=1
check_eq "cmd && echo ok works on fallback (CHAIN_OK=1)" 1 "$CHAIN_OK"

############################################################################
echo "== (17) inline 404, no --pr → resolved PR still feeds the fallback (exit 0) =="
# Behavior change (issue #1446): the former "inline 404 and no --pr → exit 3"
# leg is gone. PR_NUMBER is resolved from the comment before the inline attempt,
# so a genuine inline 404 (outdated/deleted comment) can still fall back.
export FAKE_INLINE_MODE="404"
unset FAKE_FALLBACK_MODE
export FAKE_RESOLVE_MODE="success"
export FAKE_RESOLVED_PR="42"
run_split 1234567 --reviewer bugbot --body "Fixed."
check_eq "no --pr, comment resolves: exit 0" 0 "$RC"
check_contains "stderr note mentions fallback" "fallback" "$STDERR_OUT"
check_eq "fallback targets the resolved PR" "42" "$FALLBACK_PR"

############################################################################
echo "== (18) both inline and fallback return 404 → exit 3 =="
export FAKE_INLINE_MODE="404"
export FAKE_FALLBACK_MODE="404"
run 1234567 --reviewer bugbot --body "Fixed." --pr 1
check_eq "both 404: exit 3" 3 "$RC"
check_contains "error: both endpoints 404" "404" "$OUT"

############################################################################
echo "== (19) fallback non-404 error → exit 4 =="
export FAKE_INLINE_MODE="404"
export FAKE_FALLBACK_MODE="error"
run 1234567 --reviewer bugbot --body "Fixed." --pr 1
check_eq "fallback non-404 error: exit 4" 4 "$RC"

############################################################################
echo "== (20) fallback preserves review-comment identity in a hidden marker =="
export FAKE_INLINE_MODE="404"
export FAKE_FALLBACK_MODE="success"
run_and_capture 1234567 --reviewer greptile --body "Fixed in abc1234." --pr 1
check_eq "fallback marker: exit 0" 0 "$RC"
check_contains "fallback marker names source comment" \
  "<!-- review-comment-id:1234567 -->" "$POSTED_BODY"
check_contains "fallback marker retains reply body" "Fixed in abc1234." "$POSTED_BODY"

############################################################################
echo "== (21) REGRESSION: inline reply POSTs to the PR-SCOPED route (issue #1446) =="
# The pin that would have caught the bug: before the fix the inline POST went to
# the PR-less route repos/{owner}/{repo}/pulls/comments/{id}/replies, which does
# not accept POST — every inline attempt 404'd and the PR-level fallback became
# the de-facto default on every reply, in every repo.
export FAKE_INLINE_MODE="success"
export FAKE_FALLBACK_MODE="success"
export FAKE_RESOLVE_MODE="success"
run_split 1234567 --reviewer codeant --body "Fixed in abc1234." --pr 317
check_eq "inline success: exit 0" 0 "$RC"
check_contains "URL printed on stdout" "https://github.com/" "$STDOUT_OUT"
check_not_contains "no fallback note on stderr" "fallback" "$STDERR_OUT"
check_eq "inline endpoint is the PR-scoped route" \
  "repos/test-owner/test-repo/pulls/317/comments/1234567/replies" "$POSTED_ENDPOINT"
check_eq "--pr supplied: no comment-lookup GET" "" "$RESOLVE_ENDPOINT"

############################################################################
echo "== (22) --pr omitted → PR resolved from the comment, inline succeeds =="
export FAKE_INLINE_MODE="success"
export FAKE_RESOLVE_MODE="success"
export FAKE_RESOLVED_PR="4242"
run_split 1234567 --reviewer cr --body "Fixed in abc1234."
check_eq "resolved inline success: exit 0" 0 "$RC"
check_not_contains "no fallback note on stderr" "fallback" "$STDERR_OUT"
check_eq "comment-lookup GET uses the PR-less comment route" \
  "repos/test-owner/test-repo/pulls/comments/1234567" "$RESOLVE_ENDPOINT"
check_eq "inline endpoint carries the RESOLVED PR number" \
  "repos/test-owner/test-repo/pulls/4242/comments/1234567/replies" "$POSTED_ENDPOINT"

############################################################################
echo "== (23) --pr omitted, comment 404s → exit 3, no inline POST =="
export FAKE_INLINE_MODE="success"
export FAKE_RESOLVE_MODE="404"
run_and_capture 1234567 --reviewer cr --body "Fixed in abc1234."
check_eq "comment 404: exit 3" 3 "$RC"
check_contains "error names the resolution failure" "could not resolve PR number" "$OUT"
check_eq "no inline POST attempted" "" "$POSTED_ENDPOINT"

############################################################################
echo "== (23b) --pr omitted, lookup fails non-404 (5xx) → exit 5, not 3 =="
# A transient outage must NOT masquerade as "this comment has no resolvable PR":
# exit 3 is a permanent, data-shaped verdict a caller may act on, whereas a 5xx
# means the PR is unknown, not absent. Mirrors the inline path's own
# 404-vs-non-404 split.
export FAKE_INLINE_MODE="success"
export FAKE_RESOLVE_MODE="error"
run_and_capture 1234567 --reviewer cr --body "Fixed in abc1234."
check_eq "resolver 5xx: exit 5" 5 "$RC"
check_contains "error marks the failure non-404" "non-404" "$OUT"
check_eq "no inline POST attempted" "" "$POSTED_ENDPOINT"

############################################################################
echo "== (24) --pr omitted, response has no pull_request_url → exit 3 =="
export FAKE_INLINE_MODE="success"
export FAKE_RESOLVE_MODE="nourl"
run_and_capture 1234567 --reviewer cr --body "Fixed in abc1234."
check_eq "missing pull_request_url: exit 3" 3 "$RC"
check_contains "error names the missing field" "no pull_request_url" "$OUT"
check_eq "no inline POST attempted" "" "$POSTED_ENDPOINT"

############################################################################
echo "== (25) --pr omitted, pull_request_url has no numeric PR segment → exit 3 =="
export FAKE_INLINE_MODE="success"
export FAKE_RESOLVE_MODE="nonnumeric"
run_and_capture 1234567 --reviewer cr --body "Fixed in abc1234."
check_eq "non-numeric PR segment: exit 3" 3 "$RC"
check_contains "error names the bad segment" "no numeric PR segment" "$OUT"
check_eq "no inline POST attempted" "" "$POSTED_ENDPOINT"

############################################################################
echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
