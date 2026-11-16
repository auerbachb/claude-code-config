#!/usr/bin/env bash
# Tests for the Claude status-line usage reading (issue #2403).
# catalog: tests — Tests the status-line usage path offline — statusline.sh saves `rate_limits` per registered account (mode 600, no credential, never misattributed), `ai-quotas.sh` reads a fresh saved figure with no token and falls back when it is stale, the weekly reserve accepts it, and a 429 from the token endpoint pauses renewal for a cool-off
#
# Fully offline: HOME is a sandbox, curl is a stub that logs every call, and no
# real Anthropic endpoint is touched. The payload shape is the one Claude Code
# 2.1.321 passes the status line (`rate_limits.five_hour` / `.seven_day`, each
# `used_percentage` + `resets_at`); a live session check is still owed.
#
# Usage: bash .claude/scripts/tests/claude-status-reading.test.sh
set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
STATUSLINE="$REPO_ROOT/.claude/scripts/statusline.sh"
READER="$REPO_ROOT/.claude/scripts/ai-quotas.sh"
RESERVE="$REPO_ROOT/.claude/scripts/quota-reserve.sh"

TMP="$(mktemp -d)"
cleanup() { chmod -R u+rwx "$TMP" 2>/dev/null || true; rm -rf "$TMP"; }
trap cleanup EXIT

export HOME="$TMP/home"
mkdir -p "$HOME/.claude"
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL="$TMP/gitconfig-none"
unset CLAUDE_CONFIG_DIR CLAUDE_SESSION_REPO AI_QUOTAS_NOW
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

NOW=1800000000
WORK=work@example.com
PERS=personal@example.com
# The profile FOLDER names are deliberately swapped against the labels (Issue
# #1850): attribution must follow the registry and the signed-in email, never
# the folder name.
WORK_DIR="$TMP/profiles/$PERS/claude"
PERS_DIR="$TMP/profiles/$WORK/claude"
mkdir -p "$WORK_DIR" "$PERS_DIR"
printf '{"oauthAccount":{"emailAddress":"%s"}}' "$WORK" > "$WORK_DIR/.claude.json"
printf '{"oauthAccount":{"emailAddress":"%s"}}' "$PERS" > "$PERS_DIR/.claude.json"
# The default install is the personal account.
printf '{"oauthAccount":{"emailAddress":"%s"}}' "$PERS" > "$HOME/.claude.json"

jq -n --arg wl "$WORK" --arg wd "$WORK_DIR" --arg pl "$PERS" --arg pd "$PERS_DIR" '
  {schema_version:"1.0", accounts:[
    {provider:"claude", label:$wl, profile_dir:$wd, nickname:"Claude Work"},
    {provider:"claude", label:$pl, profile_dir:$pd, nickname:"Claude Personal"}]}' > "$AI_QUOTAS_CONFIG"

# Expired credentials WITH a refresh token, for both profiles, so the token
# path is reachable (it must still not be used while a fresh reading exists).
seed_expired_credentials() {
  local d
  for d in "$WORK_DIR" "$PERS_DIR"; do
    printf '{"claudeAiOauth":{"accessToken":"SECRET-ACCESS-TOKEN","refreshToken":"SECRET-REFRESH-TOKEN","expiresAt":%s}}' "$(( (NOW - 3600) * 1000 ))" > "$d/.credentials.json"
  done
}
seed_expired_credentials

CURL_LOG="$TMP/curl.log"; TOKEN_MODE="$TMP/token-mode"; USAGE_MODE="$TMP/usage-mode"
cat > "$TMP/bin/curl" <<EOF
#!/usr/bin/env bash
url=""; out=""; hdr=""
while [[ \$# -gt 0 ]]; do
  case "\$1" in
    -o) out="\$2"; shift 2 ;;
    -D) hdr="\$2"; shift 2 ;;
    https://*) url="\$1"; shift ;;
    *) shift ;;
  esac
done
printf '%s\n' "\$url" >> "$CURL_LOG"
case "\$url" in
  *token.test*)
    if [[ "\$(cat "$TOKEN_MODE" 2>/dev/null)" == 429* ]]; then
      if [[ -n "\$hdr" && -s "$TMP/retry-after" ]]; then printf 'Retry-After: %s\r\n' "\$(cat "$TMP/retry-after")" > "\$hdr"; fi
      printf '{"error":{"type":"rate_limit_error"}}' > "\$out"; printf '429'
    else
      printf '{"access_token":"NEW","refresh_token":"NEWR","expires_in":3600}' > "\$out"; printf '200'
    fi ;;
  *usage.test*)
    printf '{"seven_day":{"utilization":41,"resets_at":"2027-01-15T08:00:00Z"}}' > "\$out"; printf '200' ;;
esac
EOF
chmod +x "$TMP/bin/curl"
curl_calls() { grep -c "$1" "$CURL_LOG" 2>/dev/null || true; }

PAYLOAD_FUTURE=$(( NOW + 200000 ))
payload() { # <seven-pct> <five-pct> [extra-top-level-json]
  jq -nc --argjson s "$1" --argjson f "$2" --argjson r "$PAYLOAD_FUTURE" --argjson r5 "$(( NOW + 9000 ))" '
    {cwd:"/tmp", rate_limits:{spend_limit:{used_credits:3,monthly_limit:50}, five_hour:{used_percentage:$f, resets_at:$r5},
                              seven_day:{used_percentage:$s, resets_at:$r}},
     rate_limits_available:true,
 subscription_type:"max",
     access_token:"SECRET-IN-PAYLOAD"}'
}
reading_file() { printf '%s/claude--%s.json' "$AI_QUOTAS_STATUSLINE_DIR" "$1"; }
run_sl() { printf '%s' "$1" | AI_QUOTAS_NOW="$NOW" "$STATUSLINE" 2>/dev/null; }
run_reader() { AI_QUOTAS_NOW="${1:-$NOW}" "$READER" --json --no-last-known ${2:+--account "$2"} 2>/dev/null; }
row_field() { # <json> <label> <window> <field>
  printf '%s' "$1" | jq -r --arg l "$2" --arg w "$3" --arg f "$4" '.rows[] | select(.label == $l and .window == $w) | .[$f]' | head -n 1
}

# --- 1. the status line saves the reading for the right account --------------
export CLAUDE_CONFIG_DIR="$WORK_DIR"
out="$(run_sl "$(payload 63 12)")"
unset CLAUDE_CONFIG_DIR
[[ -n "$out" && "$out" == *" · "* ]] && ok "statusline still prints its line when it saves a reading" || fail "statusline line missing: '$out'"
F="$(reading_file "$WORK")"
[[ -f "$F" ]] && ok "a reading is saved for the work account" || fail "no reading file for the work account"
check_eq "$(jq -r '.windows.seven_day.used_pct' "$F" 2>/dev/null)" "63" "the 7-day used percentage is saved"
check_eq "$(jq -r '.windows.seven_day.resets_at_epoch' "$F" 2>/dev/null)" "$PAYLOAD_FUTURE" "the 7-day reset time is saved"
check_eq "$(jq -r '.windows.five_hour.used_pct' "$F" 2>/dev/null)" "12" "the 5-hour window is saved too"
check_eq "$(jq -r '.captured_at_epoch' "$F" 2>/dev/null)" "$NOW" "the capture time is recorded"
check_eq "$(jq -r '.account_label' "$F" 2>/dev/null)" "$WORK" "the account label is recorded"
check_eq "$(jq -c '.rate_limits.spend_limit' "$F" 2>/dev/null)" '{"used_credits":3,"monthly_limit":50}' "the whole rate_limits object is kept, spend_limit included"
check_eq "$(jq -r '.rate_limits.seven_day.used_percentage' "$F" 2>/dev/null)" "63" "with the payload's own field names"
check_eq "$(jq -r '.subscription_type' "$F" 2>/dev/null)" "max" "the subscription type is kept"
check_eq "$(jq -r '.captured_at' "$F" 2>/dev/null)" "2027-01-15T08:00:00Z" "the capture time is also saved as UTC ISO-8601"
check_eq "$(stat -c '%a' "$F" 2>/dev/null || stat -f '%Lp' "$F")" "600" "the reading file is mode 600"
check_eq "$(stat -c '%a' "$AI_QUOTAS_STATUSLINE_DIR" 2>/dev/null || stat -f '%Lp' "$AI_QUOTAS_STATUSLINE_DIR")" "700" "the folder is mode 700"
check_lacks "$(cat "$F")" "SECRET" "the file holds no credential, even when the payload carried one"
[[ ! -e "$(reading_file "$PERS")" ]] && ok "the other account's file is untouched (no cross-attribution)" || fail "the personal account got a reading it did not earn"
check_eq "$(ls -A "$AI_QUOTAS_STATUSLINE_DIR" | wc -l | tr -d ' ')" "1" "no temp file is left behind"

# The default install (no CLAUDE_CONFIG_DIR) is the personal account.
out="$(run_sl "$(payload 22 5)")"
[[ -f "$(reading_file "$PERS")" ]] && ok "the default install's reading is filed under the personal account" || fail "no reading for the default install"
check_eq "$(jq -r '.windows.seven_day.used_pct' "$(reading_file "$PERS")" 2>/dev/null)" "22" "and carries the default install's own figure"
check_eq "$(jq -r '.windows.seven_day.used_pct' "$(reading_file "$WORK")" 2>/dev/null)" "63" "while the work account's reading is unchanged"

# --- 2. nothing to save, or nobody to save it for ----------------------------
rm -rf "$AI_QUOTAS_STATUSLINE_DIR"
out="$(run_sl '{"cwd":"/tmp"}')"
[[ -n "$out" ]] && ok "no rate_limits (API-key session): the line still prints" || fail "no line without rate_limits"
[[ ! -e "$AI_QUOTAS_STATUSLINE_DIR" ]] && ok "and nothing is written" || fail "something was written without rate_limits"
out="$(run_sl '{"cwd":"/tmp","rate_limits":{"five_hour":{"used_percentage":"x"},"seven_day":null}}')"
[[ -n "$out" && ! -e "$AI_QUOTAS_STATUSLINE_DIR" ]] && ok "malformed rate_limits: line prints, nothing saved" || fail "malformed rate_limits mishandled"
out="$(printf 'not json rate_limits' | AI_QUOTAS_NOW="$NOW" "$STATUSLINE" 2>/dev/null)"
[[ -n "$out" ]] && ok "unparseable stdin mentioning rate_limits: the line still prints" || fail "line lost on bad stdin"

# A session whose email matches no registered account saves nothing.
printf '{"oauthAccount":{"emailAddress":"stranger@example.com"}}' > "$TMP/stranger.json"
mkdir -p "$TMP/strangerdir"; cp "$TMP/stranger.json" "$TMP/strangerdir/.claude.json"
CLAUDE_CONFIG_DIR="$TMP/strangerdir" run_sl "$(payload 50 5)" > /dev/null
[[ ! -e "$AI_QUOTAS_STATUSLINE_DIR" ]] && ok "an unregistered account's reading is dropped, not guessed" || fail "an unattributable reading was saved"

# Two registered accounts that claim the same email are ambiguous: drop.
cp "$AI_QUOTAS_CONFIG" "$TMP/config.keep"
printf '{"oauthAccount":{"emailAddress":"%s"}}' "$WORK" > "$PERS_DIR/.claude.json"
CLAUDE_CONFIG_DIR="$WORK_DIR" run_sl "$(payload 50 5)" > /dev/null
[[ ! -e "$AI_QUOTAS_STATUSLINE_DIR" ]] && ok "an ambiguous match saves nothing" || fail "an ambiguous reading was saved"
printf '{"oauthAccount":{"emailAddress":"%s"}}' "$PERS" > "$PERS_DIR/.claude.json"

# An unwritable save target must not break the line.
mkdir -p "$TMP/ro"; chmod 500 "$TMP/ro"
out="$(printf '%s' "$(payload 50 5)" | AI_QUOTAS_NOW="$NOW" AI_QUOTAS_STATUSLINE_DIR="$TMP/ro/sub" CLAUDE_CONFIG_DIR="$WORK_DIR" "$STATUSLINE" 2>/dev/null)"
[[ -n "$out" ]] && ok "an unwritable save folder: the line still prints" || fail "line lost on an unwritable folder"
chmod 700 "$TMP/ro"

# Unchanged figures inside the throttle window do not rewrite the file.
rm -rf "$AI_QUOTAS_STATUSLINE_DIR"
CLAUDE_CONFIG_DIR="$WORK_DIR" run_sl "$(payload 63 12)" > /dev/null
touch -t 202001010000 "$(reading_file "$WORK")"
CLAUDE_CONFIG_DIR="$WORK_DIR" run_sl "$(payload 63 12)" > /dev/null
[[ "$(stat -c '%y' "$(reading_file "$WORK")" 2>/dev/null | cut -c1-4 | grep -E '^[0-9]{4}$' || stat -f '%Sm' -t '%Y' "$(reading_file "$WORK")")" == "2020" ]] \
  && ok "an unchanged reading inside the throttle window is not rewritten" || fail "the file was rewritten despite no change"
CLAUDE_CONFIG_DIR="$WORK_DIR" run_sl "$(payload 64 12)" > /dev/null
check_eq "$(jq -r '.windows.seven_day.used_pct' "$(reading_file "$WORK")")" "64" "a changed figure is written at once"

# One malformed window must not drop a valid one (each window stands alone).
rm -rf "$AI_QUOTAS_STATUSLINE_DIR"
mixed="$(jq -nc --argjson r "$PAYLOAD_FUTURE" '{cwd:"/tmp", rate_limits:{five_hour:{used_percentage:12, resets_at:null}, seven_day:{used_percentage:40, resets_at:$r}}}')"
CLAUDE_CONFIG_DIR="$WORK_DIR" run_sl "$mixed" > /dev/null
check_eq "$(jq -r '.windows.seven_day.used_pct' "$(reading_file "$WORK")" 2>/dev/null)" "40" "a malformed 5-hour window does not lose a valid 7-day one"
check_eq "$(jq -r '.windows.five_hour // "none"' "$(reading_file "$WORK")" 2>/dev/null)" "none" "and the malformed window is left out"
# A percentage outside 0-100 is rejected.
rm -rf "$AI_QUOTAS_STATUSLINE_DIR"
CLAUDE_CONFIG_DIR="$WORK_DIR" run_sl "$(payload 140 12)" > /dev/null
check_eq "$(jq -r '.windows.seven_day // "none"' "$(reading_file "$WORK")" 2>/dev/null)" "none" "a 7-day percentage above 100 is not saved"
CLAUDE_CONFIG_DIR="$WORK_DIR" run_sl "$(payload 64 12)" > /dev/null

# --- 3. the reader uses a fresh reading and never touches the token ----------
run_sl "$(payload 22 5)" > /dev/null
: > "$CURL_LOG"
json="$(run_reader "$(( NOW + 30 ))")"
check_eq "$(row_field "$json" "$WORK" 7-day status)" "ok" "a fresh reading reads ok with the stored token expired"
check_eq "$(row_field "$json" "$WORK" 7-day used_pct)" "64" "the row carries the 7-day used percentage"
check_eq "$(row_field "$json" "$WORK" 7-day resets_at_epoch)" "$PAYLOAD_FUTURE" "and its reset time"
check_eq "$(row_field "$json" "$WORK" 7-day source)" "status-line" "and says it came from the status line"
check_contains "$(row_field "$json" "$WORK" 7-day detail)" "status line" "with a note naming the status line"
check_eq "$(curl_calls .)" "0" "no request was made to either endpoint"
check_eq "$(printf '%s' "$json" | jq -r --arg l "$PERS" '[.rows[] | select(.label == $l)] | length')" "1" "the personal account has its own row"
check_eq "$(row_field "$json" "$PERS" 7-day used_pct)" "22" "and carries its own figure, never the work account's"
rm -f "$(reading_file "$PERS")"
check_lacks "$(cat "$CURL_LOG")" "SECRET" "no credential reached a request"

# Five-hour only on request.
json5="$(AI_QUOTAS_NOW="$(( NOW + 30 ))" "$READER" --json --no-last-known --five-hour 2>/dev/null)"
check_eq "$(row_field "$json5" "$WORK" 5-hour used_pct)" "12" "--five-hour reports the saved 5-hour figure"

# --- 4. a stale reading is not used ------------------------------------------
: > "$CURL_LOG"; rm -rf "$AI_QUOTAS_COOLOFF_DIR"
echo 429 > "$TOKEN_MODE"
json="$(run_reader "$(( NOW + 4000 ))" "$WORK")"
check_eq "$(row_field "$json" "$WORK" 7-day source)" "oauth-refresh" "a reading past the freshness limit is passed over for the token path"
check_contains "$(row_field "$json" "$WORK" 7-day detail)" "expired" "which reports the token path's own result"
check_eq "$(curl_calls token.test)" "1" "the token endpoint was asked once"
# A stale note rides on a successful token-path row.
echo 200 > "$TOKEN_MODE"; rm -rf "$AI_QUOTAS_COOLOFF_DIR"; : > "$CURL_LOG"
json="$(run_reader "$(( NOW + 4000 ))" "$WORK")"
check_eq "$(row_field "$json" "$WORK" 7-day status)" "ok" "with the token path working the row reads ok"
check_contains "$(row_field "$json" "$WORK" 7-day detail)" "status-line reading is" "and the row says the saved reading was too old"
check_eq "$(row_field "$json" "$WORK" 7-day source)" "oauth-usage" "from the token source"

# A reading whose weekly window has since reset describes another week.
: > "$CURL_LOG"
json="$(run_reader "$(( PAYLOAD_FUTURE + 10 ))" "$WORK")"
check_eq "$(row_field "$json" "$WORK" 7-day source)" "oauth-usage" "a reading from a window that has since reset is not used"

# A reading filed under another label is invalid for this account.
cp "$(reading_file "$WORK")" "$TMP/work-reading.json"
jq '.account_label = "someone@else.com"' "$TMP/work-reading.json" > "$(reading_file "$WORK")"
json="$(run_reader "$(( NOW + 30 ))" "$WORK")"
check_eq "$(row_field "$json" "$WORK" 7-day source)" "oauth-usage" "a reading carrying another account's label is not used"
cp "$TMP/work-reading.json" "$(reading_file "$WORK")"; chmod 600 "$(reading_file "$WORK")"

# --- 5. the weekly reserve accepts the status-line reading -------------------
jq '.windows.seven_day.used_pct = 97' "$(reading_file "$WORK")" > "$TMP/r.json" && cp "$TMP/r.json" "$(reading_file "$WORK")" && chmod 600 "$(reading_file "$WORK")"
rm -rf "$QUOTA_RESERVE_DIR"
env -u QUOTA_RESERVE_AI_QUOTAS_SH AI_QUOTAS_NOW="$(( NOW + 30 ))" QUOTA_RESERVE_NOW="$(( NOW + 30 ))" QUOTA_RESERVE_NOTIFY_CMD=true \
  "$RESERVE" --refresh --force > /dev/null 2>&1
check_eq "$(jq -r --arg l "$WORK" '.accounts[] | select(.label == $l) | .state' "$QUOTA_RESERVE_DIR/marker.json" 2>/dev/null)" "reserve" "quota-reserve --refresh marks the account at 97% as reserve from the status-line reading"
check_eq "$(jq -r --arg l "$WORK" '.accounts[] | select(.label == $l) | .used_pct' "$QUOTA_RESERVE_DIR/marker.json" 2>/dev/null)" "97" "with the reported percentage"

# --- 6. a 429 from the token endpoint pauses renewal -------------------------
rm -f "$(reading_file "$WORK")" "$(reading_file "$PERS")"
rm -rf "$AI_QUOTAS_COOLOFF_DIR"; : > "$CURL_LOG"; echo 429 > "$TOKEN_MODE"
seed_expired_credentials
json="$(run_reader "$NOW" "$WORK")"
check_eq "$(row_field "$json" "$WORK" 7-day status)" "rate-limited" "an expired token and a 429 on renewal reads rate-limited"
check_eq "$(curl_calls token.test)" "1" "the first run asks once"
json="$(run_reader "$(( NOW + 60 ))" "$WORK")"
check_eq "$(curl_calls token.test)" "1" "a run inside the cool-off makes no renewal request"
check_contains "$(row_field "$json" "$WORK" 7-day detail)" "paused" "and the row says renewal is paused"
check_eq "$(row_field "$json" "$WORK" 7-day status)" "rate-limited" "with the same status"
check_eq "$(stat -c '%a' "$AI_QUOTAS_COOLOFF_DIR/claude--$WORK.json" 2>/dev/null || stat -f '%Lp' "$AI_QUOTAS_COOLOFF_DIR/claude--$WORK.json")" "600" "the cool-off file is mode 600"
check_lacks "$(cat "$AI_QUOTAS_COOLOFF_DIR/claude--$WORK.json")" "SECRET" "and holds no credential"
json="$(run_reader "$(( NOW + 2000 ))" "$WORK")"
check_eq "$(curl_calls token.test)" "2" "once the cool-off ends, renewal is attempted again"

# An HTTP-date Retry-After longer than the default cool-off is honoured.
rm -rf "$AI_QUOTAS_COOLOFF_DIR"; : > "$CURL_LOG"
RA_EPOCH=$(( NOW + 7200 ))
date -u -d "@$RA_EPOCH" '+%a, %d %b %Y %H:%M:%S GMT' > "$TMP/retry-after" 2>/dev/null \
  || LC_ALL=C date -u -r "$RA_EPOCH" '+%a, %d %b %Y %H:%M:%S GMT' > "$TMP/retry-after"
seed_expired_credentials
run_reader "$NOW" "$WORK" > /dev/null
check_eq "$(jq -r '.until_epoch' "$AI_QUOTAS_COOLOFF_DIR/claude--$WORK.json" 2>/dev/null)" "$RA_EPOCH" "a Retry-After HTTP-date sets the cool-off to that time"
run_reader "$(( NOW + 3600 ))" "$WORK" > /dev/null
check_eq "$(curl_calls token.test)" "1" "and no renewal request is made before it"
rm -f "$TMP/retry-after"

# A cool-off that cannot be written is disclosed, not silent.
rm -rf "$AI_QUOTAS_COOLOFF_DIR"; : > "$CURL_LOG"
seed_expired_credentials
: > "$TMP/not-a-dir"
json="$(AI_QUOTAS_COOLOFF_DIR="$TMP/not-a-dir/sub" run_reader "$NOW" "$WORK")"
check_contains "$(row_field "$json" "$WORK" 7-day detail)" "cool-off could not be saved" "an unwritable cool-off folder is disclosed on the row"

echo "----------------------------------------"
echo "claude-status-reading.test.sh: $PASS passed, $FAILED failed"
[[ "$FAILED" -eq 0 ]]
