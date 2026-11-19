#!/usr/bin/env python3
# catalog: utilities — Join exact-HEAD workflow inventory to checks without hiding another execution
"""Join exact-HEAD workflow evidence to checks without hiding another execution.

Pure fixture seam for Issue 2316. No network, credentials, or filesystem writes.
"""
import json
from datetime import datetime
import sys


def pages(path, field):
    with open(path, encoding="utf-8") as handle:
        raw = handle.read()
    decoder = json.JSONDecoder()
    index, items, total = 0, [], 0
    while raw[index:].strip():
        index += len(raw[index:]) - len(raw[index:].lstrip())
        page, end = decoder.raw_decode(raw, index)
        index = end
        if not isinstance(page, dict) or not isinstance(page.get(field), list):
            raise ValueError("invalid evidence page")
        reported = page.get("total_count")
        if not isinstance(reported, int) or isinstance(reported, bool) or reported < 0:
            raise ValueError("missing evidence count")
        total = max(total, reported)
        items.extend(page[field])
    identities = [item.get("id") for item in items if isinstance(item, dict)]
    if len(identities) != len(items) or any(not positive(value) for value in identities) or len(set(identities)) != len(identities):
        raise ValueError("ambiguous evidence pagination")
    if not raw.strip() or len(items) < total:
        raise ValueError("incomplete evidence pages")
    return items


def positive(value):
    return isinstance(value, int) and not isinstance(value, bool) and value > 0


def scope(run):
    prs = run.get("pull_requests")
    if not isinstance(prs, list):
        raise ValueError("missing workflow PR scope")
    identities = []
    for pr in prs:
        if not isinstance(pr, dict) or not positive(pr.get("number")):
            raise ValueError("invalid workflow PR identity")
        base = pr.get("base") or {}
        if not isinstance(base, dict) or not isinstance(base.get("repo") or {}, dict):
            raise ValueError("invalid workflow PR base")
        identities.append((pr["number"], base.get("ref"), (base.get("repo") or {}).get("id")))
    # Missing branch/PR identity is not proof that two executions are reruns.
    unknown = run["event"] not in ("push", "pull_request", "pull_request_target") or not isinstance(run.get("head_branch"), str) or not run.get("head_branch") or (
        run["event"].startswith("pull_request") and not identities
    ) or any(not isinstance(ref, str) or not ref or not positive(repo) for _, ref, repo in identities)
    return [run["workflow_id"], run["event"], run.get("head_branch"),
            sorted(identities), run["id"] if unknown else None]


def latest_executions(group):
    # Latest-run policy for a verified workflow/event/branch/PR scope: a newer
    # execution supersedes completed older runs, including PR-body rechecks.
    # This does not infer event actions such as edited/reopened. Every unfinished
    # execution stays visible. A manual retry retains its ID, so its latest
    # run_started_at (reset on retry) governs ordering instead of creation ID.
    if all(run.get("run_attempt") == 1 for run in group):
        newest = max(run["id"] for run in group)
        return [run for run in group if run["id"] == newest]
    starts = []
    for run in group:
        value = run.get("run_started_at") or (run.get("created_at") if run.get("run_attempt") == 1 else None)
        try:
            parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
            if parsed.tzinfo is None:
                return group
            starts.append(parsed.timestamp())
        except (ValueError, AttributeError):
            # Missing retry chronology cannot justify discarding an execution.
            return group
    newest = max(starts)
    return [run for run, start in zip(group, starts) if start == newest]


def normalize(checks, workflows, head):
    by_url, by_suite, groups = {}, {}, {}
    for run in workflows:
        if not isinstance(run, dict) or run.get("head_sha") != head:
            raise ValueError("workflow HEAD mismatch")
        if not positive(run.get("id")) or not positive(run.get("workflow_id")):
            raise ValueError("invalid workflow identity")
        if "run_attempt" in run and not positive(run["run_attempt"]):
            raise ValueError("invalid workflow attempt")
        if not isinstance(run.get("event"), str) or not run["event"]:
            raise ValueError("missing workflow event")
        if not isinstance(run.get("html_url"), str) or not run["html_url"]:
            raise ValueError("missing workflow URL")
        if not isinstance(run.get("status"), str) or not run["status"]:
            raise ValueError("missing workflow state")
        run_scope = scope(run)
        run["_scope"] = run_scope
        key = json.dumps(run_scope, sort_keys=True)
        groups.setdefault(key, []).append(run)
        if run["html_url"] in by_url and by_url[run["html_url"]]["id"] != run["id"]:
            raise ValueError("ambiguous workflow URL")
        by_url[run["html_url"]] = run
        if positive(run.get("check_suite_id")):
            by_suite.setdefault(run["check_suite_id"], {})[run["id"]] = run
    latest = {key: latest_executions(group) for key, group in groups.items()}
    newest_ids = {run["id"] for group in latest.values() for run in group}
    selected = [run for run in workflows if run["id"] in newest_ids or run["status"] != "completed"]
    current = {run["id"] for run in selected}
    result, superseded, reported = [], [], set()
    for check in checks:
        if not isinstance(check, dict):
            raise ValueError("invalid check")
        if check.get("head_sha", head) != head:
            raise ValueError("check HEAD mismatch")
        app = check.get("app") or {}
        if not isinstance(app, dict):
            raise ValueError("invalid check publisher")
        if app.get("slug") != "github-actions":
            result.append(check)
            continue
        url = check.get("details_url") or ""
        if not isinstance(url, str) or not isinstance(check.get("check_suite") or {}, dict):
            raise ValueError("invalid check workflow reference")
        run = by_url.get(url.split("/job/", 1)[0])
        if run is None:
            matches = by_suite.get((check.get("check_suite") or {}).get("id"), {})
            if len(matches) == 1:
                run = next(iter(matches.values()))
        if run is None:
            raise ValueError("Actions check has no authoritative workflow identity")
        suite = (check.get("check_suite") or {}).get("id")
        if suite is not None and run.get("check_suite_id") != suite:
            raise ValueError("conflicting workflow identity")
        if run["id"] in current:
            result.append(dict(check, _actions_scope=run["_scope"], _actions_run_id=run["id"]))
            reported.add((run["id"], app.get("id"), check.get("name")))
        else:
            superseded.append((check, run))
    # A selected-name gate must not age a known job into optional absence while
    # its replacement is queued. Keep only pending name evidence, never the old
    # result or check ID. A reported replacement job or completed workflow ends it.
    for check, old in superseded:
        for run in latest[json.dumps(old["_scope"], sort_keys=True)]:
            key = (run["id"], check["app"].get("id"), check.get("name"))
            if run["status"] != "completed" and key not in reported:
                reported.add(key)
                result.append({
                    "id": None, "name": check["name"], "status": "queued", "conclusion": None,
                    "app": check["app"], "check_suite": {"id": run.get("check_suite_id")},
                    "details_url": run["html_url"], "_actions_scope": run["_scope"],
                    "_actions_run_id": run["id"], "_superseded_check_pending": True,
                })
    # A queued workflow may have no check runs yet. Its inventory entry is still
    # pending evidence; a successful unrelated job cannot hide an absent gate.
    for run in selected:
        result.append({
            "id": None, "name": "workflow: {} ({})".format(run.get("path") or run["workflow_id"], run["event"]),
            "status": run["status"], "conclusion": run.get("conclusion"),
            "app": {"slug": "github-actions", "id": None},
            "check_suite": {"id": run.get("check_suite_id")}, "details_url": run["html_url"],
            "_actions_scope": run["_scope"], "_actions_run_id": run["id"], "_workflow_inventory": True,
        })
    return result


if __name__ == "__main__":
    try:
        if len(sys.argv) != 4:
            raise ValueError("expected checks file, workflows file, and HEAD")
        output = normalize(pages(sys.argv[1], "check_runs"), pages(sys.argv[2], "workflow_runs"), sys.argv[3])
        print(json.dumps(output, separators=(",", ":")))
    except (ValueError, KeyError, TypeError, OSError):
        print("check workflow evidence is unavailable or incomplete", file=sys.stderr)
        sys.exit(5)
