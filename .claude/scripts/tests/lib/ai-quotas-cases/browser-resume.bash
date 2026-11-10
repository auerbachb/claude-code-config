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
  'label':os.environ['BROWSER_STUB_LABEL'], 'email':'cursor-fixture@example.com',
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
write_config "$(account_json claude resume-other "$C1" Claude-resume-other)"
run --json --account resume-other --browser-results "$TMP/not-needed"
check_eq "$RC" "3" "resume refuses a non-Cursor label before any read"
write_config "$(account_json cursor shared-label "$TMP/browser-account")" "$(account_json claude shared-label "$C1" Claude-resume-other)"
run --json --account shared-label --browser-results "$TMP/not-needed"
check_eq "$RC" "3" "resume refuses an ambiguous cross-provider label"
# Scheduled context ignores resume flags and performs its normal source chain.
run --json --quiet --account shared-label --browser-results "$TMP/not-needed"
check_eq "$RC" "0" "scheduled context ignores browser result mode"
unset AI_QUOTAS_BROWSER_CLI
