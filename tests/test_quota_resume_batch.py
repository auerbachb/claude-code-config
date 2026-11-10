import os
import shlex
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch


LIB = Path(__file__).resolve().parents[1] / ".claude/scripts/lib"
sys.path.insert(0, str(LIB))
try:
    import quota_resume_batch as batch
finally:
    sys.path.pop(0)


class QuotaResumeBatchTests(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.home = Path(temp.name).resolve()
        self.source = self.home / "source"
        self.projects = self.source / "projects"
        self.projects.mkdir(parents=True)
        self.target_profile = self.home / "target's $profile"
        self.target_profile.mkdir()
        (self.target_profile / "projects").symlink_to(self.projects, target_is_directory=True)
        self.cwd = self.home / "a coworker's $repo"
        self.cwd.mkdir()
        self.label, self.target_label = "source@example.test", "target@example.test"
        self.session = "11111111-1111-4111-8111-111111111111"
        self.second = "22222222-2222-4222-8222-222222222222"
        self.repo = "owner/repo"
        self.gate = "a" * 64
        self.origin = True
        self.accounts = batch.roster.registered_accounts([
            {"label": self.label, "launcher": "claude-source", "profile_dir": str(self.source)},
            {"label": self.target_label, "launcher": "claude-target", "profile_dir": str(self.target_profile)},
        ])
        self.state = batch.BatchState(self.home, self.accounts, write=True,
                                      check_gate=lambda *_: self.gate, check_origin=lambda *_: self.origin)
        self.state.root.parent.mkdir(parents=True)
        self.handoff = self.state.root.parent / "handoff.md"
        self.handoff.write_text("Fixture handoff must not appear in worker output")
        self.cli = self.home / "claude"
        self.cli.write_text("fixture only")
        self.cli.chmod(0o700)
        self.generated = self.home / "launchers.zsh"
        self.generated.write_text(f"# fixture\n{batch.launch.GENERATED}\n"
                                  """claude-target() { _ai_launch claude 'target@example.test' 'Target' "$@"; }\n""")
        self.generated.chmod(0o600)
        self.launcher = batch.launch.snapshot_launcher(self.generated, "claude-target", self.target_label,
                                                       str(self.target_profile), self.cli)
        self.target = batch.approval.Target("claude-target", str(self.target_profile),
                                            "terminal:" + "b" * 64, self.launcher.proof,
                                            batch.approval.digest(batch.selector_values()))

    def record(self, session, cwd):
        project = self.projects / "fixture-project"
        project.mkdir(exist_ok=True)
        (project / f"{session}.jsonl").touch()
        batch.roster.record(self.state.root, self.label, self.source, session, str(cwd),
                            "Fixture objective", "end", str(self.handoff))
        self.state.record(session, session, self.repo, str(cwd), str(self.handoff), self.label, self.source,
                          capture=lambda *_: {"pid": 42, "start": "fixture", "generation": session})

    def candidates(self):
        return self.state.candidates(self.label, self.source, self.target)

    def test_worker_context_contains_only_exact_local_path_selectors(self):
        selector = str(self.home / "owner's $state.json")
        self.assertEqual(batch.selector_values({"CLAUDE_SESSION_STATE_FILE": selector,
                                                "CLAUDE_CODE_OAUTH_TOKEN": "fixture-token",
                                                "CLAUDE_CODE_SESSION_ID": self.session}),
                         {"CLAUDE_SESSION_STATE_FILE": selector})
        with self.assertRaises(ValueError):
            batch.selector_values({"AI_QUOTAS_CONFIG": "relative.json"})

    def test_replaced_directory_or_changed_gate_never_reuses_old_proof(self):
        self.record(self.session, self.cwd)
        self.assertEqual([item.session for item in self.candidates()], [self.session])
        self.assertFalse(self.state.receipts.exists())
        self.gate = "c" * 64
        self.assertEqual(self.candidates(), [])
        self.gate = "a" * 64
        self.origin = False
        self.assertEqual(self.candidates(), [])
        self.origin = True
        self.cwd.rename(self.home / "old worktree")
        self.cwd.mkdir()
        self.assertEqual(self.candidates(), [])
        self.assertFalse(self.state.receipts.exists())

    def test_two_stop_preview_and_approved_workers_keep_exact_boundaries(self):
        second_dir = self.home / "another directory"
        second_dir.mkdir()
        self.record(self.session, self.cwd)
        self.record(self.second, second_dir)
        stops = self.candidates()
        plan = batch.approval.make_plan(self.target, stops, 1000)
        self.assertFalse(self.state.receipts.exists())
        workers = []

        def submit(stop, _target):
            worker = batch.worker_files(self.state, plan, stop, self.launcher)
            self.assertEqual(worker.stat().st_mode & 0o777, 0o600)
            args = shlex.split(worker.read_text())
            self.assertEqual(args[:2], ["exec", "/usr/bin/env"])
            self.assertEqual(args[-5:-1], [sys.executable, "-B", str(batch.SCRIPT), "worker"])
            workers.append((stop, args[-1]))
            return True

        results = batch.approval.execute_approved(self.target, stops, plan.approval, self.state.receipts,
                                                  self.state.verify, submit, now=1005)
        self.assertEqual({r["status"] for r in results}, {"dispatch accepted"})
        observed = []

        def execute(launcher, session, cwd, directory_fd):
            self.assertEqual(os.fstat(directory_fd).st_ino, Path(cwd).stat().st_ino)
            observed.append((launcher.profile, session, cwd))

        with patch.object(batch.launch, "trusted_cli", return_value=self.cli):
            for stop, manifest in workers:
                batch.run_worker(self.state, manifest, execute=execute, now=1005)
                with self.assertRaises(ValueError):
                    batch.run_worker(self.state, manifest, execute=execute, now=1005)
        self.assertEqual(set(observed), {(str(self.target_profile), self.session, str(self.cwd)),
                                         (str(self.target_profile), self.second, str(second_dir))})
        self.assertEqual(len(observed), 2)
