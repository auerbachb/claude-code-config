import importlib.util
import os
import subprocess
import tempfile
import unittest
from pathlib import Path


MODULE = Path(__file__).resolve().parents[1] / ".claude/scripts/lib/quota_resume_launcher.py"
SPEC = importlib.util.spec_from_file_location("quota_resume_launcher", MODULE)
launcher = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(launcher)


class QuotaResumeLauncherTests(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.root = Path(temp.name).resolve()
        self.profile = self.root / "target's $profile"
        self.profile.mkdir()
        self.worktree = self.root / "a coworker's $repo"
        self.worktree.mkdir()
        self.cli = self.root / "claude"
        self.cli.write_text('#!/bin/sh\nprintf "%s\\n" "$CLAUDE_CONFIG_DIR" "$PWD" "$#" "$1" "$2"\n')
        self.cli.chmod(0o700)
        self.generated = self.root / "private launchers.zsh"
        self.generated.write_text(f"# fixture\n{launcher.GENERATED}\n" + r'''
_ai_profile_dir() { print -r -- "/wrong/profile"; }
_ai_launch() {
  local provider="$1" label="$2"; shift 3
  local dir
  dir=$(_ai_profile_dir "$provider" "$label") || return 1
  CLAUDE_CONFIG_DIR="$dir" command claude "$@"
}
claude-target() { _ai_launch claude 'target@example.test' 'Target' "$@"; }
''')
        self.generated.chmod(0o600)
        self.session = "11111111-1111-4111-8111-111111111111"

    def snapshot(self):
        return launcher.snapshot_launcher(self.generated, "claude-target", "target@example.test",
                                          str(self.profile), self.cli)

    @unittest.skipUnless(Path(launcher.ZSH).is_file(), "zsh unavailable")
    def test_real_zsh_pins_profile_and_preserves_exact_cwd_and_argv(self):
        state = self.snapshot()
        self.generated.write_text("a changed file cannot replace the approved bytes")
        with tempfile.TemporaryFile(mode="w+b") as stream:
            stream.write(state.contents)
            stream.seek(0)
            result = subprocess.run(state.argv(stream.fileno(), self.session), cwd=self.worktree,
                                    env=dict(os.environ, PATH=f"{self.root}:/usr/bin:/bin"),
                                    pass_fds=(stream.fileno(),), capture_output=True, text=True, timeout=5)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.splitlines(), [str(self.profile), str(self.worktree),
                                                      "2", "--resume", self.session])

    def test_rejects_untrusted_mapping_and_shared_or_symlink_file(self):
        with self.assertRaises(ValueError):
            launcher.snapshot_launcher(self.generated, "claude-target", "wrong@example.test",
                                       str(self.profile), self.cli)
        self.generated.chmod(0o644)
        with self.assertRaises(ValueError):
            self.snapshot()
        other = self.root / "elsewhere.zsh"
        self.generated.rename(other)
        self.generated.symlink_to(other)
        with self.assertRaises(OSError):
            self.snapshot()

    def test_launcher_proof_changes_with_approved_bytes(self):
        before = self.snapshot()
        with self.generated.open("a") as stream:
            stream.write("# changed after approval\n")
        self.assertNotEqual(before.proof, self.snapshot().proof)
