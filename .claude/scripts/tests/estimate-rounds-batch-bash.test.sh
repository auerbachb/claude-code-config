#!/usr/bin/env bash
# catalog: tests — Runs actual estimate rounds batch controls under current Bash and macOS Bash 3.2
set -euo pipefail
if [[ "$(uname -s)" != Darwin ]]; then
  echo 'estimate rounds batch Bash matrix: macOS only (Ubuntu Python discovery covers PATH Bash)'
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
for shell, minimum, legacy in ((current, 4, False), ('/bin/bash', 3, True)):
    version = subprocess.check_output([shell, '--version'], text=True)
    match = re.search(r'version (\d+)\.(\d+)', version)
    require(match, version)
    major, minor = map(int, match.groups())
    require((major, minor) == (3, 2) if legacy else major >= minimum, version)
    for key in list(os.environ):
        if key.startswith('BATCH_TEST_') or key == 'ESTIMATE_BATCH_TEST_SOURCE':
            os.environ.pop(key)
    os.environ['ESTIMATE_BATCH_TEST_SHELL'] = shell
    spec = importlib.util.spec_from_file_location('estimate_rounds_batch_matrix', root / 'tests/test_estimate_rounds_batch.py')
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    result = unittest.TextTestRunner(verbosity=2).run(unittest.defaultTestLoader.loadTestsFromModule(module))
    require(result.testsRun > 0 and result.wasSuccessful() and not result.skipped,
            f'Lock controls failed or did not run under {shell}')
PY
