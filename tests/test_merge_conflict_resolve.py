#!/usr/bin/env python3
"""Unit tests for merge-conflict resolve_merge_conflicts.py."""

import importlib.util
import pathlib
import sys
import tempfile
import unittest


REPO_ROOT = pathlib.Path(__file__).resolve().parents[1]
SCRIPT = REPO_ROOT / ".claude" / "skills" / "merge-conflict" / "resolve_merge_conflicts.py"

spec = importlib.util.spec_from_file_location("merge_conflict_resolve", SCRIPT)
mod = importlib.util.module_from_spec(spec)
assert spec.loader is not None
sys.modules[spec.name] = mod
spec.loader.exec_module(mod)


class ClassifyTests(unittest.TestCase):
    def test_identical_trailing_whitespace_simple(self) -> None:
        ours = "foo  \nbar\n"
        theirs = "foo\nbar\n"
        cls, resolved, reason = mod.classify_and_resolve(ours, theirs)
        self.assertEqual(cls, "simple")
        self.assertIsNotNone(resolved)
        assert resolved is not None
        self.assertEqual(resolved, "foo\nbar")
        self.assertEqual(reason, "")

    def test_per_line_trailing_simple(self) -> None:
        ours = "a \nb\n"
        theirs = "a\nb \n"
        cls, resolved, _ = mod.classify_and_resolve(ours, theirs)
        self.assertEqual(cls, "simple")
        assert resolved is not None
        self.assertEqual(resolved, "a\nb")

    def test_different_content_complex(self) -> None:
        ours = "return 1\n"
        theirs = "return 2\n"
        cls, resolved, reason = mod.classify_and_resolve(ours, theirs)
        self.assertEqual(cls, "complex")
        self.assertIsNone(resolved)
        self.assertIn("differing", reason)

    def test_empty_ours_import_only_simple(self) -> None:
        ours = ""
        theirs = "from x import y\nimport z\n"
        cls, resolved, _ = mod.classify_and_resolve(ours, theirs)
        self.assertEqual(cls, "simple")
        assert resolved is not None
        self.assertIn("from x import y", resolved)

    def test_empty_ours_non_import_complex(self) -> None:
        ours = ""
        theirs = "x = 1\n"
        cls, resolved, reason = mod.classify_and_resolve(ours, theirs)
        self.assertEqual(cls, "complex")
        self.assertIsNone(resolved)
        self.assertIn("non-import", reason)

    def test_empty_theirs_complex(self) -> None:
        ours = "keep me\n"
        theirs = ""
        cls, resolved, reason = mod.classify_and_resolve(ours, theirs)
        self.assertEqual(cls, "complex")
        self.assertIsNone(resolved)
        self.assertIn("incoming side empty", reason)


class ResolveFileTests(unittest.TestCase):
    def test_writes_resolved_file(self) -> None:
        content = (
            "before\n"
            "<<<<<<< HEAD\n"
            "a  \n"
            "=======\n"
            "a\n"
            ">>>>>>> branch\n"
            "after\n"
        )
        with tempfile.TemporaryDirectory() as td:
            p = pathlib.Path(td) / "f.txt"
            p.write_text(content, encoding="utf-8")
            fr = mod.resolve_file(p, content)
            self.assertTrue(fr.wrote)
            self.assertEqual(len(fr.hunks), 1)
            self.assertEqual(fr.hunks[0][1], "simple")
            out = p.read_text(encoding="utf-8")
            self.assertNotIn("<<<<<<<", out)
            self.assertEqual(out, "before\na\nafter\n")


if __name__ == "__main__":
    unittest.main()
