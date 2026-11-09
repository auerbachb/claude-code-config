import importlib.util
import json
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
