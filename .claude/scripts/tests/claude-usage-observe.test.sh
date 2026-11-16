#!/usr/bin/env bash
# Tests for saving the Claude usage the desktop app's usage tool reports (issue #2404).
# catalog: tests — Tests claude-usage-observe.sh offline — the recorded 2026-11-16 usage-tool payload is saved for the account CLAUDE_CODE_USER_EMAIL names (mode 600, no credential), every refusal branch writes nothing, and the quota reader and weekly reserve use the NEWER of the app reading and the status-line reading
#
# Fully offline: HOME is a sandbox and curl is a stub that logs every call.
#
# Usage: bash .claude/scripts/tests/claude-usage-observe.test.sh
set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
OBSERVE="$REPO_ROOT/.claude/scripts/claude-usage-observe.sh"
READER="$REPO_ROOT/.claude/scripts/ai-quotas.sh"
RESERVE="$REPO_ROOT/.claude/scripts/quota-reserve.sh"

TMP="$(mktemp -d)"
cleanup() { chmod -R u+rwx "$TMP" 2>/dev/null || true; rm -rf "$TMP"; }
trap cleanup EXIT

export HOME="$TMP/home"
mkdir -p "$HOME/.claude"
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL="$TMP/gitconfig-none"
unset CLAUDE_CONFIG_DIR CLAUDE_SESSION_REPO AI_QUOTAS_NOW CLAUDE_CODE_USER_EMAIL
export AI_QUOTAS_CONFIG="$TMP/ai-quotas.json"
export AI_QUOTAS_STATUSLINE_DIR="$TMP/status-line"
export AI_QUOTAS_COOLOFF_DIR="$TMP/cooloff"
export AI_QUOTAS_HISTORY="$TMP/history.jsonl"
export AI_QUOTAS_LAST_KNOWN_DIR="$TMP/last-known"
export AI_QUOTAS_PLATFORM=Linux
export AI_QUOTAS_CLAUDE_VERSION=2.1.321
export AI_QUOTAS_CURL_BIN="$TMP/bin/curl"
export AI_QUOTAS_ANTHROPIC_URL="https://usage.test/api/oauth/usage"
export AI_QUOTAS_CLAUDE_TOKEN_URL="https://token.test/v1/oauth/token"
export AI_QUOTAS_SOURCE=manual
export QUOTA_RESERVE_DIR="$TMP/qr"
mkdir -p "$TMP/bin"

PASS=0; FAILED=0
ok() { echo "ok   — $*"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $*" >&2; FAILED=$((FAILED + 1)); }
check_eq() { if [[ "$1" == "$2" ]]; then ok "$3"; else fail "$3 (want '$2', got '$1')"; fi; }
check_contains() { if [[ "$1" == *"$2"* ]]; then ok "$3"; else fail "$3 (no '$2' in '$1')"; fi; }
check_lacks() { if [[ "$1" != *"$2"* ]]; then ok "$3"; else fail "$3 (unexpected '$2' in '$1')"; fi; }

# 2026-11-16T14:39:00Z, 7h 21m before the recorded weekly reset.
NOW=1794839940
RESET_EPOCH=1794866400
PERS=personal@example.com
WORK=work@example.com
PERS_DIR="$TMP/profiles/personal"; WORK_DIR="$TMP/profiles/work"
mkdir -p "$PERS_DIR" "$WORK_DIR"
printf '{"oauthAccount":{"emailAddress":"%s"}}' "$PERS" > "$PERS_DIR/.claude.json"
printf '{"oauthAccount":{"emailAddress":"%s"}}' "$WORK" > "$WORK_DIR/.claude.json"
printf '{"oauthAccount":{"emailAddress":"%s"}}' "$PERS" > "$HOME/.claude.json"
jq -n --arg wl "$WORK" --arg wd "$WORK_DIR" --arg pl "$PERS" --arg pd "$PERS_DIR" '
  {schema_version:"1.0", accounts:[
    {provider:"claude", label:$wl, profile_dir:$wd, nickname:"Claude Work"},
    {provider:"claude", label:$pl, profile_dir:$pd, nickname:"Claude Personal"}]}' > "$AI_QUOTAS_CONFIG"
cp "$AI_QUOTAS_CONFIG" "$TMP/config.keep"

# The usage tool's result as recorded on 2026-11-16 (no secret in it).
cat > "$TMP/tool.json" <<'EOF'
{"plan":{"status":"ok","plan":"Ultra","windows":[{"label":"Weekly · all models","percentUsed":35,"resetsAt":"2026-11-16T22:00:00.409Z","resetsIn":"7h 21m"},{"label":"Weekly · Fable","percentUsed":37,"resetsAt":"2026-11-16T22:00:00.409Z","resetsIn":"7h 21m"}],"extraUsage":{"enabled":true,"percentUsed":63,"spent":"315.79","monthlyLimit":"500.00","currency":"USD"}},"context":{"session":"self","status":"ok","tokensUsed":250311,"contextWindow":1000000,"percentUsed":25}}
EOF
jq -c '.plan' "$TMP/tool.json" > "$TMP/plan-only.json"

APP_FILE="$AI_QUOTAS_STATUSLINE_DIR/claude-app--$PERS.json"
SL_FILE="$AI_QUOTAS_STATUSLINE_DIR/claude--$PERS.json"
observe_as() { local e="$1"; shift; AI_QUOTAS_NOW="$NOW" CLAUDE_CODE_USER_EMAIL="$e" "$OBSERVE" "$@" 2>&1; }
observe() { observe_as "$PERS" "$@"; }
# A modified copy of the recorded payload: observe_edit '<jq filter>'
observe_edit() { jq -c "$1" "$TMP/tool.json" > "$TMP/edit.json"; observe "$TMP/edit.json"; }
refused() { # <description> <jq filter> <reason fragment>
  rm -rf "$AI_QUOTAS_STATUSLINE_DIR"
  local out rc=0
  out="$(observe_edit "$2")" || rc=$?
  [[ "$rc" -ne 0 ]] && ok "$1: exit non-zero" || fail "$1: expected a refusal, got exit 0"
  check_contains "$out" "$3" "$1: one-line reason"
  [[ ! -e "$APP_FILE" ]] && ok "$1: nothing written" || fail "$1: a reading was written"
}

# --- 1. the recorded payload is saved for the right account -----------------
out="$(observe "$TMP/tool.json")"; rc=$?
check_eq "$rc" "0" "the recorded payload is accepted"
check_contains "$out" "$PERS" "the success line names the account"
check_contains "$out" "35" "and the 7-day percent"
check_eq "$(jq -r '.windows.seven_day.used_pct' "$APP_FILE")" "35" "the weekly all-models percent is saved"
check_eq "$(jq -r '.windows.seven_day.resets_at_epoch' "$APP_FILE")" "$RESET_EPOCH" "the reset time is parsed to an epoch (fraction dropped)"
check_eq "$(jq -r '.source' "$APP_FILE")" "app-usage-tool" "the source says it came from the app usage tool"
check_eq "$(jq -r '.captured_at_epoch' "$APP_FILE")" "$NOW" "the capture time is recorded"
check_eq "$(jq -r '.captured_at' "$APP_FILE")" "2026-11-16T14:39:00Z" "also as UTC ISO-8601"
check_eq "$(jq -r '.account_label' "$APP_FILE")" "$PERS" "the account label is recorded"
check_eq "$(jq -r '.subscription_type' "$APP_FILE")" "ultra" "the plan name is kept"
check_eq "$(jq -c '.weekly_models' "$APP_FILE")" "[{\"label\":\"Weekly · Fable\",\"used_pct\":37,\"resets_at_epoch\":$RESET_EPOCH}]" "the per-model weekly window is kept for later readers"
check_eq "$(jq -c '.extra_usage' "$APP_FILE")" '{"enabled":true,"used_pct":63,"spent":"315.79","monthly_limit":"500.00","currency":"USD"}' "the extra-usage block is kept for later readers"
check_eq "$(jq -r '.windows.five_hour // "none"' "$APP_FILE")" "none" "no five-hour window when the tool returned none"
check_lacks "$(jq -r 'keys | join(",")' "$APP_FILE")" "context" "nothing else from the tool result is copied (no context block)"
check_eq "$(stat -c '%a' "$APP_FILE" 2>/dev/null || stat -f '%Lp' "$APP_FILE")" "600" "the file is mode 600"
check_eq "$(stat -c '%a' "$AI_QUOTAS_STATUSLINE_DIR" 2>/dev/null || stat -f '%Lp' "$AI_QUOTAS_STATUSLINE_DIR")" "700" "in a mode 700 folder"
check_eq "$(ls -A "$AI_QUOTAS_STATUSLINE_DIR" | wc -l | tr -d ' ')" "1" "no temp file is left behind"
[[ ! -e "$AI_QUOTAS_STATUSLINE_DIR/claude--$WORK.json" && ! -e "$SL_FILE" ]] && ok "the status-line file and the other account's are untouched" || fail "another file was written"

# The plan object alone, and stdin.
rm -rf "$AI_QUOTAS_STATUSLINE_DIR"
observe "$TMP/plan-only.json" >/dev/null; rc=$?
check_eq "$rc" "0" "the plan object alone is accepted"
rm -rf "$AI_QUOTAS_STATUSLINE_DIR"
out="$(AI_QUOTAS_NOW="$NOW" CLAUDE_CODE_USER_EMAIL="$PERS" "$OBSERVE" - < "$TMP/tool.json" 2>&1)"; rc=$?
check_eq "$rc" "0" "the tool result is accepted on stdin"
check_eq "$(jq -r '.windows.seven_day.used_pct' "$APP_FILE")" "35" "and saved the same"

# A five-hour window under another label is kept when valid.
rm -rf "$AI_QUOTAS_STATUSLINE_DIR"
observe_edit '.plan.windows += [{"label":"5-hour limit","percentUsed":12,"resetsAt":"2026-11-16T17:00:00Z"}]' >/dev/null
check_eq "$(jq -c '.windows.five_hour' "$APP_FILE")" "{\"used_pct\":12,\"resets_at_epoch\":$(( 1794866400 - 18000 ))}" "a five-hour window entry is saved when present"
check_eq "$(jq -r '.weekly_models | length' "$APP_FILE")" "1" "and is not mistaken for a per-model weekly window"

# Case-insensitive exact match.
rm -rf "$AI_QUOTAS_STATUSLINE_DIR"
observe_as "Personal@Example.COM" "$TMP/tool.json" >/dev/null; rc=$?
check_eq "$rc" "0" "the session email matches the registry case-insensitively"

# --- 2. refusals write nothing -----------------------------------------------
refused "plan status not_applicable" '.plan.status = "not_applicable"' "not_applicable"
refused "plan status unavailable" '.plan.status = "unavailable"' "unavailable"
refused "no plan status" 'del(.plan.status)' "not ok"
refused "no windows at all" 'del(.plan.windows)' "no windows"
refused "no weekly all-models window" '.plan.windows |= map(select(.label != "Weekly · all models"))' "no weekly all-models window"
refused "only a per-model weekly window" '.plan.windows = [.plan.windows[1]]' "no weekly all-models window"
refused "two weekly all-models windows" '.plan.windows += [.plan.windows[0]]' "several weekly all-models"
refused "percent above 100" '.plan.windows[0].percentUsed = 140' "0 to 100"
refused "percent below 0" '.plan.windows[0].percentUsed = -1' "0 to 100"
refused "percent a string" '.plan.windows[0].percentUsed = "35"' "0 to 100"
refused "percent missing" 'del(.plan.windows[0].percentUsed)' "0 to 100"
refused "reset not a timestamp" '.plan.windows[0].resetsAt = "in 7h"' "reset time"
refused "reset an impossible date" '.plan.windows[0].resetsAt = "2026-13-45T99:00:00Z"' "reset time"
refused "reset missing" 'del(.plan.windows[0].resetsAt)' "reset time"
refused "reset with an offset (not UTC Z)" '.plan.windows[0].resetsAt = "2026-11-16T22:00:00+05:00"' "reset time"
refused "reset already past" '.plan.windows[0].resetsAt = "2026-11-16T14:00:00Z"' "already past"
refused "plan is not an object" '.plan = "ok"' "not the usage tool result"

rm -rf "$AI_QUOTAS_STATUSLINE_DIR"
printf 'not json at all' > "$TMP/bad.json"
out="$(observe "$TMP/bad.json")"; rc=$?
[[ "$rc" -ne 0 && ! -e "$APP_FILE" ]] && ok "unparseable input: refused, nothing written" || fail "unparseable input mishandled"
check_contains "$out" "not valid JSON" "with its own reason"
cat "$TMP/tool.json" "$TMP/tool.json" > "$TMP/two.json"
out="$(observe "$TMP/two.json")"; rc=$?
[[ "$rc" -ne 0 && ! -e "$APP_FILE" ]] && ok "two JSON values in one input: refused, nothing written" || fail "two JSON values were accepted"
printf '[1,2]' > "$TMP/arr.json"
out="$(observe "$TMP/arr.json")"; rc=$?
[[ "$rc" -ne 0 && ! -e "$APP_FILE" ]] && ok "a JSON array: refused" || fail "a JSON array was accepted"
out="$(observe "$TMP/missing.json")"; rc=$?
[[ "$rc" -ne 0 ]] && ok "an unreadable file: refused" || fail "an unreadable file was accepted"
out="$("$OBSERVE" 2>&1)"; rc=$?
check_eq "$rc" "3" "no argument is a usage error"

# --- 3. the account is the calling session's, never guessed -------------------
# Fallback: the variable unset, the session's own signed-in account (HOME here)
# names the account by exact equality.
rm -rf "$AI_QUOTAS_STATUSLINE_DIR"
out="$(AI_QUOTAS_NOW="$NOW" "$OBSERVE" "$TMP/tool.json" 2>&1)"; rc=$?
[[ "$rc" -eq 0 && -f "$APP_FILE" ]] && ok "variable unset: the signed-in account names the account" || fail "the signed-in fallback did not save ($out)"
# Neither source readable: refused, nothing written.
rm -rf "$AI_QUOTAS_STATUSLINE_DIR"
mv "$HOME/.claude.json" "$TMP/home-claude.json.keep"
out="$(AI_QUOTAS_NOW="$NOW" "$OBSERVE" "$TMP/tool.json" 2>&1)"; rc=$?
[[ "$rc" -ne 0 && ! -e "$AI_QUOTAS_STATUSLINE_DIR" ]] && ok "variable unset and no signed-in account: refused, nothing written" || fail "an unnamed account was accepted"
check_contains "$out" "CLAUDE_CODE_USER_EMAIL" "and the reason names the variable"
# Variable set, no signed-in file: the variable alone names it.
out="$(observe "$TMP/tool.json")"; rc=$?
[[ "$rc" -eq 0 && -f "$APP_FILE" ]] && ok "variable set, no signed-in file: saved for the variable's account" || fail "the variable alone did not save ($out)"
rm -rf "$AI_QUOTAS_STATUSLINE_DIR"
mv "$TMP/home-claude.json.keep" "$HOME/.claude.json"
# Variable and signed-in account disagree: refused, nothing written.
out="$(observe_as "$WORK" "$TMP/tool.json")"; rc=$?
[[ "$rc" -ne 0 && ! -e "$AI_QUOTAS_STATUSLINE_DIR" ]] && ok "variable disagrees with the signed-in account: refused, nothing written" || fail "a disagreeing pair was accepted"
check_contains "$out" "disagree" "and the reason says so"
out="$(CLAUDE_CONFIG_DIR="$WORK_DIR" observe "$TMP/tool.json")"; rc=$?
[[ "$rc" -ne 0 && ! -e "$AI_QUOTAS_STATUSLINE_DIR" ]] && ok "CLAUDE_CONFIG_DIR's account disagrees with the variable: refused" || fail "a disagreement through CLAUDE_CONFIG_DIR was accepted"
# Variable and signed-in account agree (case-insensitively): saved.
out="$(observe_as "$(printf '%s' "$PERS" | tr '[:lower:]' '[:upper:]')" "$TMP/tool.json")"; rc=$?
[[ "$rc" -eq 0 && -f "$APP_FILE" ]] && ok "agreeing pair, different case: saved" || fail "an agreeing pair was refused ($out)"
rm -rf "$AI_QUOTAS_STATUSLINE_DIR"
out="$(observe_as "stranger@example.com" "$TMP/tool.json")"; rc=$?
[[ "$rc" -ne 0 && ! -e "$AI_QUOTAS_STATUSLINE_DIR" ]] && ok "an unregistered email: refused" || fail "an unregistered email was accepted"
# The signed-in account is unregistered, variable unset: refused, never the default profile.
printf '{"oauthAccount":{"emailAddress":"stranger@example.com"}}' > "$HOME/.claude.json"
out="$(AI_QUOTAS_NOW="$NOW" "$OBSERVE" "$TMP/tool.json" 2>&1)"; rc=$?
[[ "$rc" -ne 0 && ! -e "$AI_QUOTAS_STATUSLINE_DIR" ]] && ok "an unregistered signed-in account is not attributed to any profile" || fail "an unregistered signed-in account was attributed"
printf '{"oauthAccount":{"emailAddress":"%s"}}' "$PERS" > "$HOME/.claude.json"
# Two registered accounts claiming one email: refused, not guessed.
printf '{"oauthAccount":{"emailAddress":"%s"}}' "$PERS" > "$WORK_DIR/.claude.json"
out="$(observe_as "$WORK" "$TMP/tool.json")"; rc=$?
[[ "$rc" -ne 0 && ! -e "$AI_QUOTAS_STATUSLINE_DIR" ]] && ok "two registered accounts claiming one email: refused, not guessed" || fail "an ambiguous email was accepted"
printf '{"oauthAccount":{"emailAddress":"%s"}}' "$WORK" > "$WORK_DIR/.claude.json"
CLAUDE_CONFIG_DIR="$WORK_DIR" observe_as "$WORK" "$TMP/tool.json" >/dev/null
[[ -f "$AI_QUOTAS_STATUSLINE_DIR/claude-app--$WORK.json" && ! -e "$APP_FILE" ]] && ok "the work account's session files under the work account" || fail "the reading was misfiled"
rm -rf "$AI_QUOTAS_STATUSLINE_DIR"

# --- 4. the reader uses it, and the NEWER of two readings ---------------------
CURL_LOG="$TMP/curl.log"
cat > "$TMP/bin/curl" <<EOF
#!/usr/bin/env bash
url=""; out=""
while [[ \$# -gt 0 ]]; do
  case "\$1" in -o) out="\$2"; shift 2 ;; -D) shift 2 ;; https://*) url="\$1"; shift ;; *) shift ;; esac
done
printf '%s\n' "\$url" >> "$CURL_LOG"
case "\$url" in
  *token.test*) printf '{"access_token":"NEW","refresh_token":"NEWR","expires_in":3600}' > "\$out"; printf '200' ;;
  *usage.test*) printf '{"seven_day":{"utilization":41,"resets_at":"2027-01-15T08:00:00Z"}}' > "\$out"; printf '200' ;;
esac
EOF
chmod +x "$TMP/bin/curl"
# Expired credentials so any fall-through to the token path is visible.
printf '{"claudeAiOauth":{"accessToken":"SECRET-ACCESS-TOKEN","refreshToken":"SECRET-REFRESH-TOKEN","expiresAt":%s}}' "$(( (NOW - 3600) * 1000 ))" > "$PERS_DIR/.credentials.json"
run_reader() { AI_QUOTAS_NOW="$1" "$READER" --json --no-last-known --account "$PERS" 2>/dev/null; }
row() { printf '%s' "$1" | jq -r --arg w "7-day" --arg f "$2" '.rows[] | select(.window == $w) | .[$f]' | head -n 1; }
write_sl() { # <pct> <captured-epoch>: a status-line reading for the personal account
  jq -nc --argjson p "$1" --argjson c "$2" --argjson r "$RESET_EPOCH" --arg l "$PERS" \
    '{schema_version:"1.0",provider:"claude",captured_at_epoch:$c,captured_at:($c|todate),account_label:$l,
      subscription_type:"max",rate_limits:{},windows:{seven_day:{used_pct:$p,resets_at_epoch:$r}}}' > "$SL_FILE"
  chmod 600 "$SL_FILE"
}

rm -rf "$AI_QUOTAS_STATUSLINE_DIR"; : > "$CURL_LOG"
observe "$TMP/tool.json" >/dev/null
json="$(run_reader "$(( NOW + 60 ))")"
check_eq "$(row "$json" status)" "ok" "after an observation the personal account reads ok with an expired token"
check_eq "$(row "$json" used_pct)" "35" "with the 7-day used percentage"
check_eq "$(row "$json" resets_at_epoch)" "$RESET_EPOCH" "and the reset time"
check_eq "$(row "$json" source)" "app-usage-tool" "the row names the app usage tool as its source"
check_contains "$(row "$json" detail)" "usage tool" "and the note says so"
check_eq "$(row "$json" fetched_at_epoch)" "$NOW" "the row carries the capture time as fetched_at_epoch"
check_eq "$(grep -c . "$CURL_LOG" 2>/dev/null || true)" "0" "no request was made to either endpoint"

# Newer of two: the status line is newer -> it wins.
write_sl 40 "$(( NOW + 30 ))"
json="$(run_reader "$(( NOW + 60 ))")"
check_eq "$(row "$json" source)" "status-line" "a newer status-line reading beats an older app reading"
check_eq "$(row "$json" used_pct)" "40" "and its figure is the one shown"
check_eq "$(row "$json" fetched_at_epoch)" "$(( NOW + 30 ))" "with its own capture time"
# Newer of two: the app reading is newer -> it wins.
write_sl 40 "$(( NOW - 120 ))"
json="$(run_reader "$(( NOW + 60 ))")"
check_eq "$(row "$json" source)" "app-usage-tool" "a newer app reading beats an older status-line reading"
check_eq "$(row "$json" used_pct)" "35" "and its figure is the one shown"
# The older reading is stale, the other fresh: the fresh one is used.
write_sl 40 "$(( NOW + 3000 ))"
json="$(run_reader "$(( NOW + 3100 ))")"
check_eq "$(row "$json" source)" "status-line" "a stale app reading is passed over for a fresh status-line one"
# Both stale: token path, with a note naming both.
json="$(run_reader "$(( NOW + 9000 ))")"
check_eq "$(row "$json" source)" "oauth-usage" "both readings stale: the token path runs"
check_contains "$(row "$json" detail)" "app usage tool reading is" "and the row says the app reading was too old"
check_contains "$(row "$json" detail)" "status-line reading is" "and the status-line reading too"
# An app reading from a finished week is not used.
rm -f "$SL_FILE"
cp "$APP_FILE" "$TMP/app.orig"
# Captured a minute before the reset, read ten seconds after: fresh by age, so only the reset check can reject it.
jq --argjson c "$(( RESET_EPOCH - 60 ))" '.captured_at_epoch = $c' "$TMP/app.orig" > "$APP_FILE"; chmod 600 "$APP_FILE"
json="$(run_reader "$(( RESET_EPOCH + 10 ))")"
check_eq "$(row "$json" source)" "oauth-usage" "an app reading from a finished week is not used"
check_contains "$(row "$json" detail)" "predates the current 7-day window" "and the note names the weekly reset check"
cp "$TMP/app.orig" "$APP_FILE"; chmod 600 "$APP_FILE"
# An app reading filed under another label is invalid.
cp "$APP_FILE" "$TMP/app.keep"
jq '.account_label = "someone@else.com"' "$TMP/app.keep" > "$APP_FILE"; chmod 600 "$APP_FILE"
json="$(run_reader "$(( NOW + 60 ))")"
check_eq "$(row "$json" source)" "oauth-usage" "an app reading carrying another account's label is not used"
cp "$TMP/app.keep" "$APP_FILE"; chmod 600 "$APP_FILE"

# --- 5. the weekly reserve ---------------------------------------------------
reserve_marker() { rm -rf "$QUOTA_RESERVE_DIR"
  env -u QUOTA_RESERVE_AI_QUOTAS_SH AI_QUOTAS_NOW="$1" QUOTA_RESERVE_NOW="$1" QUOTA_RESERVE_NOTIFY_CMD=true \
    "$RESERVE" --refresh --force > /dev/null 2>&1; }
marker_field() { jq -r --arg l "$PERS" --arg f "$1" '.accounts[] | select(.label == $l) | .[$f]' "$QUOTA_RESERVE_DIR/marker.json" 2>/dev/null; }
jq '.windows.seven_day.used_pct = 97' "$TMP/app.keep" > "$APP_FILE"; chmod 600 "$APP_FILE"
reserve_marker "$(( NOW + 60 ))"
check_eq "$(marker_field used_pct)" "97" "the reserve shows the app reading's percent for the account"
check_eq "$(marker_field state)" "reserve" "and marks the account at 97% as reserve"
# Stale: the reserve reads unknown (fails open), never the old figure.
rm -f "$PERS_DIR/.credentials.json"
reserve_marker "$(( NOW + 9000 ))"
check_eq "$(marker_field state)" "unknown" "a stale app reading reads as unknown in the reserve (fail open)"
check_eq "$(marker_field used_pct)" "null" "with no percent"

echo "----------------------------------------"
echo "claude-usage-observe.test.sh: $PASS passed, $FAILED failed"
[[ "$FAILED" -eq 0 ]]
