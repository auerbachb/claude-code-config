#!/usr/bin/env bash
# Actual Bash-to-child transport controls. No database or provider is contacted.
set -euo pipefail
HQ_BINDING_SOURCE=$(cd "$(dirname "$0")/../.." && pwd)
export HQ_BINDING_SOURCE
python3 - <<'PY'
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import time

source = Path(os.environ['HQ_BINDING_SOURCE'])
shells = [shutil.which('bash')]
if subprocess.check_output(['/bin/bash', '-c', 'echo ${BASH_VERSINFO[0]}']).strip() == b'3':
    shells.append('/bin/bash')
checks = 0
with tempfile.TemporaryDirectory(prefix='hq-bindings-') as temporary:
    root = Path(temporary)
    stub = root / 'psql'
    stub.write_text('''#!/usr/bin/env python3
import json, os, sys, time
from pathlib import Path
args=sys.argv[1:]
marker=next(a.split('=',1)[1] for a in args if a.startswith('hq_marker='))
Path(marker).write_text('connected')
Path(os.environ['HQ_CAPTURE']).write_text(json.dumps(dict(
    pid=os.getpid(), args=args,
    values={k:v for k,v in os.environ.items() if k.startswith('HQ_PSQL_TEXT_')},
    raw_url='HUMAN_QUEUE_DATABASE_URL' in os.environ)))
while not Path(os.environ['HQ_RELEASE']).exists(): time.sleep(.01)
''')
    stub.chmod(0o700)
    driver = root / 'driver'
    driver.write_text('''set -euo pipefail
source "$HQ_BINDING_SOURCE/desk/bin/lib/common.sh"
source "$HQ_BINDING_SOURCE/desk/bin/lib/db.sh"
HQ_PSQL="$HQ_STUB"
hq_mktemp HQ_CONN_MARKER
hq_psql "$@" </dev/null
if env | grep '^HQ_PSQL_TEXT_' >/dev/null; then exit 99; fi
''')
    value = "HQ-PRIVATE-fixture 'quoted' \\\\ $() `backticks`\tλ\nline two\n"
    bindings = [value, '', 'first', 'last', 'x' * 65536]
    arguments = ['-At', '-v', 'hq_answer=' + bindings[0], '--set=hq_empty=',
                 '--variable', 'hq_repeat=first', '-vhq_repeat=last',
                 '--variable=hq_large=' + bindings[4], '-v', 'fixed=allowed',
                 '-c', "SELECT :'hq_answer';"]
    for index, shell in enumerate(shells):
        capture, release = root / f'capture{index}', root / f'release{index}'
        env = dict(os.environ, HQ_STUB=str(stub), HQ_CAPTURE=str(capture),
                   HQ_RELEASE=str(release), HUMAN_QUEUE_DATABASE_URL='postgresql://fixture.invalid/no-connection')
        # Test the parent's export boundary without ambient names contaminating it.
        env = {k:v for k,v in env.items() if not k.startswith('HQ_PSQL_TEXT_')}
        proc = subprocess.Popen([shell, str(driver), *arguments], env=env,
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        try:
            deadline = time.monotonic() + 5
            while not capture.exists() and proc.poll() is None and time.monotonic() < deadline:
                time.sleep(.01)
            assert capture.exists(), 'owned transport fixture did not start'
            record = json.loads(capture.read_text())
            command = subprocess.check_output(['ps', '-ww', '-p', str(record['pid']), '-o', 'args='], text=True)
            assert 'psql' in command and value not in command and 'x' * 200 not in command
            assert [record['values'][f'HQ_PSQL_TEXT_{i}'] for i in range(len(bindings))] == bindings
            assert not record['raw_url']
            args = record['args']
            assert 'fixed=allowed' in args and "SELECT :'hq_answer';" in args
            assert not any(a.startswith(('hq_answer=', 'hq_empty=', 'hq_repeat=', 'hq_large=')) for a in args)
            assert '\\getenv hq_answer HQ_PSQL_TEXT_0' in args
            assert '\\getenv hq_repeat HQ_PSQL_TEXT_2' in args
            assert '\\getenv hq_repeat HQ_PSQL_TEXT_3' in args
            checks += 8
        finally:
            release.touch()
            try:
                out, err = proc.communicate(timeout=5)
            except subprocess.TimeoutExpired:
                proc.kill()
                proc.communicate()
                raise
        assert proc.returncode == 0 and not out and not err, 'transport failed or exported values escaped parent scope'
        checks += 1
        for invalid in ('hq_marker=private', 'hq_bad-name=private', 'hq_bad;name=private'):
            result = subprocess.run([shell, str(driver), '-v', invalid], env=env, capture_output=True)
            assert result.returncode == 1 and b'private' not in result.stderr
            checks += 1
print(f'{checks} actual psql transport checks passed (offline; known fixture PIDs only)')
PY
