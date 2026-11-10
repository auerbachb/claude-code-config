import importlib.util
import os
import tempfile
import unittest
from pathlib import Path


MODULE = Path(__file__).resolve().parents[1] / ".claude/scripts/lib/quota_resume_process.py"
SPEC = importlib.util.spec_from_file_location("quota_resume_process", MODULE)
process = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(process)


class QuotaResumeProcessTests(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.root = Path(temp.name).resolve()
        self.repo = "owner/repo"
        self.session = "11111111-1111-4111-8111-111111111111"
        self.uid = 501
        self.start = "Mon Nov 9 20:30:02 2026"
        self.origin = {"pid": 10, "start": self.start,
                       "generation": process.stop_generation(self.repo, self.session, self.uid, 10, self.start)}

    def row(self, pid, parent, command, start=None, uid=None):
        return f"{pid} {parent} {self.uid if uid is None else uid} {start or self.start} {command}\n"

    def reader(self, tables, directories=None):
        tables = iter(tables)
        directories = directories or {}

        def read(executable, *args):
            if executable == "ps":
                return next(tables).encode()
            if executable != "lsof":
                raise AssertionError("unexpected process tool")
            pid = int(args[3])
            value = directories.get(pid)
            if value is None:
                raise process.EvidenceUnavailable("missing process directory")
            return f"p{pid}\0\nfcwd\0n".encode() + os.fsencode(value) + b"\0\n"

        return read

    def test_captures_exact_native_origin_and_stable_generation(self):
        table = self.row(21, 10, "/bin/bash") + self.row(10, 1, "/usr/local/bin/claude")
        for native in (self.session, self.session.upper()):
            result = process.capture_origin(self.session, native, self.repo, parent=21, uid=self.uid,
                                            read=self.reader([table]))
            self.assertEqual(result, self.origin)
        with self.assertRaises(process.EvidenceUnavailable):
            process.capture_origin(self.session, "default", self.repo, parent=21, uid=self.uid,
                                   read=self.reader([]))
        not_native = self.row(21, 10, "/bin/bash") + self.row(10, 1, "/Applications/Claude")
        with self.assertRaises(process.EvidenceUnavailable):
            process.capture_origin(self.session, self.session, self.repo, parent=21, uid=self.uid,
                                   read=self.reader([not_native]))

    def check(self, tables, directories=None, origin=None, repo=None):
        return process.origin_exited(origin or self.origin, self.root, self.session, repo or self.repo,
                                     uid=self.uid, read=self.reader(tables, directories))

    def test_origin_must_be_absent_and_generation_must_match(self):
        alive = self.row(10, 1, "/usr/local/bin/claude")
        self.assertFalse(self.check([alive]))
        reused = self.row(10, 1, "/bin/sleep", start="Mon Nov 9 20:30:03 2026")
        self.assertTrue(self.check([reused, reused]))
        self.assertFalse(self.check([], repo="other/repo"))
        self.assertFalse(self.check([], origin=dict(self.origin, generation=self.session)))

    def test_same_directory_or_unknown_directory_blocks(self):
        possible = self.row(44, 1, "/usr/local/bin/node")
        self.assertFalse(self.check([possible], {44: self.root}))
        self.assertFalse(self.check([possible]))
        other = self.root / "a coworker's $directory"
        other.mkdir()
        self.assertTrue(self.check([possible, possible], {44: other}))

    def test_new_or_replaced_process_during_snapshot_blocks(self):
        shell = self.row(29, 1, "/bin/bash")
        appeared = shell + self.row(44, 1, "/usr/local/bin/claude")
        self.assertFalse(self.check([shell, appeared]))
        replaced = shell + self.row(10, 1, "/bin/sleep")
        self.assertFalse(self.check([shell, replaced]))
        self.assertFalse(self.check(["invalid process output"]))

    def test_untrusted_pid_owner_cannot_create_stop_proof(self):
        table = self.row(21, 10, "/bin/bash") + self.row(10, 1, "claude", uid=self.uid + 1)
        with self.assertRaises(process.EvidenceUnavailable):
            process.capture_origin(self.session, self.session, self.repo, parent=21, uid=self.uid,
                                   read=self.reader([table]))
