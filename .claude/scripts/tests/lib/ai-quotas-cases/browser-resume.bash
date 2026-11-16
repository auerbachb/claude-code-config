#!/usr/bin/env bash
# Source-only quota fixture group: browser-resume. Run ai-quotas.test.sh.
# shellcheck source=../ai-quotas-fixtures.bash
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/ai-quotas-fixtures.bash"

# Independent browser bridge/configuration; no prior assertions or reads are replayed.
reset_state
mkdir -p "$TMP/browser-account"
write_config "$(account_json cursor cursor-browser "$TMP/browser-account")"
printf 'ratelimit' > "$STUB_CURSOR_MODE"
export AI_QUOTAS_BROWSER_CLI="$BIN/browser-bridge"
export BROWSER_STUB_LOG="$TMP/browser-bridge.log"
export BROWSER_STUB_LABEL=cursor-browser
export BROWSER_STUB_NOW="$NOW"
: > "$BROWSER_STUB_LOG"
cat > "$AI_QUOTAS_BROWSER_CLI" <<'BROWSER_STUB'
#!/usr/bin/env python3
import json, os, sys, shlex, subprocess
with open(os.environ['BROWSER_STUB_LOG'], 'a') as log: log.write('read\n')
sys.stdin.read()  # A CLI that reads stdin must not consume remaining source names.
assert '--chrome' in sys.argv and '--settings' in sys.argv
if os.environ.get('BROWSER_STUB_STAGE'):
 from pathlib import Path
 settings=json.loads(sys.argv[sys.argv.index('--settings')+1])
 evidence=Path(shlex.split(settings['hooks']['PreToolUse'][0]['hooks'][0]['command'])[3])
 evidence.write_text(json.dumps(dict(last_failure=os.environ['BROWSER_STUB_STAGE'],owned_tab=False,read_authorized=False)));evidence.chmod(0o600)
if os.environ.get('BROWSER_STUB_FAIL'):
 print('BROWSER-RAW-SECRET-SENTINEL',file=sys.stderr);sys.exit(1)
# Successful fixtures exercise the actual private hook path rather than minting
# a receipt or treating plausible model JSON as a completed native read.
if not os.environ.get('BROWSER_STUB_STATUS'):
 settings=json.loads(sys.argv[sys.argv.index('--settings')+1])
 command=shlex.split(settings['hooks']['PreToolUse'][0]['hooks'][0]['command'])
 tab=42;url='https://cursor.com/dashboard?tab=usage'
 def event(name,params,phase='PreToolUse',response=None):
  data=dict(hook_event_name=phase,tool_name='mcp__claude-in-chrome__'+name,
            tool_input=params,tool_response=response,tool_use_id='toolu_quota_fixture_'+name)
  result=subprocess.run(command,input=json.dumps(data),text=True,capture_output=True,check=True)
  if phase=='PreToolUse':assert json.loads(result.stdout)['hookSpecificOutput']['permissionDecision']=='allow'
 event('tabs_create_mcp',{})
 event('tabs_create_mcp',{},'PostToolUse',[{'type':'text','text':'Created new tab. Tab ID: 42'}])
 event('navigate',dict(tabId=tab,url=url))
 event('navigate',dict(tabId=tab,url=url),'PostToolUse',[{'type':'text','text':'Navigated to '+url}])
 event('tabs_context_mcp',{})
 event('tabs_context_mcp',{},'PostToolUse',[{'type':'text','text':json.dumps({'availableTabs':[dict(tabId=tab,url=url)]})}])
 event('read_page',dict(tabId=tab))
 event('read_page',dict(tabId=tab),'PostToolUse',[{'type':'text','text':'Synthetic quota fixture usage: 37%'}])
print(json.dumps({'structured_output': {'schema_version':1, 'provider':'cursor',
  'label':os.environ['BROWSER_STUB_LABEL'], 'email':os.environ.get('BROWSER_STUB_EMAIL','cursor-fixture@example.com'),
  'status':os.environ.get('BROWSER_STUB_STATUS','ok'), 'observed_at_epoch':int(os.environ['BROWSER_STUB_NOW']),
  'rows':[] if os.environ.get('BROWSER_STUB_STATUS') else [{'window':'cursor-models','used_pct':37,'resets_at_epoch':float(os.environ['BROWSER_STUB_RESET']) if os.environ.get('BROWSER_STUB_RESET') else None}]}}))
BROWSER_STUB
chmod +x "$AI_QUOTAS_BROWSER_CLI"

OUTCOMES_LEDGER="$CASE_HOME/.claude/ai-quotas-history.outcomes.jsonl"
# Browser acquisition uses the same Claude resolver, including its explicit seam.
cp "$BIN/claude" "$TMP/claude-before-browser"
cp "$AI_QUOTAS_BROWSER_CLI" "$BIN/claude"
unset AI_QUOTAS_BROWSER_CLI
run --json --browser
check_eq "$(printf '%s' "$OUT" | jq -r '.[0].source')" "browser" "browser resolves Claude through the existing provider binary resolver"
# Chrome-collector path (#1870): a page that shows no email is accepted as unverified through the
# same flag as an observation file; a supplied email that differs is still rejected.
BROWSER_STUB_EMAIL="" run --json --browser
check_eq "$(printf '%s' "$OUT" | jq -r '[.[] | select(.status == "ok")] | length')" "1" "the Chrome collector accepts a page with no email"
check_eq "$(printf '%s' "$OUT" | jq -r '.[0].identity_verified')" "false" "a collector reading with no email is marked unverified"
check_contains "$(printf '%s' "$OUT" | jq -r '.[0].detail')" "account not verified" "a collector reading with no email says so"
BROWSER_STUB_EMAIL="someone-else@example.com" run --json --browser
check_eq "$(printf '%s' "$OUT" | jq -r '[.[] | select(.status == "ok")] | length')" "0" "the Chrome collector rejects a supplied email that differs"
BROWSER_STUB_EMAIL="   " run --json --browser
check_eq "$(printf '%s' "$OUT" | jq -r '[.[] | select(.status == "ok")] | length')" "0" "a whitespace-only email is rejected, not treated as empty"
cp "$TMP/claude-before-browser" "$BIN/claude"
export AI_QUOTAS_BROWSER_CLI="$BIN/browser-bridge"
# Browser-first identity lookup applies the same control filter as the IDE reader.
jq '.accounts[0].sources=["browser"]' "$CONFIG" > "$TMP/source-config"
mv "$TMP/source-config" "$CONFIG"
cp "$CURSOR_DB" "$TMP/browser-control-email.vscdb"
"$SQLITE3_REAL" "$TMP/browser-control-email.vscdb" "update ItemTable set value='bad-' || char(9) || 'name' || char(10) || '@example.com' where key='cursorAuth/cachedEmail';"
CURSOR_DB_UNDER_TEST="$TMP/browser-control-email.vscdb"
run --json --browser
check_eq "$(printf '%s' "$OUT" | jq -r '.[0].reported_email')" "cursor-browser" "controlled cached email is cleared before browser identity/output"
check_eq "$(printf '%s' "$OUT" | jq -r '.[0].status')" "unreadable" "unknown independent identity cannot establish browser usage"
CURSOR_DB_UNDER_TEST=""

jq '.accounts[0].sources=["unknown-source"]' "$CONFIG" > "$TMP/source-config"
mv "$TMP/source-config" "$CONFIG"
run --json
check_eq "$RC" "0" "unknown configured source fails without aborting report"
check_eq "$(tail -n 1 "$OUTCOMES_LEDGER" | jq -r '.error_class')" "source_unsupported" "unknown source gets a sanitized fixed class"
# Result mode cannot invent browser rows for another provider or an ambiguous label.
run --json --account cursor-browser --browser-results "$TMP/not-needed"
check_eq "$RC" "3" "resume refuses a Cursor account with browser excluded"
C1="$(seed_claude_profile resume-other Claude-resume-other)"
write_config "$(account_json claude resume-other "$C1" Claude-resume-other | jq '.sources=["oauth-usage"]')"
run --json --account resume-other --browser-results "$TMP/not-needed"
check_eq "$RC" "3" "resume refuses a Claude label without browser configured, before any read"
write_config "$(account_json cursor shared-label "$TMP/browser-account")" "$(account_json claude shared-label "$C1" Claude-resume-other)"
run --json --account shared-label --browser-results "$TMP/not-needed"
check_eq "$RC" "3" "resume refuses an unreadable observation for a cross-provider label before any read (#2337)"
# Scheduled context ignores resume flags and performs its normal source chain.
run --json --quiet --account shared-label --browser-results "$TMP/not-needed"
check_eq "$RC" "0" "scheduled context ignores browser result mode"
unset AI_QUOTAS_BROWSER_CLI

# --- Cursor Spending-page observation and the encrypted IDE token (#1870) -----
# The recorded reading is the one an agent took from cursor.com/dashboard/spending:
# Ultra, both pools 100% used, on-demand $6.33 of $50, limits reset Nov 28. Only
# figures and the fixture identity are in the file.
reset_state
OBS_LABEL="cursor-spending"
write_config "$(account_json cursor "$OBS_LABEL" "$TMP/browser-account")"
CURSOR_DB_UNDER_TEST="$TMP/cursor-spending-encrypted.vscdb"
build_cursor_db "$CURSOR_DB_UNDER_TEST" 'cursor-safe-storage:v1:FIXTURE_CIPHER_SENTINEL'
OBS_LEDGER="$CASE_HOME/.claude/ai-quotas-history.outcomes.jsonl"
OBS_RESET="$(python3 -c 'import datetime as d; print(int(d.datetime(2026,11,28,17,0,tzinfo=d.timezone.utc).timestamp()))')"
for _i in 1 2 3 4; do run --json; done
check_eq "$(field_of "$OBS_LABEL" billing-cycle status)" "unreadable" "encrypted IDE token reports unreadable, never zero usage"
check_contains "$(field_of "$OBS_LABEL" billing-cycle detail)" "--print-instructions cursor" "encrypted IDE token hint names the observation route"
check_eq "$(jq -r 'select(.source == "ide-token") | .error_class' "$OBS_LEDGER" | sort -u)" "ide_token_encrypted" "encrypted IDE token is recorded under one fixed class"
check_eq "$(printf '%s' "$DOC" | jq '.recommendations | length')" "0" "a standing encrypted-token state never becomes a repeated source-failed alert"
check_eq "$(printf '%s' "$OUT" | grep -c 'FIXTURE_CIPHER_SENTINEL' || true)" "0" "the stored ciphertext never reaches the output"

jq -n --argjson ob "$NOW" --argjson reset "$OBS_RESET" --arg label "$OBS_LABEL" --arg email "$CURSOR_FIXTURE_EMAIL" \
  '{schema_version:1,provider:"cursor",label:$label,email:$email,status:"ok",observed_at_epoch:$ob,plan:"Ultra",
    on_demand_used_usd:6.33,on_demand_limit_usd:50,cycle_resets_at_epoch:$reset,
    rows:[{window:"cursor-models",used_pct:100,resets_at_epoch:null},{window:"other-models",used_pct:100,resets_at_epoch:null}]}' > "$TMP/cursor-spending-obs.json"
chmod 600 "$TMP/cursor-spending-obs.json"
run --json --account "$OBS_LABEL" --browser-results "$TMP/cursor-spending-obs.json"
check_eq "$RC" "0" "a Spending-page observation resumes the Cursor account"
check_eq "$(printf '%s' "$OUT" | jq '[.[] | select(.label == "cursor-spending" and .status == "ok")] | length')" "2" "both pool rows are shown"
check_eq "$(printf '%s' "$OUT" | jq -r '[.[] | select(.label == "cursor-spending") | .pool] | sort | join(",")')" "cursor-models,other-models" "the two pools are named"
check_eq "$(printf '%s' "$OUT" | jq -r '[.[] | select(.label == "cursor-spending") | .used_pct] | unique | join(",")')" "100" "both pools read 100 percent"
check_eq "$(printf '%s' "$OUT" | jq -r '[.[] | select(.label == "cursor-spending") | .spend_limit_used_usd] | unique | join(",")')" "6.33" "on-demand spend is exposed"
check_eq "$(printf '%s' "$OUT" | jq -r '[.[] | select(.label == "cursor-spending") | .spend_limit_usd] | unique | join(",")')" "50" "on-demand limit is exposed"
check_eq "$(printf '%s' "$OUT" | jq -r '[.[] | select(.label == "cursor-spending") | .plan] | unique | join(",")')" "Ultra" "plan is exposed"
check_eq "$(printf '%s' "$OUT" | jq -r '[.[] | select(.label == "cursor-spending") | .resets_at_epoch] | unique | join(",")')" "$OBS_RESET" "the cycle reset date fills rows that carry none"
check_eq "$(printf '%s' "$OUT" | jq -r '[.[] | select(.label == "cursor-spending") | .source] | unique | join(",")')" "browser" "the rows name the browser source"

# An unlimited on-demand limit is reported as such, not as a number.
jq '.on_demand_limit_usd=null | .on_demand_unlimited=true' "$TMP/cursor-spending-obs.json" > "$TMP/cursor-spending-unl.json"
chmod 600 "$TMP/cursor-spending-unl.json"
run --json --account "$OBS_LABEL" --browser-results "$TMP/cursor-spending-unl.json"
check_eq "$(field_of "$OBS_LABEL" billing-cycle spend_limit_unlimited | head -n 1)" "true" "unlimited on-demand is flagged"
check_eq "$(field_of "$OBS_LABEL" billing-cycle spend_limit_usd | head -n 1)" "null" "unlimited on-demand carries no dollar limit"

# An observation file without the new fields still works.
jq 'del(.plan,.on_demand_used_usd,.on_demand_limit_usd,.cycle_resets_at_epoch)' "$TMP/cursor-spending-obs.json" > "$TMP/cursor-spending-old.json"
chmod 600 "$TMP/cursor-spending-old.json"
run --json --account "$OBS_LABEL" --browser-results "$TMP/cursor-spending-old.json"
check_eq "$(printf '%s' "$OUT" | jq '[.[] | select(.label == "cursor-spending" and .status == "ok")] | length')" "2" "an older observation without spending fields still reads"
check_eq "$(field_of "$OBS_LABEL" billing-cycle spend_limit_usd | head -n 1)" "null" "absent on-demand figures stay null, never zero"
CURSOR_DB_UNDER_TEST=""

# Identity (#1870): the dashboard shows no account email, so a Cursor observation may leave it
# empty, null or absent and is shown marked unverified. A supplied email must still match.
run --json --account "$OBS_LABEL" --browser-results "$TMP/cursor-spending-obs.json"
check_eq "$(printf '%s' "$OUT" | jq -r '[.[] | select(.label == "cursor-spending") | .identity_verified] | unique | join(",")')" "true" "a matching email marks the rows verified"
for _shape in '.email=""' '.email=null' 'del(.email)'; do
  jq "$_shape" "$TMP/cursor-spending-obs.json" > "$TMP/cursor-spending-noemail.json"
  chmod 600 "$TMP/cursor-spending-noemail.json"
  run --json --account "$OBS_LABEL" --browser-results "$TMP/cursor-spending-noemail.json"
  check_eq "$(printf '%s' "$OUT" | jq '[.[] | select(.label == "cursor-spending" and .status == "ok")] | length')" "2" "a Cursor observation with email $_shape is accepted"
  check_eq "$(printf '%s' "$OUT" | jq -r '[.[] | select(.label == "cursor-spending") | .identity_verified] | unique | join(",")')" "false" "email $_shape is marked identity_verified false"
  check_contains "$(field_of "$OBS_LABEL" billing-cycle detail)" "account not verified" "email $_shape says the account was not verified"
done
check_eq "$(printf '%s' "$OUT" | jq -r '[.[] | select(.label == "cursor-spending") | .used_pct] | unique | join(",")')" "100" "an unverified observation still shows its figures"
check_eq "$(grep -rl 'account not verified' "$CASE_HOME/.claude/ai-quotas/last-known" 2>/dev/null | wc -l | tr -d ' ')" "1" "an unverified observation is saved under an unverified last-known source"
jq '.email="someone-else@example.com"' "$TMP/cursor-spending-obs.json" > "$TMP/cursor-spending-wrong.json"
chmod 600 "$TMP/cursor-spending-wrong.json"
run --json --account "$OBS_LABEL" --browser-results "$TMP/cursor-spending-wrong.json"
check_eq "$(printf '%s' "$OUT" | jq '[.[] | select(.label == "cursor-spending" and .status == "ok")] | length')" "0" "a supplied email that does not match is still rejected"
check_eq "$(printf '%s' "$OUT" | jq -r '[.[] | select(.label == "cursor-spending") | .identity_verified] | unique | join(",")')" "" "a rejected observation carries no verification claim"
# Restore (#1870): an unverified reading stays marked unverified when it is shown later, and a
# later verified reading replaces it with no mark.
jq '.email=""' "$TMP/cursor-spending-obs.json" > "$TMP/cursor-spending-noemail.json"; chmod 600 "$TMP/cursor-spending-noemail.json"
run --json --account "$OBS_LABEL" --browser-results "$TMP/cursor-spending-noemail.json"
_lkfile="$(grep -rl 'account not verified' "$CASE_HOME/.claude/ai-quotas/last-known" | head -n 1)"
check_eq "$(jq -r '[.rows[].source] | unique | join(",")' "$_lkfile")" "live: browser (account not verified)" "every saved row of an unverified reading carries the unverified source"
jq '.status="logged_out" | .rows=[]' "$TMP/cursor-spending-obs.json" > "$TMP/cursor-spending-out.json"; chmod 600 "$TMP/cursor-spending-out.json"
run --json --account "$OBS_LABEL" --browser-results "$TMP/cursor-spending-out.json"
check_contains "$(printf '%s' "$OUT" | jq -r '[.[] | select(.label == "cursor-spending") | .last_known_source] | unique | join(",")')" "account not verified" "a restored unverified reading still says it was not verified"
# A later verified reading replaces it.
run --json --account "$OBS_LABEL" --browser-results "$TMP/cursor-spending-obs.json"
check_eq "$(jq -r '[.rows[].source] | unique | join(",")' "$_lkfile")" "live: browser" "a later verified reading replaces the unverified marking"
CURSOR_DB_UNDER_TEST=""

# The cycle start comes from the observed reset: the same day and time one calendar month
# earlier (UTC), not reset minus 30 days, and a day the earlier month lacks falls back to
# that month's last day (#1870).
OBS_START="$(python3 -c 'import datetime as d; print(int(d.datetime(2026,10,28,17,0,tzinfo=d.timezone.utc).timestamp()))')"
run --json --account "$OBS_LABEL" --browser-results "$TMP/cursor-spending-obs.json"
check_eq "$(printf '%s' "$OUT" | jq -r '[.[] | select(.label == "cursor-spending") | .window_start_epoch] | unique | join(",")')" "$OBS_START" "the cycle start is the reset day one month earlier"
MAR31="$(python3 -c 'import datetime as d; print(int(d.datetime(2027,3,31,17,0,tzinfo=d.timezone.utc).timestamp()))')"
FEB28="$(python3 -c 'import datetime as d; print(int(d.datetime(2027,2,28,17,0,tzinfo=d.timezone.utc).timestamp()))')"
jq --argjson r "$MAR31" '.cycle_resets_at_epoch=$r' "$TMP/cursor-spending-obs.json" > "$TMP/cursor-spending-mar.json"
chmod 600 "$TMP/cursor-spending-mar.json"
run --json --account "$OBS_LABEL" --browser-results "$TMP/cursor-spending-mar.json"
check_eq "$(printf '%s' "$OUT" | jq -r '[.[] | select(.label == "cursor-spending") | .window_start_epoch] | unique | join(",")')" "$FEB28" "a reset on the 31st starts on the last day of the shorter earlier month"
