import importlib.util
import os
import socket
import tempfile
import types
import unittest
from pathlib import Path
from unittest.mock import patch


MODULE = Path(__file__).resolve().parents[1] / ".claude/scripts/lib/quota_resume_terminal.py"
SPEC = importlib.util.spec_from_file_location("quota_resume_terminal", MODULE)
terminal = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(terminal)


class QuotaResumeTerminalTests(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory(prefix="qr-", dir="/tmp")
        self.addCleanup(temp.cleanup)
        self.root = Path(temp.name).resolve()
        self.executable = self.root / "adapter"
        self.executable.write_text("fixture only")
        self.executable.chmod(0o700)
        self.worker = self.root / "owner's $worker.zsh"
        self.worker.write_text("fixture only")
        self.worker.chmod(0o600)
        self.script = self.root / "terminal.applescript"
        self.script.write_text("fixture only")
        self.calls = []

    def reply(self, text, code=0):
        def runner(argv):
            self.calls.append(list(map(str, argv)))
            return types.SimpleNamespace(returncode=code, stdout=text)

        return runner

    def test_terminal_requires_exact_ack_and_trusted_private_worker(self):
        identity = (*terminal.file_identity(self.executable), *terminal.file_identity(self.script))
        backend = terminal.Backend("terminal", self.executable, identity, self.script)
        self.assertTrue(backend.submit(self.worker, self.reply("accepted /dev/ttys042\n")))
        self.assertEqual(self.calls, [[str(self.executable), str(self.script), str(self.worker)]])
        self.assertFalse(backend.submit(self.worker, self.reply("accepted /dev/ttys042\nextra text")))
        self.assertFalse(backend.submit(self.worker, self.reply("accepted /dev/ttys042", code=1)))
        self.worker.chmod(0o644)
        with self.assertRaises(terminal.BackendUnavailable):
            backend.submit(self.worker, self.reply("accepted /dev/ttys042"))
        self.assertEqual(len(self.calls), 3)

    def test_changed_terminal_script_refuses_dispatch(self):
        identity = (*terminal.file_identity(self.executable), *terminal.file_identity(self.script))
        backend = terminal.Backend("terminal", self.executable, identity, self.script)
        self.script.write_text("a different backend script")
        with self.assertRaises(terminal.BackendUnavailable):
            backend.submit(self.worker, self.reply("accepted /dev/ttys042"))
        self.assertEqual(self.calls, [])

    def test_tmux_uses_verified_pane_session_and_separate_arguments(self):
        sock_path = self.root / "socket"
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as sock:
            sock.bind(str(sock_path))
            sock_path.chmod(0o600)
            env = {"TMUX": f"{sock_path},42,0", "TMUX_PANE": "%12"}
            with patch.object(terminal, "TMUX_LOCATIONS", (self.executable,)):
                backend = terminal.discover(env, self.reply("$3\n"), platform="linux")
                self.assertEqual(backend.session, "$3")
                self.assertRegex(backend.approval_destination, r"^tmux:[a-f0-9]{64}$")
                self.assertEqual(self.calls, [[str(self.executable), "-S", str(sock_path), "display-message",
                                               "-p", "-t", "%12", "#{session_id}"]])
                self.assertTrue(backend.submit(self.worker, self.reply("@8\n")))
                self.assertEqual(self.calls[-1], [str(self.executable), "-S", str(sock_path), "new-window",
                                                 "-d", "-P", "-F", "#{window_id}", "-t", "$3:", "--",
                                                 "/bin/zsh", "-f", str(self.worker)])
                self.assertFalse(backend.submit(self.worker, self.reply("ambiguous")))
                sock_path.chmod(0o660)
                with self.assertRaises(terminal.BackendUnavailable):
                    backend.submit(self.worker, self.reply("@9"))

    def test_tmux_missing_pane_does_not_switch_to_terminal(self):
        with self.assertRaises(terminal.BackendUnavailable):
            terminal.discover({"TMUX": "/fake/socket,1,0", "TMUX_PANE": "%bad"},
                              self.reply("unexpected"), platform="darwin")
        self.assertEqual(self.calls, [])
