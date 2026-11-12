#!/usr/bin/env bash
# hook-scripts-macos-after-merge.test.sh — Workflow-contract test for the macOS hook
# tests running after merge only (issue #2265).
#
# WHAT IS UNDER TEST
#   .github/workflows/hook-scripts.yml, parsed with PyYAML and checked as data:
#     - on pull_request the macOS plan is skipped (its `if` admits push only), so the
#       shards are skipped with it and no macOS runner is queued;
#     - the aggregate `hook-tests-macos` still reports and passes on a pull_request
#       with the "run after merge" notice, and on push it passes only when the plan
#       and every shard succeeded;
#     - `hook-tests-macos-report` runs only on push after a failed macOS aggregate,
#       holds `issues: write` as its only permission, and never interpolates
#       `${{ }}` into a run script (values travel through env);
#     - the workflow-level permissions stay `contents: read`, and no other job gains
#       `issues: write`;
#     - the Linux and Python jobs carry no event gate (they still run on PRs);
#     - the shard that uploads the failing-suite list does so only after a failure,
#       and the runner's contract is written through SUMMARY_CONTRACT_FILE.
#
# NEGATIVE CONTROLS
#   The same checker runs against in-memory mutations of the real workflow (plan not
#   gated, aggregate failing on PR, report job with extra permissions, a PR-gated Linux
#   job, interpolation in the report script). Each must be rejected.
#
# WHAT THIS CANNOT PROVE
#   That GitHub skips the jobs and files the issue. That is CI evidence from the PR run
#   and the first push to main after merge.
#
# PyYAML is a hard dependency; a missing module fails rather than skips.

set -uo pipefail

REPO_ROOT="$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)" || {
  echo "FAIL: cannot resolve repo root from ${BASH_SOURCE[0]}" >&2
  exit 1
}
WORKFLOW="$REPO_ROOT/.github/workflows/hook-scripts.yml"

if ! command -v python3 >/dev/null 2>&1; then
  echo "FAIL: python3 not found — required to parse $WORKFLOW" >&2
  exit 1
fi
if ! python3 -c 'import yaml' 2>/dev/null; then
  echo "FAIL: PyYAML not importable by python3 — install it (pip install PyYAML); this test never skips" >&2
  exit 1
fi
if [ ! -f "$WORKFLOW" ]; then
  echo "FAIL: workflow not found: $WORKFLOW" >&2
  exit 1
fi

python3 - "$WORKFLOW" <<'PY'
import copy
import re
import sys

import yaml

WORKFLOW_PATH = sys.argv[1]
PUSH_GATE = "github.event_name == 'push'"
NOTICE = "macOS hook tests run after merge on main (issue #2265)"
REPORT_GATE = "always() && github.event_name == 'push' && needs.hook-tests-macos.result == 'failure'"
EXPR = re.compile(r"\$\{\{.*?\}\}", re.S)


def run_blocks(job):
    return [s.get("run", "") for s in job.get("steps", []) if isinstance(s, dict)]


AGG_CASES = [
    # (event, plan result, shard result, expected pass)
    ("pull_request", "skipped", "skipped", True),
    ("push", "success", "success", True),
    ("push", "skipped", "skipped", False),
    ("push", "success", "failure", False),
    ("push", "failure", "success", False),
    ("push", "success", "cancelled", False),
]


def aggregate_behaviour(run):
    """Execute the aggregate's run script per case; a PR must pass with the notice, main must gate."""
    import os
    import subprocess

    errs = []
    for event, plan, shard, want_pass in AGG_CASES:
        env = {
            "PATH": os.environ.get("PATH", "/usr/bin:/bin"),
            "EVENT_NAME": event,
            "PLAN_RESULT": plan,
            "SHARD_RESULT": shard,
        }
        res = subprocess.run(["bash", "-c", run], env=env, capture_output=True, text=True)
        passed = res.returncode == 0
        if passed != want_pass:
            errs.append(f"aggregate on {event} plan={plan} shards={shard} exited {res.returncode}, expected {'pass' if want_pass else 'fail'}")
        elif event == "pull_request" and NOTICE not in res.stdout:
            errs.append("aggregate on pull_request passes without the run-after-merge notice")
    return errs


def check(doc):
    """Return a list of contract violations (empty = pass)."""
    errors = []
    if not isinstance(doc, dict):
        return ["workflow document is not a mapping"]
    jobs = doc.get("jobs") or {}

    if doc.get("permissions") != {"contents": "read"}:
        errors.append(f"workflow permissions must be exactly contents: read, got {doc.get('permissions')!r}")

    for job_id, job in jobs.items():
        if not isinstance(job, dict):
            errors.append(f"job {job_id!r} is not a mapping")
            continue
        perms = job.get("permissions")
        if job_id != "hook-tests-macos-report" and isinstance(perms, dict) and "issues" in perms:
            errors.append(f"job {job_id!r} grants issues: {perms['issues']!r}; only the report job may")

    plan = jobs.get("hook-tests-macos-plan") or {}
    if plan.get("if") != PUSH_GATE:
        errors.append(f"hook-tests-macos-plan must be gated `if: {PUSH_GATE}`, got {plan.get('if')!r}")

    shard = jobs.get("hook-tests-macos-shard") or {}
    if shard.get("needs") != "hook-tests-macos-plan":
        errors.append(f"hook-tests-macos-shard must need only the plan, got {shard.get('needs')!r}")

    agg = jobs.get("hook-tests-macos") or {}
    if agg.get("if") != "always()":
        errors.append(f"hook-tests-macos must stay `if: always()`, got {agg.get('if')!r}")
    agg_steps = [s for s in agg.get("steps", []) if isinstance(s, dict) and "run" in s]
    agg_env = (agg_steps[0].get("env") or {}) if agg_steps else {}
    if agg_env.get("EVENT_NAME") != "${{ github.event_name }}":
        errors.append("hook-tests-macos does not receive github.event_name through a step env")
    if agg_steps:
        errors.extend(aggregate_behaviour(agg_steps[0]["run"]))
    else:
        errors.append("hook-tests-macos has no run step")

    report = jobs.get("hook-tests-macos-report")
    if not isinstance(report, dict):
        errors.append("hook-tests-macos-report job is missing")
    else:
        if report.get("needs") != ["hook-tests-macos"]:
            errors.append(f"report job must need only hook-tests-macos, got {report.get('needs')!r}")
        cond = str(report.get("if", ""))
        if cond != REPORT_GATE:
            errors.append(f"report job gate must be exactly {REPORT_GATE!r}, got {cond!r}")
        if report.get("concurrency") != {"group": "hook-tests-macos-report", "cancel-in-progress": False}:
            errors.append(f"report job must serialize on the constant main-only group, got {report.get('concurrency')!r}")
        if report.get("permissions") != {"issues": "write"}:
            errors.append(f"report job permissions must be exactly issues: write, got {report.get('permissions')!r}")
        for block in run_blocks(report):
            if EXPR.search(block):
                errors.append("report job interpolates ${{ }} inside a run script; pass values through env")
        if "gh issue create" not in " ".join(run_blocks(report)):
            errors.append("report job does not file a new issue")
        if "gh issue comment" not in " ".join(run_blocks(report)):
            errors.append("report job does not comment on an existing issue")

    upload_steps = [
        s for s in (shard.get("steps") or [])
        if isinstance(s, dict) and str(s.get("uses", "")).startswith("actions/upload-artifact@")
    ]
    if len(upload_steps) != 1 or upload_steps[0].get("if") != "failure()":
        errors.append("the macOS shard must upload its failing-suite list in exactly one `if: failure()` step")

    shard_steps = [s for s in (shard.get("steps") or []) if isinstance(s, dict)]
    runner_steps = [s for s in shard_steps if "run-hook-tests.sh" in str(s.get("run", ""))]
    if not runner_steps or "SUMMARY_CONTRACT_FILE" not in (runner_steps[0].get("env") or {}):
        errors.append("the macOS bash runner step does not set SUMMARY_CONTRACT_FILE")

    for job_id in ("hook-tests-plan", "hook-tests-shard", "hook-tests", "hook-tests-py39"):
        job = jobs.get(job_id)
        if not isinstance(job, dict):
            errors.append(f"Linux/Python job {job_id!r} is missing")
        elif "event_name" in str(job.get("if", "")):
            errors.append(f"Linux/Python job {job_id!r} gained an event gate: {job['if']!r}")

    return errors


with open(WORKFLOW_PATH, encoding="utf-8") as fh:
    real = yaml.safe_load(fh)

failures = 0
passes = 0


def ok(msg):
    global passes
    passes += 1
    print(f"PASS: {msg}")


def bad(msg):
    global failures
    failures += 1
    print(f"FAIL: {msg}")


errs = check(real)
if errs:
    for e in errs:
        bad(f"shipped workflow: {e}")
else:
    ok("shipped hook-scripts.yml gates macOS to main and reports the failure issue")


def mutate(fn):
    doc = copy.deepcopy(real)
    fn(doc)
    return doc


def drop_plan_gate(d):
    d["jobs"]["hook-tests-macos-plan"].pop("if", None)


def report_extra_perm(d):
    d["jobs"]["hook-tests-macos-report"]["permissions"]["contents"] = "write"


def linux_pr_gate(d):
    d["jobs"]["hook-tests-plan"]["if"] = "github.event_name == 'push'"


def report_interpolates(d):
    steps = d["jobs"]["hook-tests-macos-report"]["steps"]
    steps[-1]["run"] += "\necho ${{ github.event.issue.title }}\n"


def report_gate_or_true(d):
    d["jobs"]["hook-tests-macos-report"]["if"] = REPORT_GATE + " || true"


def report_job_wide_concurrency(d):
    d["jobs"]["hook-tests-macos-report"]["concurrency"]["group"] = "hook-tests-${{ github.event.pull_request.number }}"


def aggregate_fails_on_pr(d):
    # The original rule: a skipped plan fails the aggregate on a pull_request.
    run = d["jobs"]["hook-tests-macos"]["steps"][0]["run"]
    d["jobs"]["hook-tests-macos"]["steps"][0]["run"] = run.replace('if [ "$EVENT_NAME" != "push" ]; then', 'if false; then')


def shard_issues_write(d):
    d["jobs"]["hook-tests-macos-shard"]["permissions"] = {"issues": "write"}


def drop_upload_gate(d):
    for s in d["jobs"]["hook-tests-macos-shard"]["steps"]:
        if isinstance(s, dict) and str(s.get("uses", "")).startswith("actions/upload-artifact@"):
            s.pop("if", None)


NEGATIVES = [
    ("plan not gated to push", drop_plan_gate),
    ("report job with extra permission", report_extra_perm),
    ("Linux plan gated off PRs", linux_pr_gate),
    ("expression interpolated into report script", report_interpolates),
    ("shard granted issues: write", shard_issues_write),
    ("upload step not gated on failure", drop_upload_gate),
    ("aggregate fails on a pull_request", aggregate_fails_on_pr),
    ("report gate with an unconditional || true", report_gate_or_true),
    ("report concurrency keyed on a PR number", report_job_wide_concurrency),
]

for label, fn in NEGATIVES:
    found = check(mutate(fn))
    if found:
        ok(f"negative control rejected: {label}")
    else:
        bad(f"negative control accepted: {label}")

print(f"\n{passes} passed, {failures} failed")
sys.exit(1 if failures else 0)
PY
