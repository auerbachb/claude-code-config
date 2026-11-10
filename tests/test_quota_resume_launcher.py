import importlib.util
import json
import os
import subprocess
import tempfile
import types
import unittest
from pathlib import Path
from unittest.mock import patch


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
            safe = {k: v for k, v in os.environ.items() if k not in launcher.AUTH_OVERRIDES}
            safe["PATH"] = f"{self.root}:/usr/bin:/bin"
            result = subprocess.run(state.argv(stream.fileno(), self.session), cwd=self.worktree,
                                    env=safe,
                                    pass_fds=(stream.fileno(),), capture_output=True, text=True, timeout=5)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.splitlines(), [str(self.profile), str(self.worktree),
                                                      "2", "--resume", self.session])
        with tempfile.TemporaryFile(mode="w+b") as stream:
            stream.write(state.contents)
            stream.seek(0)
            refused = subprocess.run(state.argv(stream.fileno(), self.session), cwd=self.worktree,
                                     env=dict(safe, ANTHROPIC_API_KEY="fixture-key"), pass_fds=(stream.fileno(),),
                                     capture_output=True, text=True, timeout=5)
        self.assertEqual(refused.returncode, 1)
        self.assertEqual(refused.stdout, "")

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

    def test_subscription_preflight_requires_exact_logged_in_account_and_profile(self):
        selected = self.snapshot()
        valid = dict(loggedIn=True, authMethod="claude.ai", apiProvider="firstParty",
                     email="target@example.test", configDirectory=str(self.profile))
        calls = []

        def runner(value):
            def run(args, **kwargs):
                calls.append((args, kwargs["env"]["CLAUDE_CONFIG_DIR"], kwargs["cwd"]))
                return types.SimpleNamespace(returncode=0, stdout=json.dumps(value).encode())

            return run

        with patch.dict(os.environ, {key: "" for key in launcher.AUTH_OVERRIDES}):
            launcher.verify_subscription(selected, self.profile, run=runner(valid))
            self.assertEqual(calls[-1], ([str(self.cli), "auth", "status"], str(self.profile), self.profile))
            for change in (dict(email="other@example.test"), dict(authMethod="api_key"),
                           dict(configDirectory=str(self.worktree)), dict(loggedIn=False)):
                with self.subTest(change=change), self.assertRaises(ValueError):
                    launcher.verify_subscription(selected, self.profile, run=runner(dict(valid, **change)))

            before = len(calls)
            with patch.dict(os.environ, {"ANTHROPIC_API_KEY": "fixture-not-a-real-key"}):
                with self.assertRaises(ValueError):
                    launcher.verify_subscription(selected, self.profile, run=runner(valid))
            profile_settings = self.profile / "settings.json"
            profile_settings.write_text('{"apiKeyHelper":"must-not-run"}')
            with self.assertRaises(ValueError):
                launcher.verify_subscription(selected, self.profile, run=runner(valid))
            profile_settings.unlink()
            project = self.worktree / ".claude"
            project.mkdir()
            (project / "settings.json").write_text('{"apiKeyHelper":"must-not-run"}')
            with self.assertRaises(ValueError):
                launcher.verify_subscription(selected, self.worktree, project=True, run=runner(valid))
            self.assertEqual(len(calls), before)

    def test_launcher_proof_changes_with_approved_bytes(self):
        before = self.snapshot()
        with self.generated.open("a") as stream:
            stream.write("# changed after approval\n")
        self.assertNotEqual(before.proof, self.snapshot().proof)
