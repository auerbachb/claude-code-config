#!/usr/bin/env bash
# hook-scripts-concurrency.test.sh — Workflow-contract test for the per-PR
# concurrency group in .github/workflows/hook-scripts.yml (issue #1882).
#
# WHAT IS UNDER TEST
#   A new PR head must cancel that PR's older queued/running Hook scripts run,
#   and nothing else. The workflow's top-level `concurrency:` block is parsed
#   with PyYAML and its `group` expression is EVALUATED by a restricted
#   evaluator against fixture contexts — never string-matched — so the test
#   asserts what the key means:
#     - two pushes (different SHAs) to the same PR share one group (supersede);
#     - two distinct PRs never share a group (no cross-PR cancellation);
#     - another workflow with the same PR number never shares the group;
#     - runs without a PR number (a future non-pull_request trigger) get a
#       per-run group, never one global group, and never a PR's group;
#     - `cancel-in-progress` is the YAML boolean true (not the string "true");
#     - the trigger set is exactly {pull_request, push limited to main} and no job
#       declares its own concurrency, so push/main runs cannot join a PR's group.
#   The evaluator knows only a handful of `github.*` names and the `||`
#   operator; any other token is an error, so a new key ingredient forces this
#   test to be revisited rather than passing on an unmodelled value.
#
# NEGATIVE CONTROLS
#   The same checker runs against in-memory mutations of the real workflow
#   (global group, constant group, SHA-keyed group, workflow-less group, no
#   run_id fallback, string "true", false, missing block, push trigger, job
#   concurrency, unknown token). Each must be rejected, so a green run is not
#   unconditional.
#
# WHAT THIS CANNOT PROVE
#   That GitHub Actions actually cancels the superseded run — that lands on CI
#   evidence from a real PR (the issue's Test Plan item 3).
#
# PyYAML is a hard dependency (CI installs it — see hook-scripts.yml); a missing
# module fails rather than skips, since every assertion would pass vacuously.

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

# Values the restricted evaluator can resolve. Anything else is an error.
KNOWN = {
    "github.workflow",
    "github.event.pull_request.number",
    "github.run_id",
    "github.sha",
    "github.event.pull_request.head.sha",
    "github.ref",
    "github.event_name",
}
TOKEN = re.compile(r"\$\{\{(.*?)\}\}")


class EvalError(Exception):
    pass


def eval_expr(expr, ctx):
    """Evaluate `a || b || ...` over KNOWN names; first truthy operand wins."""
    value = ""
    for operand in expr.split("||"):
        name = operand.strip()
        if name not in KNOWN:
            raise EvalError(f"unsupported expression token {name!r}")
        value = ctx.get(name, "")
        if value not in ("", None):
            return str(value)
    return "" if value is None else str(value)


def eval_group(group, ctx):
    if not isinstance(group, str):
        raise EvalError(f"group is not a string: {group!r}")
    return TOKEN.sub(lambda m: eval_expr(m.group(1), ctx), group)


def pr_ctx(workflow, pr, sha, run_id):
    return {
        "github.workflow": workflow,
        "github.event.pull_request.number": pr,
        "github.run_id": run_id,
        "github.sha": sha,
        "github.event.pull_request.head.sha": sha,
        "github.ref": f"refs/pull/{pr}/merge",
        "github.event_name": "pull_request",
    }


def push_ctx(workflow, sha, run_id):
    return {
        "github.workflow": workflow,
        "github.event.pull_request.number": "",
        "github.run_id": run_id,
        "github.sha": sha,
        "github.event.pull_request.head.sha": "",
        "github.ref": "refs/heads/main",
        "github.event_name": "push",
    }


def check(doc):
    """Return a list of contract violations (empty = pass)."""
    errors = []
    if not isinstance(doc, dict):
        return ["workflow document is not a mapping"]

    # PyYAML (YAML 1.1) reads a bare `on:` key as boolean True.
    trigger_keys = [k for k in ("on", True) if k in doc]
    if len(trigger_keys) != 1:
        errors.append(f"expected exactly one trigger key, found {trigger_keys!r}")
    else:
        on = doc[trigger_keys[0]]
        events = set(on) if isinstance(on, (dict, list)) else {on}
        if events != {"pull_request", "push"}:
            errors.append(
                f"trigger set must be exactly {{pull_request, push}}, got {sorted(map(str, events))}"
            )
        elif not (isinstance(on, dict) and isinstance(on.get("push"), dict)
                  and on["push"].get("branches") == ["main"]):
            errors.append("push trigger must be limited to branches: [main]")

    for job_id, job in (doc.get("jobs") or {}).items():
        if isinstance(job, dict) and "concurrency" in job:
            errors.append(f"job {job_id!r} declares its own concurrency")

    conc = doc.get("concurrency")
    if not isinstance(conc, dict):
        errors.append(f"top-level concurrency must be a mapping, got {conc!r}")
        return errors

    cip = conc.get("cancel-in-progress")
    if not (isinstance(cip, bool) and cip is True):
        errors.append(f"cancel-in-progress must be boolean true, got {cip!r}")

    group = conc.get("group")
    wf = "Hook scripts"
    try:
        a1 = eval_group(group, pr_ctx(wf, 101, "aaaa111", 9001))
        a2 = eval_group(group, pr_ctx(wf, 101, "bbbb222", 9002))  # superseding SHA
        b1 = eval_group(group, pr_ctx(wf, 102, "cccc333", 9003))
        other = eval_group(group, pr_ctx("Rule lint", 101, "aaaa111", 9004))
        p1 = eval_group(group, push_ctx(wf, "dddd444", 9005))
        p2 = eval_group(group, push_ctx(wf, "eeee555", 9006))
    except EvalError as exc:
        errors.append(f"group {group!r}: {exc}")
        return errors

    if a1 != a2:
        errors.append(f"superseding SHA on PR #101 lands in a new group ({a1!r} vs {a2!r})")
    if a1 == b1:
        errors.append(f"PR #101 and PR #102 share group {a1!r} (cross-PR cancellation)")
    if a1 == other:
        errors.append(f"another workflow shares PR #101's group {a1!r}")
    if p1 == p2:
        errors.append(f"runs without a PR number share one global group {p1!r}")
    if p1 in (a1, b1) or p2 in (a1, b1):
        errors.append("a non-PR run shares a pull request's group")
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


# Positive: the shipped workflow meets the contract.
errs = check(real)
if errs:
    for e in errs:
        bad(f"shipped workflow: {e}")
else:
    ok("shipped hook-scripts.yml satisfies the per-PR concurrency contract")


def mutate(fn):
    doc = copy.deepcopy(real)
    fn(doc)
    return doc


def set_group(value):
    return lambda d: d["concurrency"].__setitem__("group", value)


def set_cip(value):
    return lambda d: d["concurrency"].__setitem__("cancel-in-progress", value)


def add_push_all_branches(d):
    key = "on" if "on" in d else True
    d[key] = {"pull_request": {}, "push": {}}


def job_conc(d):
    first = next(iter(d["jobs"]))
    d["jobs"][first]["concurrency"] = {"group": "x", "cancel-in-progress": True}


NEGATIVES = [
    ("concurrency block missing", lambda d: d.pop("concurrency", None)),
    ("cancel-in-progress false", set_cip(False)),
    ("cancel-in-progress string 'true'", set_cip("true")),
    ("global group (workflow only)", set_group("${{ github.workflow }}")),
    ("constant group", set_group("hook-scripts")),
    ("SHA-keyed group", set_group("${{ github.workflow }}-${{ github.sha }}")),
    ("head-SHA-keyed group",
     set_group("${{ github.workflow }}-${{ github.event.pull_request.head.sha }}")),
    ("group without workflow identity",
     set_group("pr-${{ github.event.pull_request.number || github.run_id }}")),
    ("group without run_id fallback",
     set_group("${{ github.workflow }}-${{ github.event.pull_request.number }}")),
    ("unknown token in group", set_group("${{ github.workflow }}-${{ github.actor }}")),
    ("push trigger on every branch", add_push_all_branches),
    ("job-level concurrency", job_conc),
]

for label, fn in NEGATIVES:
    if "concurrency" not in real and label != "concurrency block missing":
        bad(f"negative control '{label}' cannot run: shipped workflow lacks concurrency")
        continue
    errs = check(mutate(fn))
    if errs:
        ok(f"rejects {label}: {errs[0]}")
    else:
        bad(f"negative control '{label}' was ACCEPTED — checker is not discriminating")

print(f"\n{passes} passed, {failures} failed")
sys.exit(1 if failures else 0)
PY
