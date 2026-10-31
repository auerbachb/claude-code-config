#!/usr/bin/env bash
# Verify retained-file compatibility and ephemeral JSON collection of real PR state.
# catalog: tests — Verify pr-state stdout parity and absence of temp bundles on success, failure, and interruption
set -euo pipefail
ROOT="$(git rev-parse --show-toplevel)"
python3 - "$ROOT" <<'PY'
import json,os,pathlib,signal,subprocess,sys,tempfile,time
root=pathlib.Path(sys.argv[1]);script=root/'.claude/scripts/pr-state.sh'
with tempfile.TemporaryDirectory(prefix='pr-state-stdout-') as td:
 t=pathlib.Path(td);b=t/'bin';b.mkdir();h=t/'home';(h/'.claude').mkdir(parents=True)
 stub=b/'gh';stub.write_text('''#!/usr/bin/env python3
import json,os,sys,time
a=sys.argv[1:]
with open(os.environ['CALLS'],'a') as f:f.write(json.dumps(a)+'\\n')
if a[:2]==['pr','view']: print(json.dumps(dict(number=7,headRefName='fixture',headRefOid='abc123',state='OPEN',url='https://github.com/org/repo/pull/7',mergeStateStatus='CLEAN',mergeable='MERGEABLE',reviewDecision='REVIEW_REQUIRED')))
elif a[:2]==['repo','view']: print('org/repo')
elif a[:2]==['api','graphql']:
 if os.environ.get('BLOCK')=='yes':
  open(os.environ['READY'],'w').write('ready');time.sleep(30)
 if os.environ.get('LARGE_THREADS'):nodes=json.load(open(os.environ['LARGE_THREADS']))
 else:nodes=[]
 print(json.dumps({'data':{'repository':{'pullRequest':{'reviewThreads':{'nodes':nodes,'pageInfo':{'hasNextPage':False}}}}}}))
elif a[0]=='api':
 if any('/reviews?' in x for x in a) and os.environ.get('FAIL')=='yes':sys.exit(1)
 if any('/pulls/7/comments?' in x for x in a) and os.environ.get('LARGE_INLINE'):
  print(open(os.environ['LARGE_INLINE']).read())
 elif not any('/check-runs?' in x for x in a):print('[]')
else:sys.exit(2)
''');stub.chmod(0o755)
 date=b/'date';date.write_text('#!/bin/bash\ncase "$*" in *%s*) echo 1793412000;; *) echo 2026-10-31T02:00:00Z;; esac\n');date.chmod(0o755)
 mk=b/'mktemp';mk.write_text('#!/bin/bash\nprintf "%s\\n" "$*" >> "$TEMPS"\nexec /usr/bin/mktemp "$@"\n');mk.chmod(0o755)
 env=dict(os.environ,PATH=str(b)+':'+os.environ['PATH'],HOME=str(h),CALLS=str(t/'calls'),TEMPS=str(t/'temps'),READY=str(t/'ready'))
 def run(*args,**extra):return subprocess.run(['bash',str(script),'--pr','7',*args],env=dict(env,**extra),capture_output=True,text=True)
 r=run();assert r.returncode==0,(r.stdout,r.stderr)
 retained=pathlib.Path(r.stdout.strip());assert retained.is_file() and retained.name.startswith('pr-state-7-')
 expected=json.loads(retained.read_text());retained.unlink();before=(t/'temps').read_bytes()
 r=run('--stdout');assert r.returncode==0 and json.loads(r.stdout)==expected,(r.stdout,r.stderr)
 assert (t/'temps').read_bytes()==before,'stdout allocated a retained bundle'
 r=run('--stdout',FAIL='yes');assert r.returncode!=0 and not r.stdout and (t/'temps').read_bytes()==before,(r.stdout,r.stderr)
 p=subprocess.Popen(['bash',str(script),'--pr','7','--stdout'],env=dict(env,BLOCK='yes'),stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True,start_new_session=True)
 for _ in range(100):
  if (t/'ready').exists():break
  time.sleep(.02)
 assert (t/'ready').exists(),'interruption fixture never reached actual collection'
 os.killpg(p.pid,signal.SIGTERM);out,err=p.communicate(timeout=3)
 assert p.returncode!=0 and not out and (t/'temps').read_bytes()==before
 # Actual source assembly receives a projected history larger than ARG_MAX.
 large=t/'large-inline.json';record={'body':'Minor fix','user':{'login':'coderabbitai[bot]'},'created_at':'2026-10-31T02:00:00Z','updated_at':'2026-10-31T02:00:00Z','path':'/'.join(['fixture']*180),'html_url':'https://github.com/org/repo/pull/7#discussion_r1'}
 large.write_text(json.dumps([dict(record,id=10000+i) for i in range(2000)]))
 assert large.stat().st_size>os.sysconf('SC_ARG_MAX')
 r=run('--stdout',LARGE_INLINE=str(large));assert r.returncode==0 and len(json.loads(r.stdout)['comments']['inline'])==2000 and (t/'temps').read_bytes()==before,(r.stdout[:100],r.stderr)
 print('PASS: actual pr-state streams2000 projected comments larger than ARG_MAX without E2BIG or retained bundle')
 r=run('--stdout','--since','2000-01-01T00:00:00Z',LARGE_INLINE=str(large));assert r.returncode==0 and json.loads(r.stdout)['new_since_baseline']['finding_count']==2000,(r.stdout[:100],r.stderr)
 r=run('--since','2000-01-01T00:00:00Z',LARGE_INLINE=str(large));assert r.returncode==0,(r.stdout,r.stderr)
 retained=pathlib.Path(r.stdout.strip());data=json.loads(retained.read_text());retained.unlink();assert len(data['comments']['inline'])==2000 and data['new_since_baseline']['finding_count']==2000
 print('PASS: large-history --since classification streams through canonical filter in stdout and default retained-file modes')
 threads=t/'large-threads.json';threads.write_text(json.dumps([{'id':'T'+str(i),'isResolved':False,'comments':{'nodes':[{'body':'Minor finding. '*2048,'author':{'login':'coderabbitai[bot]'}}]}} for i in range(100)]))
 assert threads.stat().st_size>os.sysconf('SC_ARG_MAX')
 r=run('--stdout',LARGE_THREADS=str(threads));assert r.returncode==0 and json.loads(r.stdout)['threads']['unresolved_count']==100,(r.stdout[:100],r.stderr)
 print('PASS: oversized GraphQL thread page and final arrays also stream without E2BIG')
 r=subprocess.run(['/bin/bash',str(script),'--pr','7','--stdout','--since','2000-01-01T00:00:00Z'],env=dict(env,LARGE_INLINE=str(large)),capture_output=True,text=True)
 assert r.returncode==0 and json.loads(r.stdout)['new_since_baseline']['finding_count']==2000,(r.stdout[:100],r.stderr)
 print('PASS: system Bash executes large-history stdin/process-substitution classification')



 calls=[json.loads(x) for x in (t/'calls').read_text().splitlines()]
 # One unpaginated fixture success executes 1 thread GraphQL + 5 REST APIs,
 # plus pr/repo-view CLI requests. Pagination and merge-gate add further calls.
 first=calls[:8];assert len(first)==8 and sum(a[:1]==['api'] for a in first)==6,first
 print('PASS: real pr-state default path/stdout JSON parity; stdout success/failure/interruption allocate no bundle; fixture request floor is six API calls plus two views')
PY
