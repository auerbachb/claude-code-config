#!/usr/bin/env python3
# review_ci_report.py — pure classifier behind review-ci-report.sh (issue #2196).
#
# Input: a manifest of per-repo GraphQL responses (written by the shell
# entrypoint). Output: one report, as a Markdown table or as JSON. No network,
# no files besides the manifest and the response files it names.
#
# Compatible with Python 3.9. Load it through review-ci-report.sh; the
# `--help` text of that script is the operator contract.
#
# Reuse, not re-derivation:
#   - reviewer identities and the "a bot, not a user with the same login" rule
#     follow the merge gate (`merge-gate.sh`, `review-substance.sh`);
#   - reviewer app slugs that mark a check-run as a reviewer, not build CI,
#     are the exact set `ci-status.sh` uses;
#   - trigger comments are `review_ledger.TRIGGERS` and `_GREPTILE_RE`;
#   - CodeAnt pre-review approvals follow `codeant-round.jq`: an APPROVED
#     alone is never a review round (issues #1365, #1432).
#
# Known holes are printed in every repo's blind-spot list, not hidden here.
import argparse
import json
import math
import os
import sys
import re
from datetime import datetime, timedelta, timezone


def _shared_trigger_patterns():
    # The review_ledger module sits beside this file; import it lazily from there.
    sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
    import review_ledger
    return review_ledger.TRIGGERS, review_ledger._GREPTILE_RE


TRIGGERS, _GREPTILE_RE = _shared_trigger_patterns()

SCHEMA = "review-ci-report/v1"
REVIEWERS = (
    ("coderabbitai", "CodeRabbit"),
    ("codeant-ai", "CodeAnt"),
    ("cursor", "BugBot"),
    ("greptile-apps", "Greptile"),
)
REVIEWER_LABEL = dict(REVIEWERS)
TRIGGER_LOGIN = {"coderabbit": "coderabbitai", "bugbot": "cursor", "codeant": "codeant-ai"}
# ci-status.sh's reviewer app-slug set: a check-run from these is review, not build CI.
REVIEWER_SLUGS = frozenset([
    "codeant-ai", "codeant", "cursor", "cursor-com", "coderabbitai", "coderabbit",
    "greptile-apps", "greptile", "graphite-app", "graphite",
])
KNOWN_PASSED_CONCLUSIONS = frozenset(["SUCCESS", "NEUTRAL", "CANCELLED", "SKIPPED"])
CODEANT_MARKER_RE = re.compile(r"<!--[ \t]*codeant-review-status:(.*?)-->", re.S)
ISO_RE = re.compile(r"^(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2})(?:\.(\d+))?(Z|[+-]\d{2}:?\d{2})?$")
REVIEW_CONTEXT_PREFIXES = ("coderabbit", "codeant", "cursor", "greptile", "graphite")
BLOCKING_CONCLUSIONS = frozenset(["FAILURE", "TIMED_OUT", "ACTION_REQUIRED", "STARTUP_FAILURE", "STALE"])
FAILED_STATUS_STATES = frozenset(["FAILURE", "ERROR"])
PENDING_STATUS_STATES = frozenset(["PENDING", "EXPECTED"])
# Tool-scoped refusal phrases (rate, usage, spend, subscription, trial, credits).
# Matched case-insensitively against a reviewer's own review bodies and comments.
REFUSAL_PHRASES = (
    "rate limit", "rate-limit", "usage limit", "spend limit", "out of credits",
    "fair-usage", "fair usage", "trial limit", "review limit reached",
    "no pr review subscription", "couldn't run",
)
SMALL_SAMPLE = 10
PREFIX_NOTE = "Blind spots are stated, not hidden: read them before drawing a conclusion."


def parse_ts(value):
    """ISO-8601 instant as aware UTC. Accepts fractional seconds, Z or a numeric
    offset, and a naive value, which CodeAnt's run markers use and which is UTC."""
    if not value or not isinstance(value, str):
        return None
    match = ISO_RE.match(value.strip())
    if not match:
        return None
    try:
        moment = datetime.strptime(match.group(1), "%Y-%m-%dT%H:%M:%S")
    except ValueError:
        return None
    fraction = match.group(2) or ""
    moment = moment.replace(microsecond=int((fraction + "000000")[:6]) if fraction else 0)
    zone = match.group(3)
    if zone and zone != "Z":
        digits = zone[1:].replace(":", "")
        offset = timedelta(hours=int(digits[:2]), minutes=int(digits[2:]))
        moment = moment - offset if zone[0] == "+" else moment + offset
    return moment.replace(tzinfo=timezone.utc)


def codeant_run_ends(comments):
    """Finish instant of each completed CodeAnt run, keyed by full commit SHA.

    Read from the `codeant-review-status` marker on CodeAnt's own comment, the
    same record merge-gate.sh and review-substance.sh use. Only rows with
    done == true count; the latest finish per SHA wins.
    """
    ends = {}
    for comment in comments:
        author = comment.get("author") or {}
        if not is_bot(author) or login_of(author) != "codeant-ai":
            continue
        for match in CODEANT_MARKER_RE.finditer(comment.get("body") or ""):
            try:
                rows = json.loads(match.group(1).strip())
            except ValueError:
                continue
            if not isinstance(rows, list):
                continue
            for row in rows:
                if not isinstance(row, dict) or row.get("done") is not True:
                    continue
                sha = str(row.get("commit") or "").lower()
                finished = parse_ts(row.get("finished"))
                if not sha or finished is None:
                    continue
                if sha not in ends or finished > ends[sha]:
                    ends[sha] = finished
    return ends


def minutes_between(start, end):
    return (end - start).total_seconds() / 60.0


def median(values):
    if not values:
        return None
    ordered = sorted(values)
    mid = len(ordered) // 2
    if len(ordered) % 2:
        return round(ordered[mid], 1)
    return round((ordered[mid - 1] + ordered[mid]) / 2.0, 1)


def p90(values):
    # Nearest rank: the value at position ceil(0.9 * n), 1-based.
    if not values:
        return None
    ordered = sorted(values)
    rank = int(math.ceil(0.9 * len(ordered)))
    return round(ordered[rank - 1], 1)


# A body that carries review-summary evidence is a review even when it mentions a
# limit in passing: CodeRabbit's full walkthroughs (6-18 KB) quote the banner
# text, while its refusal notices (about 4 KB) carry no walkthrough at all.
REVIEW_EVIDENCE_MARKERS = ("walkthrough",)


def is_refusal(body):
    text = (body or "").lower()
    if any(marker in text for marker in REVIEW_EVIDENCE_MARKERS):
        return False
    return any(phrase in text for phrase in REFUSAL_PHRASES)


def is_bot(actor):
    return bool(actor) and actor.get("__typename") == "Bot"


def login_of(actor):
    return (actor or {}).get("login") or ""


def load_repo(entry):
    """Return (repo_object, cost, None) or (None, None, reason) for one manifest entry."""
    if entry.get("rc") not in (0, None):
        err = (entry.get("err") or "").strip().splitlines()
        detail = err[0] if err else "no stderr"
        return None, None, "gh exited %s: %s" % (entry.get("rc"), detail[:160])
    try:
        with open(entry["out_file"], "r", encoding="utf-8") as handle:
            raw = handle.read()
    except (OSError, KeyError, TypeError) as exc:
        return None, None, "response unreadable (%s)" % exc.__class__.__name__
    try:
        payload = json.loads(raw)
    except ValueError:
        return None, None, "response is not valid JSON"
    if not isinstance(payload, dict):
        return None, None, "response is not a JSON object"
    if payload.get("errors"):
        first = payload["errors"][0] if isinstance(payload["errors"], list) and payload["errors"] else {}
        message = first.get("message", "unspecified") if isinstance(first, dict) else "unspecified"
        return None, None, "GraphQL errors: %s" % str(message)[:160]
    data = payload.get("data")
    if not isinstance(data, dict):
        return None, None, "response has no data object"
    repo = data.get("repository")
    if repo is None:
        return None, None, "repository not found or not accessible"
    if not isinstance(repo, dict) or not isinstance(repo.get("pullRequests"), dict):
        return None, None, "pullRequests connection missing"
    cost = (data.get("rateLimit") or {}).get("cost")
    return repo, cost, None


def build_items(commit):
    """Build-CI rows of one commit (reviewer checks removed), or None when truncated."""
    items = []
    rollup = (commit.get("statusCheckRollup") or {}).get("contexts") or {}
    total = rollup.get("totalCount")
    if isinstance(total, int) and total > len(rollup.get("nodes") or []):
        # Checks were omitted by the bounded read: a missing check must never
        # make a commit look passed, so the commit is excluded and counted.
        return None
    for node in rollup.get("nodes") or []:
        kind = node.get("__typename")
        if kind == "CheckRun":
            slug = ((node.get("checkSuite") or {}).get("app") or {}).get("slug") or ""
            if slug in REVIEWER_SLUGS:
                continue
            items.append(("check", node))
        elif kind == "StatusContext":
            if (node.get("context") or "").lower().startswith(REVIEW_CONTEXT_PREFIXES):
                continue
            items.append(("status", node))
    return items


def commit_ci(commit):
    """Summarise build CI for one commit at its final state."""
    items = build_items(commit)
    if items is None:
        return {"state": "incomplete", "duration": None, "first_start": None, "items": None}
    return ci_summary(items, None)


def ci_summary(items, when):
    """CI state of build rows as known at instant `when` (None = final state).

    A check or status that completed after `when` is still pending for a
    review submitted at `when`, so it cannot make that review a failed-CI or
    completed-CI review.
    """
    if not items:
        return {"state": "none", "duration": None, "first_start": None}
    pending = failed = False
    starts, ends = [], []
    for kind, node in items:
        if kind == "check":
            end = parse_ts(node.get("completedAt"))
            done = node.get("status") == "COMPLETED" and bool(node.get("conclusion"))
            if when is not None and (end is None or end > when):
                done = False
            if not done:
                pending = True
                continue
            if node.get("conclusion") in BLOCKING_CONCLUSIONS:
                failed = True
            elif node.get("conclusion") not in KNOWN_PASSED_CONCLUSIONS:
                # An unrecognised conclusion is not evidence of a pass: keep it unresolved.
                pending = True
            start = parse_ts(node.get("startedAt"))
            if start:
                starts.append(start)
            if end:
                ends.append(end)
        else:
            state = node.get("state")
            created = parse_ts(node.get("createdAt"))
            if when is not None and created is not None and created > when:
                pending = True
            elif not state or state in PENDING_STATUS_STATES:
                pending = True
            elif state in FAILED_STATUS_STATES:
                failed = True
    if pending:
        state = "pending"
    elif failed:
        state = "failed"
    else:
        state = "passed"
    duration = None
    if starts and ends and max(ends) >= min(starts):
        duration = minutes_between(min(starts), max(ends))
    return {"state": state, "duration": duration, "first_start": min(starts) if starts else None}


def new_repo_acc():
    return {
        "prs": 0, "prs_outside_window": 0,
        "commits": {}, "forced_pushes": 0, "inferred": 0, "undated": 0, "negative": 0,
        "truncated": {"commits": 0, "reviews": 0, "comments": 0, "timeline": 0},
        "push_kinds": {"force_push": 0, "build_start": 0, "committed_date": 0, "none": 0},
        "reviewers": {login: {"reviews": 0, "minutes": [], "on_failed": 0, "on_completed": 0,
                              "first_completed": 0, "first_failed": 0, "first_pr_total": 0,
                              "anchor": {"request": 0, "push": 0}, "refusal_keys": set(),
                              "pre_review_approvals": 0}
                      for login, _label in REVIEWERS},
        "cost": None,
    }


def connection_truncated(conn):
    if not isinstance(conn, dict):
        return False
    total = conn.get("totalCount")
    shown = len(conn.get("nodes") or [])
    return isinstance(total, int) and total > shown


def analyze_pr(pr, acc, since):
    merged = parse_ts(pr.get("mergedAt"))
    if since and (merged is None or merged.strftime("%Y-%m-%d") < since):
        acc["prs_outside_window"] += 1
        return
    acc["prs"] += 1
    commits_conn = pr.get("commits") or {}
    if connection_truncated(commits_conn):
        acc["truncated"]["commits"] += 1
    timeline = (pr.get("timelineItems") or {}).get("nodes") or []
    if connection_truncated(pr.get("timelineItems")):
        acc["truncated"]["timeline"] += 1
    if connection_truncated(pr.get("reviews")):
        acc["truncated"]["reviews"] += 1
    comments = (pr.get("comments") or {}).get("nodes") or []
    if connection_truncated(pr.get("comments")):
        acc["truncated"]["comments"] += 1

    forced = {}
    requests = {login: [] for login, _ in REVIEWERS}
    for item in timeline:
        kind = item.get("__typename")
        if kind == "HeadRefForcePushedEvent":
            acc["forced_pushes"] += 1
            after = (item.get("afterCommit") or {}).get("oid")
            when = parse_ts(item.get("createdAt"))
            if after and when and (after not in forced or when < forced[after]):
                forced[after] = when
        elif kind == "ReviewRequestedEvent":
            reviewer = item.get("requestedReviewer") or {}
            login = reviewer.get("login") if is_bot(reviewer) else None
            when = parse_ts(item.get("createdAt"))
            if login in requests and when:
                requests[login].append(when)
    for comment in comments:
        author = comment.get("author") or {}
        if is_bot(author):
            continue
        body = comment.get("body") or ""
        when = parse_ts(comment.get("createdAt"))
        if not when:
            continue
        for key, login in TRIGGER_LOGIN.items():
            if TRIGGERS[key].search(body):
                requests[login].append(when)
        if _GREPTILE_RE.search(body):
            requests["greptile-apps"].append(when)

    # Commits: push proxy and CI state, deduplicated per repo by oid.
    pr_commits = {}
    for node in commits_conn.get("nodes") or []:
        commit = node.get("commit") or {}
        oid = commit.get("oid")
        if not oid:
            continue
        items = build_items(commit)
        ci = commit_ci(commit)
        committed = parse_ts(commit.get("committedDate"))
        if oid in forced:
            push_t, push_kind = forced[oid], "force_push"
        elif ci["first_start"]:
            push_t, push_kind = ci["first_start"], "build_start"
        elif committed:
            push_t, push_kind = committed, "committed_date"
        else:
            push_t, push_kind = None, "none"
        record = {"ci": ci, "items": items, "push": push_t, "push_kind": push_kind}
        pr_commits[oid] = record
        acc["commits"][oid] = record

    # Reviews: refusals and pre-review approvals are not reviews.
    review_map = {}
    codeant_ends = codeant_run_ends(comments)
    for rv in (pr.get("reviews") or {}).get("nodes") or []:
        author = rv.get("author") or {}
        if not is_bot(author):
            continue
        login = login_of(author)
        if login not in REVIEWER_LABEL:
            continue
        state = rv.get("state")
        if state == "PENDING":
            continue
        submitted = parse_ts(rv.get("submittedAt"))
        if is_refusal(rv.get("body")):
            acc["reviewers"][login]["refusal_keys"].add(("review", rv.get("submittedAt")))
            continue
        if submitted is None:
            acc["undated"] += 1
            continue
        oid = (rv.get("commit") or {}).get("oid")
        end_at = submitted
        if login == "codeant-ai" and state == "APPROVED":
            # A pre-review stub, unless a completed run on this exact commit substantiates it.
            run_end = codeant_ends.get(oid.lower()) if oid else None
            if run_end is None:
                acc["reviewers"][login]["pre_review_approvals"] += 1
                continue
            end_at = run_end
        if oid and oid not in pr_commits:
            # The review names a commit outside the sample: it is not attributed elsewhere.
            acc["undated"] += 1
            continue
        if not oid:
            # Attribute to the latest sampled commit pushed before the review.
            candidates = [(rec["push"], o) for o, rec in pr_commits.items()
                          if rec["push"] and rec["push"] <= submitted]
            if not candidates:
                acc["undated"] += 1
                continue
            oid = max(candidates)[1]
            acc["inferred"] += 1
        key = (login, oid)
        if key not in review_map or submitted < review_map[key][0]:
            review_map[key] = (submitted, end_at)

    for comment in comments:
        author = comment.get("author") or {}
        if not is_bot(author):
            continue
        login = login_of(author)
        if login in REVIEWER_LABEL and is_refusal(comment.get("body")):
            acc["reviewers"][login]["refusal_keys"].add(("comment", comment.get("createdAt")))

    # Per reviewer: response time from the earliest request after the push proxy, else from push.
    first_by_login = {}
    for (login, oid), (submitted, end_at) in sorted(review_map.items(), key=lambda kv: kv[1][0]):
        rec = pr_commits[oid]
        bucket = acc["reviewers"][login]
        bucket["reviews"] += 1
        # Final CI state of the commit: the issue's metric is reviews on a commit whose CI
        # then failed, so a check finishing after the review still counts.
        ci_state = rec["ci"]["state"]
        if ci_state == "failed":
            bucket["on_failed"] += 1
        if ci_state in ("passed", "failed"):
            bucket["on_completed"] += 1
        push_t = rec["push"]
        if push_t is None:
            acc["undated"] += 1
            anchor_kind, anchor = None, None
        else:
            matching = [t for t in requests[login] if push_t <= t <= end_at]
            if matching:
                anchor_kind, anchor = "request", min(matching)
            elif push_t <= end_at:
                anchor_kind, anchor = "push", push_t
            else:
                anchor_kind, anchor = None, None
                acc["negative"] += 1
        if anchor is not None:
            bucket["anchor"][anchor_kind] += 1
            bucket["minutes"].append(minutes_between(anchor, end_at))
        if login not in first_by_login or submitted < first_by_login[login][0]:
            first_by_login[login] = (submitted, ci_state)
    for login, (_when, ci_state) in first_by_login.items():
        bucket = acc["reviewers"][login]
        bucket["first_pr_total"] += 1
        if ci_state in ("passed", "failed"):
            bucket["first_completed"] += 1
            if ci_state == "failed":
                bucket["first_failed"] += 1


def share(num, den):
    if not den:
        return None
    return round(100.0 * num / den, 1)


def summarise_repo(name, acc, wait):
    commits = list(acc["commits"].values())
    completed = [c for c in commits if c["ci"]["state"] in ("passed", "failed")]
    failed = [c for c in completed if c["ci"]["state"] == "failed"]
    durations = [c["ci"]["duration"] for c in completed if c["ci"]["duration"] is not None]
    push_kinds = {"force_push": 0, "build_start": 0, "committed_date": 0, "none": 0}
    for c in commits:
        push_kinds[c["push_kind"]] += 1
    ci = {
        "commits_sampled": len(commits),
        "commits_ci_none": sum(1 for c in commits if c["ci"]["state"] == "none"),
        "commits_ci_pending": sum(1 for c in commits if c["ci"]["state"] == "pending"),
        "commits_ci_incomplete": sum(1 for c in commits if c["ci"]["state"] == "incomplete"),
        "commits_ci_completed": len(completed),
        "commits_ci_failed": len(failed),
        "failed_share_pct": share(len(failed), len(completed)),
        "duration_median_min": median(durations),
        "duration_p90_min": p90(durations),
        "duration_n": len(durations),
        "push_proxy_kinds": push_kinds,
    }
    reviewers = {}
    for login, label in REVIEWERS:
        bucket = acc["reviewers"][login]
        minutes = bucket["minutes"]
        within = sum(1 for m in minutes if m <= wait)
        entry = {
            "label": label,
            "reviews": bucket["reviews"],
            "response_median_min": median(minutes),
            "response_p90_min": p90(minutes),
            "response_n": len(minutes),
            "within_wait_pct": share(within, len(minutes)),
            "within_wait_count": within,
            "within_wait_n": len(minutes),
            "reviews_on_failed_ci": bucket["on_failed"],
            "reviews_on_failed_ci_pct": share(bucket["on_failed"], bucket["on_completed"]),
            "reviews_on_completed_ci": bucket["on_completed"],
            "first_reviews_on_failed_ci_pct": share(bucket["first_failed"], bucket["first_completed"]),
            "first_reviews_on_failed_ci": bucket["first_failed"],
            "first_reviews_completed_ci": bucket["first_completed"],
            "refusals": len(bucket["refusal_keys"]),
            "anchor_samples": dict(bucket["anchor"]),
            "small_sample": bucket["reviews"] < SMALL_SAMPLE,
        }
        if login == "codeant-ai":
            entry["pre_review_approvals"] = bucket["pre_review_approvals"]
        reviewers[login] = entry
    blind = blind_spots(name, acc, reviewers, ci, wait)
    return {"status": "read", "reason": None, "prs_sampled": acc["prs"],
            "prs_outside_window": acc["prs_outside_window"],
            "ci": ci, "reviewers": reviewers, "blind_spots": blind,
            "rate_limit_cost": acc["cost"]}


def blind_spots(name, acc, reviewers, ci, wait):
    lines = [
        "Commits replaced by a force-push leave no record in this view, and reviews on them are not counted: %d force-push event(s) in the sample." % acc["forced_pushes"],
        "No cost data: see the review-stack audit for billing.",
        "PRs are selected by last update time (newest first), then sorted by merge time; a PR merged earlier but updated recently can displace one merged later.",
        "Re-runs that later passed are not netted out: a commit whose earlier check run failed is counted as failed even when a later re-run passed.",
        "Refusals are detected by phrase in the reviewer's own bodies and comments; a refusal worded differently is counted as a review or not at all.",
        "Inferred attributions (review named no commit, attributed to the latest earlier-pushed sampled commit): %d." % acc["inferred"],
        "Undated items excluded (no timestamp, or no commit pushed before the review): %d." % acc["undated"],
        "Responses that finished before the push proxy were excluded: %d." % acc["negative"],
        "Commits pending, without CI, or with truncated check lists are excluded from CI rates: %d pending, %d without CI, %d truncated." % (ci["commits_ci_pending"], ci["commits_ci_none"], ci["commits_ci_incomplete"]),
    ]
    trunc = acc["truncated"]
    if any(trunc.values()):
        lines.append("Truncated connections (earliest items beyond the read window not counted): commits in %d PR(s), reviews in %d, comments in %d, timeline in %d." % (trunc["commits"], trunc["reviews"], trunc["comments"], trunc["timeline"]))
    for login, label in REVIEWERS:
        entry = reviewers[login]
        if entry["small_sample"]:
            lines.append("%s: %d review(s) in the sample, too small to draw conclusions (fewer than %d)." % (label, entry["reviews"], SMALL_SAMPLE))
        else:
            lines.append("%s: %d review(s) in the sample." % (label, entry["reviews"]))
    if acc["prs"] == 0:
        lines.append("No merged PRs in the window: every figure is n/a.")
    lines.append("Response times are measured from the earliest request after the push proxy when one exists, otherwise from the push proxy.")
    return lines


def unread_repo(reason, cost):
    return {"status": "unread", "reason": reason, "prs_sampled": None, "prs_outside_window": None,
            "ci": None, "reviewers": None, "blind_spots": [], "rate_limit_cost": cost}


def build_report(manifest, wait, wait_source, limit, since):
    per_repo = []
    total_requests = 0
    for entry in manifest:
        total_requests += 1
        repo_obj, cost, reason = load_repo(entry)
        if reason:
            per_repo.append({"repo": entry["repo"], **unread_repo(reason, cost)})
            continue
        acc = new_repo_acc()
        acc["cost"] = cost
        for pr in repo_obj["pullRequests"].get("nodes") or []:
            if pr:
                analyze_pr(pr, acc, since)
        per_repo.append({"repo": entry["repo"], **summarise_repo(entry["repo"], acc, wait)})
    return {
        "schema": SCHEMA,
        "wait_minutes": wait,
        "wait_source": wait_source,
        "limit": limit,
        "since": since,
        "request_budget": {"graphql_requests_per_repo": 1, "repos": len(manifest),
                           "graphql_requests_total": total_requests},
        "per_repo": per_repo,
        "all_read": all(r["status"] == "read" for r in per_repo),
    }


def fmt_min(value, n):
    if value is None:
        return "n/a (0 samples)"
    return "%.1f (n=%d)" % (value, n)


def fmt_share(value, num, den):
    if value is None:
        return "n/a (0 samples)"
    return "%.1f%% (%d of %d)" % (value, num, den)


def render_table(report):
    out = []
    budget = report["request_budget"]
    out.append("# Review timing and CI report (%s)" % SCHEMA)
    out.append("")
    out.append("Wait: %d min (%s). Last %d merged PRs per repo%s." % (
        report["wait_minutes"], report["wait_source"], report["limit"],
        " merged since %s" % report["since"] if report["since"] else ""))
    out.append("Request budget: 1 GraphQL request per repo, %d total." % budget["graphql_requests_total"])
    out.append("")
    for repo in report["per_repo"]:
        if repo["status"] == "unread":
            out.append("## %s: unread (%s)" % (repo["repo"], repo["reason"]))
            out.append("")
            out.append("| Metric | Value |")
            out.append("| --- | --- |")
            out.append("| CI duration median / p90 | unread () |")
            out.append("| Commits with failed CI | unread () |")
            out.append("| Reviews | unread () |")
            out.append("")
            continue
        ci = repo["ci"]
        out.append("## %s" % repo["repo"])
        out.append("")
        out.append("Requests: 1 GraphQL request; reported point cost %s." % (
            "n/a" if repo.get("rate_limit_cost") is None else repo["rate_limit_cost"]))
        out.append("")
        out.append("| Metric | Value |")
        out.append("| --- | --- |")
        out.append("| PRs sampled | %d |" % repo["prs_sampled"])
        out.append("| Commits (CI completed / sampled) | %d / %d |" % (ci["commits_ci_completed"], ci["commits_sampled"]))
        out.append("| CI duration median / p90 (min) | %s / %s (n=%d) |" % (
            "n/a" if ci["duration_median_min"] is None else "%.1f" % ci["duration_median_min"],
            "n/a" if ci["duration_p90_min"] is None else "%.1f" % ci["duration_p90_min"],
            ci["duration_n"]))
        out.append("| Commits whose CI failed | %s |" % fmt_share(ci["failed_share_pct"], ci["commits_ci_failed"], ci["commits_ci_completed"]))
        out.append("")
        out.append("| Reviewer | Reviews | Response median / p90 (min) | Within %d min | On failed-CI commits | First review on failed CI | Refusals | Pre-review approvals |" % report["wait_minutes"])
        out.append("| --- | --- | --- | --- | --- | --- | --- | --- |")
        for login, _label in REVIEWERS:
            r = repo["reviewers"][login]
            median_v = r["response_median_min"]
            p90_v = r["response_p90_min"]
            if median_v is None:
                timing = "n/a (0 samples)"
            else:
                timing = "%.1f / %.1f (n=%d)" % (median_v, p90_v, r["response_n"])
            pre = str(r.get("pre_review_approvals", "not tracked")) if login == "codeant-ai" else "not tracked"
            out.append("| %s | %d%s | %s | %s | %s | %s | %d | %s |" % (
                r["label"], r["reviews"], " (small sample)" if r["small_sample"] else "",
                timing,
                fmt_share(r["within_wait_pct"], r["within_wait_count"], r["within_wait_n"]),
                fmt_share(r["reviews_on_failed_ci_pct"], r["reviews_on_failed_ci"], r["reviews_on_completed_ci"]),
                fmt_share(r["first_reviews_on_failed_ci_pct"], r["first_reviews_on_failed_ci"], r["first_reviews_completed_ci"]),
                r["refusals"], pre))
        out.append("")
        out.append("Blind spots:")
        for line in repo["blind_spots"]:
            out.append("- %s" % line)
        out.append("")
    out.append(PREFIX_NOTE)
    return "\n".join(out) + "\n"


def main(argv=None):
    parser = argparse.ArgumentParser(prog="review_ci_report.py", add_help=False)
    parser.add_argument("--manifest", required=True)
    parser.add_argument("--wait-minutes", type=int, required=True)
    parser.add_argument("--wait-source", required=True)
    parser.add_argument("--limit", type=int, required=True)
    parser.add_argument("--since", default="")
    parser.add_argument("--format", choices=("table", "json"), default="table")
    args = parser.parse_args(argv)
    with open(args.manifest, "r", encoding="utf-8") as handle:
        # One JSON object per line: {"repo", "rc", "out_file", "err"}.
        manifest = [json.loads(line) for line in handle if line.strip()]
    report = build_report(manifest, args.wait_minutes, args.wait_source, args.limit, args.since or None)
    if args.format == "json":
        sys.stdout.write(json.dumps(report, indent=2, sort_keys=True) + "\n")
    else:
        sys.stdout.write(render_table(report))
    return 0 if report["all_read"] else 1


if __name__ == "__main__":
    sys.exit(main())
