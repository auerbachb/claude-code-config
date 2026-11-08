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
assert sys.version_info >= (3, 9), 'Python >=3.9 required'
assert shutil.which('jq'), 'jq required'
version = subprocess.check_output(['jq', '--version'], text=True).strip()
match = re.match(r'jq-(\d+)\.(\d+)', version)
assert match and tuple(map(int, match.groups())) >= (1, 5), version
for shell, minimum, legacy in ((current, 4, False), ('/bin/bash', 3, True)):
    version = subprocess.check_output([shell, '--version'], text=True)
    match = re.search(r'version (\d+)\.(\d+)', version)
    assert match, version
    major, minor = map(int, match.groups())
    assert (major, minor) == (3, 2) if legacy else major >= minimum, version
    for key in list(os.environ):
        if key.startswith('LOCK_TEST_') or key == 'ESTIMATE_LOCK_TEST_SOURCE':
            os.environ.pop(key)
    os.environ['ESTIMATE_LOCK_TEST_SHELL'] = shell
    spec = importlib.util.spec_from_file_location('estimate_locks_matrix', root / 'tests/test_estimate_log_locks.py')
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    result = unittest.TextTestRunner(verbosity=2).run(unittest.defaultTestLoader.loadTestsFromModule(module))
    assert result.testsRun > 0 and result.wasSuccessful() and not result.skipped, shell
PY
