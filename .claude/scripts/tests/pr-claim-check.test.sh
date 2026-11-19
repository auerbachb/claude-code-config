#!/usr/bin/env bash
# Offline tests for pr-claim-check.sh and pr-claim-line.sh (issue #2288 — PR-side claim gate).
# catalog: tests — Tests for `pr-claim-check.sh` and `pr-claim-line.sh` against a stateful `gh` stub that runs the REAL issue-claim.sh, including the --report CI mapping and comment de-duplication
#
# The REAL pr-claim-check.sh, pr-claim-line.sh and issue-claim.sh run here. Only
# `gh` and `hostname` are stubbed. The stub serves fixture files from a state
# directory, so a comment POSTed by --report shows up on the next read, which
# is what the de-duplication case depends on.
#
# Run from repo root:
#   bash .claude/scripts/tests/pr-claim-check.test.sh
set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
CHECK="$REPO_ROOT/.claude/scripts/pr-claim-check.sh"
LINE="$REPO_ROOT/.claude/scripts/pr-claim-line.sh"

TMP="$(mktemp -d)"
TMP_HOME="$(mktemp -d)"
cleanup() { rm -rf "$TMP" "$TMP_HOME"; }
trap cleanup EXIT
export HOME="$TMP_HOME"
mkdir -p "$HOME/.claude"

# Distinctive values: none of these may appear in any script output.
CANARY_HOST="canary-host-7c1e"
CANARY_PATH="/Users/canary-user/private-checkout"
RAW_OLD_HOLDER="old-style:$CANARY_HOST:$CANARY_PATH"

PASS=0
FAIL=0
ok()   { PASS=$((PASS + 1)); echo "ok   — $1"; }
bad()  { FAIL=$((FAIL + 1)); echo "FAIL — $1"; }
check_eq() {
  if [[ "$3" == "$2" ]]; then ok "$1"; else bad "$1 (expected '$2', got '$3')"; fi
}
check_contains() {
  if [[ "$3" == *"$2"* ]]; then ok "$1"; else bad "$1 (expected to contain '$2', got '$3')"; fi
}
check_absent() {
  if [[ "$3" == *"$2"* ]]; then bad "$1 (found forbidden '$2')"; else ok "$1"; fi
}

# portable sha256 hex digest, first 12 chars, prefixed h-
expect_digest() {
  local d
  if command -v shasum >/dev/null 2>&1; then
    d="$(printf '%s' "$1" | shasum -a 256 | cut -c1-12)"
  else
    d="$(printf '%s' "$1" | sha256sum | cut -c1-12)"
  fi
  printf 'h-%s' "$d"
}

# ISO-8601 UTC timestamp N hours in the past (GNU date first, see issue #1587).
iso_ago() {
  local epoch
  epoch=$(( $(date -u +%s) - $1 * 3600 ))
  date -u -d "@$epoch" +%FT%TZ 2>/dev/null && return 0
  date -u -r "$epoch" +%FT%TZ 2>/dev/null && return 0
  return 1
}

# ---- stub bin: gh + hostname ---------------------------------------------------
STUB_BIN="$TMP/bin"
mkdir -p "$STUB_BIN"
export FAKE_STATE="$TMP/state"
mkdir -p "$FAKE_STATE"
S="$FAKE_STATE"

cat > "$STUB_BIN/hostname" <<HOST
#!/usr/bin/env bash
echo "$CANARY_HOST"
HOST
chmod +x "$STUB_BIN/hostname"

cat > "$STUB_BIN/gh" <<'STUB'
#!/usr/bin/env bash
# Stateful gh stub for pr-claim-check tests. Fixtures live in $FAKE_STATE.
set -uo pipefail
S="$FAKE_STATE"

case "${1:-}" in
  repo)
    echo '{"nameWithOwner":"owner/repo"}'
    exit 0 ;;
  api)
    shift
    METHOD="GET"; ENDPOINT=""; BODY=""
    while [[ $# -gt 0 ]]; do
      case "$1" in
        -X) METHOD="$2"; shift 2 ;;
        --paginate|--slurp) shift ;;
        --jq) shift 2 ;;
        -f|-F|--raw-field|--field)
          [[ "$2" == body=* ]] && BODY="${2#body=}"; shift 2 ;;
        *) [[ -z "$ENDPOINT" ]] && ENDPOINT="$1"; shift ;;
      esac
    done
    ENDPOINT="${ENDPOINT%%\?*}"
    # Endpoint log: lets a test prove a call (GET /user) never happened.
    [[ -d "$S" ]] && printf '%s %s\n' "$METHOD" "$ENDPOINT" >> "$S/calls.log"
    case "$ENDPOINT" in
      user)
        # FAKE_USER_FAIL mimics the Actions installation token, which cannot
        # call GET /user (issue #2412).
        if [[ -n "${FAKE_USER_FAIL:-}" ]]; then
          echo "gh: Resource not accessible by integration (HTTP 403)" >&2; exit 1
        fi
        echo "viewer-stub"; exit 0 ;;
      repos/*/pulls/*)
        if [[ -e "$S/pr_garbage" ]]; then echo "<html>maintenance page</html>"; exit 0; fi
        if [[ -f "$S/pr.json" && ! -e "$S/pr_fail" ]]; then cat "$S/pr.json"; exit 0; fi
        echo "gh: HTTP 404: Not Found" >&2; exit 1 ;;
      */issues/*/comments)
        N="${ENDPOINT%/comments}"; N="${N##*/}"
        if [[ "$METHOD" == "POST" ]]; then
          CUR="$S/comments-$N.json"
          [[ -f "$CUR" ]] || echo '[]' > "$CUR"
          jq --arg b "$BODY" '. + [{id: (length + 1000), user: {login: "bot-stub"}, created_at: "2026-11-13T00:00:00Z", body: $b}]' "$CUR" > "$CUR.tmp" \
            && mv "$CUR.tmp" "$CUR"
          echo '{}'; exit 0
        fi
        if [[ -n "${FAKE_COMMENTS_FAIL:-}" && "$FAKE_COMMENTS_FAIL" == "$N" ]]; then
          echo "gh: HTTP 500: internal server error" >&2; exit 1
        fi
        if [[ -e "$S/comments_garbage" ]]; then echo "<html>maintenance page</html>"; exit 0; fi
        if [[ -f "$S/comments-$N.json" ]]; then cat "$S/comments-$N.json"; else echo '[]'; fi
        exit 0 ;;
      */issues/*/timeline)
        echo '[]'; exit 0 ;;
      */issues/*)
        N="${ENDPOINT##*/}"
        if [[ -e "$S/issue_garbage" ]]; then echo "<html>maintenance page</html>"; exit 0; fi
        if [[ -f "$S/issue-$N.json" ]]; then cat "$S/issue-$N.json"; exit 0; fi
        echo "gh: HTTP 404: Not Found" >&2; exit 1 ;;
      *)
        echo "unexpected gh api endpoint: $ENDPOINT" >&2; exit 99 ;;
    esac ;;
  label|issue)
    # issue-claim.sh --check never writes; a write here means the test is wrong.
    echo "unexpected write-side gh call: $*" >&2; exit 99 ;;
  *)
    echo "unexpected gh call: $*" >&2; exit 99 ;;
esac
STUB
chmod +x "$STUB_BIN/gh"

# ---- fixtures -------------------------------------------------------------------
reset_state() {
  rm -rf "$S"
  mkdir -p "$S"
  export FAKE_VIEWER="viewer-stub"
  unset FAKE_COMMENTS_FAIL FAKE_USER_FAIL
  unset CLAUDE_CLAIM_HOLDER CLAUDE_SESSION_REPO PR_STATE_FIXTURE PR_MERGED_AT_FIXTURE
}

# set_pr <body> <author login> <author type>
# PR_STATE_FIXTURE: open (default), closed, invalid, or __missing__ (no state field).
# PR_MERGED_AT_FIXTURE: when set, the PR carries that merged_at (a merged PR).
set_pr() {
  jq -cn --arg b "$1" --arg l "$2" --arg t "$3" \
    --arg st "${PR_STATE_FIXTURE:-open}" --arg mg "${PR_MERGED_AT_FIXTURE:-}" \
    '{number: 900, user: {login: $l, type: $t}, body: $b}
     + (if $st == "__missing__" then {} else {state: $st} end)
     + (if $mg == "" then {} else {merged_at: $mg} end)' > "$S/pr.json"
}

# set_issue <number> <open|closed> [labeled]
set_issue() {
  local labels='[]'
  [[ "${3:-}" == "labeled" ]] && labels='[{"name":"in-progress"}]'
  jq -cn --argjson n "$1" --arg s "$2" --argjson lb "$labels" \
    '{number: $n, state: $s, labels: $lb, assignees: []}' > "$S/issue-$1.json"
}

# add_claim <issue> <raw holder> <provider> <device> <label> <created_at>
add_claim() {
  local payload body
  payload="$(jq -cn --arg h "$2" --arg p "$3" --arg d "$4" --arg l "$5" --arg s "$6" \
    '{holder: $h, login: "alice", since: $s, provider: $p, device: $d, label: $l}')"
  body="$(printf '🔒 Claimed by `alice` for active work. Held by %s on device %s.\n\n<!-- claude-claim: %s -->' "$3" "$4" "$payload")"
  jq -cn --arg b "$body" --arg t "$6" '[{id: 101, user: {login: "alice"}, created_at: $t, body: $b}]' > "$S/comments-$1.json"
}

NOW="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
PATH="$STUB_BIN:$PATH"
export PATH

# run_check <extra args...> -> sets OUT and RC
run_check() {
  OUT="$(bash "$CHECK" 900 --repo owner/repo "$@" 2>"$TMP/stderr")"
  RC=$?
}
verdict_of() { printf '%s' "$OUT" | jq -r '.verdict' 2>/dev/null; }
outcome_of() { printf '%s' "$OUT" | jq -r ".issues[$1].outcome" 2>/dev/null; }

# ==== A. pr-claim-check.sh verdicts ===========================================
echo "== A. verdicts =="

reset_state
MATCH_RAW="claude-thread-alpha"
MATCH_DIGEST="$(expect_digest "$MATCH_RAW")"
set_issue 2288 open labeled
add_claim 2288 "$MATCH_RAW" "claude" "laptop" "run-1" "$NOW"
set_pr "Closes #2288

<!-- claim-holder: $MATCH_DIGEST -->" "human-dev" "User"
run_check
check_eq "A1 holder matches -> match" "match" "$(verdict_of)"
check_eq "A1 exit 0" "0" "$RC"

reset_state
set_issue 2288 open labeled
add_claim 2288 "codex-thread-beta" "codex" "box-7" "run-9" "$NOW"
set_pr "Closes #2288

<!-- claim-holder: $(expect_digest "some-other-thread") -->" "human-dev" "User"
run_check
check_eq "A2 different fresh holder -> foreign" "foreign" "$(verdict_of)"
check_eq "A2 foreign carries provider" "codex" "$(printf '%s' "$OUT" | jq -r '.issues[0].provider')"
check_eq "A2 foreign carries device" "box-7" "$(printf '%s' "$OUT" | jq -r '.issues[0].device')"
check_eq "A2 foreign carries label" "run-9" "$(printf '%s' "$OUT" | jq -r '.issues[0].label')"
check_eq "A2 exit 0 without --report" "0" "$RC"

reset_state
set_issue 2288 open labeled
add_claim 2288 "$RAW_OLD_HOLDER" "codex" "box-7" "run-9" "$NOW"
set_pr "Closes #2288

<!-- claim-holder: $(expect_digest "some-other-thread") -->" "human-dev" "User"
run_check
check_absent "A3 raw holder with hostname/path never printed (stdout)" "$CANARY_HOST" "$OUT"
check_absent "A3 raw holder path never printed" "$CANARY_PATH" "$OUT"
check_absent "A3 raw holder never printed (full token)" "$RAW_OLD_HOLDER" "$OUT"
check_absent "A3 raw holder never on stderr" "$CANARY_HOST" "$(cat "$TMP/stderr")"

reset_state
set_issue 2288 open
set_pr "Closes #2288" "human-dev" "User"
run_check
check_eq "A4 unclaimed issue -> pass_unclaimed" "pass_unclaimed" "$(verdict_of)"
check_eq "A4 issue outcome pass_unclaimed" "pass_unclaimed" "$(outcome_of 0)"

reset_state
set_issue 2288 open labeled
add_claim 2288 "claude-old-thread" "claude" "laptop" "run-2" "$(iso_ago 10)"
set_pr "Closes #2288" "human-dev" "User"
run_check
check_eq "A5 stale claim -> pass_unclaimed" "pass_unclaimed" "$(verdict_of)"

reset_state
set_issue 2288 open labeled
add_claim 2288 "$MATCH_RAW" "claude" "laptop" "run-1" "$NOW"
set_pr "Closes #2288" "human-dev" "User"
run_check
check_eq "A6 claimed, PR has no claim line -> no_claim_line" "no_claim_line" "$(verdict_of)"
check_eq "A6 claim_line false" "false" "$(printf '%s' "$OUT" | jq -r '.claim_line')"

reset_state
set_pr "Refs #2288 only" "human-dev" "User"
run_check
check_eq "A7 no closing keyword -> skipped" "skipped" "$(verdict_of)"
check_eq "A7 reason no_linked_issue" "no_linked_issue" "$(printf '%s' "$OUT" | jq -r '.reason')"

reset_state
set_pr "Work notes:

\`\`\`
Closes #2288
\`\`\`" "human-dev" "User"
run_check
check_eq "A8 closing keyword only in a code fence -> skipped" "skipped" "$(verdict_of)"

reset_state
set_pr "Notes <!-- Closes #2288 --> nothing else" "human-dev" "User"
run_check
check_eq "A9 closing keyword only in an HTML comment -> skipped" "skipped" "$(verdict_of)"

reset_state
set_issue 2288 open labeled
add_claim 2288 "$MATCH_RAW" "claude" "laptop" "run-1" "$NOW"
set_pr "Closes #2288" "dependabot[bot]" "Bot"
run_check
check_eq "A10 bot author -> skipped" "skipped" "$(verdict_of)"
check_eq "A10 reason bot_author" "bot_author" "$(printf '%s' "$OUT" | jq -r '.reason')"

reset_state
set_issue 2288 open labeled
add_claim 2288 "$MATCH_RAW" "claude" "laptop" "run-1" "$NOW"
set_pr "Closes #2288

<!-- claim-holder: $MATCH_DIGEST -->" "human-dev" "User"
FAKE_COMMENTS_FAIL=2288 run_check
check_eq "A11 claim read fails -> unverifiable" "unverifiable" "$(verdict_of)"
if [[ "$(verdict_of)" == "match" ]]; then bad "A11 must never read as match"; else ok "A11 never passes as match"; fi

reset_state
set_issue 2288 open labeled
add_claim 2288 "$MATCH_RAW" "claude" "laptop" "run-1" "$NOW"
set_issue 2290 open labeled
add_claim 2290 "codex-thread-beta" "codex" "box-7" "run-9" "$NOW"
set_pr "Closes #2288
Fixes #2290

<!-- claim-holder: $MATCH_DIGEST -->" "human-dev" "User"
run_check
check_eq "A12 one match + one foreign -> foreign" "foreign" "$(verdict_of)"
check_eq "A12 two issue entries" "2" "$(printf '%s' "$OUT" | jq -r '.issues | length')"

reset_state
set_issue 2288 open labeled
add_claim 2288 "$MATCH_RAW" "claude" "laptop" "run-1" "$NOW"
set_pr "Closes #2288

<!-- claim-holder: not-a-holder -->" "human-dev" "User"
run_check
check_eq "A13 garbled claim-holder marker -> unverifiable" "unverifiable" "$(verdict_of)"

reset_state
set_issue 2288 closed labeled
set_pr "Closes #2288" "human-dev" "User"
run_check
check_eq "A14 closed issue -> unverifiable" "unverifiable" "$(verdict_of)"

reset_state
set_pr "Closes #2288" "human-dev" "User"
run_check
check_eq "A15 issue does not exist -> unverifiable" "unverifiable" "$(verdict_of)"

reset_state
set_pr "Closes #2288" "human-dev" "User"
touch "$S/pr_fail"
run_check
check_eq "A16 PR read fails -> unverifiable" "unverifiable" "$(verdict_of)"

reset_state
set_pr "Example:

\`\`\`\`markdown
\`\`\`
Closes #2288
\`\`\`
\`\`\`\`" "human-dev" "User"
run_check
check_eq "A17 keyword inside a longer fence, after a shorter fence line -> skipped" "skipped" "$(verdict_of)"

reset_state
set_issue 2288 open labeled
add_claim 2288 "$MATCH_RAW" "claude" "laptop" "run-1" "$NOW"
set_pr "Closes#2288" "human-dev" "User"
run_check
check_eq "A18 keyword with no space before the number is linked -> no_claim_line" "no_claim_line" "$(verdict_of)"

# ==== A2. fail-closed reads and claim-line parsing (issue #2288 review) =======
echo "== A2. fail-closed reads and claim-line parsing =="

reset_state
set_issue 2288 open labeled
add_claim 2288 "$MATCH_RAW" "claude" "laptop" "run-1" "$NOW"
set_pr "Closes #2288

<!-- claim-holder: $MATCH_DIGEST -->" "human-dev" "User"
touch "$S/pr_garbage"
run_check
check_eq "A19 PR read returns non-JSON -> unverifiable" "unverifiable" "$(verdict_of)"
check_eq "A19 non-JSON PR read exits 0" "0" "$RC"

reset_state
set_issue 2288 open labeled
add_claim 2288 "$MATCH_RAW" "claude" "laptop" "run-1" "$NOW"
set_pr "Closes #2288

<!-- claim-holder: $MATCH_DIGEST -->" "human-dev" "User"
touch "$S/issue_garbage"
run_check
check_eq "A20 issue read returns non-JSON -> unverifiable" "unverifiable" "$(verdict_of)"

reset_state
set_issue 2288 open labeled
add_claim 2288 "$MATCH_RAW" "claude" "laptop" "run-1" "$NOW"
set_pr "Closes #2288

<!-- claim-holder: $MATCH_DIGEST -->" "human-dev" "User"
touch "$S/comments_garbage"
run_check
check_eq "A21 claim comments return non-JSON -> never match" "unverifiable" "$(verdict_of)"

reset_state
set_issue 2288 open labeled
add_claim 2288 "$MATCH_RAW" "claude" "laptop" "run-1" "$NOW"
set_pr "Closes #2288

<!-- claim-holder: $MATCH_DIGEST -->
<!-- claim-holder: $(expect_digest "some-other-thread") -->" "human-dev" "User"
run_check
check_eq "A22 two different claim-holder lines -> unverifiable" "unverifiable" "$(verdict_of)"
check_eq "A22 reason names the ambiguity" "pr_claim_line_ambiguous" "$(printf '%s' "$OUT" | jq -r '.issues[0].reason')"

reset_state
set_issue 2288 open labeled
add_claim 2288 "$MATCH_RAW" "claude" "laptop" "run-1" "$NOW"
set_pr "Closes #2288

<!-- claim-holder: $MATCH_DIGEST -->
<!-- claim-holder: $MATCH_DIGEST -->" "human-dev" "User"
run_check
check_eq "A23 identical duplicate claim-holder lines -> match" "match" "$(verdict_of)"

reset_state
set_issue 2288 open labeled
add_claim 2288 "$MATCH_RAW" "claude" "laptop" "run-1" "$NOW"
set_pr "Closes #2288

\`\`\`
<!-- claim-holder: $MATCH_DIGEST -->
\`\`\`" "human-dev" "User"
run_check
check_eq "A24 claim-holder line only inside a code fence is ignored -> no_claim_line" "no_claim_line" "$(verdict_of)"

reset_state
set_issue 2288 open labeled
add_claim 2288 "$MATCH_RAW" "claude" "laptop" "run-1" "$NOW"
set_pr "Closes #2288

Backticked example: \`<!-- claim-holder: $MATCH_DIGEST -->\` in a sentence.

<!-- claim-holder: $MATCH_DIGEST -->" "human-dev" "User"
run_check
check_eq "A25 sentence mention plus real own-line marker -> match (one marker)" "match" "$(verdict_of)"

# ==== A3. GFM fence rules (issue #2412) =======================================
echo "== A3. GFM fence rules =="

# Each line below looks like a fence but is not one under GFM, so the closing
# keyword and the claim line after it stay visible: the verdict is match, not
# skipped (a hidden keyword) or no_claim_line (a hidden marker).
TAB="$(printf '\t')"
for NOT_FENCE in "    \`\`\`" "$TAB\`\`\`" "\`\`\` info\`with-backtick"; do
  reset_state
  set_issue 2288 open labeled
  add_claim 2288 "$MATCH_RAW" "claude" "laptop" "run-1" "$NOW"
  set_pr "Intro.

$NOT_FENCE
Closes #2288

<!-- claim-holder: $MATCH_DIGEST -->" "human-dev" "User"
  run_check
  check_eq "A26 not a fence ($(printf '%s' "$NOT_FENCE" | tr '\t' 'T')): keyword and claim line visible -> match" "match" "$(verdict_of)"
done

reset_state
set_pr "Example:

~~~ info\`with-backtick
Closes #2288
~~~" "human-dev" "User"
run_check
check_eq "A27 tilde opener with a backtick info string still hides content -> skipped" "skipped" "$(verdict_of)"

reset_state
set_pr "Example:

\`\`\`
    \`\`\`
Closes #2288
\`\`\`" "human-dev" "User"
run_check
check_eq "A28 a four-space closer does not close a real fence -> skipped" "skipped" "$(verdict_of)"

reset_state
set_pr "Example:

   \`\`\`
Closes #2288
   \`\`\`" "human-dev" "User"
run_check
check_eq "A29 three-space indented fence still hides content -> skipped" "skipped" "$(verdict_of)"

reset_state
set_issue 2288 open labeled
add_claim 2288 "$MATCH_RAW" "claude" "laptop" "run-1" "$NOW"
CR="$(printf '\r')"
set_pr "Example:$CR
$CR
\`\`\`$CR
not a keyword$CR
\`\`\`$CR
Closes #2288$CR
$CR
<!-- claim-holder: $MATCH_DIGEST -->$CR" "human-dev" "User"
run_check
check_eq "A29b CRLF body: the closing fence still closes -> match" "match" "$(verdict_of)"

# ==== A4. Actions token cannot call GET /user (issue #2412) ===================
echo "== A4. viewer lookup unavailable =="

reset_state
set_issue 2288 open labeled
add_claim 2288 "$MATCH_RAW" "claude" "laptop" "run-1" "$NOW"
set_pr "Closes #2288

<!-- claim-holder: $MATCH_DIGEST -->" "human-dev" "User"
export FAKE_USER_FAIL=1
run_check
check_eq "A30 GET /user fails, holder matches -> match" "match" "$(verdict_of)"
check_eq "A30 no GET /user request was made" "0" "$(grep -c ' user$' "$S/calls.log" 2>/dev/null || true)"
check_contains "A30 the claim comments were read" "GET repos/owner/repo/issues/2288/comments" "$(cat "$S/calls.log")"

reset_state
set_issue 2288 open labeled
add_claim 2288 "codex-thread-beta" "codex" "box-7" "run-9" "$NOW"
set_pr "Closes #2288

<!-- claim-holder: $(expect_digest "some-other-thread") -->" "human-dev" "User"
export FAKE_USER_FAIL=1
run_check
check_eq "A31 GET /user fails, other holder -> foreign" "foreign" "$(verdict_of)"
OUT="$(bash "$CHECK" 900 --repo owner/repo --report 2>"$TMP/stderr")"; RC=$?
check_eq "A31 foreign --report exits 1" "1" "$RC"
check_eq "A31 no GET /user request was made" "0" "$(grep -c ' user$' "$S/calls.log" 2>/dev/null || true)"
unset FAKE_USER_FAIL

# ==== B. pr-claim-line.sh =====================================================
echo "== B. claim line =="

LINE_OUT="$(bash "$LINE" 2288 --holder "$RAW_OLD_HOLDER")"
check_eq "B1 old-format holder prints an h- digest line" "1" \
  "$(printf '%s' "$LINE_OUT" | LC_ALL=C grep -cE '^<!-- claim-holder: h-[0-9a-f]{12} -->$')"
check_absent "B1 output has no hostname" "$CANARY_HOST" "$LINE_OUT"
check_absent "B1 output has no path" "$CANARY_PATH" "$LINE_OUT"
check_eq "B1 value is the SHA-256 digest of the raw holder" \
  "<!-- claim-holder: $(expect_digest "$RAW_OLD_HOLDER") -->" "$LINE_OUT"

PASS_THROUGH="$(bash "$LINE" 2288 --holder h-0123456789ab)"
check_eq "B2 h-<12 hex> holder passes through unchanged" "<!-- claim-holder: h-0123456789ab -->" "$PASS_THROUGH"

ENV_OUT="$(CLAUDE_CLAIM_HOLDER="env-thread-gamma" bash "$LINE" 2288)"
check_eq "B3 CLAUDE_CLAIM_HOLDER is hashed" "<!-- claim-holder: $(expect_digest "env-thread-gamma") -->" "$ENV_OUT"

SESS_HOME="$(mktemp -d)"
mkdir -p "$SESS_HOME/.claude"
jq -cn '{repos: {"auerbachb/claude-code-config": {pipelines: {"2288": {claim_holder: "sess-thread-delta"}}}}}' \
  > "$SESS_HOME/.claude/session-state.json"
SESS_OUT="$(HOME="$SESS_HOME" CLAUDE_SESSION_REPO="auerbachb/claude-code-config" bash "$LINE" 2288)"
check_eq "B4 session-state holder used when env unset" "<!-- claim-holder: $(expect_digest "sess-thread-delta") -->" "$SESS_OUT"
rm -rf "$SESS_HOME"

# B6-B8: CLAUDE_SESSION_ID is the holder issue-claim.sh uses when no
# CLAUDE_CLAIM_HOLDER is set; a recorded session-state holder comes first.
EMPTY_HOME="$(mktemp -d)"
SID_OUT="$(env -u CLAUDE_CLAIM_HOLDER HOME="$EMPTY_HOME" CLAUDE_SESSION_ID="sess-id-epsilon" bash "$LINE" 2288)"
check_eq "B6 CLAUDE_SESSION_ID alone is hashed" "<!-- claim-holder: $(expect_digest "sess-id-epsilon") -->" "$SID_OUT"

SID_HOME="$(mktemp -d)"
mkdir -p "$SID_HOME/.claude"
jq -cn '{repos: {"auerbachb/claude-code-config": {pipelines: {"2288": {claim_holder: "sess-thread-zeta"}}}}}' \
  > "$SID_HOME/.claude/session-state.json"
REC_OUT="$(env -u CLAUDE_CLAIM_HOLDER HOME="$SID_HOME" CLAUDE_SESSION_REPO="auerbachb/claude-code-config" CLAUDE_SESSION_ID="sess-id-epsilon" bash "$LINE" 2288)"
check_eq "B7 recorded holder beats CLAUDE_SESSION_ID" "<!-- claim-holder: $(expect_digest "sess-thread-zeta") -->" "$REC_OUT"
if [[ "$REC_OUT" == "$SID_OUT" ]]; then bad "B7 must differ from the session-id digest"; else ok "B7 differs from the session-id digest"; fi
rm -rf "$EMPTY_HOME" "$SID_HOME"

BAD_ISSUE="$(bash "$LINE" abc 2>/dev/null; echo "rc=$?")"
check_contains "B5 non-numeric issue is a usage error" "rc=2" "$BAD_ISSUE"

# ==== C. --report: CI mapping and comment de-duplication =======================
echo "== C. report mode =="

reset_state
set_issue 2288 open labeled
add_claim 2288 "codex-thread-beta" "codex" "box-7" "run-9" "$NOW"
set_pr "Closes #2288

<!-- claim-holder: $(expect_digest "some-other-thread") -->" "human-dev" "User"
OUT="$(bash "$CHECK" 900 --repo owner/repo --report 2>"$TMP/stderr")"; RC=$?
check_eq "C1 foreign --report exits 1" "1" "$RC"
check_eq "C1 one comment posted" "1" "$(jq '[.[] | select(.body | startswith("<!-- pr-claim-check:foreign:2288 -->"))] | length' "$S/comments-900.json")"
check_contains "C1 comment names provider" "codex" "$(jq -r '.[-1].body' "$S/comments-900.json")"
check_absent "C1 comment never names raw holder" "codex-thread-beta" "$(jq -r '.[-1].body' "$S/comments-900.json")"

OUT="$(bash "$CHECK" 900 --repo owner/repo --report 2>"$TMP/stderr")"; RC=$?
check_eq "C2 same verdict on a later run exits 1 again" "1" "$RC"
check_eq "C2 no second comment for the same outcome" "1" "$(jq '[.[] | select(.body | startswith("<!-- pr-claim-check:foreign:2288 -->"))] | length' "$S/comments-900.json")"

set_pr "Closes #2288

<!-- claim-holder: $(expect_digest "codex-thread-beta") -->" "human-dev" "User"
OUT="$(bash "$CHECK" 900 --repo owner/repo --report 2>"$TMP/stderr")"; RC=$?
check_eq "C3 corrected PR body passes" "0" "$RC"
check_eq "C3 match posts nothing new" "1" "$(jq '[.[] | select(.body | startswith("<!-- pr-claim-check"))] | length' "$S/comments-900.json")"

reset_state
set_issue 2288 open labeled
add_claim 2288 "codex-thread-beta" "codex" "box-7" "run-9" "$NOW"
set_pr "Closes #2288

<!-- claim-holder: $(expect_digest "some-other-thread") -->" "human-dev" "User"
bash "$CHECK" 900 --repo owner/repo --report >/dev/null 2>&1
set_pr "Closes #2288 and polish

<!-- claim-holder: $(expect_digest "some-other-thread") -->" "human-dev" "User"
bash "$CHECK" 900 --repo owner/repo --report >/dev/null 2>&1
check_eq "C4 same verdict across pushes still one comment" "1" \
  "$(jq '[.[] | select(.body | startswith("<!-- pr-claim-check:foreign:2288 -->"))] | length' "$S/comments-900.json")"

reset_state
set_issue 2288 open labeled
add_claim 2288 "$MATCH_RAW" "claude" "laptop" "run-1" "$NOW"
set_pr "Closes #2288" "human-dev" "User"
bash "$CHECK" 900 --repo owner/repo --report >/dev/null 2>&1; RC=$?
check_eq "C5 no_claim_line --report passes (warning only)" "0" "$RC"
check_eq "C5 one no_claim_line comment" "1" \
  "$(jq '[.[] | select(.body | startswith("<!-- pr-claim-check:no_claim_line:2288 -->"))] | length' "$S/comments-900.json")"

reset_state
set_issue 2288 open labeled
add_claim 2288 "$MATCH_RAW" "claude" "laptop" "run-1" "$NOW"
set_pr "Closes #2288" "human-dev" "User"
FAKE_COMMENTS_FAIL=2288 bash "$CHECK" 900 --repo owner/repo --report >/dev/null 2>&1; RC=$?
check_eq "C6 unverifiable --report passes with warning" "0" "$RC"

reset_state
set_pr "Closes #2288" "dependabot[bot]" "Bot"
bash "$CHECK" 900 --repo owner/repo --report >/dev/null 2>&1; RC=$?
check_eq "C7 skipped --report exits 0" "0" "$RC"
check_eq "C7 no comment for skipped" "0" "$(jq 'length' "$S/comments-900.json" 2>/dev/null || echo 0)"

reset_state
set_issue 2288 open labeled
add_claim 2288 "codex-thread-beta" "codex" "box-7" "run-9" "$NOW"
set_pr "Closes owner/repo#2288

<!-- claim-holder: $(expect_digest "some-other-thread") -->" "human-dev" "User"
run_check
check_eq "C8 same-repo qualified reference is linked -> foreign" "foreign" "$(verdict_of)"

reset_state
set_pr "Closes other-owner/elsewhere#2288" "human-dev" "User"
run_check
check_eq "C9 other-repo qualified reference is not linked -> skipped" "skipped" "$(verdict_of)"
check_eq "C9 reason is cross_repo_issue" "cross_repo_issue" "$(printf '%s' "$OUT" | jq -r '.reason')"
check_eq "C9 one skipped reference" "1" "$(printf '%s' "$OUT" | jq -r '.skipped_references | length')"
check_eq "C9 skipped reference names repo and issue" "other-owner/elsewhere#2288" \
  "$(printf '%s' "$OUT" | jq -r '.skipped_references[0] | "\(.repo)#\(.issue)"')"
check_eq "C9 skipped reference reason" "cross_repo_issue" "$(printf '%s' "$OUT" | jq -r '.skipped_references[0].reason')"

# C9b: a cross-repository keyword never hides a local outcome (foreign).
reset_state
set_issue 2288 open labeled
add_claim 2288 "codex-thread-beta" "codex" "box-7" "run-9" "$NOW"
set_pr "Closes #2288 and fixes Other-Owner/Elsewhere#5

<!-- claim-holder: $(expect_digest "some-other-thread") -->" "human-dev" "User"
run_check
check_eq "C9b mixed local foreign + cross-repo keeps foreign" "foreign" "$(verdict_of)"
check_eq "C9b mixed lists the skipped reference (repo lowercased)" "other-owner/elsewhere#5" \
  "$(printf '%s' "$OUT" | jq -r '.skipped_references[0] | "\(.repo)#\(.issue)"')"

# C9c: mixed local match + cross-repo keeps match.
reset_state
set_issue 2288 open labeled
add_claim 2288 "$MATCH_RAW" "claude" "laptop" "run-1" "$NOW"
set_pr "Closes #2288, closes other-owner/elsewhere#5

<!-- claim-holder: $MATCH_DIGEST -->" "human-dev" "User"
run_check
check_eq "C9c mixed local match + cross-repo keeps match" "match" "$(verdict_of)"
check_eq "C9c skipped reference still listed" "1" "$(printf '%s' "$OUT" | jq -r '.skipped_references | length')"

# C9d: cross-repo keywords inside a fence or an HTML comment are ignored.
reset_state
set_pr 'Intro

```
Closes other-owner/elsewhere#7
```

<!-- Closes other-owner/elsewhere#8 -->' "human-dev" "User"
run_check
check_eq "C9d fenced/commented cross-repo keyword ignored -> no_linked_issue" "no_linked_issue" "$(printf '%s' "$OUT" | jq -r '.reason')"
check_eq "C9d no skipped references" "0" "$(printf '%s' "$OUT" | jq -r '.skipped_references | length')"

# C9e: duplicate and case-varied cross-repo references give one entry.
reset_state
set_pr "Closes other-owner/elsewhere#2288 and Fixes Other-Owner/ELSEWHERE#2288" "human-dev" "User"
run_check
check_eq "C9e duplicate/case-varied cross-repo reference -> one entry" "1" "$(printf '%s' "$OUT" | jq -r '.skipped_references | length')"

# C9f: a case-varied qualifier for THIS repository stays local.
reset_state
set_issue 2288 open labeled
add_claim 2288 "codex-thread-beta" "codex" "box-7" "run-9" "$NOW"
set_pr "Closes OWNER/Repo#2288

<!-- claim-holder: $(expect_digest "some-other-thread") -->" "human-dev" "User"
run_check
check_eq "C9f case-varied same-repo qualifier stays local -> foreign" "foreign" "$(verdict_of)"
check_eq "C9f no skipped references" "0" "$(printf '%s' "$OUT" | jq -r '.skipped_references | length')"

# C9g: --report on a cross-repository-only PR: exit 0, no comment, summary names it.
reset_state
set_pr "Closes other-owner/elsewhere#2288" "human-dev" "User"
GITHUB_STEP_SUMMARY="$TMP/summary-c9g" bash "$CHECK" 900 --repo owner/repo --report >"$TMP/c9g.out" 2>/dev/null; RC=$?
check_eq "C9g cross-repo-only --report exits 0" "0" "$RC"
check_eq "C9g posts no comment" "0" "$(jq 'length' "$S/comments-900.json" 2>/dev/null || echo 0)"
check_contains "C9g summary names the reference" "other-owner/elsewhere#2288" "$(cat "$TMP/summary-c9g")"
check_contains "C9g summary names the reason" "cross_repo_issue" "$(cat "$TMP/summary-c9g")"
check_contains "C9g notice names the reason" "::notice::" "$(cat "$TMP/c9g.out")"

# C14: a merged PR is finished work: skipped/pr_not_open, no issue read, no comment.
# No issue fixture exists, so any issue read would turn the verdict into unverifiable.
reset_state
PR_STATE_FIXTURE=closed PR_MERGED_AT_FIXTURE="2026-11-13T00:00:00Z" set_pr "Closes #2288" "human-dev" "User"
run_check
check_eq "C14 merged PR -> skipped" "skipped" "$(verdict_of)"
check_eq "C14 merged PR reason is pr_not_open" "pr_not_open" "$(printf '%s' "$OUT" | jq -r '.reason')"
check_eq "C14 merged PR has no issues" "0" "$(printf '%s' "$OUT" | jq -r '.issues | length')"
GITHUB_STEP_SUMMARY="$TMP/summary-c14" bash "$CHECK" 900 --repo owner/repo --report >"$TMP/c14.out" 2>/dev/null; RC=$?
check_eq "C14 merged PR --report exits 0" "0" "$RC"
check_eq "C14 merged PR posts no comment" "0" "$(jq 'length' "$S/comments-900.json" 2>/dev/null || echo 0)"
check_contains "C14 summary says pr_not_open" "pr_not_open" "$(cat "$TMP/summary-c14")"

# C14b: a merged PR whose issue is claimed by someone else is still quiet.
reset_state
set_issue 2288 closed
add_claim 2288 "codex-thread-beta" "codex" "box-7" "run-9" "$NOW"
PR_STATE_FIXTURE=closed PR_MERGED_AT_FIXTURE="2026-11-13T00:00:00Z" set_pr "Closes #2288" "human-dev" "User"
bash "$CHECK" 900 --repo owner/repo --report >/dev/null 2>&1; RC=$?
check_eq "C14b merged PR on a closed, claimed issue exits 0" "0" "$RC"
check_eq "C14b claim comment on the issue untouched" "1" "$(jq 'length' "$S/comments-2288.json" 2>/dev/null || echo 0)"
check_eq "C14b no PR comment posted" "0" "$(jq 'length' "$S/comments-900.json" 2>/dev/null || echo 0)"

# C14c: closed (unmerged) PR and closed bot PR.
reset_state
PR_STATE_FIXTURE=closed set_pr "Closes #2288" "human-dev" "User"
run_check
check_eq "C14c closed unmerged PR -> pr_not_open" "pr_not_open" "$(printf '%s' "$OUT" | jq -r '.reason')"
reset_state
PR_STATE_FIXTURE=closed set_pr "Closes #2288" "dependabot[bot]" "Bot"
run_check
check_eq "C14c closed bot PR -> pr_not_open (state checked before bot)" "pr_not_open" "$(printf '%s' "$OUT" | jq -r '.reason')"

# C14d: a missing or unexpected state is unverifiable, never a silent skip.
reset_state
PR_STATE_FIXTURE=__missing__ set_pr "Closes #2288" "human-dev" "User"
run_check
check_eq "C14d missing state -> unverifiable" "unverifiable" "$(verdict_of)"
check_eq "C14d missing state reason" "pr_read_failed" "$(printf '%s' "$OUT" | jq -r '.reason')"
reset_state
PR_STATE_FIXTURE=weird set_pr "Closes #2288" "human-dev" "User"
run_check
check_eq "C14d invalid state -> unverifiable" "unverifiable" "$(verdict_of)"

reset_state
set_issue 2288 open labeled
add_claim 2288 "$MATCH_RAW" "claude" "laptop" "run-1" "$NOW"
set_pr "Closes #2288

Prose that mentions claim-holder without a hidden marker.

<!-- claim-holder: $MATCH_DIGEST -->" "human-dev" "User"
run_check
check_eq "C10 prose mention of claim-holder is ignored -> match" "match" "$(verdict_of)"

reset_state
set_pr "Closes #2288" "human-dev" "User"
touch "$S/pr_fail"
bash "$CHECK" 900 --repo owner/repo --report >"$TMP/c11.out" 2>"$TMP/c11.err"; RC=$?
check_eq "C11 early unverifiable with --report still warns and exits 0" "0" "$RC"
check_contains "C11 early unverifiable emits a ::warning:: annotation" "::warning::" "$(cat "$TMP/c11.out")"
check_eq "C11 JSON reason is pr_read_failed" "unverifiable|pr_read_failed" \
  "$(head -n 1 "$TMP/c11.out" | jq -r '[.verdict, .reason] | join("|")' 2>/dev/null)"
check_absent "C11 no unbound-variable abort" "unbound variable" "$(cat "$TMP/c11.err")"
check_eq "C11 early unverifiable posts a comment" "1" \
  "$(jq '[.[] | select(.body | startswith("<!-- pr-claim-check:unverifiable:"))] | length' "$S/comments-900.json" 2>/dev/null || echo 0)"
rm -f "$S/pr_fail"

# C11b: an inherited LINKED from the environment never leaks into the marker.
reset_state
set_pr "Closes #2288" "human-dev" "User"
touch "$S/pr_fail"
LINKED="4242" bash "$CHECK" 900 --repo owner/repo --report >/dev/null 2>"$TMP/c11b.err"; RC=$?
check_eq "C11b inherited LINKED: exits 0" "0" "$RC"
check_eq "C11b inherited LINKED: early marker lists no issues" "1" \
  "$(jq '[.[] | select(.body | startswith("<!-- pr-claim-check:unverifiable: -->"))] | length' "$S/comments-900.json" 2>/dev/null || echo 0)"
check_absent "C11b inherited LINKED: value not used" "4242" "$(jq -r '.[].body' "$S/comments-900.json" 2>/dev/null)"
rm -f "$S/pr_fail"

# C12: no temporary directory in --report mode is a warning, never a silent pass.
reset_state
set_issue 2288 open labeled
add_claim 2288 "$MATCH_RAW" "claude" "laptop" "run-1" "$NOW"
set_pr "Closes #2288

<!-- claim-holder: $MATCH_DIGEST -->" "human-dev" "User"
FAILBIN="$TMP/failbin"
mkdir -p "$FAILBIN"
printf '#!/usr/bin/env bash\nexit 1\n' > "$FAILBIN/mktemp"
chmod +x "$FAILBIN/mktemp"
C12_OUT="$(PATH="$FAILBIN:$PATH" bash "$CHECK" 900 --repo owner/repo --report 2>&1)"; C12_RC=$?
check_eq "C12 mktemp failure in --report exits 0" "0" "$C12_RC"
check_contains "C12 mktemp failure warns that ownership is unverified" "::warning::pr-claim-check: could not verify ownership" "$C12_OUT"
check_contains "C12 mktemp failure verdict is unverifiable" '"verdict":"unverifiable"' "$C12_OUT"
check_absent "C12 mktemp failure is not a match" '"verdict":"match"' "$C12_OUT"

# C13: a claim held by the literal string the old throwaway holder used is still
# compared by digest, not treated as "mine".
reset_state
set_issue 2288 open labeled
add_claim 2288 "pr-claim-check" "claude" "laptop" "run-1" "$NOW"
set_pr "Closes #2288

<!-- claim-holder: $(expect_digest "some-other-thread") -->" "human-dev" "User"
run_check
check_eq "C13 claim held by literal pr-claim-check, other PR line -> foreign" "foreign" "$(verdict_of)"

reset_state
set_issue 2288 open labeled
add_claim 2288 "pr-claim-check" "claude" "laptop" "run-1" "$NOW"
set_pr "Closes #2288

<!-- claim-holder: $(expect_digest "pr-claim-check") -->" "human-dev" "User"
run_check
check_eq "C13 claim held by literal pr-claim-check, matching PR line -> match" "match" "$(verdict_of)"

# ==== E. workflow shape (issue #2412) =========================================
echo "== E. workflow =="
WF="$REPO_ROOT/.github/workflows/pr-claim-check.yml"
WF_TEXT="$(cat "$WF")"
check_contains "E1 runs serialize per PR" \
  'group: ${{ github.workflow }}-pr-${{ github.event.pull_request.number || github.run_id }}' "$WF_TEXT"
check_contains "E1 a running check is never cancelled mid-POST" "cancel-in-progress: false" "$WF_TEXT"
check_absent "E1 no cancel-in-progress: true" "cancel-in-progress: true" "$WF_TEXT"
check_contains "E2 checks out the base SHA (trusted code)" 'ref: ${{ github.event.pull_request.base.sha }}' "$WF_TEXT"
check_contains "E2 does not persist credentials" "persist-credentials: false" "$WF_TEXT"

# ==== F. installed gate: bootstrap into a scratch repo (issue #2412) ==========
echo "== F. installed gate =="
GATE_REPO="$TMP/gate-repo"
mkdir -p "$GATE_REPO"
git init -q "$GATE_REPO"
reset_state
# The stub answers branch-protection reads as unexpected endpoints, so the
# bootstrap exit code reflects that gap; only a write failure (5) is a failure.
(cd "$GATE_REPO" && bash "$REPO_ROOT/.claude/scripts/repo-bootstrap.sh" --apply >"$TMP/gate-apply.out" 2>&1); RC=$?
# Documented codes: 0 clean, 1 gap, 4 gh error (the stub's branch-protection
# read); 5 (write failure) or anything else fails.
case "$RC" in
  0|1|4) ok "F1 bootstrap --apply finished with a documented non-write-failure code ($RC)" ;;
  *) bad "F1 bootstrap --apply exit $RC: $(cat "$TMP/gate-apply.out")" ;;
esac
for f in .claude/scripts/pr-claim-check.sh .claude/scripts/issue-claim.sh .claude/scripts/pr-claim-line.sh .github/workflows/pr-claim-check.yml; do
  if [[ -f "$GATE_REPO/$f" ]]; then ok "F1 installed $f"; else bad "F1 $f not installed"; fi
done
GATE_CHECK="$GATE_REPO/.claude/scripts/pr-claim-check.sh"

reset_state
set_issue 2288 open labeled
add_claim 2288 "codex-thread-beta" "codex" "box-7" "run-9" "$NOW"
set_pr "Closes #2288

<!-- claim-holder: $(expect_digest "some-other-thread") -->" "human-dev" "User"
FAKE_USER_FAIL=1 bash "$GATE_CHECK" 900 --repo owner/repo --report >"$TMP/gate.out" 2>/dev/null; RC=$?
check_eq "F2 installed gate, foreign claim, GET /user failing -> --report exits 1" "1" "$RC"
check_eq "F2 installed gate verdict is foreign" "foreign" "$(head -n 1 "$TMP/gate.out" | jq -r .verdict 2>/dev/null)"

reset_state
set_issue 2288 open labeled
add_claim 2288 "$MATCH_RAW" "claude" "laptop" "run-1" "$NOW"
# The claim line comes from the installed helper, run directly (mode 755).
GATE_LINE="$("$GATE_REPO/.claude/scripts/pr-claim-line.sh" 2288 --holder "$MATCH_RAW" 2>/dev/null)"
check_eq "F3 installed pr-claim-line.sh prints the matching line" "<!-- claim-holder: $MATCH_DIGEST -->" "$GATE_LINE"
set_pr "Closes #2288

$GATE_LINE" "human-dev" "User"
OUT="$(FAKE_USER_FAIL=1 bash "$GATE_CHECK" 900 --repo owner/repo 2>/dev/null)"
check_eq "F3 installed gate, matching claim, GET /user failing -> match" "match" "$(verdict_of)"

# ==== D. usage ================================================================
echo "== D. usage =="
bash "$CHECK" >/dev/null 2>&1; check_eq "D1 missing PR is usage error 2" "2" "$?"
bash "$CHECK" 900 --bogus >/dev/null 2>&1; check_eq "D2 unknown flag is usage error 2" "2" "$?"

echo
echo "pr-claim-check tests: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
