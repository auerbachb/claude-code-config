"""Test scheduled PM reporting without a watch or GitHub calls."""
import copy
import json
import os
from pathlib import Path
import re
import runpy
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parent.parent
SCRIPT = ROOT / ".claude/scripts/lib/pm-report.py"
FUNCTIONS = runpy.run_path(str(SCRIPT))
evaluate = FUNCTIONS["evaluate"]
interval = FUNCTIONS["interval"]


class PMReportTest(unittest.TestCase):
    def setUp(self):
        self.board = {
            "running": [{"issue": 38, "phase": "A", "pr": None}],
            "queued": [55],
            "needs": [],
            "terminal": [],
        }

    def test_absent_setting_defaults_to_thirty(self):
        for config in ("", "Set a custom interval in minutes."):
            self.assertEqual(interval(config), 30)
        self.assertEqual(interval("report_every_min: 20"), 20)

    def test_zero_disables_without_board_or_state(self):
        self.assertEqual(evaluate(interval("report_every_min: 0"), None, None, 0),
                         {"due": False, "reason": "disabled"})

    def test_config_only_cli(self):
        for config, expected in (("", "30"), ("report_every_min: 0", "0"),
                                 ("report_every_min: 20", "20")):
            result = subprocess.run([sys.executable, str(SCRIPT), "--config-only"],
                                    input=config, text=True, capture_output=True, check=True)
            self.assertEqual(result.stdout.strip(), expected)
            self.assertFalse(result.stderr)

    def test_changed_board_at_cadence_and_quiet_when_unchanged(self):
        first = evaluate(20, self.board, None, 0)
        self.assertFalse(first["due"])
        receipt = first["initialize"]
        self.board["running"][0].update(phase="B", pr=91)
        self.assertFalse(evaluate(20, self.board, receipt, 5 * 60)["due"])
        report = evaluate(20, self.board, receipt, 20 * 60)
        self.assertEqual(report["reason"], "scheduled")
        self.assertEqual(report["groups"]["working"], [{"issue": 38, "phase": "B", "pr": 91}])
        self.assertEqual(report["groups"]["up_next"], [55])
        receipt = report["after_delivery"]
        self.assertFalse(evaluate(20, self.board, receipt, 45 * 60)["due"])
        self.board["running"][0]["phase"] = "C"
        self.assertTrue(evaluate(20, self.board, receipt, 45 * 60)["due"])

    def test_terminal_outcome_immediate_even_on_empty_board_and_deduplicated(self):
        receipt = evaluate(20, self.board, None, 0)["initialize"]
        self.board["running"] = []
        self.board["queued"] = []
        self.board["terminal"] = [{"key": "run1:42:merged", "issue": 42, "pr": 88, "outcome": "merged"}]
        report = evaluate(20, self.board, receipt, 5 * 60)
        self.assertEqual(report["reason"], "terminal")
        self.assertEqual(report["groups"]["done_since_last_report"],
                         [{"issue": 42, "outcome": "merged", "pr": 88}])
        receipt = report["after_delivery"]
        self.assertFalse(evaluate(20, self.board, receipt, 6 * 60)["due"])
        self.board["terminal"].append(
            {"key": "run1:67:blocked", "issue": 67, "pr": None, "outcome": "blocked"}
        )
        self.board["needs"] = [{"issue": 67, "reason": "choose a delivery scope"}]
        blocked = evaluate(20, self.board, receipt, 6 * 60)
        self.assertEqual(blocked["groups"]["done_since_last_report"][0]["outcome"], "blocked")
        self.assertEqual(blocked["groups"]["needs_you"], self.board["needs"])
        self.assertEqual(set(blocked["groups"]), {"done_since_last_report", "working", "up_next", "needs_you"})

    def test_phase_telemetry_and_running_order_do_not_change_digest(self):
        self.board["running"].append({"issue": 39, "phase": "C", "pr": 90})
        receipt = evaluate(20, self.board, None, 0)["initialize"]
        receipt = evaluate(20, self.board, receipt, 20 * 60)["after_delivery"]
        self.board["running"].reverse()
        self.board["running"][0]["seconds_remaining"] = 20
        self.assertFalse(evaluate(20, self.board, receipt, 60 * 60)["due"])

    def test_invalid_evidence_fails_closed(self):
        for config in ("report_every_min: -1", "report_every_min: 1.5",
                       "report_every_min: 2\nreport_every_min: 3"):
            with self.subTest(config=config), self.assertRaises(ValueError):
                interval(config)
        bad_board = copy.deepcopy(self.board)
        bad_board["running"][0]["phase"] = "done"
        with self.assertRaises(ValueError):
            evaluate(20, bad_board, None, 0)
        with self.assertRaises(ValueError):
            evaluate(20, self.board, {"at": "unknown"}, 0)

    def test_documented_gate_and_receipt_against_real_session_state(self):
        templates = (ROOT / ".claude/reference/pm-output-templates.md").read_text(encoding="utf-8")
        blocks = dict(re.findall(
            r"<!-- test-anchor: (pm-progress-report-[a-z]+) -->\n```bash\n(.*?)\n```",
            templates, re.S,
        ))
        gate = blocks["pm-progress-report-check"] + "\n" + r'''printf '%s\n' "$REPORT_RESULT"''' + "\n"
        receipt = blocks["pm-progress-report-receipt"]
        self.board["terminal"] = [
            {"key": "run1:42:merged", "issue": 42, "pr": 88, "outcome": "merged"}
        ]
        with tempfile.TemporaryDirectory(prefix="pm-report-test-") as folder:
            scratch = Path(folder)
            (scratch / ".claude").mkdir()
            config = scratch / ".claude/pm-config.md"
            config.write_text("## Reporting\nreport_every_min: 20\n", encoding="utf-8")
            subprocess.run(["git", "init", "-q", folder], check=True)
            subprocess.run(["git", "remote", "add", "origin", "https://github.com/fixture/repo.git"],
                           cwd=folder, check=True)
            env = dict(os.environ, HOME=folder, CLAUDE_CODE_SESSION_ID="11111111-2222-3333-4444-555555555555",
                       PM_CONFIG_GET=str(ROOT / ".claude/scripts/pm-config-get.sh"), PM_REPORT_SH=str(SCRIPT),
                       SESSION_STATE_SH=str(ROOT / ".claude/scripts/session-state.sh"),
                       PM_REPORT_BOARD_JSON=json.dumps(self.board))

            def execute(shell):
                return subprocess.check_output(["bash", "-eu", "-o", "pipefail", "-c", shell],
                                               env=env, cwd=folder, text=True).splitlines()[0]

            self.assertTrue(json.loads(execute(gate + "\nREPORT_DELIVERED=0\n" + receipt))["due"])
            self.assertFalse((scratch / ".claude/session-state.json").exists())
            self.assertTrue(json.loads(execute(gate + "\nREPORT_DELIVERED=1\n" + receipt))["due"])
            self.assertFalse(json.loads(execute(gate))["due"])
            env["CLAUDE_CODE_SESSION_ID"] = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
            self.assertTrue(json.loads(execute(gate))["due"])
            env["PM_REPORT_SH"] = ""
            missing = subprocess.run(["bash", "-eu", "-o", "pipefail", "-c", gate],
                                     env=env, cwd=folder, text=True, capture_output=True, check=True)
            self.assertFalse(missing.stdout.strip())
            self.assertIn("PM report helper missing", missing.stderr)
            config.write_text("## Reporting\nreport_every_min: 0\n", encoding="utf-8")
            off = subprocess.run(["bash", "-eu", "-o", "pipefail", "-c", gate],
                                 env=env, cwd=folder, text=True, capture_output=True, check=True)
            self.assertFalse(off.stdout.strip())
            self.assertFalse(off.stderr)

            # Exercise the real gate's missing-section route at its exact default boundary.
            helper = scratch / "report-clock"
            helper.write_text(
                '#!/usr/bin/env bash\nexec "$REPORT_TEST_PYTHON" "$REPORT_TEST_SCRIPT" '
                '--now "$REPORT_TEST_NOW" "$@"\n', encoding="utf-8")
            helper.chmod(0o700)
            config.write_text("## Notes\nNo Reporting section.\n", encoding="utf-8")
            self.board["terminal"] = []
            env.update(PM_REPORT_SH=str(helper), REPORT_TEST_PYTHON=sys.executable,
                       REPORT_TEST_SCRIPT=str(SCRIPT), REPORT_TEST_NOW="1000",
                       CLAUDE_CODE_SESSION_ID="bbbbbbbb-cccc-dddd-eeee-ffffffffffff",
                       PM_REPORT_BOARD_JSON=json.dumps(self.board))
            baseline = json.loads(execute(gate + "\n" + receipt))
            self.assertEqual(baseline["initialize"]["at"], 1000)
            self.board["running"][0].update(phase="B", pr=91)
            env.update(REPORT_TEST_NOW="2799", PM_REPORT_BOARD_JSON=json.dumps(self.board))
            self.assertFalse(json.loads(execute(gate))["due"])
            env["REPORT_TEST_NOW"] = "2800"
            self.assertEqual(json.loads(execute(gate))["reason"], "scheduled")

            # A missing file uses the default. A present unreadable config fails closed.
            config.unlink()
            self.assertTrue(json.loads(execute(gate))["due"])
            reader = env.pop("PM_CONFIG_GET")
            self.assertTrue(json.loads(execute(gate))["due"])
            config.write_text("## Reporting\nreport_every_min: 0\n", encoding="utf-8")
            unavailable = subprocess.run(["bash", "-eu", "-o", "pipefail", "-c", gate],
                                         env=env, cwd=folder, text=True, capture_output=True, check=True)
            self.assertFalse(unavailable.stdout.strip())
            self.assertIn("Reporting configuration unavailable", unavailable.stderr)
            env["PM_CONFIG_GET"] = reader
            config.unlink()
            config.mkdir()
            bad_config = subprocess.run(["bash", "-eu", "-o", "pipefail", "-c", gate],
                                        env=env, cwd=folder, text=True, capture_output=True, check=True)
            self.assertFalse(bad_config.stdout.strip())
            self.assertIn("Reporting configuration unavailable", bad_config.stderr)

    def test_scheduled_gate_is_pm_only(self):
        for skill in ("subagent", "pr-monitor-and-manage"):
            text = (ROOT / ".claude/skills" / skill / "SKILL.md").read_text(encoding="utf-8")
            self.assertNotIn("pm-progress-report-check", text)
            self.assertNotIn("PM_REPORT_SH", text)

    def test_cli_reports_invalid_config_without_a_render_signal(self):
        result = subprocess.run([sys.executable, str(SCRIPT)],
                                input=json.dumps({"config": "report_every_min: tomorrow"}),
                                text=True, capture_output=True, check=False)
        self.assertEqual(result.returncode, 2)
        self.assertEqual(result.stdout, "")
        self.assertIn("nonnegative integer", result.stderr)


if __name__ == "__main__":
    unittest.main()
