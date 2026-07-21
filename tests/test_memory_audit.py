#!/usr/bin/env python3
"""Unit tests for .claude/scripts/memory-audit.py (issue #620).

Every fixture is a throwaway ``memory`` dir under a tempdir — the live memory
store is never touched. Covers detection (orphans, dangling pointers, index
size, advisory superseded/duplicate), the read-only guarantee of ``--check``,
the confirmed-prune + integrity path, and the safety refusals that make the
irreversible deletes trustworthy.
"""

from __future__ import annotations

import importlib.util
import os
import pathlib
import shutil
import subprocess
import sys
import tempfile
import unittest


REPO_ROOT = pathlib.Path(__file__).resolve().parents[1]
SCRIPT_PATH = REPO_ROOT / ".claude" / "scripts" / "memory-audit.py"

spec = importlib.util.spec_from_file_location("memory_audit", SCRIPT_PATH)
memory_audit = importlib.util.module_from_spec(spec)
assert spec.loader is not None
spec.loader.exec_module(memory_audit)


def make_store(root, index_lines, files):
    """Create a ``memory`` dir. ``files`` maps basename -> full file text;
    ``index_lines`` is the list of MEMORY.md lines (no trailing newline each)."""
    mem = os.path.join(root, "memory")
    os.makedirs(mem, exist_ok=True)
    for name, text in files.items():
        with open(os.path.join(mem, name), "w") as fh:
            fh.write(text)
    if index_lines is not None:
        with open(os.path.join(mem, "MEMORY.md"), "w") as fh:
            fh.write("\n".join(index_lines) + "\n")
    return mem


def fact(name, body="body\n"):
    return "---\nname: {}\ntype: feedback\n---\n{}".format(name, body)


class DetectTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.addCleanup(lambda: shutil.rmtree(self.tmp, ignore_errors=True))

    def test_orphans_and_dangling(self):
        mem = make_store(
            self.tmp,
            ["- [Keep](keep.md) — h", "- [Gone](gone.md) — dangling"],
            {"keep.md": fact("keep"), "orphan.md": fact("orphan")},
        )
        r = memory_audit.detect(mem, memory_audit.DEFAULT_BUDGET_BYTES)
        self.assertEqual(r["orphans"], ["orphan.md"])
        self.assertEqual(r["dangling"], ["gone.md"])
        self.assertEqual(r["summary"]["orphan_count"], 1)
        self.assertEqual(r["summary"]["dangling_count"], 1)

    def test_index_size_budget_boundary(self):
        mem = make_store(self.tmp, ["- [A](a.md) — h"], {"a.md": fact("a")})
        size = memory_audit.detect(mem, 10 ** 9)["index"]["bytes"]
        self.assertFalse(memory_audit.detect(mem, size)["index"]["over_budget"])
        self.assertTrue(memory_audit.detect(mem, size - 1)["index"]["over_budget"])

    def test_superseded_cites_replacement_and_ignores_trap(self):
        mem = make_store(
            self.tmp,
            [
                "- [Stale](stale.md) — h",
                "- [Trap](trap.md) — h",
                "- [Current](current.md) — h",
            ],
            {
                "stale.md": fact("stale", "Superseded by [[new-thing]].\n"),
                "trap.md": fact("trap", "This review does not supersede that one.\n"),
                "current.md": fact("current", "A distinct, current fact.\n"),
            },
        )
        sup = memory_audit.detect(mem, memory_audit.DEFAULT_BUDGET_BYTES)["advisory"]["superseded"]
        self.assertEqual(len(sup), 1)
        self.assertEqual(sup[0]["file"], "stale.md")
        self.assertEqual(sup[0]["replacement"], "new-thing")
        flagged = {s["file"] for s in sup}
        self.assertNotIn("trap.md", flagged)     # bare keyword, no cross-ref
        self.assertNotIn("current.md", flagged)  # distinct, current

    def test_superseded_marker_without_crossref_not_flagged(self):
        mem = make_store(
            self.tmp,
            ["- [Old](old.md) — h"],
            {"old.md": fact("old", "This entry is deprecated.\n")},  # no cross-ref
        )
        self.assertEqual(memory_audit.detect(mem, 10 ** 9)["advisory"]["superseded"], [])

    def test_duplicate_names(self):
        mem = make_store(
            self.tmp,
            ["- [A](a.md) — h", "- [B](b.md) — h"],
            {"a.md": fact("same fact"), "b.md": fact("same fact")},
        )
        dups = memory_audit.detect(mem, 10 ** 9)["advisory"]["duplicate_names"]
        self.assertEqual(len(dups), 1)
        self.assertEqual(sorted(dups[0]["files"]), ["a.md", "b.md"])

    def test_check_is_read_only(self):
        mem = make_store(
            self.tmp,
            ["- [Keep](keep.md) — h", "- [Gone](gone.md) — d"],
            {"keep.md": fact("keep"), "orphan.md": fact("orphan")},
        )
        before = sorted(os.listdir(mem))
        with open(os.path.join(mem, "MEMORY.md"), "rb") as fh:
            idx_before = fh.read()
        memory_audit.detect(mem, memory_audit.DEFAULT_BUDGET_BYTES)
        self.assertEqual(sorted(os.listdir(mem)), before)
        with open(os.path.join(mem, "MEMORY.md"), "rb") as fh:
            self.assertEqual(fh.read(), idx_before)

    def test_scan_skips_symlinks(self):
        # A symlink inside the store (which could point outside) must never be
        # scanned, listed, or recommended — the boundary guarantee.
        mem = make_store(self.tmp, ["- [Keep](keep.md) — h"], {"keep.md": fact("keep")})
        outside = os.path.join(self.tmp, "outside.md")
        with open(outside, "w") as fh:
            fh.write("secret outside the store\n")
        os.symlink(outside, os.path.join(mem, "sneaky.md"))
        self.assertEqual(memory_audit.list_memory_files(mem), ["keep.md"])
        r = memory_audit.detect(mem, memory_audit.DEFAULT_BUDGET_BYTES)
        self.assertNotIn("sneaky.md", r["orphans"])


class ApplyTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.addCleanup(lambda: shutil.rmtree(self.tmp, ignore_errors=True))
        self.mem = make_store(
            self.tmp,
            [
                "- [Keep](keep.md) — h",
                "- [Stale](stale.md) — h",
                "- [Gone](gone.md) — dangling",
            ],
            {
                "keep.md": fact("keep"),
                "stale.md": fact("stale", "Superseded by [[new]].\n"),
                "orphan.md": fact("orphan"),
            },
        )

    def _detect(self):
        return memory_audit.detect(self.mem, memory_audit.DEFAULT_BUDGET_BYTES)

    def test_delete_orphan_leaves_index_untouched(self):
        r = memory_audit.apply_prune(self.mem, ["orphan.md"], [], memory_audit.DEFAULT_BUDGET_BYTES)
        self.assertEqual(r["deleted"], ["orphan.md"])
        self.assertEqual(r["index_lines_dropped"], [])
        self.assertFalse(os.path.exists(os.path.join(self.mem, "orphan.md")))
        self.assertTrue(r["integrity"]["ok"])
        self.assertEqual(r["integrity"]["new_dangling"], [])
        # pre-existing dangling stays (user did not ask to clear it)
        self.assertEqual(r["integrity"]["remaining_dangling"], ["gone.md"])

    def test_delete_orphan_keeps_index_byte_identical(self):
        with open(os.path.join(self.mem, "MEMORY.md"), "rb") as fh:
            before = fh.read()
        memory_audit.apply_prune(self.mem, ["orphan.md"], [], memory_audit.DEFAULT_BUDGET_BYTES)
        with open(os.path.join(self.mem, "MEMORY.md"), "rb") as fh:
            self.assertEqual(fh.read(), before)  # no line dropped -> no rewrite

    def test_index_write_failure_leaves_files_intact(self):
        # The index is rewritten BEFORE any unlink; if that write fails, nothing
        # is deleted (fail toward zero mutation, never a dangling pointer).
        def boom(*_a, **_k):
            raise OSError("simulated disk-full during index rewrite")
        orig = memory_audit._atomic_write
        memory_audit._atomic_write = boom
        self.addCleanup(lambda: setattr(memory_audit, "_atomic_write", orig))
        with self.assertRaises(OSError):
            memory_audit.apply_prune(self.mem, ["keep.md"], [], memory_audit.DEFAULT_BUDGET_BYTES)
        self.assertTrue(os.path.exists(os.path.join(self.mem, "keep.md")))

    def test_drop_dangling_line(self):
        before = self._detect()["index"]["entry_count"]
        r = memory_audit.apply_prune(self.mem, [], ["gone.md"], memory_audit.DEFAULT_BUDGET_BYTES)
        self.assertEqual(len(r["index_lines_dropped"]), 1)
        self.assertEqual(r["after"]["entry_count"], before - 1)
        self.assertTrue(r["integrity"]["ok"])
        self.assertEqual(r["integrity"]["remaining_dangling"], [])

    def test_delete_referenced_file_drops_its_line(self):
        r = memory_audit.apply_prune(self.mem, ["keep.md"], [], memory_audit.DEFAULT_BUDGET_BYTES)
        self.assertEqual(r["deleted"], ["keep.md"])
        self.assertEqual(len(r["index_lines_dropped"]), 1)
        self.assertFalse(os.path.exists(os.path.join(self.mem, "keep.md")))
        # deleting a referenced file AND its line must not create a dangling pointer
        self.assertEqual(r["integrity"]["new_dangling"], [])
        self.assertTrue(r["integrity"]["ok"])

    def test_before_after_counts(self):
        r = memory_audit.apply_prune(self.mem, ["keep.md"], ["gone.md"], memory_audit.DEFAULT_BUDGET_BYTES)
        self.assertEqual(r["before"]["entry_count"], 3)
        self.assertEqual(r["after"]["entry_count"], 1)
        self.assertLess(r["after"]["bytes"], r["before"]["bytes"])

    def test_atomic_rewrite_preserves_remaining_lines(self):
        memory_audit.apply_prune(self.mem, [], ["gone.md"], memory_audit.DEFAULT_BUDGET_BYTES)
        with open(os.path.join(self.mem, "MEMORY.md")) as fh:
            content = fh.read()
        self.assertTrue(content.endswith("\n"))
        self.assertIn("keep.md", content)
        self.assertIn("stale.md", content)
        self.assertNotIn("gone.md", content)

    def test_requires_targets(self):
        with self.assertRaises(memory_audit.AuditError) as ctx:
            memory_audit.apply_prune(self.mem, [], [], memory_audit.DEFAULT_BUDGET_BYTES)
        self.assertEqual(ctx.exception.code, 2)

    def test_drop_index_on_live_file_refused(self):
        with self.assertRaises(memory_audit.AuditError) as ctx:
            memory_audit.apply_prune(self.mem, [], ["keep.md"], memory_audit.DEFAULT_BUDGET_BYTES)
        self.assertEqual(ctx.exception.code, 4)
        self.assertTrue(os.path.exists(os.path.join(self.mem, "keep.md")))


class SafetyTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.addCleanup(lambda: shutil.rmtree(self.tmp, ignore_errors=True))
        self.mem = make_store(
            self.tmp, ["- [Keep](keep.md) — h"], {"keep.md": fact("keep")}
        )
        self.home = tempfile.mkdtemp()
        self.addCleanup(lambda: shutil.rmtree(self.home, ignore_errors=True))

    def _run(self, *args):
        env = dict(os.environ)
        env["HOME"] = self.home  # keep the usage log + forbidden-set hermetic
        return subprocess.run(
            [sys.executable, str(SCRIPT_PATH)] + list(args),
            capture_output=True, text=True, env=env,
        )

    def _files(self):
        return sorted(os.listdir(self.mem))

    def test_refuse_path_component(self):
        before = self._files()
        p = self._run("--apply", "--dir", self.mem, "--files", "../evil.md")
        self.assertEqual(p.returncode, 4)
        self.assertEqual(self._files(), before)

    def test_refuse_memory_index(self):
        p = self._run("--apply", "--dir", self.mem, "--files", "MEMORY.md")
        self.assertEqual(p.returncode, 4)
        self.assertTrue(os.path.exists(os.path.join(self.mem, "MEMORY.md")))

    def test_refuse_non_md(self):
        with open(os.path.join(self.mem, "notes.txt"), "w") as fh:
            fh.write("x")
        p = self._run("--apply", "--dir", self.mem, "--files", "notes.txt")
        self.assertEqual(p.returncode, 4)
        self.assertTrue(os.path.exists(os.path.join(self.mem, "notes.txt")))

    def test_refuse_symlink_escape(self):
        outside = os.path.join(self.tmp, "outside.md")
        with open(outside, "w") as fh:
            fh.write("secret\n")
        link = os.path.join(self.mem, "evil.md")
        os.symlink(outside, link)
        p = self._run("--apply", "--dir", self.mem, "--files", "evil.md")
        self.assertEqual(p.returncode, 4)
        self.assertTrue(os.path.exists(outside))  # target untouched
        self.assertTrue(os.path.islink(link))     # link not removed

    def test_refuse_dir_outside_memory_store(self):
        plain = os.path.join(self.tmp, "not_a_store")
        os.makedirs(plain, exist_ok=True)
        p = self._run("--check", "--dir", plain)
        self.assertEqual(p.returncode, 4)

    def test_env_dir_not_found(self):
        p = self._run("--check", "--dir", os.path.join(self.tmp, "nope"))
        self.assertEqual(p.returncode, 3)

    def test_resolve_refuses_forbidden_dirs(self):
        # A dir that LOOKS like a store (holds a MEMORY.md) but IS a forbidden
        # path (~/.claude/projects) must still be refused by the explicit guard.
        real_home = os.environ.get("HOME")
        os.environ["HOME"] = self.home
        try:
            projects = os.path.join(self.home, ".claude", "projects")
            os.makedirs(projects, exist_ok=True)
            with open(os.path.join(projects, "MEMORY.md"), "w") as fh:
                fh.write("- [x](x.md) — h\n")
            with self.assertRaises(memory_audit.AuditError) as ctx:
                memory_audit.resolve_memory_dir(projects)
            self.assertEqual(ctx.exception.code, 4)
        finally:
            if real_home is not None:
                os.environ["HOME"] = real_home
            else:
                os.environ.pop("HOME", None)


class MainErrorTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.addCleanup(lambda: shutil.rmtree(self.tmp, ignore_errors=True))
        self.mem = make_store(self.tmp, ["- [A](a.md) — h"], {"a.md": fact("a")})

    def test_unexpected_error_maps_to_exit_4(self):
        # An unexpected OSError from the engine must surface as the documented
        # exit code, not a raw traceback with an undocumented code.
        def boom(*_a, **_k):
            raise OSError("simulated failure")
        orig = memory_audit.detect
        memory_audit.detect = boom
        self.addCleanup(lambda: setattr(memory_audit, "detect", orig))
        self.assertEqual(memory_audit.main(["--check", "--dir", self.mem]), 4)


class HelperTests(unittest.TestCase):
    def test_path_encode(self):
        self.assertEqual(
            memory_audit.encode_project_path("/Users/x/Develop/claude-code-config"),
            "-Users-x-Develop-claude-code-config",
        )
        # both "/" and "." collapse to "-", 1:1 (worktree path shape)
        self.assertEqual(
            memory_audit.encode_project_path("/a/b/.claude/worktrees/wt"),
            "-a-b--claude-worktrees-wt",
        )

    def test_extract_pointer(self):
        self.assertEqual(memory_audit.extract_pointer("- [T](foo.md) — h"), "foo.md")
        self.assertEqual(memory_audit.extract_pointer("- [T](sub/bar.md) — h"), "bar.md")
        self.assertIsNone(memory_audit.extract_pointer("- plain text, no link"))
        self.assertIsNone(memory_audit.extract_pointer("- [T](https://x.md) — h"))


if __name__ == "__main__":
    unittest.main()
