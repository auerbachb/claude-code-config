#!/usr/bin/env bash
# hook-scripts-macos-after-merge.test.sh — Workflow-contract test for the macOS hook
# tests running after merge only (issue #2265).
#
# WHAT IS UNDER TEST
#   .github/workflows/hook-scripts.yml, parsed with PyYAML and checked as data:
#     - the trigger set is exactly pull_request, push (main), schedule (one weekly
#       cron, early Monday UTC) and workflow_dispatch (issue #2351);
#     - on pull_request and push the macOS plan is skipped (its `if` admits the
#       schedule and dispatch events only), so the shards are skipped with it and no
#       macOS runner is queued;
#     - the aggregate `hook-tests-macos` still reports and passes on a pull_request or
#       push with the "weekly schedule" notice, and on schedule or dispatch it passes
#       only when the plan and every shard succeeded;
#     - `hook-tests-macos-report` runs only on a schedule, or a dispatch of main, after
#       a failed macOS aggregate, holds `issues: write` as its only permission, and
#       never interpolates `${{ }}` into a run script (values travel through env);
#     - the workflow-level permissions stay `contents: read`, and no other job gains
#       `issues: write`;
#     - the Linux and Python jobs carry no event gate (they still run on PRs and push);
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
MACOS_GATE = "github.event_name == 'schedule' || github.event_name == 'workflow_dispatch'"
NOTICE = "macOS hook tests run on the weekly schedule and by manual dispatch (issue #2351)"
REPORT_GATE = "always() && (github.event_name == 'schedule' || (github.event_name == 'workflow_dispatch' && github.ref == 'refs/heads/main')) && needs.hook-tests-macos.result == 'failure'"
EXPR = re.compile(r"\$\{\{.*?\}\}", re.S)


def run_blocks(job):
    return [s.get("run", "") for s in job.get("steps", []) if isinstance(s, dict)]


AGG_CASES = [
    # (event, plan result, shard result, expected pass)
    ("pull_request", "skipped", "skipped", True),
    ("push", "skipped", "skipped", True),
    ("schedule", "success", "success", True),
    ("workflow_dispatch", "success", "success", True),
    ("schedule", "skipped", "skipped", False),
    ("schedule", "success", "failure", False),
    ("workflow_dispatch", "failure", "success", False),
    ("schedule", "success", "cancelled", False),
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
        elif event in ("pull_request", "push") and NOTICE not in res.stdout:
            errs.append(f"aggregate on {event} passes without the weekly-schedule notice")
    return errs


def check(doc):
    """Return a list of contract violations (empty = pass)."""
    errors = []
    if not isinstance(doc, dict):
        return ["workflow document is not a mapping"]
    jobs = doc.get("jobs") or {}

    if doc.get("permissions") != {"contents": "read"}:
        errors.append(f"workflow permissions must be exactly contents: read, got {doc.get('permissions')!r}")

    # PyYAML (YAML 1.1) reads a bare `on:` key as boolean True.
    on_block = doc.get("on", doc.get(True))
    if not isinstance(on_block, dict) or set(on_block) != {"pull_request", "push", "schedule", "workflow_dispatch"}:
        errors.append(f"trigger set must be exactly pull_request, push, schedule, workflow_dispatch, got {on_block!r}")
    else:
        crons = [s.get("cron") for s in (on_block.get("schedule") or []) if isinstance(s, dict)]
        if crons != ["17 6 * * 1"]:
            errors.append(f"weekly schedule must be exactly one cron '17 6 * * 1', got {crons!r}")
        if on_block.get("push") != {"branches": ["main"]}:
            errors.append(f"push trigger must stay limited to branches: [main], got {on_block.get('push')!r}")

    for job_id, job in jobs.items():
        if not isinstance(job, dict):
            errors.append(f"job {job_id!r} is not a mapping")
            continue
        perms = job.get("permissions")
        if job_id != "hook-tests-macos-report" and perms is not None:
            # Only the report job may hold issues: write. A string shorthand (write-all, read-all)
            # is rejected outright on any other job; a mapping may not name issues at all.
            if not isinstance(perms, dict):
                errors.append(f"job {job_id!r} sets permissions shorthand {perms!r}; only the report job may widen permissions")
            elif "issues" in perms:
                errors.append(f"job {job_id!r} grants issues: {perms['issues']!r}; only the report job may")

    plan = jobs.get("hook-tests-macos-plan") or {}
    if plan.get("if") != MACOS_GATE:
        errors.append(f"hook-tests-macos-plan must be gated `if: {MACOS_GATE}`, got {plan.get('if')!r}")

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
    if agg_env.get("PLAN_RESULT") != "${{ needs.hook-tests-macos-plan.result }}":
        errors.append("hook-tests-macos does not bind PLAN_RESULT to needs.hook-tests-macos-plan.result")
    if agg_env.get("SHARD_RESULT") != "${{ needs.hook-tests-macos-shard.result }}":
        errors.append("hook-tests-macos does not bind SHARD_RESULT to needs.hook-tests-macos-shard.result")
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
        if "concurrency" in report:
            errors.append(f"report job must not declare concurrency (a queued group drops pending reports), got {report.get('concurrency')!r}")
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
    ok("shipped hook-scripts.yml runs macOS weekly and by dispatch and reports the failure issue")


def mutate(fn):
    doc = copy.deepcopy(real)
    fn(doc)
    return doc


def drop_plan_gate(d):
    d["jobs"]["hook-tests-macos-plan"].pop("if", None)


def plan_gated_back_to_push(d):
    d["jobs"]["hook-tests-macos-plan"]["if"] = "github.event_name == 'push'"


def _on(d):
    return d["on"] if "on" in d else d[True]


def drop_schedule(d):
    _on(d).pop("schedule", None)


def drop_dispatch(d):
    _on(d).pop("workflow_dispatch", None)


def daily_cron(d):
    _on(d)["schedule"] = [{"cron": "17 6 * * *"}]


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
    d["jobs"]["hook-tests-macos-report"]["concurrency"] = {"group": "hook-tests-macos-report", "cancel-in-progress": False}


def aggregate_fails_on_pr(d):
    # A skipped plan must not pass the aggregate on a pull_request: the skip guard is disabled.
    run = d["jobs"]["hook-tests-macos"]["steps"][0]["run"]
    d["jobs"]["hook-tests-macos"]["steps"][0]["run"] = run.replace('if [ "$EVENT_NAME" != "schedule" ] && [ "$EVENT_NAME" != "workflow_dispatch" ]; then', 'if false; then')


def shard_issues_write(d):
    d["jobs"]["hook-tests-macos-shard"]["permissions"] = {"issues": "write"}


def shard_write_all(d):
    d["jobs"]["hook-tests-macos-shard"]["permissions"] = "write-all"


def drop_upload_gate(d):
    for s in d["jobs"]["hook-tests-macos-shard"]["steps"]:
        if isinstance(s, dict) and str(s.get("uses", "")).startswith("actions/upload-artifact@"):
            s.pop("if", None)


def hardcode_plan_result(d):
    d["jobs"]["hook-tests-macos"]["steps"][0]["env"]["PLAN_RESULT"] = "success"


def hardcode_shard_result(d):
    d["jobs"]["hook-tests-macos"]["steps"][0]["env"]["SHARD_RESULT"] = "success"


NEGATIVES = [
    ("plan not gated to schedule or dispatch", drop_plan_gate),
    ("plan gated back to push", plan_gated_back_to_push),
    ("weekly schedule dropped", drop_schedule),
    ("workflow_dispatch dropped", drop_dispatch),
    ("schedule cron changed to daily", daily_cron),
    ("report job with extra permission", report_extra_perm),
    ("Linux plan gated off PRs", linux_pr_gate),
    ("expression interpolated into report script", report_interpolates),
    ("shard granted issues: write", shard_issues_write),
    ("shard granted write-all", shard_write_all),
    ("upload step not gated on failure", drop_upload_gate),
    ("aggregate fails on a pull_request", aggregate_fails_on_pr),
    ("report gate with an unconditional || true", report_gate_or_true),
    ("report job declares a concurrency group", report_job_wide_concurrency),
    ("aggregate PLAN_RESULT hard-coded", hardcode_plan_result),
    ("aggregate SHARD_RESULT hard-coded", hardcode_shard_result),
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
