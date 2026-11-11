import contextlib
import importlib.util
import io
import json
from pathlib import Path
from subprocess import CompletedProcess
import unittest
from unittest.mock import patch


ROOT = Path(__file__).resolve().parents[1]
HELPER = ROOT / ".claude/scripts/lib/pm-slot-census.py"
SPEC = importlib.util.spec_from_file_location("pm_slot_census", HELPER)
CENSUS = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(CENSUS)
REPO = "org/repo"
PATH = '.repos["org/repo"].slot_census'


class SlotCensusTest(unittest.TestCase):
    def setUp(self):
        self.records = {}
        self.conflicts = 0
        self.writes = 0
        fake = patch.object(CENSUS, "state_call", side_effect=self.state_call)
        fake.start()
        self.addCleanup(fake.stop)

    def state_call(self, helper, repo, mode, target, *args):
        if mode == "--get-json":
            self.assertEqual(target, PATH)
            return CompletedProcess([], 0, json.dumps(self.records.get((repo, target))))
        self.assertEqual(mode, "--cas")
        path, value = target.split("=", 1)
        self.assertEqual(args[0], "--expect")
        if self.conflicts:
            self.conflicts -= 1
            return CompletedProcess([], 7, "")
        self.assertEqual(self.records.get((repo, path)), json.loads(args[1]))
        self.records[(repo, path)] = json.loads(value)
        self.writes += 1
        return CompletedProcess([], 0, "")

    @staticmethod
    def observation(*outcomes, running=2, gate=None, horizon=None):
        return dict(limit=6, running=running, merge_ready_or_phase_c=1, queued=len(outcomes),
                    global_gate=gate, horizon_status=horizon,
                    candidates=[dict(issue=index, outcome=outcome) for index, outcome in enumerate(outcomes, 1)])

    def record(self, data, repo=REPO, session="worker-1"):
        output = io.StringIO()
        with contextlib.redirect_stdout(output):
            CENSUS.record(None, repo, PATH, session, CENSUS.make_census(data))
        return output.getvalue().strip()

    def board(self, repo=REPO, session="worker-1"):
        output = io.StringIO()
        with contextlib.redirect_stdout(output):
            CENSUS.render(None, repo, PATH, session)
        return output.getvalue().strip()

    def test_candidate_counts_match_board_output(self):
        line = self.record(self.observation("chained", "chained", "chained", "undeclared"))
        self.assertEqual(line, "Board below limit · 2/6 slots · 3 chained, 1 undeclared")
        self.assertEqual(self.board(), line)
        self.assertEqual(self.board(session="observer"), line + " (recorded session worker-1)")
        self.assertEqual(self.board(repo="other/repo"), "")
        self.assertEqual(self.writes, 1)
        record = self.records[(REPO, PATH)]["worker-1"]
        self.assertEqual(record["merge_ready_or_phase_c"], 1)
        self.assertEqual(record["queued"], 4)
        self.assertEqual(sum(record["reasons"].values()), 4)

    def test_identical_evaluation_is_saved_quietly_even_after_cas_loss(self):
        state = self.observation("chained")
        self.assertTrue(self.record(state))
        self.conflicts = 1
        self.assertEqual(self.record(state), "")
        record = self.records[(REPO, PATH)]["worker-1"]
        self.assertEqual(record["seq"], 2)
        self.assertEqual(len(record["history"]), 2)
        self.assertEqual(self.writes, 2)

    def test_eligible_work_and_no_launch_is_a_fault(self):
        line = self.record(self.observation(*(["eligible"] * 4)))
        self.assertIn("4 refill_missed", line)
        self.assertTrue(self.records[(REPO, PATH)]["worker-1"]["refill_missed"])
        for evidence in ("launched", "launch_unconfirmed", "launch_unknown"):
            with self.subTest(evidence=evidence):
                self.assertNotIn("refill_missed", self.record(self.observation(evidence, "eligible")))
                self.assertFalse(self.records[(REPO, PATH)]["worker-1"]["refill_missed"])

    def test_full_board_is_quiet_and_a_later_taper_emits(self):
        partial = self.observation("chained")
        first = self.record(partial)
        self.assertEqual(self.record(self.observation("eligible", running=6)), "")
        self.assertEqual(self.board(), "")
        self.assertEqual(self.record(partial), first)

    def test_global_gate_accounts_for_every_open_slot(self):
        self.assertIn("4 horizon (critical)", self.record(self.observation(gate="horizon", horizon="critical")))
        self.assertIn("4 paused (budget unknown)", self.record(self.observation("eligible", gate="paused_budget_unknown")))
        self.assertFalse(self.records[(REPO, PATH)]["worker-1"]["refill_missed"])

    def test_repo_retention_bounds_both_sessions_and_history(self):
        data = self.observation("chained")
        for index in range(CENSUS.SESSION_LIMIT + 1):
            for _ in range(4):
                self.record(data, session=f"session-{index:02}")
        records = self.records[(REPO, PATH)]
        self.assertEqual(len(records), CENSUS.SESSION_LIMIT)
        self.assertNotIn("session-00", records)
        self.assertEqual(records[f"session-{CENSUS.SESSION_LIMIT:02}"]["seq"], 4)
        self.assertEqual(sum(len(record["history"]) for record in records.values()), CENSUS.REPO_HISTORY_LIMIT)
        self.assertLess(len(CENSUS.compact(records)), 100_000)

    def test_invalid_observations_fail_before_the_cas(self):
        broken = self.observation("eligible", "chained")
        broken["candidates"][1]["issue"] = 1
        with self.assertRaisesRegex(ValueError, "unique issue"):
            self.record(broken)
        self.assertEqual(self.writes, 0)


if __name__ == "__main__":
    unittest.main()
