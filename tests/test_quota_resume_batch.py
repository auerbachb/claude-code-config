import os
import re
import shlex
import subprocess
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
        self.state.record(session, session, "42", self.repo, str(cwd), str(self.handoff), self.label, self.source,
                          capture=lambda *_: {"pid": 42, "start": "fixture", "generation": session})

    def candidates(self):
        return self.state.candidates(self.label, self.source, self.target)

    def skill_block(self, name, anchor):
        skill = LIB.parents[1] / "skills" / name / "SKILL.md"
        value = skill.read_text()
        return re.search(r"<!-- test-anchor: " + re.escape(anchor) + r" -->\s+```bash\n(.*?)\n```",
                         value, re.S)[1]

    def test_go_on_batch_routes_only_exact_preview_and_owner_token(self):
        helper = self.home / ".claude/scripts/quota-resume-batch.sh"
        helper.parent.mkdir()
        helper.write_text('#!/bin/bash\nprintf "%s\\n" "$@" >> "$BATCH_TEST_CALLS"\n')
        helper.chmod(0o700)
        calls = self.home / "batch-calls"
        # Point only the anchor's trusted-root reference at isolated fixtures.
        block = re.sub(r"\bHOME\b", "BATCH_FIXTURE_ROOT", self.skill_block("go-on", "go-on-approved-quota-batch"))
        token = "1000." + "a" * 64

        def route(mode, value, installed=None):
            env = dict(os.environ, BATCH_FIXTURE_ROOT=str(installed or self.home), BATCH_TEST_CALLS=str(calls),
                       QUOTA_RESUME_BATCH_MODE=mode, QUOTA_RESUME_TARGET="claude-target",
                       QUOTA_RESUME_BATCH_APPROVAL=value)
            return subprocess.run(["/bin/bash", "-c", block], cwd=self.home, env=env,
                                  capture_output=True, text=True, timeout=5)

        self.assertEqual(route("preview", "").returncode, 0)
        self.assertEqual(calls.read_text().splitlines(), ["preview", "--target", "claude-target"])
        before = calls.read_bytes()
        self.assertEqual(route("preview", token).returncode, 2)
        self.assertEqual(route("approve", "invalid").returncode, 2)
        self.assertEqual(route("preview", "", self.home / "no-install").returncode, 1)
        self.assertEqual(calls.read_bytes(), before)
        self.assertEqual(route("approve", token).returncode, 0)
        self.assertEqual(calls.read_bytes()[len(before):].decode().splitlines(),
                         ["approve", "--target", "claude-target", "--approval", token])

    def test_end_records_batch_proof_only_after_the_manual_roster_write(self):
        manual, automatic, calls = self.home / "manual", self.home / "automatic", self.home / "calls"

        def fixture(path, status):
            path.write_text('#!/bin/bash\nprintf "%s\\n" "$@" >> "$BATCH_TEST_CALLS"\nexit ' + str(status) + '\n')
            path.chmod(0o700)

        fixture(manual, 0)
        fixture(automatic, 0)
        block = self.skill_block("end", "end-quota-resume-record")
        env = dict(os.environ, QUOTA_RESUME_ROSTER_SH=str(manual), QUOTA_RESUME_BATCH_SH=str(automatic),
                   BATCH_TEST_CALLS=str(calls), REPO_KEY=self.repo, SESSION_ID=self.session,
                   RESUME_SUMMARY="fixture", RESUME_CWD=str(self.cwd), OUT=str(self.handoff),
                   RESUME_STOP_VERIFIED="true", PUBLISH_RC="0", EXECUTION_GATE_PERSISTED="1",
                   WINDDOWN_PERSISTED="1")

        def run():
            return subprocess.run(["/bin/bash", "-c", block], cwd=self.home, env=env,
                                  capture_output=True, text=True, timeout=5)

        self.assertEqual(run().returncode, 0)
        self.assertEqual(calls.read_text().splitlines().count("record"), 2)
        before = calls.read_bytes()
        fixture(manual, 7)
        self.assertEqual(run().returncode, 7)
        self.assertEqual(calls.read_bytes()[len(before):].decode().splitlines().count("record"), 1)

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
                batch.run_worker(self.state, manifest, execute=execute, now=1005,
                                 authenticate=lambda *_a, **_kw: None)
                with self.assertRaises(ValueError):
                    batch.run_worker(self.state, manifest, execute=execute, now=1005,
                                 authenticate=lambda *_a, **_kw: None)
        self.assertEqual(set(observed), {(str(self.target_profile), self.session, str(self.cwd)),
                                         (str(self.target_profile), self.second, str(second_dir))})
        self.assertEqual(len(observed), 2)
