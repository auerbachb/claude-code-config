import importlib.util
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


MODULE = Path(__file__).resolve().parents[1] / ".claude/scripts/lib/quota_resume_roster.py"
SPEC = importlib.util.spec_from_file_location("quota_resume_roster", MODULE)
roster = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(roster)


class QuotaResumeRosterTests(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.home = Path(temp.name).resolve()
        self.source = self.home / ".claude"
        self.projects = self.source / "projects"
        self.projects.mkdir(parents=True)
        self.root = roster.roster_path(self.home)
        self.root.parent.mkdir()
        self.handoff = self.root.parent / "handoff.md"
        self.handoff.write_text("Verified local handoff\n")
        self.wt = self.home / "a coworker's repo"
        self.wt.mkdir()
        self.work = self.home / "physically-personal"
        self.work.mkdir()
        (self.work / "projects").symlink_to(self.projects, target_is_directory=True)
        self.other = self.home / "different-profile"
        (self.other / "projects").mkdir(parents=True)
        self.accounts = roster.registered_accounts([
            {"label": "personal@example.com", "launcher": "claude-personal", "profile_dir": str(self.source)},
            {"label": "work@example.com", "launcher": "claude-work", "profile_dir": str(self.work)},
            {"label": "split@example.com", "launcher": "claude-split", "profile_dir": str(self.other)},
        ])
        self.label = "personal@example.com"
        self.sid = "11111111-aaaa-4aaa-8aaa-111111111111"
        self.sid2 = "22222222-bbbb-4bbb-8bbb-222222222222"

    def put_transcript(self, sid):
        project = self.projects / "project-key"
        project.mkdir(exist_ok=True)
        (project / (sid + ".jsonl")).write_text("fixture transcript content must never be read\n")

    def record(self, sid, cwd):
        return roster.record(self.root, self.label, self.source, sid, str(cwd),
                             "Work on the fixture", "end", str(self.handoff))

    def test_two_own_checkpoints_and_exact_shell_round_trip(self):
        second = self.home / "another worktree"
        second.mkdir()
        for sid, cwd in ((self.sid, self.wt), (self.sid2, second)):
            self.put_transcript(sid)
            self.record(sid, cwd)
        value = roster.list_records(self.root, self.accounts, self.label, self.source)
        first, other = value["entries"]
        self.assertEqual([first["cwd"], other["cwd"]], [str(self.wt), str(second)])
        self.assertIn("Close the original", value["precondition"])
        eligible, split = first["options"]
        self.assertEqual(eligible["target_account"], "work@example.com")
        self.assertEqual(split, {"target_account": "split@example.com", "status": "not portable", "handoff": str(self.handoff)})
        fake = 'claude-work() { printf "%s\\n" "$PWD" "$1" "$2"; }\n'
        actual = subprocess.check_output(["bash", "-c", fake + eligible["command"]], text=True).splitlines()
        self.assertEqual(actual, [str(self.wt), "--resume", self.sid])
        self.assertNotIn("fixture transcript content", json.dumps(value))

    def test_unavailable_history_never_has_resume_command(self):
        self.record(self.sid, self.wt)
        entry = roster.list_records(self.root, self.accounts, self.label, self.source)["entries"][0]
        self.assertTrue(all(option["status"] == "not portable" and "command" not in option for option in entry["options"]))

    def test_park_is_deduplicated_and_other_account_is_not_disclosed(self):
        self.put_transcript(self.sid)
        park = {"checkpoint": "usage-limit-park", "session_id": self.sid, "cwd": str(self.wt),
                "summary": "Parked review", "handoff": str(self.handoff), "source_profile": str(self.source)}
        different = dict(park, session_id=self.sid2, source_profile=str(self.work), summary="Other account")
        value = roster.list_records(self.root, self.accounts, self.label, self.source, [park, park, different], "read")
        self.assertEqual([(x["session_id"], x["checkpoint"]) for x in value["entries"]], [(self.sid, "usage-limit-park")])
        self.assertNotIn("Other account", json.dumps(value))

    def test_park_summary_is_normalized_without_hiding_the_checkpoint(self):
        park = {"checkpoint": "usage-limit-park", "session_id": self.sid, "cwd": str(self.wt),
                "summary": "  Adopted\n  park " + "a" * 200,
                "handoff": str(self.handoff), "source_profile": str(self.source)}
        value = roster.list_records(self.root, self.accounts, self.label, self.source, [park], "read")
        self.assertEqual(value["unreadable_records"], 0)
        self.assertEqual(value["entries"][0]["summary"], "Adopted park " + "a" * 167)
        park["summary"] = {"text": "unexpected"}
        value = roster.list_records(self.root, self.accounts, self.label, self.source, [park], "read")
        self.assertEqual(value["unreadable_records"], 1)
        self.assertEqual(value["entries"], [])

    def run_skill_block(self, name, anchor, env):
        skill = MODULE.parents[2] / "skills" / name / "SKILL.md"
        block = skill.read_text().split(f"<!-- test-anchor: {anchor} -->", 1)[1]
        block = block.split("```bash\n", 1)[1].split("\n```", 1)[0]
        return subprocess.run(["bash", "-c", block], cwd=self.wt, env=env, capture_output=True, text=True)

    def test_resume_options_never_executes_checkout_or_path_fallback(self):
        def executable(path, body):
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text("#!/bin/bash\n" + body + "\n")
            path.chmod(0o700)

        relative = Path(".claude/scripts/quota-resume-roster.sh")
        executable(self.wt / relative, 'echo "checkout should not run"')
        executable(self.wt / relative.name, 'echo "PATH should not run"')
        env = dict(os.environ, HOME=str(self.home), PATH=str(self.wt) + os.pathsep + os.environ["PATH"])
        run = lambda: self.run_skill_block("go-on", "go-on-quota-resume-options", env)
        missing = run()
        self.assertEqual((missing.returncode, missing.stdout), (1, ""))
        executable(self.home / relative, 'printf "installed %s\\n" "$1"')
        self.assertEqual(run().stdout, "installed list\n")
        executable(self.home / ".claude/skills-worktree" / relative, 'printf "worktree %s\\n" "$1"; exit 5')
        broken = run()
        self.assertEqual((broken.returncode, broken.stdout), (5, "worktree list\n"))
        del env["HOME"]
        missing = run()
        self.assertEqual((missing.returncode, missing.stdout), (1, ""))

    def test_end_roster_uses_only_the_audited_conversation(self):
        helper = self.home / "recorder"
        helper.write_text('#!/bin/bash\nprintf "%s\\n" "$@"\n')
        helper.chmod(0o700)
        env = dict(os.environ, RESUME_STOP_VERIFIED="true", QUOTA_RESUME_ROSTER_SH=str(helper),
                   PUBLISH_RC="0", EXECUTION_GATE_PERSISTED="1", WINDDOWN_PERSISTED="1",
                   SESSION_ID="default", RESUME_CWD=str(self.wt), RESUME_SUMMARY="Stopped work", OUT=str(self.handoff))
        run = lambda: self.run_skill_block("end", "end-quota-resume-record", env)
        missing = run()
        self.assertEqual(missing.stdout, "")
        self.assertIn("no verified Claude session UUID", missing.stderr)
        env["SESSION_ID"] = self.sid
        self.assertEqual(run().stdout.splitlines(), ["record", "--kind", "end", "--session", self.sid,
                         "--cwd", str(self.wt), "--summary", "Stopped work", "--handoff", str(self.handoff)])
        env["RESUME_STOP_VERIFIED"] = "false"
        self.assertEqual(run().stdout, "")

    def test_conflicting_checkpoint_paths_withhold_the_command(self):
        self.put_transcript(self.sid)
        self.record(self.sid, self.wt)
        park = {"checkpoint": "usage-limit-park", "session_id": self.sid, "cwd": str(self.home),
                "summary": "Conflicting checkpoint", "handoff": str(self.handoff), "source_profile": str(self.source)}
        value = roster.list_records(self.root, self.accounts, self.label, self.source, [park], "read")
        self.assertEqual(value["unreadable_records"], 1)
        self.assertTrue(all("command" not in x for x in value["entries"][0]["options"]))

    def test_home_dotfiles_checkout_only_writes_ignored_untracked_roster(self):
        subprocess.run(["git", "init", "--quiet", str(self.home)], check=True)
        self.assertEqual(roster.roster_path(self.home), self.root)
        with self.assertRaises(ValueError):
            roster.roster_path(self.home, write=True)
        (self.home / ".gitignore").write_text("/.claude/handoffs/claude-resume-roster/\n")
        self.assertEqual(roster.roster_path(self.home, write=True), self.root)
        self.root.mkdir()
        existing = self.root / "already-tracked.json"
        existing.write_text("{}\n")
        subprocess.run(["git", "-C", str(self.home), "add", "-f", "--", str(existing)], check=True)
        with self.assertRaises(ValueError):
            roster.roster_path(self.home, write=True)

    def test_primary_identity_fallback_and_unsafe_roster_path(self):
        external_registry = {self.label: ("claude-personal", self.other), "work@example.com": ("claude-work", self.work)}
        self.assertEqual(roster.source_account(external_registry, str(self.source), "PERSONAL@example.com"), (self.label, self.source))
        with self.assertRaises(ValueError):
            roster.source_account(external_registry, str(self.source))
        self.root.symlink_to(self.wt, target_is_directory=True)
        with self.assertRaises(ValueError):
            roster.roster_path(self.home)
