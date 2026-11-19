"""Exercise provider normalization and filing decisions without remote writes."""

import copy
import datetime as dt
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
from urllib.parse import parse_qs, urlsplit

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("infra_cost_audit", ROOT / ".claude/skills/infra-cost-audit/audit.py")
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)

NOW = dt.datetime(2026, 11, 9, 21, tzinfo=dt.timezone.utc)
REPO = "owner/app"
CFG = {"schema": m.SCHEMA, "vercel": {"scope": "owner"}, "github": {"kind": "user", "account": "owner"},
       "railway": {"workspace": "workspace-a"}, "repositories": [
           {"repo": REPO, "personal": True, "monorepo": True, "allow_filing": True,
            "vercel": {"id": "prj_a", "name": "app-web"}, "railway": "railway-app"}]}


class Fixture:
    def __init__(self):
        self.calls = []
        self.issues = []
        self.private = True
        self.vercel_link = REPO
        self.no_vercel = False
        self.billed_actions = True
        self.old_vercel_cli = False
        self.cost_unit = "USD"
        self.build_unit = "minutes"
        self.preview_count = 70
        self.preview_target = None
        self.merge_count = 5
        self.next_page = None
        self.machine = "turbo"
        self.issue_list_fails = False

    def json(self, tool, *args, body=None):
        self.calls.append((tool, args, body))
        if tool == "vercel" and self.no_vercel:
            raise m.Unavailable("vercel CLI not available")
        if tool == "vercel" and args[0] in {"billing", "usage"}:
            if self.old_vercel_cli and args[0] == "billing":
                raise m.Unavailable("old CLI")
            if args[0] == "billing":
                return {"context": "verified owner scope", "costUnit": self.cost_unit,
                        "period": {"from": "2026-11-01T07:00:00Z", "to": "2026-11-09T21:00:00Z"},
                        "totals": {"cost": 100}, "groupBy": {"dimension": "project", "data": [
                            {"name": "app-web", "totals": {"cost": 60}, "services": [
                                {"name": "Build CPU Minutes", "product": "build-cpu", "quantity": 120,
                                 "unit": self.build_unit, "cost": 12},
                                {"name": "Build Minutes", "product": "build", "quantity": 3,
                                 "unit": "hours", "cost": 3}]}]}}
            # Older releases: pricingQuantity is a cost in pricingUnit, not usage.
            return {"context": "verified owner scope", "pricingUnit": "USD",
                    "period": {"from": "2026-11-01T07:00:00Z", "to": "2026-11-09T21:00:00Z"},
                    "totals": {"billedCost": 100}, "groupBy": {"dimension": "project", "data": [
                        {"name": "app-web", "totals": {"billedCost": 60}, "services": [
                            {"name": "Build CPU Minutes", "pricingQuantity": 120, "pricingUnit": "USD", "billedCost": 12},
                            {"name": "Build Minutes", "pricingQuantity": 180, "pricingUnit": "USD", "billedCost": 3}]}]}}
        if tool == "vercel" and args[1] == "/v9/projects/prj_a":
            org, repo = self.vercel_link.split("/")
            return {"id": "prj_a", "name": "app-web", "resourceConfig": {"buildMachineType": self.machine},
                    "link": {"type": "github", "org": org, "repo": repo},
                    "commandForIgnoringBuildStep": None}
        if tool == "vercel" and args[1].startswith("/v7/deployments?"):
            query = parse_qs(urlsplit(args[1]).query)
            assert query["projectId"] == ["prj_a"] and query["target"] == ["preview"]
            return {"deployments": [{"uid": f"deploy-{i}", "target": self.preview_target} for i in range(self.preview_count)],
                    "pagination": {"next": self.next_page}}
        if tool == "gh" and args[:2] == ("repo", "view"):
            return {"nameWithOwner": REPO, "defaultBranchRef": {"name": "main"}, "isPrivate": self.private}
        if tool == "gh" and args[:2] == ("issue", "list"):
            if self.issue_list_fails:
                raise m.Unavailable("gh request failed")
            return copy.deepcopy(self.issues)
        if tool == "gh" and args[:3] == ("api", "--method", "POST"):
            assert args[3] == "repos/owner/app/issues"
            issue = {"number": 71, **json.loads(body)}
            self.issues.append(issue)
            return {"number": 71, "html_url": "https://github.com/owner/app/issues/71", "body": issue["body"]}
        if tool == "gh" and args[-1].startswith("search/issues?"):
            query = parse_qs(urlsplit(args[-1]).query)["q"][0]
            assert "repo:owner/app is:pr is:merged base:main merged:" in query
            return {"total_count": self.merge_count, "incomplete_results": False}
        if tool == "gh" and "settings/billing/usage?" in args[-1]:
            if not self.billed_actions:
                raise m.Unavailable("gh request failed (HTTP 404)")
            return {"usageItems": [
                {"product": "Actions", "unitType": "minutes", "repositoryName": REPO, "quantity": 25, "netAmount": 2},
                {"product": "Actions", "unitType": "minutes", "repositoryName": "owner/other", "quantity": 60, "netAmount": 4},
                {"product": "Actions", "unitType": "gigabytes", "repositoryName": REPO, "quantity": 11, "netAmount": 1}]}
        if tool == "railway":
            assert "--workspace" in args and "workspace-a" in args
            return {"workspace": {"id": "workspace-a"}, "projects": [
                {"id": "railway-app", "name": "app", "currentUsageDollars": 3.25}]}
        raise AssertionError((tool, args))

    def posts(self):
        return [args for tool, args, _ in self.calls if tool == "gh" and args[:3] == ("api", "--method", "POST")]


class AuditTest(unittest.TestCase):
    def collect(self, f, cfg=None, baseline=None, apply=False):
        return m.audit(f, m.config(copy.deepcopy(cfg or CFG)), "2026-11", NOW, baseline, apply)

    def test_provider_metrics_and_read_only_preview(self):
        f = Fixture()
        r = self.collect(f)["repositories"][0]
        metrics = r["vercel_usage"]["data"]["build_metrics"]
        self.assertEqual(metrics["Build CPU Minutes"]["hours"], 2)
        self.assertEqual(metrics["Build Minutes"]["hours"], 3)
        self.assertEqual(r["github_actions"]["data"]["actions_minutes"], 25)
        self.assertEqual(r["github_actions"]["data"]["actions_net_amount_usd"], 2)
        self.assertEqual(r["railway"]["data"]["project_current_usage_usd"], m.Decimal("3.25"))
        self.assertEqual({x["code"] for x in r["findings"]},
                         {"vercel_premium_machine", "vercel_dashboard_ignore_missing", "vercel_preview_volume"})
        self.assertEqual(r["filing"]["data"]["decision"], "preview")
        self.assertIn("70 preview deployments", r["filing"]["data"]["body"])
        self.assertEqual(f.posts(), [])

    def test_cost_share_requires_compatible_prior_scope(self):
        f = Fixture()
        old = self.collect(f)
        old["observed_at"] = "2026-10-09T21:00:00Z"
        old["repositories"][0]["vercel_usage"]["data"]["provider_billed_cost"]["data"]["share"] = "0.2"
        r = self.collect(f, baseline=old)["repositories"][0]
        self.assertIn("vercel_cost_share_jump", {x["code"] for x in r["findings"]})
        old["provider_scopes"]["vercel"] = "different"
        r = self.collect(f, baseline=old)["repositories"][0]
        self.assertNotIn("vercel_cost_share_jump", {x["code"] for x in r["findings"]})

    def test_cost_share_requires_the_same_mapped_project(self):
        f = Fixture()
        old = self.collect(f)
        old["observed_at"] = "2026-10-09T21:00:00Z"
        row = old["repositories"][0]
        row["vercel_usage"]["data"]["provider_billed_cost"]["data"]["share"] = "0.2"
        row["railway"]["data"]["cost_share"]["share"] = "0.4"
        row["provider_projects"]["vercel"] = "prj_previous"
        row["provider_projects"]["railway"] = "railway-previous"
        codes = {x["code"] for x in self.collect(f, baseline=old)["repositories"][0]["findings"]}
        self.assertNotIn("vercel_cost_share_jump", codes)
        self.assertNotIn("railway_cost_share_jump", codes)

    def test_cost_share_requires_a_like_billing_period(self):
        f = Fixture()
        old = self.collect(f)
        old["observed_at"] = "2026-10-31T23:00:00Z"
        row = old["repositories"][0]
        row["github_actions"]["data"]["cost_share"]["share"] = "0.1"
        # A completed baseline month never compares with a month-to-date run.
        old["provider_periods"]["github"]["complete"] = True
        codes = {x["code"] for x in self.collect(f, baseline=old)["repositories"][0]["findings"]}
        self.assertNotIn("github_cost_share_jump", codes)
        # Two partial windows of different length do not compare either.
        old["provider_periods"]["github"].update(complete=False, elapsed_days="30")
        codes = {x["code"] for x in self.collect(f, baseline=old)["repositories"][0]["findings"]}
        self.assertNotIn("github_cost_share_jump", codes)
        # A baseline without recorded periods is not comparable.
        del old["provider_periods"]
        codes = {x["code"] for x in self.collect(f, baseline=old)["repositories"][0]["findings"]}
        self.assertNotIn("github_cost_share_jump", codes)

    def test_unrecognized_machine_value_is_reported_not_classified(self):
        f = Fixture()
        f.machine = "14cpu-28gb"
        r = self.collect(f)["repositories"][0]
        data = r["vercel_settings"]["data"]
        self.assertIsNone(data["machine"])
        self.assertEqual(data["machine_reported"], "14cpu-28gb")
        self.assertNotIn("vercel_premium_machine", {x["code"] for x in r["findings"]})

    def test_preview_survives_a_failed_github_check_but_filing_does_not(self):
        f = Fixture()
        f.issue_list_fails = True
        plan = self.collect(f)["repositories"][0]["filing"]["data"]
        self.assertEqual(plan["decision"], "preview")
        self.assertEqual(plan["dedup"]["status"], "unavailable")
        self.assertEqual(self.collect(f, apply=True)["repositories"][0]["filing"]["status"], "unavailable")
        self.assertFalse(f.posts())

    def test_railway_receives_the_requested_month_label(self):
        f = Fixture()
        self.collect(f)
        calls = [args for tool, args, _ in f.calls if tool == "railway"]
        self.assertEqual(len(calls), 1)
        self.assertEqual(calls[0][calls[0].index("--period") + 1], "2026-11")

    def test_actions_and_railway_compare_their_own_reported_costs(self):
        f = Fixture()
        old = self.collect(f)
        old["observed_at"] = "2026-10-09T21:00:00Z"
        row = old["repositories"][0]
        row["github_actions"]["data"]["cost_share"]["share"] = "0.1"
        row["railway"]["data"]["cost_share"]["share"] = "0.4"
        r = self.collect(f, baseline=old)["repositories"][0]
        codes = {x["code"] for x in r["findings"]}
        self.assertIn("github_cost_share_jump", codes)
        self.assertIn("railway_cost_share_jump", codes)

    def test_no_vercel_or_actions_usage_is_not_zero(self):
        f = Fixture()
        f.no_vercel = True
        f.billed_actions = False
        r = self.collect(f)["repositories"][0]
        self.assertEqual(r["vercel_usage"]["status"], "unavailable")
        self.assertEqual(r["github_actions"]["status"], "unavailable")
        self.assertEqual(r["railway"]["status"], "ok")
        self.assertEqual(r["findings"], [])
        with tempfile.TemporaryDirectory() as tmp, patch.dict("os.environ", {"PATH": ""}):
            with self.assertRaisesRegex(m.Unavailable, "vercel CLI not available"):
                m.Runner({}, tmp).tool("vercel")

    def test_mismatched_project_link_cannot_generate_or_file_findings(self):
        f = Fixture()
        f.vercel_link = "owner/other"
        r = self.collect(f, apply=True)["repositories"][0]
        self.assertEqual(r["vercel_settings"]["status"], "unavailable")
        self.assertEqual(r["findings"], [])
        self.assertFalse(f.posts())

    def test_repeated_filing_only_creates_one_issue(self):
        f = Fixture()
        one = self.collect(f, apply=True)["repositories"][0]["filing"]["data"]
        two = self.collect(f, apply=True)["repositories"][0]["filing"]["data"]
        self.assertEqual(one["decision"], "filed")
        self.assertEqual(two, {"decision": "existing_open_issue", "numbers": [71]})
        self.assertEqual(len(f.posts()), 1)

    def test_existing_related_issue_blocks_filing(self):
        f = Fixture()
        f.issues = [{"number": 19, "title": "Tracked elsewhere", "body": ""}]
        cfg = copy.deepcopy(CFG)
        cfg["repositories"][0]["related_issues"] = [19]
        self.assertEqual(self.collect(f, cfg, apply=True)["repositories"][0]["filing"]["data"]["numbers"], [19])
        self.assertFalse(f.posts())

    def test_public_repo_and_incomplete_dedup_never_file(self):
        f = Fixture()
        f.private = False
        self.assertEqual(self.collect(f)["repositories"][0]["filing"]["data"]["decision"], "preview")
        self.assertEqual(self.collect(f, apply=True)["repositories"][0]["filing"]["data"]["decision"],
                         "private_repo_required")
        f.private = True
        f.issues = [{"number": i, "title": "Other", "body": ""} for i in range(1, 101)]
        self.assertEqual(self.collect(f, apply=True)["repositories"][0]["filing"]["status"], "unavailable")
        self.assertFalse(f.posts())

    def test_explicit_apply_respects_repo_opt_in(self):
        f = Fixture()
        cfg = copy.deepcopy(CFG)
        cfg["repositories"][0]["allow_filing"] = False
        r = self.collect(f, cfg, apply=True)["repositories"][0]
        self.assertEqual(r["filing"]["data"]["decision"], "filing_not_allowed_for_repo")
        self.assertFalse(f.posts())

    def test_snapshot_is_private_and_never_overwrites_a_baseline(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "snapshot.json"
            m.write_snapshot(path, '{"first":true}')
            self.assertEqual(path.stat().st_mode & 0o777, 0o600)
            self.assertEqual(m.private_json(path), {"first": True})
            with self.assertRaises(m.Unavailable):
                m.write_snapshot(path, '{"first":false}')
            self.assertEqual(m.private_json(path), {"first": True})
            path.chmod(0o644)
            with self.assertRaises(m.Unavailable):
                m.private_json(path)

    def test_preview_query_does_not_count_a_production_deployment(self):
        f = Fixture()
        f.preview_target = "production"
        row = self.collect(f)["repositories"][0]
        self.assertEqual(row["preview_activity"]["status"], "unavailable")
        self.assertNotIn("vercel_preview_volume", {x["code"] for x in row["findings"]})
        self.assertIn("vercel_premium_machine", {x["code"] for x in row["findings"]})

    def test_older_vercel_cli_and_invalid_cursor(self):
        f = Fixture()
        f.old_vercel_cli = True
        f.next_page = int(NOW.timestamp() * 1000)
        r = self.collect(f)["repositories"][0]
        self.assertEqual(r["vercel_usage"]["status"], "ok")
        self.assertEqual(r["preview_activity"]["status"], "unavailable")
        self.assertNotIn("vercel_preview_volume", {x["code"] for x in r["findings"]})
        # The older schema's pricingQuantity is a cost, so it never becomes minutes.
        metric = r["vercel_usage"]["data"]["build_metrics"]["Build CPU Minutes"]
        self.assertIsNone(metric["minutes"])
        self.assertEqual(metric["provider_billed_amount"], {"amount": 12, "unit": "USD"})

    def test_vercel_build_units_and_cost_units_are_read_from_their_fields(self):
        f = Fixture()
        f.build_unit = "Credits"
        f.cost_unit = "managed_infrastructure_units"
        data = self.collect(f)["repositories"][0]["vercel_usage"]["data"]
        cpu = data["build_metrics"]["Build CPU Minutes"]
        self.assertIsNone(cpu["minutes"])
        self.assertEqual((cpu["quantity"], cpu["unit"]), (120, "Credits"))
        self.assertEqual(cpu["provider_billed_amount"]["unit"], "MIU")
        self.assertEqual(data["build_metrics"]["Build Minutes"]["minutes"], 180)
        self.assertEqual(data["provider_billed_cost"]["data"]["unit"], "MIU")
        f.cost_unit = "EUR"
        data = self.collect(f)["repositories"][0]["vercel_usage"]["data"]
        self.assertEqual(data["provider_billed_cost"]["status"], "unavailable")
        self.assertNotIn("provider_billed_amount", data["build_metrics"]["Build Minutes"])


if __name__ == "__main__":
    unittest.main()
