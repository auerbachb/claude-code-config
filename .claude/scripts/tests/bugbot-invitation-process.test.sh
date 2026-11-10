#!/usr/bin/env bash
# catalog: tests — Verify real BugBot invitation process cleanup and direct-child-only negative controls
# Ubuntu also discovers this Python module; this bridge includes it in the
# macOS Bash-suite discovery. Missing Python is a failure, never a skipped check.
set -euo pipefail
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$TEST_DIR/../../.."
python3 -m unittest discover -s tests -p test_bugbot_invitation.py -v
