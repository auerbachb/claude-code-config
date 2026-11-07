#!/usr/bin/env bash
# catalog: tests — Discriminating GNU/uutils/BSD/unavailable quota date operations, bounded hangs, partial output and epoch-file decoys
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
python3 - "$ROOT" <<'PY'
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time

root = Path(sys.argv[1])
helper = root / '.claude/scripts/lib/quota-date.py'
checks = 0

def verify(value, message):
    global checks
    assert value, message
    checks += 1

with tempfile.TemporaryDirectory(prefix='quota-date-fixture-') as directory:
    tmp = Path(directory)
    bin_dir = tmp / 'bin'
    bin_dir.mkdir()
    trace = tmp / 'trace.jsonl'
    (bin_dir / 'date').write_text(r'''#!/usr/bin/env python3
from datetime import datetime, timedelta, timezone
import json,os,re,sys,time
from pathlib import Path
from zoneinfo import ZoneInfo
a=sys.argv[1:]; kind=os.environ['QUOTA_DATE_FIXTURE_KIND']
with open(os.environ['QUOTA_DATE_FIXTURE_TRACE'],'a') as stream:
    stream.write(json.dumps({'args':a,'cwd':str(Path.cwd()),'files':sorted(p.name for p in Path.cwd().iterdir())})+'\n')
if '--version' in a:
    print({'gnu':'date (GNU coreutils) fixture','uutils':'date (uutils coreutils) fixture','bsd':'date: illegal option -- -'}.get(kind,'unsupported'));sys.exit(0)
if kind=='hang':time.sleep(10)
if kind=='unsupported':print('946782245');sys.exit(1)
if kind=='empty':sys.exit(0)
if kind=='partial':print('946782245\npartial');sys.exit(0)
zone=ZoneInfo(os.environ.get('TZ','UTC'))
if a and a[0]=='-u':a=a[1:];zone=timezone.utc
try:
    if a[0]=='-d':
        if kind not in ('gnu','uutils'):sys.exit(1)
        value,fmt=a[1:]
        if value.startswith('@'):dt=datetime.fromtimestamp(int(value[1:]),zone)
        elif 'T' in value:dt=datetime.fromisoformat(value.replace('Z','+00:00')).astimezone(zone)
        else:dt=datetime.strptime(value,'%Y-%m-%d %H:%M:%S').replace(tzinfo=zone)
    elif a[0]=='-j':
        if kind!='bsd' or a[1]!='-f':sys.exit(1)
        shape,value,fmt=a[2:]
        if shape=='%Y-%m-%d %H:%M:%S':
            y,m,d=map(int,value[:10].split('-'))
            dt=datetime(y,m,1,12,tzinfo=zone)+timedelta(days=d-1)
        else:
            dt=datetime.strptime(value,shape)
            if dt.tzinfo is None:dt=dt.replace(tzinfo=zone)
            dt=dt.astimezone(zone)
    elif a[0]=='-r':
        value,fmt=a[1:]
        if kind=='bsd':dt=datetime.fromtimestamp(int(value),zone)
        else:dt=datetime.fromtimestamp(Path(value).stat().st_mtime,zone)
    else:
        fmt=a[0];dt=datetime(2026,9,8,20,tzinfo=timezone.utc).astimezone(zone)
    failure=os.environ.get('QUOTA_DATE_FIXTURE_FAIL')
    if failure=='weekday' and fmt=='+%a':print('Tue');sys.exit(1)
    if failure=='month' and fmt=='+%Y-%m':print('2026-09');sys.exit(1)
    if failure=='iso' and fmt=='+%s' and '2026' in value:print('1788897600');sys.exit(1)
    print(str(int(dt.timestamp())) if fmt=='+%s' else dt.strftime(fmt[1:]))
except (ValueError,IndexError,OSError):sys.exit(1)
''', encoding='utf-8')
    (bin_dir / 'date').chmod(0o755)
    env = dict(os.environ, PATH=str(bin_dir)+os.pathsep+os.environ['PATH'],
               QUOTA_DATE_FIXTURE_TRACE=str(trace), HOME=str(tmp/'home'))
    (tmp/'home').mkdir()
    # Both a likely probe epoch and a report epoch exist with unrelated mtimes.
    for epoch in ('946782245', '1788897600'):
        decoy = tmp / epoch
        decoy.write_text('fixture decoy')
        os.utime(decoy, (1000000000, 1000000000))

    def run(kind, *args, failure=None):
        return subprocess.run([sys.executable,str(helper),*args],cwd=tmp,
            env=dict(env,QUOTA_DATE_FIXTURE_KIND=kind,QUOTA_DATE_FIXTURE_FAIL=failure or ''),
            text=True,capture_output=True,timeout=15)

    for kind in ('gnu','uutils','bsd'):
        dialect='bsd' if kind=='bsd' else 'gnu'
        trace.write_text('')
        result=run(kind,'detect')
        verify(result.returncode==0 and result.stdout.strip()==dialect, kind+' capability classification')
        traces=[json.loads(line) for line in trace.read_text().splitlines()]
        verify(not any('--version' in t['args'] for t in traces), kind+' never depends on banner')
        if kind=='bsd':
            r_index=next(i for i,t in enumerate(traces) if '-r' in t['args'])
            verify(any('-j' in t['args'] for t in traces[:r_index]), 'BSD -j verified before -r')
            verify(traces[r_index]['files']==[], 'BSD -r capability probe runs in empty cwd')
        else:
            verify(not any('-r' in t['args'] for t in traces),kind+' never reads epoch-named files')
        for iso in ('2026-09-08T20:00:00Z','2026-09-09T01:30:00.999+05:30','2026-09-08T16:00:00-04:00'):
            result=run(kind,'iso',dialect,iso)
            verify(result.returncode==0 and result.stdout.strip()=='1788897600',kind+' ISO offset/fractions '+iso)
        for fmt,wanted in [('+%a','Tue'),('+%Y-%m','2026-09'),('+%Y-%m-%d','2026-09-08'),
                           ('+%a %b %-d %-I:%M %p %Z','Tue Sep 8 4:00 PM EDT'),
                           ('+%a %-I:%M %p','Tue 4:00 PM'),('+%b %-d %-I:%M %p ET','Sep 8 4:00 PM ET')]:
            result=run(kind,'format',dialect,'1788897600',fmt,'America/New_York')
            verify(result.returncode==0 and result.stdout.strip()==wanted,kind+' ET format '+fmt)
        result=run(kind,'format',dialect,'1788897600','+%Y-%m-%dT%H:%M:%SZ','UTC')
        verify(result.returncode==0 and result.stdout.strip()=='2026-09-08T20:00:00Z',kind+' UTC snapshot')
        # Fixed expected weekdays around both DST transitions, including UTC Monday -> ET Sunday.
        for iso,wanted in [('2026-03-08T06:59:00Z','Sun'),('2026-03-08T07:01:00Z','Sun'),
                           ('2026-11-01T05:59:00Z','Sun'),('2026-11-01T06:01:00Z','Sun'),
                           ('2026-11-02T00:30:00Z','Sun')]:
            epoch=str(int(datetime.fromisoformat(iso.replace('Z','+00:00')).timestamp()))
            result=run(kind,'format',dialect,epoch,'+%a','America/New_York')
            verify(result.returncode==0 and result.stdout.strip()==wanted,kind+' DST/weekday '+iso)
        for day,valid in [('2024-02-29',True),('2026-02-29',False),('2026-02-31',False),('2026-99-99',False)]:
            result=run(kind,'calendar',dialect,day)
            verify(result.returncode==(0 if valid else 3) and result.stdout.strip()==(day if valid else ''),kind+' actual calendar '+day)
        for operation,args in [('iso',('2026-09-08T20:00:00Z',)),('format',('1788897600','+%a','America/New_York'))]:
            result=run(kind,operation,dialect,*args,failure='iso' if operation=='iso' else 'weekday')
            verify(result.returncode!=0 and result.stdout=='',kind+' rejects partial failed '+operation)

    for kind in ('unsupported','empty','partial','hang'):
        trace.write_text('');started=time.monotonic()
        result=run(kind,'detect')
        verify(result.returncode==0 and result.stdout.strip()=='unavailable',kind+' remains unavailable')
        verify(time.monotonic()-started<7,kind+' detection is bounded')
        traces=[json.loads(line) for line in trace.read_text().splitlines()]
        verify(not any('-r' in t['args'] for t in traces),kind+' cannot select BSD -r')
    result=run('gnu','format','unavailable','1788897600','+%a','America/New_York')
    verify(result.returncode==4 and result.stdout=='','unavailable operation is explicit, never fabricated')
    # Load the shipped shell adapter, so the shell/Python interface is exercised too.
    result=subprocess.run(['bash','-c','source "$1"; d=$(quota_date_detect); quota_date_iso "$d" 2026-09-08T20:00:00Z','fixture',str(root/'.claude/scripts/lib/quota-date.sh')],cwd=tmp,env=dict(env,QUOTA_DATE_FIXTURE_KIND='uutils'),text=True,capture_output=True)
    verify(result.returncode==0 and result.stdout.strip()=='1788897600','actual sourced adapter handles uutils')
    # Exercise the real money-affecting watermark consumer with synthetic state.
    state = tmp/'quota-state'
    state.mkdir()
    watermark = state/'codex-reset.json'
    original = json.dumps({'month':'2026-09','used_on':'2026-09-08'})
    watermark.write_text(original)
    consumer = root/'.claude/scripts/quotas-cheapest-next.sh'
    consumer_env = dict(env, AI_QUOTAS_NOW='1788897600', CLAUDE_QUOTAS_STATE_DIR=str(state))
    result = subprocess.run(['bash',str(consumer),'--codex-reset-status'],cwd=tmp,
        env=dict(consumer_env,QUOTA_DATE_FIXTURE_KIND='uutils'),text=True,capture_output=True)
    doc = json.loads(result.stdout)
    verify(result.returncode==0 and doc['month']=='2026-09' and not doc['free_reset_available'], 'real consumer honors supported uutils watermark')
    for kind,failure in [('unsupported',''),('uutils','month')]:
        result = subprocess.run(['bash',str(consumer),'--codex-reset-status'],cwd=tmp,
            env=dict(consumer_env,QUOTA_DATE_FIXTURE_KIND=kind,QUOTA_DATE_FIXTURE_FAIL=failure),text=True,capture_output=True)
        doc = json.loads(result.stdout)
        verify(result.returncode==0 and doc['month']=='' and doc['free_reset_available'] and doc['figure_source']=='assumed', kind+' failed frozen month stays unknown and assumed-free')
        verify('month unavailable' in result.stderr,kind+' month failure is visible')
    result = subprocess.run(['bash',str(consumer),'--record-codex-reset','2026-09-08'],cwd=tmp,
        env=dict(consumer_env,QUOTA_DATE_FIXTURE_KIND='unsupported'),text=True,capture_output=True)
    verify(result.returncode==5 and 'validation unavailable' in result.stderr,'real record mode refuses unsupported calendar')
    verify(watermark.read_text()==original,'unsupported record mode preserves existing synthetic watermark')
    # Preserve the reader's stricter nonnegative-credit-deadline input guard.
    source = (root/'.claude/scripts/ai-quotas.sh').read_text()
    body = source.split('epoch_to_et_datetime_short() {',1)[1].split('\n}',1)[0]
    function = 'epoch_to_et_datetime_short() {'+body+'\n}\n'
    for epoch,wanted in [('-1',''),('1788897600','formatted')]:
        result = subprocess.run(['bash','-c','QUOTA_DATE_DIALECT=gnu; quota_date_format() { printf formatted; }; '+function+'epoch_to_et_datetime_short "$1"','fixture',epoch],text=True,capture_output=True)
        verify(result.returncode==0 and result.stdout==wanted,'actual credit-deadline guard '+epoch)
print(str(checks)+' quota date capability checks passed; synthetic dates/processes only.')
PY
