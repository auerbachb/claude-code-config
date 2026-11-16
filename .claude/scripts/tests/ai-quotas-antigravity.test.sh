#!/usr/bin/env bash
# catalog: tests — Verifies the Antigravity /usage parser, observation capture, the `antigravity` provider rows in /quotas and its /quotas-setup registration against a recorded sample (Issue #2407)
set -euo pipefail

SCRIPTS="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PARSER="$SCRIPTS/lib/quotas-antigravity.py"
SAMPLE="$SCRIPTS/tests/fixtures/antigravity-usage-panel.txt"
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

export HOME="$T/home"
mkdir -p "$HOME"
CAP=1794389000
NOW=1794390000

# --- parser: the recorded sample -------------------------------------------------
parsed="$(python3 -I "$PARSER" parse "$SAMPLE" "$CAP")"
jq -e '.status == "ok" and .account == "<email>" and (.groups | length) == 3' <<<"$parsed" >/dev/null || fail "sample parses to three groups and an account"
jq -e '[.groups[] | .slug] == ["gemini","claude-gpt","gemini-4-argon"]' <<<"$parsed" >/dev/null || fail "group slugs"
jq -e '.groups[0].windows[0] | .name == "7-day" and .used_pct == 28.3 and .remaining_pct == 71.7 and .resets_at_epoch == '"$((CAP + 153*3600 + 32*60))"' and .full == false' <<<"$parsed" >/dev/null || fail "weekly window converts remaining to used and reset to an epoch"
jq -e '.groups[0].windows[1] | .name == "5-hour" and .used_pct == 0 and .resets_at_epoch == null and .full == true' <<<"$parsed" >/dev/null || fail "Quota available means full with no reset"
jq -e '.groups[2].windows | length == 1 and .[0].used_pct == 75 and .[0].resets_at_epoch == '"$((CAP + 153*3600 + 28*60))"'' <<<"$parsed" >/dev/null || fail "Argon weekly-only group"
jq -e '.groups[0].models == ["Gemini 4 Hydrogen","Gemini 3.8 Flash"]' <<<"$parsed" >/dev/null || fail "models list kept"
pass "recorded sample: groups, percent used, absolute resets, full windows"

# --- parser: tolerance ------------------------------------------------------------
messy="$T/messy.txt"
{ printf '\033[1m\033[36mGEMINI MODELS\033[0m\n\n\n\n'; printf '  Weekly Limit Remaining\n'; printf '    \033[32m████░░░░\033[0m 40.00%%\n\n\n'; printf '    Refreshes in 2d 3h\n'
  printf '\nBRAND NEW GROUP\n  Hourly Limit Remaining\n    50%%\n    Refreshes in 45m\n'; } > "$messy"
m="$(python3 -I "$PARSER" parse "$messy" "$CAP")"
jq -e '.status == "ok" and (.groups | map(.slug) == ["gemini","brand-new-group"])' <<<"$m" >/dev/null || fail "ANSI, blanks and an unseen group name are tolerated and kept"
jq -e '.groups[0].windows[0].resets_at_epoch == '"$((CAP + 2*86400 + 3*3600))"' and .groups[0].windows[0].used_pct == 60' <<<"$m" >/dev/null || fail "day/hour reset and ANSI-wrapped bar"
jq -e '.groups[1].windows[0] | .name == "hourly" and .used_pct == 50 and .resets_at_epoch == '"$((CAP + 45*60))"'' <<<"$m" >/dev/null || fail "unseen window name kept"
sed -n '/^CLAUDE AND GPT/,/^GEMINI 4/p' "$SAMPLE" | sed '$d' > "$T/one.txt"
python3 -I "$PARSER" parse "$T/one.txt" "$CAP" | jq -e '.status == "ok" and (.groups | length) == 1 and .account == null' >/dev/null || fail "a missing group and a missing account line"
pass "tolerates ANSI colour, blank lines, no bars, an unknown group, a missing group"

# --- parser: unreadable, never 0% ---------------------------------------------------
for garbage in "" "Sign in required" "limit 0%"; do
  r="$(printf '%s' "$garbage" | python3 -I "$PARSER" parse - "$CAP")"
  jq -e '.status == "unreadable" and (.groups | length) == 0' <<<"$r" >/dev/null || fail "unreadable for: $garbage"
done
r="$(printf 'GEMINI MODELS\n  Weekly Limit Remaining\n    150%%\n' | python3 -I "$PARSER" parse - "$CAP")"
jq -e '.status == "unreadable"' <<<"$r" >/dev/null || fail "an out-of-range percent is refused"
r="$(printf 'GEMINI MODELS\n  Weekly Limit Remaining\n    50%%\n  Five Hour Limit Remaining\n    150%%\n' | python3 -I "$PARSER" parse - "$CAP")"
jq -e '.status == "unreadable"' <<<"$r" >/dev/null || fail "a mixed valid and out-of-range panel is unreadable"
r="$(printf 'GEMINI MODELS\n  Weekly Limit Remaining\n    50%%\n  Five Hour Limit Remaining\n    -5%%\n' | python3 -I "$PARSER" parse - "$CAP")"
jq -e '.status == "unreadable"' <<<"$r" >/dev/null || fail "a negative percent beside a valid window is unreadable"
for bad in "Refreshes in -2h" "Refreshes in 1.5h" "Refreshes in" "Refreshes in 5m 2h" "Refreshes in soon"; do
  r="$(printf 'GEMINI MODELS\n  Weekly Limit Remaining\n    50%%\n    %s\n' "$bad" | python3 -I "$PARSER" parse - "$CAP")"
  jq -e '.status == "unreadable"' <<<"$r" >/dev/null || fail "malformed countdown is unreadable: $bad"
done
r="$(printf 'GEMINI MODELS\n  Weekly Limit Remaining\n    50%%\n    Refreshes in 1d 2h 5m\n' | python3 -I "$PARSER" parse - "$CAP")"
jq -e '.status == "ok" and .groups[0].windows[0].resets_at_epoch == '"$((CAP + 86400 + 7200 + 300))"'' <<<"$r" >/dev/null || fail "a well-formed d/h/m countdown still parses"
r="$(printf 'GEMINI MODELS\n  Weekly Limit Remaining\n    50%%\n  Five Hour Limit Remaining\n    N/A%%\n' | python3 -I "$PARSER" parse - "$CAP")"
jq -e '.status == "unreadable"' <<<"$r" >/dev/null || fail "an unrecognised percent beside a valid window is unreadable"
pass "unparseable input is unreadable, never 0%"

# --- capture helper -----------------------------------------------------------------
OBS="$T/obs.json"
export AI_QUOTAS_ANTIGRAVITY_OBSERVATION="$OBS"
out="$(bash "$SCRIPTS/quotas-antigravity-capture.sh" --from-file "$SAMPLE" --captured-at "$CAP")"
grep -Fq 'saved: 5 windows in 3 groups' <<<"$out" || fail "capture from file saves"
[[ "$(stat -c %a "$OBS" 2>/dev/null || stat -f %Lp "$OBS")" == 600 ]] || fail "observation file is private (0600)"
jq -e '.schema == "antigravity-usage/1" and .captured_at_epoch == '"$CAP"'' "$OBS" >/dev/null || fail "observation carries schema and capture time"
cp "$OBS" "$T/good.json"
if printf 'nothing here' | bash "$SCRIPTS/quotas-antigravity-capture.sh" --stdin 2>"$T/err"; then fail "garbage must be refused"; fi
grep -Fq 'nothing saved' "$T/err" || fail "refusal names the outcome"
cmp "$OBS" "$T/good.json" || fail "a refused capture leaves the saved observation untouched"
cat > "$T/agy-good" <<EOF
#!/bin/sh
[ "\$1" = "-p" ] && [ "\$2" = "/usage" ] || exit 9
cat "$SAMPLE"
EOF
printf '#!/bin/sh\necho "I cannot help with that"\n' > "$T/agy-bad"
chmod +x "$T/agy-good" "$T/agy-bad"
rm -f "$OBS"
out="$(AI_QUOTAS_AGY_BIN="$T/agy-good" bash "$SCRIPTS/quotas-antigravity-capture.sh" --live)"
grep -Fq 'saved:' <<<"$out" || fail "--live saves a printed panel"
jq -e '.via == "agy-print"' "$OBS" >/dev/null || fail "--live records where the text came from"
cp "$OBS" "$T/good.json"
if AI_QUOTAS_AGY_BIN="$T/agy-bad" bash "$SCRIPTS/quotas-antigravity-capture.sh" --live 2>/dev/null; then fail "--live must refuse non-panel output"; fi
cmp "$OBS" "$T/good.json" || fail "--live leaves the saved observation untouched on refusal"
if bash "$SCRIPTS/quotas-antigravity-capture.sh" --from-file "$SAMPLE" --captured-at "$((CAP - 600))" 2>"$T/err"; then fail "an older capture must not replace a newer one"; fi
grep -Fq 'newer reading' "$T/err" || fail "older-capture refusal names the reason"
cmp "$OBS" "$T/good.json" || fail "the newer observation is kept"
if bash "$SCRIPTS/quotas-antigravity-capture.sh" --from-file "$SAMPLE" --captured-at "$(( $(date +%s) + 9999 ))" 2>/dev/null; then fail "a future capture time is refused"; fi
jq --argjson c "$((CAP + 99999))" '.captured_at_epoch = $c' "$OBS" > "$T/future.json"
python3 -I "$PARSER" show "$T/future.json" "$CAP" | jq -e '.status == "unreadable" and (.reason | test("future"))' >/dev/null || fail "show refuses a future capture time"
helpout="$(bash "$SCRIPTS/quotas-antigravity-capture.sh" --help)"
grep -Fq 'Exit: 0 saved' <<<"$helpout" || fail "--help prints the whole header"
if grep -Eq 'set -euo|SELF_PATH' <<<"$helpout"; then fail "--help must stop at the end of the header comment"; fi
pass "capture: file, stdin refusal, --live with a fake agy, atomic and private"

# --- /quotas rows --------------------------------------------------------------------
export AI_QUOTAS_CONFIG="$T/accounts.json"
export AI_QUOTAS_HISTORY="$T/history.jsonl"
export AI_QUOTAS_LAST_KNOWN_DIR="$T/last-known"
export AI_QUOTAS_NOW="$NOW"
export AI_QUOTAS_CLAUDE_VERSION=1.0.0
export AI_QUOTAS_AGY_BIN="$T/agy-good"
rm -f "$OBS"
bash "$SCRIPTS/quotas-antigravity-capture.sh" --from-file "$SAMPLE" --captured-at "$CAP" >/dev/null
printf '%s\n' '{"schema_version":"1.0","accounts":[]}' > "$AI_QUOTAS_CONFIG"
bash "$SCRIPTS/ai-quotas-setup.sh" add antigravity personal >/dev/null 2>&1 || fail "setup registers an antigravity account"
if bash "$SCRIPTS/ai-quotas-setup.sh" add antigravity second >/dev/null 2>&1; then fail "a second antigravity account must be refused"; fi
jq -e '[.accounts[] | select(.provider == "antigravity")] | length == 1' "$AI_QUOTAS_CONFIG" >/dev/null || fail "one antigravity account is held"
setup_refuses() { # <name> <setup args...>
  local name="$1" out
  shift
  if out="$(bash "$SCRIPTS/ai-quotas-setup.sh" "$@" 2>&1)"; then fail "setup $name must refuse antigravity"; fi
  [[ "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" == 1 ]] || { printf '%s\n' "$out" >&2; fail "setup $name refuses in one line"; }
  grep -Eiq 'antigravity' <<<"$out" || fail "setup $name refusal names antigravity"
}
list_out="$(bash "$SCRIPTS/ai-quotas-setup.sh" list 2>&1)"
grep -Fq 'agy is installed' <<<"$list_out" || { printf '%s\n' "$list_out" >&2; fail "list shows the CLI presence note"; }
[[ ! -e "$HOME/.claude/ai-quotas/profiles/personal/antigravity" ]] || fail "no profile directory is created"
setup_refuses report report personal 7-day 50 antigravity
setup_refuses relogin relogin personal antigravity
setup_refuses share-config share-config personal antigravity
setup_refuses "a repeated add" add antigravity personal
dup="$(bash "$SCRIPTS/ai-quotas-setup.sh" add antigravity personal 2>&1 || true)"
grep -Fq 'quotas-antigravity-capture.sh' <<<"$dup" || fail "a repeated add points at the capture command"
if grep -Fq relogin <<<"$dup"; then fail "a repeated add must not recommend relogin"; fi

rows="$(bash "$SCRIPTS/ai-quotas.sh" --json 2>/dev/null)"
jq -e '[.rows[] | select(.provider == "antigravity")] | length == 5' <<<"$rows" >/dev/null || fail "one row per group and window"
jq -e '[.rows[] | select(.window == "gemini 7-day")] | .[0] | .status == "ok" and .used_pct == 28.3 and .group == "Gemini Models" and .source == "observation" and (.detail | test("pasted /usage text, observed 16m ago"))' <<<"$rows" >/dev/null || fail "weekly Gemini row"
jq -e '[.rows[] | select(.window == "gemini-4-argon 7-day")] | .[0] | .used_pct == 75 and .resets_at_epoch == '"$((CAP + 153*3600 + 28*60))"'' <<<"$rows" >/dev/null || fail "Argon row carries its reset"
jq -e '[.rows[] | select(.provider == "antigravity" and ((.detail // "") | test("not verified"))) ] | length == 5' <<<"$rows" >/dev/null || fail "rows say the account is not verified"
pass "/quotas rows: one per group and window, used percent, reset, source, not verified"

# FETCHED (#2406): the observation's capture time is when the figure was read, so a
# row shows that date; `now` only for a capture at or after the run began.
cap_date="$(python3 -c 'import sys,datetime,zoneinfo; print(datetime.datetime.fromtimestamp(int(sys.argv[1]), zoneinfo.ZoneInfo("America/New_York")).strftime("%b %d"))' "$CAP")"
jq -e --arg d "$cap_date" '[.rows[] | select(.provider == "antigravity")] | all(.fetched == "saved" and .fetched_display == $d and .fetched_at_epoch == '"$CAP"')' <<<"$rows" >/dev/null || fail "figures read from a saved observation show its capture date, not now"
live_now="$(AI_QUOTAS_NOW="$CAP" bash "$SCRIPTS/ai-quotas.sh" --json 2>/dev/null)"
jq -e '[.rows[] | select(.provider == "antigravity")] | all(.fetched == "live" and .fetched_display == "now")' <<<"$live_now" >/dev/null || fail "an observation captured at the start of the run is now"
pass "FETCHED on Antigravity rows: capture date, now only when captured during the run"

# Stale: shown with its age and the last known figure, not as a live one.
stale="$(AI_QUOTAS_NOW=$((CAP + 4*3600)) bash "$SCRIPTS/ai-quotas.sh" --json 2>/dev/null)"
jq -e '[.rows[] | select(.provider == "antigravity")] | all(.status == "unreadable" and .used_pct == null and (.detail | test("stale: captured 4h 0m ago.*account not verified")) )' <<<"$stale" >/dev/null || fail "stale rows carry age and no live figure"
jq -e '[.rows[] | select(.window == "gemini 7-day")] | .[0].last_known_used_pct == 28.3' <<<"$stale" >/dev/null || fail "stale rows keep the last known figure"
# A reset that passed after the capture also makes that window stale.
expired="$(AI_QUOTAS_NOW=$((CAP + 154*3600)) AI_QUOTAS_ANTIGRAVITY_STALE_SECONDS=99999999 bash "$SCRIPTS/ai-quotas.sh" --json 2>/dev/null)"
jq -e '([.rows[] | select(.window == "gemini 7-day")] | .[0].status == "unreadable") and ([.rows[] | select(.window == "claude-gpt 5-hour")] | .[0].status == "ok")' <<<"$expired" >/dev/null || fail "only the window whose reset passed goes stale"
jq -e --arg d "$cap_date" '[.rows[] | select(.provider == "antigravity")] | all(.fetched == "saved" and .fetched_display == $d)' <<<"$stale" >/dev/null || fail "stale rows show the capture date of their last-known figure"
pass "stale observations show age and last known; no figure invented"

# Missing observation: a clear unreadable row.
rm -f "$OBS"
none="$(bash "$SCRIPTS/ai-quotas.sh" --json 2>/dev/null)"
jq -e '[.rows[] | select(.provider == "antigravity")] | length == 1 and .[0].status == "unreadable" and .[0].used_pct == null and (.[0].detail | test("no Antigravity reading yet"))' <<<"$none" >/dev/null || fail "no observation -> one unreadable row naming what is missing"
jq -e '[.rows[] | select(.provider == "antigravity")] | all(has("fetched_at") and .fetched == null and .fetched_display == null and .fetched_at == null)' <<<"$none" >/dev/null || fail "no figure: the new fields are present and null, never now"
printf 'not json' > "$OBS"
bad="$(bash "$SCRIPTS/ai-quotas.sh" --json 2>/dev/null)"
jq -e '[.rows[] | select(.provider == "antigravity")] | .[0].status == "unreadable" and .[0].used_pct == null' <<<"$bad" >/dev/null || fail "a corrupt observation is unreadable, not 0%"
pass "missing or corrupt observation gives an unreadable row"

# --- display only ---------------------------------------------------------------------
grep -Fq 'select(.provider == "claude" or .provider == "codex")' "$SCRIPTS/quota-reserve.sh" || fail "quota-reserve keeps only Claude and Codex rows"
if grep -n 'antigravity' "$SCRIPTS/quota-reserve.sh" >/dev/null; then fail "quota-reserve must not mention antigravity"; fi
pass "Antigravity is display-only (the reserve gate reads Claude and Codex rows only)"
