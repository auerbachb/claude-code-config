#!/usr/bin/env bash
# Issue #2300: the SessionStart hook writes a session breadcrumb keyed by the
# nearest claude ancestor identity, and the spend link writer reads it when its
# shell carries no session id. Every fixture uses a temp HOME; the identity is
# stubbed through CLAUDE_SESSION_BREADCRUMB_TEST_IDENTITY (test-only override).
set -euo pipefail

REPO_ROOT="$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)"
SESSION_HOOK="$REPO_ROOT/.claude/hooks/spend-session-tracker.sh"
LINK="$REPO_ROOT/.claude/scripts/spend-telemetry-link.sh"
REPORT="$REPO_ROOT/.claude/scripts/spend-telemetry-report.sh"
TMP_BASE="$(mktemp -d)"
trap 'rm -rf "$TMP_BASE"' EXIT

unset CLAUDE_CODE_SESSION_ID CLAUDE_SESSION_ID
fail() { echo "FAIL: $*" >&2; exit 1; }
ok() { echo "PASS: $*"; }

# Discriminating identities: same shape, different pid and start time.
IDENT_A="claude=4242|start=Thu Nov 12 10:00:00 2026"
IDENT_B="claude=4243|start=Thu Nov 12 10:05:00 2026"
SID="sess-2300-real-0001"
PRIVATE_SENTINEL="BREADCRUMB_PRIVATE_SENTINEL"

REPO_DIR="$TMP_BASE/repo"
mkdir -p "$REPO_DIR"
git -C "$REPO_DIR" init -q
git -C "$REPO_DIR" remote add origin https://github.com/owner/repo.git

digest() { printf '%s' "$1" | shasum -a 256 | awk '{print $1}'; }
crumb_path() { printf '%s/.claude/session-breadcrumbs/%s.txt' "$1" "$(digest "$2")"; }
correlation_rows() { grep -F $'\ttask_correlation\t' "$1/.claude/spend-telemetry.log" 2>/dev/null || true; }

HOME_A="$TMP_BASE/home-a"
mkdir -p "$HOME_A"

# (d) The SessionStart hook writes the payload session id under the identity.
hook_payload=$(python3 -c 'import json,sys
print(json.dumps({"hook_event_name":"SessionStart","session_id":sys.argv[1],"source":"startup","model":"claude-opus-5-5","cwd":sys.argv[2]}))' "$SID" "$REPO_DIR")
printf '%s' "$hook_payload" | HOME="$HOME_A" CLAUDE_SESSION_BREADCRUMB_TEST_IDENTITY="$IDENT_A" bash "$SESSION_HOOK" >/dev/null
CRUMB_A="$(crumb_path "$HOME_A" "$IDENT_A")"
[[ -f "$CRUMB_A" ]] || fail "(d) hook wrote no breadcrumb for the ancestor identity"
grep -qx "session_id=$SID" "$CRUMB_A" || fail "(d) breadcrumb does not hold the payload session id"
if [[ "$(wc -l < "$CRUMB_A" | tr -d ' ')" -ne 2 ]]; then fail "(d) breadcrumb must hold exactly session_id and ts"; fi
ok "(d) SessionStart hook writes session_id and ts under the ancestor identity digest"

# Fixture transcript for the same session: one assistant message, metadata only.
TRANSCRIPT="$TMP_BASE/main.jsonl"
cat > "$TRANSCRIPT" <<JEOF
{"type":"user","message":{"role":"user","content":[{"type":"text","text":"$PRIVATE_SENTINEL"}]}}
{"type":"assistant","timestamp":"2026-11-12T12:00:00Z","message":{"id":"bc-msg-1","model":"claude-sonnet-4-6","role":"assistant","content":[{"type":"text","text":"$PRIVATE_SENTINEL"}],"usage":{"input_tokens":100,"output_tokens":20}}}
JEOF
end_payload=$(python3 -c 'import json,sys
print(json.dumps({"hook_event_name":"SessionEnd","session_id":sys.argv[1],"transcript_path":sys.argv[2],"cwd":sys.argv[3]}))' "$SID" "$TRANSCRIPT" "$REPO_DIR")
printf '%s' "$end_payload" | HOME="$HOME_A" CLAUDE_SESSION_BREADCRUMB_TEST_IDENTITY="$IDENT_A" bash "$SESSION_HOOK" >/dev/null

# gh stub: the link writer's bounded `gh pr view` returns this merged PR, which
# closes issue 2300. Only (a) needs PR evidence for the report's linked count.
FAKE_BIN="$TMP_BASE/bin"
mkdir -p "$FAKE_BIN"
PR_FIXTURE="$TMP_BASE/pr-7.json"
cat > "$PR_FIXTURE" <<JEOF
{"number":7,"url":"https://github.com/owner/repo/pull/7","state":"MERGED","mergedAt":"2026-11-12T12:10:00Z","closingIssuesReferences":[{"number":2300,"repository":{"nameWithOwner":"owner/repo"}}],"reviewDecision":"APPROVED","statusCheckRollup":[],"headRefOid":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","mergeCommit":{"oid":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"},"commit_count":1}
JEOF
cat > "$FAKE_BIN/gh" <<GHEOF
#!/usr/bin/env bash
cat "$PR_FIXTURE"
GHEOF
chmod +x "$FAKE_BIN/gh"

# (a) Empty session env plus a breadcrumb for this identity: the link writer
# records the real session id, and the report joins the message row to it.
(cd "$REPO_DIR" && env -u CLAUDE_CODE_SESSION_ID -u CLAUDE_SESSION_ID HOME="$HOME_A" PATH="$FAKE_BIN:$PATH" \
  CLAUDE_SESSION_BREADCRUMB_TEST_IDENTITY="$IDENT_A" bash "$LINK" --repo owner/repo --issue 2300 --pr 7 \
  --source test_breadcrumb >/dev/null 2>&1) || fail "(a) link writer exited non-zero"
row_a="$(correlation_rows "$HOME_A" | tail -n 1)"
[[ -n "$row_a" ]] || fail "(a) link writer recorded no correlation row"
[[ "$(printf '%s' "$row_a" | cut -f6)" == "$SID" ]] || fail "(a) correlation row does not carry the real session id"
if printf '%s' "$row_a" | grep -q session_unresolved; then fail "(a) real session id still carries the unsupported marker"; fi
report_a="$(HOME="$HOME_A" bash "$REPORT" 2>&1 || true)"
printf '%s\n' "$report_a" | grep -q "Correlation rows with no runtime session ID: 0" \
  || fail "(a) report still counts a sessionless correlation row"
linked_line="$(printf '%s\n' "$report_a" | grep "$SID" || true)"
[[ -n "$linked_line" ]] || fail "(a) report lists no linked row for the session"
printf '%s\n' "$linked_line" | grep -Eq '\| 1 \|' || fail "(a) linked message count is not above 0: $linked_line"
if grep -q "$PRIVATE_SENTINEL" "$HOME_A/.claude/spend-telemetry.log"; then fail "(a) telemetry log stored transcript content"; fi
ok "(a) empty env + breadcrumb: link row carries the real session id and the report counts 1 linked message"

# (b) No breadcrumb for this identity: unknown plus the unsupported marker, exit 0.
HOME_B="$TMP_BASE/home-b"
mkdir -p "$HOME_B"
set +e
(cd "$REPO_DIR" && env -u CLAUDE_CODE_SESSION_ID -u CLAUDE_SESSION_ID HOME="$HOME_B" PATH="$FAKE_BIN:$PATH" \
  CLAUDE_SESSION_BREADCRUMB_TEST_IDENTITY="$IDENT_A" bash "$LINK" --repo owner/repo --issue 2301 --pr 7 \
  --source test_breadcrumb >/dev/null 2>&1)
rc_b=$?
set -e
[[ "$rc_b" -eq 0 ]] || fail "(b) link writer must exit 0 without a breadcrumb"
row_b="$(correlation_rows "$HOME_B" | tail -n 1)"
[[ "$(printf '%s' "$row_b" | cut -f6)" == unknown ]] || fail "(b) missing breadcrumb must yield unknown"
printf '%s' "$row_b" | grep -q "unsupported:no_runtime_session_id_at_link_writer" || fail "(b) unknown row lacks the unsupported marker"
ok "(b) no breadcrumb: session stays unknown with the unsupported marker, exit 0"

# (c) A breadcrumb for another identity is ignored.
HOME_C="$TMP_BASE/home-c"
mkdir -p "$HOME_C/.claude/session-breadcrumbs"
cp "$CRUMB_A" "$(crumb_path "$HOME_C" "$IDENT_A")"
set +e
(cd "$REPO_DIR" && env -u CLAUDE_CODE_SESSION_ID -u CLAUDE_SESSION_ID HOME="$HOME_C" PATH="$FAKE_BIN:$PATH" \
  CLAUDE_SESSION_BREADCRUMB_TEST_IDENTITY="$IDENT_B" bash "$LINK" --repo owner/repo --issue 2302 --pr 7 \
  --source test_breadcrumb >/dev/null 2>&1)
set -e
row_c="$(correlation_rows "$HOME_C" | tail -n 1)"
[[ "$(printf '%s' "$row_c" | cut -f6)" == unknown ]] || fail "(c) breadcrumb for another identity was used"
ok "(c) breadcrumb for a different ancestor identity is ignored"

# (e) A corrupt breadcrumb value degrades to unknown, never to a fabricated id.
HOME_E="$TMP_BASE/home-e"
mkdir -p "$HOME_E/.claude/session-breadcrumbs"
printf 'session_id=../../escape\nts=2026-11-12T12:00:00Z\n' > "$(crumb_path "$HOME_E" "$IDENT_A")"
set +e
(cd "$REPO_DIR" && env -u CLAUDE_CODE_SESSION_ID -u CLAUDE_SESSION_ID HOME="$HOME_E" PATH="$FAKE_BIN:$PATH" \
  CLAUDE_SESSION_BREADCRUMB_TEST_IDENTITY="$IDENT_A" bash "$LINK" --repo owner/repo --issue 2303 --pr 7 \
  --source test_breadcrumb >/dev/null 2>&1)
rc_e=$?
set -e
[[ "$rc_e" -eq 0 ]] || fail "(e) corrupt breadcrumb aborted the link writer"
row_e="$(correlation_rows "$HOME_E" | tail -n 1)"
[[ "$(printf '%s' "$row_e" | cut -f6)" == unknown ]] || fail "(e) corrupt breadcrumb value was used"
ok "(e) corrupt breadcrumb value is rejected; caller exits 0"

echo "All session breadcrumb tests passed."
