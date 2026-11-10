#!/usr/bin/env bash
# catalog: tests — Runs actual estimate lock controls under current Bash and macOS Bash 3.2
set -euo pipefail
if [[ "$(uname -s)" != Darwin ]]; then
  echo 'estimate lock Bash matrix: macOS only (Ubuntu Python discovery covers PATH Bash)'
  exit 0
fi
ROOT="$(git rev-parse --show-toplevel)"
python3 - "$ROOT" "$(command -v bash)" <<'PY'
import importlib.util
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import unittest

root, current = Path(sys.argv[1]), sys.argv[2]

def require(condition, message):
    if not condition:
        raise SystemExit(message)

require(sys.version_info >= (3, 9), 'Python >=3.9 required')
require(shutil.which('jq'), 'jq required')
version = subprocess.check_output(['jq', '--version'], text=True).strip()
match = re.match(r'jq-(\d+)\.(\d+)', version)
require(match and tuple(map(int, match.groups())) >= (1, 5), version)
# A native runner can intentionally put Bash 3.2 first on PATH. Locate the
# modern half independently, while preserving both actual-version checks.
explicit = os.environ.get('ESTIMATE_MATRIX_CURRENT_BASH')
candidates = [explicit] if explicit else [current, '/opt/homebrew/bin/bash', '/usr/local/bin/bash']
selected = None
for candidate in candidates:
    if not candidate or not os.access(candidate, os.X_OK):
        continue
    try:
        candidate_version = subprocess.check_output([candidate, '--version'], text=True,
                                                    stderr=subprocess.STDOUT, timeout=5)
    except (OSError, subprocess.SubprocessError):
        continue
    candidate_match = re.search(r'version (\d+)\.(\d+)', candidate_version)
    if candidate_match and int(candidate_match.group(1)) >= 4:
        selected = candidate
        break
require(selected, 'Current Bash >=4 required; set ESTIMATE_MATRIX_CURRENT_BASH to its executable')
current = selected
for shell, minimum, legacy in ((current, 4, False), ('/bin/bash', 3, True)):
    version = subprocess.check_output([shell, '--version'], text=True)
    match = re.search(r'version (\d+)\.(\d+)', version)
    require(match, version)
    major, minor = map(int, match.groups())
    require((major, minor) == (3, 2) if legacy else major >= minimum, version)
    for key in list(os.environ):
        if key.startswith('LOCK_TEST_') or key == 'ESTIMATE_LOCK_TEST_SOURCE':
            os.environ.pop(key)
    os.environ['ESTIMATE_LOCK_TEST_SHELL'] = shell
    spec = importlib.util.spec_from_file_location('estimate_locks_matrix', root / 'tests/test_estimate_log_locks.py')
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    result = unittest.TextTestRunner(verbosity=2).run(unittest.defaultTestLoader.loadTestsFromModule(module))
    require(result.testsRun > 0 and result.wasSuccessful() and not result.skipped,
            f'Lock controls failed or did not run under {shell}')
PY
