#!/usr/bin/env python3
"""Unit tests for merge-conflict resolve_merge_conflicts.py."""

import importlib.util
import json
import pathlib
import subprocess
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
        self.assertEqual(resolved, "from x import y\nimport z")
        self.assertFalse(resolved.endswith("\n"))

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

    def test_identical_nonblank_sequence_preserves_blank_lines(self) -> None:
        """o_nb == t_nb branch must run (not swallowed by per-line rstrip-only path)."""
        ours = "a\n\nb\n"
        theirs = "a\n\nb\n"
        cls, resolved, _ = mod.classify_and_resolve(ours, theirs)
        self.assertEqual(cls, "simple")
        assert resolved is not None
        self.assertEqual(resolved, "a\n\nb")


class WriteRepoTextTests(unittest.TestCase):
    def test_surrogateescape_round_trip(self) -> None:
        """Non-UTF-8 file bytes must survive write after decode(read) with surrogateescape."""
        with tempfile.TemporaryDirectory() as td:
            p = pathlib.Path(td) / "latin1.txt"
            p.write_bytes(b"caf\xe9\n")
            text = mod.read_repo_text(p)
            self.assertIn("\udce9", text)
            mod.write_repo_text(p, text)
            self.assertEqual(p.read_bytes(), b"caf\xe9\n")


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

    def test_non_utf8_simple_hunk_does_not_crash(self) -> None:
        """Resolved output must re-encode when file has non-UTF-8 bytes outside the hunk."""
        with tempfile.TemporaryDirectory() as td:
            p = pathlib.Path(td) / "f.txt"
            # Latin-1 é outside conflict; simple whitespace-only hunk inside
            raw = (
                b"caf\xe9\n"
                b"<<<<<<< HEAD\n"
                b"x  \n"
                b"=======\n"
                b"x\n"
                b">>>>>>> branch\n"
            )
            p.write_bytes(raw)
            text = raw.decode("utf-8", errors="surrogateescape")
            fr = mod.resolve_file(p, text)
            self.assertTrue(fr.wrote)
            out = p.read_bytes()
            self.assertTrue(out.startswith(b"caf\xe9\n"))
            self.assertIn(b"x\n", out)
            self.assertNotIn(b"<<<<<<<", out)


class UnmergedNoMarkersIntegrationTests(unittest.TestCase):
    def test_modify_delete_reported_in_complex(self) -> None:
        """Unmerged paths without conflict markers appear in complex_report."""
        with tempfile.TemporaryDirectory() as td:
            repo = pathlib.Path(td)
            subprocess.run(["git", "init", "-b", "main", "-q"], cwd=repo, check=True)
            subprocess.run(
                ["git", "config", "user.email", "t@t"],
                cwd=repo,
                check=True,
            )
            subprocess.run(["git", "config", "user.name", "t"], cwd=repo, check=True)
            (repo / "tracked.txt").write_text("base\n", encoding="utf-8")
            subprocess.run(["git", "add", "tracked.txt"], cwd=repo, check=True)
            subprocess.run(["git", "commit", "-qm", "base"], cwd=repo, check=True)
            subprocess.run(["git", "checkout", "-b", "other", "-q"], cwd=repo, check=True)
            subprocess.run(["git", "rm", "-q", "tracked.txt"], cwd=repo, check=True)
            subprocess.run(["git", "commit", "-qm", "del"], cwd=repo, check=True)
            subprocess.run(["git", "checkout", "main", "-q"], cwd=repo, check=True)
            subprocess.run(["git", "checkout", "-b", "feature", "-q"], cwd=repo, check=True)
            (repo / "tracked.txt").write_text("changed\n", encoding="utf-8")
            subprocess.run(["git", "add", "tracked.txt"], cwd=repo, check=True)
            subprocess.run(["git", "commit", "-qm", "mod"], cwd=repo, check=True)
            r = subprocess.run(
                ["git", "merge", "other", "--no-commit"],
                cwd=repo,
                capture_output=True,
                text=True,
            )
            self.assertNotEqual(r.returncode, 0)
            self.assertIn("tracked.txt", r.stderr + r.stdout)

            proc = subprocess.run(
                [
                    sys.executable,
                    str(SCRIPT),
                    "--repo",
                    str(repo),
                    "--skip-fetch",
                    "--json",
                ],
                cwd=repo,
                capture_output=True,
                text=True,
            )
            self.assertEqual(proc.returncode, 1)
            data = json.loads(proc.stdout)
            names = [str(x["file"]) for x in data["complex_report"]]
            self.assertIn("tracked.txt", names)
            reasons = " ".join(str(x["reason"]) for x in data["complex_report"])
            self.assertIn("no inline conflict markers", reasons)


if __name__ == "__main__":
    unittest.main()
