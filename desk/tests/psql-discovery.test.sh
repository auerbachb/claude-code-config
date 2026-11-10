#!/usr/bin/env bash
# Exercise the actual discovery/probe against synthetic installed-client layouts.
# Fixed Homebrew roots are remapped in a private copy; no host files are changed.
set -euo pipefail
HQ_DISCOVERY_SOURCE=$(cd "$(dirname "$0")/../.." && pwd)
export HQ_DISCOVERY_SOURCE
python3 - <<'PY'
import os
from pathlib import Path
import shutil
import subprocess
import tempfile

source = Path(os.environ['HQ_DISCOVERY_SOURCE'])
original = Path(os.environ.get('HQ_DISCOVERY_SUT', str(source/'desk/bin/lib/db.sh'))).read_text()
shells = [shutil.which('bash')]
if subprocess.check_output(['/bin/bash', '-c', 'echo ${BASH_VERSINFO[0]}']).strip() == b'3':
    shells.append('/bin/bash')
checks = 0
with tempfile.TemporaryDirectory(prefix='hq-discovery-') as temporary:
    base = Path(temporary)
    for index, shell in enumerate(shells):
        for scenario in ('path-before-linked', 'path-before-libpq', 'explicit-old', 'versioned-keg', 'explicit-current'):
            root = base/str(index)/scenario
            root.mkdir(parents=True)
            home = root/'home'
            home.mkdir()
            homebrew = root/'homebrew'
            pathbin = root/'pathbin'
            linked = homebrew/'bin/psql'
            client = pathbin/'psql'
            clients = [(linked, '14.17'), (client, '15.17')]
            expected = client
            if scenario == 'path-before-libpq':
                clients.append((homebrew/'opt/libpq/bin/psql', '14.17'))
            if scenario == 'versioned-keg':
                expected = homebrew/'opt/postgresql@15/bin/psql'
                clients = [(linked, '14.17'), (client, '14.17'), (expected, '15.17')]
            override = ''
            if scenario == 'explicit-old':
                override = str(linked)
            if scenario == 'explicit-current':
                expected = root/'explicit-psql'
                clients.append((expected, '17.9'))
                override = str(expected)
            for location, version in clients:
                location.parent.mkdir(parents=True, exist_ok=True)
                location.write_text('#!/bin/sh\nif [ "${1-}" = --version ]; then echo "psql (PostgreSQL) '+version+'"; fi\nexit 0\n')
                location.chmod(0o700)
            fixture = root/'db.sh'
            fixture.write_text(original.replace('/opt/homebrew', str(homebrew)).replace('/usr/local', str(root/'usr-local')))
            env = dict(os.environ, HOME=str(home), PATH=str(pathbin)+':'+os.environ['PATH'],
                       HUMAN_QUEUE_DATABASE_URL='postgresql://fixture@no-network.invalid/fixture',
                       HUMAN_QUEUE_PSQL=override, HQ_REAL_COMMON=str(source/'desk/bin/lib/common.sh'),
                       HQ_FIXTURE_DB=str(fixture))
            driver = 'set -euo pipefail\nsource "$HQ_REAL_COMMON"\nsource "$HQ_FIXTURE_DB"\nhq_db_connect\nprintf "%s" "$HQ_PSQL"\n'
            result = subprocess.run([shell, '-c', driver], env=env, capture_output=True, text=True, timeout=4)
            if scenario == 'explicit-old':
                assert result.returncode == 7 and '15 or newer' in result.stderr and not result.stdout, scenario
            else:
                assert result.returncode == 0 and result.stdout == str(expected) and not result.stderr, scenario
            checks += 1
print(f'{checks} actual psql discovery/probe layout checks passed (offline)')
PY
