import concurrent.futures
import importlib.util
import json
import os
import stat
import tempfile
import threading
import unittest
from dataclasses import replace
from pathlib import Path


MODULE = Path(__file__).resolve().parents[1] / ".claude/scripts/lib/quota_resume_approval.py"
SPEC = importlib.util.spec_from_file_location("quota_resume_approval", MODULE)
approval = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(approval)


class QuotaResumeApprovalTests(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.root = Path(directory.name).resolve()
        self.receipts = self.root / "receipts"
        self.target = approval.Target("claude-target", str(self.root / "target"), "terminal:" + "a" * 64, "c" * 64)
        self.stop = approval.Stop(
            "source@example.test", str(self.root / "source"), "owner/repo",
            "11111111-1111-4111-8111-111111111111", "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
            str(self.root / "a coworker's $repo"),
        )
        self.second = replace(self.stop, session="22222222-2222-4222-8222-222222222222",
                              generation="bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb")
        self.calls = []

    def sent(self, stop, target):
        self.calls.append((stop, target))
        return True

    def run_batch(self, stops, token=None, *, target=None, verify=None, dispatch=None, now=1005):
        target = target or self.target
        token = approval.make_plan(target, stops, 1000).approval if token is None else token
        return approval.execute_approved(target, stops, token, self.receipts, verify or (lambda *_: True),
                                         dispatch or self.sent, now=now)

    def test_approval_binds_target_working_copy_and_exact_set(self):
        plan = approval.make_plan(self.target, [self.stop, self.second], 1000)
        self.assertEqual(plan.approval, approval.make_plan(self.target, [self.second, self.stop], 1000).approval)
        changed = replace(self.stop, cwd=str(self.root / "other"))
        target = replace(self.target, profile=str(self.root / "replacement target"))
        for stops, selected, token, now in (
            ([self.stop, self.second], target, plan.approval, 1005),
            ([self.stop, self.second], replace(self.target, launcher_proof="d" * 64), plan.approval, 1005),
            ([self.stop, self.second], replace(self.target, destination="tmux:" + "b" * 64), plan.approval, 1005),
            ([changed, self.second], self.target, plan.approval, 1005),
            ([self.stop], self.target, plan.approval, 1005),
            ([self.stop, self.second], self.target, plan.approval, 1601),
            ([self.stop, self.second], self.target, plan.approval, 999),
            ([self.stop, self.second], self.target, "", 1005),
        ):
            with self.subTest(stops=len(stops), now=now), self.assertRaises(ValueError):
                self.run_batch(stops, token, target=selected, now=now)
        self.assertEqual(self.calls, [])
        self.assertFalse(self.receipts.exists())

    def test_repeated_and_different_approvals_do_not_redispatch(self):
        stops = [self.stop, self.second]
        first = self.run_batch(stops)
        self.assertEqual({x["status"] for x in first}, {"dispatch accepted"})
        self.assertEqual({x[0].cwd for x in self.calls}, {str(self.root / "a coworker's $repo")})
        self.assertEqual({x["status"] for x in self.run_batch(stops)}, {"already reserved"})
        changed_account = replace(self.stop, account="renamed@example.test", repo="other/repo")
        alternate = approval.Target("claude-alternate", str(self.root / "alternate"), "terminal:" + "a" * 64, "c" * 64)
        self.assertEqual({x["status"] for x in self.run_batch([changed_account, self.second], target=alternate)},
                         {"already reserved"})
        self.assertEqual(len(self.calls), 2)
        files = list(self.receipts.glob("*.json"))
        self.assertEqual(len(files), 2)
        self.assertEqual(stat.S_IMODE(self.receipts.stat().st_mode), 0o700)
        for path in files:
            self.assertEqual(stat.S_IMODE(path.stat().st_mode), 0o600)
            data = json.loads(path.read_text())
            self.assertEqual(data["state"], "reserved")
            self.assertEqual(data["target_launcher"], self.target.launcher)

    def test_parallel_approvals_dispatch_once(self):
        workers = 6
        barrier = threading.Barrier(workers)

        def run(i):
            token = approval.make_plan(self.target, [self.stop], 1000 + i).approval
            barrier.wait(timeout=10)
            return self.run_batch([self.stop], token)[0]["status"]

        with concurrent.futures.ThreadPoolExecutor(max_workers=workers) as pool:
            results = list(pool.map(run, range(workers)))
        self.assertEqual(results.count("dispatch accepted"), 1)
        self.assertEqual(results.count("already reserved"), workers - 1)
        self.assertEqual(self.calls, [(self.stop, self.target)])

    def test_ambiguous_dispatch_and_incomplete_receipt_are_holds(self):
        def uncertain(*args):
            self.calls.append(args)
            raise RuntimeError("backend disconnected after receiving the command")

        first = self.run_batch([self.stop], dispatch=uncertain)
        self.assertEqual(first[0]["status"], "dispatch uncertain")
        self.assertEqual(self.run_batch([self.stop])[0]["status"], "already reserved")
        partial = self.receipts / f"{self.second.receipt_key}.json"
        partial.touch(mode=0o600)
        self.assertEqual(self.run_batch([self.second])[0]["status"], "already reserved")
        self.assertEqual(len(self.calls), 1)

    def test_liveness_must_be_confirmed_before_and_after_reservation(self):
        checks = {self.stop.session: 0, self.second.session: 0}

        def verify(stop, _target):
            checks[stop.session] += 1
            return stop == self.stop and checks[stop.session] == 1

        results = {r["session"]: r["status"] for r in self.run_batch([self.stop, self.second], verify=verify)}
        self.assertEqual(results[self.stop.session], "stop changed after reservation")
        self.assertEqual(results[self.second.session], "stop unverified")
        self.assertEqual(self.calls, [])
        self.assertEqual(checks, {self.stop.session: 2, self.second.session: 1})
        self.assertEqual(self.run_batch([self.stop])[0]["status"], "already reserved")
        self.assertEqual(self.run_batch([self.second])[0]["status"], "dispatch accepted")

    def test_insecure_receipt_directory_never_dispatches(self):
        other = self.root / "other"
        other.mkdir()
        self.receipts.symlink_to(other, target_is_directory=True)
        with self.assertRaises(OSError):
            self.run_batch([self.stop])
        self.assertEqual(list(other.iterdir()), [])
        self.receipts.unlink()
        self.receipts.mkdir()
        os.chmod(self.receipts, 0o755)
        with self.assertRaises(PermissionError):
            self.run_batch([self.stop])
        self.assertEqual(self.calls, [])

    def test_worker_requires_matching_reservation_and_consumes_once(self):
        stops = [self.stop, self.second]
        approved = approval.make_plan(self.target, stops, 1000).approval
        self.assertIsNone(approval.consume_worker(self.target, stops, approved, self.stop.session,
                                                  self.receipts, lambda *_: True, now=1005))
        self.run_batch(stops, approved)
        different = approval.make_plan(self.target, stops, 1001).approval
        self.assertIsNone(approval.consume_worker(self.target, stops, different, self.stop.session,
                                                  self.receipts, lambda *_: True, now=1005))
        barrier = threading.Barrier(4)

        def claim(_):
            barrier.wait(timeout=10)
            return approval.consume_worker(self.target, stops, approved, self.stop.session,
                                           self.receipts, lambda *_: True, now=1005)

        with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:
            workers = list(pool.map(claim, range(4)))
        self.assertEqual(workers.count(self.stop), 1)
        self.assertEqual(workers.count(None), 3)
        self.assertEqual(approval.consume_worker(self.target, stops, approved, self.second.session,
                                                 self.receipts, lambda *_: True, now=1005), self.second)

    def test_worker_liveness_change_keeps_the_second_receipt_closed(self):
        stops = [self.stop]
        approved = approval.make_plan(self.target, stops, 1000).approval
        self.run_batch(stops, approved)
        checks = iter([True, False])
        self.assertIsNone(approval.consume_worker(self.target, stops, approved, self.stop.session,
                                                  self.receipts, lambda *_: next(checks), now=1005))
        self.assertIsNone(approval.consume_worker(self.target, stops, approved, self.stop.session,
                                                  self.receipts, lambda *_: True, now=1005))

    def test_a_new_verified_stop_generation_can_be_approved(self):
        fresh = replace(self.stop, generation="cccccccc-cccc-4ccc-8ccc-cccccccccccc")
        with self.assertRaises(ValueError):
            approval.make_plan(self.target, [self.stop, fresh], 1000)
        self.assertEqual(self.run_batch([self.stop])[0]["status"], "dispatch accepted")
        self.assertEqual(self.run_batch([fresh])[0]["status"], "dispatch accepted")
        self.assertEqual(self.run_batch([fresh])[0]["status"], "already reserved")
        self.assertEqual(len(self.calls), 2)
