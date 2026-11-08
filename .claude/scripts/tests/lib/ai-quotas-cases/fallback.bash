#!/usr/bin/env bash
# Source-only quota fixture group: fallback. Run ai-quotas.test.sh.
# shellcheck source=../ai-quotas-fixtures.bash
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/ai-quotas-fixtures.bash"

# --- ordered source fallback (#1884) ------------------------------------------
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
run --json --browser
check_eq "$RC" "0" "interactive browser fallback completes"
check_eq "$(printf '%s' "$OUT" | jq -r '.[0].source')" "browser" "interactive Cursor fallback labels browser source"
check_eq "$(printf '%s' "$OUT" | jq -r '.[0].used_pct')" "37" "interactive bridge returns observed usage"
OUTCOMES_LEDGER="$CASE_HOME/.claude/ai-quotas-history.outcomes.jsonl"
check_eq "$(jq -s 'length' "$OUTCOMES_LEDGER")" "2" "ledger records primary and browser attempts"
check_eq "$(printf '%s' "$DOC" | jq -r '.account_reliability[0].attempts_7d')" "1" "source attempts count as one terminal account read"
run --json --browser
run --json --browser
check_eq "$(printf '%s' "$DOC" | jq -r '.recommendations[0].source')" "ide-token" "three primary failures recommend source change despite successful fallback"
check_eq "$(printf '%s' "$DOC" | jq -r '.account_reliability[0].streak_count')" "0" "successful fallback leaves account failure streak clear"
check_eq "$(wc -l < "$BROWSER_STUB_LOG" | tr -d ' ')" "3" "three interactive runs invoke actual bridge adapter"
run --json --quiet --browser
check_eq "$(wc -l < "$BROWSER_STUB_LOG" | tr -d ' ')" "3" "scheduled run never invokes browser even with explicit flag"
check_eq "$(tail -n 1 "$OUTCOMES_LEDGER" | jq -r '.skip_reason')" "browser-unattended" "scheduled browser skip is recorded explicitly"
check_eq "$(tail -n 1 "$OUTCOMES_LEDGER" | jq -r '.status')" "unreadable" "skip preserves the six-status ledger contract"
# Custom ordering wins without touching the Cursor API, and unknown sources fail safely.
jq '.accounts[0].sources=["browser","ide-token"] | .source_failure_threshold=2' "$CONFIG" > "$TMP/source-config"
mv "$TMP/source-config" "$CONFIG"
: > "$STUB_CURL_LOG"
run --json --browser
check_eq "$(wc -l < "$STUB_CURL_LOG" | tr -d ' ')" "0" "browser-first source preference avoids the failed primary"
export BROWSER_STUB_RESET=1788897600.5
run --json --browser
check_not_contains "$ERR" "syntax error" "fractional browser reset never reaches integer shell arithmetic"
check_eq "$(printf '%s' "$OUT" | jq -r '.[0].resets_at_epoch')" "1788897600" "browser reset floors fractional epoch seconds"
export BROWSER_STUB_RESET=1e100
run --json --browser
check_not_contains "$ERR" "syntax error" "huge finite browser reset never reaches shell arithmetic"
check_eq "$(printf '%s' "$OUT" | jq -r '.[0].resets_at_epoch')" "null" "out-of-range browser reset remains unknown"
unset BROWSER_STUB_RESET
export BROWSER_STUB_STATUS=unreadable
printf 'ok' > "$STUB_CURSOR_MODE"
run --json --browser
check_eq "$(printf '%s' "$OUT" | jq -r '.[0].source')" "ide-token" "stdin-reading failed browser cannot consume the next source"
check_eq "$(tail -n 1 "$OUTCOMES_LEDGER" | jq -r '.source')" "ide-token" "fallback after browser failure is recorded in ledger"
unset BROWSER_STUB_STATUS
export BROWSER_STUB_STAGE=denied BROWSER_STUB_FAIL=1
run --json --browser
check_eq "$(jq -r 'select(.source == "browser") | .error_class' "$OUTCOMES_LEDGER" | tail -n 1)" "browser_tool_denied" "guard denial survives failed CLI as fixed browser diagnostic"
check_eq "$(printf '%s' "$OUT" | jq -r '.[0].source')" "ide-token" "stage diagnostics preserve fallback after browser failure"
check_not_contains "$OUT$ERR$(cat "$OUTCOMES_LEDGER")" "BROWSER-RAW-SECRET-SENTINEL" "CLI stderr never reaches report or outcome ledger"
unset BROWSER_STUB_STAGE
run --json --browser
check_eq "$(jq -r 'select(.source == "browser") | .error_class' "$OUTCOMES_LEDGER" | tail -n 1)" "browser_stage_unknown" "failed CLI without guard evidence does not invent bootstrap cause"
unset BROWSER_STUB_FAIL
printf 'ratelimit' > "$STUB_CURSOR_MODE"
run --browser-results "" --json
check_eq "$RC" "3" "empty browser-results filename is refused before enabling browser mode"
run --browser-results
check_eq "$RC" "3" "missing browser-results filename is a usage error"
