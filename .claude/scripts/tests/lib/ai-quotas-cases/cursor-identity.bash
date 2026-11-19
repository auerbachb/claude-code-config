#!/usr/bin/env bash
# Source-only quota fixture group: cursor-identity. Run ai-quotas.test.sh.
# shellcheck source=../ai-quotas-fixtures.bash
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/ai-quotas-fixtures.bash"

# --- 13f4. protected Cursor identity stages and stdin-only payload (#1870) ---
IDENTITY_PROBE=$(python3 - "${SCRIPT%/*}/lib/ai-quotas-cursor.sh" <<'PY'
from pathlib import Path
import base64,json,os,re,shutil,subprocess,sys,tempfile
source=Path(os.environ.get('CURSOR_IDENTITY_SOURCE',sys.argv[1])).read_text()
def function(name):
    match=re.search(r'^'+name+r'\(\).*?^}',source,re.M|re.S)
    assert match,name
    return match[0]
functions=function('cursor_cached_email')+'\n'+function('cursor_token_for')
def encode(value):return base64.urlsafe_b64encode(value).decode().rstrip('=')
def token(claim):return 'FIXTUREHEADER.'+encode(json.dumps(claim).encode())+'.FIXTURESIGNATURE'
cases=[
 ('encrypted-store','cursor-safe-storage:v1:FIXTURE_CIPHER_SENTINEL','encrypted',None),
 ('encrypted-lookalike','cursor-safe-storage:v1:head.payload.signature','encrypted',None),
 ('opaque-token','FIXTURE_OPAQUE_CREDENTIAL','unsupported structure',None),
 ('payload-bad-length','head.a.sig','base64url',None),
 ('token-unsafe-payload','head.%!.sig','not shaped like a JWT',None),
 ('payload-not-json','head.'+encode(b'not-json')+'.sig','valid JSON',None),
 ('payload-not-object',token([]),'not an object',None),
 ('subject-missing',token({}),'no sub claim',None),
 ('subject-null',token({'sub':None}),'not a string',None),
 ('subject-number',token({'sub':42}),'not a string',None),
 ('subject-array',token({'sub':['fixture']}),'not a string',None),
 ('subject-empty',token({'sub':''}),'is empty',None),
 ('subject-prefix-empty',token({'sub':'auth0|'}),'empty after',None),
 ('subject-quote',token({'sub':'fixture"bad'}),'request header',None),
 ('subject-backslash',token({'sub':'fixture\\bad'}),'request header',None),
 ('subject-newline',token({'sub':'fixture\nbad'}),'request header',None),
 ('subject-trailing-newline',token({'sub':'fixture\n'}),'request header',None),
 ('token-quote',token({'sub':'fixture'})+'"','not shaped like a JWT',None),
 ('token-newline','BAD\n'+token({'sub':'fixture'}),'not shaped like a JWT',None),
 ('auth0',token({'sub':'auth0|fixture-user'}),None,'fixture-user'),
 ('google',token({'sub':'google-oauth2|fixture-user'}),None,'google-oauth2|fixture-user'),
 ('large-stdin-payload',token({'sub':'fixture-user','padding':'A'*150000}),None,'fixture-user'),
 ('decoder-failure',token({'sub':'fixture-user'}),'decoder could not run',None),
 ('sqlite-failure',token({'sub':'fixture-user'}),'sqlite3 could not read',None),
]
checks=[]
with tempfile.TemporaryDirectory(prefix='cursor-identity-fixture-') as temp:
    root=Path(temp).resolve();bin_dir=root/'bin';bin_dir.mkdir();(root/'home').mkdir()
    actual_jq=shutil.which('jq');assert actual_jq
    (bin_dir/'sqlite3').write_text('''#!/usr/bin/env python3
import json,os,sys,pathlib
with open(os.environ['CURI_ARGV_LOG'],'a') as f:f.write(json.dumps(sys.argv[1:])+'\\n')
if os.environ.get('CURI_SQLITE_FAIL')=='1':sys.exit(5)
if 'cachedEmail' in sys.argv[-1]:print('fixture@example.invalid')
else:sys.stdout.write(pathlib.Path(os.environ['CURI_TOKEN_FILE']).read_text()+'\\n')
''')
    (bin_dir/'jq').write_text('''#!/usr/bin/env python3
import json,os,sys
with open(os.environ['CURI_ARGV_LOG'],'a') as f:f.write(json.dumps(sys.argv[1:])+'\\n')
if os.environ.get('CURI_JQ_FAIL')=='1' and any('payload_base64_invalid' in a and '@base64d' in a for a in sys.argv[1:]):sys.exit(2)
os.execv(os.environ['CURI_REAL_JQ'],[os.environ['CURI_REAL_JQ'],*sys.argv[1:]])
''')
    for p in bin_dir.iterdir():p.chmod(0o700)
    harness='set -euo pipefail\nSQLITE3_BIN="$CURI_SQLITE_BIN"\n'+functions+'''
if cursor_token_for "$CURI_DB"; then identity_rc=0; else identity_rc=$?; fi
printf '%s\\0' "$identity_rc" "$CURSOR_TOKEN_STATUS" "$CURSOR_TOKEN_DETAIL" "$CURSOR_USER_ID" "${#CURSOR_TOKEN}"
'''
    shells=['/bin/bash']
    if Path('/opt/homebrew/bin/bash').is_file():shells.append('/opt/homebrew/bin/bash')
    for shell in shells:
        for name,credential,detail,subject in cases:
            token_file=root/'token';token_file.write_text(credential);token_file.chmod(0o600)
            log=root/'argv';log.write_text('');log.chmod(0o600)
            env=dict(os.environ,HOME=str(root/'home'),PATH=str(bin_dir)+os.pathsep+os.environ['PATH'],CURI_SQLITE_BIN=str(bin_dir/'sqlite3'),CURI_DB=str(root/'fake.state'),CURI_REAL_JQ=actual_jq,CURI_TOKEN_FILE=str(token_file),CURI_ARGV_LOG=str(log),CURI_JQ_FAIL='1' if name=='decoder-failure' else '0',CURI_SQLITE_FAIL='1' if name=='sqlite-failure' else '0')
            result=subprocess.run([shell,'-c',harness],env=env,text=True,capture_output=True,timeout=20)
            fields=result.stdout.split('\0');valid=result.returncode==0 and len(fields)==6
            if valid:
                rc,status,message,identity,length,_=fields
                if subject is not None:valid=rc=='0' and identity==subject and int(length)>0
                else:valid=rc=='1' and status==('unreachable' if name=='sqlite-failure' else 'unreadable') and detail in message and identity=='' and length=='0'
            checks.append((Path(shell).parent.parent.name+'-'+name,valid))
            logged=log.read_text();payload=credential.split('.')[1] if credential.count('.')==2 else ''
            private=credential not in logged and not (len(payload)>=12 and payload in logged)
            checks.append((name+'-argv-private',private))
            checks.append((name+'-output-private',credential not in result.stdout+result.stderr))
print(';'.join(name+'='+('ok' if good else 'BAD') for name,good in checks))
PY
)
case "$IDENTITY_PROBE" in
  *BAD*|"") bad "Cursor identity stage/argv probe: $IDENTITY_PROBE" ;;
  *) ok "Cursor identity stages, header guards and stdin-only payload ($IDENTITY_PROBE)" ;;
esac

reset_state
seed_cursor_account
CURSOR_DB_UNDER_TEST="$TMP/cursor-encrypted-state.vscdb"
build_cursor_db "$CURSOR_DB_UNDER_TEST" 'cursor-safe-storage:v1:FIXTURE_CIPHER_SENTINEL'
run --json
check_eq "$(rows_for cursor-one@example.com)" unreadable 'encrypted IDE storage is unreadable, never guessed logged-out'
check_contains "$(field_of cursor-one@example.com billing-cycle detail)" '--browser' 'encrypted-store diagnostic names the supported interactive fallback'
check_eq "$(field_of cursor-one@example.com billing-cycle used_pct)" null 'encrypted store never invents zero usage'
check_eq "$(field_of cursor-one@example.com billing-cycle action)" null 'encrypted store does not demand an IDE login'
check_eq "$(grep -c 'cursor.com' "$STUB_CURL_LOG" | tr -d ' ')" 0 'ciphertext makes no dashboard API request'
check_not_contains "$OUT$ERR" FIXTURE_CIPHER_SENTINEL 'ciphertext never reaches displayed diagnostics'

reset_state
seed_cursor_account
BROWSER_LOGGED_OUT_FIXTURE="$TMP/cursor-browser-logged-out.json"
printf '{"schema_version":1,"provider":"cursor","label":"cursor-one@example.com","email":"","status":"logged_out","observed_at_epoch":%s,"rows":[]}\n' "$NOW" > "$BROWSER_LOGGED_OUT_FIXTURE"
chmod 600 "$BROWSER_LOGGED_OUT_FIXTURE"
run --json --account cursor-one@example.com --browser-results "$BROWSER_LOGGED_OUT_FIXTURE"
check_eq "$(field_of cursor-one@example.com billing-cycle status)" needs-login 'explicit browser logged-out observation retains its status'
check_eq "$(field_of cursor-one@example.com billing-cycle action)" 'open the Cursor dashboard in Chrome and sign in' 'browser recovery names Chrome rather than the IDE'

# --- 13g. a changed payload shape is unreadable, never 0 % -------------------

reset_state
seed_cursor_account
echo "shape" > "$STUB_CURSOR_MODE"
run --json
check_eq "$(rows_for cursor-one@example.com)" "unreadable" \
  "HTTP 200 carrying no pool percentages reads unreadable"
check_eq "$(field_of cursor-one@example.com "billing-cycle" used_pct)" "null" \
  "and reports no figure rather than 0 %"
check_contains "$(field_of cursor-one@example.com "billing-cycle" detail)" "somethingElse" \
  "the note names the keys it actually saw"

# --- 13h. an enrichment failure costs a label, not the row -------------------
#
# Only get-current-period-usage decides the row. A row that went unreachable
# because a plan-NAME lookup 500'd would report a blackout it does not have.

reset_state
seed_cursor_account
echo "plan500" > "$STUB_CURSOR_MODE"
run --json
check_eq "$(cursor_field cursor-one@example.com cursor-models status)" "ok" \
  "a 500 from get-plan-info still renders the row"
check_eq "$(cursor_field cursor-one@example.com cursor-models used_pct)" "53" \
  "with its figures intact"
check_eq "$(cursor_field cursor-one@example.com cursor-models plan)" "null" \
  "and only the plan name missing"

# --- 13h2. a hostile sub claim never reaches the curl config -----------------
#
# The cookie is handed to curl through a line-oriented, quoted config on stdin.
# A `sub` carrying a newline does not merely corrupt the header — it ends the
# line, and what follows is read by curl as further OPTIONS. The state store is
# a local file this script does not own, so its shape is checked, not assumed
# (CodeRabbit).

reset_state
seed_cursor_account
CURSOR_DB_HOSTILE="$TMP/cursor-hostile.vscdb"
# `"` closes the quoted value and the newline starts a fresh config directive —
# the exact two characters the guard exists for.
HOSTILE_SUB='evil"
output = /dev/null'
build_cursor_db "$CURSOR_DB_HOSTILE" \
  "$(b64url '{"alg":"HS256","typ":"JWT"}').$(b64url "$(jq -nc --arg s "$HOSTILE_SUB" '{sub: $s}')").SIG" \
  || bad "could not build the hostile cursor fixture"
CURSOR_DB_UNDER_TEST="$CURSOR_DB_HOSTILE"
run --json
CURSOR_DB_UNDER_TEST=""
check_eq "$(rows_for cursor-one@example.com)" "unreadable" \
  "a sub claim carrying a quote and a newline is refused, not sent"
check_contains "$(field_of cursor-one@example.com "billing-cycle" detail)" "will not put in a request header" \
  "and the note says why"
check_eq "$(grep -c 'cursor.com' "$STUB_CURL_LOG" | tr -d ' ')" "0" \
  "control(-): no request was made at all"

# --- 13h3. a cached email carrying control characters is dropped -------------
#
# `reported_email` goes straight into a terminal table, where a tab splits the
# columns, a newline forges a row, and an escape sequence is executed by the
# terminal rather than shown. It comes from the same local file the token does,
# so it gets the invariant ROW_NICKNAME already documents (CodeRabbit).

reset_state
seed_cursor_account
CURSOR_DB_CTRL="$TMP/cursor-ctrl-email.vscdb"
rm -f "$CURSOR_DB_CTRL"
"$SQLITE3_REAL" "$CURSOR_DB_CTRL" "PRAGMA journal_mode=WAL;" >/dev/null
"$SQLITE3_REAL" "$CURSOR_DB_CTRL" "create table ItemTable (key TEXT PRIMARY KEY, value BLOB);"
"$SQLITE3_REAL" "$CURSOR_DB_CTRL" \
  "insert into ItemTable (key, value) values ('cursorAuth/accessToken', '${CURSOR_FIXTURE_TOKEN}');"
# A tab and a newline, inserted as real control characters via SQLite's own
# char() so the fixture cannot be softened by shell quoting on the way in.
"$SQLITE3_REAL" "$CURSOR_DB_CTRL" \
  "insert into ItemTable (key, value) values ('cursorAuth/cachedEmail', 'ev' || char(9) || 'il' || char(10) || '@example.com');"
CURSOR_DB_UNDER_TEST="$CURSOR_DB_CTRL"
run --json
CURSOR_DB_UNDER_TEST=""
check_eq "$(cursor_field cursor-one@example.com cursor-models status)" "ok" \
  "a control-character email does not take the row down"
check_eq "$(cursor_field cursor-one@example.com cursor-models reported_email)" "cursor-one@example.com" \
  "and the row falls back to the label instead of rendering it"

# --- 13i. a broken cursor account degrades alone -----------------------------
#
# The property this file is about: per-row isolation.

reset_state
X1="$(seed_codex_profile codex-one@example.com "$(codex_snapshot_primary_weekly)")"
write_config \
  "$(account_json cursor cursor-one@example.com "$CUR")" \
  "$(account_json codex codex-one@example.com "$X1")"
echo "down" > "$STUB_CURSOR_MODE"
run --json
check_eq "$RC" "0" "a cursor row does not fail the run"
check_eq "$(rows_for cursor-one@example.com)" "unreachable" \
  "a curl failure reads unreachable"
# The email was read from the LOCAL store before any request went out, so a
# network failure has not invalidated it (CodeAnt). Discriminating on purpose:
# the fixture email differs from the label, and an emit_row that passed "" here
# would fall back to the label and this assertion would read it.
check_eq "$(field_of cursor-one@example.com "billing-cycle" reported_email)" "$CURSOR_FIXTURE_EMAIL" \
  "and the unreachable row still names the account from the local store"
check_eq "$(rows_for codex-one@example.com)" "ok" "the codex row beside it still renders"

# An unknown provider is what `unsupported` is for now that cursor is read.
reset_state
write_config "$(account_json weirdprovider someone@example.com "$PROFILES/x")"
run --json
check_eq "$RC" "0" "an unknown provider does not fail the run"
check_eq "$(rows_for someone@example.com)" "unsupported" "and reads unsupported"

