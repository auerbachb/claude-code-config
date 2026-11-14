#!/usr/bin/env python3
# catalog: tests — Verify workflow-scoped CI evidence, queued runs, reruns and fail-closed snapshot collection
"""Offline workflow-identity regressions for Issue 2316 (Python 3.9+)."""
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

SCRIPTS = Path(__file__).resolve().parents[1] / ".claude" / "scripts"
spec = importlib.util.spec_from_file_location("check_run_workflows", SCRIPTS / "lib/check_run_workflows.py")
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
HEAD = "a" * 40


def workflow(run_id, workflow_id=10, event="push", status="completed", conclusion="success"):
    return {"id": run_id, "run_attempt": 1, "run_started_at": "2026-11-13T12:{:02d}:00Z".format(run_id), "workflow_id": workflow_id, "event": event, "head_sha": HEAD,
            "head_branch": "feature", "pull_requests": ([{"number": 7, "base": {"ref": "main", "repo": {"id": 1}}}] if event == "pull_request" else []),
            "html_url": "https://github.com/example/repo/actions/runs/{}".format(run_id),
            "check_suite_id": run_id * 10, "path": ".github/workflows/{}.yml".format(workflow_id),
            "status": status, "conclusion": conclusion}


def check(run, check_id=None, status=None, conclusion="same"):
    return {"id": check_id or run["id"] * 100, "name": "test",
            "status": status or run["status"], "conclusion": run["conclusion"] if conclusion == "same" else conclusion,
            "app": {"slug": "github-actions", "id": 15368}, "check_suite": {"id": run["check_suite_id"]},
            "details_url": run["html_url"] + "/job/{}".format(check_id or run["id"] * 100)}


class WorkflowEvidenceTests(unittest.TestCase):
    def gate(self, checks, workflows, names="", head_epoch=None):
        normalized = module.normalize(checks, workflows, HEAD)
        with tempfile.TemporaryDirectory() as home:
            Path(home, ".claude").mkdir()
            env = dict(os.environ, HOME=home)
            deduped = subprocess.check_output([str(SCRIPTS / "check-runs-dedup.sh")], input=json.dumps(normalized), text=True, env=env)
            command = [str(SCRIPTS / "review-request-gate.sh"), "--setting", "after-ci", "--head", HEAD, "--checks", names]
            if head_epoch is not None:
                command.extend(["--head-epoch", str(head_epoch)])
            output = subprocess.check_output(command, input=deduped, text=True, env=env)
        return json.loads(output), json.loads(deduped)

    def test_newer_other_workflow_success_does_not_hide_running_test(self):
        old = workflow(1, status="in_progress", conclusion=None)
        new = workflow(2, workflow_id=20)
        result, runs = self.gate([check(old), check(new)], [old, new])
        self.assertEqual(result["decision"], "wait")
        self.assertEqual(len([r for r in runs if r["name"] == "test"]), 2)

    def test_named_checks_preserve_distinct_workflow_results(self):
        old = workflow(1, status="in_progress", conclusion=None)
        new = workflow(2, workflow_id=20)
        result, _ = self.gate([check(old), check(new)], [old, new], names="test")
        self.assertEqual(result["decision"], "wait")

    def test_push_and_pull_request_are_distinct_executions(self):
        push = workflow(1, status="queued", conclusion=None)
        pr = workflow(2, event="pull_request")
        result, _ = self.gate([check(pr)], [push, pr])
        self.assertEqual(result["decision"], "wait")

    def test_latest_completed_same_scope_execution_supersedes_old_failure(self):
        old = workflow(1, conclusion="failure")
        new = workflow(2)
        result, runs = self.gate([check(old), check(new)], [old, new])
        self.assertEqual(result["decision"], "request")
        self.assertFalse(any(r.get("_actions_run_id") == 1 for r in runs))

    def test_queued_replacement_keeps_named_check_pending_after_grace(self):
        for retry in (False, True):
            with self.subTest(manual_retry=retry):
                old = workflow(2, conclusion="failure")
                new = workflow(1 if retry else 3, status="queued", conclusion=None)
                if retry:
                    new.update(run_attempt=2, run_started_at="2026-11-13T13:00:00Z")
                result, runs = self.gate([check(old)], [old, new], names="test", head_epoch=1)
                self.assertEqual(result["decision"], "wait")
                pending = [r for r in runs if r["name"] == "test"]
                self.assertEqual(len(pending), 1)
                self.assertIsNone(pending[0]["id"])
                self.assertEqual(pending[0]["_actions_run_id"], new["id"])
                result, _ = self.gate([check(old), check(new, status="completed", conclusion="success")],
                                      [old, new], names="test", head_epoch=1)
                self.assertEqual(result["decision"], "request")
                new.update(status="completed", conclusion="success")
                result, _ = self.gate([check(old)], [old, new], names="test", head_epoch=1)
                self.assertEqual(result["decision"], "request")

    def test_pending_name_does_not_cross_workflow_or_publisher(self):
        old = workflow(1, conclusion="failure")
        new = workflow(2, status="queued", conclusion=None)
        unrelated = workflow(3, workflow_id=20)
        different_app = dict(check(new, status="completed", conclusion="success"),
                             app={"slug": "github-actions", "id": 99})
        result, _ = self.gate([check(old), check(unrelated), different_app], [old, new, unrelated],
                              names="test", head_epoch=1)
        self.assertEqual(result["decision"], "wait")

    def test_inventory_ids_are_not_diagnostic_check_ids(self):
        for status, conclusion, expected_code in (("queued", None, 1), ("completed", "failure", 3)):
            with self.subTest(status=status):
                run = workflow(1, status=status, conclusion=conclusion)
                normalized = module.normalize([], [run], HEAD)
                self.assertIsNone(normalized[0]["id"])
                self.assertEqual(normalized[0]["_actions_run_id"], run["id"])
                output = self.snapshot([], [run], consumer="ci-status.sh")
                self.assertEqual(output.returncode, expected_code, output.stderr)
                data = json.loads(output.stdout)
                entries = data["in_progress_runs"] if status == "queued" else data["blocking"]
                self.assertTrue(entries)
                self.assertIsNone(entries[0]["id"])

    def test_newer_first_attempt_keeps_older_unfinished_same_scope(self):
        old = workflow(1, status="in_progress", conclusion=None)
        new = workflow(2)
        result, runs = self.gate([check(old), check(new)], [old, new])
        self.assertEqual(result["decision"], "wait")
        self.assertEqual({r["_actions_run_id"] for r in runs}, {1, 2})

    def test_newer_manual_retry_keeps_older_unfinished_first_attempt(self):
        old = workflow(1, status="queued", conclusion=None)
        new = workflow(2)
        new.update(run_attempt=2, run_started_at="2026-11-13T13:00:00Z")
        result, _ = self.gate([check(old), check(new)], [old, new])
        self.assertEqual(result["decision"], "wait")

    def test_retried_older_run_id_is_not_hidden_by_newer_green_id(self):
        retry = workflow(1, status="in_progress", conclusion=None)
        retry.update(run_attempt=2, run_started_at="2026-11-13T13:00:00Z")
        green = workflow(2)
        result, runs = self.gate([check(retry), check(green)], [retry, green])
        self.assertEqual(result["decision"], "wait")
        self.assertTrue(any(r.get("_actions_run_id") == 1 for r in runs))

    def test_completed_retry_uses_latest_attempt_start_not_original_id(self):
        retry = workflow(1, conclusion="failure")
        retry.update(run_attempt=2, run_started_at="2026-11-13T13:00:00Z")
        green = workflow(2)
        result, _ = self.gate([check(retry), check(green)], [retry, green])
        self.assertEqual(result["decision"], "none")
        green["run_started_at"] = "2026-11-13T14:00:00Z"
        result, _ = self.gate([check(retry), check(green)], [retry, green])
        self.assertEqual(result["decision"], "request")

    def test_retry_with_missing_start_is_retained_alongside_green_run(self):
        retry = workflow(1, status="queued", conclusion=None)
        retry["run_attempt"] = 2
        del retry["run_started_at"]
        green = workflow(2)
        result, runs = self.gate([check(retry), check(green)], [retry, green])
        self.assertEqual(result["decision"], "wait")
        self.assertEqual(len([r for r in runs if r["name"] == "test"]), 2)

    def test_matrix_siblings_are_retained(self):
        run = workflow(1, conclusion="failure")
        result, checks = self.gate([check(run, 100, conclusion="success"), check(run, 101, conclusion="failure")], [run])
        self.assertEqual(result["reason"], "ci_failed")
        self.assertEqual(len([r for r in checks if r["name"] == "test"]), 2)

    def test_queued_workflow_without_aggregate_is_pending(self):
        result, _ = self.gate([], [workflow(1, status="queued", conclusion=None)])
        self.assertEqual(result["decision"], "wait")

    def test_eventual_all_green(self):
        runs = [workflow(1), workflow(2, workflow_id=20), workflow(3, event="pull_request")]
        result, _ = self.gate([check(run) for run in runs], runs)
        self.assertEqual(result["decision"], "request")

    def test_unknown_job_identity_fails_closed(self):
        with self.assertRaises(ValueError):
            module.normalize([check(workflow(1))], [workflow(2)], HEAD)

    def test_conflicting_url_and_suite_fail_closed(self):
        first, second = workflow(1), workflow(2)
        job = check(first)
        job["details_url"] = second["html_url"] + "/job/100"
        with self.assertRaises(ValueError):
            module.normalize([job], [first, second], HEAD)

    def test_check_head_mismatch_fails_closed(self):
        run = workflow(1)
        job = dict(check(run), head_sha="b" * 40)
        with self.assertRaises(ValueError):
            module.normalize([job], [run], HEAD)

    def test_mismatched_head_fails_closed(self):
        run = workflow(1)
        run["head_sha"] = "b" * 40
        with self.assertRaises(ValueError):
            module.normalize([], [run], HEAD)

    def test_missing_pr_scope_never_proves_rerun(self):
        old = workflow(1, event="pull_request", conclusion="failure")
        new = workflow(2, event="pull_request")
        old["pull_requests"], new["pull_requests"] = [], []
        result, _ = self.gate([check(old), check(new)], [old, new])
        self.assertEqual(result["reason"], "ci_failed")

    def test_dispatch_inputs_not_available_cannot_prove_supersession(self):
        old = workflow(1, event="workflow_dispatch", conclusion="failure")
        new = workflow(2, event="workflow_dispatch")
        result, _ = self.gate([check(old), check(new)], [old, new])
        self.assertEqual(result["decision"], "none")

    def test_malformed_pr_identity_fails_closed(self):
        run = workflow(1, event="pull_request")
        run["pull_requests"] = [None]
        with self.assertRaises(ValueError):
            module.normalize([], [run], HEAD)

    def test_partial_pr_scope_never_proves_rerun(self):
        old = workflow(1, event="pull_request", conclusion="failure")
        new = workflow(2, event="pull_request")
        for run in [old, new]:
            del run["pull_requests"][0]["base"]["repo"]
        result, _ = self.gate([check(old), check(new)], [old, new])
        self.assertEqual(result["reason"], "ci_failed")

    def test_unknown_completed_conclusion_is_not_green(self):
        run = workflow(1, conclusion="future_state")
        result, _ = self.gate([check(run)], [run])
        self.assertEqual(result["decision"], "none")

    def test_duplicate_pagination_cannot_mask_missing_execution(self):
        with tempfile.NamedTemporaryFile(mode="w", encoding="utf-8") as handle:
            json.dump({"total_count": 2, "workflow_runs": [workflow(1), workflow(1)]}, handle)
            handle.flush()
            with self.assertRaises(ValueError):
                module.pages(handle.name, "workflow_runs")

    def snapshot(self, checks, workflows, failure="", consumer=None):
        with tempfile.TemporaryDirectory() as root:
            root = Path(root)
            (root / ".claude").mkdir()
            (root / "checks.json").write_text(json.dumps({"total_count": len(checks), "check_runs": checks}))
            (root / "workflows.json").write_text(json.dumps({"total_count": len(workflows), "workflow_runs": workflows}))
            gh = root / "gh"
            gh.write_text("""#!/usr/bin/env bash
case "$*" in
  *check-runs*)
    if [[ "$FAILURE" == checks404 ]]; then echo 'HTTP 404 test marker' >&2; exit 1; fi
    cat "$HOME/checks.json" ;;
  *actions/runs*)
    if [[ "$FAILURE" == workflows ]]; then echo 'private upstream diagnostic' >&2; exit 1; fi
    cat "$HOME/workflows.json" ;;
  'repo view'*) echo example/repo ;;
  *) exit 99 ;;
esac
""")
            gh.chmod(0o755)
            env = dict(os.environ, HOME=str(root), FAILURE=failure, PATH=str(root) + os.pathsep + os.environ["PATH"])
            command = [str(SCRIPTS / "check-runs-snapshot.sh"), "--head", HEAD, "--repo", "example/repo"]
            if consumer:
                command = [str(SCRIPTS / consumer), HEAD, "--format", "json"]
            return subprocess.run(command, text=True, capture_output=True, env=env)

    def test_live_snapshot_shared_ci_consumer_keeps_running_workflow(self):
        old = workflow(1, status="in_progress", conclusion=None)
        new = workflow(2, workflow_id=20)
        result = self.snapshot([check(old), check(new)], [old, new], consumer="ci-status.sh")
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertGreater(json.loads(result.stdout)["in_progress"], 0)

    def test_live_snapshot_rejects_unavailable_workflow_inventory(self):
        result = self.snapshot([], [], failure="workflows")
        self.assertEqual(result.returncode, 5)
        self.assertNotIn("private upstream", result.stderr)
        self.assertEqual(result.stdout, "")

    def test_live_snapshot_preserves_commit_not_found_contract(self):
        result = self.snapshot([], [], failure="checks404", consumer="ci-status.sh")
        self.assertEqual(result.returncode, 4, result.stderr)

    def test_live_snapshot_valid_empty_inventory(self):
        result = self.snapshot([], [])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout), [])

    def test_status_cannot_prove_a_required_app_pin(self):
        status = [{"context": "aggregate", "state": "success"}]
        cases = [({"aggregate": 15368}, [], False), ({}, [], True),
                 ({"aggregate": 15368}, [{"name": "aggregate", "app": {"id": 15368},
                                           "status": "completed", "conclusion": "success"}], True)]
        for apps, runs, expected in cases:
            with self.subTest(apps=apps, runs=runs):
                output = subprocess.check_output(["jq", "-cn", "-L", str(SCRIPTS / "lib"),
                    "--argjson", "req", '["aggregate"]', "--argjson", "apps", json.dumps(apps),
                    "--argjson", "runs", json.dumps({"check_runs": runs}), "--argjson", "statuses", json.dumps(status),
                    "-f", str(SCRIPTS / "lib/required-context-state.jq")], text=True)
                self.assertEqual(json.loads(output)[0]["satisfied"], expected)

    def test_required_branch_path_encodes_reserved_characters(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            stub = root / "gh"
            stub.write_text("#!/bin/sh\nprintf '%s\\n' \"$2\" >> \"$API_LOG\"\n"
                            "case \"$2\" in\n"
                            "  */protection/required_status_checks) printf '%s\\n' '{\"contexts\":[\"aggregate\"]}' ;;\n"
                            "  *) printf '%s\\n' '{\"name\":\"release/2.0#safe%\",\"protected\":true}' ;;\nesac\n")
            stub.chmod(0o755)
            log = root / "calls"
            env = dict(os.environ, PATH=str(root) + os.pathsep + os.environ["PATH"], API_LOG=str(log))
            result = subprocess.run([str(SCRIPTS / "required-checks.sh"), "--repo", "example/repo",
                                     "--base", "release/2.0#safe%"], env=env, text=True, capture_output=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(json.loads(result.stdout)["contexts"], ["aggregate"])
            base = "repos/example/repo/branches/release%2F2.0%23safe%25"
            self.assertEqual(log.read_text().splitlines(), [base, base + "/protection/required_status_checks"])

    def test_workflow_inventory_never_impersonates_a_required_check(self):
        inventory = {"name": "aggregate", "status": "completed", "conclusion": "success", "_workflow_inventory": True}
        output = subprocess.check_output(["jq", "-cn", "-L", str(SCRIPTS / "lib"),
            "--argjson", "req", '["aggregate"]', "--argjson", "apps", "{}",
            "--argjson", "runs", json.dumps({"check_runs": [inventory]}), "--argjson", "statuses", "[]",
            "-f", str(SCRIPTS / "lib/required-context-state.jq")], text=True)
        self.assertEqual(json.loads(output), [{"context": "aggregate", "state": "absent", "satisfied": False}])

    def test_truncated_workflow_inventory_fails_closed(self):
        with tempfile.NamedTemporaryFile(mode="w", encoding="utf-8") as handle:
            json.dump({"total_count": 2, "workflow_runs": [workflow(1)]}, handle)
            handle.flush()
            with self.assertRaises(ValueError):
                module.pages(handle.name, "workflow_runs")


if __name__ == "__main__":
    unittest.main()
