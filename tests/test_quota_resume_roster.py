import contextlib
import io
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch


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

    def park(self, cwd, handoff):
        return {"checkpoint": "usage-limit-park", "session_id": self.sid, "cwd": str(cwd),
                "summary": "Parked review", "handoff": str(handoff), "source_profile": str(self.source)}

    def test_missing_worktree_keeps_verified_handoff_without_resume(self):
        self.put_transcript(self.sid)
        missing = self.home / "missing worktree"
        target = roster.account_for_launcher(self.accounts, self.label, "claude-work")
        value = roster.list_records(self.root, {target: self.accounts[target]}, self.label, self.source,
                                    [self.park(missing, self.handoff)], "read")
        entry, = value["entries"]
        self.assertEqual(value["unreadable_records"], 0)
        self.assertEqual(entry["handoffs"], [{"path": str(self.handoff), "cwd": str(missing),
                                              "cwd_available": False}])
        self.assertEqual(entry["options"], [{"target_account": target, "status": "not portable",
                                             "handoff": str(self.handoff)}])
        self.assertFalse(missing.exists())

    def test_same_worktree_preserves_distinct_handoffs_and_one_command(self):
        self.put_transcript(self.sid)
        self.record(self.sid, self.wt)
        second = self.root.parent / "pr-102.md"
        second.write_text("Second verified handoff")
        records = [self.park(self.wt, self.handoff), self.park(self.wt, second), self.park(self.wt, second)]
        value = roster.list_records(self.root, self.accounts, self.label, self.source, records, "read")
        entry, = value["entries"]
        self.assertEqual(entry["checkpoint"], "end")
        self.assertEqual(entry["handoff"], str(self.handoff))
        self.assertEqual([row["path"] for row in entry["handoffs"]], [str(self.handoff), str(second)])
        self.assertTrue(all(row["cwd_available"] for row in entry["handoffs"]))
        commands = [option["command"] for option in entry["options"] if "command" in option]
        self.assertEqual(len(commands), 1)
        self.assertNotIn("Second verified handoff", json.dumps(value))

    def test_invalid_handoff_excluded_and_mixed_locations_never_authorize(self):
        self.put_transcript(self.sid)
        self.record(self.sid, self.wt)
        second = self.root.parent / "pr-102.md"
        second.write_text("Second verified handoff")
        untrusted = self.home / "outside-handoffs.md"
        untrusted.write_text("Outside handoff directory")
        missing = self.home / "missing worktree"
        records = [self.park(missing, second), self.park(self.wt, untrusted)]
        value = roster.list_records(self.root, self.accounts, self.label, self.source, records, "read")
        entry, = value["entries"]
        self.assertEqual(value["unreadable_records"], 2)
        self.assertEqual([(row["path"], row["cwd_available"]) for row in entry["handoffs"]],
                         [(str(self.handoff), True), (str(second), False)])
        self.assertTrue(all(option["status"] == "not portable" and "command" not in option
                            for option in entry["options"]))
        self.assertNotIn(str(untrusted), json.dumps(value))

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

    def test_suggestion_ranks_verified_weekly_headroom_and_fails_on_ambiguity(self):
        def row(label, used, status="ok", window="7-day", reset=2000, provider="claude"):
            return dict(label=label, used_pct=used, status=status, window=window,
                        resets_at_epoch=reset, provider=provider)

        def suggest(rows, observed=900):
            return roster.suggest_account(self.accounts, self.label, rows, 95, observed, 1000, 120)

        work, split = "work@example.com", "split@example.com"
        ranked = [row(work, 18), row(work, 66, window="7-day sonnet"), row(split, 45),
                  row(split, 99, window="5-hour"), row("codex@example.com", 0, provider="codex")]
        self.assertEqual(suggest(ranked), {"decision": "suggested", "launcher": "claude-split"})
        self.assertEqual(suggest([row(work, 35), row(split, 35)]),
                         {"decision": "suggested", "launcher": "claude-split"})
        self.assertEqual(suggest([row(work, 95), row(split, None, "needs-login")]), {"decision": "none"})
        self.assertEqual(suggest([row(work, 25), row(split, None, "needs-login")]),
                         {"decision": "suggested", "launcher": "claude-work"})
        for rows in ([row(work, 25)], [row(work, 25), row(split, None, "rate-limited")],
                     [row(work, 25), row(split, 10, reset=999)],
                     [row(work, 25), row(split, 10), row(split, 20)],
                     [row(work, 25), row(split, True)], [row(work, 25), row(split, float("nan"))]):
            self.assertEqual(suggest(rows), {"decision": "unknown"})
        self.assertEqual(suggest(ranked, observed=879), {"decision": "unknown"})
        self.assertEqual(suggest(ranked, observed=1001), {"decision": "unknown"})

    def test_target_launcher_must_be_an_exact_registered_alternative(self):
        self.assertEqual(roster.account_for_launcher(self.accounts, self.label, "claude-work"),
                         "work@example.com")
        for wrong in ("claude-personal", "claude-wor", "claude-work; echo bad", "work@example.com"):
            with self.assertRaises(ValueError):
                roster.account_for_launcher(self.accounts, self.label, wrong)

    def test_targeted_list_only_displays_the_selected_existing_option(self):
        self.put_transcript(self.sid)
        self.record(self.sid, self.wt)
        registry = [{"label": label, "launcher": name, "profile_dir": str(path)}
                    for label, (name, path) in self.accounts.items()]
        output = io.StringIO()
        with patch.object(Path, "home", return_value=self.home), \
                patch.object(roster, "metadata", return_value=registry), \
                patch.object(roster, "read_park_records", return_value=([], "read")), \
                patch.dict(os.environ, CLAUDE_CONFIG_DIR=str(self.source)), \
                patch.object(roster.sys, "argv", ["roster", "list", "--target", "claude-work"]), \
                contextlib.redirect_stdout(output):
            self.assertEqual(roster.main(), 0)
        options = json.loads(output.getvalue())["entries"][0]["options"]
        self.assertEqual([option["target_account"] for option in options], ["work@example.com"])
        self.assertIn("claude-work --resume", options[0]["command"])

    def run_skill_block(self, name, anchor, env, trailer=""):
        skill = MODULE.parents[2] / "skills" / name / "SKILL.md"
        block = skill.read_text().split(f"<!-- test-anchor: {anchor} -->", 1)[1]
        block = block.split("```bash\n", 1)[1].split("\n```", 1)[0]
        return subprocess.run(["bash", "-c", block + "\n" + trailer], cwd=self.wt, env=env,
                              capture_output=True, text=True)

    def test_end_and_end_resume_use_the_native_session_bound_to_task_hooks(self):
        gate = self.home / "gate"
        gate.write_text('#!/bin/bash\nprintf "%s\\n" "$@"\n')
        gate.chmod(0o700)
        state = self.home / "state"
        state.write_text('#!/bin/bash\nif [[ "$1" == --repo-key ]]; then echo owner/repo; fi\n')
        state.chmod(0o700)
        env = dict(os.environ, CLAUDE_CODE_SESSION_ID=self.sid, CLAUDE_SESSION_ID="legacy",
                   EXECUTION_PAUSE_SH=str(gate), SESSION_STATE_SH=str(state), WINDOW_MINUTES="0")
        end = self.run_skill_block("end", "end-native-session-gate", env)
        self.assertEqual(end.returncode, 0)
        self.assertEqual(end.stdout.splitlines()[:3], ["--activate", "--session", self.sid])
        def resume():
            return self.run_skill_block("end-resume", "end-resume-native-session", env,
                                        'printf "%s" "$SESSION_ID"').stdout
        self.assertEqual(resume(), self.sid)
        env["CLAUDE_CODE_SESSION_ID"] = "not-a-native-uuid"
        self.assertEqual(resume(), "legacy")
        del env["CLAUDE_SESSION_ID"]
        self.assertEqual(resume(), "default")

    def test_end_resume_checks_the_other_key_without_clearing_or_guessing_it(self):
        gate = self.home / "other-gate"
        gate.write_text('#!/bin/bash\nprintf "%s\\n" "$*" >> "$GATE_CALLS"\n'
                        'printf "%s\\n" "$LEGACY_STATUS"; exit "$LEGACY_RC"\n')
        gate.chmod(0o700)
        calls = self.home / "other-gate-calls"
        env = dict(os.environ, SESSION_ID=self.sid, CLAUDE_SESSION_ID="legacy:raw/key",
                   EXECUTION_PAUSE_SH=str(gate), GATE_CALLS=str(calls), LEGACY_RC="0")
        for status, exit_code, expected in [("active", "0", 1), ("inactive", "4", 1),
                                             ("unexpected", "0", 1), ("inactive", "0", 0)]:
            with self.subTest(status=status, exit_code=exit_code):
                calls.write_text("")
                env.update(LEGACY_STATUS=status, LEGACY_RC=exit_code)
                result = self.run_skill_block("end-resume", "end-resume-other-gate", env,
                                              'printf "can continue"')
                self.assertEqual(result.returncode, expected)
                self.assertEqual(result.stdout, "can continue" if expected == 0 else "")
                self.assertEqual(calls.read_text().splitlines(), ["--status --session legacy:raw/key"])
        calls.write_text("")
        env["SESSION_ID"] = ""
        result = self.run_skill_block("end-resume", "end-resume-other-gate", env)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(calls.read_text(), "")

    def test_go_on_checks_legacy_and_native_gate_without_turning_failures_into_absence(self):
        gate = self.home / "status"
        gate.write_text('#!/bin/bash\nprintf "%s\\n" "$3" >> "$GATE_CALLS"\n'
                        'if [[ "$3" == "$CLAUDE_CODE_SESSION_ID" ]]; then echo "$NATIVE_STATUS"; '
                        'else echo "$LEGACY_STATUS"; fi\n')
        gate.chmod(0o700)
        calls = self.home / "calls"
        env = dict(os.environ, CLAUDE_CODE_SESSION_ID=self.sid, SESSION_ID="default",
                   EXECUTION_PAUSE_SH=str(gate), GATE_CALLS=str(calls), NATIVE_STATUS="inactive",
                   LEGACY_STATUS="active")
        env.pop("CLAUDE_SESSION_ID", None)

        def probe():
            return self.run_skill_block("go-on", "go-on-live-native-session-gate", env,
                                        'printf "%s" "$GATE_LIVE"').stdout
        self.assertEqual(probe(), "active")
        self.assertEqual(calls.read_text().splitlines(), [self.sid, "default"])
        env.update(NATIVE_STATUS="active", LEGACY_STATUS="unreadable")
        self.assertEqual(probe(), "active")
        env.update(NATIVE_STATUS="malformed", LEGACY_STATUS="inactive")
        self.assertEqual(probe(), "unreadable")
        env.update(NATIVE_STATUS="inactive")
        self.assertEqual(probe(), "inactive")

        calls.write_text("")
        env.update(CLAUDE_SESSION_ID="legacy:with/slash", SESSION_ID="legacy_with_slash",
                   LEGACY_STATUS="active")
        self.assertEqual(probe(), "active")
        self.assertEqual(calls.read_text().splitlines(), [self.sid, "legacy:with/slash"])
        calls.write_text("")
        env["CLAUDE_SESSION_ID"] = self.sid
        self.assertEqual(probe(), "inactive")
        self.assertEqual(calls.read_text().splitlines(), [self.sid])

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
        executable(self.home / relative, 'printf "%s\\n" "$@"')
        env["QUOTA_RESUME_TARGET"] = "claude-work"
        self.assertEqual(run().stdout.splitlines(), ["list", "--target", "claude-work"])
        env["QUOTA_RESUME_TARGET"] = "claude-work; echo bad"
        rejected = run()
        self.assertEqual((rejected.returncode, rejected.stdout), (1, ""))
        del env["QUOTA_RESUME_TARGET"]
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
