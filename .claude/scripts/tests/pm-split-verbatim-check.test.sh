#!/usr/bin/env bash
# catalog: tests — Exercises PM split parity, resolved links, routing markers, and unverifiable history.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
python3 - "$root" <<'PY'
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

SCRIPT = Path(sys.argv[1]) / ".claude/scripts/pm-split-verbatim-check.py"
ENTRY = Path(".claude/skills/pm/SKILL.md")
MODULE = ENTRY.parent / "modules/day-tick.md"
OLD = "entry\nrepeat\nrepeat\n[shared](../../reference/example.md)\n"
NEW_ENTRY = "entry\n<!-- pm-routing:begin -->\nRead one module.\n<!-- pm-routing:end -->\n"
NEW_MODULE = "repeat\nrepeat\n[shared](../../../reference/example.md)\n"


class Parity(unittest.TestCase):
    def setUp(self):
        folder = tempfile.TemporaryDirectory(prefix="pm-split-parity-")
        self.addCleanup(folder.cleanup)
        self.root = Path(folder.name)
        self.git("init", "-q", "-b", "main")
        self.write(ENTRY, OLD)
        self.git("add", str(ENTRY))
        self.git("-c", "user.name=fixture", "-c", "user.email=fixture@example.invalid",
                 "-c", "core.hooksPath=/dev/null", "commit", "-qm", "baseline")
        self.baseline = self.git("rev-parse", "HEAD").strip()
        self.write(ENTRY, NEW_ENTRY)
        self.write(MODULE, NEW_MODULE)

    def git(self, *args):
        return subprocess.check_output(["git", *args], cwd=self.root, text=True)

    def write(self, relative, text):
        path = self.root / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(text.encode())

    def check(self, *args):
        return subprocess.run([str(SCRIPT), *args], cwd=self.root, text=True,
                              capture_output=True, check=False)

    def test_clean_moved_lines_and_same_resolved_link(self):
        result = self.check("--baseline-sha", self.baseline)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(f"4 lines match baseline {self.baseline}", result.stdout)
        self.assertEqual(self.check().returncode, 0)

    def test_missing_duplicate_line_is_reported(self):
        self.write(MODULE, NEW_MODULE.replace("repeat\n", "", 1))
        result = self.check("--base", "main")
        self.assertEqual(result.returncode, 1)
        self.assertIn("missing (1): repeat", result.stderr)

    def test_unmarked_addition_and_changed_link_are_reported(self):
        self.write(MODULE, NEW_MODULE.replace("example.md", "wrong.md") + "extra\n")
        result = self.check("--baseline-sha", self.baseline)
        self.assertEqual(result.returncode, 1)
        self.assertIn("missing (1): [shared](.claude/reference/example.md)", result.stderr)
        self.assertIn("unclassified extra (1): [shared](.claude/reference/wrong.md)", result.stderr)
        self.assertIn("unclassified extra (1): extra", result.stderr)

    def test_invalid_text_and_markers_are_unverifiable(self):
        for content in (NEW_MODULE.rstrip("\n"), NEW_MODULE.replace("\n", "\r\n"),
                        "<!-- pm-routing:begin -->\n<!-- pm-routing:end -->\n" + NEW_MODULE):
            with self.subTest(content=content):
                self.write(MODULE, content)
                result = self.check("--base", "main")
                self.assertEqual(result.returncode, 2)
                self.assertIn("unverifiable", result.stderr)

    def test_missing_ref_or_missing_historical_source(self):
        result = self.check("--base", "unknown")
        self.assertEqual(result.returncode, 2)
        self.assertIn("base ref is missing", result.stderr)
        self.git("rm", "--cached", str(ENTRY))
        self.git("-c", "user.name=fixture", "-c", "user.email=fixture@example.invalid",
                 "-c", "core.hooksPath=/dev/null", "commit", "-qm", "empty tree")
        result = self.check("--baseline-sha", self.git("rev-parse", "HEAD").strip())
        self.assertEqual(result.returncode, 2)
        self.assertIn("unverifiable", result.stderr)


unittest.main(argv=[sys.argv[0]], verbosity=2)
PY
