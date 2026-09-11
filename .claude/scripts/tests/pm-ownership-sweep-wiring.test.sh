#!/usr/bin/env bash
# End-to-end test for `/pm` Step 1B.5's ownership-sweep wiring (issue #1459).
# catalog: tests — Executes the real `/pm` Step 1B.5 session-listing and ownership-sweep blocks against the real `candidate-ownership.sh`, proving the `owned_dead -> adopt` branch is reachable through `/pm`'s own wiring
#
# WHAT IS UNDER TEST
#   The REAL fenced bash in `.claude/skills/pm/SKILL.md`, pulled out at run time
#   by `lib/skill-bash.sh` through its `<!-- test-anchor: … -->` markers —
#   `pm-1b5-session-listing` (builds the listing file) and
#   `pm-1b5-ownership-sweep` (runs the sweep) — executed back to back against
#   the REAL `candidate-ownership.sh` with a stubbed claim gate, `gh` and `git`.
#   Nothing here is a transcription: edit the skill and this suite runs the edit.
#
# WHY (issue #1459)
#   `candidate-ownership.sh` resolves owner liveness from a caller-supplied
#   session listing, and until #1459 nothing in the repo supplied one:
#   `SESSION_LISTING_PATH` was read but never written, so liveness was
#   `indeterminate` on every real run, which resolves to **live**, and the
#   `owned_dead -> adopt` branch — the "resume from surviving state" half of
#   issue #1431 — was unreachable in practice. The helper's own tests (3),
#   (3b), (3c) exercise adoption through the `--sessions` flag directly, which
#   is exactly the half that was never wired. This suite closes that gap by
#   running `/pm`'s blocks rather than the flag.
#
# THE FOUR CASES
#   adopt        listing built from a `list_sessions`-shaped array whose owner
#                record is archived -> `--sessions` forwarded -> action `adopt`
#   no listing   `SESSION_LISTING_RAW_PATH` unset -> DEGRADED line, no
#                `--sessions` argument, liveness indeterminate -> action `skip`
#   malformed    raw listing that is not a JSON array -> same fail-soft path as
#                "no listing" (a corrupt listing must never look like a clean one)
#   self-append  the built file carries this thread's own session record, which
#                `list_sessions` omits and the sweep would otherwise read as
#                absent -> dead -> adopt (adopting its own running work)
#
#   The first two are each other's discrimination control: the same scenario,
#   the same helper, opposite verdicts, with the only difference being whether
#   `/pm`'s own wiring produced a listing.
#
# Requires: bash 3.2+ (macOS system bash), jq. Offline: no gh, no network.
set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=.claude/scripts/tests/lib/skill-bash.sh
. "$TEST_DIR/lib/skill-bash.sh"

SCRIPTS_DIR="$(cd "$TEST_DIR/.." && pwd)"
SKILL_MD="$SCRIPTS_DIR/../skills/pm/SKILL.md"
SWEEP_SCRIPT="$SCRIPTS_DIR/candidate-ownership.sh"
REAL_SESSION_STATE="$SCRIPTS_DIR/session-state.sh"

PASS=0
FAIL=0
pass() { echo "ok   — $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL — $1" >&2; FAIL=$((FAIL + 1)); }
die() { echo "FATAL: $1" >&2; exit 1; }

check_eq() { # check_eq <desc> <expected> <actual>
  if [ "$3" = "$2" ]; then pass "$1"; else fail "$1 (expected '$2', got '$3')"; fi
}
check_contains() { # check_contains <desc> <needle> <haystack>
  case "$3" in *"$2"*) pass "$1" ;; *) fail "$1 (expected to contain '$2')" ;; esac
}
check_not_contains() { # check_not_contains <desc> <needle> <haystack>
  case "$3" in *"$2"*) fail "$1 (expected NOT to contain '$2')" ;; *) pass "$1" ;; esac
}

# Negative control: assertion helpers that cannot fail are not assertions.
check_eq "negative control" "a" "b" >/dev/null 2>&1
check_contains "negative control" "needle" "haystack" >/dev/null 2>&1
check_not_contains "negative control" "hay" "haystack" >/dev/null 2>&1
if [ "$FAIL" -ne 3 ] || [ "$PASS" -ne 0 ]; then
  echo "FAIL — negative control: helpers did not register 3 failures (got $FAIL/$PASS)" >&2
  exit 1
fi
FAIL=0; PASS=0

# ---------------------------------------------------------------------------
# Extract the live blocks. A failure here is fatal: a suite that runs zero lines
# of skill bash must never report green.
# ---------------------------------------------------------------------------
LISTING_BLOCK="$(extract_skill_bash "$SKILL_MD" pm-1b5-session-listing)" \
  || die "could not extract pm-1b5-session-listing from $SKILL_MD"
SWEEP_BLOCK="$(extract_skill_bash "$SKILL_MD" pm-1b5-ownership-sweep)" \
  || die "could not extract pm-1b5-ownership-sweep from $SKILL_MD"
[ -n "$LISTING_BLOCK" ] || die "extracted listing block is empty"
[ -n "$SWEEP_BLOCK" ] || die "extracted sweep block is empty"

# Sanity: the real blocks are under test, not a neighbour the anchor drifted onto.
case "$SWEEP_BLOCK" in
  *'--sessions "$SESSION_LISTING_PATH"'*) : ;;
  *) die "sweep block does not forward --sessions — anchor drifted?" ;;
esac
case "$LISTING_BLOCK" in
  *SESSION_LISTING_RAW_PATH*) : ;;
  *) die "listing block does not read SESSION_LISTING_RAW_PATH — anchor drifted?" ;;
esac

# ---------------------------------------------------------------------------
# Environment
# ---------------------------------------------------------------------------
TMP="$(mktemp -d)"
TMP_HOME="$(mktemp -d)"
cleanup() {
  [ -n "${TMP:-}" ] && rm -rf "$TMP"
  [ -n "${TMP_HOME:-}" ] && rm -rf "$TMP_HOME"
  return 0
}
trap cleanup EXIT
export HOME="$TMP_HOME"
mkdir -p "$HOME/.claude/handoffs"

STUB_BIN="$TMP/bin"
STUB_SCRIPTS="$TMP/scripts"
mkdir -p "$STUB_BIN" "$STUB_SCRIPTS/lib"
export CANDIDATE_OWNERSHIP_SCRIPT_DIR="$STUB_SCRIPTS"

# The real state reader, so the sweep's repo-scoped path reads are production ones.
cp "$REAL_SESSION_STATE" "$STUB_SCRIPTS/session-state.sh"
cp "$SCRIPTS_DIR/state-lock.sh" "$STUB_SCRIPTS/state-lock.sh"
cp "$SCRIPTS_DIR/lib/repo-normalizer.sh" "$STUB_SCRIPTS/lib/repo-normalizer.sh"
chmod +x "$STUB_SCRIPTS/session-state.sh" "$STUB_SCRIPTS/state-lock.sh"
export CLAUDE_SESSION_STATE_FILE="$HOME/.claude/session-state.json"
echo '{"schema_version":2,"repos":{}}' > "$CLAUDE_SESSION_STATE_FILE"

# Claim gate stub: verdict `stale`, held by $OWNER_UUID — the shape that makes a
# takeover startable, so liveness alone decides adopt vs skip.
OWNER_UUID="7c9e1a2b-3333-4ccc-9999-000000000042"
cat > "$STUB_SCRIPTS/issue-claim.sh" <<'CLAIM_STUB'
#!/usr/bin/env bash
set -uo pipefail
ISSUE=""
for a in "$@"; do case "$a" in [0-9]*) ISSUE="$a"; break ;; esac; done
jq -cn --argjson issue "${ISSUE:-0}" --arg holder "${STUB_CLAIM_HOLDER:-}" \
  '{issue:$issue, repo:null, viewer:"alice", holder:"selfholder", verdict:"stale",
    claimant:"alice", claimant_holder:$holder, claimed_at:"2026-09-01T00:00:00Z",
    stale:true, overridden:false, reason:"stub"}'
CLAIM_STUB
chmod +x "$STUB_SCRIPTS/issue-claim.sh"
export STUB_CLAIM_HOLDER="$OWNER_UUID"

cat > "$STUB_BIN/gh" <<'GH_STUB'
#!/usr/bin/env bash
set -uo pipefail
case "${1:-}" in
  issue) : ;;
  pr)    echo '[]' ;;
  repo)  echo "testowner/testrepo" ;;
  *)     echo "unexpected gh call: $*" >&2; exit 99 ;;
esac
GH_STUB
chmod +x "$STUB_BIN/gh"

BRANCHES_FILE="$TMP/branches.txt"
printf 'issue-311-feature\n' > "$BRANCHES_FILE"
REAL_GIT="$(command -v git)"
cat > "$STUB_BIN/git" <<GIT_STUB
#!/usr/bin/env bash
set -uo pipefail
if [ "\${1:-}" = "for-each-ref" ]; then
  cat "\${FAKE_BRANCHES_FILE:-/dev/null}" 2>/dev/null || true
  exit 0
fi
exec "$REAL_GIT" "\$@"
GIT_STUB
chmod +x "$STUB_BIN/git"
export PATH="$STUB_BIN:$PATH"
export FAKE_BRANCHES_FILE="$BRANCHES_FILE"

export CLAUDE_SESSION_REPO="testowner/testrepo"
export CLAUDE_SESSION_ID="aa11bb22-4444-4ddd-8888-000000000009"
export CLAUDE_CLAIM_HOLDER="selfholder"

# Logging shim in front of the REAL sweep, so "did /pm forward --sessions?" is
# asserted against the argv that actually reached the helper.
ARGV_LOG="$TMP/sweep-argv.log"
: > "$ARGV_LOG"
cat > "$TMP/candidate-ownership-shim.sh" <<SHIM
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$ARGV_LOG"
exec bash "$SWEEP_SCRIPT" "\$@"
SHIM
chmod +x "$TMP/candidate-ownership-shim.sh"

# The `list_sessions` payload shape, verbatim from the field capture on issue
# #1459: `local_`-prefixed sessionId, no `status` string, state in booleans.
RAW_LISTING="$TMP/raw-listing.json"
cat > "$RAW_LISTING" <<LISTING_JSON
[
  {"sessionId":"local_$OWNER_UUID","title":"[#311] old coding thread",
   "cwd":"/w/issue-311-feature","branch":"issue-311-feature",
   "isArchived":true,"isRunning":false,
   "lastActivityAt":"2026-09-01T12:00:00Z","group":"older"},
  {"sessionId":"local_ffffffff-5555-4eee-7777-000000000001","title":"unrelated",
   "isArchived":false,"isRunning":true,
   "lastActivityAt":"2026-09-10T12:00:00Z","group":"today"}
]
LISTING_JSON

# Every temp file the blocks create lands here, so "did the block clean up after
# itself?" is a count of an isolated directory rather than a glob over a shared
# /tmp that any other process may be writing to.
LISTING_TMPDIR="$TMP/listing-tmp"
mkdir -p "$LISTING_TMPDIR"

# run_blocks <extra-shell-prelude> -> sets RUN_OUT / RUN_ERR / RUN_RC
run_blocks() {
  local prelude="$1" errfile="$TMP/run.err"
  : > "$ARGV_LOG"
  RUN_OUT="$(bash -c "
export TMPDIR='$LISTING_TMPDIR/'
CANDIDATE_OWNERSHIP='$TMP/candidate-ownership-shim.sh'
BATCH_ISSUES=(311)
$prelude
$LISTING_BLOCK
$SWEEP_BLOCK
printf '===SWEEP===\n%s\n' \"\$SWEEP\"
" 2>"$errfile")"
  RUN_RC=$?
  RUN_ERR="$(cat "$errfile")"
}
sweep_json() { # the NDJSON the sweep emitted, stripped of the block's own output
  printf '%s\n' "$RUN_OUT" | awk 'f; /^===SWEEP===$/ {f=1}'
}

############################################################################
echo "== (1) listing supplied — /pm's own wiring reaches the adopt branch =="
run_blocks "export SESSION_LISTING_RAW_PATH='$RAW_LISTING'"
OUT_JSON="$(sweep_json)"
check_eq "the blocks run clean" 0 "$RUN_RC"
check_eq "and say nothing on stderr" "" "$RUN_ERR"
check_contains "the sweep was invoked with --sessions" "--sessions" "$(cat "$ARGV_LOG")"
check_not_contains "no degradation was reported" "DEGRADED:" "$RUN_OUT"
check_eq "one sweep line for the candidate" "1" \
  "$(printf '%s' "$OUT_JSON" | jq -s 'length')"
check_eq "the archived owner classifies dead" "dead" \
  "$(printf '%s' "$OUT_JSON" | jq -r '.liveness')"
check_eq "verdict owned_dead" "owned_dead" \
  "$(printf '%s' "$OUT_JSON" | jq -r '.verdict')"
check_eq "ACTION IS ADOPT — reachable through /pm, not only via --sessions" "adopt" \
  "$(printf '%s' "$OUT_JSON" | jq -r '.action')"
check_eq "and it resumes from the surviving branch" "branch" \
  "$(printf '%s' "$OUT_JSON" | jq -r '.adopt.from')"
# The temp listing is this thread's own file; leaving it behind would pile up
# one per sweeping tick, and a later tick must rebuild from a fresh call anyway.
LEFTOVER="$(find "$LISTING_TMPDIR" -type f | wc -l | tr -d ' ')"
check_eq "the temp listing is cleaned up after the sweep reads it" "0" "$LEFTOVER"

############################################################################
echo
echo "== (2) no listing (control) — same scenario stays surface-and-skip =="
run_blocks "unset SESSION_LISTING_RAW_PATH"
OUT_JSON="$(sweep_json)"
check_eq "the blocks still run clean" 0 "$RUN_RC"
check_not_contains "no --sessions argument was forwarded" "--sessions" "$(cat "$ARGV_LOG")"
check_contains "the missing listing is named, not swallowed" \
  "DEGRADED: no session listing" "$RUN_OUT"
check_eq "liveness indeterminate" "indeterminate" \
  "$(printf '%s' "$OUT_JSON" | jq -r '.liveness')"
check_eq "so the owner is treated as live" "owned_live" \
  "$(printf '%s' "$OUT_JSON" | jq -r '.verdict')"
check_eq "and the candidate is skipped, never adopted" "skip" \
  "$(printf '%s' "$OUT_JSON" | jq -r '.action')"

############################################################################
echo
echo "== (3) malformed raw listing — fails soft, never looks clean =="
BAD_LISTING="$TMP/bad-listing.json"
printf '{"sessions": not json <<<' > "$BAD_LISTING"
run_blocks "export SESSION_LISTING_RAW_PATH='$BAD_LISTING'"
OUT_JSON="$(sweep_json)"
check_not_contains "a corrupt listing is not forwarded" "--sessions" "$(cat "$ARGV_LOG")"
check_contains "and it is named" "DEGRADED: no session listing" "$RUN_OUT"
check_eq "the sweep still ran over the candidate" "311" \
  "$(printf '%s' "$OUT_JSON" | jq -r '.issue')"
check_eq "surface-and-skip, not adopt" "skip" \
  "$(printf '%s' "$OUT_JSON" | jq -r '.action')"

############################################################################
echo
echo "== (4) the built listing carries this thread's own session record =="
# `list_sessions` excludes the calling session, and a session absent from a
# listing that WAS read classifies dead -> adopt. Without the append, a /pm
# thread could adopt work its own background tasks are running.
BUILT_PATH="$(bash -c "
export TMPDIR='$LISTING_TMPDIR/'
export SESSION_LISTING_RAW_PATH='$RAW_LISTING'
$LISTING_BLOCK
printf '%s' \"\$SESSION_LISTING_PATH\"
")"
if [ -z "$BUILT_PATH" ] || [ ! -r "$BUILT_PATH" ]; then
  fail "the listing block produced no readable file"
else
  pass "the listing block wrote a file"
  check_eq "this session's id is present in the built listing" "1" \
    "$(jq --arg id "$CLAUDE_SESSION_ID" \
       '[.[] | select(.sessionId == $id)] | length' "$BUILT_PATH")"
  check_eq "and it is marked running, not archived" "true" \
    "$(jq --arg id "$CLAUDE_SESSION_ID" \
       'any(.[]; .sessionId == $id and .isRunning == true and .isArchived == false)' \
       "$BUILT_PATH")"
  check_eq "every record from the tool survived the rewrite" "3" \
    "$(jq 'length' "$BUILT_PATH")"
  rm -f "$BUILT_PATH"
fi

############################################################################
echo
echo "== (5) a listing that filled its own limit is refused as possibly truncated =="
# RAW_LISTING holds 2 records; asking for 2 is indistinguishable from a cut
# page. A cut page hides live owners, and a hidden owner classifies dead ->
# adopt, so the block must not use it.
run_blocks "export SESSION_LISTING_RAW_PATH='$RAW_LISTING'
export SESSION_LISTING_LIMIT=2"
OUT_JSON="$(sweep_json)"
check_not_contains "a possibly-truncated listing is not forwarded" \
  "--sessions" "$(cat "$ARGV_LOG")"
check_contains "and the truncation is named, not swallowed" \
  "possibly truncated" "$RUN_OUT"
check_eq "surface-and-skip, not adopt" "skip" \
  "$(printf '%s' "$OUT_JSON" | jq -r '.action')"

# Negative control: the SAME listing under a limit it did not fill is used.
# Without this, (5) would pass even if the block had simply stopped working.
run_blocks "export SESSION_LISTING_RAW_PATH='$RAW_LISTING'
export SESSION_LISTING_LIMIT=500"
OUT_JSON="$(sweep_json)"
check_contains "an unfilled limit still forwards the listing" \
  "--sessions" "$(cat "$ARGV_LOG")"
check_not_contains "and reports no degradation" "DEGRADED:" "$RUN_OUT"
check_eq "so the archived owner still reaches adopt" "adopt" \
  "$(printf '%s' "$OUT_JSON" | jq -r '.action')"

############################################################################
echo
echo "== (6) an unknown CLAUDE_SESSION_ID degrades rather than self-adopting =="
# With no session id there is no self-record to append, and `list_sessions`
# excludes the caller — so forwarding the listing would let this thread's own
# work classify dead -> adopt, the exact failure the append prevents.
run_blocks "export SESSION_LISTING_RAW_PATH='$RAW_LISTING'
export CLAUDE_SESSION_ID=''"
OUT_JSON="$(sweep_json)"
check_not_contains "a self-recordless listing is not forwarded" \
  "--sessions" "$(cat "$ARGV_LOG")"
check_contains "and the reason names the missing session id" \
  "CLAUDE_SESSION_ID is unset" "$RUN_OUT"
check_eq "liveness indeterminate" "indeterminate" \
  "$(printf '%s' "$OUT_JSON" | jq -r '.liveness')"
check_eq "surface-and-skip, not adopt" "skip" \
  "$(printf '%s' "$OUT_JSON" | jq -r '.action')"

############################################################################
echo
echo "== summary: $PASS passed, $FAIL failed =="
if [ "$FAIL" -gt 0 ]; then
  echo "FAILED: /pm ownership-sweep wiring tests" >&2
  exit 1
fi
echo "OK: /pm ownership-sweep wiring tests passed"
