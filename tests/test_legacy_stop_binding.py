"""Verify legacy stop binding and exact guarded recovery in disposable state."""
from datetime import datetime, timedelta
import hashlib
import json
import os
from pathlib import Path
import re
import shlex
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parent.parent
PAUSE = ROOT / ".claude/scripts/execution-pause.sh"
BIND = ROOT / ".claude/scripts/lib/legacy-stop-binding.py"
SKILL = ROOT / ".claude/skills/end-resume/SKILL.md"
NATIVE = "11111111-2222-3333-4444-555555555555"
OTHER = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
REPO = "fixture/repo"
LEGACY = "default"


class LegacyStopTest(unittest.TestCase):
    def setUp(self):
        scratch = tempfile.TemporaryDirectory(prefix="legacy-stop-test-")
        self.addCleanup(scratch.cleanup)
        self.scratch = Path(scratch.name)
        self.checkout = self.scratch / "repo"
        self.checkout.mkdir()
        self.projects = self.scratch / ".claude/projects/fixture-repo"
        self.projects.mkdir(parents=True)
        subprocess.run(["git", "init", "-q", str(self.checkout)], check=True)
        subprocess.run(["git", "remote", "add", "origin", "https://github.com/fixture/repo.git"],
                       cwd=self.checkout, check=True)
        self.state = self.scratch / ".claude/session-state.json"
        self.env = dict(os.environ, HOME=str(self.scratch),
                        CLAUDE_CONFIG_DIR=str(self.scratch / ".claude"),
                        CLAUDE_SESSION_STATE_FILE=str(self.state),
                        CLAUDE_EXECUTION_PAUSE_MARKER_DIR=str(self.scratch / "markers"))
        self.env.pop("AI_QUOTAS_CONFIG", None)

    def invoke(self, *args, expected=0, env=None):
        result = subprocess.run([str(arg) for arg in args], cwd=self.checkout,
                                env=self.env if env is None else env, capture_output=True,
                                text=True, check=False, timeout=20)
        self.assertEqual(result.returncode, expected, result.stderr)
        return result.stdout.strip()

    def pause(self, *args, expected=0):
        return self.invoke(PAUSE, "--repo", REPO, *args, expected=expected)

    def arm(self, key=LEGACY):
        self.pause("--activate", "--session", key, "--command", "end", "--window-minutes", "0")

    def snapshot(self):
        return json.loads(self.pause("--snapshot-legacy", "--session", LEGACY))

    def transcript(self, session=NATIVE, *, command=None, after=1):
        stamp = datetime.fromisoformat(self.snapshot()["at"].replace("Z", "+00:00"))
        begin = stamp - timedelta(seconds=1)
        end = stamp + timedelta(seconds=after)
        if command is None:
            command = shlex.join([str(PAUSE), "--activate", "--session", LEGACY,
                                  "--command", "end", "--window-minutes", "0"])
        events = [
            {"type": "assistant", "sessionId": session, "cwd": str(self.checkout),
             "timestamp": begin.isoformat().replace("+00:00", "Z"),
             "message": {"content": [{"type": "tool_use", "id": "toolu-fixture", "name": "Bash",
                                      "input": {"command": command}}]}},
            {"type": "user", "sessionId": session,
             "timestamp": end.isoformat().replace("+00:00", "Z"),
             "message": {"content": [{"type": "tool_result", "tool_use_id": "toolu-fixture",
                                      "is_error": False}]}},
        ]
        path = self.projects / f"{session}.jsonl"
        path.write_text("".join(json.dumps(row) + "\n" for row in events), encoding="utf-8")
        return path

    def bind(self, expected=0):
        return json.loads(self.invoke(BIND, "--repo", REPO, "--native-session", NATIVE,
                                      "--legacy-session", LEGACY, expected=expected))

    def guarded_clear(self, token, expected=0):
        self.pause("--clear", "--session", LEGACY, "--native-session", NATIVE,
                   "--expect-legacy-token", token, expected=expected)

    def test_verified_binding_clears_only_legacy_and_survives_retry(self):
        self.arm()
        state = json.loads(self.state.read_text(encoding="utf-8"))
        record = state["repos"][REPO]["execution_pauses"][LEGACY]
        del record["generation"]  # Original releases did not stamp a generation.
        self.state.write_text(json.dumps(state) + "\n", encoding="utf-8")
        suffix = hashlib.sha256(f"{REPO}\0{LEGACY}".encode("utf-8")).hexdigest()
        marker = self.scratch / "markers" / f"claude-execution-pause-v2-{suffix}"
        marker.write_text(json.dumps(record) + "\n", encoding="utf-8")
        self.transcript()
        original = self.state.read_bytes()
        proof = self.bind()
        self.assertEqual(proof["verdict"], "verified")
        self.assertEqual(self.state.read_bytes(), original)
        self.guarded_clear(proof["gate_token"])
        self.assertEqual(self.pause("--status", "--session", LEGACY), "inactive")
        self.assertEqual(self.pause("--status", "--session", NATIVE), "inactive")
        self.assertEqual(self.pause("--legacy-resume-scope", "--session", LEGACY,
                                    "--native-session", NATIVE), LEGACY)
        self.pause("--legacy-resume-scope", "--session", LEGACY, "--native-session", OTHER, expected=3)
        self.arm(NATIVE)
        self.pause("--legacy-resume-scope", "--session", LEGACY, "--native-session", NATIVE, expected=3)

    def test_unrelated_default_and_ambiguous_transcripts_hold(self):
        self.arm()
        self.transcript(OTHER)
        before = self.state.read_bytes()
        self.assertEqual(self.bind(expected=1)["verdict"], "held")
        self.transcript()
        self.assertEqual(self.bind(expected=1)["verdict"], "held")
        self.assertEqual(self.state.read_bytes(), before)
        self.assertEqual(self.pause("--status", "--session", LEGACY), "active")

    def test_registered_isolated_profile_can_hold_competing_evidence(self):
        self.arm()
        self.transcript()
        other = self.transcript(OTHER)
        separate = self.scratch / "isolated-profile/projects/fixture-repo"
        separate.mkdir(parents=True)
        other.rename(separate / other.name)
        registry = self.scratch / ".claude/ai-quotas.json"
        registry.write_text(json.dumps({"schema_version": "1.0", "accounts": [{
            "provider": "claude", "label": "test@example.invalid",
            "profile_dir": str(separate.parent.parent)
        }]}), encoding="utf-8")
        self.env["AI_QUOTAS_CONFIG"] = str(registry)
        result = self.bind(expected=1)
        self.assertIn("another activation", result["reason"])

    def test_failed_marker_removal_leaves_exact_clear_retryable(self):
        self.arm()
        self.transcript()
        token = self.bind()["gate_token"]
        fake_bin = self.scratch / "bin"
        fake_bin.mkdir()
        rm = fake_bin / "rm"
        rm.write_text('#!/bin/bash\ncase "$*" in *claude-execution-pause-v2-*) exit 1;; esac\nexec /bin/rm "$@"\n',
                      encoding="utf-8")
        rm.chmod(0o700)
        env = dict(self.env, PATH=str(fake_bin) + os.pathsep + self.env["PATH"])
        self.invoke(PAUSE, "--repo", REPO, "--clear", "--session", LEGACY,
                    "--native-session", NATIVE, "--expect-legacy-token", token, expected=5, env=env)
        self.assertEqual(self.pause("--status", "--session", LEGACY), "active")
        self.assertEqual(self.bind()["gate_token"], token)
        self.guarded_clear(token)
        self.assertEqual(self.pause("--status", "--session", LEGACY), "inactive")

    def test_transcript_resolves_only_same_call_literal_shell_assignments(self):
        self.arm()
        command = "\n".join([
            f"EXECUTION_PAUSE_SH={shlex.quote(str(PAUSE))}", "SESSION_ID=default", "WINDOW_MINUTES=0",
            '"$EXECUTION_PAUSE_SH" --activate --session "$SESSION_ID" --command end --window-minutes "$WINDOW_MINUTES"',
        ])
        self.transcript(command=command)
        self.assertEqual(self.bind()["verdict"], "verified")
        self.transcript(command=command.replace('"$SESSION_ID"', "'$SESSION_ID'"))
        self.assertEqual(self.bind(expected=1)["verdict"], "held")

    def test_missing_malformed_and_dynamic_evidence_hold(self):
        self.arm()
        before = self.state.read_bytes()
        self.assertEqual(self.bind(expected=1)["verdict"], "held")
        path = self.transcript(command=' "$EXECUTION_PAUSE_SH" --activate --session "$SESSION_ID" --command end')
        self.assertEqual(self.bind(expected=1)["verdict"], "held")
        path.write_text("{\n", encoding="utf-8")
        self.assertEqual(self.bind(expected=1)["verdict"], "held")
        self.assertEqual(self.state.read_bytes(), before)

    def test_new_generation_or_active_native_gate_cannot_be_cleared(self):
        self.arm()
        self.transcript()
        previous = self.bind()["gate_token"]
        self.arm()
        changed = self.snapshot()["token"]
        self.assertNotEqual(changed, previous)
        before = self.state.read_bytes()
        self.guarded_clear(previous, expected=7)
        self.assertEqual(self.state.read_bytes(), before)
        self.arm(NATIVE)
        before = self.state.read_bytes()
        self.guarded_clear(changed, expected=7)
        self.assertEqual(self.state.read_bytes(), before)

    def test_skill_uses_one_exact_stop_scope_and_native_path(self):
        text = SKILL.read_text(encoding="utf-8")
        blocks = dict(re.findall(
            r"<!-- test-anchor: (end-resume-[a-z-]+) -->\n\n```bash\n(.*?)\n```", text, re.S))
        bind = blocks["end-resume-other-gate"]
        clear = blocks["end-resume-clear-selected"]
        prefix = 'RESUME_REPO_ARGS=(--repo "$RESUME_REPO")\n'
        env = dict(self.env, SESSION_ID=NATIVE, CLAUDE_SESSION_ID=LEGACY,
                   RESUME_REPO=REPO, EXECUTION_PAUSE_SH=str(PAUSE), LEGACY_STOP_BINDING_SH=str(BIND))

        self.arm(NATIVE)
        self.invoke("bash", "-eu", "-c", prefix + bind + "\n" + clear, env=env)
        self.assertEqual(self.pause("--status", "--session", NATIVE), "inactive")

        self.arm()
        self.transcript()
        result = self.invoke("bash", "-eu", "-c", prefix + bind + "\n" + clear
                             + '\nprintf "%s" "$STOP_SESSION_ID"', env=env)
        self.assertEqual(result, LEGACY)
        self.assertEqual(self.pause("--status", "--session", LEGACY), "inactive")
        result = self.invoke("bash", "-eu", "-c", prefix + bind + "\n" + clear
                             + '\nprintf "%s:%s" "$STOP_SESSION_ID" "$LEGACY_ALREADY_CLEARED"', env=env)
        self.assertEqual(result, f"{LEGACY}:1")
        registry = ROOT / ".claude/scripts/background-task-registry.sh"
        self.invoke(registry, "--repo", REPO, "--register", "--session", LEGACY,
                    "--task-id", "old-task", "--type", "agent", "--name", "legacy")
        self.invoke(registry, "--repo", REPO, "--transition", "--session", LEGACY,
                    "--task-id", "old-task", "--status", "stopped")
        env.update(TASK_REGISTRY_SH=str(registry), TASK_ID="old-task")
        self.invoke("bash", "-eu", "-c", prefix + bind + "\n" + blocks["end-resume-reserve-task"], env=env)
        self.assertEqual(json.loads(self.invoke(registry, "--repo", REPO, "--list", "--session", NATIVE)), [])
        old = json.loads(self.invoke(registry, "--repo", REPO, "--list", "--session", LEGACY))
        self.assertEqual([(row["task_id"], row["status"]) for row in old], [("old-task", "rearming")])

        # Rearm the legacy gate after the procedural check, just before the
        # native tool launch reaches its PreToolUse hook.
        self.arm(LEGACY)
        self.assertEqual(self.pause("--status", "--session", NATIVE), "inactive")
        gate = ROOT / ".claude/hooks/pause-launch-gate.sh"
        payload = {"tool_name": "Agent", "cwd": str(self.checkout)}
        for native, expected in ((NATIVE, 2), (OTHER, 0)):
            result = subprocess.run([str(gate)], input=json.dumps(dict(payload, session_id=native)),
                                    cwd=self.checkout, env=self.env, capture_output=True, text=True)
            self.assertEqual(result.returncode, expected, result.stderr)


        self.arm(NATIVE)
        before = self.state.read_bytes()
        gated = prefix + 'STOP_SESSION_ID=default; LEGACY_GATE_SESSION_ID=default\n' + blocks["end-resume-prelaunch-gates"]
        self.invoke("bash", "-eu", "-c", gated, expected=1, env=env)
        self.assertEqual(self.state.read_bytes(), before)



if __name__ == "__main__":
    unittest.main()
