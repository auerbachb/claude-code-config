#!/usr/bin/env bash
# Tests for the quota-reserve hooks (issue #1863): quota-reserve-guard.sh
# (PreToolUse) and quota-reserve-turn.sh (UserPromptSubmit), plus their
# registration and the safety.md carve-out.
#
# Two layers on purpose. The wrapper behavior (fast path, exit codes, every
# fail-open path) is tested against a STUB decision script in a copied hooks tree,
# so a regression in the wrapper cannot hide behind the real decision logic. The
# end-to-end cases then run the REAL script, so a regression in the pairing cannot
# hide behind the stub. The decision matrix itself lives in
# .claude/scripts/tests/quota-reserve.test.sh.
#
# Self-contained — defines its own helpers. Usage: bash .claude/hooks/tests/quota-reserve-hooks.test.sh
set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
GUARD="$REPO_ROOT/.claude/hooks/quota-reserve-guard.sh"
TURN="$REPO_ROOT/.claude/hooks/quota-reserve-turn.sh"
REAL_SCRIPT="$REPO_ROOT/.claude/scripts/quota-reserve.sh"
SETTINGS="$REPO_ROOT/global-settings.json"
SAFETY="$REPO_ROOT/.claude/rules/safety.md"

TMP="$(mktemp -d)"
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT
export HOME="$TMP/home"; mkdir -p "$HOME/.claude"
unset QUOTA_RESERVE_THRESHOLD_PCT QUOTA_RESERVE_ENABLED CLAUDE_ACCOUNT_CONFIG CLAUDE_CONFIG_DIR
export QUOTA_RESERVE_DIR="$TMP/qr"
export QUOTA_RESERVE_CLAUDE_JSON="$TMP/session-claude.json"

PASS=0; FAILED=0
ok() { echo "ok   — $*"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $*" >&2; FAILED=$((FAILED + 1)); }
check_eq() { if [[ "$1" == "$2" ]]; then ok "$3"; else fail "$3 (want '$2', got '$1')"; fi; }
check_contains() { if [[ "$1" == *"$2"* ]]; then ok "$3"; else fail "$3 (no '$2' in '$1')"; fi; }

for f in "$GUARD" "$TURN" "$REAL_SCRIPT"; do
  [[ -x "$f" ]] || { echo "FAIL: $f is missing or not executable" >&2; exit 1; }
done

# ---------------------------------------------------------------- stub tree ---
# A copy of the two hooks beside a stub quota-reserve.sh that logs each call and
# answers from $STUB_VERDICT, so the wrapper is tested alone.
STUB_TREE="$TMP/tree"; mkdir -p "$STUB_TREE/.claude/hooks" "$STUB_TREE/.claude/scripts"
cp "$GUARD" "$STUB_TREE/.claude/hooks/"; cp "$TURN" "$STUB_TREE/.claude/hooks/"
STUB_LOG="$TMP/stub.log"
cat > "$STUB_TREE/.claude/scripts/quota-reserve.sh" <<EOF
#!/usr/bin/env bash
echo "\$1" >> "$STUB_LOG"
cat >/dev/null
[[ -n "\${STUB_CRASH:-}" ]] && exit 1
printf '%s\n' "\${STUB_VERDICT:-allow}"
EOF
chmod +x "$STUB_TREE/.claude/scripts/quota-reserve.sh"
S_GUARD="$STUB_TREE/.claude/hooks/quota-reserve-guard.sh"
S_TURN="$STUB_TREE/.claude/hooks/quota-reserve-turn.sh"

mk_marker() { # <state> [age-seconds]
  mkdir -p "$QUOTA_RESERVE_DIR"
  jq -n --arg s "$1" '{schema_version: "1.0", read_at: 1, threshold_pct: 95, enabled: true,
      accounts: [{provider: "claude", label: "a", email: "a@example.com", nickname: "A", used_pct: 50, state: $s}]}' \
    > "$QUOTA_RESERVE_DIR/marker.json"
  if [[ -n "${2:-}" ]]; then
    # touch -t reads LOCAL time, so format the target instant in local time (GNU date -d, else BSD date -r).
    local when=$(( $(date +%s) - $2 ))
    touch -t "$(date -d "@$when" +%Y%m%d%H%M.%S 2>/dev/null || date -r "$when" +%Y%m%d%H%M.%S)" "$QUOTA_RESERVE_DIR/marker.json"
  fi
}
run_guard() { # <guard> <stdin>  -> sets RC, ERR
  ERR="$(printf '%s' "$2" | "$1" 2>&1 >/dev/null)"; RC=$?
}
calls() { [[ -f "$STUB_LOG" ]] && wc -l < "$STUB_LOG" | tr -d ' ' || echo 0; }
PAYLOAD='{"tool_name":"Edit","session_id":"s1","tool_input":{}}'

# ------------------------------------------------------------------------------
# 1. The guard's fast path and exit codes (stub decision script)
# ------------------------------------------------------------------------------
rm -f "$STUB_LOG"; rm -rf "$QUOTA_RESERVE_DIR"; mk_marker ok 30
run_guard "$S_GUARD" "$PAYLOAD"
check_eq "$RC" "0" "fresh marker, nobody in reserve: allowed"
check_eq "$(calls)" "0" "and the decision script is never run (the fast path costs a grep and a stat)"

rm -f "$STUB_LOG"; mk_marker reserve 30
STUB_VERDICT="deny Claude A is at 96%." run_guard "$S_GUARD" "$PAYLOAD"
check_eq "$RC" "2" "an account in reserve reaches the decision script, and a deny exits 2"
check_contains "$ERR" "BLOCKED: Claude A is at 96%." "with the reason on stderr for the model to read"
check_eq "$(calls)" "1" "the decision script ran once"
STUB_VERDICT="allow interactive turn" run_guard "$S_GUARD" "$PAYLOAD"
check_eq "$RC" "0" "an allow verdict exits 0"
check_eq "$ERR" "" "and prints nothing"

rm -f "$STUB_LOG"; mk_marker ok 900
run_guard "$S_GUARD" "$PAYLOAD"
check_eq "$(calls)" "1" "a marker older than ten minutes goes to the decision script, which starts the refresh"

rm -f "$STUB_LOG"; rm -f "$QUOTA_RESERVE_DIR/marker.json"
run_guard "$S_GUARD" "$PAYLOAD"
check_eq "$(calls)" "1" "no marker at all also goes to the decision script"
check_eq "$RC" "0" "and is allowed"

# fail-open
mk_marker reserve 30
STUB_CRASH=1 run_guard "$S_GUARD" "$PAYLOAD"
check_eq "$RC" "0" "a decision script that crashes allows the call"
STUB_VERDICT="" run_guard "$S_GUARD" "$PAYLOAD"
check_eq "$RC" "0" "a decision script that prints nothing allows the call"
STUB_VERDICT="denyish nonsense" run_guard "$S_GUARD" "$PAYLOAD"
check_eq "$RC" "0" "only a verdict that starts with 'deny ' blocks"
mv "$STUB_TREE/.claude/scripts/quota-reserve.sh" "$STUB_TREE/.claude/scripts/quota-reserve.sh.off"
run_guard "$S_GUARD" "$PAYLOAD"
check_eq "$RC" "0" "a missing decision script allows the call"
run_guard "$S_TURN" "$PAYLOAD"
check_eq "$RC" "0" "and so does the turn classifier"
mv "$STUB_TREE/.claude/scripts/quota-reserve.sh.off" "$STUB_TREE/.claude/scripts/quota-reserve.sh"
run_guard "$S_GUARD" ""
check_eq "$RC" "0" "an empty payload allows the call"
run_guard "$S_GUARD" "not json at all"
check_eq "$RC" "0" "a garbage payload allows the call"

# the turn hook
rm -f "$STUB_LOG"
run_guard "$S_TURN" "$PAYLOAD"
check_eq "$RC" "0" "the turn classifier always exits 0"
check_eq "$(cat "$STUB_LOG")" "--classify-prompt" "and hands the payload to --classify-prompt"
STUB_CRASH=1 run_guard "$S_TURN" "$PAYLOAD"
check_eq "$RC" "0" "even when the classifier crashes"

# ------------------------------------------------------------------------------
# 2. End to end through the REAL decision script
# ------------------------------------------------------------------------------
mkdir -p "$TMP/bin"
cat > "$TMP/bin/ai-quotas.sh" <<EOF
#!/usr/bin/env bash
cat <<'JSON'
{"rows": [
 {"provider":"claude","label":"a@example.com","nickname":"Claude A","reported_email":"a@example.com","window":"7-day","status":"ok","used_pct":97,"resets_at_epoch":1800000000},
 {"provider":"claude","label":"b@example.com","nickname":"Claude B","reported_email":"b@example.com","window":"7-day","status":"ok","used_pct":20,"resets_at_epoch":1800000000}
]}
JSON
EOF
chmod +x "$TMP/bin/ai-quotas.sh"
export QUOTA_RESERVE_AI_QUOTAS_SH="$TMP/bin/ai-quotas.sh"
rm -rf "$QUOTA_RESERVE_DIR"; "$REAL_SCRIPT" --refresh --force
jq -n '{oauthAccount: {emailAddress: "a@example.com"}}' > "$QUOTA_RESERVE_CLAUDE_JSON"

run_guard "$GUARD" '{"tool_name":"Agent","session_id":"e2e","tool_input":{}}'
check_eq "$RC" "2" "end to end: a launch on the account in reserve is blocked with exit 2"
check_contains "$ERR" "Claude A is at 97%" "with the account and figure in the message"
run_guard "$GUARD" '{"tool_name":"Read","session_id":"e2e","tool_input":{}}'
check_eq "$RC" "0" "end to end: the owner's own read goes through"

printf '%s' '{"session_id":"e2e","prompt":"<task-notification>build done"}' | "$TURN"
run_guard "$GUARD" '{"tool_name":"Edit","session_id":"e2e","tool_input":{}}'
check_eq "$RC" "2" "end to end: after the classifier marks the turn automated, an Edit is blocked"
printf '%s' '{"session_id":"e2e","prompt":"ok, go ahead and edit it"}' | "$TURN"
run_guard "$GUARD" '{"tool_name":"Edit","session_id":"e2e","tool_input":{}}'
check_eq "$RC" "0" "end to end: once the owner speaks, the next turn is interactive and the Edit goes through"

jq -n '{oauthAccount: {emailAddress: "b@example.com"}}' > "$QUOTA_RESERVE_CLAUDE_JSON"
run_guard "$GUARD" '{"tool_name":"Agent","session_id":"e2e","tool_input":{}}'
check_eq "$RC" "0" "end to end: the same launch on the other account is allowed"

# ------------------------------------------------------------------------------
# 3. Registration: one entry per hook, matcher/command/timeout checked together
# ------------------------------------------------------------------------------
python3 - "$SETTINGS" <<'PY' && ok "the guard is registered on PreToolUse for every tool, with a 5 s timeout" || fail "no single PreToolUse group registers quota-reserve-guard.sh with no matcher and timeout 5"
import json, sys
data = json.load(open(sys.argv[1]))
for g in data["hooks"]["PreToolUse"]:
    for h in g["hooks"]:
        if h["command"].endswith("/quota-reserve-guard.sh") and h["timeout"] == 5 and not g.get("matcher"):
            sys.exit(0)
sys.exit(1)
PY
python3 - "$SETTINGS" <<'PY' && ok "the turn classifier is registered on UserPromptSubmit with a 5 s timeout" || fail "quota-reserve-turn.sh is not registered on UserPromptSubmit with timeout 5"
import json, sys
data = json.load(open(sys.argv[1]))
for g in data["hooks"]["UserPromptSubmit"]:
    for h in g["hooks"]:
        if h["command"].endswith("/quota-reserve-turn.sh") and h["timeout"] == 5:
            sys.exit(0)
sys.exit(1)
PY

# ------------------------------------------------------------------------------
# 4. The rule carve-out exists, and the original prohibition is untouched
# ------------------------------------------------------------------------------
grep -q 'MUST NOT gate agent decisions' "$SAFETY" && ok "safety.md still carries the locally-estimated prohibition" || fail "safety.md's prohibition text is missing or altered"
grep -q 'Reserve carve-out (#1863)' "$SAFETY" && ok "safety.md carries the reserve carve-out" || fail "safety.md has no reserve carve-out"
grep -q 'never an estimate' "$SAFETY" && ok "and it is limited to the provider-reported figure" || fail "the carve-out does not say it excludes estimates"

# The guard must never read or compute usage itself: the only numbers it may see
# come from the marker the decision script wrote.
CODE_ONLY="$TMP/guard-code.sh"; sed -e 's/[[:space:]]*#.*$//' "$GUARD" | grep -v '^[[:space:]]*$' > "$CODE_ONLY"
if grep -nEi 'input_tokens|output_tokens|cache_read|used_percentage|estimate|oauth|credential|access_token' "$CODE_ONLY"; then
  fail "the guard reads or computes accounting itself; it must only act on the marker's verdict"
else
  ok "the guard contains no usage accounting or credential handling"
fi

echo
echo "passed: $PASS   failed: $FAILED"
[[ "$FAILED" -eq 0 ]] || exit 1
exit 0
