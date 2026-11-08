#!/usr/bin/env bash
# catalog: tests — Exercise CommonMark AC extraction, exact REST mutation and gate parity with offline fixtures
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
python3 - "$ROOT" <<'PY'
import json,os,shutil,subprocess,sys,tempfile
from pathlib import Path
root=Path(sys.argv[1]);checks=0
extractor=Path(os.environ.get('AC_CHECKBOXES_SUT',str(root/'.claude/scripts/ac-checkboxes.sh')))
gate=Path(os.environ.get('AC_GATE_SUT',str(root/'.claude/scripts/ac-gate.sh')))

def verify(ok,message):
    global checks
    checks+=1
    assert ok,message

with tempfile.TemporaryDirectory(prefix='ac-checkboxes-fixture-') as directory:
    tmp=Path(directory);(tmp/'home/.claude').mkdir(parents=True);(tmp/'bin').mkdir()
    body=tmp/'body';capture=tmp/'patched';calls=tmp/'calls'
    stub=tmp/'bin/gh'
    stub.write_text(r'''#!/usr/bin/env python3
import json,os,sys
from pathlib import Path
a=sys.argv[1:]
with open(os.environ['AC_FIXTURE_CALLS'],'a') as f:f.write(json.dumps(a)+'\n')
if a[:2]==['pr','view']:
 text=Path(os.environ['AC_FIXTURE_BODY']).read_bytes().decode()
 print(text if '--jq' in a else json.dumps({'body':text}))
elif a[:2]==['repo','view']:print('fixture/repo')
elif a[:2]==['issue','view']:print('CLOSED' if a[2]=='778' else 'OPEN')
elif a and a[0]=='api' and 'PATCH' in a:
 source=next(x[len('body=@'):] for x in a if x.startswith('body=@'))
 Path(os.environ['AC_FIXTURE_CAPTURE']).write_bytes(Path(source).read_bytes())
 print('{}')
else:sys.exit(90)
''');stub.chmod(0o755)
    env=dict(os.environ,HOME=str(tmp/'home'),PATH=str(tmp/'bin')+os.pathsep+os.environ['PATH'],
             AC_FIXTURE_BODY=str(body),AC_FIXTURE_CAPTURE=str(capture),AC_FIXTURE_CALLS=str(calls))
    def run(script,*args):
        return subprocess.run(['bash',str(script),'7',*args],env=env,capture_output=True,text=True,timeout=10)
    def patches():
        return sum(json.loads(line)[0]=='api' for line in calls.read_text().splitlines()) if calls.exists() else 0
    for index,marker in enumerate(('-', '1.', '1)', '*', '+')):
        newline='\r\n' if index==2 else '\n'
        text=newline.join(['## Summary','- [ ] outside','## Test Plan',
                          '  '+marker+'  [ ] alpha  ',marker+' [X] beta',marker+'\t[ ] gamma',
                          '## Other','- [ ] leave alone']) + ('' if index==4 else newline*2)
        body.write_bytes(text.encode())
        result=run(extractor,'--extract')
        verify(result.returncode==0,marker+' extraction: '+result.stderr)
        items=json.loads(result.stdout)
        verify(items==[dict(index=0,checked=False,text='alpha'),dict(index=1,checked=True,text='beta'),dict(index=2,checked=False,text='gamma')],marker+' indexes/text/checked state')
        result=run(gate)
        verify(result.returncode==1,marker+' unchecked gate must fail: '+result.stdout+result.stderr)
        result=run(extractor,'--tick','0')
        verify(result.returncode==0,marker+' indexed tick: '+result.stderr)
        expected=text.replace(marker+'  [ ] alpha',marker+'  [x] alpha')
        verify(capture.read_bytes()==expected.encode(),marker+' indexed tick changes only intended marker, preserving CRLF/EOF/outside content')
        body.write_bytes(capture.read_bytes());result=run(extractor,'--tick','gamma')
        verify(result.returncode==0,marker+' regex tick: '+result.stderr)
        expected=expected.replace(marker+'\t[ ] gamma',marker+'\t[x] gamma')
        verify(capture.read_bytes()==expected.encode(),marker+' regex tick preserves marker, indentation, uppercase X and trailing whitespace')
        body.write_bytes(capture.read_bytes());result=run(gate)
        verify(result.returncode==0,marker+' checked gate must pass: '+result.stderr)
        before=patches();result=run(extractor,'--all-pass')
        verify(result.returncode==0 and patches()==before,marker+' all-pass is idempotent without PATCH')
    text='## Test Plan\n'+''.join(m+' [ ] item\n' for m in ('-','*','+','2.','9)'))+'\n## Other\n- [ ] retain\n'
    body.write_text(text);result=run(extractor,'--all-pass')
    verify(result.returncode==0,'all-pass accepts a mixed-marker list')
    expected=text.split('## Other')[0].replace('[ ]','[x]')+'## Other'+text.split('## Other')[1]
    verify(capture.read_bytes()==expected.encode(),'mixed all-pass preserves non-Test-Plan content')
    for text,extract_rc,gate_rc in [('',1,0),('## Summary\nNo criteria.\n',1,0),
                                   ('## Test Plan\nProse only.\n',1,1),('## Test Plan\n## Other\n',1,1),
                                   ('## Test Plan\n-[ ] missing separator\n',1,1),
                                   ('## Test Plan\n1234567890. [ ] overlong marker\n',1,1),
                                   ('## Test Plan\n1: [ ] invalid marker\n',1,1),
                                   ('## Test Plan\nProse.\n## Test Plan\n- [x] second\n',1,1),
                                   ('## Test Plan\n- [x] first\n## Acceptance Criteria\nProse.\n',0,1)]:
        body.write_text(text);result=run(extractor,'--extract');verify(result.returncode==extract_rc,'extractor section/invalid-marker contract: '+repr(text))
        result=run(gate);verify(result.returncode==gate_rc,'gate section/invalid-marker contract: '+repr(text)+result.stderr)
    for ending in ('', '\n', '\n\n', '\r\n\r\n'):
        separator='\r\n' if '\r' in ending else '\n'
        body.write_bytes(('## TEST PLAN'+separator+'123456789) [ ] maximal marker'+ending).encode())
        result=run(extractor,'--all-pass');verify(result.returncode==0,'maximal ordered marker / newline profile accepted')
        verify(capture.read_bytes()==('## TEST PLAN'+separator+'123456789) [x] maximal marker'+ending).encode(),'all-pass exact trailing-newline profile')
    post='Closes #88\n\n## Acceptance Criteria\n- [x] implemented\n\n## Post-merge verification\n'+''.join(m+' [ ] later\n' for m in ('-','*','+','1.','1)'))
    for tracking,expected in [('',5),('Tracking issue: #777\n',0),('Tracking issue: #88\n',6),('Tracking issue: #778\n',7)]:
        body.write_text(post+tracking);result=run(gate);verify(result.returncode==expected,'mixed-marker exemption validates tracking: '+tracking+result.stderr)
    body.write_text(post.replace('## Post-merge verification','## post-merge verification')+'Tracking issue: #777\n')
    verify(run(gate).returncode==1,'wrong-case exemption cannot hide new markers')
    body.write_text('## Test Plan\n- [x] current\n## Test Plan\nProse.\n## Post-merge verification\n- [ ] later\n')
    verify(run(gate).returncode==1,'empty in-scope section blocks before missing-tracking exemption')
    body.write_text('## Test Plan\n- [ ] alpha\n');before=patches()
    verify(run(extractor,'--tick','[').returncode==2 and patches()==before,'invalid regex refuses without PATCH')
    for script,expected in ((extractor,2),(gate,4)):
        isolated=tmp/('isolated-'+script.stem);isolated.mkdir();copied=isolated/script.name;shutil.copyfile(script,copied)
        result=run(copied,'--extract') if script==extractor else run(copied)
        verify(result.returncode==expected and 'marker library' in result.stderr,'missing shared library fails loudly')
        (isolated/'lib').mkdir();(isolated/'lib/ac-checkbox-markers.sh').write_text('')
        env['AC_LIST_MARKER_RE']='.*'
        result=run(copied,'--extract') if script==extractor else run(copied)
        verify(result.returncode==expected,'empty shared library cannot inherit an environment pattern')
        env.pop('AC_LIST_MARKER_RE')
    print(str(checks)+' actual AC extractor/mutation/gate checks passed (offline)')
PY
