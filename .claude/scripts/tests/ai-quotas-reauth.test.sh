#!/bin/bash
# catalog: tests — Exercise owner-run fresh-profile reauthentication with private mixed/non-cycle stores, preserved original identities and publication failures
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
python3 - "$ROOT" "${BASH:-/bin/bash}" <<'PY'
from pathlib import Path
import shlex, subprocess, sys
root=Path(sys.argv[1])
fixture=(root/'.claude/scripts/tests/ai-quotas-setup.test.sh').read_text()
bootstrap=fixture.split('# --- 1. --help contract',1)[0]
old='ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"'
assert bootstrap.count(old)==1
bootstrap=bootstrap.replace(old,'ROOT='+shlex.quote(str(root)))
cases=r'''
# All provider writes below target a synthetic file-backed Keychain boundary.
# The provider, security, HOME and config seams never reach owner accounts.
unset CLAUDE_SECURESTORAGE_CONFIG_DIR AI_QUOTAS_KEYCHAIN_ADAPTER_BIN
export AI_QUOTAS_CLAUDE_LOGIN_ARGS='auth login --claudeai'
export REAUTH_REAL_MV="$(command -v mv)" REAUTH_FAIL_CONFIG=''
cat > "$BIN/mv" <<'MV'
#!/bin/bash
[[ -z "${REAUTH_FAIL_CONFIG:-}" || "${!#}" != "$REAUTH_FAIL_CONFIG" ]] || exit 1
exec "$REAUTH_REAL_MV" "$@"
MV
cat > "$BIN/reauth-provider" <<'PROVIDER'
#!/usr/bin/env python3
import hashlib,json,os,pathlib,sys,unicodedata
if sys.argv[1:]==['--version']:
 print('2.1.312 (Claude Code)');sys.exit(0)
assert sys.argv[1:]==['auth','login','--claudeai']
p=pathlib.Path(os.environ['CLAUDE_CONFIG_DIR'])
with open(os.environ['STUB_CALL_LOG'],'a') as f:f.write(str(p)+' auth-only\n')
mode=os.environ.get('REAUTH_LOGIN_MODE','ok')
if mode=='abort':sys.exit(1)
if mode=='silent':sys.exit(0)
svc='Claude Code-credentials-'+hashlib.sha256(unicodedata.normalize('NFC',str(p)).encode()).hexdigest()[:8]
db=pathlib.Path(os.environ['REAUTH_PAYLOAD_DB']);data=json.loads(db.read_text())
previous=data.get(svc,{})
data[svc]={'identity':'expected-subscription-fixture','value':'replacement-secret-fixture','acl':'replacement-acl','logins':previous.get('logins',0)+1}
db.write_text(json.dumps(data,sort_keys=True))
services=pathlib.Path(os.environ['STUB_KEYCHAIN_DB'])
if svc not in services.read_text().splitlines():
 with services.open('a') as f:f.write(svc+'\n')
(p/'account-identity').write_text(data[svc]['identity'])
PROVIDER
chmod +x "$BIN/mv" "$BIN/reauth-provider"
export PATH="$BIN:$PATH"
seed() {
  new_case "$1"
  PLATFORM_UNDER_TEST=Darwin
  CLAUDE_BIN_UNDER_TEST="$BIN/reauth-provider"
  export REAUTH_PAYLOAD_DB="$CASE_DIR/payload.json" REAUTH_LOGIN_MODE=ok
  # alpha's original path is a non-cycle destination. Mixed adds a file-backed
  # beta whose canonical destination is occupied by alpha's original directory.
  python3 - "$CONFIG" "$PROFILES" "$REAUTH_PAYLOAD_DB" "$STUB_KEYCHAIN_DB" "$2" <<'SEED'
import hashlib,json,pathlib,sys,unicodedata
cfg,root,db,services=map(pathlib.Path,sys.argv[1:5]);rows=[];data={}
p=root/'displaced'/'claude';p.mkdir(parents=True)
svc='Claude Code-credentials-'+hashlib.sha256(unicodedata.normalize('NFC',str(p)).encode()).hexdigest()[:8]
rows.append({'provider':'claude','label':'alpha','profile_dir':str(p),'credential_ref':{'kind':'macos-keychain','service':svc}})
(p.parent/'.keychain-service-claude').write_text(svc+'\n')
(p/'identity').write_text('original-alpha')
data[svc]={'identity':'original-alpha','value':'original-secret-fixture','acl':'original-acl-fixture'}
if sys.argv[5]=='mixed':
 q=root/'alpha'/'claude';q.mkdir(parents=True)
 (q/'.credentials.json').write_text('{"claudeAiOauth":{"accessToken":"original-file-secret-fixture"}}')
 (q/'identity').write_text('original-beta')
 rows.append({'provider':'claude','label':'beta','profile_dir':str(q)})
cfg.write_text(json.dumps({'schema_version':'1.0','accounts':rows}));db.write_text(json.dumps(data,sort_keys=True));services.write_text(svc+'\n')
SEED
  cp "$CONFIG" "$CASE_DIR/original-config"
  cp "$REAUTH_PAYLOAD_DB" "$CASE_DIR/original-payload"
}
original_intact() {
  python3 - "$CASE_DIR" "$CONFIG" "$REAUTH_PAYLOAD_DB" <<'CHECK'
import json,pathlib,sys
case,cfg,db=map(pathlib.Path,sys.argv[1:]);original=json.loads((case/'original-config').read_text())['accounts'];current=json.loads(cfg.read_text())['accounts']
for row in original:
 assert row in current
 p=pathlib.Path(row['profile_dir']);assert p.is_dir()
 assert (p/'identity').read_text()=='original-'+row['label']
 if 'credential_ref' in row:assert (p.parent/'.keychain-service-claude').read_text().strip()==row['credential_ref']['service']
 else:assert 'original-file-secret-fixture' in (p/'.credentials.json').read_text()
old=json.loads((case/'original-payload').read_text());now=json.loads(db.read_text())
assert all(now.get(k)==v for k,v in old.items())
CHECK
  check_eq "$?" 0 'original registry identities, files, services, credential bytes and synthetic ACLs preserved'
}
for layout in noncycle mixed; do
  seed "reauth-$layout" "$layout"
  run doctor --json
  check_eq "$RC" 8 'unsupported layout remains diagnostic'
  check_contains "$OUT" 'fresh-profile reauthentication' 'doctor gives supported fallback pointer'
  run repair-layout claude
  [[ "$RC" -ne 0 ]] && ok 'in-place repair still refuses' || bad 'unsafe repair accepted'
  original_intact
  run add claude recovered --no-login
  check_eq "$RC" 0 'reserve fresh canonical replacement'
  check_eq "$(wc -c < "$STUB_CALL_LOG" | tr -d ' ')" 0 'reservation launches no login'
  original_intact
  run relogin recovered claude
  check_eq "$RC" 0 'auth-only replacement login'
  check_eq "$(cat "$PROFILES/recovered/claude/account-identity")" expected-subscription-fixture 'independent fixture identity matches expected account'
  check_eq "$(cat "$PROFILES/recovered/.keychain-service-claude")" "$(service_of recovered)" 'observed service agrees with sidecar and registry'
  run relogin recovered claude
  check_eq "$RC" 0 'subsequent auth-only relogin succeeds'
  check_eq "$(status_of recovered)" ok 'replacement credential present after second login'
  python3 - "$REAUTH_PAYLOAD_DB" "$(service_of recovered)" <<'IDENTITY'
import json,sys
row=json.load(open(sys.argv[1]))[sys.argv[2]]
assert row['identity']=='expected-subscription-fixture' and row['logins']==2
IDENTITY
  check_eq "$?" 0 'second provider write preserves independently checked identity'
  original_intact
  run add claude recovered --no-login
  check_eq "$RC" 3 'duplicate label refuses before another provider write'
  run remove alpha claude
  check_eq "$RC" 0 'retire only old registry row after identity verification'
  check_eq "$(jq '[.accounts[]|select(.label=="alpha")]|length' "$CONFIG")" 0 'old row retired'
  check_eq "$(status_of recovered)" ok 'verified replacement remains readable'
  [[ -f "$PROFILES/displaced/claude/identity" && -f "$PROFILES/displaced/.keychain-service-claude" ]] && ok 'retirement preserves original directory and sidecar' || bad 'retirement removed recovery originals'
  python3 - "$REAUTH_PAYLOAD_DB" "$CASE_DIR/original-payload" <<'RETIRED'
import json,sys
now,old=(json.load(open(p)) for p in sys.argv[1:])
assert all(now.get(k)==v for k,v in old.items())
RETIRED
  check_eq "$?" 0 'retirement preserves original synthetic credential bytes and ACLs'
done
for failure in reserve-publication abort silent relogin-publication retire-publication; do
  seed "reauth-failure-$failure" mixed
  [[ "$failure" != reserve-publication ]] || export REAUTH_FAIL_CONFIG="$CONFIG"
  run add claude recovered --no-login
  if [[ "$failure" == reserve-publication ]]; then
    check_eq "$RC" 5 'reservation publication failure is visible'
  else
    check_eq "$RC" 0 'staging slot reserved'
    case "$failure" in
      abort|silent) export REAUTH_LOGIN_MODE="$failure" ;;
      relogin-publication) export REAUTH_FAIL_CONFIG="$CONFIG" ;;
    esac
    run relogin recovered claude
    if [[ "$failure" == retire-publication ]]; then
      check_eq "$RC" 0 'replacement verified before retirement failure'
      export REAUTH_FAIL_CONFIG="$CONFIG"
      run remove alpha claude
      check_eq "$RC" 5 'retirement publication failure leaves both rows'
    else
      [[ "$RC" -ne 0 ]] && ok 'failed login/publication is visible; no original retirement' || bad 'failure reported success'
    fi
  fi
  original_intact
  # The documented recovery retains newly written provider data, not a fake
  # rollback promise. A publication failure after login leaves precise evidence.
  if [[ "$failure" == relogin-publication ]]; then
    [[ -f "$PROFILES/recovered/.keychain-service-claude" ]] && ok 'unpublished provider write retains sidecar for manual reconciliation' || bad 'provider recovery evidence absent'
    check_eq "$(service_of recovered)" '' 'failed publication has not invented a registry binding'
  fi
  check_not_contains "$OUT" 'original-secret-fixture' 'no original secret in output'
  check_not_contains "$OUT" 'replacement-secret-fixture' 'no replacement secret in output'
  check_not_contains "$(cat "$CONFIG")" 'secret-fixture' 'registry never contains credential values'
  export REAUTH_FAIL_CONFIG='' REAUTH_LOGIN_MODE=ok
done
check_eq "$(wc -c < "$STUB_SECURITY_VALUE_REQUESTS" | tr -d ' ')" 0 'no security credential-value request'
echo "$PASS passed; $FAILED failed (private synthetic reauthentication only)"
[[ "$FAILED" -eq 0 ]]
'''
result=subprocess.run([sys.argv[2]],input=bootstrap+cases,text=True,cwd=root)
sys.exit(result.returncode)
PY
